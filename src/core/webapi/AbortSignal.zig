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

const js = @import("../js/js.zig");
const Context = @import("../js/Context.zig");

const DOMException = @import("../dom/DOMException.zig");
const Event = @import("Event.zig");
const EventTarget = @import("EventTarget.zig");
const EventManagerBase = @import("../browser/EventManagerBase.zig");
const log = @import("../../support/log.zig");
const Execution = js.Execution;

const AbortSignal = @This();

var next_event_order: u32 = 0;

_proto: *EventTarget,
_aborted: bool = false,
_aborting: bool = false,
_abort_event_fired: bool = false,
_reason: Reason = .undefined,
_on_abort: ?js.Function.Global = null,
_event_order: u32 = 0,
_dependent: bool = false,
_sources: std.ArrayList(*AbortSignal) = .empty,
_dependents: std.ArrayList(*AbortSignal) = .empty,

pub fn init(exec: *const Execution) !*AbortSignal {
    const order = next_event_order;
    next_event_order +%= 1;
    return exec._factory.eventTarget(AbortSignal{
        ._proto = undefined,
        ._event_order = order,
    });
}

pub fn getAborted(self: *const AbortSignal) bool {
    return self._aborted;
}

pub fn getReason(self: *const AbortSignal) Reason {
    return self._reason;
}

pub fn getReasonJs(self: *const AbortSignal, exec: *const Execution) js.Value {
    const local = exec.context.local.?;
    return switch (self._reason) {
        .undefined => .{ .local = local, .handle = local.isolate.initUndefined() },
        .js_val => |v| local.toLocal(v),
        .string => |s| local.newString(s).toValue(),
        .null_reason => .{ .local = local, .handle = local.isolate.initNull() },
        .dom_exception => |dom_ex| local.zigValueToJs(dom_ex, .{}) catch .{
            .local = local,
            .handle = local.isolate.initUndefined(),
        },
    };
}

pub fn getOnAbort(self: *const AbortSignal) ?js.Function.Global {
    return self._on_abort;
}

pub fn setOnAbort(self: *AbortSignal, cb: ?js.Function.Global) !void {
    self._on_abort = cb;
}

pub fn asEventTarget(self: *AbortSignal) *EventTarget {
    return self._proto;
}

pub fn abort(self: *AbortSignal, reason_: ?Reason, exec: *const Execution) !void {
    if (self._aborted) return;
    const reason = try resolveAbortReason(reason_, exec);
    try self.abortWithReason(reason, exec);
}

fn resolveAbortReason(reason_: ?Reason, exec: *const Execution) !Reason {
    const local = exec.context.local.?;

    if (reason_) |reason| {
        return switch (reason) {
            .js_val => |js_val| blk: {
                const val = local.toLocal(js_val);
                if (val.isNull()) {
                    break :blk .{ .null_reason = {} };
                }
                if (val.isUndefined()) {
                    break :blk .{ .js_val = try createDefaultAbortError(exec) };
                }
                break :blk .{ .js_val = js_val };
            },
            .null_reason => .{ .null_reason = {} },
            .string => |str| .{ .string = try exec.dupeString(str) },
            .undefined => .{ .js_val = try createDefaultAbortError(exec) },
            .dom_exception => |dom_ex| .{ .dom_exception = dom_ex },
        };
    }
    return .{ .js_val = try createDefaultAbortError(exec) };
}

fn createDefaultAbortError(exec: *const Execution) !js.Value.Global {
    const local = exec.context.local.?;
    const dom_ex = try exec.arena.create(DOMException);
    dom_ex.* = DOMException.init("The operation was aborted.", "AbortError");
    const js_val = try local.zigValueToJs(dom_ex, .{});
    return try js_val.persist();
}

fn createTimeoutReason(exec: *const Execution) !Reason {
    const dom_ex = try exec.arena.create(DOMException);
    dom_ex.* = DOMException.init("The operation timed out.", "TimeoutError");
    return .{ .dom_exception = dom_ex };
}

fn copyReason(reason: Reason, exec: *const Execution) !Reason {
    return switch (reason) {
        .js_val => |js_val| .{ .js_val = js_val },
        .string => |str| .{ .string = try exec.dupeString(str) },
        .null_reason => .{ .null_reason = {} },
        .undefined => .undefined,
        .dom_exception => |dom_ex| .{ .dom_exception = dom_ex },
    };
}

fn markDependentsAborted(
    self: *AbortSignal,
    reason: Reason,
    exec: *const Execution,
    fire_list: *std.ArrayList(*AbortSignal),
) !void {
    for (self._dependents.items) |dependent| {
        if (dependent._aborted) continue;
        dependent._aborted = true;
        dependent._reason = try copyReason(reason, exec);
        try fire_list.append(exec.arena, dependent);
    }
}

fn abortWithReason(self: *AbortSignal, reason: Reason, exec: *const Execution) !void {
    if (self._aborted or self._aborting) return;

    self._aborting = true;
    defer self._aborting = false;

    self._aborted = true;
    self._reason = reason;

    var fire_list: std.ArrayList(*AbortSignal) = .empty;
    try markDependentsAborted(self, reason, exec, &fire_list);
    try fire_list.append(exec.arena, self);

    const SortCtx = struct {
        fn lessThan(_: void, a: *AbortSignal, b: *AbortSignal) bool {
            return a._event_order < b._event_order;
        }
    };
    std.mem.sort(*AbortSignal, fire_list.items, {}, SortCtx.lessThan);

    const base = eventManagerBase(exec);
    // Nested abort (e.g. testharness cleanup aborting during onabort) must defer
    // its whole fire pass. Top-level passes use dispatch_depth==0 and fire inline
    // so a multi-signal fire_list is not broken by per-signal deferral.
    if (base.dispatch_depth > 0) {
        for (fire_list.items) |signal| {
            removeSignalListeners(signal, exec);
            if (signal._abort_event_fired) continue;
            try base.deferred_abort_fires.append(base.arena, .{ .signal = signal, .exec = exec });
        }
    } else {
        for (fire_list.items) |signal| {
            removeSignalListeners(signal, exec);
            try fireAbortEvent(signal, exec);
        }
    }
}

fn eventManagerBase(exec: *const Execution) *EventManagerBase {
    return switch (exec.context.global) {
        .frame => |frame| &frame._event_manager.base,
        .worker => |wgs| &wgs._event_manager,
    };
}

pub fn flushDeferredAbortFires(base: *EventManagerBase) void {
    while (base.deferred_abort_fires.items.len > 0) {
        const item = base.deferred_abort_fires.items[0];
        _ = base.deferred_abort_fires.orderedRemove(0);
        fireAbortEvent(item.signal, item.exec) catch |err| {
            log.warn(.app, "deferred abort event", .{ .err = err });
        };
    }
}

fn removeSignalListeners(signal: *AbortSignal, exec: *const Execution) void {
    switch (exec.context.global) {
        .frame => |frame| frame._event_manager.removeSignalListeners(signal),
        .worker => |wgs| wgs._event_manager.removeSignalListeners(signal),
    }
}

const abort_dispatch_opts = EventManagerBase.DispatchDirectOptions{
    .context = "abort signal",
    // Burst/reentrant aborts (abort-signal-any) must not drain microtasks between
    // each signal; doing so while realm_state=initializing spams checkpoints and
    // has been observed to precede SIGSEGV under WPT load.
    .skip_post_dispatch_microtasks = true,
};

fn hasAbortObservers(signal: *AbortSignal, exec: *const Execution) bool {
    if (signal._on_abort != null) return true;
    const target = signal.asEventTarget();
    return switch (exec.context.global) {
        .frame => |frame| frame._event_manager.hasDirectListeners(target, "abort", null),
        .worker => |wgs| wgs.hasDirectListeners(target, "abort", null),
    };
}

fn fireAbortEvent(signal: *AbortSignal, exec: *const Execution) !void {
    if (signal._abort_event_fired) return;
    if (!hasAbortObservers(signal, exec)) {
        signal._abort_event_fired = true;
        return;
    }
    signal._abort_event_fired = true;

    const target = signal.asEventTarget();
    const on_abort = signal._on_abort;
    switch (exec.context.global) {
        .frame => |frame| {
            const event = try Event.initTrusted(comptime .wrap("abort"), .{}, frame._page);
            try frame._event_manager.dispatchDirect(target, event, on_abort, abort_dispatch_opts);
        },
        .worker => |wgs| {
            const event = try Event.initTrusted(comptime .wrap("abort"), .{}, wgs._page);
            try wgs.dispatch(target, event, on_abort, abort_dispatch_opts);
        },
    }
}

fn addSource(self: *AbortSignal, source: *AbortSignal, exec: *const Execution) !void {
    for (self._sources.items) |existing| {
        if (existing == source) return;
    }
    try self._sources.append(exec.arena, source);
}

fn addDependent(self: *AbortSignal, dependent: *AbortSignal, exec: *const Execution) !void {
    for (self._dependents.items) |existing| {
        if (existing == dependent) return;
    }
    try self._dependents.append(exec.arena, dependent);
}

fn linkToSourceSignals(
    composite: *AbortSignal,
    signal: *AbortSignal,
    exec: *const Execution,
    linked_sources: *std.AutoHashMapUnmanaged(usize, void),
) !void {
    if (!signal._dependent) {
        const key = @intFromPtr(signal);
        if (linked_sources.contains(key)) return;
        try linked_sources.put(exec.arena, key, {});
        try composite.addSource(signal, exec);
        try signal.addDependent(composite, exec);
        return;
    }

    for (signal._sources.items) |source_signal| {
        const key = @intFromPtr(source_signal);
        if (linked_sources.contains(key)) continue;
        try linked_sources.put(exec.arena, key, {});
        try composite.addSource(source_signal, exec);
        try source_signal.addDependent(composite, exec);
    }
}

// Static method to create an already-aborted signal (must not fire abort events).
pub fn createAborted(reason: ?js.Value, exec: *const Execution) !*AbortSignal {
    const signal = try init(exec);
    signal._aborted = true;
    signal._reason = if (reason == null or reason.?.isUndefined())
        try resolveAbortReason(null, exec)
    else if (reason.?.isNull())
        .{ .null_reason = {} }
    else
        .{ .js_val = try reason.?.persist() };
    return signal;
}

pub fn createAny(signals_val: js.Value.Temp, exec: *const Execution) !*AbortSignal {
    const local = exec.context.local.?;
    const composite = try init(exec);
    composite._dependent = true;

    const val = signals_val.local(local);
    if (!val.isArray()) return error.TypeError;
    const arr = val.toArray();
    const len = arr.len();

    var seen: std.AutoHashMapUnmanaged(usize, void) = .{};
    var linked_sources: std.AutoHashMapUnmanaged(usize, void) = .{};
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = try arr.get(@intCast(i));
        const source = try local.jsValueToZig(*AbortSignal, item);
        const key = @intFromPtr(source);
        if (seen.contains(key)) continue;
        try seen.put(exec.arena, key, {});

        if (source._aborted) {
            try composite.abortWithReason(try copyReason(source._reason, exec), exec);
            return composite;
        }

        try linkToSourceSignals(composite, source, exec, &linked_sources);
    }

    return composite;
}

pub fn createTimeout(delay: u32, exec: *const Execution) !*AbortSignal {
    const callback = try exec.arena.create(TimeoutCallback);
    callback.* = .{
        .exec = exec,
        .signal = try init(exec),
        .task_owner = exec.captureTaskOwner(),
    };

    try exec._scheduler.add(callback, TimeoutCallback.run, delay, .{
        .name = "AbortSignal.timeout",
        .finalizer = TimeoutCallback.cancelled,
    });

    return callback.signal;
}

fn rethrowReason(self: *const AbortSignal, exec: *const Execution) !void {
    const local = exec.context.local.?;
    const reason_val: js.Value = switch (self._reason) {
        .js_val => |js_val| local.toLocal(js_val),
        .string => |str| local.newString(str).toValue(),
        .null_reason => .{ .local = local, .handle = local.isolate.initNull() },
        .undefined => local.newString("AbortError").toValue(),
        .dom_exception => |dom_ex| try local.zigValueToJs(dom_ex, .{}),
    };
    exec.context.pending_callback_exception = true;
    _ = local.isolate.throwException(reason_val.handle);
    return error.JsException;
}

pub fn throwIfAborted(self: *const AbortSignal, exec: *const Execution) !void {
    if (!self._aborted) return;
    try rethrowReason(self, exec);
}

const Reason = union(enum) {
    js_val: js.Value.Global,
    string: []const u8,
    null_reason: void,
    undefined: void,
    /// Arena-backed DOMException; materialized to JS only when a live Local exists.
    dom_exception: *DOMException,
};

const TimeoutCallback = struct {
    exec: *const Execution,
    signal: *AbortSignal,
    task_owner: @import("../../runtime/RealmLifecycleKernel.zig").TaskOwner,

    fn cancelled(ctx: *anyopaque) void {
        _ = ctx;
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *TimeoutCallback = @ptrCast(@alignCast(ctx));

        if (self.exec.isTaskOwnerStale(self.task_owner)) return null;

        switch (self.exec.context.global) {
            .frame => |frame| {
                if (frame._detach_pending) return null;
            },
            .worker => {},
        }

        // Root realms can still be `.initializing` when inline document scripts run;
        // retry instead of dropping the timeout (WPT abort-signal-any + timeout).
        // Use canEnterJs (no trace) while waiting — validateJsEntry would spam
        // microtask_checkpoint traces at realm_state=initializing.
        self.exec.validateJsEntry(.allow_draining, .timer) catch {
            return switch (self.exec.realmState()) {
                .initializing => 50,
                else => null,
            };
        };

        // Timer callbacks are Zig-initiated; install ctx.local so helpers that read
        // exec.context.local (createTimeoutError, abort dispatch) see a live Local.
        var installed = Context.InstalledLocal.install(self.exec.context);
        defer installed.deinit(self.exec.context);

        const reason = try createTimeoutReason(self.exec);
        self.signal.abortWithReason(reason, self.exec) catch |err| {
            log.warn(.app, "abort signal timeout", .{ .err = err });
        };
        return null;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(AbortSignal);

    pub const Meta = struct {
        pub const name = "AbortSignal";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const enumerable = false;
    };

    pub const Prototype = EventTarget;

    pub const constructor = bridge.constructor(AbortSignal.init, .{});
    pub const aborted = bridge.accessor(AbortSignal.getAborted, null, .{});
    pub const reason = bridge.accessor(AbortSignal.getReasonJs, null, .{});
    pub const onabort = bridge.accessor(AbortSignal.getOnAbort, AbortSignal.setOnAbort, .{});
    pub const throwIfAborted = bridge.function(AbortSignal.throwIfAborted, .{});

    // Static methods
    pub const abort = bridge.function(AbortSignal.createAborted, .{ .static = true });
    pub const timeout = bridge.function(AbortSignal.createTimeout, .{ .static = true });
    pub const any = bridge.function(AbortSignal.createAny, .{ .static = true });
};
