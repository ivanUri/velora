//
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
const builtin = @import("builtin");

const App = @import("../../runtime/App.zig");
const FingerprintProfile = @import("../profile/types.zig");
const ProfileStore = @import("../../runtime/profile/ProfileStore.zig");
const NavigatorState = @import("../webapi/NavigatorState.zig");

const js = @import("../js/js.zig");
const v8 = js.v8;

const Frame = @import("Frame.zig");
const Session = @import("Session.zig");
const Factory = @import("Factory.zig");
const BroadcastChannel = @import("../webapi/broadcast_channel.zig").BroadcastChannel;

const log = @import("../../support/log.zig");
const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;

// A Page is the container for a root Frame and all of its descendants
// (nested iframes). It owns the resources that share the lifetime of the root
// document: the DOM factory, the per-page arena, the JS identity map, shared
// origins, v8 global handles, and queued navigation buffers.
//
// In the future, a Session may hold multiple Pages at once (e.g. during a
// navigation, while the old Page is retiring and the new one is provisional).
// For now, Session still holds a single Page.
const Page = @This();

const TerminalOwner = struct {
    ctx: *anyopaque,
    release: *const fn (*anyopaque, *Page) void,
};

session: *Session,

// DOM object factory scoped to this Page's documents.
factory: Factory,

// The arena for this Page's lifetime. Document / Frame / Factory / DOM
// objects allocate out of this.
frame_arena: Allocator,

// Stable allocator for identity_map buckets and TaggedOpaque nodes. Kept
// separate from frame_arena so hash-table metadata is not perturbed by high-
// churn DOM/audio allocations and is only released on Page teardown.
identity_arena: Allocator,

// Origin map for same-origin context sharing. Entries live for the Page's
// lifetime.
origins: std.StringHashMapUnmanaged(*js.Origin) = .empty,

// Identity tracking for the main world. All main-world contexts in this Page
// share this, ensuring object identity works across same-origin frames.
identity: js.Identity = .{},

// Zig ptr ids queued by V8 weak callbacks. identity_map is not mutated inside
// weak callbacks (re-entrant GC during getOrPut would corrupt the table).
pending_identity_removals: std.ArrayList(usize) = .empty,

// Finalizer callbacks for Zig instances exposed to v8 in this Page. Keyed by
// Zig instance ptr. The backing FinalizerCallback.Identity structs come from
// Session.fc_identity_pool so they outlive the Page for v8 weak-callback
// safety.
finalizer_callbacks: std.AutoHashMapUnmanaged(usize, *Session.FinalizerCallback) = .empty,

/// Native owners whose storage outlives the transport but has not yet been
/// transferred to a JS wrapper (for example a completed fetch waiting for its
/// deferred Promise-settlement task).
terminal_owners: std.AutoHashMapUnmanaged(usize, TerminalOwner) = .empty,

// Tracked global v8 objects that need to be released when the Page tears down.
globals: std.ArrayList(v8.Global) = .empty,

// Temporary v8 globals that can be released early. Key is global.data_ptr.
temps: std.AutoHashMapUnmanaged(usize, v8.Global) = .empty,

// Double buffered so that, as we process one list of queued navigations, new
// entries are added to the separate buffer. Prevents endless navigation loops
// and invalidation of the list during iteration.
queued_navigation_1: std.ArrayList(*Frame) = .empty,
queued_navigation_2: std.ArrayList(*Frame) = .empty,
// pointer to either queued_navigation_1 or queued_navigation_2
queued_navigation: *std.ArrayList(*Frame) = undefined,

// Temporary buffer for about:blank navigations during processing.
// We process async navigations first (safe from re-entrance), then sync
// about:blank navigations (which may add to queued_navigation).
queued_queued_navigation: std.ArrayList(*Frame) = .empty,

// The root Frame of this Page. Non-optional — a Page always has a root frame.
frame: Frame,

// BroadcastChannel registry keyed by "{origin_key}\x1f{channel_name}".
broadcast_channels: std.StringHashMapUnmanaged(std.ArrayList(*BroadcastChannel)) = .empty,

// Popup Frames opened by window.open. They are top-level browsing contexts
// (parent == null, no iframe element) but share this Page's factory, arena,
// and identity map.
// Their lifetime is bound to the Page: on Page.deinit they
// are torn down. TODO: this is far from correct. An new window shouldn't be tied
// to the original page like this.
popups: std.ArrayList(*Frame) = .empty,

// Popups that have called window.close() but whose teardown is deferred to
// Page.deinit. We can't deinit synchronously from window.close() because
// that's invoked from JS still running on top of the Frame's V8 context (or
// from a script eval whose parser still holds the Frame).
queued_close: std.ArrayList(*Frame) = .empty,

// Lifecycle state. A Page is `.pending` while we hold it as the in-flight
// destination of a root navigation — its V8 context exists but is not yet the
// session's active context. Flipped to `.active` by Session.commitPendingPage
// when response headers arrive. Frame.navigate / frameHeaderDoneCallback
// branch on this to: (a) stamp `is_pending_root` on the frame_navigate
// notification (so CDP doesn't reset its node registry yet) and
// (b) flag the HTTP request `protect_from_abort` (so the old page's deinit
// can't kill the transfer we're sitting inside).
_state: enum { active, pending } = .active,

// Initialize a Page and its root Frame.
pub fn identityProfile(self: *const Page) *const FingerprintProfile.IdentityProfile {
    return self.session.browser.app.config.profile.identityPtr();
}

pub fn loadedProfile(self: *const Page) *const ProfileStore.LoadedProfile {
    return &self.session.browser.app.config.profile;
}

pub fn navigatorState(self: *const Page) NavigatorState {
    return .{
        .profile = self.identityProfile(),
        .emulation = self.session.emulation,
    };
}

pub fn init(self: *Page, session: *Session, frame_id: u32) !void {
    const frame_arena = try session.arena_pool.acquire(.large, "Page.frame_arena");
    errdefer session.arena_pool.release(frame_arena);

    const identity_arena = try session.arena_pool.acquire(.medium, "Page.identity_arena");
    errdefer session.arena_pool.release(identity_arena);

    self.* = .{
        .session = session,
        .frame = undefined,
        .frame_arena = frame_arena,
        .identity_arena = identity_arena,
        .factory = Factory.init(frame_arena),
    };
    self.queued_navigation = &self.queued_navigation_1;

    try Frame.init(&self.frame, frame_id, self, null);
}

pub fn queueIdentityRemoval(self: *Page, resolved_ptr_id: usize) void {
    self.pending_identity_removals.append(self.identity_arena, resolved_ptr_id) catch {};
}

pub fn flushPendingIdentityRemovals(self: *Page) void {
    if (self.pending_identity_removals.items.len == 0) return;
    for (self.pending_identity_removals.items) |ptr_id| {
        // Global was already reset in the V8 weak callback; drop the stale entry.
        _ = self.identity.identity_map.remove(ptr_id);
    }
    self.pending_identity_removals.clearRetainingCapacity();
}

/// Tear down a secondary identity map (e.g. a dedicated worker realm). Globals
/// may still be live in V8 when the worker context is destroyed; mark finalizer
/// nodes done and drop the map. Retired nodes must also be unlinked before
/// destroyContext: their weak callbacks own and free the nodes once `done` is
/// set, so leaving one in the FinalizerCallback chain creates a dangling link.
pub fn shutdownIdentity(self: *Page, identity: *js.Identity) void {
    var fc_it = self.finalizer_callbacks.valueIterator();
    while (fc_it.next()) |fc_ptr| {
        retireFinalizerIdentityNodes(fc_ptr.*, identity);
    }
    identity.identity_map = .{};
}

fn retireFinalizerIdentityNodes(fc: *Session.FinalizerCallback, identity: *js.Identity) void {
    var current = fc.identities;
    var kept_head: ?*Session.FinalizerCallback.Identity = null;
    var kept_tail: ?*Session.FinalizerCallback.Identity = null;
    var kept_count: u8 = 0;

    // Detach the published chain first. A weak callback may run as soon as a
    // node is marked done and is then allowed to destroy that session-owned
    // node without leaving a stale pointer reachable from `fc`.
    fc.identities = null;
    fc.identity_count = 0;
    while (current) |node| {
        const next = node.next;
        node.next = null;
        if (node.identity == identity) {
            _ = identity.identity_map.remove(node.resolved_ptr_id);
            node.done = true;
        } else {
            if (kept_tail) |tail| {
                tail.next = node;
            } else {
                kept_head = node;
            }
            kept_tail = node;
            kept_count +|= 1;
        }
        current = next;
    }
    fc.identities = kept_head;
    fc.identity_count = kept_count;
}

// Tear down the Page and its root Frame. Equivalent to the old
// Session.removePage + Session.resetFrameResources.
pub fn deinit(self: *Page) void {
    self.cleanupClosedPopups();

    for (self.popups.items) |popup| {
        popup.deinit();
    }
    self.popups = .empty;

    const session = self.session;
    defer session.browser.env.memoryPressureNotification(.moderate);

    // Invalidate outstanding V8 weak callbacks BEFORE destroyContext pumps them
    // during frame.deinit. Otherwise weak finalizers can releaseRef NodeList /
    // iterators while force_deinit still owns the same instances.
    //
    // Also clear each FC's identity linked list after marking done. Weak
    // callbacks with `done == true` destroy Identity nodes without unlinking
    // (Local.zig). If those fire (background GC / child-context teardown)
    // before MutationObserver release walks the list, detachFinalizer would
    // UAF (SIGSEGV 0xaaa… on nytimes.com SPA navigations).
    {
        var fc_it = self.finalizer_callbacks.valueIterator();
        while (fc_it.next()) |fc_ptr| {
            var id = fc_ptr.*.identities;
            fc_ptr.*.identities = null;
            fc_ptr.*.identity_count = 0;
            while (id) |identity| {
                const next = identity.next;
                // The weak callback owns the copied Global once this node is
                // marked done. Remove the map entry without Reset while both
                // the Identity and its allocator are still alive. A callback
                // arriving after Page.deinit can then finish without touching
                // this retired Page or its released identity_arena.
                _ = identity.identity.identity_map.remove(identity.resolved_ptr_id);
                identity.next = null;
                identity.done = true;
                id = next;
            }
        }
    }

    self.frame.deinit();

    // Scheduler cancellation during frame teardown drops deferred callbacks.
    // Release their native owners explicitly before page arenas disappear.
    self.drainTerminalOwners();

    self.flushPendingIdentityRemovals();
    self.identity.deinit();
    self.identity = .{};
    self.pending_identity_removals = .empty;

    // Force cleanup all remaining finalized objects. Remove each callback from
    // the map before releasing it, because release_ref can re-enter
    // detachFinalizer through RC.release.
    while (self.finalizer_callbacks.count() > 0) {
        var it = self.finalizer_callbacks.iterator();
        const entry = it.next() orelse break;
        const finalizer_ptr_id = entry.key_ptr.*;
        const fc = entry.value_ptr.*;
        _ = self.finalizer_callbacks.remove(finalizer_ptr_id);
        fc.deinit(self);
    }

    {
        for (self.globals.items) |*global| {
            v8.v8__Global__Reset(global);
        }
        self.globals = .empty;
    }

    {
        var it = self.temps.valueIterator();
        while (it.next()) |global| {
            v8.v8__Global__Reset(global);
        }
        self.temps = .empty;
    }

    if (comptime IS_DEBUG) {
        std.debug.assert(self.origins.count() == 0);
    }
    // Defensive cleanup in case origins leaked.
    {
        const app = session.browser.app;
        var it = self.origins.valueIterator();
        while (it.next()) |value| {
            value.*.deinit(app);
        }
        self.origins = .empty;
    }

    session.arena_pool.release(self.identity_arena);
    session.arena_pool.release(self.frame_arena);
}

fn drainTerminalOwners(self: *Page) void {
    while (self.terminal_owners.count() > 0) {
        var it = self.terminal_owners.iterator();
        const entry = it.next() orelse break;
        const key = entry.key_ptr.*;
        const owner = entry.value_ptr.*;
        _ = self.terminal_owners.remove(key);
        owner.release(owner.ctx, self);
    }
}

pub fn cleanupClosedPopups(self: *Page) void {
    for (self.queued_close.items) |popup| {
        popup.deinit();
    }
    self.queued_close = .empty;
}

pub fn prepareForBrowserShutdown(self: *Page) void {
    self.frame.prepareForBrowserShutdown();
    for (self.popups.items) |popup| popup.prepareForBrowserShutdown();
    for (self.queued_close.items) |popup| popup.prepareForBrowserShutdown();
}

pub fn registerTerminalOwner(
    self: *Page,
    ctx: *anyopaque,
    release: *const fn (*anyopaque, *Page) void,
) !void {
    try self.terminal_owners.put(self.identity_arena, @intFromPtr(ctx), .{
        .ctx = ctx,
        .release = release,
    });
}

pub fn unregisterTerminalOwner(self: *Page, ctx: *anyopaque) void {
    _ = self.terminal_owners.remove(@intFromPtr(ctx));
}

test "Page terminal owners release exactly once" {
    const State = struct {
        releases: usize = 0,

        fn release(ctx: *anyopaque, _: *Page) void {
            const state: *@This() = @ptrCast(@alignCast(ctx));
            state.releases += 1;
        }
    };

    var page: Page = undefined;
    page.identity_arena = std.testing.allocator;
    page.terminal_owners = .empty;
    defer page.terminal_owners.deinit(std.testing.allocator);

    var first: State = .{};
    var second: State = .{};
    try page.registerTerminalOwner(&first, State.release);
    try page.registerTerminalOwner(&second, State.release);

    page.drainTerminalOwners();
    page.drainTerminalOwners();

    try std.testing.expectEqual(@as(usize, 1), first.releases);
    try std.testing.expectEqual(@as(usize, 1), second.releases);
    try std.testing.expectEqual(@as(usize, 0), page.terminal_owners.count());
}

pub fn getArena(self: *Page, size_or_bucket: anytype, debug: []const u8) !Allocator {
    return self.session.getArena(size_or_bucket, debug);
}

pub fn releaseArena(self: *Page, allocator: Allocator) void {
    return self.session.releaseArena(allocator);
}

// Detach (and forget) any FinalizerCallback registered for the Zig
// instance whose finalizer pointer is `finalizer_ptr_id`. This is
// invoked from a Zig-side `deinit` once the underlying refcount hits
// zero. Without this, the FC stays in `finalizer_callbacks` and any
// later V8 weak-callback for an outstanding identity would attempt to
// `release_ref` against memory that has already been freed (or, worse,
// recycled by the arena pool for an unrelated instance), producing the
// "integer overflow" / "ArenaPool counter out of sync" crash chain
// observed on JS-heavy SPAs (TikTok Live).
pub fn detachFinalizer(self: *Page, finalizer_ptr_id: usize) void {
    const fc_entry = self.finalizer_callbacks.fetchRemove(finalizer_ptr_id) orelse return;
    const fc = fc_entry.value;
    // Mark every outstanding identity as `done` so any subsequent V8
    // weak-callback for those identities short-circuits before deref'ing
    // the (potentially recycled) FC or its target object.
    // Detach list first so re-entrant paths and concurrent weak callbacks
    // cannot observe a half-walked chain.
    var id = fc.identities;
    fc.identities = null;
    fc.identity_count = 0;
    while (id) |identity| {
        const next = identity.next;
        _ = identity.identity.identity_map.remove(identity.resolved_ptr_id);
        identity.next = null;
        identity.done = true;
        id = next;
    }
    self.releaseArena(fc.arena);
}

test "Page: shutting down one realm unlinks only its finalizer identity nodes" {
    var retired_identity: js.Identity = .{};
    var live_identity: js.Identity = .{};
    const session: *Session = @ptrFromInt(@alignOf(Session));
    const page: *Page = @ptrFromInt(@alignOf(Page));

    var retired_first: Session.FinalizerCallback.Identity = .{
        .session = session,
        .page = page,
        .identity = &retired_identity,
        .finalizer_ptr_id = 1,
        .resolved_ptr_id = 11,
    };
    var live: Session.FinalizerCallback.Identity = .{
        .session = session,
        .page = page,
        .identity = &live_identity,
        .finalizer_ptr_id = 1,
        // Deliberately collide with the retired realm's pointer id. Arena
        // reuse must not retire a live wrapper owned by another Identity.
        .resolved_ptr_id = 11,
    };
    var retired_last: Session.FinalizerCallback.Identity = .{
        .session = session,
        .page = page,
        .identity = &retired_identity,
        .finalizer_ptr_id = 1,
        .resolved_ptr_id = 13,
    };
    retired_first.next = &live;
    live.next = &retired_last;

    var fc: Session.FinalizerCallback = undefined;
    fc.identities = &retired_first;
    fc.identity_count = 3;

    retireFinalizerIdentityNodes(&fc, &retired_identity);

    try std.testing.expect(retired_first.done);
    try std.testing.expect(retired_last.done);
    try std.testing.expect(!live.done);
    try std.testing.expectEqual(@as(?*Session.FinalizerCallback.Identity, &live), fc.identities);
    try std.testing.expectEqual(@as(?*Session.FinalizerCallback.Identity, null), live.next);
    try std.testing.expectEqual(@as(u8, 1), fc.identity_count);
}

pub fn getOrCreateOrigin(self: *Page, key_: ?[]const u8) !*js.Origin {
    const session = self.session;
    const key = key_ orelse {
        var opaque_origin: [36]u8 = undefined;
        @import("../../support/id.zig").uuidv4(&opaque_origin);
        // Origin.init will dupe opaque_origin. It's fine that this doesn't
        // get added to self.origins. In fact, it further isolates it. When the
        // context is freed, it'll call Page.releaseOrigin which will free it.
        return js.Origin.init(session.browser.app, session.browser.env.isolate, &opaque_origin);
    };

    const gop = try self.origins.getOrPut(session.arena, key);
    if (gop.found_existing) {
        const origin = gop.value_ptr.*;
        origin.rc += 1;
        return origin;
    }

    errdefer _ = self.origins.remove(key);

    const origin = try js.Origin.init(session.browser.app, session.browser.env.isolate, key);
    gop.key_ptr.* = origin.key;
    gop.value_ptr.* = origin;
    return origin;
}

pub fn releaseOrigin(self: *Page, origin: *js.Origin) void {
    const rc = origin.rc;
    if (rc == 1) {
        _ = self.origins.remove(origin.key);
        origin.deinit(self.session.browser.app);
    } else {
        origin.rc = rc - 1;
    }
}

pub fn scheduleNavigation(self: *Page, frame: *Frame) !void {
    const list = self.queued_navigation;

    // Check if frame is already queued
    for (list.items) |existing| {
        if (existing == frame) {
            // Already queued
            return;
        }
    }

    return list.append(self.session.arena, frame);
}

pub fn findFrameByFrameId(self: *Page, frame_id: u32) ?*Frame {
    return findFrameBy(&self.frame, "_frame_id", frame_id);
}

/// Map a dedicated-worker's synthetic frame_id to its parent frame for CDP/network attribution.
pub fn findFrameForWorkerFrameId(self: *Page, frame_id: u32) ?*Frame {
    return findFrameForWorkerFrameIdInner(&self.frame, frame_id);
}

fn findFrameForWorkerFrameIdInner(frame: *Frame, frame_id: u32) ?*Frame {
    for (frame.workers.items) |worker| {
        if (worker._frame_id == frame_id) return frame;
    }
    for (frame.child_frames.items) |child| {
        if (findFrameForWorkerFrameIdInner(child, frame_id)) |found| return found;
    }
    return null;
}

// Returns the popup Frame registered under `name`, or null.
pub fn findPopupByName(self: *Page, name: []const u8) ?*Frame {
    for (self.popups.items) |popup| {
        if (std.mem.eql(u8, popup.window._name, name)) {
            return popup;
        }
    }
    return null;
}

pub fn findFrameByLoaderId(self: *Page, loader_id: u32) ?*Frame {
    return findFrameBy(&self.frame, "_loader_id", loader_id);
}

fn findFrameBy(frame: *Frame, comptime field: []const u8, id: u32) ?*Frame {
    if (@field(frame, field) == id) return frame;
    for (frame.child_frames.items) |f| {
        if (findFrameBy(f, field, id)) |found| {
            return found;
        }
    }
    return null;
}

pub fn broadcastChannelRegistryKey(self: *Page, origin_key: []const u8, name: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(self.frame_arena, "{s}\x1f{s}", .{ origin_key, name });
}

pub fn registerBroadcastChannel(self: *Page, channel: *BroadcastChannel) !void {
    const gop = try self.broadcast_channels.getOrPut(self.frame_arena, channel.registryKey());
    if (!gop.found_existing) {
        gop.value_ptr.* = .empty;
    }
    try gop.value_ptr.append(self.frame_arena, channel);
}

pub fn unregisterBroadcastChannel(self: *Page, channel: *BroadcastChannel) void {
    const list = self.broadcast_channels.getPtr(channel.registryKey()) orelse return;
    for (list.items, 0..) |existing, i| {
        if (existing == channel) {
            _ = list.swapRemove(i);
            break;
        }
    }
    if (list.items.len == 0) {
        _ = self.broadcast_channels.remove(channel.registryKey());
    }
}

/// A BroadcastChannel is entangled with its creation realm. Closing every
/// channel before that realm's V8 context is reset prevents later senders from
/// cloning into a stale global. Scheduler reset owns cancellation of already
/// queued deliveries through their task finalizers.
pub fn unregisterBroadcastChannelsForContext(self: *Page, context: *js.Context) void {
    var it = self.broadcast_channels.iterator();
    while (it.next()) |entry| {
        const list = entry.value_ptr;
        var i = list.items.len;
        while (i > 0) {
            i -= 1;
            const channel = list.items[i];
            if (channel.detachForContextTeardown(context)) {
                _ = list.swapRemove(i);
            }
        }
    }
}
