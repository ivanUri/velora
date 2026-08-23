// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const datetime = @import("../../support/datetime.zig");
const assert = @import("../../support/assert.zig").assert;
const builtin = @import("builtin");

const App = @import("../../runtime/App.zig");

const js = @import("../js/js.zig");
const v8 = js.v8;
const storage = @import("../webapi/storage/storage.zig");
const Navigation = @import("../webapi/navigation/Navigation.zig");
const History = @import("../webapi/History.zig");

const Frame = @import("Frame.zig");
const Page = @import("Page.zig");
const IFrame = @import("../webapi/element/html/IFrame.zig");
const URL = @import("../webapi/URL.zig");
const BrowserURL = @import("URL.zig");
pub const Runner = @import("Runner.zig");
const Browser = @import("Browser.zig");
const ClientHints = @import("../../runtime/profile/ClientHints.zig");
const Notification = @import("../../runtime/Notification.zig");
const QueuedNavigation = Frame.QueuedNavigation;

const log = @import("../../support/log.zig");
const FingerprintSeed = @import("../../runtime/profile/FingerprintSeed.zig");
const ArenaPool = App.ArenaPool;
const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;

// A Session represents a browsing context group (cookie jar, session storage,
// navigation history) within a Browser. It hosts one Page at a time — the
// root Frame and all of its descendants — and is responsible for Page
// lifecycle (create, remove, replace on root navigation).
//
// Multiple concurrent Pages (e.g. an old Page retiring while a new provisional
// Page is loading) are not yet supported; see Page.zig for the intended
// direction.
const Session = @This();

browser: *Browser,
arena: Allocator,
history: History,
navigation: Navigation,
storage_shed: storage.Shed,
notification: *Notification,
cookie_jar: storage.Cookie.Jar,
fingerprint_seed: u64 = 0,

/// CDP Emulation overrides for this session (set when attached via BrowserContext).
emulation: ?*const @import("../../protocols/cdp/EmulationState.zig").State = null,

// Shared allocator. Used by Session itself and borrowed by Pages.
arena_pool: *ArenaPool,

// Pool for FinalizerCallback.Identity structs. These must survive Page
// teardowns so V8 weak callbacks can validate the FC before dereferencing it.
fc_identity_pool: std.heap.MemoryPool(FinalizerCallback.Identity),

// The currently-active Page
// flips this pointer.
_active: ?*Page = null,

// In-flight root navigation
_pending: ?*Page = null,

/// Retries for transient root document HTTP failures (e.g. ebay.com status=0).
_pending_root_nav_retries: u8 = 0,

// Discarded pending pages waiting for in-flight document transfers whose
// req.ctx still aliases the frame. Reaped from HttpClient after transfer.deinit.
_zombie_pending_pages: std.ArrayList(*Page) = .empty,

/// Active/pending pages deferred until native WebSocket `pollNative` unwinds.
_zombie_pages: std.ArrayList(*Page) = .empty,

// True when a pending root navigation's headers arrived inside a
// reentrant HttpClient.perform (e.g. JS on the active page called fetch();
// libcurl drained the pending navigation's response while we are still
// nested inside Fetch.init). Committing immediately would destroy the
// active page's V8 context while JS is on its stack and would also abort
// the JS-initiated transfer we are currently submitting, producing a UAF
// (frame_id is shared between active and pending pages — abortFrame in
// Frame.deinit kills the in-flight fetch and its shutdown_callback then
// dereferences a freed Execution). When set, commitPendingPage and the
// associated protect_from_abort flip + frame_navigated dispatch are
// postponed until drainDeferredCommit runs at a safe point (top of CDP
// tick or before a new root navigation discards the pending page).
_deferred_commit_pending: bool = false,

/// Depth of `initiateRootNavigation` / `commitPendingPage`. Gates reentrant
/// `HttpClient.serviceInboundCdpIfReadable` (Page.navigate during commitPendingPage
/// or post-commit HTTP callbacks) to avoid tearing down pages concurrently.
_navigation_critical_depth: u32 = 0,

// When set during CDP dispatch, `currentFrame()` resolves to this child frame
// (iframe target session). Cleared after each command.
cdp_frame_override: ?u32 = null,

// IDs. Kept at Session level so IDs can remain unique across Page replacements.
frame_id_gen: u32 = 0,
loader_id_gen: u32 = 0,

/// Origins that sent `Accept-CH` for UA client hints (high-entropy hints enabled).
_client_hints_origins: ClientHints.OriginSet = .empty,

_shared_workers: std.StringHashMapUnmanaged(*@import("../webapi/shared_worker.zig").SharedWorkerRuntime) = .{},

pub fn init(self: *Session, browser: *Browser, notification: *Notification) !void {
    const allocator = browser.app.allocator;
    const arena_pool = browser.arena_pool;

    const arena = try arena_pool.acquire(.small, "Session");
    errdefer arena_pool.release(arena);

    self.* = .{
        .arena = arena,
        .arena_pool = arena_pool,
        .history = .{},
        // The prototype (EventTarget) for Navigation is created when a Frame is created.
        .navigation = .{ ._proto = undefined },
        .storage_shed = .{},
        .browser = browser,
        .notification = notification,
        .fc_identity_pool = .empty,
        .cookie_jar = storage.Cookie.Jar.init(allocator),
        .fingerprint_seed = FingerprintSeed.sessionSeed(
            browser.app.config.profile.id,
            @intCast(datetime.nanoTimestamp(.monotonic)),
        ),
    };
    self.enableProfilePersistence();
}

/// Record `Accept-CH` from a response so subsequent requests to the same origin
/// include high-entropy UA client hints (Chrome behavior after page 1).
pub fn processAcceptClientHints(
    self: *Session,
    response_url: [:0]const u8,
    header_iter: *@import("../../runtime/network/http.zig").HeaderIterator,
) !void {
    return ClientHints.processAcceptHeaders(&self._client_hints_origins, self.arena, response_url, header_iter);
}

pub fn clientHintsEnabledForUrl(self: *const Session, allocator: Allocator, url: [:0]const u8) bool {
    return ClientHints.enabledForUrl(&self._client_hints_origins, allocator, url);
}

pub fn deinit(self: *Session) void {
    // A page can be deferred as a zombie while a native WebSocket poll still
    // aliases its Frame. Session teardown is the final owner boundary, so
    // cancel those frame-attributed transports and drain their abort callbacks
    // before touching Page/V8 state. Finishing a zombie while curl still has
    // the frame on its callback stack is a direct UAF/SIGSEGV path on sites
    // with long-lived WebSockets (for example Tinhte).
    for (self._zombie_pages.items) |zombie| {
        self.browser.http_client.abortTransfersAttributedTo(&zombie.frame, .{ .scope = .full });
    }
    for (self._zombie_pending_pages.items) |zombie| {
        self.browser.http_client.abortTransfersAttributedTo(&zombie.frame, .{ .scope = .full });
    }
    if (self._zombie_pages.items.len > 0 or self._zombie_pending_pages.items.len > 0) {
        _ = self.browser.http_client.tick(0) catch {};
    }

    for (self._zombie_pages.items) |zombie| {
        self.finishDestroyPage(zombie);
    }
    self._zombie_pages = .empty;

    for (self._zombie_pending_pages.items) |zombie| {
        self.finishDestroyPage(zombie);
    }
    self._zombie_pending_pages = .empty;

    if (self._pending != null) {
        self.discardPendingPage();
    }
    if (self._active != null) {
        // removePage bails when is_evaluating to avoid reentrant CDP teardown
        // inside syncRequest. Final session destruction must always reclaim the
        // active page or V8 contexts survive until Platform.deinit.
        self.browser.env.waitForBackgroundTasks();
        if (self.activeIsEvaluating()) {
            self.browser.env.terminate();
            self.browser.env.pumpMessageLoop();
            self.browser.env.runMicrotasks(.unknown);
            self.browser.env.cancelTerminate();
        }
        if (self._pending != null) {
            self.discardPendingPage();
        }
        if (self._active != null) {
            self.tearDownActivePage();
        }
    }
    self.destroySharedWorkers();
    if (self.browser.app.storage.usesSqlite()) {
        self.browser.app.storage.flush() catch |err| log.err(.storage, "session sqlite flush", .{ .err = err });
        self.cookie_jar.setMutationSink(null);
    }
    self.cookie_jar.deinit();
    self._client_hints_origins.deinit(self.arena);

    // Force V8 to flush any remaining weak callbacks while
    // fc_identity_pool is still alive. Identity structs allocated from
    // this pool back V8 weak-callback parameters; freeing the pool first
    // would leave dangling pointers that segfault on the next GC.
    self.browser.env.memoryPressureNotification(.critical);
    self.fc_identity_pool.deinit(self.browser.app.allocator);

    // storage_shed and all Lookup contents use the session arena. Reset the
    // root before returning that arena to the pool; freeing entries through the
    // app allocator would mix allocator ownership.
    self.storage_shed = .{};
    self.arena_pool.release(self.arena);
}

pub fn prepareForBrowserShutdown(self: *Session) void {
    if (self._active) |page| page.prepareForBrowserShutdown();
    if (self._pending) |page| page.prepareForBrowserShutdown();
    for (self._zombie_pages.items) |page| page.prepareForBrowserShutdown();
    for (self._zombie_pending_pages.items) |page| page.prepareForBrowserShutdown();

    var it = self._shared_workers.valueIterator();
    while (it.next()) |runtime| {
        runtime.*.host._frame.prepareForBrowserShutdown();
    }
}

pub fn enableProfilePersistence(self: *Session) void {
    if (!self.browser.app.storage.usesSqlite()) return;
    self.cookie_jar.setMutationSink(.{ .ctx = self, .notify = persistCookieMutation });
}

fn persistCookieMutation(ctx: *anyopaque, mutation: storage.Cookie.Jar.Mutation) void {
    const self: *Session = @ptrCast(@alignCast(ctx));
    const persistent = &self.browser.app.storage;
    switch (mutation) {
        .upsert => |cookie| persistent.cookieUpsert(cookie.*) catch |err| log.err(.storage, "cookie enqueue", .{ .err = err }),
        .delete => |cookie| persistent.cookieDelete(cookie.*) catch |err| log.err(.storage, "cookie delete enqueue", .{ .err = err }),
        .clear => persistent.cookieClear() catch |err| log.err(.storage, "cookie clear enqueue", .{ .err = err }),
    }
}

pub fn persistLocalSet(self: *Session, origin: []const u8, key: []const u8, value: []const u8) void {
    self.browser.app.storage.localSet(origin, key, value) catch |err| log.err(.storage, "localStorage set enqueue", .{ .err = err });
}

pub fn persistLocalRemove(self: *Session, origin: []const u8, key: []const u8) void {
    self.browser.app.storage.localRemove(origin, key) catch |err| log.err(.storage, "localStorage remove enqueue", .{ .err = err });
}

pub fn persistLocalClear(self: *Session, origin: []const u8) void {
    self.browser.app.storage.localClear(origin) catch |err| log.err(.storage, "localStorage clear enqueue", .{ .err = err });
}

pub fn enqueueCurrentProfileState(self: *Session) void {
    var it = self.storage_shed._origins.iterator();
    while (it.next()) |origin_entry| {
        var local = origin_entry.value_ptr.*.local._data.iterator();
        while (local.next()) |item| {
            self.persistLocalSet(origin_entry.key_ptr.*, item.key_ptr.*, item.value_ptr.*);
        }
    }
    for (self.cookie_jar.cookies.items) |*cookie| {
        self.browser.app.storage.cookieUpsert(cookie.*) catch |err| log.err(.storage, "cookie seed enqueue", .{ .err = err });
    }
}

/// Emit a redacted, origin-scoped storage snapshot for local observability.
/// Values are intentionally omitted because the JSONL sink is durable and may
/// be opened outside the browser process.
pub fn emitApplicationStorageSnapshot(self: *Session, frame: *Frame) void {
    const max_entries = 1_000;
    var emitted: usize = 0;
    var cookie_count: usize = 0;
    var local_storage_count: usize = 0;
    var session_storage_count: usize = 0;
    var indexed_db_count: usize = 0;

    const maybe_inspected_origin = BrowserURL.getOrigin(self.arena, frame.url) catch return;
    const inspected_origin = maybe_inspected_origin orelse return;
    const inspected_host = BrowserURL.getHostname(frame.url);

    for (self.cookie_jar.cookies.items) |*cookie| {
        if (!cookieMatchesHost(cookie.domain, inspected_host)) continue;
        cookie_count += 1;
        if (emitted < max_entries) {
            self.browser.observeApplicationStorageEntry("cookies", cookie.domain, cookie.name, cookie.value, cookie.value.len, .{
                .domain = cookie.domain,
                .path = cookie.path,
                .expires = cookie.expires,
                .secure = cookie.secure,
                .httpOnly = cookie.http_only,
                .sameSite = @tagName(cookie.same_site),
                .partitioned = cookie.partitioned,
                .partitionSite = cookie.partition_site,
            });
            emitted += 1;
        }
    }

    var origins = self.storage_shed._origins.iterator();
    while (origins.next()) |origin_entry| {
        const origin = origin_entry.key_ptr.*;
        if (!std.mem.eql(u8, origin, inspected_origin)) continue;
        var local = origin_entry.value_ptr.*.local._data.iterator();
        while (local.next()) |entry| {
            local_storage_count += 1;
            if (emitted < max_entries) {
                self.browser.observeApplicationStorageEntry("local-storage", origin, entry.key_ptr.*, entry.value_ptr.*, entry.value_ptr.*.len, .{});
                emitted += 1;
            }
        }
        var session = origin_entry.value_ptr.*.session._data.iterator();
        while (session.next()) |entry| {
            session_storage_count += 1;
            if (emitted < max_entries) {
                self.browser.observeApplicationStorageEntry("session-storage", origin, entry.key_ptr.*, entry.value_ptr.*, entry.value_ptr.*.len, .{});
                emitted += 1;
            }
        }
    }

    var indexed_databases: std.ArrayListUnmanaged(@import("../webapi/idb.zig").IDBFactory.Snapshot) = .empty;
    defer indexed_databases.deinit(self.arena);
    frame.window.getIndexedDB().appendSnapshot(&indexed_databases, self.arena) catch return;
    for (indexed_databases.items) |database| {
        indexed_db_count += 1;
        if (emitted < max_entries) {
            self.browser.observeApplicationStorageEntry("indexed-db", inspected_origin, database.name, null, 0, .{
                .version = database.version,
                .objectStoreCount = database.object_store_count,
                .recordCount = database.record_count,
                .snapshotState = "metadata-only",
            });
            emitted += 1;
        }
    }

    self.browser.observeApplicationStorageEntry("snapshot", inspected_origin, "snapshot", null, 0, .{
        .state = "complete",
        .cookies = cookie_count,
        .localStorage = local_storage_count,
        .sessionStorage = session_storage_count,
        .indexedDb = indexed_db_count,
        .emittedEntries = emitted,
        .truncated = emitted >= max_entries,
    });
}

fn cookieMatchesHost(cookie_domain: []const u8, host: []const u8) bool {
    if (cookie_domain.len == 0 or host.len == 0) return false;
    if (cookie_domain[0] != '.') return std.ascii.eqlIgnoreCase(cookie_domain, host);
    const domain = cookie_domain[1..];
    return std.ascii.eqlIgnoreCase(domain, host) or
        (host.len > domain.len and std.ascii.eqlIgnoreCase(host[host.len - domain.len ..], domain) and host[host.len - domain.len - 1] == '.');
}

test "Application snapshot only includes cookies visible to inspected host" {
    try std.testing.expect(cookieMatchesHost("example.com", "example.com"));
    try std.testing.expect(!cookieMatchesHost("example.com", "www.example.com"));
    try std.testing.expect(cookieMatchesHost(".example.com", "www.example.com"));
    try std.testing.expect(!cookieMatchesHost(".example.com", "notexample.com"));
}

// True iff there is an active Page. CDP / external callers should use this
// (or `currentPage()`) rather than poking at the underlying field.
pub fn hasPage(self: *const Session) bool {
    return self._active != null;
}

/// BrowserContext disposal may be requested immediately after Target.closeTarget,
/// while curl still has a callback or native WebSocket poll referring to a
/// retired Page. Only release the Session once every page/transfer alias is
/// gone; the CDP tick loop will retry this predicate after draining I/O.
pub fn canDisposeContext(self: *const Session) bool {
    if (self._active != null or self._pending != null) return false;
    for (self._zombie_pages.items) |page| {
        const frame_ctx: *const anyopaque = &page.frame;
        if (self.browser.http_client.frameHasWebSocketPollInFlight(@constCast(frame_ctx)) or
            self.browser.http_client.hasLiveTransferWithCtx(frame_ctx)) return false;
    }
    for (self._zombie_pending_pages.items) |page| {
        const frame_ctx: *const anyopaque = &page.frame;
        if (self.browser.http_client.hasLiveTransferWithCtx(frame_ctx)) return false;
    }
    return true;
}

// Allocate and initialize a Page.
fn allocatePage(self: *Session, frame_id: u32) !*Page {
    const page = try self.browser.page_pool.create(self.browser.allocator);
    errdefer self.browser.page_pool.destroy(page);

    try Page.init(page, self, frame_id);
    return page;
}

fn finishDestroyPage(self: *Session, page: *Page) void {
    // SharedWorkerRuntime currently owns a realm assembled from its creator
    // Page's factory and registries. Tear it down while that Page is still
    // valid; destroying the Page first leaves Context.page dangling during
    // realm cleanup (for example BroadcastChannel detachment).
    self.destroySharedWorkersOwnedBy(page);
    page.deinit();
    self.browser.page_pool.destroy(page);
}

// Tear down and free a Page allocated via allocatePage.
fn destroyPage(self: *Session, page: *Page) void {
    if (self.browser.http_client.frameHasWebSocketPollInFlight(&page.frame)) {
        self._zombie_pages.append(self.arena, page) catch {
            self.finishDestroyPage(page);
        };
        return;
    }
    self.finishDestroyPage(page);
}

// Tear down the currently-active Page. Dispatches `frame_remove` first
// so CDP can clear inspector state while the OLD page is still walkable,
// then frees the slot and notifies Navigation. Resets `frame_id_gen` to
// match pre-pending-page behavior. Used by removePage and by the
// synthetic-nav path (replaceRootImmediate). Does NOT touch any pending
// page — callers handle that themselves.
//
// NOT a substitute for the careful 5-step sequence in commitPendingPage,
// which interleaves the OLD-page teardown with the pending-page promotion
// in a specific order.
fn tearDownActivePage(self: *Session) void {
    self.notification.dispatch(.frame_remove, .{});
    const page = self._active orelse {
        if (comptime IS_DEBUG) {
            assert(false, "Session.tearDownActivePage - no active page", .{});
        }
        return;
    };
    self.destroyPage(page);
    self._active = null;
    self.history.onRemoveFrame();
    self.navigation.onRemoveFrame();
    self.frame_id_gen = 0;
}

// Allocate a Page in a free slot, publish it as the active page, and
// dispatch `frame_created` so CDP creates fresh isolated-world V8
// contexts. Used by createPage and by the synthetic-nav path. Does NOT
// dispatch `frame_navigate` — the caller does that (or doesn't, for a
// blank initial page).
//
// On any failure after allocation, the errdefers roll back the Page
// and `active`, leaving the session pageless (the caller is responsible
// for any prior teardown of an old page).
fn installNewActivePage(self: *Session, frame_id: u32) !*Frame {
    const page = try self.allocatePage(frame_id);
    errdefer self.destroyPage(page);
    self._active = page;
    errdefer self._active = null;

    const frame = &page.frame;
    self.history.onNewFrame(frame);
    try self.navigation.onNewFrame(frame);
    // Inform CDP the main frame has been created such that additional
    // context for other Worlds can be created as well.
    self.notification.dispatch(.frame_created, frame);
    return frame;
}

// NOTE: the caller is not the owner of the returned value,
// the pointer on Frame is just returned as a convenience
pub fn createPage(self: *Session) !*Frame {
    assert(self._active == null, "Session.createPage - page not null", .{});
    if (comptime IS_DEBUG) {
        log.debug(.browser, "create page", .{});
    }
    return self.installNewActivePage(self.nextFrameId());
}

pub fn removePage(self: *Session) void {
    const page = self._active orelse {
        assert(false, "Session.removePage - page is null", .{});
        unreachable;
    };

    if (page.frame._script_manager.base.is_evaluating) {
        // Reentrant teardown from a CDP message drained inside syncRequest;
        // Session.deinit reclaims the page when the connection closes.
        return;
    }

    // If a navigation is in flight, drop the pending Page first. Its
    // transfer was protected from abort to survive commitPendingPage's
    // teardown of the old page, but we are now permanently removing the
    // session's page state — the pending transfer should die with it.
    if (self._pending != null) {
        self.discardPendingPage();
    }
    self.tearDownActivePage();
    if (comptime IS_DEBUG) {
        log.debug(.browser, "remove page", .{});
    }
}

pub fn getArena(self: *Session, size_or_bucket: anytype, debug: []const u8) !Allocator {
    return self.arena_pool.acquire(size_or_bucket, debug);
}

pub fn releaseArena(self: *Session, allocator: Allocator) void {
    self.arena_pool.release(allocator);
}

pub fn getOrCreateOrigin(self: *Session, key_: ?[]const u8) !*js.Origin {
    return self.currentPage().?.getOrCreateOrigin(key_);
}

pub fn releaseOrigin(self: *Session, origin: *js.Origin) void {
    self.currentPage().?.releaseOrigin(origin);
}

pub fn currentPage(self: *Session) ?*Page {
    return self._active;
}

pub fn pendingPage(self: *Session) ?*Page {
    return self._pending;
}

pub fn pendingOrCurrentFrame(self: *Session) ?*Frame {
    const page = self.pendingPage() orelse self.currentPage() orelse return null;
    return &page.frame;
}

pub fn currentFrame(self: *Session) ?*Frame {
    const page = self.currentPage() orelse return null;
    if (self.cdp_frame_override) |frame_id| {
        return page.findFrameByFrameId(frame_id) orelse &page.frame;
    }
    return &page.frame;
}

pub fn findFrameByFrameId(self: *Session, frame_id: u32) ?*Frame {
    const page = self.currentPage() orelse return null;
    return page.findFrameByFrameId(frame_id);
}

/// Resolve HTTP frame_id to a real Frame (including dedicated-worker synthetic ids).
pub fn findFrameForHttpAttribution(self: *Session, frame_id: u32) ?*Frame {
    if (self.findFrameByFrameId(frame_id)) |frame| return frame;
    const page = self.currentPage() orelse return null;
    return page.findFrameForWorkerFrameId(frame_id);
}

pub fn runner(self: *Session, opts: Runner.Opts) !Runner {
    return Runner.init(self, opts);
}

pub fn scheduleNavigation(self: *Session, frame: *Frame) !void {
    return self.currentPage().?.scheduleNavigation(frame);
}

/// Upgrade a parser-inserted iframe from `about:blank` to its real `src` immediately.
/// html5ever may run `nodeComplete` before attributes are bound on void elements.
pub fn upgradeIframeFromAboutBlank(self: *Session, parent: *Frame, iframe: *IFrame, src: []const u8) !void {
    if (src.len == 0 or std.mem.eql(u8, src, "about:blank")) return;
    const window = iframe._window orelse return;
    const child = window._frame;
    if (!std.mem.eql(u8, child.url, "about:blank")) return;

    const arena = try self.getArena(.small, "upgradeIframe");
    errdefer self.releaseArena(arena);

    const resolved_url = try URL.resolve(arena, parent.base(), src, .{
        .always_dupe = true,
        .encoding = parent.charset,
    });

    var nav_opts: Frame.NavigateOpts = .{
        .reason = .initialFrameNavigation,
        .kind = .{ .push = null },
    };
    if (std.mem.startsWith(u8, parent.url, "http")) {
        nav_opts.referer = try arena.dupe(u8, parent.url);
    }
    if (parent.origin) |origin| {
        nav_opts.prior_origin = try arena.dupe(u8, origin);
    }

    const qn = try arena.create(QueuedNavigation);
    qn.* = .{
        .opts = nav_opts,
        .arena = arena,
        .url = resolved_url,
        .is_about_blank = false,
        .navigation_type = .iframe,
    };

    return self.processFrameNavigation(child, qn);
}

pub fn processQueuedNavigation(self: *Session) !void {
    const page = self.currentPage() orelse return;
    const navigations = page.queued_navigation;
    if (page.queued_navigation == &page.queued_navigation_1) {
        page.queued_navigation = &page.queued_navigation_2;
    } else {
        page.queued_navigation = &page.queued_navigation_1;
    }

    if (page.frame._queued_navigation != null) {
        // This is both an optimization and a simplification of sorts. If the
        // root frame is navigating, then we don't need to process any other
        // navigation. Also, the navigation for the root frame and for a frame
        // is different enough that have two distinct code blocks is, imo,
        // better. Yes, there will be duplication.
        navigations.clearRetainingCapacity();
        return self.processRootQueuedNavigation();
    }

    const about_blank_queue = &page.queued_queued_navigation;
    defer about_blank_queue.clearRetainingCapacity();

    // First pass: process async navigations (non-about:blank)
    for (navigations.items) |frame| {
        // Detached iframe teardown can leave a stale pointer in this
        // double-buffered queue. Its scheduler finalizer owns Frame.deinit;
        // the queue no longer owns or may dereference its navigation.
        if (frame._deinit_done) continue;
        const qn = frame._queued_navigation orelse continue;

        if (qn.is_about_blank) {
            // Defer about:blank to second pass
            try about_blank_queue.append(self.arena, frame);
            continue;
        }

        self.processFrameNavigation(frame, qn) catch |err| {
            log.warn(.frame, "frame navigation", .{ .url = qn.url, .err = err });
        };
    }

    navigations.clearRetainingCapacity();

    // Second pass: process synchronous navigations (about:blank)
    // These may trigger new navigations which go into queued_navigation
    for (about_blank_queue.items) |frame| {
        if (frame._deinit_done) continue;
        const qn = frame._queued_navigation orelse continue;
        try self.processFrameNavigation(frame, qn);
    }

    // Safety: Remove any about:blank navigations that were queued during
    // processing to prevent infinite loops. New navigations have been queued
    // in the other buffer.
    const new_navigations = page.queued_navigation;
    var i: usize = 0;
    while (i < new_navigations.items.len) {
        const frame = new_navigations.items[i];
        if (frame._queued_navigation) |qn| {
            if (qn.is_about_blank) {
                log.warn(.frame, "recursive about blank", .{});
                _ = page.queued_navigation.swapRemove(i);
                continue;
            }
        }
        i += 1;
    }
}

fn processFrameNavigation(self: *Session, frame: *Frame, qn: *QueuedNavigation) !void {
    // Popups live on the Page as top-level browsing contexts without a
    // parent or iframe element. Their re-navigation path is simpler than
    // iframes — no parent bookkeeping to patch.
    if (frame.parent == null and frame.iframe == null) {
        return self.processPopupNavigation(frame, qn);
    }

    assert(frame.parent != null, "root queued navigation", .{});

    const iframe = frame.iframe.?;
    const parent = frame.parent.?;

    const old_window_ptr: ?usize = if (iframe._window) |w| @intFromPtr(w) else null;

    // Snapshot before deinit — qn lives in qn.arena which we release below.
    // If a prior deinit already released that arena, skip this frame (stale).
    if (frame._deinit_done) {
        // Arena was released with the frame; drop the queued entry only.
        return;
    }
    const nav_url = qn.url;
    const nav_opts = qn.opts;
    const qn_arena = qn.arena;
    frame._queued_navigation = null;
    // Commit-time suppression — see processRootQueuedNavigation.
    frame.suppressScheduler(.teardown);
    defer self.releaseArena(qn_arena);

    errdefer iframe._window = null;

    const parent_notified = frame._parent_notified;
    if (parent_notified) {
        // we already notified the parent that we had loaded
        parent._pending_loads += 1;
    }

    const frame_id = frame._frame_id;
    const page = self.currentPage().?;
    // Fire unload/pagehide on the departing document before tear-down so
    // navigations started from unload handlers are ignored (_unload_running).
    Frame.fireUnloadForNavigation(frame);
    frame.deinit();
    frame.* = undefined;

    errdefer {
        // If anything fails from this point on, frame.deinit will be called
        // and we need to remove the frame from the parent's frame list.
        for (parent.child_frames.items, 0..) |f, i| {
            if (f == frame) {
                parent.child_frames_sorted = false;
                _ = parent.child_frames.swapRemove(i);
                break;
            }
        }
    }

    try Frame.init(frame, frame_id, page, parent);
    errdefer {
        if (parent_notified) {
            parent._pending_loads -= 1;
        }
        frame.deinit();
    }

    frame.iframe = iframe;
    iframe._window = frame.window;

    if (old_window_ptr) |old| {
        _ = page.identity.rekey(
            page.frame_arena,
            self.browser.env.isolate.handle,
            old,
            @intFromPtr(frame.window),
            frame.window,
        );
    }

    frame.navigate(nav_url, nav_opts) catch |err| {
        log.err(.browser, "queued frame navigation error", .{ .err = err });
        return err;
    };
}

// Re-navigates a popup Frame in place. The Frame pointer stays stable
// (scripts in the opener may hold a cached Window ref — though the Window
// object inside is replaced, matching how iframes behave on navigation).
fn processPopupNavigation(self: *Session, frame: *Frame, qn: *QueuedNavigation) !void {
    frame._queued_navigation = null;
    frame.suppressScheduler(.teardown);
    defer self.releaseArena(qn.arena);

    // Preserve popup identity fields. _name lives in the Page arena and
    // survives Frame.deinit; _opener is just a pointer.
    const saved_name = frame.window._name;
    const saved_opener = frame.window._opener;
    const frame_id = frame._frame_id;
    const page = self.currentPage().?;

    frame.deinit();
    frame.* = undefined;

    errdefer {
        // If re-init fails, drop from popups so we don't leave a corpse.
        for (page.popups.items, 0..) |p, i| {
            if (p == frame) {
                _ = page.popups.swapRemove(i);
                break;
            }
        }
    }

    try Frame.init(frame, frame_id, page, null);
    errdefer frame.deinit();

    frame.window._name = saved_name;
    frame.window._opener = saved_opener;

    frame.navigate(qn.url, qn.opts) catch |err| {
        log.err(.browser, "queued popup navigation error", .{ .err = err });
        return err;
    };
}

fn processRootQueuedNavigation(self: *Session) !void {
    const active = self._active orelse {
        assert(false, "Session.processRootQueuedNavigation - no active page", .{});
        unreachable;
    };
    const current_frame = &active.frame;

    // Detach the QueuedNavigation. Whether we keep it on the active frame
    // (synthetic path) or transfer it to the pending frame (HTTP path), the
    // current frame must no longer claim it.
    const qn = current_frame._queued_navigation.?;
    current_frame._queued_navigation = null;

    // Synthetic navigations (about:blank, blob:) commit instantly — no HTTP,
    // so there is no in-flight window to worry about. Use the optimized
    // immediate-swap path for them.
    const is_synthetic = qn.is_about_blank or std.mem.startsWith(u8, qn.url, "blob:");

    if (is_synthetic) {
        return self.replaceRootImmediate(current_frame._frame_id, qn);
    }

    // The qn arena is consumed here regardless of success — frame.navigate
    // dupes the URL into the page's own arena, so we can release the qn
    // arena as soon as navigate returns.
    defer self.arena_pool.release(qn.arena);

    return self.initiateRootNavigation(current_frame._frame_id, qn.url, qn.opts);
}

// Legacy immediate-swap path: tear down the active page and create a new one
// in its place before issuing the navigation. Used for synthetic navigations
// (about:blank, blob:) where there is no in-flight HTTP and therefore no
// "pending" window to span.
fn replaceRootImmediate(self: *Session, frame_id: u32, qn: *QueuedNavigation) !void {
    defer self.arena_pool.release(qn.arena);

    if (self._active) |active| active.frame.suppressScheduler(.teardown);
    self.tearDownActivePage();
    const new_frame = try self.installNewActivePage(frame_id);

    new_frame.navigate(qn.url, qn.opts) catch |err| {
        log.err(.browser, "queued navigation error", .{ .err = err });
        return err;
    };
}

/// Cancel document-owned work on `frame` then abort attributed HTTP/WS.
/// Order: realm drain + scheduler cancel → kill transfers → curl drain → script arenas.
fn abortOutgoingSubresources(frame: *Frame, http_client: *@import("HttpClient.zig").Client) void {
    frame.prepareForOutgoingAbort();
    // Kill transfers attributed to this frame (requires attribution_frame on
    // Fetch/XHR/beacon/worker/script/image). protect_from_abort / keepalive
    // still survive via shouldAbortTransfer unless scope=.full.
    http_client.abortTransfersAttributedTo(frame, .{});
    // Drain libcurl messages so deferred abort notifications finish *before*
    // script_manager.reset frees Script arenas (nytimes.com UAF).
    _ = http_client.tick(0) catch {};
    frame._script_manager.reset();
    for (frame.child_frames.items) |child| {
        abortOutgoingSubresources(child, http_client);
    }
}

/// The browser starts each CDP session with a pristine initial about:blank
/// document.  A first address-bar navigation can reuse that Page/Frame in
/// place: there is no document-owned work to cancel and no old page that an
/// external client can still be interacting with.  Keeping this narrow is
/// important; once parsing, a child frame, or a script has run, navigation
/// must use the normal clean-slate teardown path.
fn canReuseInitialBlank(frame: *const Frame) bool {
    return frame.parent == null and
        std.mem.eql(u8, frame.url, "about:blank") and
        frame._load_state == .waiting and
        frame._parse_state == .pre and
        frame._navigated_options == null and
        frame._queued_navigation == null and
        frame.child_frames.items.len == 0 and
        frame.document._frame == frame and
        frame._realm_state == .active and
        !frame._script_manager.base.shutdown;
}

// Real HTTP root navigation: allocate a pending Page, leave the active Page
// alive, and dispatch the navigation HTTP request against the pending frame.
// The active Page (and its V8 context) stays addressable across the round-
// trip — Runtime.evaluate, DOM.*, etc. continue to operate on the OLD page
// until commitPendingPage swaps the pointer when response headers arrive.
pub fn initiateRootNavigation(self: *Session, frame_id: u32, url: [:0]const u8, opts: Frame.NavigateOpts) !void {
    self.enterNavigationCritical();
    defer self.leaveNavigationCritical();

    if (!opts.is_document_retry) {
        self._pending_root_nav_retries = 0;
    }

    // If a previous pending page is sitting on a deferred commit, finish it
    // before discardPendingPage tears it down. drainDeferredCommit is a no-op
    // if the active page is still mid-evaluate, in which case discardPendingPage
    // below will (correctly) abandon the deferred pending — the new navigation
    // supersedes it.
    self.drainDeferredCommit();
    self.discardPendingPage();

    // A fresh CDP session already owns an initial about:blank page. Reusing it
    // avoids a full Page/V8 teardown + allocation cycle on the first real
    // navigation while preserving the normal path for every non-pristine page.
    const clean_slate = opts.reason == .address_bar or opts.reason == .form;
    if (clean_slate) {
        if (self._active) |active| {
            if (active.frame._frame_id == frame_id and canReuseInitialBlank(&active.frame)) {
                active.frame.cancelOwnedSchedulerWork();
                active.frame.navigate(url, opts) catch |err| {
                    log.err(.browser, "initial blank navigation start", .{ .err = err, .url = url });
                    return err;
                };
                return;
            }
        }
    }

    // Drop outgoing-document script fetches before the pending page loads.
    // Heavy sites (Google knitsail, Bing) poison the next document parse if
    // their V8 context stays live through dual-page pending until headers
    // (incorrect alignment / SIGBUS mid-parse). Address-bar / form root
    // navigations use clean-slate: tear down the old page *before* the new
    // document transfer, then install the new page as active immediately.
    // Dual-page pending is kept only for in-page script navigations that may
    // still need the old realm during the hop.
    if (self._active) |active| {
        if (active.frame._frame_id == frame_id) {
            abortOutgoingSubresources(&active.frame, &self.browser.http_client);
            if (clean_slate) {
                active.frame.suppressScheduler(.teardown);
                self.browser.env.waitForBackgroundTasks();
                self.tearDownActivePage();
                self.reapZombiePages();
            }
        }
    }

    if (clean_slate) {
        const frame = try self.installNewActivePage(frame_id);
        if (comptime IS_DEBUG) {
            log.debug(.browser, "clean-slate navigate", .{ .url = url, .reason = opts.reason });
        }
        frame.navigate(url, opts) catch |err| {
            log.err(.browser, "clean-slate navigation start", .{ .err = err, .url = url });
            return err;
        };
        return;
    }

    const page = try self.allocatePage(frame_id);
    errdefer self.destroyPage(page);

    page._state = .pending;
    self._pending = page;
    errdefer self._pending = null;

    if (comptime IS_DEBUG) {
        log.debug(.browser, "initiate root navigation", .{ .url = url });
    }

    // No frame_created notification yet — CDP must not see the pending page
    // (no isolated worlds, no Target.* visibility). Inspector execution
    // contexts for the pending page are published at commit (frame_created
    // in_commit), after frame_remove surgically tears down the OLD page's
    // inspector mappings without resetting the live replacement context.

    page.frame.navigate(url, opts) catch |err| {
        log.err(.browser, "pending navigation start", .{ .err = err, .url = url });
        return err;
    };
}

// Promote the pending Page to be the active Page. Called from
// frameHeaderDoneCallback when the in-flight pending root navigation's
// response headers arrive.
//
// Order matters here:
//   1. frame_remove dispatch — CDP's frameRemove tears down the OUTGOING
//      page's inspector mappings. For pending-root swap it uses surgical
//      contextDestroyed (the replacement context is already live in the
//      same group); otherwise resetContextGroup(). Isolated worlds and
//      node_registry are cleared. The OLD page's memory is still alive
//      (intentional: CDP teardown can walk old-page state without UAF).
//   2. Pointer flip and _state = .active. session.page now points at the
//      pending page.
//   3. frame_created dispatch — CDP creates fresh isolated world contexts
//      against the new (now active) frame. While pending_page is still
//      non-null at this point, CDP's frameCreated handler skips its
//      frame_arena reset and captured_responses zeroing (the captured_
//      response for the request we are committing was just inserted by
//      onHttpResponseHeadersDone moments earlier and must survive).
//   4. pending_page = null. Order matters: step 3 reads it.
//   5. OLD Page.deinit + free LAST. Its frame.deinit calls
//      http_client.abortFrame(frame_id) on the frame_id that the OLD
//      page shares with the now-active pending page; the in-flight
//      navigation transfer (whose callback we are inside) is shielded
//      by protect_from_abort, which abortFrame's default .normal scope
//      honors. The caller clears the flag AFTER we return.
pub fn commitPendingPage(self: *Session) !void {
    self.enterNavigationCritical();
    defer self.leaveNavigationCritical();

    const pending = self._pending orelse {
        assert(false, "Session.commitPendingPage - no pending page", .{});
        unreachable;
    };
    const old_active = self._active orelse {
        assert(false, "Session.commitPendingPage - no active page", .{});
        unreachable;
    };

    if (comptime IS_DEBUG) {
        log.debug(.browser, "commit pending page", .{});
    }

    // Step 1: clear the OLD page's CDP / V8 inspector state.
    self.notification.dispatch(.frame_remove, .{});
    self.history.onRemoveFrame();
    self.navigation.onRemoveFrame();

    // Step 2: pointer flip. Page addresses are stable (heap-allocated),
    // so every self-pointer inside `pending` (window._frame,
    // document._frame, EventManager.frame, etc.) remains valid.
    self._active = pending;
    pending._state = .active;
    self.history.onNewFrame(&pending.frame);

    // Step 3: register the new page with CDP. `pending` is still set at
    // this point — CDP's frameCreated handler reads `pendingPage() != null`
    // to skip the captured_responses / frame_arena resets that would wipe
    // the in-flight response we just received.
    self.navigation.onNewFrame(&pending.frame) catch |err| {
        log.err(.browser, "commitPendingPage onNewFrame", .{ .err = err });
    };
    self.notification.dispatch(.frame_created, &pending.frame);

    // Step 4: `pending` = null AFTER frame_created so step 3 saw it.
    self._pending = null;

    // Step 5: tear down the OLD page LAST. Anything in steps 1-4 that
    // needed to walk the OLD page's state (CDP node_registry, inspector
    // context group, isolated worlds) has already done so. The OLD page's
    // frame.deinit calls http_client.abortFrame(frame_id) on the frame_id
    // shared with the pending page; the in-flight transfer survives via
    // protect_from_abort.
    //
    // Suppress the departing realm before teardown so runaway microtasks in
    // the old context cannot monopolize the event loop during destroyPage.
    old_active.frame.suppressScheduler(.teardown);
    // Drain V8 background tasks tied to the old context before freeing it.
    // Without this, platform worker threads can still be in Zig DOM hooks
    // (e.g. img.src → domChanged) after destroyContext → UAF / segfault.
    self.browser.env.waitForBackgroundTasks();
    self.destroyPage(old_active);
    self.reapZombiePages();
    self.reapZombiePendingPages();
}

// Discard a pending Page without committing. Used for failure paths
// (HTTP error before commit, session deinit during pending, etc.). The
// active page is untouched.
pub fn discardPendingPage(self: *Session) void {
    const page = self._pending orelse return;

    if (comptime IS_DEBUG) {
        log.debug(.browser, "discard pending page", .{});
    }

    const frame_ctx: *const anyopaque = &page.frame;

    // Force abort all inflight queries attributed to this pending frame.
    self.browser.http_client.abortTransfersAttributedTo(&page.frame, .{ .scope = .full });

    self._pending = null;
    // A discarded pending page invalidates any deferred commit targeting it.
    self._deferred_commit_pending = false;

    // Transfers aborted mid-perform keep req.ctx until curl drains; do not free
    // the frame while any transfer still aliases &page.frame.
    if (self.browser.http_client.hasLiveTransferWithCtx(frame_ctx)) {
        self._zombie_pending_pages.append(self.arena, page) catch {
            self.destroyPage(page);
        };
        return;
    }
    self.destroyPage(page);
}

// Free pages deferred while native WebSocket pollNative was still on the stack.
pub fn reapZombiePages(self: *Session) void {
    var i: usize = 0;
    while (i < self._zombie_pages.items.len) {
        const zombie = self._zombie_pages.items[i];
        if (self.browser.http_client.frameHasWebSocketPollInFlight(&zombie.frame)) {
            i += 1;
            continue;
        }
        _ = self._zombie_pages.swapRemove(i);
        self.finishDestroyPage(zombie);
    }
}

// Free discarded pending pages once no HTTP transfer aliases their frame ctx.
pub fn reapZombiePendingPages(self: *Session) void {
    var i: usize = 0;
    while (i < self._zombie_pending_pages.items.len) {
        const zombie = self._zombie_pending_pages.items[i];
        const frame_ctx: *const anyopaque = &zombie.frame;
        if (self.browser.http_client.hasLiveTransferWithCtx(frame_ctx)) {
            i += 1;
            continue;
        }
        _ = self._zombie_pending_pages.swapRemove(i);
        self.destroyPage(zombie);
    }
}

// True iff the currently active Page has JS on the V8 stack (a script is
// synchronously executing, or a JS-initiated HTTP request is being submitted
// inside HttpClient.request). Callers use this to detect re-entrancy paths
// where tearing down the active Page would invalidate live references the
// V8 callers hold (Execution*, isolate context, frame_id-bound transfers).
pub fn activeIsEvaluating(self: *const Session) bool {
    const active = self._active orelse return false;
    return active.frame._script_manager.base.is_evaluating or
        self.browser.cdpInspectorBusy();
}

// True when it is safe to tear down the active Page (commit pending root nav,
// discard stale pages). False while JS is on the V8 stack or protected HTTP
// transfers for the frame are still in flight.
pub fn canDestructivelyTeardown(self: *const Session, frame_id: u32) bool {
    if (self.activeIsEvaluating()) return false;
    if (self.browser.http_client.hasProtectedTransfersForFrame(frame_id)) return false;
    return true;
}

pub fn navigationCritical(self: *const Session) bool {
    return self._navigation_critical_depth > 0;
}

pub fn enterNavigationCritical(self: *Session) void {
    self._navigation_critical_depth += 1;
}

pub fn leaveNavigationCritical(self: *Session) void {
    if (self._navigation_critical_depth > 0) self._navigation_critical_depth -= 1;
}

// Commit any deferred pending root navigation when it is safe to do so.
// No-op if the active page is still mid-evaluate (caller will be re-invoked
// from a safer drain point), if there is no pending page (it was discarded),
// or if nothing was deferred. See `_deferred_commit_pending` for background.
pub fn drainDeferredCommit(self: *Session) void {
    if (!self._deferred_commit_pending) return;
    const pending = self._pending orelse {
        self._deferred_commit_pending = false;
        return;
    };
    if (!self.canDestructivelyTeardown(pending.frame._frame_id)) return;
    self._deferred_commit_pending = false;
    pending.frame.finalizePendingRootCommit() catch |err| {
        log.err(.browser, "drain deferred commit", .{ .err = err });
    };
}

pub fn nextFrameId(self: *Session) u32 {
    const id = self.frame_id_gen +% 1;
    self.frame_id_gen = id;
    return id;
}

pub fn nextLoaderId(self: *Session) u32 {
    const id = self.loader_id_gen +% 1;
    self.loader_id_gen = id;
    return id;
}

const SharedWorkerRuntime = @import("../webapi/shared_worker.zig").SharedWorkerRuntime;

pub fn getOrCreateSharedWorkerRuntime(self: *Session, params: SharedWorkerRuntime.CreateParams) !*SharedWorkerRuntime {
    if (self._shared_workers.get(params.identity_key)) |existing| {
        return existing;
    }
    const runtime = try SharedWorkerRuntime.create(self, params);
    try self._shared_workers.put(self.arena, runtime.identity_key, runtime);
    return runtime;
}

pub fn unregisterSharedWorkerRuntime(self: *Session, runtime: *SharedWorkerRuntime) void {
    _ = self._shared_workers.remove(runtime.identity_key);
}

fn destroySharedWorkersOwnedBy(self: *Session, page: *Page) void {
    if (self._shared_workers.count() == 0) return;

    // Runtime.destroy mutates the registry, so snapshot matching values first.
    var owned: std.ArrayList(*SharedWorkerRuntime) = .empty;
    var it = self._shared_workers.valueIterator();
    while (it.next()) |runtime| {
        if (runtime.*.owner_page == page) {
            owned.append(self.arena, runtime.*) catch {
                // Teardown cannot leave a runtime pointing into a Page that is
                // about to be freed. Destroy immediately if snapshot growth
                // fails; reset iteration because the map was mutated.
                runtime.*.destroy();
                return self.destroySharedWorkersOwnedBy(page);
            };
        }
    }
    for (owned.items) |runtime| runtime.destroy();
}

fn destroySharedWorkers(self: *Session) void {
    if (self._shared_workers.count() == 0) return;
    var list: std.ArrayList(*SharedWorkerRuntime) = .empty;
    var it = self._shared_workers.valueIterator();
    while (it.next()) |runtime| {
        list.append(self.arena, runtime.*) catch {};
    }
    self._shared_workers.deinit(self.arena);
    self._shared_workers = .{};
    for (list.items) |runtime| {
        if (!runtime.host._terminated) {
            runtime.host.deinitForSession(self);
        }
        self.releaseArena(runtime.arena);
    }
}

// Every finalizable instance of Zig gets 1 FinalizerCallback registered in the
// Page. This is to ensure that, if v8 doesn't finalize the value, we can
// release on Page teardown.
pub const FinalizerCallback = struct {
    page: *Page,
    arena: Allocator,
    resolved_ptr_id: usize,
    finalizer_ptr_id: usize,
    release_ref: *const fn (ptr_id: usize, page: *Page) void,
    force_deinit: *const fn (ptr_id: usize, page: *Page) void,

    // Linked list of Identities referencing this FC.
    identities: ?*Identity = null,
    // Count of active identities (for knowing when to clean up FC).
    identity_count: u8 = 0,

    // For every FinalizerCallback we'll have 1+ FinalizerCallback.Identity: one
    // for every identity that gets the instance. In most cases, that'll be 1.
    // Allocated from Session.fc_identity_pool so it survives Page teardowns and
    // allows the weak callback to safely check the done flag.
    pub const Identity = struct {
        session: *Session,
        // The Page that owns the FinalizerCallback this Identity references.
        // Only safe to dereference when `done == false`. When done is true,
        // the Page may have been torn down and this pointer is stale.
        page: *Page,
        identity: *js.Identity,
        finalizer_ptr_id: usize,
        resolved_ptr_id: usize,
        // Copy of the JS wrapper global so weak callbacks can reset it without
        // touching identity_map (which is unsafe during V8 GC).
        js_global: v8.Global = undefined,
        next: ?*Identity = null,
        done: bool = false,
    };

    // Called during Page teardown to force cleanup regardless of identities.
    pub fn deinit(self: *FinalizerCallback, page: *Page) void {
        // Mark all identities as done so stale V8 weak callbacks
        // won't find the wrong FC if resolved_ptr_id is reused.
        // Clear the list first — weak callbacks may destroy Identity nodes
        // while this walk would otherwise still hold pointers.
        var id = self.identities;
        self.identities = null;
        self.identity_count = 0;
        while (id) |identity| {
            const next = identity.next;
            _ = identity.identity.identity_map.remove(identity.resolved_ptr_id);
            identity.next = null;
            identity.done = true;
            id = next;
        }
        self.force_deinit(self.finalizer_ptr_id, page);
        page.releaseArena(self.arena);
    }
};

const testing = @import("../../testing/testing.zig");

test "Session: newer root navigation supersedes and releases pending page" {
    const active_frame = try testing.pageTest("regression/iframe_child_static.html", .{});
    const session = active_frame._session;
    defer testing.reset();
    defer if (session.currentPage() != null) session.removePage();

    const active_page = session.currentPage().?;
    const frame_id = active_frame._frame_id;

    try session.initiateRootNavigation(
        frame_id,
        "http://127.0.0.1:9582/fetch-stream-hold",
        .{ .reason = .script },
    );
    try std.testing.expect(session.pendingPage() != null);
    const first_pending = session.pendingPage().?;
    const first_loader_id = first_pending.frame._loader_id;
    try std.testing.expect(session.currentPage() == active_page);

    // No network tick occurs between these calls, so the first request is
    // deterministically pending when the newer navigation supersedes it.
    try session.initiateRootNavigation(
        frame_id,
        "http://127.0.0.1:9582/redirect-target",
        .{ .reason = .script },
    );
    try std.testing.expect(session.pendingPage() != null);
    const second_pending = session.pendingPage().?;
    // The arena is allowed to reuse the same address after terminal release;
    // loader identity, not allocation address, distinguishes navigations.
    try std.testing.expect(second_pending.frame._loader_id != first_loader_id);
    try std.testing.expect(session.currentPage() == active_page);

    var browser_runner = try session.runner(.{});
    try browser_runner.wait(.{ .ms = 2000, .until = .load });
    session.reapZombiePendingPages();

    try std.testing.expect(session.pendingPage() == null);
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:9582/redirect-target",
        session.currentFrame().?.url,
    );
    try std.testing.expectEqual(@as(usize, 0), session._zombie_pending_pages.items.len);
}

test "Session: first address-bar navigation reuses pristine initial page" {
    defer testing.reset();
    defer if (testing.test_session.currentPage() != null) testing.test_session.removePage();

    const initial_frame = try testing.test_session.createPage();
    const initial_page = testing.test_session.currentPage().?;
    const frame_id = initial_frame._frame_id;

    try std.testing.expect(canReuseInitialBlank(initial_frame));
    try testing.test_session.initiateRootNavigation(
        frame_id,
        "http://127.0.0.1:9582/echo_referer",
        .{ .reason = .address_bar },
    );

    // The optimization is intentionally observable as stable Page/Frame
    // identity during the first navigation. It must still complete through
    // the ordinary HTTP lifecycle and publish the final document.
    try std.testing.expect(testing.test_session.currentPage().? == initial_page);
    try std.testing.expect(testing.test_session.currentFrame().? == initial_frame);

    var browser_runner = try testing.test_session.runner(.{});
    try browser_runner.wait(.{ .ms = 2000, .until = .load });
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:9582/echo_referer",
        testing.test_session.currentFrame().?.url,
    );
}

test "Session: navigation after redirected stream has one terminal owner" {
    const active_frame = try testing.pageTest("regression/iframe_child_static.html", .{});
    const session = active_frame._session;
    defer testing.reset();
    defer if (session.currentPage() != null) session.removePage();

    const frame_id = active_frame._frame_id;
    try session.initiateRootNavigation(
        frame_id,
        "http://127.0.0.1:9582/redirect-stream-hold",
        .{ .reason = .script },
    );

    var browser_runner = try session.runner(.{});
    var reached_streaming_hop = false;
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        _ = try browser_runner.tick(.{ .ms = 10 });
        if (session.currentFrame()) |current| {
            if (std.mem.eql(
                u8,
                current.url,
                "http://127.0.0.1:9582/fetch-stream-hold",
            )) {
                reached_streaming_hop = true;
                break;
            }
        }
    }
    try std.testing.expect(reached_streaming_hop);

    try session.initiateRootNavigation(
        frame_id,
        "http://127.0.0.1:9582/redirect-target",
        .{ .reason = .script },
    );
    try browser_runner.wait(.{ .ms = 2000, .until = .load });
    session.reapZombiePendingPages();

    try std.testing.expect(session.pendingPage() == null);
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:9582/redirect-target",
        session.currentFrame().?.url,
    );
    try std.testing.expectEqual(@as(usize, 0), session._zombie_pending_pages.items.len);
}
