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
const assert = @import("../../support/assert.zig").assert;

const App = @import("../../runtime/App.zig");
const Notification = @import("../../runtime/Notification.zig");
const js = @import("../../core/js/js.zig");
const Browser = @import("../../core/browser/Browser.zig");
const Session = @import("../../core/browser/Session.zig");
const Frame = @import("../../core/browser/Frame.zig");
const Mime = @import("../../core/browser/Mime.zig");
const Element = @import("../../core/dom/Element.zig");
const Label = @import("../../core/webapi/element/html/Label.zig");
const Request = @import("../../core/browser/HttpClient.zig").Request;
const CDPClient = @import("../../core/browser/HttpClient.zig").CDPClient;
const WsConnection = @import("../../runtime/network/WsConnection.zig");

const Incrementing = @import("id.zig").Incrementing;
const InterceptState = @import("domains/fetch.zig").InterceptState;

const log = @import("../../support/log.zig");
const json = std.json;
const posix = std.posix;
const Allocator = std.mem.Allocator;

pub const URL_BASE = "chrome://newtab/";

const IS_DEBUG = @import("builtin").mode == .Debug;

const TargetIdGen = Incrementing(u32, "TID");
const SessionIdGen = Incrementing(u32, "SID");
const BrowserContextIdGen = Incrementing(u32, "BID");

// Generic so that we can inject mocks into it.
const CDP = @This();

allocator: Allocator,
app: *App,

ws: WsConnection,

// The active browser
browser: Browser,

// when true, any target creation must be attached.
target_auto_attach: bool = false,

target_id_gen: TargetIdGen = .{},
session_id_gen: SessionIdGen = .{},
browser_context_id_gen: BrowserContextIdGen = .{},

browser_context: ?BrowserContext,

// A CDP connection owns one V8 isolate/browser worker. Keep a bounded
// high-water budget for that worker and reclaim its heap between browser
// contexts; this is the safe point where no client-visible Page is tearing down.
worker_pages: u32 = 0,
worker_rss_baseline_bytes: u64 = 0,
worker_recycle_requested: bool = false,
deferred_browser_context_dispose: bool = false,

// Re-used arena for processing a message. We're assuming that we're getting
// 1 message at a time.
message_arena: std.heap.ArenaAllocator,

// Used for processing notifications within a browser context.
notification_arena: std.heap.ArenaAllocator,

// Valid for 1 frame navigation (what CDP calls a "renderer")
frame_arena: std.heap.ArenaAllocator,

// Valid for the entire lifetime of the BrowserContext. Should minimize
// (or altogether eliminate) our use of this.
browser_context_arena: std.heap.ArenaAllocator,

pub fn init(
    self: *CDP,
    app: *App,
    socket: posix.socket_t,
    json_version_response: []const u8,
) !void {
    const allocator = app.allocator;

    self.* = .{
        .app = app,
        .ws = undefined,
        .browser = undefined,
        .allocator = allocator,
        .browser_context = null,
        .worker_rss_baseline_bytes = processRssHighWaterBytes(),
        .frame_arena = std.heap.ArenaAllocator.init(allocator),
        .message_arena = std.heap.ArenaAllocator.init(allocator),
        .notification_arena = std.heap.ArenaAllocator.init(allocator),
        .browser_context_arena = std.heap.ArenaAllocator.init(allocator),
    };

    try self.ws.init(socket, self.app.allocator, json_version_response);
    errdefer self.ws.deinit();

    try self.browser.init(app, .{ .env = .{ .with_inspector = true } }, .{
        .ctx = self,
        .socket = socket,
        .blocking_read_start = CDP.blockingReadStart,
        .blocking_read = CDP.blockingRead,
        .blocking_read_end = CDP.blockingReadStop,
    });
}

fn persistSessionState(session: *Session, config: *const @import("../../runtime/Config.zig")) void {
    @import("../../runtime/profile_session.zig").persistCookies(session, config);
}

pub fn deinit(self: *CDP) void {
    // The client commonly closes its websocket immediately after
    // Target.disposeBrowserContext. Give the deferred safe-point cleanup one
    // last chance before tearing down the connection-owned Browser.
    self.finishDeferredBrowserContextDispose();
    if (self.browser_context) |*bc| {
        persistSessionState(bc.session, self.app.config);
        bc.deinit();
    }
    self.browser.deinit();
    self.frame_arena.deinit();
    self.message_arena.deinit();
    self.notification_arena.deinit();
    self.browser_context_arena.deinit();
    self.ws.deinit();
}

pub fn blockingReadStart(ctx: *anyopaque) bool {
    const self: *CDP = @ptrCast(@alignCast(ctx));
    self.ws.setBlocking(true) catch |err| {
        log.warn(.app, "CDP blockingReadStart", .{ .err = err });
        return false;
    };
    return true;
}

pub fn blockingRead(ctx: *anyopaque) bool {
    const self: *CDP = @ptrCast(@alignCast(ctx));
    return self.readSocket();
}

pub fn blockingReadStop(ctx: *anyopaque) bool {
    const self: *CDP = @ptrCast(@alignCast(ctx));
    self.ws.setBlocking(false) catch |err| {
        log.warn(.app, "CDP blockingReadStop", .{ .err = err });
        return false;
    };
    return true;
}

pub fn readSocket(self: *CDP) bool {
    const n = self.ws.read() catch |err| {
        log.warn(.app, "CDP read", .{ .err = err });
        // Peer is gone: SHUT_RDWR unblocks a worker stuck in send().
        self.ws.shutdownPeer();
        return false;
    };

    if (n == 0) {
        log.info(.app, "CDP disconnect", .{});
        self.ws.shutdownPeer();
        return false;
    }

    return self.ws.processMessages(self) catch false;
}

pub fn sendJSON(self: *CDP, message: anytype) !void {
    if (log.cdp_trace_enabled) {
        var buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var aw = std.Io.Writer.Allocating.init(fba.allocator());
        std.json.Stringify.value(message, .{ .emit_null_optional_fields = false }, &aw.writer) catch {};
        log.debug(.cdp, "cdp-wire-out", .{ .payload = truncateCdpPayload(aw.written()) });
    }
    try self.ws.sendJSON(message, .{ .emit_null_optional_fields = false });
}

pub fn handleMessage(self: *CDP, msg: []const u8) bool {
    // if there's an error, it's already been logged
    self.processMessage(msg) catch return false;
    return true;
}

fn truncateCdpPayload(payload: []const u8) []const u8 {
    const max = 2048;
    if (payload.len <= max) return payload;
    return payload[0..max];
}

pub fn processMessage(self: *CDP, msg: []const u8) !void {
    if (log.cdp_trace_enabled) {
        log.debug(.cdp, "cdp-wire-in", .{ .bytes = msg.len });
    } else if (log.logRunDir() != null) {
        log.debug(.cdp, "cdp-msg", .{ .bytes = msg.len });
    }
    const arena = &self.message_arena;
    defer _ = arena.reset(.{ .retain_with_limit = 1024 * 16 });
    return self.dispatch(arena.allocator(), .{ .cdp = self }, msg);
}

// @newhttp
// A bit hacky right now. The main server loop doesn't unblock for
// scheduled task. So we run this directly in order to process any
// timeouts (or http events) which are ready to be processed.
pub fn pageWait(self: *CDP, ms: u32) !Session.Runner.CDPWaitResult {
    const session = &(self.browser.session orelse return error.NoPage);
    var runner = try session.runner(.{});
    return runner.waitCDP(.{ .ms = ms });
}

pub fn tick(self: *CDP) !bool {
    self.browser.tick_mutex.lock();
    defer self.browser.tick_mutex.unlock();

    // Drain any pending root navigation whose commit was deferred because a
    // previous tick landed inside reentrant HttpClient.perform with JS on the
    // stack (see Session._deferred_commit_pending). By the top of a fresh
    // tick all script-eval frames have unwound, so this is a safe point.
    if (self.browser.session) |*session| {
        session.drainDeferredCommit();
    }
    self.finishDeferredBrowserContextDispose();

    // Liveness is enforced by TCP keepalive (+ Linux TCP_USER_TIMEOUT)
    // configured in Network.acceptConnections; the wakeup lets V8 run or terminate.
    const wait_ms: u32 = 1000; // 1s

    const result = self.pageWait(wait_ms) catch |wait_err| switch (wait_err) {
        error.NoPage => {
            const status = self.browser.http_client.tick(wait_ms) catch |err| {
                log.err(.app, "http tick", .{ .err = err });
                return false;
            };
            return status != .cdp_socket or self.readSocket();
        },
        else => return wait_err,
    };

    if (result == .cdp_socket) {
        return self.readSocket();
    }

    return true;
}

// Called from above, in processMessage which handles client messages
// but can also be called internally. For example, Target.sendMessageToTarget
// calls back into dispatch to capture the response.
pub fn dispatch(self: *CDP, arena: Allocator, sender: Command.Sender, str: []const u8) !void {
    const input = json.parseFromSliceLeaky(InputMessage, arena, str, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidJSON;

    var command = Command{
        .input = .{
            .json = str,
            .id = input.id,
            .action = "",
            .params = input.params,
            .session_id = input.sessionId,
        },
        .cdp = self,
        .arena = arena,
        .sender = sender,
        .browser_context = if (self.browser_context) |*bc| bc else null,
    };

    // See dispatchStartupCommand for more info on this.
    var is_startup = false;
    if (input.sessionId) |input_session_id| {
        if (std.mem.eql(u8, input_session_id, "STARTUP")) {
            is_startup = true;
        } else if (self.isValidSessionId(input_session_id) == false) {
            return command.sendError(-32001, "Unknown sessionId", .{});
        }
    }

    if (is_startup) {
        dispatchStartupCommand(&command, input.method) catch |err| {
            command.sendError(-31999, @errorName(err), .{}) catch return err;
        };
    } else {
        if (command.browser_context) |bc| {
            bc.session.cdp_frame_override = bc.frameIdForSession(input.sessionId);
            bc.inspector_reply_session_id = input.sessionId orelse bc.session_id;
        }
        defer if (command.browser_context) |bc| {
            // disposeBrowserContext tears down the session before this defer
            // runs; skip session field cleanup when the context is gone.
            if (self.browser_context != null) {
                bc.session.cdp_frame_override = null;
                bc.inspector_reply_session_id = null;
            }
        };
        dispatchCommand(&command, input.method) catch |err| {
            command.sendError(-31998, @errorName(err), .{}) catch return err;
        };
    }
}

// A CDP session isn't 100% fully driven by the driver. There's are
// independent actions that the browser is expected to take. For example
// Puppeteer expects the browser to startup a tab and thus have existing
// targets.
// To this end, we create a [very] dummy BrowserContext, Target and
// Session. There isn't actually a BrowserContext, just a special id.
// When messages are received with the "STARTUP" sessionId, we do
// "special" handling - the bare minimum we need to do until the driver
// switches to a real BrowserContext.
// (I can imagine this logic will become driver-specific)
fn dispatchStartupCommand(command: *Command, method: []const u8) !void {
    // Stagehand parses the response and error if we don't return a
    // correct one for Page.getFrameTree on startup call.
    if (std.mem.eql(u8, method, "Page.getFrameTree")) {
        // The Page.getFrameTree handles startup response gracefully.
        return dispatchCommand(command, method);
    }

    return command.sendResult(null, .{});
}

fn dispatchCommand(command: *Command, method: []const u8) !void {
    const domain = blk: {
        const i = std.mem.indexOfScalarPos(u8, method, 0, '.') orelse {
            return error.InvalidMethod;
        };
        command.input.action = method[i + 1 ..];
        break :blk method[0..i];
    };

    switch (domain.len) {
        3 => switch (@as(u24, @bitCast(domain[0..3].*))) {
            asUint(u24, "DOM") => return @import("domains/dom.zig").processMessage(command),
            asUint(u24, "Log") => return @import("domains/log.zig").processMessage(command),
            asUint(u24, "CSS") => return @import("domains/css.zig").processMessage(command),
            else => {},
        },
        4 => switch (@as(u32, @bitCast(domain[0..4].*))) {
            asUint(u32, "Page") => return @import("domains/page.zig").processMessage(command),
            asUint(u32, "Koko") => return @import("domains/koko.zig").processMessage(command),
            else => {},
        },
        5 => switch (@as(u40, @bitCast(domain[0..5].*))) {
            asUint(u40, "Fetch") => return @import("domains/fetch.zig").processMessage(command),
            asUint(u40, "Input") => return @import("domains/input.zig").processMessage(command),
            else => {},
        },
        6 => switch (@as(u48, @bitCast(domain[0..6].*))) {
            asUint(u48, "Target") => return @import("domains/target.zig").processMessage(command),
            asUint(u48, "Audits") => return @import("domains/audits.zig").processMessage(command),
            else => {},
        },
        7 => switch (@as(u56, @bitCast(domain[0..7].*))) {
            asUint(u56, "Browser") => return @import("domains/browser.zig").processMessage(command),
            asUint(u56, "Runtime") => return @import("domains/runtime.zig").processMessage(command),
            asUint(u56, "Network") => return @import("domains/network.zig").processMessage(command),
            asUint(u56, "Storage") => return @import("domains/storage.zig").processMessage(command),
            else => {},
        },
        8 => switch (@as(u64, @bitCast(domain[0..8].*))) {
            asUint(u64, "Security") => return @import("domains/security.zig").processMessage(command),
            else => {},
        },
        9 => switch (@as(u72, @bitCast(domain[0..9].*))) {
            asUint(u72, "Emulation") => return @import("domains/emulation.zig").processMessage(command),
            asUint(u72, "Inspector") => return @import("domains/inspector.zig").processMessage(command),
            else => {},
        },
        11 => switch (@as(u88, @bitCast(domain[0..11].*))) {
            asUint(u88, "Performance") => return @import("domains/performance.zig").processMessage(command),
            else => {},
        },
        13 => switch (@as(u104, @bitCast(domain[0..13].*))) {
            asUint(u104, "Accessibility") => return @import("domains/accessibility.zig").processMessage(command),
            else => {},
        },

        else => {},
    }

    return error.UnknownDomain;
}

fn isValidSessionId(self: *const CDP, input_session_id: []const u8) bool {
    const browser_context = &(self.browser_context orelse return false);
    if (browser_context.frame_sessions.get(input_session_id)) |_| return true;
    const session_id = browser_context.session_id orelse return false;
    return std.mem.eql(u8, session_id, input_session_id);
}

pub fn createBrowserContext(self: *CDP) ![]const u8 {
    self.finishDeferredBrowserContextDispose();
    if (self.browser_context != null) {
        return error.AlreadyExists;
    }

    // A disposed context is a safe boundary for reclaiming the worker heap.
    // Keep the websocket and V8 isolate alive; real sites can still have
    // callbacks from detached workers/blob URLs during isolate teardown.
    if (self.worker_recycle_requested or self.workerRecycleNeeded()) {
        try self.recycleWorker();
    }

    const id = self.browser_context_id_gen.next();

    self.browser_context = @as(BrowserContext, undefined);
    const browser_context = &self.browser_context.?;

    try BrowserContext.init(browser_context, id, self);
    self.worker_pages +|= 1;
    self.worker_recycle_requested = self.workerRecycleNeeded();
    return id;
}

pub fn disposeBrowserContext(self: *CDP, browser_context_id: []const u8) bool {
    const bc = &(self.browser_context orelse return false);
    if (std.mem.eql(u8, bc.id, browser_context_id) == false) {
        return false;
    }
    // Reentrant teardown from a CDP message drained inside HttpClient.syncRequest.
    // Tearing down the browser context here would free Session/Page state
    // that the unwinding script-eval frame above us is about to dereference
    // (see Session.removePage's matching guard). Defer cleanup to the next
    // safe CDP tick, by which time eval has unwound, while acknowledging the
    // dispose request immediately.
    // Always defer the actual free until the command dispatch has unwound.
    // Target.closeTarget may have just dispatched frame_remove callbacks, and
    // freeing the BrowserContext from the dispose command itself can still
    // race those callbacks even when no script-eval flag is set.
    self.deferred_browser_context_dispose = true;
    return true;
}

fn finishDeferredBrowserContextDispose(self: *CDP) void {
    if (!self.deferred_browser_context_dispose) return;
    const bc = self.browser_context orelse {
        self.deferred_browser_context_dispose = false;
        return;
    };
    if (bc.session.activeIsEvaluating() or !bc.session.canDisposeContext()) return;
    self.finishBrowserContextDispose();
}

fn finishBrowserContextDispose(self: *CDP) void {
    const bc = &(self.browser_context orelse {
        self.deferred_browser_context_dispose = false;
        return;
    });
    // Drain pending tasks while contexts are still registered and valid.
    self.browser.env.pumpMessageLoop();
    self.browser.runMicrotasks();

    persistSessionState(bc.session, self.app.config);
    bc.deinit();
    self.browser_context = null;
    // BrowserContext teardown uses browser_context_arena allocations (id strings,
    // session_id, captured-response metadata). Reset so createBrowserContext can
    // run again on this CDP connection without leaving the server wedged.
    _ = self.browser_context_arena.reset(.retain_capacity);
    // Response bodies are captured in frame_arena while Network is enabled so
    // Network.getResponseBody can serve them. Do not retain their peak capacity
    // across browser contexts: a large site would otherwise permanently pin
    // every body buffer in the long-lived CDP connection.
    _ = self.frame_arena.reset(.{ .retain_with_limit = 1024 * 512 });
    self.worker_recycle_requested = self.workerRecycleNeeded();
    self.deferred_browser_context_dispose = false;
}

fn workerRecycleNeeded(self: *const CDP) bool {
    const max_pages = self.app.config.workerMaxPages();
    if (max_pages > 0 and self.worker_pages >= max_pages) return true;

    const max_rss_growth = self.app.config.workerMaxRssBytes();
    if (max_rss_growth == 0) return false;

    const rss = processRssHighWaterBytes();
    return rss >= self.worker_rss_baseline_bytes and
        rss - self.worker_rss_baseline_bytes >= max_rss_growth;
}

fn recycleWorker(self: *CDP) !void {
    if (self.browser_context != null) return error.BrowserContextActive;

    log.info(.app, "recycling CDP worker heap", .{
        .pages = self.worker_pages,
        .rss_high_water = processRssHighWaterBytes(),
    });

    // BrowserContext.deinit has already closed the Session and the deferred
    // disposal predicate guarantees no page/transport callback still aliases
    // its state. Now it is safe to force V8 to reclaim detached contexts and
    // backing stores without tearing down the isolate itself.
    self.browser.env.memoryPressureNotification(.critical);
    self.browser.env.lowMemoryNotification();

    _ = self.frame_arena.reset(.{ .retain_with_limit = 1024 * 512 });
    _ = self.notification_arena.reset(.{ .retain_with_limit = 1024 * 64 });
    _ = self.browser_context_arena.reset(.{ .retain_with_limit = 1024 * 64 });
    self.worker_pages = 0;
    self.worker_rss_baseline_bytes = processRssHighWaterBytes();
    self.worker_recycle_requested = false;
}

fn processRssHighWaterBytes() u64 {
    const usage = std.posix.getrusage(0);
    const raw: u64 = if (usage.maxrss <= 0) 0 else @intCast(usage.maxrss);
    return switch (builtin.os.tag) {
        .macos, .ios, .watchos, .tvos => raw,
        else => raw * 1024,
    };
}

const SendEventOpts = struct {
    session_id: ?[]const u8 = null,
};
pub fn sendEvent(self: *CDP, method: []const u8, p: anytype, opts: SendEventOpts) !void {
    return self.sendJSON(.{
        .method = method,
        .params = if (comptime @typeInfo(@TypeOf(p)) == .null) struct {}{} else p,
        .sessionId = opts.session_id,
    });
}

pub const BrowserContext = struct {
    const Node = @import("Node.zig");
    const AXNode = @import("AXNode.zig");

    const CapturedResponse = struct {
        must_encode: bool,
        data: std.ArrayList(u8),
    };

    // Key for `captured_responses`. Documents are keyed by `loader_id`,
    // everything else by `request_id` — the two id-spaces are independent
    // counters and overlap numerically (loader 1 / request 1, loader 2 /
    // request 2, ...), so the map key has to carry the namespace or
    // entries collide. The wire-format prefix (`LID-` / `REQ-`) provides
    // the same disambiguation on lookup; see `idFromRequestId` in
    // domains/network.zig.
    pub const CapturedResponseKey = struct {
        kind: enum { request, loader },
        id: u32,
    };

    id: []const u8,
    cdp: *CDP,

    // Represents the browser session. There is no equivalent in CDP. For
    // all intents and purpose, from CDP's point of view our Browser and
    // our Session more or less maps to a BrowserContext. THIS HAS ZERO
    // RELATION TO SESSION_ID
    session: *Session,

    // Tied to the lifetime of the BrowserContext
    arena: Allocator,

    // Tied to the lifetime of 1 page rendered in the BrowserContext.
    frame_arena: Allocator,

    // From the parent's notification_arena.allocator(). Most of the CDP
    // code paths deal with a cmd which has its own arena (from the
    // message_arena). But notifications happen outside of the typical CDP
    // request->response, and thus don't have a cmd and don't have an arena.
    notification_arena: Allocator,

    // Maps to our Page. (There are other types of targets, but we only
    // deal with "pages" for now). Since we only allow 1 open page at a
    // time, we only have 1 target_id.
    target_id: ?[14]u8,

    // The CDP session_id. After the target/page is created, the client
    // "attaches" to it (either explicitly or automatically). We return a
    // "sessionId" which identifies this link. `sessionId` is the how
    // the CDP client informs us what it's trying to manipulate. Because we
    // only support 1 BrowserContext at a time, and 1 page at a time, this
    // is all pretty straightforward, but it still needs to be enforced, i.e.
    // if we get a request with a sessionId that doesn't match the current one
    // we should reject it.
    session_id: ?[]const u8,

    security_origin: []const u8,
    page_life_cycle_events: bool,
    secure_context_type: []const u8,
    node_registry: Node.Registry,
    node_search_list: Node.Search.List,

    inspector_session: *js.Inspector.Session,
    isolated_worlds: std.ArrayList(*IsolatedWorld),

    // Scripts registered via Page.addScriptToEvaluateOnNewDocument.
    // Evaluated in each new document after navigation completes.
    scripts_on_new_document: std.ArrayList(ScriptOnNewDocument) = .empty,
    // Last main-world V8 context observed for each frame. Loader ids can change
    // during same-realm SPA/history transitions, but new-document hooks belong
    // to a JavaScript realm and must execute exactly once in that realm.
    new_document_script_contexts: std.AutoHashMapUnmanaged(u32, usize) = .empty,
    next_script_id: u32 = 1,

    http_proxy_changed: bool = false,
    user_agent_changed: bool = false,
    network_enabled: bool = false,

    // Extra headers to add to all requests.
    extra_headers: std.ArrayList([*c]const u8) = .empty,

    intercept_state: InterceptState,

    // When network is enabled, we'll capture the transfer.id -> body
    // This is awfully memory intensive, but our underlying http client and
    // its users (script manager and frame) correctly do not hold the body
    // memory longer than they have to. In fact, the main request is only
    // ever streamed. So if CDP is the only thing that needs bodies in
    // memory for an arbitrary amount of time, then that's where we're going
    // to store the,
    captured_responses: std.AutoHashMapUnmanaged(CapturedResponseKey, CapturedResponse),

    notification: *Notification,

    // Pre-armed response for the next JS dialog (alert/confirm/prompt).
    // Set by Page.handleJavaScriptDialog; consumed (and cleared) when the
    // next javascript_dialog_opening notification is dispatched. Strings
    // are duplicated into self.arena so they outlive the CDP command's
    // own message arena.
    pending_dialog_response: ?Notification.DialogResponse = null,

    /// CDP Emulation domain overrides (viewport, timezone, permissions, …).
    emulation: @import("EmulationState.zig").State = .{},

    // Iframe CDP targets: sessionId -> frame_id (child frame attach).
    frame_sessions: std.StringHashMap(u32),

    // Inspector replies echo this session (iframe attach uses a child session).
    inspector_reply_session_id: ?[]const u8 = null,

    fn init(self: *BrowserContext, id: []const u8, cdp: *CDP) !void {
        const allocator = cdp.allocator;

        // Create notification for this BrowserContext
        const notification = try Notification.init(allocator);
        errdefer notification.deinit();

        const session = try cdp.browser.newSession(notification);
        @import("../../runtime/profile_session.zig").bootstrapCookies(session, cdp.app.config);

        const browser = &cdp.browser;
        const inspector_session = browser.env.inspector.?.startSession(self);
        errdefer browser.env.inspector.?.stopSession();

        var registry = Node.Registry.init(allocator);
        errdefer registry.deinit();

        self.* = .{
            .id = id,
            .cdp = cdp,
            .target_id = null,
            .session_id = null,
            .session = session,
            .security_origin = URL_BASE,
            .secure_context_type = "Secure", // TODO = enum
            .page_life_cycle_events = false, // TODO; Target based value
            .node_registry = registry,
            .node_search_list = undefined,
            .isolated_worlds = .empty,
            .inspector_session = inspector_session,
            .frame_arena = cdp.frame_arena.allocator(),
            .arena = cdp.browser_context_arena.allocator(),
            .notification_arena = cdp.notification_arena.allocator(),
            .intercept_state = try InterceptState.init(allocator),
            .captured_responses = .empty,
            .notification = notification,
            .frame_sessions = std.StringHashMap(u32).init(allocator),
        };
        self.node_search_list = Node.Search.List.init(allocator, &self.node_registry);
        errdefer self.deinit();

        try notification.register(.frame_remove, self, onFrameRemove);
        try notification.register(.frame_created, self, onFrameCreated);
        try notification.register(.frame_navigate, self, onFrameNavigate);
        try notification.register(.frame_navigated, self, onFrameNavigated);
        try notification.register(.frame_navigate_ack, self, onFrameNavigateAck);
        try notification.register(.frame_navigation_failed, self, onFrameNavigationFailed);
        try notification.register(.frame_child_frame_created, self, onFrameChildFrameCreated);
        try notification.register(.frame_child_frame_removed, self, onFrameChildFrameRemoved);
        try notification.register(.frame_dom_content_loaded, self, onFrameDOMContentLoaded);
        try notification.register(.frame_loaded, self, onFrameLoaded);
        try notification.register(.javascript_dialog_opening, self, onJavascriptDialogOpening);

        session.emulation = &self.emulation;
    }

    pub fn deinit(self: *BrowserContext) void {
        const browser = &self.cdp.browser;

        // abort all intercepted requests before closing the session/page
        // since some of these might callback into the page/scriptmanager
        const http_client = &browser.http_client;
        for (self.intercept_state.pendingIntercepts()) |intercept| {
            defer {
                assert(
                    http_client.interception_layer.intercepted > 0,
                    "BrowserContext.deinit.intercepted",
                    .{ .value = http_client.interception_layer.intercepted },
                );
                http_client.interception_layer.intercepted -= 1;
            }
            switch (intercept) {
                .transfer => |t| {
                    t.abort(error.ClientDisconnect);
                },
                .request => |r| {
                    defer http_client.deinitRequest(r);
                    r.error_callback(r.ctx, error.ClientDisconnect);
                },
            }
        }

        // closeSession dispatches frame_remove → frameRemove, which resets
        // inspector contexts, isolated worlds, and node registries while the
        // page is still walkable. Do not resetContextGroup or unregister
        // notifications before this — that skips frameRemove and leaves stale
        // Env.context entries that segfault on the next microtask checkpoint.
        browser.closeSession();

        if (browser.env.inspector) |inspector| {
            inspector.stopSession();
        }

        for (self.isolated_worlds.items) |world| {
            world.deinit();
        }
        self.isolated_worlds.clearRetainingCapacity();

        self.node_registry.deinit();
        self.node_search_list.deinit();
        self.notification.deinit();

        if (self.http_proxy_changed) {
            // has to be called after browser.closeSession, since it won't
            // work if there are active connections.
            browser.http_client.changeProxy(null) catch |err| {
                log.warn(.http, "changeProxy", .{ .err = err });
            };
        }
        if (self.user_agent_changed) {
            browser.http_client.clearUserAgentOverride();
        }
        self.intercept_state.deinit();
        self.emulation.deinit(self.arena);
        self.frame_sessions.deinit();
        self.new_document_script_contexts.deinit(self.arena);
    }

    pub fn reset(self: *BrowserContext) void {
        self.node_registry.reset();
        self.node_search_list.reset();
    }

    pub fn frameIdForSession(self: *const BrowserContext, session_id: ?[]const u8) ?u32 {
        if (session_id) |sid| {
            if (self.frame_sessions.get(sid)) |frame_id| return frame_id;
            if (self.session_id) |main_sid| {
                if (std.mem.eql(u8, sid, main_sid)) {
                    if (self.session.currentFrame()) |f| return f._frame_id;
                }
            }
            return null;
        }
        if (self.session.currentFrame()) |f| return f._frame_id;
        return null;
    }

    pub fn registerFrameSession(self: *BrowserContext, session_id: []const u8, frame_id: u32) !void {
        const key = try self.arena.dupe(u8, session_id);
        try self.frame_sessions.put(key, frame_id);
    }

    pub fn unregisterFrameSession(self: *BrowserContext, session_id: []const u8) void {
        _ = self.frame_sessions.remove(session_id);
    }

    pub fn frameForId(self: *const BrowserContext, frame_id: u32) ?*Frame {
        return self.session.findFrameByFrameId(frame_id);
    }

    pub fn createIsolatedWorld(self: *BrowserContext, world_name: []const u8, grant_universal_access: bool) !*IsolatedWorld {
        const browser = &self.cdp.browser;
        const arena = try browser.arena_pool.acquire(.small, "IsolatedWorld");
        errdefer browser.arena_pool.release(arena);

        const call_arena = try browser.arena_pool.acquire(.tiny, "IsolatedWorld.call_arena");
        errdefer browser.arena_pool.release(call_arena);

        const world = try arena.create(IsolatedWorld);
        world.* = .{
            .arena = arena,
            .call_arena = call_arena,
            .context = null,
            .browser = browser,
            .name = try arena.dupe(u8, world_name),
            .grant_universal_access = grant_universal_access,
        };

        try self.isolated_worlds.append(self.arena, world);

        return world;
    }

    pub fn nodeWriter(self: *BrowserContext, root: *const Node, opts: Node.Writer.Opts) Node.Writer {
        return .{
            .root = root,
            .depth = opts.depth,
            .exclude_root = opts.exclude_root,
            .registry = &self.node_registry,
        };
    }

    pub fn axnodeWriter(self: *BrowserContext, temp_arena: Allocator, root: *const Node, opts: AXNode.Writer.Opts) !AXNode.Writer {
        const frame = self.session.currentFrame() orelse return error.FrameNotLoaded;
        _ = opts;
        const cache = try frame.call_arena.create(Element.VisibilityCache);
        cache.* = .empty;
        const label_index = try frame.call_arena.create(Label.LabelByForIndex);
        label_index.* = .{};
        return .{
            .frame = frame,
            .root = root,
            .registry = &self.node_registry,
            .visibility_cache = cache,
            .label_index = label_index,
            .temp_arena = temp_arena,
        };
    }

    pub fn getURL(self: *const BrowserContext) ?[:0]const u8 {
        const frame = self.session.currentFrame() orelse return null;
        const url = frame.url;
        return if (url.len == 0) null else url;
    }

    pub fn getTitle(self: *const BrowserContext) ?[]const u8 {
        const frame = self.session.currentFrame() orelse return null;
        return frame.getTitle() catch |err| {
            log.err(.cdp, "page title", .{ .err = err });
            return null;
        };
    }

    pub fn networkEnable(self: *BrowserContext) !void {
        if (self.network_enabled) return;
        try self.notification.register(.http_request_fail, self, onHttpRequestFail);
        try self.notification.register(.http_request_start, self, onHttpRequestStart);
        try self.notification.register(.http_request_done, self, onHttpRequestDone);
        try self.notification.register(.http_response_data, self, onHttpResponseData);
        try self.notification.register(.http_response_header_done, self, onHttpResponseHeadersDone);
        self.network_enabled = true;
    }

    pub fn networkDisable(self: *BrowserContext) void {
        if (!self.network_enabled) return;
        self.notification.unregister(.http_request_fail, self);
        self.notification.unregister(.http_request_start, self);
        self.notification.unregister(.http_request_done, self);
        self.notification.unregister(.http_response_data, self);
        self.notification.unregister(.http_response_header_done, self);
        self.network_enabled = false;
    }

    pub fn fetchEnable(self: *BrowserContext, authRequests: bool) !void {
        try self.notification.register(.http_request_intercept, self, onHttpRequestIntercept);
        if (authRequests) {
            try self.notification.register(.http_request_auth_required, self, onHttpRequestAuthRequired);
        }
    }

    pub fn fetchDisable(self: *BrowserContext) void {
        self.notification.unregister(.http_request_intercept, self);
        self.notification.unregister(.http_request_auth_required, self);
    }

    pub fn lifecycleEventsEnable(self: *BrowserContext) !void {
        self.page_life_cycle_events = true;
        try self.notification.register(.frame_network_idle, self, onFrameNetworkIdle);
        try self.notification.register(.frame_network_almost_idle, self, onFrameNetworkAlmostIdle);
    }

    pub fn lifecycleEventsDisable(self: *BrowserContext) void {
        self.page_life_cycle_events = false;
        self.notification.unregister(.frame_network_idle, self);
        self.notification.unregister(.frame_network_almost_idle, self);
    }

    pub fn onFrameRemove(ctx: *anyopaque, _: Notification.FrameRemove) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        @import("domains/page.zig").frameRemove(self);
    }

    pub fn onFrameCreated(ctx: *anyopaque, frame: *Frame) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        return @import("domains/page.zig").frameCreated(self, frame);
    }

    pub fn onFrameNavigate(ctx: *anyopaque, msg: *const Notification.FrameNavigate) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        return @import("domains/page.zig").frameNavigate(self, msg);
    }

    pub fn onFrameNavigated(ctx: *anyopaque, msg: *const Notification.FrameNavigated) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        defer self.resetNotificationArena();
        return @import("domains/page.zig").frameNavigated(self.notification_arena, self, msg);
    }

    pub fn onFrameNavigateAck(ctx: *anyopaque, msg: *const Notification.FrameNavigateAck) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        return @import("domains/page.zig").frameNavigateAck(self, msg);
    }

    pub fn onFrameNavigationFailed(ctx: *anyopaque, msg: *const Notification.FrameNavigationFailed) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        return @import("domains/page.zig").frameNavigationFailed(self, msg);
    }

    pub fn onFrameChildFrameCreated(ctx: *anyopaque, msg: *const Notification.FrameChildFrameCreated) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        return @import("domains/page.zig").frameChildFrameCreated(self, msg);
    }

    pub fn onFrameChildFrameRemoved(ctx: *anyopaque, msg: *const Notification.FrameChildFrameRemoved) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        return @import("domains/page.zig").frameChildFrameRemoved(self, msg);
    }

    pub fn onFrameNetworkIdle(ctx: *anyopaque, msg: *const Notification.FrameNetworkIdle) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        return @import("domains/page.zig").frameNetworkIdle(self, msg);
    }

    pub fn onFrameNetworkAlmostIdle(ctx: *anyopaque, msg: *const Notification.FrameNetworkAlmostIdle) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        return @import("domains/page.zig").frameNetworkAlmostIdle(self, msg);
    }

    pub fn onHttpRequestStart(ctx: *anyopaque, msg: *const Notification.RequestStart) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        try @import("domains/network.zig").httpRequestStart(self, msg);
    }

    pub fn onHttpRequestIntercept(ctx: *anyopaque, msg: *const Notification.RequestIntercept) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        try @import("domains/fetch.zig").requestIntercept(self, msg);
    }

    pub fn onHttpRequestFail(ctx: *anyopaque, msg: *const Notification.RequestFail) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        return @import("domains/network.zig").httpRequestFail(self, msg);
    }

    pub fn onFrameDOMContentLoaded(ctx: *anyopaque, msg: *const Notification.FrameDOMContentLoaded) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        return @import("domains/page.zig").frameDOMContentLoaded(self, msg);
    }

    pub fn onFrameLoaded(ctx: *anyopaque, msg: *const Notification.FrameLoaded) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        return @import("domains/page.zig").frameLoaded(self, msg);
    }

    pub fn onJavascriptDialogOpening(ctx: *anyopaque, msg: *const Notification.JavascriptDialogOpening) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        return @import("domains/page.zig").javascriptDialogOpening(self, msg);
    }

    fn keyFromRequestReq(req: *const Request) CDP.BrowserContext.CapturedResponseKey {
        return if (req.params.resource_type == .document)
            .{ .kind = .loader, .id = req.params.loader_id }
        else
            .{ .kind = .request, .id = req.params.request_id };
    }

    pub fn onHttpResponseHeadersDone(ctx: *anyopaque, msg: *const Notification.ResponseHeaderDone) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        defer self.resetNotificationArena();

        const arena = self.frame_arena;

        // Prepare the captured response value.
        const key = keyFromRequestReq(msg.request);
        const gop = try self.captured_responses.getOrPut(arena, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .data = .empty,
                // Encode the data in base64 by default, but don't encode
                // for well known content-type.
                .must_encode = blk: {
                    const response = msg.response;
                    if (response.contentType()) |ct| {
                        const mime = try Mime.parse(ct);

                        if (!mime.isText()) {
                            break :blk true;
                        }

                        if (std.mem.eql(u8, "UTF-8", mime.charsetString())) {
                            break :blk false;
                        }
                    }
                    break :blk true;
                },
            };
        }

        return @import("domains/network.zig").httpResponseHeaderDone(self.notification_arena, self, msg);
    }

    pub fn onHttpRequestDone(ctx: *anyopaque, msg: *const Notification.RequestDone) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        return @import("domains/network.zig").httpRequestDone(self, msg);
    }

    pub fn onHttpResponseData(ctx: *anyopaque, msg: *const Notification.ResponseData) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        const arena = self.frame_arena;

        const key = keyFromRequestReq(msg.request);
        const resp = self.captured_responses.getPtr(key) orelse {
            log.warn(.cdp, "http response data without captured headers", .{
                .loader_id = msg.request.params.loader_id,
                .request_id = msg.request.params.request_id,
            });
            return;
        };

        return resp.data.appendSlice(arena, msg.data);
    }

    pub fn onHttpRequestAuthRequired(ctx: *anyopaque, data: *const Notification.RequestAuthRequired) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        defer self.resetNotificationArena();
        try @import("domains/fetch.zig").requestAuthRequired(self, data);
    }

    fn resetNotificationArena(self: *BrowserContext) void {
        defer _ = self.cdp.notification_arena.reset(.{ .retain_with_limit = 1024 * 64 });
    }

    pub fn callInspector(self: *const BrowserContext, msg: []const u8) void {
        const browser = self.session.browser;
        browser.cdp_eval_depth += 1;
        defer browser.cdp_eval_depth -= 1;
        self.inspector_session.send(msg);
        browser.env.runMicrotasks(.unknown);
        browser.env.pumpMessageLoop();
    }

    pub fn onInspectorResponse(ctx: *anyopaque, _: u32, msg: []const u8) void {
        sendInspectorMessage(@ptrCast(@alignCast(ctx)), msg) catch |err| {
            log.err(.cdp, "send inspector response", .{ .err = err });
        };
    }

    pub fn onInspectorEvent(ctx: *anyopaque, msg: []const u8) void {
        if (log.enabled(.cdp, .debug)) {
            // msg should be {"method":<method>,...
            assert(std.mem.startsWith(u8, msg, "{\"method\":"), "onInspectorEvent prefix", .{});
            const method_end = std.mem.indexOfScalar(u8, msg, ',') orelse {
                log.err(.cdp, "invalid inspector event", .{ .msg = msg });
                return;
            };
            const method = msg[10..method_end];
            log.debug(.cdp, "inspector event", .{ .method = method });
        }

        sendInspectorMessage(@ptrCast(@alignCast(ctx)), msg) catch |err| {
            log.err(.cdp, "send inspector event", .{ .err = err });
        };
    }

    // This is hacky x 2. First, we create the JSON payload by gluing our
    // session_id onto it. Second, we're much more client/websocket aware than
    // we should be.
    fn sendInspectorMessage(self: *BrowserContext, msg: []const u8) !void {
        const session_id = self.inspector_reply_session_id orelse self.session_id orelse {
            // We no longer have an active session. What should we do
            // in this case?
            return;
        };

        const cdp = self.cdp;
        const allocator = cdp.ws.send_arena.allocator();

        const field = ",\"sessionId\":\"";

        // + 1 for the closing quote after the session id
        // + 10 for the max websocket header
        const message_len = msg.len + session_id.len + 1 + field.len + 10;

        var buf: std.ArrayList(u8) = .empty;
        buf.ensureTotalCapacity(allocator, message_len) catch |err| {
            log.err(.cdp, "inspector buffer", .{ .err = err });
            return;
        };

        // reserve 10 bytes for websocket header
        buf.appendSliceAssumeCapacity(&.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });

        // -1  because we dont' want the closing brace '}'
        buf.appendSliceAssumeCapacity(msg[0 .. msg.len - 1]);
        buf.appendSliceAssumeCapacity(field);
        buf.appendSliceAssumeCapacity(session_id);
        buf.appendSliceAssumeCapacity("\"}");
        if (comptime IS_DEBUG) {
            std.debug.assert(buf.items.len == message_len);
        }

        try cdp.ws.sendJSONRaw(buf);
    }
};

/// see: https://chromium.googlesource.com/chromium/src/+/master/third_party/blink/renderer/bindings/core/v8/V8BindingDesign.md#world
/// The current understanding. An isolated world lives in the same isolate, but a separated context.
/// Clients create this to be able to create variables and run code without interfering with the
/// normal namespace and values of the webframe. Similar to the main context we need to pretend to recreate it after
/// a executionContextsCleared event which happens when navigating to a new frame. A client can have a command be executed
const ScriptOnNewDocument = struct {
    identifier: u32,
    source: []const u8,
};

/// in the isolated world by using its Context ID or the worldName.
/// grantUniversalAccess Indicates whether the isolated world can reference objects like the DOM or other JS Objects.
/// An isolated world has it's own instance of globals like Window.
/// Generally the client needs to resolve a node into the isolated world to be able to work with it.
/// An object id is unique across all contexts, different object ids can refer to the same Node in different contexts.
const IsolatedWorld = struct {
    arena: Allocator,
    call_arena: Allocator,
    browser: *Browser,
    name: []const u8,
    context: ?*js.Context = null,
    grant_universal_access: bool,

    // Identity tracking for this isolated world (separate from main world).
    // This ensures CDP inspector contexts don't share v8::Globals with main world.
    identity: js.Identity = .{},

    pub fn deinit(self: *IsolatedWorld) void {
        self.removeContext();
        self.browser.arena_pool.release(self.call_arena);
        self.browser.arena_pool.release(self.arena);
    }

    pub fn removeContext(self: *IsolatedWorld) void {
        if (self.context) |ctx| {
            self.browser.env.destroyContext(ctx);
            self.context = null;
        }
        // I don't think it's possible to have any identity without a context,
        // but there's no harm in being safe.
        self.identity.deinit();
        self.identity = .{};
    }

    // The isolate world must share at least some of the state with the related frame, specifically the DocumentHTML
    // (assuming grantUniversalAccess will be set to True!).
    // We just created the world and the frame. The frame's state lives in the session, but is update on navigation.
    // This also means this pointer becomes invalid after removePage until a new frame is created.
    // Currently we have only 1 frame and thus also only 1 state in the isolate world.
    pub fn createContext(self: *IsolatedWorld, frame: *Frame) !*js.Context {
        if (self.context != null) {
            self.removeContext();
        }
        const ctx = try self.browser.env.createContext(frame, .{
            .identity = &self.identity,
            .identity_arena = self.arena,
            .call_arena = self.call_arena,
            .debug_name = "IsolatedContext",
        });
        self.context = ctx;
        return ctx;
    }
};

// This is a generic because when we send a result we have two different
// behaviors. Normally, we're sending the result to the client. But in some cases
// we want to capture the result. So we want the command.sendResult to be
// generic.
pub const Command = struct {
    // A misc arena that can be used for any allocation for processing
    // the message
    arena: Allocator,

    // reference to our CDP instance
    cdp: *CDP,

    // The browser context this command targets
    browser_context: ?*BrowserContext,

    // The command input (the id, optional session_id, params, ...)
    input: Input,

    // In most cases, Sender is going to be cdp itself. We'll call
    // sender.sendJSON() and CDP will send it to the client. But some
    // commands are dispatched internally, in which cases the Sender will
    // be code to capture the data that we were "sending".
    sender: Sender,

    const Sender = union(enum) {
        cdp: *CDP,
        capture: *std.Io.Writer,

        pub fn sendJSON(self: Sender, message: anytype) !void {
            switch (self) {
                .cdp => |cdp| return cdp.sendJSON(message),
                .capture => |writer| {
                    return std.json.Stringify.value(message, .{
                        .emit_null_optional_fields = false,
                    }, writer);
                },
            }
        }
    };

    pub fn params(self: *const Command, comptime T: type) !?T {
        if (self.input.params) |p| {
            return try json.parseFromSliceLeaky(
                T,
                self.arena,
                p.raw,
                .{ .ignore_unknown_fields = true },
            );
        }
        return null;
    }

    pub fn createBrowserContext(self: *Command) !*BrowserContext {
        _ = try self.cdp.createBrowserContext();
        self.browser_context = &(self.cdp.browser_context.?);
        return self.browser_context.?;
    }

    const SendResultOpts = struct {
        include_session_id: bool = true,
    };
    pub fn sendResult(self: *Command, result: anytype, opts: SendResultOpts) !void {
        return self.sender.sendJSON(.{
            .id = self.input.id,
            .result = if (comptime @typeInfo(@TypeOf(result)) == .null) struct {}{} else result,
            .sessionId = if (opts.include_session_id) self.input.session_id else null,
        });
    }

    pub fn sendEvent(self: *Command, method: []const u8, p: anytype, opts: SendEventOpts) !void {
        // Events ALWAYS go to the client. self.sender should not be used
        return self.cdp.sendEvent(method, p, opts);
    }

    const SendErrorOpts = struct {
        include_session_id: bool = true,
    };
    pub fn sendError(self: *Command, code: i32, message: []const u8, opts: SendErrorOpts) !void {
        return self.sender.sendJSON(.{
            .id = self.input.id,
            .@"error" = .{ .code = code, .message = message },
            .sessionId = if (opts.include_session_id) self.input.session_id else null,
        });
    }

    const Input = struct {
        // When we reply to a message, we echo back the message id
        id: ?i64,

        // The "action" of the message.Given a method of "LOG.enable", the
        // action is "enable"
        action: []const u8,

        // See notes in BrowserContext about session_id
        session_id: ?[]const u8,

        // Unparsed / untyped input.params.
        params: ?InputParams,

        // The full raw json input
        json: []const u8,
    };
};

// When we parse a JSON message from the client, this is the structure
// we always expect
const InputMessage = struct {
    id: ?i64 = null,
    method: []const u8,
    params: ?InputParams = null,
    sessionId: ?[]const u8 = null,
};

// The JSON "params" field changes based on the "method". Initially, we just
// capture the raw json object (including the opening and closing braces).
// Then, when we're processing the message, and we know what type it is, we
// can parse it (in Disaptch(T).params).
const InputParams = struct {
    raw: []const u8,

    pub fn jsonParse(
        _: Allocator,
        scanner: *json.Scanner,
        _: json.ParseOptions,
    ) !InputParams {
        const height = scanner.stackHeight();

        const start = scanner.cursor;
        if (try scanner.next() != .object_begin) {
            return error.UnexpectedToken;
        }
        try scanner.skipUntilStackHeight(height);
        const end = scanner.cursor;

        return .{ .raw = scanner.input[start..end] };
    }
};

fn asUint(comptime T: type, comptime string: []const u8) T {
    return @bitCast(string[0..string.len].*);
}

const testing = @import("testing.zig");
test "cdp: invalid json" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try testing.expectError(error.InvalidJSON, ctx.processMessage("invalid"));

    // method is required
    try testing.expectError(error.InvalidJSON, ctx.processMessage(.{}));

    try ctx.processMessage(.{
        .method = "Target",
    });
    try ctx.expectSentError(-31998, "InvalidMethod", .{});

    try ctx.processMessage(.{
        .method = "Unknown.domain",
    });
    try ctx.expectSentError(-31998, "UnknownDomain", .{});

    try ctx.processMessage(.{
        .method = "Target.over9000",
    });
    try ctx.expectSentError(-31998, "UnknownMethod", .{});
}

test "cdp: invalid sessionId" {
    var ctx = try testing.context();
    defer ctx.deinit();

    {
        // we have no browser context
        try ctx.processMessage(.{ .method = "Hi", .sessionId = "nope" });
        try ctx.expectSentError(-32001, "Unknown sessionId", .{});
    }

    {
        // we have a browser context but no session_id
        _ = try ctx.loadBrowserContext(.{});
        try ctx.processMessage(.{ .method = "Hi", .sessionId = "BC-Has-No-SessionId" });
        try ctx.expectSentError(-32001, "Unknown sessionId", .{});
    }

    {
        // we have a browser context with a different session_id
        _ = try ctx.loadBrowserContext(.{ .session_id = "SESS-2" });
        try ctx.processMessage(.{ .method = "Hi", .sessionId = "SESS-1" });
        try ctx.expectSentError(-32001, "Unknown sessionId", .{});
    }
}

test "cdp: STARTUP sessionId" {
    var ctx = try testing.context();
    defer ctx.deinit();

    {
        // we have no browser context
        try ctx.processMessage(.{ .id = 2, .method = "Hi", .sessionId = "STARTUP" });
        try ctx.expectSentResult(null, .{ .id = 2, .index = 0, .session_id = "STARTUP" });
    }

    {
        // we have a browser context but no session_id
        _ = try ctx.loadBrowserContext(.{});
        try ctx.processMessage(.{ .id = 3, .method = "Hi", .sessionId = "STARTUP" });
        try ctx.expectSentResult(null, .{ .id = 3, .index = 1, .session_id = "STARTUP" });
    }

    {
        // we have a browser context with a different session_id
        _ = try ctx.loadBrowserContext(.{ .session_id = "SESS-2" });
        try ctx.processMessage(.{ .id = 4, .method = "Hi", .sessionId = "STARTUP" });
        try ctx.expectSentResult(null, .{ .id = 4, .index = 2, .session_id = "STARTUP" });
    }
}
