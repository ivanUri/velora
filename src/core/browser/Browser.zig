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
const sync = @import("../../support/sync.zig");

const Allocator = std.mem.Allocator;

const js = @import("../js/js.zig");
const App = @import("../../runtime/App.zig");
const HttpClient = @import("HttpClient.zig");

const ArenaPool = App.ArenaPool;

const Session = @import("Session.zig");
const Page = @import("Page.zig");
const Notification = @import("../../runtime/Notification.zig");
const BatteryManager = @import("../webapi/BatteryManager.zig");

// Browser is an instance of the browser.
// You can create multiple browser instances.
// A browser contains only one session.
const Browser = @This();

pub fn observeBrowserStage(self: *Browser, stage: []const u8, duration_us: u64, frame_id: u32, loader_id: u32, measurement_state: []const u8, process: []const u8, thread: []const u8) void {
    self.app.network.emitBrowserStage(stage, duration_us, frame_id, loader_id, measurement_state, process, thread);
}
pub fn observeLifecycle(self: *Browser, stage: []const u8, frame_id: u32, loader_id: u32, url: []const u8) void {
    self.app.network.emitLifecycle(stage, frame_id, loader_id, url);
}
pub fn observeBrowserScript(self: *Browser, duration_us: u64, frame_id: u32, loader_id: u32, url: []const u8, script_kind: []const u8) void {
    self.app.network.emitBrowserScript(duration_us, frame_id, loader_id, url, script_kind);
}
pub fn observeJavaScriptError(self: *Browser, error_kind: []const u8, message: []const u8, script_url: []const u8, line: u32, column: u32, frame_id: u32, loader_id: u32, stack: ?[]const u8) void {
    self.app.network.emitJavaScriptError(error_kind, message, script_url, line, column, frame_id, loader_id, stack);
}
pub fn observeApplicationStorageEntry(self: *Browser, storage_type: []const u8, origin: []const u8, key: []const u8, value: ?[]const u8, value_bytes: usize, details: anytype) void {
    self.app.network.emitApplicationStorageEntry(storage_type, origin, key, value, value_bytes, details);
}

env: js.Env,
app: *App,
session: ?Session,
allocator: Allocator,
arena_pool: *ArenaPool,
http_client: HttpClient,
battery_config: BatteryManager.Config,

// used by sessions to allocate pages.
page_pool: std.heap.MemoryPool(Page),

// Serializes CDP-driven browser ticks. Multiple CDP WebSocket threads must not
// run HttpClient.perform / V8 macrotasks concurrently on the same session.
tick_mutex: sync.Mutex = .{},

// Host-owned cancellation is durable across V8 execution scopes. V8's
// TerminateExecution flag is intentionally transient: script watchdogs may
// clear it after containing one runaway evaluation. A CLI deadline, however,
// applies to the whole browser operation and must remain observable by the
// runner until that operation reaches its terminal path.
host_termination_requested: std.atomic.Value(bool) = .init(false),

// Inspector-driven Runtime.evaluate / callFunctionOn depth. Used to defer
// commitPendingPage while CDP holds the active V8 context on the stack.
cdp_eval_depth: u32 = 0,

pub fn cdpInspectorBusy(self: *const Browser) bool {
    return self.cdp_eval_depth > 0;
}

pub fn requestHostTermination(self: *Browser) void {
    self.host_termination_requested.store(true, .release);
    self.env.terminate();
}

pub fn isHostTerminationRequested(self: *const Browser) bool {
    return self.host_termination_requested.load(.acquire);
}

pub fn clearHostTermination(self: *Browser) void {
    self.env.cancelTerminate();
    self.host_termination_requested.store(false, .release);
}

const InitOpts = struct {
    env: js.Env.InitOpts = .{},
    battery_config: BatteryManager.Config = .{},
};

pub fn init(self: *Browser, app: *App, opts: InitOpts, cdp_client: ?HttpClient.CDPClient) !void {
    const allocator = app.allocator;

    var env = try js.Env.init(app, opts.env);
    errdefer env.deinit();

    self.* = .{
        .app = app,
        .env = env,
        .session = null,
        .allocator = allocator,
        .arena_pool = &app.arena_pool,
        .http_client = undefined,
        .battery_config = opts.battery_config,
        .page_pool = .empty,
    };
    try self.http_client.init(allocator, &app.network, cdp_client);
    self.http_client.env = &self.env;
}

pub fn deinit(self: *Browser) void {
    // HTTP callbacks retain pointers into Page/Execution state. Terminate all
    // transports while their owning storage is still alive, but first mark
    // every realm terminal so shutdown callbacks cannot re-enter JavaScript
    // and create new work during teardown.
    if (self.session) |*session| session.prepareForBrowserShutdown();
    self.http_client.abort();
    self.closeSession();
    self.env.deinit();
    self.page_pool.deinit(self.allocator);
    self.http_client.deinit();
}

pub fn newSession(self: *Browser, notification: *Notification) !*Session {
    self.closeSession();
    self.session = @as(Session, undefined);
    const session = &self.session.?;
    try Session.init(session, self, notification);
    self.http_client.session = session;
    return session;
}

pub fn closeSession(self: *Browser) void {
    self.http_client.session = null;
    if (self.session) |*session| {
        session.deinit();
        self.session = null;
    }
}

pub fn runMicrotasks(self: *Browser) void {
    self.env.runMicrotasks(.unknown);
}

pub fn runMacrotasks(self: *Browser) !void {
    const env = &self.env;

    // HTML event loop: microtasks before macrotasks, then shared EventLoop.spin
    // so delay-0 chains (MessageChannel / post-script) progress without site pumps.
    env.runMicrotasks(.macrotask_loop);

    try self.env.runMacrotasks();
    env.pumpMessageLoop();

    // EventLoop.spin for the current frame is applied from Runner after
    // runMacrotasks / post-script paths — avoid double-spin reentrancy here.
    env.runMicrotasks(.macrotask_loop);

    // WebRTC ICE candidates land on a network thread queue; BrowserLeaks and
    // onicecandidate handlers need drain even when CDP awaitPromise starves
    // Runner._tick (timer-only pages never re-enter the full wait loop).
    self.drainAllRtcEvents();
}

/// One macrotask turn for CDP interleaving — returns true if any task ran.
pub fn runMacrotasksCdpSlice(self: *Browser) !bool {
    const env = &self.env;
    env.runMicrotasks(.macrotask_loop);
    const ran = try env.runOneMacrotaskRound();
    env.pumpMessageLoop();
    env.runMicrotasks(.macrotask_loop);
    self.drainAllRtcEvents();
    if (self.http_client.cdp_client != null) {
        self.http_client.serviceInboundCdpIfReadable();
    }
    return ran;
}

fn drainAllRtcEvents(self: *Browser) void {
    const session = &(self.session orelse return);
    // Prefer active page; fall back to pending root during navigation.
    if (session.pendingOrCurrentFrame()) |frame| {
        frame.drainRtcEvents();
    }
}

pub fn hasBackgroundTasks(self: *Browser) bool {
    return self.env.hasBackgroundTasks();
}

pub fn hasReadyMacrotasks(self: *const Browser) bool {
    return self.env.hasReadyMacrotasks();
}

pub fn waitForBackgroundTasks(self: *Browser) void {
    self.env.waitForBackgroundTasks();
}

pub fn msToNextMacrotask(self: *Browser) ?u64 {
    return self.env.msToNextMacrotask();
}

pub fn msTo(self: *Browser) bool {
    return self.env.hasBackgroundTasks();
}

pub fn runIdleTasks(self: *const Browser) void {
    self.env.runIdleTasks();
}
