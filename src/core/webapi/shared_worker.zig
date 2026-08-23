//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.

const std = @import("std");

const js = @import("../js/js.zig");
const URL = @import("../browser/URL.zig");
const Frame = @import("../browser/Frame.zig");
const Session = @import("../browser/Session.zig");

const EventTarget = @import("EventTarget.zig");
const Event = @import("Event.zig");
const MessagePort = @import("MessagePort.zig");
const Worker = @import("Worker.zig");
const WorkerGlobalScope = @import("WorkerGlobalScope.zig");

const log = @import("../../support/log.zig");
const Allocator = std.mem.Allocator;

pub const SharedWorker = @This();

_proto: *EventTarget,
_port: ?*MessagePort = null,
_runtime: ?*SharedWorkerRuntime = null,
_on_error: ?js.Function.Global = null,
_pending_error: bool = false,
_error_frame: ?*Frame = null,

pub const SharedWorkerOptions = struct {
    type: ?Worker.WorkerType = null,
    credentials: ?Worker.WorkerCredentials = null,
    extended_lifetime: ?bool = null,
    extendedLifetime: ?bool = null,
};

pub fn registerTypes() []const type {
    return &.{SharedWorker};
}

pub fn constructor(
    url: []const u8,
    name: []const u8,
    options: ?SharedWorkerOptions,
    frame: *Frame,
) !*SharedWorker {
    const exec = &frame.js.execution;
    const session = frame._session;

    if (!URL.canParse(url, exec.url.*)) {
        return error.SyntaxError;
    }

    const resolved_url = try URL.resolve(frame.arena, exec.url.*, url, .{ .encoding = frame.charset });
    const normalized = normalizeOptions(options);

    const identity_key = try makeIdentityKey(frame.arena, frame.origin, resolved_url, name);
    const runtime = try session.getOrCreateSharedWorkerRuntime(.{
        .frame = frame,
        .resolved_url = resolved_url,
        .name = name,
        .identity_key = identity_key,
        .options = normalized,
    });

    const self = try frame._factory.eventTarget(SharedWorker{
        ._proto = undefined,
        ._port = null,
        ._runtime = runtime,
        ._on_error = null,
    });

    if (!runtime.optionsMatch(normalized)) {
        self._pending_error = true;
        self._error_frame = frame;
        scheduleDeferredMismatchError(self) catch |err| {
            log.warn(.browser, "SharedWorker.scheduleDeferredMismatchError", .{ .err = err });
        };
        return self;
    }

    const page_port = try self.getPort(exec);
    const worker_port = try MessagePort.init(&runtime.workerScope().js.execution);
    MessagePort.entangle(page_port, worker_port);
    page_port.start() catch |err| {
        log.warn(.browser, "SharedWorker page port start", .{ .err = err });
    };

    try runtime.queueConnect(self, worker_port, frame);
    return self;
}

fn normalizeOptions(options: ?SharedWorkerOptions) SharedWorkerRuntime.NormalizedOptions {
    const opts = options orelse SharedWorkerOptions{};
    const script_type = opts.type orelse .classic;
    // WorkerSharedOptions credentials default is "same-origin" for identity.
    // Classic fetch still uses `include` in Worker.initSharedHost.
    const credentials: Worker.WorkerCredentials = opts.credentials orelse .@"same-origin";
    return .{
        .script_type = script_type,
        .credentials = credentials,
        .extended_lifetime = opts.extended_lifetime orelse opts.extendedLifetime orelse false,
    };
}

fn makeIdentityKey(
    arena: Allocator,
    origin: ?[]const u8,
    resolved_url: [:0]const u8,
    name: []const u8,
) ![]const u8 {
    const origin_str: []const u8 = origin orelse
        (try URL.getOrigin(arena, resolved_url)) orelse resolved_url;
    return try std.fmt.allocPrint(arena, "{s}\x1e{s}\x1e{s}", .{ origin_str, resolved_url, name });
}

pub fn getPort(self: *SharedWorker, exec: *const js.Execution) !*MessagePort {
    if (self._port) |p| return p;
    const p = try MessagePort.init(exec);
    self._port = p;
    return p;
}

pub fn getOnError(self: *const SharedWorker) ?js.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *SharedWorker, setter: ?FunctionSetter) void {
    self._on_error = getFunctionFromSetter(setter);
    tryFlushPendingError(self);
}

fn tryFlushPendingError(self: *SharedWorker) void {
    if (!self._pending_error) return;
    const frame = self._error_frame orelse return;
    if (self._on_error == null) return;
    self._pending_error = false;
    fireErrorEvent(self, frame);
}

fn scheduleDeferredMismatchError(self: *SharedWorker) !void {
    const frame = self._error_frame orelse return;
    const arena = try frame.getArena(.tiny, "SharedWorker.deferMismatchError");
    errdefer frame.releaseArena(arena);

    const callback = try arena.create(DeferMismatchErrorCallback);
    callback.* = .{ .worker = self, .arena = arena };

    try frame.js.scheduler.add(callback, DeferMismatchErrorCallback.run, 0, .{
        .name = "SharedWorker.deferMismatchError",
        .low_priority = false,
        .finalizer = DeferMismatchErrorCallback.cancelled,
    });
}

const DeferMismatchErrorCallback = struct {
    worker: *SharedWorker,
    arena: Allocator,

    fn cancelled(ctx: *anyopaque) void {
        const self: *DeferMismatchErrorCallback = @ptrCast(@alignCast(ctx));
        if (self.worker._error_frame) |frame| {
            frame._session.releaseArena(self.arena);
        }
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DeferMismatchErrorCallback = @ptrCast(@alignCast(ctx));
        defer if (self.worker._error_frame) |frame| {
            frame._session.releaseArena(self.arena);
        };
        tryFlushPendingError(self.worker);
        return null;
    }
};

pub fn fireErrorEvent(self: *SharedWorker, frame: *Frame) void {
    const target = self._proto;
    const on_error = self._on_error;
    if (!frame._event_manager.hasDirectListeners(target, "error", on_error)) {
        // WPT assigns worker.onerror after construction; queue the error until then.
        self._pending_error = true;
        self._error_frame = frame;
        scheduleDeferredMismatchError(self) catch |err| {
            log.warn(.browser, "SharedWorker.scheduleDeferredMismatchError", .{ .err = err });
        };
        return;
    }
    const error_event = Event.initTrusted(comptime .wrap("error"), .{
        .bubbles = false,
        .cancelable = true,
    }, frame._page) catch |err| {
        log.warn(.browser, "SharedWorker.fireErrorEvent", .{ .err = err });
        return;
    };
    frame._event_manager.dispatchDirect(target, error_event, on_error, .{
        .context = "SharedWorker.onerror",
    }) catch |err| {
        log.warn(.browser, "SharedWorker.fireErrorEvent dispatch", .{ .err = err });
        return;
    };
    self._pending_error = false;
}

const FunctionSetter = union(enum) {
    func: js.Function.Global,
    anything: js.Value,
};

fn getFunctionFromSetter(setter_: ?FunctionSetter) ?js.Function.Global {
    const setter = setter_ orelse return null;
    return switch (setter) {
        .func => |func| func,
        .anything => null,
    };
}

pub const SharedWorkerRuntime = struct {
    const PendingConnect = struct {
        client: *SharedWorker,
        worker_port: *MessagePort,
    };

    arena: Allocator,
    session: *Session,
    /// The current worker realm is built from this Page's factory, origin
    /// registry, and lifecycle-owned web-platform state. Until shared-worker
    /// realms have a fully session-owned environment, the runtime must be
    /// destroyed before this Page.
    owner_page: *@import("../browser/Page.zig"),
    identity_key: []const u8,
    resolved_url: [:0]const u8,
    name: []const u8,
    options: NormalizedOptions,
    host: *Worker,
    state: State = .loading,
    pending_connects: std.ArrayList(PendingConnect) = .empty,
    clients: std.ArrayList(*SharedWorker) = .empty,

    pub const NormalizedOptions = struct {
        script_type: Worker.WorkerType = .classic,
        credentials: Worker.WorkerCredentials = .@"same-origin",
        extended_lifetime: bool = false,
    };

    pub const State = enum {
        loading,
        ready,
        failed,
    };

    pub const CreateParams = struct {
        frame: *Frame,
        resolved_url: [:0]const u8,
        name: []const u8,
        identity_key: []const u8,
        options: NormalizedOptions,
    };

    pub fn create(session: *Session, params: CreateParams) !*SharedWorkerRuntime {
        const arena = try session.getArena(.large, "SharedWorkerRuntime");
        errdefer session.releaseArena(arena);

        const identity_key = try arena.dupe(u8, params.identity_key);
        const resolved_url = try arena.dupeZ(u8, params.resolved_url);
        const name = try arena.dupe(u8, params.name);

        const self = try arena.create(SharedWorkerRuntime);
        self.* = .{
            .arena = arena,
            .session = session,
            .owner_page = params.frame._page,
            .identity_key = identity_key,
            .resolved_url = resolved_url,
            .name = name,
            .options = params.options,
            .host = undefined,
        };

        const worker_options = Worker.WorkerOptions{
            .type = params.options.script_type,
            .credentials = params.options.credentials,
        };
        self.host = try Worker.initSharedHost(
            resolved_url,
            worker_options,
            params.frame,
            onSharedScriptReady,
            onSharedScriptError,
        );
        self.host._shared_runtime = self;
        self.host._worker_scope._name = name;
        return self;
    }

    pub fn workerScope(self: *SharedWorkerRuntime) *WorkerGlobalScope {
        return self.host._worker_scope;
    }

    pub fn optionsMatch(self: *const SharedWorkerRuntime, opts: NormalizedOptions) bool {
        return self.options.script_type == opts.script_type and
            self.options.credentials == opts.credentials and
            self.options.extended_lifetime == opts.extended_lifetime;
    }

    pub fn queueConnect(self: *SharedWorkerRuntime, client: *SharedWorker, worker_port: *MessagePort, frame: *Frame) !void {
        try self.clients.append(self.arena, client);

        switch (self.state) {
            .loading => try self.pending_connects.append(self.arena, .{
                .client = client,
                .worker_port = worker_port,
            }),
            .ready => try self.dispatchConnect(worker_port, .{}),
            .failed => fireErrorEvent(client, frame),
        }
    }

    const DispatchConnectOpts = struct {
        /// When true, frame scheduler pumping is deferred to drainBootstrapSchedulers
        /// so connect dispatch stays inside the worker's entered local scope.
        defer_frame_pump: bool = false,
    };

    fn dispatchConnect(self: *SharedWorkerRuntime, worker_port: *MessagePort, opts: DispatchConnectOpts) !void {
        const wgs = self.workerScope();
        const frame = self.host._frame;
        try wgs.dispatchConnectEvent(worker_port);
        try wgs.js.scheduler.run();
        if (!opts.defer_frame_pump) {
            try frame.js.scheduler.run();
            frame.scheduleDeferredMacrotaskPump(0) catch |err| {
                log.warn(.browser, "SharedWorker connect pump", .{ .err = err });
            };
        }
    }

    fn flushPendingConnects(self: *SharedWorkerRuntime, opts: DispatchConnectOpts) !void {
        for (self.pending_connects.items) |pending| {
            try self.dispatchConnect(pending.worker_port, opts);
        }
        self.pending_connects.clearRetainingCapacity();
    }

    fn onSharedScriptReady(worker: *Worker) void {
        const runtime: *SharedWorkerRuntime = @ptrCast(@alignCast(worker._shared_runtime.?));
        runtime.state = .ready;
        runtime.flushPendingConnects(.{ .defer_frame_pump = true }) catch |err| {
            log.warn(.browser, "SharedWorker.flushPendingConnects", .{ .err = err });
        };
    }

    fn onSharedScriptError(worker: *Worker, message: []const u8) void {
        const runtime: *SharedWorkerRuntime = @ptrCast(@alignCast(worker._shared_runtime.?));
        runtime.state = .failed;
        _ = message;
        const frame = worker._frame;
        for (runtime.clients.items) |client| {
            fireErrorEvent(client, frame);
        }
    }

    pub fn destroy(self: *SharedWorkerRuntime) void {
        self.session.unregisterSharedWorkerRuntime(self);
        self.host.deinitForSession(self.session);
        self.session.releaseArena(self.arena);
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(SharedWorker);
    pub const Meta = struct {
        pub const name = "SharedWorker";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const constructor = bridge.constructor(SharedWorker.constructor, .{ .dom_exception = true });
    pub const port = bridge.accessor(SharedWorker.getPort, null, .{});
    pub const onerror = bridge.accessor(SharedWorker.getOnError, SharedWorker.setOnError, .{});
};

const testing = @import("../../testing/testing.zig");
test "SharedWorker runtime host is session-owned, not frame-owned" {
    const session = testing.test_session;
    const runtime_count_before = session._shared_workers.count();
    const frame = try testing.pageTest("regression/shared_worker_ownership.html", .{});

    try std.testing.expectEqual(@as(usize, 0), frame.workers.items.len);
    try std.testing.expectEqual(runtime_count_before + 1, session._shared_workers.count());
    session.removePage();
    try std.testing.expectEqual(runtime_count_before, session._shared_workers.count());
}
