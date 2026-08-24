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

const js = @import("../js/js.zig");
const Page = @import("Page.zig");

const Event = @import("../webapi/Event.zig");
const EventTarget = @import("../webapi/EventTarget.zig");

const log = @import("../../support/log.zig");
const String = @import("../../support/string.zig").String;
const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;

const EventKey = struct {
    event_target: usize,
    type_string: String,
};

const EventKeyContext = struct {
    pub fn hash(_: @This(), key: EventKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&key.event_target));
        hasher.update(key.type_string.str());
        return hasher.final();
    }

    pub fn eql(_: @This(), a: EventKey, b: EventKey) bool {
        return a.event_target == b.event_target and a.type_string.eql(b.type_string);
    }
};

// EventManagerBase provides core event listener management without DOM-specific
// functionality. It handles listener registration, removal, and the basic dispatch
// loop for non-propagating events.
pub const EventManagerBase = @This();

arena: Allocator,
listener_pool: std.heap.MemoryPool(Listener),
list_pool: std.heap.MemoryPool(std.DoublyLinkedList),
lookup: std.HashMapUnmanaged(
    EventKey,
    *std.DoublyLinkedList,
    EventKeyContext,
    std.hash_map.default_max_load_percentage,
),
dispatch_depth: usize,
deferred_removals: std.ArrayList(struct { list: *std.DoublyLinkedList, listener: *Listener }),
deferred_abort_fires: std.ArrayList(DeferredAbortFire),

pub const DeferredAbortFire = struct {
    signal: *@import("../webapi/AbortSignal.zig"),
    exec: *const js.Execution,
};

pub fn init(arena: Allocator) EventManagerBase {
    return .{
        .arena = arena,
        .lookup = .{},
        .list_pool = .empty,
        .listener_pool = .empty,
        .dispatch_depth = 0,
        .deferred_removals = .empty,
        .deferred_abort_fires = .empty,
    };
}

pub fn beginDispatch(self: *EventManagerBase) void {
    self.dispatch_depth += 1;
}

pub fn endDispatch(self: *EventManagerBase) void {
    if (self.dispatch_depth == 0) return;
    self.dispatch_depth -= 1;
    if (self.dispatch_depth == 0) {
        for (self.deferred_removals.items) |removal| {
            removal.list.remove(&removal.listener.node);
            self.listener_pool.destroy(removal.listener);
        }
        self.deferred_removals.clearRetainingCapacity();

        const AbortSignal = @import("../webapi/AbortSignal.zig");
        AbortSignal.flushDeferredAbortFires(self);
    }
}

fn reportListenerException(
    local: *const js.Local,
    ctx: *js.Context,
    try_catch: js.TryCatch,
    caught: js.TryCatch.Caught,
) void {
    const ex = try_catch.exceptionValue() orelse return;
    const message = ex.toStringSlice() catch "Uncaught exception";
    const line: u32 = caught.line orelse 0;

    // Listener exceptions are reported on the listener's realm (incumbent), not the
    // dispatch entry realm (WPT Event-dispatch-throwing-multiple-globals).
    const report_ctx = blk: {
        const v8_incumbent = js.v8.v8__Isolate__GetIncumbentContext(local.isolate.handle) orelse break :blk ctx;
        break :blk js.Context.fromC(v8_incumbent) orelse ctx;
    };

    switch (report_ctx.global) {
        .frame => |frame| {
            frame.window.reportUncaughtException(ex, message, frame.base(), line, 0, frame) catch |err| {
                log.warn(.event, "listener uncaught", .{ .err = err });
            };
        },
        .worker => |wgs| {
            wgs.reportUncaughtException(ex, message, wgs.base(), line, 0) catch |err| {
                log.warn(.event, "listener uncaught", .{ .err = err });
            };
        },
    }
}

pub fn invokeListener(
    local: *const js.Local,
    ctx: *js.Context,
    func: js.Function,
    this: anytype,
    event: *Event,
    context: []const u8,
) void {
    var try_catch: js.TryCatch = undefined;
    try_catch.init(local);
    defer try_catch.deinit();

    var caught: js.TryCatch.Caught = undefined;
    func.tryCallWithThis(void, this, .{event}, &caught) catch |err| {
        if (err != error.JsException) {
            log.warn(.event, "listener invocation failed", .{ .err = err, .context = context });
            return;
        }
        ctx.pending_callback_exception = false;
        reportListenerException(local, ctx, try_catch, caught);
    };
}

pub fn invokeCallback(
    local: *const js.Local,
    ctx: *js.Context,
    func: js.Function,
    comptime T: type,
    args: anytype,
    context: []const u8,
) ?T {
    var try_catch: js.TryCatch = undefined;
    try_catch.init(local);
    defer try_catch.deinit();

    var caught: js.TryCatch.Caught = undefined;
    return func.tryCall(T, args, &caught) catch |err| {
        if (err != error.JsException) {
            log.warn(.event, "callback invocation failed", .{ .err = err, .context = context });
            return null;
        }
        ctx.pending_callback_exception = false;
        reportListenerException(local, ctx, try_catch, caught);
        return null;
    };
}

pub fn invokeListenerObject(
    local: *const js.Local,
    ctx: *js.Context,
    obj: js.Object,
    event: *Event,
    context: []const u8,
) void {
    const handle_event = obj.getFunction("handleEvent") catch |err| blk: {
        log.warn(.event, "listener handleEvent lookup failed", .{ .err = err, .context = context });
        break :blk null;
    };
    if (handle_event) |handleEvent| {
        invokeListener(local, ctx, handleEvent, obj, event, context);
    }
}

pub fn invokeListenerString(
    arena: Allocator,
    local: *const js.Local,
    ctx: *js.Context,
    source: []const u8,
    context: []const u8,
) void {
    const str = arena.dupeZ(u8, source) catch |err| {
        log.warn(.event, "listener string dup failed", .{ .err = err, .context = context });
        return;
    };

    var try_catch: js.TryCatch = undefined;
    try_catch.init(local);
    defer try_catch.deinit();

    local.eval(str, null) catch |err| {
        if (err != error.JsException) {
            log.warn(.event, "listener string eval failed", .{ .err = err, .context = context });
            return;
        }
        const caught = try_catch.caughtOrError(arena, err);
        ctx.pending_callback_exception = false;
        reportListenerException(local, ctx, try_catch, caught);
    };
}

pub const SignalOption = union(enum) {
    unset,
    set: *@import("../webapi/AbortSignal.zig"),

    pub fn fromJs(local: *const js.Local, js_val: js.Value) !SignalOption {
        if (js_val.isUndefined()) return .unset;
        if (js_val.isNull()) return error.TypeError;
        return .{ .set = try local.jsValueToZig(*@import("../webapi/AbortSignal.zig"), js_val) };
    }

    pub fn get(self: SignalOption) ?*@import("../webapi/AbortSignal.zig") {
        return switch (self) {
            .unset => null,
            .set => |signal| signal,
        };
    }
};

pub const RegisterOptions = struct {
    once: bool = false,
    capture: bool = false,
    passive: bool = false,
    signal: SignalOption = .unset,
};

pub const Callback = union(enum) {
    function: js.Function,
    object: js.Object,
};

pub fn register(self: *EventManagerBase, target: *EventTarget, typ: []const u8, callback: Callback, opts: RegisterOptions) !*Listener {
    if (comptime IS_DEBUG) {
        log.debug(.event, "EventManager.register", .{
            .type = typ,
            .capture = opts.capture,
            .once = opts.once,
            .target = target.toString(),
        });
    }

    // If a signal is provided and already aborted, don't register the listener
    if (opts.signal.get()) |signal| {
        if (signal.getAborted()) {
            return error.SignalAborted;
        }
    }

    // Allocate the type string we'll use in both listener and key
    const type_string = try String.init(self.arena, typ, .{});

    const gop = try self.lookup.getOrPut(self.arena, .{
        .type_string = type_string,
        .event_target = @intFromPtr(target),
    });
    if (gop.found_existing) {
        // check for duplicate callbacks already registered
        var node = gop.value_ptr.*.first;
        while (node) |n| {
            const listener: *Listener = @alignCast(@fieldParentPtr("node", n));
            const is_duplicate = switch (callback) {
                .object => |obj| listener.function.eqlObject(obj),
                .function => |func| listener.function.eqlFunction(func),
            };
            if (is_duplicate and listener.capture == opts.capture) {
                return error.DuplicateListener;
            }
            node = n.next;
        }
    } else {
        gop.value_ptr.* = try self.list_pool.create(self.arena);
        gop.value_ptr.*.* = .{};
    }

    const func = switch (callback) {
        .function => |f| Function{ .value = try f.persist() },
        .object => |o| Function{ .object = try o.persist() },
    };

    const listener = try self.listener_pool.create(self.arena);
    listener.* = .{
        .node = .{},
        .once = opts.once,
        .capture = opts.capture,
        .passive = opts.passive,
        .function = func,
        .signal = opts.signal.get(),
        .typ = type_string,
    };
    // append the listener to the list of listeners for this target
    gop.value_ptr.*.append(&listener.node);

    return listener;
}

/// Register a listener, silently ignoring spec-mandated no-ops (aborted signal,
/// duplicate callback). Used by addEventListener in both window and worker realms.
pub fn registerIgnoringNoops(
    self: *EventManagerBase,
    target: *EventTarget,
    typ: []const u8,
    callback: Callback,
    opts: RegisterOptions,
) !?*Listener {
    return self.register(target, typ, callback, opts) catch |err| switch (err) {
        error.SignalAborted, error.DuplicateListener => return null,
        else => return err,
    };
}

pub fn remove(self: *EventManagerBase, target: *EventTarget, typ: []const u8, callback: Callback, use_capture: bool) void {
    const list = self.lookup.get(.{
        .type_string = String.wrap(typ),
        .event_target = @intFromPtr(target),
    }) orelse return;
    if (findListener(list, callback, use_capture)) |listener| {
        self.removeListener(list, listener);
    }
}

pub fn removeListener(self: *EventManagerBase, list: *std.DoublyLinkedList, listener: *Listener) void {
    if (listener.removed) return;

    // If we're in a dispatch, defer removal to avoid invalidating iteration
    if (self.dispatch_depth > 0) {
        listener.removed = true;
        self.deferred_removals.append(self.arena, .{ .list = list, .listener = listener }) catch unreachable;
    } else {
        // Outside dispatch, remove immediately
        list.remove(&listener.node);
        self.listener_pool.destroy(listener);
    }
}

/// Check if there are any listeners registered for a target/type combination.
pub fn hasListeners(self: *EventManagerBase, target: *EventTarget, typ: []const u8) bool {
    return self.lookup.get(.{
        .event_target = @intFromPtr(target),
        .type_string = String.wrap(typ),
    }) != null;
}

/// Get the listener list for a target/type, if any exist.
pub fn getListeners(self: *EventManagerBase, target: *EventTarget, event_type: String) ?*std.DoublyLinkedList {
    return self.lookup.get(.{
        .event_target = @intFromPtr(target),
        .type_string = event_type,
    });
}

// Dispatching can be recursive from the compiler's point of view, so we need to
// give it an explicit error set so that other parts of the code can use an
// inferred error.
pub const DispatchError = error{
    OutOfMemory,
    StringTooLarge,
    CompilationError,
    JsException,
};

pub const DispatchDirectOptions = struct {
    context: []const u8 = "dispatchDirect",
    inject_target: bool = true,
    /// Iframe unload/pagehide during parent DOM removal: do not drain microtasks
    /// before returning to the outer V8 API callback.
    skip_post_dispatch_microtasks: bool = false,
};

/// Direct dispatch for non-DOM targets. No propagation - just calls the property
/// handler and registered listeners. Caller is responsible for event ref counting.
/// Handler can be: null, ?js.Function.Global, ?js.Function.Temp, or js.Function
pub fn dispatchDirect(
    self: *EventManagerBase,
    arena: Allocator,
    ctx: *js.Context,
    target: *EventTarget,
    event: *Event,
    handler: anytype,
    page: *Page,
    comptime opts: DispatchDirectOptions,
) DispatchError!void {
    if (comptime IS_DEBUG) {
        log.debug(.event, "dispatchDirect", .{ .type = event._type_string, .context = opts.context });
    }

    event.acquireRef();
    defer _ = event.releaseRef(page);

    if (comptime opts.inject_target) {
        event._target = target;
        event._dispatch_target = target;
    }

    // Reuse either a V8->Zig Caller scope or a Zig-owned Local.Scope already
    // entered by the current task. A second localScope/deinit pair trips V8's
    // context stack, and a nested microtask checkpoint can re-enter handlers
    // while the outer event is still dispatching.
    const active_local = ctx.local orelse ctx.active_scope;
    const nested_in_api = active_local != null;
    var owned_scope: js.Local.Scope = undefined;
    const local: *const js.Local = blk: {
        if (active_local) |active| break :blk active;
        // Page teardown may abort XHR after destroyContext; skip events if dead.
        if (!ctx.tryLocalScope(&owned_scope)) return;
        break :blk &owned_scope.local;
    };
    defer if (!nested_in_api) {
        if (!opts.skip_post_dispatch_microtasks) {
            local.ctx.env.runMicrotasks(.event_handler);
        }
        owned_scope.deinit();
    };

    // Call the property handler (e.g., onmessage) if present
    if (getFunction(handler, local)) |func| {
        event._current_target = target;
        invokeListener(local, ctx, func, target, event, opts.context);
    }

    // Call listeners registered via addEventListener
    const list = self.getListeners(target, event._type_string) orelse return;

    // This is a slightly simplified version of what you'll find in EventManager.
    // dispatchPhase. It is simpler because, for direct dispatching, we know
    // there's no ancestors and only the single target phase.

    // Use the last listener in the list as sentinel - listeners added during dispatch will be after it
    const last_node = list.last orelse return;
    const last_listener: *Listener = @alignCast(@fieldParentPtr("node", last_node));

    // Iterate through the list, stopping after we've encountered the last_listener
    var node = list.first;
    var is_done = false;
    while (node) |n| {
        if (is_done) {
            break;
        }

        const listener: *Listener = @alignCast(@fieldParentPtr("node", n));
        is_done = (listener == last_listener);
        node = n.next;

        // Skip removed listeners
        if (listener.removed) {
            continue;
        }

        // If the listener has an aborted signal, remove it and skip
        if (listener.signal) |signal| {
            if (signal.getAborted()) {
                self.removeListener(list, listener);
                continue;
            }
        }

        // Remove "once" listeners BEFORE calling them so nested dispatches don't see them
        if (listener.once) {
            self.removeListener(list, listener);
        }

        event._current_target = target;

        event.setPassiveListener(listener.passive);
        defer event.setPassiveListener(false);

        // Listener exceptions are reported, not propagated, so dispatch can continue.
        switch (listener.function) {
            .value => |value| {
                const func = globalToFunction(value, local) orelse continue;
                invokeListener(local, ctx, func, target, event, opts.context);
            },
            .string => |string| invokeListenerString(arena, local, ctx, string.str(), opts.context),
            .object => |obj_global| invokeListenerObject(local, ctx, local.toLocal(obj_global), event, opts.context),
        }

        if (event._stop_immediate_propagation) {
            return;
        }
    }
}

fn getFunction(handler: anytype, local: *const js.Local) ?js.Function {
    const T = @TypeOf(handler);
    const ti = @typeInfo(T);

    if (ti == .null) {
        return null;
    }
    if (ti == .optional) {
        return getFunction(handler orelse return null, local);
    }
    return switch (T) {
        js.Function => handler,
        js.Function.Temp => local.toLocal(handler),
        js.Function.Global => globalToFunction(handler, local),
        else => @compileError("handler must be null or \\??js.Function(\\.(Temp|Global))?"),
    };
}

fn globalToFunction(handler: js.Function.Global, local: *const js.Local) ?js.Function {
    const handle = js.v8.v8__Global__Get(&handler.handle, local.isolate.handle) orelse return null;
    return .{
        .local = local,
        .handle = @ptrCast(handle),
    };
}

/// Remove all listeners registered with the given abort signal.
pub fn removeSignalListeners(self: *EventManagerBase, signal: *@import("../webapi/AbortSignal.zig")) void {
    var pending = std.ArrayList(struct { list: *std.DoublyLinkedList, listener: *Listener }).empty;
    defer pending.deinit(self.arena);

    var it = self.lookup.iterator();
    while (it.next()) |entry| {
        const list = entry.value_ptr.*;
        var node = list.first;
        while (node) |n| {
            const listener: *Listener = @alignCast(@fieldParentPtr("node", n));
            if (listener.signal == signal) {
                pending.append(self.arena, .{ .list = list, .listener = listener }) catch return;
            }
            node = n.next;
        }
    }

    for (pending.items) |item| {
        self.removeListener(item.list, item.listener);
    }
}

/// Check if there are any listeners for a direct dispatch (non-DOM target).
/// Use this to avoid creating an event when there are no listeners.
pub fn hasDirectListeners(self: *EventManagerBase, target: *EventTarget, typ: []const u8, handler: anytype) bool {
    if (hasHandler(handler)) {
        return true;
    }
    return self.hasListeners(target, typ);
}

fn hasHandler(handler: anytype) bool {
    const ti = @typeInfo(@TypeOf(handler));
    if (ti == .null) {
        return false;
    }
    if (ti == .optional) {
        return handler != null;
    }
    return true;
}

fn findListener(list: *const std.DoublyLinkedList, callback: Callback, capture: bool) ?*Listener {
    var node = list.first;
    while (node) |n| {
        node = n.next;
        const listener: *Listener = @alignCast(@fieldParentPtr("node", n));
        const matches = switch (callback) {
            .object => |obj| listener.function.eqlObject(obj),
            .function => |func| listener.function.eqlFunction(func),
        };
        if (!matches) {
            continue;
        }
        if (listener.capture != capture) {
            continue;
        }
        return listener;
    }
    return null;
}

pub const Listener = struct {
    typ: String,
    once: bool,
    capture: bool,
    passive: bool,
    function: Function,
    signal: ?*@import("../webapi/AbortSignal.zig") = null,
    node: std.DoublyLinkedList.Node,
    removed: bool = false,
};

pub const Function = union(enum) {
    value: js.Function.Global,
    string: String,
    object: js.Object.Global,

    pub fn eqlFunction(self: Function, func: js.Function) bool {
        return switch (self) {
            .value => |v| v.isEqual(func),
            else => false,
        };
    }

    pub fn eqlObject(self: Function, obj: js.Object) bool {
        return switch (self) {
            .object => |o| return o.isEqual(obj),
            else => false,
        };
    }
};
