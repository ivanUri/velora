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

// The struct is like a mix of Page and Window, but a very limited Page and
// a very limited Window. This dual-purpose does make it a bit harder to know
// what's what...e.g what is a WebAPI call and what it called internally.

const std = @import("std");

const JS = @import("../js/js.zig");
const URL = @import("../browser/URL.zig");
const Mime = @import("../browser/Mime.zig");
const Frame = @import("../browser/Frame.zig");
const Page = @import("../browser/Page.zig");
const Factory = @import("../browser/Factory.zig");
const Session = @import("../browser/Session.zig");
const HttpClient = @import("../browser/HttpClient.zig");
const EventManagerBase = @import("../browser/EventManagerBase.zig");
const ScriptManagerBase = @import("../browser/ScriptManagerBase.zig");

const Blob = @import("Blob.zig");
const Event = @import("Event.zig");
const Worker = @import("Worker.zig");
const Crypto = @import("Crypto.zig");
const Console = @import("Console.zig");
const Timers = @import("Timers.zig");
const EventTarget = @import("EventTarget.zig");
const MessageEvent = @import("event/MessageEvent.zig");
const ConnectEvent = @import("event/ConnectEvent.zig");
const ErrorEvent = @import("event/ErrorEvent.zig");
const Fetch = @import("net/Fetch.zig");
const Performance = @import("Performance.zig");
const WorkerNavigator = @import("WorkerNavigator.zig");
const WorkerLocation = @import("WorkerLocation.zig");
const DOMException = @import("../dom/DOMException.zig");

const v8 = JS.v8;

const builtin = @import("builtin");
const IS_DEBUG = builtin.mode == .Debug;

const log = @import("../../support/log.zig");
const RealmLifecycleKernel = @import("../../runtime/RealmLifecycleKernel.zig");
const Allocator = std.mem.Allocator;

const MessagePort = @import("MessagePort.zig");

const WorkerGlobalScope = @This();

// Meant to follow the same field naming as Page so that an anytype of generic
// can access these the same for a Page of a WGS.
// These fields represent the "Page"-like component of the WGS
_page: *Page,
_session: *Session,
_factory: *Factory,
_identity: JS.Identity = .{},
arena: Allocator,
call_arena: Allocator,
url: [:0]const u8,
/// SharedWorkerGlobalScope name (empty for dedicated workers).
_name: []const u8 = "",
// Same-origin constraint: a worker's origin is inherited from its parent frame.
origin: ?[]const u8 = null,
buf: [1024]u8 = undefined, // same size as frame.buf
// Document charset (matches Page.charset). Workers default to UTF-8.
charset: []const u8 = "UTF-8",
js: *JS.Context,

// Blob URL registry for URL.createObjectURL/revokeObjectURL.
_blob_urls: std.StringHashMapUnmanaged(*Blob) = .{},

// Reference back to the Worker object (for postMessage to frame)
_worker: *Worker,

// HTTP attribution. Mirrors Frame's fields so that generic code over
// (Frame|WorkerGlobalScope) can read them uniformly. Populated from the
// owning Worker at init.
_frame_id: u32,
_loader_id: u32,

_realm_epoch: RealmLifecycleKernel.Epoch = 0,
_realm_state: RealmLifecycleKernel.State = .active,

// Event management for non-DOM targets in worker context
_event_manager: EventManagerBase,

// Handles module imports (static + dynamic). No parser integration since
// workers don't have <script> tags.
_script_manager: ScriptManagerBase,

// These fields represent the "Window"-like component of the WGS
_closed: bool = false,
_proto: *EventTarget,
_console: Console = .init,
_crypto: Crypto = .init,
_navigator: WorkerNavigator = .init,
_location: *WorkerLocation,
_performance: Performance,
_on_error: ?JS.Function.Global = null,
_on_rejection_handled: ?JS.Function.Global = null,
_on_unhandled_rejection: ?JS.Function.Global = null,
_on_message: ?JS.Function.Global = null,
_on_messageerror: ?JS.Function.Global = null,
_on_connect: ?JS.Function.Global = null,
_pending_undelivered: std.ArrayListUnmanaged(PendingInboundMessage) = .empty,
_pending_connect_ports: std.ArrayList(*MessagePort) = .empty,
_debug_next_message_id: u64 = 1,

_timers: Timers = .{},

pub fn init(worker: *Worker, url: [:0]const u8, shared: bool) !*WorkerGlobalScope {
    const arena = worker._arena;
    const parent = worker._frame;
    const session = worker._frame._session;

    const call_arena = try session.getArena(.small, "WorkerGlobalScope.call_arena");
    errdefer session.releaseArena(call_arena);

    const factory = parent._factory;
    // data: workers use an opaque origin for inside settings (dynamic import CORS).
    const worker_origin: ?[]const u8 = if (std.mem.startsWith(u8, url, "data:"))
        null
    else if (parent.origin) |o|
        o
    else
        try URL.getOrigin(arena, url);
    const self = try factory.eventTargetWithAllocator(arena, WorkerGlobalScope{
        .url = url,
        .arena = arena,
        .origin = worker_origin,
        .js = undefined,
        .call_arena = call_arena,
        ._session = session,
        ._page = parent._page,
        ._identity = .{},
        ._proto = undefined,
        ._factory = factory,
        ._worker = worker,
        ._frame_id = worker._frame_id,
        ._loader_id = worker._loader_id,
        ._performance = Performance.init(),
        ._event_manager = .init(arena),
        ._script_manager = undefined,
        ._location = try WorkerLocation.init(url, &parent.js.execution, factory),
    });
    errdefer factory.destroy(self);

    self._script_manager = ScriptManagerBase.init(
        arena,
        &session.browser.http_client,
        .{ .worker = self },
    );

    self.js = if (shared)
        try session.browser.env.createSharedWorkerContext(self, .{
            .call_arena = call_arena,
            .identity_arena = arena,
            .identity = &self._identity,
        })
    else
        try session.browser.env.createWorkerContext(self, .{
            .call_arena = call_arena,
            .identity_arena = arena,
            .identity = &self._identity,
        });

    return self;
}

pub fn realmEpoch(self: *const WorkerGlobalScope) RealmLifecycleKernel.Epoch {
    return self._realm_epoch;
}

pub fn realmSchedulingActive(self: *const WorkerGlobalScope) bool {
    return self._realm_state == .active;
}

pub fn realmState(self: *const WorkerGlobalScope) RealmLifecycleKernel.State {
    return self._realm_state;
}

fn enterRealmDraining(self: *WorkerGlobalScope) void {
    if (self._realm_state == .active) {
        self._realm_state = .draining;
        RealmLifecycleKernel.trace(.realm_draining, self._frame_id, null, null);
    }
}

fn enterRealmDead(self: *WorkerGlobalScope) void {
    if (self._realm_state != .dead) {
        self._realm_state = .dead;
        RealmLifecycleKernel.trace(.realm_dead, self._frame_id, self.realmEpoch(), null);
    }
}

pub fn deinit(self: *WorkerGlobalScope) void {
    self.deinitForSession(self._session);
}

pub fn deinitForSession(self: *WorkerGlobalScope, session: *Session) void {
    self.enterRealmDraining();
    // Worker-owned callbacks retain this scope and V8 function handles.  Drop
    // them before destroying the worker context; otherwise the next browser
    // tick (or the next test session) can dispatch a queued message into a
    // dead realm and call a poisoned V8 handle.
    self.js.scheduler.reset();
    self.releasePendingUndelivered();
    self._script_manager.deinit();

    const page = self._page;
    var it = self._blob_urls.valueIterator();
    while (it.next()) |blob| {
        blob.*.releaseRef(page);
    }
    self.enterRealmDead();
    session.browser.env.destroyContext(self.js);
    page.shutdownIdentity(&self._identity);
    session.releaseArena(self.call_arena);
}

pub fn base(self: *const WorkerGlobalScope) [:0]const u8 {
    return self.url;
}

pub fn asEventTarget(self: *WorkerGlobalScope) *EventTarget {
    return self._proto;
}

// Dispatch an event to listeners on the given target within this worker context.
pub fn dispatch(
    self: *WorkerGlobalScope,
    target: *EventTarget,
    event: *Event,
    handler: anytype,
    comptime opts: EventManagerBase.DispatchDirectOptions,
) !void {
    self._event_manager.beginDispatch();
    defer self._event_manager.endDispatch();
    try self._event_manager.dispatchDirect(
        self.call_arena,
        self.js,
        target,
        event,
        handler,
        self._page,
        opts,
    );
}

pub fn hasDirectListeners(self: *WorkerGlobalScope, target: *EventTarget, typ: []const u8, handler: anytype) bool {
    return self._event_manager.hasDirectListeners(target, typ, handler);
}

// Workers don't have their own Referer; per spec, dedicated worker requests
// use the parent document's URL. Delegate to the owning frame.
pub fn headersForRequest(self: *WorkerGlobalScope, headers: *HttpClient.Headers, opts: Frame.HeadersForRequestOpts) !void {
    return self._worker._frame.headersForRequest(headers, opts);
}

pub fn isSameOrigin(self: *const WorkerGlobalScope, url: [:0]const u8) bool {
    const current_origin = self.origin orelse return false;

    if (!std.mem.startsWith(u8, url, current_origin)) {
        return false;
    }
    return std.mem.eql(u8, URL.getHost(url), URL.getHost(current_origin));
}

pub fn lookupBlobUrl(self: *WorkerGlobalScope, url: []const u8) ?*Blob {
    return self._blob_urls.get(url);
}

fn lookupBlobUrlFuzzy(self: *WorkerGlobalScope, url: []const u8) ?*Blob {
    if (self.lookupBlobUrl(url)) |blob| return blob;
    if (self._worker._frame.lookupBlobUrl(url)) |blob| return blob;
    const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse return null;
    const suffix = url[slash + 1 ..];
    if (suffix.len == 0) return null;
    var it = self._blob_urls.iterator();
    while (it.next()) |entry| {
        if (std.mem.endsWith(u8, entry.key_ptr.*, suffix)) return entry.value_ptr.*;
    }
    var frame_it = self._worker._frame._blob_urls.iterator();
    while (frame_it.next()) |entry| {
        if (std.mem.endsWith(u8, entry.key_ptr.*, suffix)) return entry.value_ptr.*;
    }
    return null;
}

pub fn getSelf(self: *WorkerGlobalScope) *WorkerGlobalScope {
    return self;
}

pub fn getConsole(self: *WorkerGlobalScope) *Console {
    return &self._console;
}

pub fn getCrypto(self: *WorkerGlobalScope) *Crypto {
    return &self._crypto;
}

pub fn getPerformance(self: *WorkerGlobalScope) *Performance {
    return &self._performance;
}

pub fn getNavigator(self: *WorkerGlobalScope) *WorkerNavigator {
    return &self._navigator;
}

pub fn getLocation(self: *WorkerGlobalScope) *WorkerLocation {
    return self._location;
}

pub fn getName(self: *const WorkerGlobalScope) []const u8 {
    return self._name;
}

/// Sloppy worker scripts may assign `name = …` to shadow the readonly IDL
/// attribute (WPT `setting.js`). Define an own data property on the global.
pub fn setName(self: *WorkerGlobalScope, value: JS.Value) void {
    const scope = activeLocal(self);
    var owned_scope = scope.owned;
    defer if (owned_scope) |*s| s.deinit();

    const global_handle = v8.v8__Context__Global(scope.local.handle).?;
    const global = JS.Object{ .local = scope.local, .handle = global_handle };
    // DefineOwnProperty — Object::Set would re-enter this setter.
    _ = global.defineOwnProperty("name", value, v8.None);
}

pub fn getOnError(self: *const WorkerGlobalScope) ?JS.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_error = getFunctionFromSetter(setter);
}

pub fn getOnRejectionHandled(self: *const WorkerGlobalScope) ?JS.Function.Global {
    return self._on_rejection_handled;
}

pub fn setOnRejectionHandled(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_rejection_handled = getFunctionFromSetter(setter);
}

pub fn getOnUnhandledRejection(self: *const WorkerGlobalScope) ?JS.Function.Global {
    return self._on_unhandled_rejection;
}

pub fn setOnUnhandledRejection(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_unhandled_rejection = getFunctionFromSetter(setter);
}

pub fn getOnMessage(self: *const WorkerGlobalScope) ?JS.Function.Global {
    return self._on_message;
}

pub fn setOnMessage(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_message = getFunctionFromSetter(setter);
    self.scheduleDeferredFlushUndelivered() catch |err| {
        log.warn(.browser, "WorkerGlobalScope.scheduleDeferredFlushUndelivered", .{ .err = err });
    };
}

pub fn scheduleDeferredFlushUndelivered(self: *WorkerGlobalScope) !void {
    const arena = try self._session.getArena(.tiny, "WorkerGlobalScope.deferFlushUndelivered");
    errdefer self._session.releaseArena(arena);

    const callback = try arena.create(DeferFlushUndeliveredCallback);
    callback.* = .{ .worker_scope = self, .session = self._session, .arena = arena };

    try self.js.scheduler.add(callback, DeferFlushUndeliveredCallback.run, 0, .{
        .name = "WorkerGlobalScope.deferFlushUndelivered",
        .low_priority = false,
        .finalizer = DeferFlushUndeliveredCallback.cancelled,
    });
}

const DeferFlushUndeliveredCallback = struct {
    worker_scope: *WorkerGlobalScope,
    session: *Session,
    arena: Allocator,

    fn cancelled(ctx: *anyopaque) void {
        const self: *DeferFlushUndeliveredCallback = @ptrCast(@alignCast(ctx));
        self.session.releaseArena(self.arena);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DeferFlushUndeliveredCallback = @ptrCast(@alignCast(ctx));
        defer self.session.releaseArena(self.arena);
        const worker = self.worker_scope._worker;
        if (!worker.beginTask()) return null;
        defer worker.endTask();
        try self.worker_scope.flushPendingUndelivered();
        return null;
    }
};

pub fn flushPendingUndelivered(self: *WorkerGlobalScope) !void {
    var ls: JS.Local.Scope = undefined;
    self.js.localScope(&ls);
    defer ls.deinit();
    self.syncScriptHandlerSlotsFromLocal(&ls.local);

    const target = self.asEventTarget();

    while (self._pending_undelivered.items.len > 0) {
        // The IDL setter keeps `_on_message` as a persistent handle.  Resolve
        // that handle in the current local scope instead of retaining a raw
        // V8 Local returned by a property lookup; the latter can outlive its
        // HandleScope when another worker task runs before dispatch.
        const on_message = if (self._on_message) |handler|
            handler.local(&ls.local)
        else
            null;
        if (!self._event_manager.hasDirectListeners(target, "message", on_message)) {
            break;
        }

        const pending = self._pending_undelivered.orderedRemove(0);
        const event = (try MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = .{ .value = pending.data },
            .ports = pending.ports,
            .bubbles = false,
            .cancelable = false,
        }, self._page)).asEvent();
        try self.dispatch(target, event, on_message, .{});
    }
    try self._worker._frame.scheduleDeferredMacrotaskPump(0);
    try self._worker._frame.scheduleDeferredMacrotaskPump(20);
}

fn releasePendingUndelivered(self: *WorkerGlobalScope) void {
    for (self._pending_undelivered.items) |pending| {
        pending.data.release();
    }
    self._pending_undelivered.deinit(self.arena);
    self._pending_undelivered = .empty;
}

pub fn getOnMessageError(self: *const WorkerGlobalScope) ?JS.Function.Global {
    return self._on_messageerror;
}

pub fn setOnMessageError(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_messageerror = getFunctionFromSetter(setter);
}

pub fn getOnConnect(self: *const WorkerGlobalScope) ?JS.Function.Global {
    return self._on_connect;
}

pub fn setOnConnect(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_connect = getFunctionFromSetter(setter);
    self.flushPendingConnects() catch |err| {
        log.warn(.browser, "WorkerGlobalScope.flushPendingConnects", .{ .err = err });
    };
}

fn activeLocal(self: *WorkerGlobalScope) struct { local: *const JS.Local, owned: ?JS.Local.Scope } {
    const nested_in_api = self.js.local != null;
    var owned_scope: JS.Local.Scope = undefined;
    const local: *const JS.Local = blk: {
        if (self.js.local) |active| break :blk active;
        self.js.localScope(&owned_scope);
        break :blk &owned_scope.local;
    };
    return .{
        .local = local,
        .owned = if (nested_in_api) null else owned_scope,
    };
}

fn materializeGlobalHandler(
    self: *WorkerGlobalScope,
    comptime field: []const u8,
    slot: *?JS.Function.Global,
) void {
    if (slot.* != null) return;
    // V8 disallows allocation/property access during microtask checkpoints and
    // while a worker local scope is still entered (DisallowJavascriptExecution).
    if (self._session.browser.env.checkpoint_active) return;
    if (self.js.local != null) return;
    if (!self.js.execution.canEnterJs(.strict_active)) return;

    const scope = activeLocal(self);
    var owned_scope = scope.owned;
    defer if (owned_scope) |*s| s.deinit();

    const global_handle = v8.v8__Context__Global(scope.local.handle).?;
    const global = JS.Object{ .local = scope.local, .handle = global_handle };
    const func = global.getFunction(field) catch null orelse return;
    slot.* = func.persist() catch null;
}

/// Worker scripts assign handlers as own global properties during initial eval;
/// if the accessor setter was not invoked, Zig slots stay null.
fn materializeOnConnect(self: *WorkerGlobalScope) void {
    materializeGlobalHandler(self, "onconnect", &self._on_connect);
}

fn materializeOnError(self: *WorkerGlobalScope) void {
    materializeGlobalHandler(self, "onerror", &self._on_error);
}

fn syncHandlerSlotFromLocal(
    local: *const JS.Local,
    comptime field: []const u8,
    slot: *?JS.Function.Global,
) void {
    if (slot.* != null) return;
    const global_handle = v8.v8__Context__Global(local.handle).?;
    const global = JS.Object{ .local = local, .handle = global_handle };
    const func = global.getFunction(field) catch null orelse return;
    slot.* = func.persist() catch null;
}

/// Sync Zig handler slots after classic worker eval while `local` is still entered.
pub fn syncScriptHandlerSlotsFromLocal(self: *WorkerGlobalScope, local: *const JS.Local) void {
    syncHandlerSlotFromLocal(local, "onmessage", &self._on_message);
    syncHandlerSlotFromLocal(local, "onmessageerror", &self._on_messageerror);
    syncHandlerSlotFromLocal(local, "onerror", &self._on_error);
    if (self._worker._shared_mode) {
        syncHandlerSlotFromLocal(local, "onconnect", &self._on_connect);
    }
}

fn handlerFromCurrentGlobal(local: *const JS.Local, comptime field: []const u8) ?JS.Function {
    const global_handle = v8.v8__Context__Global(local.handle).?;
    const global = JS.Object{ .local = local, .handle = global_handle };
    return global.getFunction(field) catch null;
}

/// Notify a shared-worker's `onerror` handler for a runtime throw when the
/// pending exception object is unavailable on the outer TryCatch.
pub fn reportSharedScriptRuntimeError(
    self: *WorkerGlobalScope,
    message: []const u8,
    filename: []const u8,
    line: u32,
    col: u32,
) void {
    materializeOnError(self);
    const on_error = self._on_error orelse return;

    var ls: JS.Local.Scope = undefined;
    self.js.localScope(&ls);
    defer ls.deinit();

    const msg_val = ls.local.zigValueToJs(message, .{}) catch return;
    const file_val = ls.local.zigValueToJs(filename, .{}) catch return;
    const line_val = ls.local.zigValueToJs(line, .{}) catch return;
    const col_val = ls.local.zigValueToJs(col, .{}) catch return;
    const err_val = (ls.local.zigValueToJs(@as(?[]const u8, null), .{}) catch return);

    const local_func = ls.toLocal(on_error);
    _ = local_func.call(JS.Value, .{ msg_val, file_val, line_val, col_val, err_val }) catch {};
    materializeOnError(self);
}

pub fn dispatchConnectEvent(self: *WorkerGlobalScope, port: *MessagePort) !void {
    port.start() catch |err| {
        log.warn(.browser, "SharedWorker connect port.start", .{ .err = err });
    };

    const target = self.asEventTarget();
    var on_connect = self._on_connect;
    if (!self._event_manager.hasDirectListeners(target, "connect", on_connect)) {
        materializeOnConnect(self);
        on_connect = self._on_connect;
        if (!self._event_manager.hasDirectListeners(target, "connect", on_connect)) {
            try self._pending_connect_ports.append(self.arena, port);
            return;
        }
    }

    const event = (try ConnectEvent.initTrusted(comptime .wrap("connect"), .{
        .ports = &.{port},
        .bubbles = false,
        .cancelable = false,
    }, self._page)).asEvent();
    try self.dispatch(target, event, on_connect, .{ .context = "SharedWorker.onconnect" });
    if (self._worker._shared_mode) {
        try scheduleDeferredSharedConnectPump(self, 0);
    } else {
        try self._worker._frame.scheduleDeferredMacrotaskPump(0);
    }
}

fn scheduleDeferredSharedConnectPump(self: *WorkerGlobalScope, _: u32) !void {
    const arena = try self._session.getArena(.tiny, "WGS.deferSharedConnectPump");
    errdefer self._session.releaseArena(arena);

    const callback = try arena.create(DeferSharedConnectPumpCallback);
    callback.* = .{ .worker_scope = self, .session = self._session, .arena = arena };

    try self.js.scheduler.add(callback, DeferSharedConnectPumpCallback.run, 0, .{
        .name = "WorkerGlobalScope.deferSharedConnectPump",
        .low_priority = false,
        .finalizer = DeferSharedConnectPumpCallback.cancelled,
    });
}

const DeferSharedConnectPumpCallback = struct {
    worker_scope: *WorkerGlobalScope,
    session: *Session,
    arena: Allocator,

    fn cancelled(ctx: *anyopaque) void {
        const self: *DeferSharedConnectPumpCallback = @ptrCast(@alignCast(ctx));
        self.session.releaseArena(self.arena);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DeferSharedConnectPumpCallback = @ptrCast(@alignCast(ctx));
        const wgs = self.worker_scope;
        const worker = wgs._worker;
        if (!worker.beginTask()) {
            self.session.releaseArena(self.arena);
            return null;
        }
        defer worker.endTask();
        const frame = wgs._worker._frame;
        const browser = frame._session.browser;

        _ = browser.http_client.tick(0) catch {};
        try frame.scheduleDeferredMacrotaskPump(0);

        defer self.session.releaseArena(self.arena);
        return null;
    }
};

pub fn flushPendingConnects(self: *WorkerGlobalScope) !void {
    const target = self.asEventTarget();
    while (self._pending_connect_ports.items.len > 0) {
        var on_connect = self._on_connect;
        if (!self._event_manager.hasDirectListeners(target, "connect", on_connect)) {
            materializeOnConnect(self);
            on_connect = self._on_connect;
            if (!self._event_manager.hasDirectListeners(target, "connect", on_connect)) {
                break;
            }
        }
        const port = self._pending_connect_ports.orderedRemove(0);
        try self.dispatchConnectEvent(port);
    }
}

// Posts a message from the worker back to the frame.
// The message is cloned via structured clone and dispatched on the Worker object.
pub fn postMessage(self: *WorkerGlobalScope, data: JS.Value, transfer_arg: ?JS.Value) !void {
    // Delivering to the parent can synchronously pump its scheduler.  A page
    // message handler is therefore allowed to terminate this worker before
    // postMessage returns; keep the worker realm alive for the whole bridge
    // call, including transfer processing and the follow-up pump.
    const worker = self._worker;
    if (!worker.beginTask()) return;
    defer worker.endTask();

    const FormData = @import("net/FormData.zig");
    const TaggedOpaque = @import("../js/TaggedOpaque.zig");
    if (data.isBranded(FormData) or
        data.isInstanceOf("FormData") or
        data.hasGlobalConstructorPrototype("FormData") or
        data.hasConstructorName("FormData"))
        return error.DataClone;
    if (data.isObject()) {
        if (TaggedOpaque.fromJS(*FormData, @ptrCast(data.toObject().handle)) catch null) |_| {
            return error.DataClone;
        }
    }

    const message_id = self._debug_nextMessageId();
    // Mid-eval postMessage must queue on Worker — see Worker._initial_eval_active.
    if (worker._initial_eval_active) {
        log.info(.browser, "worker postMessage mid-initial-eval", .{
            .worker_id = self._frame_id,
            .message_id = message_id,
        });
    } else if (comptime IS_DEBUG) {
        log.info(.browser, "worker postMessage to page", .{
            .worker_id = self._frame_id,
            .message_id = message_id,
        });
    }

    const frame = worker._frame;
    const transfer_list = try MessagePort.parseTransferArg(data.local, transfer_arg);
    const transferred_ports = try MessagePort.processTransferList(
        transfer_list,
        &self.js.execution,
        &frame.js.execution,
        self.arena,
    );

    try worker.receiveMessage(data, message_id, transferred_ports, transfer_list);
    Worker.pumpMessageDelivery(frame);
}

/// Run overdue worker scheduler tasks (setTimeout/setInterval) without nesting
/// `runMacrotasks` from inside an active macrotask callback.
pub fn pumpDueTimersNow(self: *WorkerGlobalScope, max_delay_ms: u32) void {
    const exec = &self.js.execution;
    if (exec.realmState() == .dead) return;
    if (!exec.canEnterJs(.strict_active)) return;

    var hs: JS.HandleScope = undefined;
    const entered = self.js.enter(&hs) orelse return;
    defer entered.exit();

    const env = &self._session.browser.env;
    var pass: u8 = 0;
    while (pass < 32) : (pass += 1) {
        const ms_to_next = self.js.scheduler.msToNext() orelse break;
        if (ms_to_next > max_delay_ms) break;
        if (!self.js.scheduler.hasReadyTasks()) break;
        _ = self.js.scheduler.runOne() catch break;
        var mt: u8 = 0;
        while (mt < 8) : (mt += 1) {
            env.performMicrotaskCheckpoint(self.js);
        }
    }
}

// Called internally by Worker when it wants to post a message to us
pub fn receiveMessage(
    self: *WorkerGlobalScope,
    data: JS.Value,
    message_id: u64,
    ports: []const *MessagePort,
    transfer_list: ?[]const JS.Value,
) !void {
    if (self._closed) {
        return;
    }
    const session = self._session;

    const cloned_data: ?JS.Value.Temp = blk: {
        var source_ls: JS.Local.Scope = undefined;
        self._worker._frame.js.localScope(&source_ls);
        defer source_ls.deinit();
        var target_ls: JS.Local.Scope = undefined;
        self.js.localScope(&target_ls);
        defer target_ls.deinit();

        const cloned = data.structuredCloneTo(&target_ls.local, transfer_list) catch break :blk null;
        break :blk cloned.temp() catch break :blk null;
    };

    const message_arena = try session.getArena(.tiny, "WorkerGlobalScope.receiveMessage");
    errdefer session.releaseArena(message_arena);

    const ports_copy = try message_arena.dupe(*MessagePort, ports);

    const callback = try message_arena.create(ReceiveMessageCallback);
    callback.* = .{
        .data = cloned_data,
        .ports = ports_copy,
        .worker_scope = self,
        .session = session,
        .arena = message_arena,
        .message_id = message_id,
        .task_owner = self.js.execution.captureTaskOwner(),
    };

    const queue_len = self._debug_schedulerQueueLen(self.js.scheduler);
    if (comptime IS_DEBUG) {
        log.info(.browser, "worker enqueue inbound message", .{
            .worker_id = self._frame_id,
            .message_id = message_id,
            .queue_len = queue_len,
        });
    }

    try self.js.scheduler.add(callback, ReceiveMessageCallback.run, 0, .{
        .name = "WorkerGlobalScope.receiveMessage",
        .low_priority = false,
        .finalizer = ReceiveMessageCallback.cancelled,
    });
}

pub fn btoa(_: *const WorkerGlobalScope, input: JS.String.OneByte, exec: *JS.Execution) ![]const u8 {
    return @import("encoding/base64.zig").encode(exec.call_arena, input.bytes);
}

pub fn atob(_: *const WorkerGlobalScope, input: JS.String.OneByte, exec: *JS.Execution) !JS.String.OneByte {
    const bytes = try @import("encoding/base64.zig").decode(exec.call_arena, input.bytes);
    return .{ .bytes = bytes };
}

pub fn structuredClone(_: *const WorkerGlobalScope, value: JS.Value) !JS.Value {
    return value.structuredClone();
}

pub fn notifyPromiseRejection(self: *WorkerGlobalScope, no_handler: bool, promise: JS.Promise, reason: ?JS.Value) !void {
    if (comptime IS_DEBUG) {
        log.debug(.js, "unhandled rejection", .{
            .target = "worker",
            .value = reason,
            .stack = promise.local.stackTrace() catch |err| @errorName(err) orelse "???",
        });
    } else {
        log.warn(.js, "unhandled rejection", .{
            .target = "worker",
            .value = reason,
        });
    }

    if (no_handler) {
        const message = if (reason) |value| value.toStringSlice() catch "Unhandled promise rejection" else "Unhandled promise rejection";
        const stack = promise.local.stackTrace() catch null;
        self._page.session.browser.observeJavaScriptError("unhandled-rejection", message, self.url, 0, 0, self._frame_id, self._loader_id, stack);
    }

    const event_name, const attribute_callback = blk: {
        if (no_handler) {
            break :blk .{ "unhandledrejection", self._on_unhandled_rejection };
        }
        break :blk .{ "rejectionhandled", self._on_rejection_handled };
    };

    const target = self.asEventTarget();
    if (self._event_manager.hasDirectListeners(target, event_name, attribute_callback)) {
        const event = (try @import("event/PromiseRejectionEvent.zig").init(event_name, .{
            .reason = if (reason) |r| try r.temp() else null,
            .promise = try promise.temp(),
        }, self._page)).asEvent();
        // Ignore any errors from dispatching the event to avoid crashing
        self.dispatch(target, event, attribute_callback, .{}) catch |err| {
            log.warn(.js, "failed to dispatch unhandledrejection event", .{ .err = err });
        };
    }
}

pub fn close(self: *WorkerGlobalScope) void {
    // TOOD: we should also stop new tasks from being scheduled
    self.js.scheduler.reset();
    self._closed = true;
}

fn _debug_nextMessageId(self: *WorkerGlobalScope) u64 {
    const id = self._debug_next_message_id;
    self._debug_next_message_id += 1;
    return id;
}

fn _debug_schedulerQueueLen(_: *WorkerGlobalScope, scheduler: anytype) usize {
    _ = scheduler;
    return 0;
}

const ImportScriptCallerSite = struct {
    filename: []const u8 = "",
    line: u32 = 0,
    col: u32 = 0,
};

const ImportedScript = struct {
    body: []const u8,
    script_url: [:0]const u8,
};

pub fn importScripts(self: *WorkerGlobalScope, urls: []const [:0]const u8) !void {
    if (urls.len > 0) {
        log.warn(.http, "importScripts begin", .{
            .worker_url = self.url,
            .count = urls.len,
            .first = urls[0],
        });
    }

    const session = self._session;
    const arena = try session.getArena(.large, "importScript");
    defer session.releaseArena(arena);

    const caller_site = try captureImportScriptsCallerSite(self, arena);

    for (urls) |url| {
        defer session.arena_pool.resetRetain(arena);
        try self.importScript(arena, url, caller_site);
    }
}

pub fn decodeDataUrlJavaScript(allocator: Allocator, url: []const u8) ![]const u8 {
    const media_type = importScriptDataUrlMediaType(url) orelse return error.NetworkError;
    if (!Mime.isImportScriptsJavaScriptMime(media_type)) return error.NetworkError;
    return decodeImportScriptDataUrlBody(allocator, url);
}

fn importScriptDataUrlMediaType(url: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, url, "data:")) return null;
    const rest = url[5..];
    const comma = std.mem.indexOfScalar(u8, rest, ',') orelse return null;
    if (comma == 0) return "text/plain";
    return rest[0..comma];
}

fn decodeImportScriptDataUrlBody(allocator: Allocator, url: []const u8) ![]const u8 {
    const rest = url[5..];
    const comma = std.mem.indexOfScalar(u8, rest, ',') orelse return error.NetworkError;
    const data = rest[comma + 1 ..];
    const metadata = rest[0..comma];
    if (std.mem.endsWith(u8, metadata, ";base64")) {
        var stripped = try std.ArrayList(u8).initCapacity(allocator, data.len);
        defer stripped.deinit(allocator);
        for (data) |c| {
            if (!std.ascii.isWhitespace(c)) try stripped.append(allocator, c);
        }
        const trimmed = std.mem.trimEnd(u8, stripped.items, "=");
        if (trimmed.len % 4 == 1) return error.NetworkError;
        const decoded_size = std.base64.standard_no_pad.Decoder.calcSizeForSlice(trimmed) catch return error.NetworkError;
        const buffer = try allocator.alloc(u8, decoded_size);
        std.base64.standard_no_pad.Decoder.decode(buffer, trimmed) catch return error.NetworkError;
        return buffer;
    }
    return URL.unescape(allocator, data);
}

fn importScriptBody(self: *WorkerGlobalScope, arena: Allocator, resolved_url: [:0]const u8) !ImportedScript {
    if (std.mem.startsWith(u8, resolved_url, "data:")) {
        const media_type = importScriptDataUrlMediaType(resolved_url) orelse return error.NetworkError;
        if (!Mime.isImportScriptsJavaScriptMime(media_type)) return error.NetworkError;
        return .{
            .body = try decodeImportScriptDataUrlBody(arena, resolved_url),
            .script_url = resolved_url,
        };
    }
    if (std.mem.startsWith(u8, resolved_url, "blob:")) {
        const blob = self.lookupBlobUrlFuzzy(resolved_url) orelse return error.NetworkError;
        if (!Mime.isImportScriptsJavaScriptMime(blob.getType())) return error.NetworkError;
        return .{
            .body = blob._slice,
            .script_url = resolved_url,
        };
    }

    const session = self._session;
    const http_client = &session.browser.http_client;

    var headers = try http_client.newHeaders();
    try self.headersForRequest(&headers, .{
        .request_url = resolved_url,
        .resource_type = .script,
        .include_origin_header = false,
    });

    const response = http_client.syncRequest(arena, .{
        .url = resolved_url,
        .method = .GET,
        .frame_id = self._frame_id,
        .attribution_frame = self._worker._frame,
        .loader_id = self._loader_id,
        .headers = headers,
        .cookie_jar = &session.cookie_jar,
        .cookie_origin = self.url,
        .top_level_cookie_url = self.url,
        .resource_type = .script,
        .notification = session.notification,
    }) catch {
        return error.NetworkError;
    };

    if (response.status != 200) return error.NetworkError;
    if (response.content_type) |ct| {
        if (!Mime.isImportScriptsJavaScriptMime(ct)) return error.NetworkError;
    } else {
        return error.NetworkError;
    }
    const script_url = response.final_url orelse resolved_url;
    return .{
        .body = response.body.items,
        .script_url = script_url,
    };
}

fn captureImportScriptsCallerSite(self: *WorkerGlobalScope, arena: Allocator) !ImportScriptCallerSite {
    var ls: JS.Local.Scope = undefined;
    self.js.localScope(&ls);
    defer ls.deinit();

    const isolate = ls.local.isolate;
    const stack_trace_handle = v8.v8__StackTrace__CurrentStackTrace__STATIC(isolate.handle, 12) orelse
        return .{};
    const frame_count = v8.v8__StackTrace__GetFrameCount(stack_trace_handle);

    var i: u32 = 0;
    while (i < frame_count) : (i += 1) {
        const frame_handle = v8.v8__StackTrace__GetFrame(stack_trace_handle, isolate.handle, i) orelse continue;
        if (!v8.v8__StackFrame__IsUserJavaScript(frame_handle)) continue;

        const script_handle = v8.v8__StackFrame__GetScriptNameOrSourceURL(frame_handle) orelse continue;
        const script_val = JS.Value{ .local = &ls.local, .handle = script_handle };
        const script_name = script_val.toStringSlice() catch continue;
        if (script_name.len == 0) continue;
        if (std.mem.indexOf(u8, script_name, "worker-importscripts-mime-shim") != null) continue;
        if (std.mem.indexOf(u8, script_name, "worker-rethrow-shim") != null) continue;
        if (std.mem.indexOf(u8, script_name, "worker-domexception-throw-shim") != null) continue;

        const line_raw = v8.v8__StackFrame__GetLineNumber(frame_handle);
        const col_raw = v8.v8__StackFrame__GetColumn(frame_handle);
        return .{
            .filename = try arena.dupe(u8, script_name),
            .line = if (line_raw < 0) 0 else @intCast(line_raw),
            .col = if (col_raw < 0) 0 else @intCast(col_raw),
        };
    }
    return .{};
}

fn isScriptCrossOrigin(self: *const WorkerGlobalScope, arena: Allocator, script_url: [:0]const u8) bool {
    if (std.mem.startsWith(u8, script_url, "data:") or std.mem.startsWith(u8, script_url, "blob:")) {
        return false;
    }
    const worker_origin = self.origin orelse blk: {
        const o = URL.getOrigin(arena, self.url) catch return true;
        break :blk o orelse return true;
    };
    const script_origin = blk: {
        const o = URL.getOrigin(arena, script_url) catch return true;
        break :blk o orelse return true;
    };
    return !std.mem.eql(u8, worker_origin, script_origin);
}

fn tryCatchMessageSite(tc: *const JS.TryCatch, local: *const JS.Local, fallback: ImportScriptCallerSite) struct {
    filename: []const u8,
    line: u32,
    col: u32,
} {
    const msg_handle = v8.v8__TryCatch__Message(&tc.handle) orelse {
        return .{
            .filename = fallback.filename,
            .line = fallback.line,
            .col = fallback.col,
        };
    };

    const filename = blk: {
        const resource_handle = v8.v8__Message__GetScriptResourceName(msg_handle) orelse break :blk fallback.filename;
        const name_val = JS.Value{ .local = local, .handle = resource_handle };
        if (name_val.toStringSlice() catch null) |s| {
            if (s.len > 0) break :blk s;
        }
        break :blk fallback.filename;
    };

    const line_raw = v8.v8__Message__GetLineNumber(msg_handle, local.handle);
    const col_raw = v8.v8__Message__GetStartColumn(msg_handle);
    return .{
        .filename = filename,
        .line = if (line_raw < 0) fallback.line else @intCast(line_raw),
        .col = if (col_raw < 0) fallback.col else @intCast(col_raw),
    };
}

fn stashImportScriptError(local: *const JS.Local, err: JS.Value) void {
    const global_handle = v8.v8__Context__Global(local.handle).?;
    const global = JS.Object{ .local = local, .handle = global_handle };
    _ = global.set("__kokoImportScriptError", err, .{}) catch {};
}

fn stashImportScriptNetworkError(local: *const JS.Local) void {
    const dom_ex = DOMException.fromError(error.NetworkError).?;
    const dom_val = local.zigValueToJs(dom_ex, .{}) catch return;
    stashImportScriptError(local, dom_val);
}

fn compileAndRunImportedScript(local: *const JS.Local, src: []const u8, name: []const u8) !JS.Value {
    const script_name = local.isolate.initStringHandle(name);
    const script_source = local.isolate.initStringHandle(src);

    var origin: v8.ScriptOrigin = undefined;
    v8.v8__ScriptOrigin__CONSTRUCT(&origin, @ptrCast(script_name));

    var script_comp_source: v8.ScriptCompilerSource = undefined;
    v8.v8__ScriptCompiler__Source__CONSTRUCT2(script_source, &origin, null, &script_comp_source);
    defer v8.v8__ScriptCompiler__Source__DESTRUCT(&script_comp_source);

    const v8_script = v8.v8__ScriptCompiler__Compile(
        local.handle,
        &script_comp_source,
        v8.kNoCompileOptions,
        v8.kNoCacheNoReason,
    ) orelse return error.JsException;

    const result = v8.v8__Script__Run(v8_script, local.handle) orelse return error.JsException;
    return .{ .local = local, .handle = result };
}

fn handleImportScriptEvalError(
    self: *WorkerGlobalScope,
    arena: Allocator,
    tc: *const JS.TryCatch,
    local: *const JS.Local,
    script_url: [:0]const u8,
    caller_site: ImportScriptCallerSite,
) !void {
    const ex = tc.exceptionValue() orelse return error.JsException;

    const muted = isScriptCrossOrigin(self, arena, script_url);
    const script_site = tryCatchMessageSite(tc, local, caller_site);
    const message = ex.toStringSlice() catch "Error";

    if (muted) {
        const dom_ex = DOMException.fromError(error.NetworkError).?;
        const dom_val = try local.zigValueToJs(dom_ex, .{});

        try self.reportUncaughtException(
            dom_val,
            message,
            caller_site.filename,
            caller_site.line,
            caller_site.col,
        );
        stashImportScriptError(local, dom_val);
        return;
    }

    try self.reportUncaughtException(
        ex,
        message,
        script_site.filename,
        script_site.line,
        script_site.col,
    );
    stashImportScriptError(local, ex);
}

fn evalImportedScript(
    self: *WorkerGlobalScope,
    arena: Allocator,
    imported: ImportedScript,
    caller_site: ImportScriptCallerSite,
) !void {
    var ls: JS.Local.Scope = undefined;
    self.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: JS.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    _ = compileAndRunImportedScript(&ls.local, imported.body, imported.script_url) catch |err| {
        if (try_catch.hasCaught()) {
            try handleImportScriptEvalError(self, arena, &try_catch, &ls.local, imported.script_url, caller_site);
            return;
        }
        log.err(.browser, "importScript eval failed", .{
            .worker_url = self.url,
            .url = imported.script_url,
            .body_len = imported.body.len,
            .err = err,
        });
        return err;
    };

    if (self._worker._bootstrap_complete) {
        Worker.pumpBootstrapMessaging(&self.js.execution);
    }
    try self._worker._frame.scheduleDeferredMacrotaskPump(0);
}

fn importScript(self: *WorkerGlobalScope, arena: Allocator, url: [:0]const u8, caller_site: ImportScriptCallerSite) !void {
    const resolved_url: [:0]const u8 = if (std.mem.startsWith(u8, url, "blob:") or std.mem.startsWith(u8, url, "data:"))
        try arena.dupeZ(u8, url)
    else
        try URL.resolve(arena, self.url, url, .{});

    log.warn(.http, "importScript fetch", .{
        .worker_url = self.url,
        .url = url,
        .resolved = resolved_url,
    });

    const imported = importScriptBody(self, arena, resolved_url) catch |err| {
        log.err(.http, "importScript NetworkError", .{
            .worker_url = self.url,
            .url = url,
            .resolved = resolved_url,
            .err = err,
        });
        var ls: JS.Local.Scope = undefined;
        self.js.localScope(&ls);
        defer ls.deinit();
        stashImportScriptNetworkError(&ls.local);
        return;
    };

    try self.evalImportedScript(arena, imported, caller_site);

    log.warn(.http, "importScript ok", .{
        .worker_url = self.url,
        .resolved = resolved_url,
        .body_len = imported.body.len,
    });
}

pub fn reportError(self: *WorkerGlobalScope, err: JS.Value) !void {
    try self.reportUncaughtException(
        err,
        err.toStringSlice() catch "Unknown error",
        self.url,
        0,
        0,
    );
}

pub fn reportUncaughtException(
    self: *WorkerGlobalScope,
    err: JS.Value,
    message: []const u8,
    filename: []const u8,
    line: u32,
    col: u32,
) !void {
    materializeOnError(self);

    const error_event = try ErrorEvent.initTrusted(comptime .wrap("error"), .{
        .@"error" = try err.temp(),
        .message = message,
        .filename = filename,
        .lineno = line,
        .colno = col,
        .bubbles = false,
        .cancelable = true,
    }, self._page);

    // Invoke onerror callback if set (per WHATWG spec, this is called
    // with 5 arguments: message, source, lineno, colno, error)
    // If it returns true, the event is cancelled.
    var prevent_default = false;
    if (self._on_error) |on_error| {
        var ls: JS.Local.Scope = undefined;
        self.js.localScope(&ls);
        defer ls.deinit();

        const local_func = ls.toLocal(on_error);
        const result = EventManagerBase.invokeCallback(&ls.local, ls.local.ctx, local_func, JS.Value, .{
            error_event._message,
            error_event._filename,
            error_event._line_number,
            error_event._column_number,
            err,
        }, "worker.onerror");

        // Per spec: returning true from onerror cancels the event
        if (result) |r| {
            prevent_default = r.isTrue();
        }
    }

    const event = error_event.asEvent();
    event._prevent_default = prevent_default;
    // Pass null as handler: onerror was already called above with 5 args.
    // We still dispatch so that addEventListener('error', ...) listeners fire.
    try self.dispatch(self.asEventTarget(), event, null, .{});

    if (comptime builtin.is_test == false) {
        if (!event._prevent_default) {
            log.warn(.js, "worker.uncaughtException", .{
                .message = error_event._message,
                .filename = error_event._filename,
                .line_number = error_event._line_number,
                .column_number = error_event._column_number,
            });
        }
    }
}

pub fn fetch(_: *const WorkerGlobalScope, input: Fetch.Input, options: ?Fetch.InitOpts, exec: *const JS.Execution) !JS.Promise {
    return Fetch.init(input, options, exec);
}

pub fn queueMicrotask(self: *WorkerGlobalScope, cb: JS.Function) void {
    self.js.queueMicrotaskFunc(cb);
}

pub fn setTimeout(self: *WorkerGlobalScope, handler: Timers.LegacyHandler, delay_ms: ?u32, params: []JS.Value.Temp, exec: *JS.Execution) !u32 {
    const cb = try handler.resolve(exec);
    return self._timers.schedule(exec, cb, delay_ms orelse 0, .{
        .repeat = false,
        .params = params,
        .name = "worker.setTimeout",
    });
}

pub fn clearTimeout(self: *WorkerGlobalScope, id: u32) void {
    self._timers.clear(id);
}

pub fn setInterval(self: *WorkerGlobalScope, handler: Timers.LegacyHandler, delay_ms: ?u32, params: []JS.Value.Temp, exec: *JS.Execution) !u32 {
    const cb = try handler.resolve(exec);
    return self._timers.schedule(exec, cb, delay_ms orelse 0, .{
        .repeat = true,
        .params = params,
        .name = "worker.setInterval",
    });
}

pub fn clearInterval(self: *WorkerGlobalScope, id: u32) void {
    self._timers.clear(id);
}

pub const FunctionSetter = union(enum) {
    func: JS.Function.Global,
    anything: JS.Value,
};

fn getFunctionFromSetter(setter_: ?FunctionSetter) ?JS.Function.Global {
    const setter = setter_ orelse return null;
    return switch (setter) {
        .func => |func| func,
        .anything => null,
    };
}

const PendingInboundMessage = struct {
    message_id: u64,
    data: JS.Value.Temp,
    ports: []const *MessagePort,
};

const ReceiveMessageCallback = struct {
    data: ?JS.Value.Temp,
    ports: []const *MessagePort,
    arena: Allocator,
    worker_scope: *WorkerGlobalScope,
    session: *Session,
    message_id: u64,
    task_owner: RealmLifecycleKernel.TaskOwner,

    fn cancelled(ctx: *anyopaque) void {
        const self: *ReceiveMessageCallback = @ptrCast(@alignCast(ctx));
        if (self.data) |d| d.release();
        self.deinit();
    }

    fn deinit(self: *ReceiveMessageCallback) void {
        self.session.releaseArena(self.arena);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ReceiveMessageCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();

        const worker_scope = self.worker_scope;
        const worker = worker_scope._worker;
        if (!worker.beginTask()) {
            if (self.data) |d| d.release();
            self.data = null;
            return null;
        }
        defer worker.endTask();
        const exec = &worker_scope.js.execution;
        if (exec.isTaskOwnerStale(self.task_owner) or
            exec.realmState() != .active or
            !exec.canEnterJs(.strict_active))
        {
            if (self.data) |d| d.release();
            self.data = null;
            return null;
        }
        const target = worker_scope.asEventTarget();

        var ls: JS.Local.Scope = undefined;
        if (!worker_scope.js.tryLocalScope(&ls)) {
            if (self.data) |d| d.release();
            self.data = null;
            return null;
        }
        defer ls.deinit();
        worker_scope.syncScriptHandlerSlotsFromLocal(&ls.local);

        if (comptime IS_DEBUG) {
            log.info(.browser, "worker dispatch inbound message", .{
                .worker_id = worker_scope._frame_id,
                .message_id = self.message_id,
                .queue_len = worker_scope._debug_schedulerQueueLen(worker_scope.js.scheduler),
            });
        }

        // If data is null, structured clone failed - fire messageerror
        if (self.data == null) {
            const on_messageerror = if (worker_scope._on_messageerror) |handler|
                handler.local(&ls.local)
            else
                null;
            if (!worker_scope._event_manager.hasDirectListeners(target, "messageerror", on_messageerror)) {
                return null;
            }
            const event = (try MessageEvent.initTrusted(comptime .wrap("messageerror"), .{
                .bubbles = false,
                .cancelable = false,
            }, worker_scope._page)).asEvent();
            try worker_scope.dispatch(target, event, on_messageerror, .{});
            return null;
        }

        const on_message = if (worker_scope._on_message) |handler|
            handler.local(&ls.local)
        else
            null;

        // Queue until onmessage / addEventListener is registered (reCAPTCHA worker setup).
        if (!worker_scope._event_manager.hasDirectListeners(target, "message", on_message)) {
            const ports_copy = try worker_scope.arena.dupe(*MessagePort, self.ports);
            try worker_scope._pending_undelivered.append(worker_scope.arena, .{
                .message_id = self.message_id,
                .data = self.data.?,
                .ports = ports_copy,
            });
            return null;
        }

        const event = (try MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = .{ .value = self.data.? },
            .ports = self.ports,
            .bubbles = false,
            .cancelable = false,
        }, worker_scope._page)).asEvent();
        try worker_scope.dispatch(target, event, on_message, .{});
        // This callback already runs as a worker macrotask. Pumping the same
        // scheduler here recursively enters the next message handler before
        // the current V8 callback and its event objects have unwound. The
        // outer scheduler loop owns FIFO continuation after this task returns.
        const frame = worker_scope._worker._frame;
        try frame.scheduleDeferredMacrotaskPump(0);
        try frame.scheduleDeferredMacrotaskPump(20);
        return null;
    }
};

pub const JsApi = struct {
    pub const bridge = JS.Bridge(WorkerGlobalScope);

    pub const Meta = struct {
        pub const name = "WorkerGlobalScope";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const self = bridge.accessor(WorkerGlobalScope.getSelf, null, .{});
    pub const console = bridge.accessor(WorkerGlobalScope.getConsole, null, .{});
    pub const crypto = bridge.accessor(WorkerGlobalScope.getCrypto, null, .{});
    pub const performance = bridge.accessor(WorkerGlobalScope.getPerformance, null, .{});
    pub const navigator = bridge.accessor(WorkerGlobalScope.getNavigator, null, .{});
    pub const location = bridge.accessor(WorkerGlobalScope.getLocation, null, .{ .deletable = false });

    pub const onerror = bridge.accessor(WorkerGlobalScope.getOnError, WorkerGlobalScope.setOnError, .{});
    pub const onrejectionhandled = bridge.accessor(WorkerGlobalScope.getOnRejectionHandled, WorkerGlobalScope.setOnRejectionHandled, .{});
    pub const onunhandledrejection = bridge.accessor(WorkerGlobalScope.getOnUnhandledRejection, WorkerGlobalScope.setOnUnhandledRejection, .{});

    pub const btoa = bridge.function(WorkerGlobalScope.btoa, .{ .dom_exception = true });
    pub const atob = bridge.function(WorkerGlobalScope.atob, .{ .dom_exception = true });
    pub const structuredClone = bridge.function(WorkerGlobalScope.structuredClone, .{ .dom_exception = true });
    pub const postMessage = bridge.function(WorkerGlobalScope.postMessage, .{ .dom_exception = true });
    pub const reportError = bridge.function(WorkerGlobalScope.reportError, .{});
    pub const close = bridge.function(WorkerGlobalScope.close, .{});
    pub const fetch = bridge.function(WorkerGlobalScope.fetch, .{});
    pub const importScripts = bridge.function(WorkerGlobalScope.importScripts, .{ .dom_exception = true });
    pub const queueMicrotask = bridge.function(WorkerGlobalScope.queueMicrotask, .{});
    pub const setTimeout = bridge.function(WorkerGlobalScope.setTimeout, .{});
    pub const clearTimeout = bridge.function(WorkerGlobalScope.clearTimeout, .{});
    pub const setInterval = bridge.function(WorkerGlobalScope.setInterval, .{});
    pub const clearInterval = bridge.function(WorkerGlobalScope.clearInterval, .{});

    pub const onmessage = bridge.accessor(WorkerGlobalScope.getOnMessage, WorkerGlobalScope.setOnMessage, .{});
    pub const onmessageerror = bridge.accessor(WorkerGlobalScope.getOnMessageError, WorkerGlobalScope.setOnMessageError, .{});

    // Return false since workers don't have secure-context-only APIs
    pub const isSecureContext = bridge.property(false, .{ .template = false });
};
