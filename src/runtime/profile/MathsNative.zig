const std = @import("std");

const Frame = @import("../../core/browser/Frame.zig");
const js = @import("../../core/js/js.zig");
const v8 = js.v8;
const Caller = js.Caller;
const log = @import("../../support/log.zig");

pub const Entry = struct {
    method: []const u8,
    args: []const f64,
    result: f64,
};

const Case = struct {
    args: []f64,
    result: f64,
};

const MethodState = struct {
    name: []const u8,
    cases: []Case,
    original: js.Function.Global,
};

const arg_match_eps: f64 = 1e-12;

pub fn installOnContext(context: *js.Context, frame: *Frame) void {
    const profile = frame.loadedProfile();
    if (profile.mode != .antidetect) return;
    const entries = profile.maths_baseline;
    if (entries.len == 0) return;

    var ls: js.Local.Scope = undefined;
    context.localScope(&ls);
    defer ls.deinit();

    const local = &ls.local;
    const arena = context.arena;

    const global_handle = v8.v8__Context__Global(local.handle).?;
    const global = js.Object{ .local = local, .handle = global_handle };
    const math_val = global.get("Math") catch return;
    const math = js.Object{ .local = local, .handle = @ptrCast(math_val.handle) };

    var methods: std.ArrayListUnmanaged([]const u8) = .empty;
    defer methods.deinit(arena);
    for (entries) |entry| {
        var found = false;
        for (methods.items) |m| {
            if (std.mem.eql(u8, m, entry.method)) {
                found = true;
                break;
            }
        }
        if (!found) methods.append(arena, entry.method) catch return;
    }

    var installed: usize = 0;
    for (methods.items) |method| {
        installMethod(local, arena, math, method, entries) catch continue;
        installed += 1;
    }
    if (installed > 0) {
        log.info(.js, "maths native install", .{ .entries = entries.len, .methods = installed });
    }
}

fn installMethod(
    local: *const js.Local,
    arena: std.mem.Allocator,
    math: js.Object,
    method: []const u8,
    entries: []const Entry,
) !void {
    var case_count: usize = 0;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.method, method)) case_count += 1;
    }
    if (case_count == 0) return;

    const cases = try arena.alloc(Case, case_count);
    var idx: usize = 0;
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.method, method)) continue;
        const args_copy = try arena.dupe(f64, entry.args);
        cases[idx] = .{
            .args = args_copy,
            .result = entry.result,
        };
        idx += 1;
    }

    const orig_func = math.getFunction(method) catch return;
    const original = try orig_func.?.persist();

    const state = try arena.create(MethodState);
    state.* = .{
        .name = method,
        .cases = cases,
        .original = original,
    };

    const replacement = makeNativeFunction(local, state);
    const replacement_val = js.Value{ .local = local, .handle = @ptrCast(replacement.handle) };
    if (math.defineOwnProperty(method, replacement_val, v8.DontEnum) != true) {
        if ((try math.set(method, replacement, .{})) != true) return error.InstallFailed;
    }
}

fn makeNativeFunction(local: *const js.Local, state: *MethodState) js.Function {
    const external = local.isolate.createExternal(@ptrCast(state));
    const template = v8.v8__FunctionTemplate__New__Config(local.isolate.handle, &.{
        .callback = callback,
        .data = @ptrCast(external),
        .length = @intCast(methodArity(state.name)),
        .behavior = v8.kConstructorBehavior_Throw,
        .side_effect_type = v8.kSideEffectType_HasNoSideEffect,
    }).?;
    const name_handle = local.isolate.initStringHandle(state.name);
    v8.v8__FunctionTemplate__SetClassName(template, name_handle);
    v8.v8__FunctionTemplate__ReadOnlyPrototype(template);
    const handle = v8.v8__FunctionTemplate__GetFunction(template, local.handle).?;
    return .{ .local = local, .handle = handle };
}

fn methodArity(method: []const u8) u32 {
    if (std.mem.eql(u8, method, "atan2") or
        std.mem.eql(u8, method, "pow") or
        std.mem.eql(u8, method, "hypot")) return 2;
    return 1;
}

fn callback(info_handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
    const info = Caller.FunctionCallbackInfo{ .handle = info_handle.? };
    const state: *MethodState = @ptrCast(@alignCast(info.getData() orelse return));

    var caller: Caller = undefined;
    if (!caller.initFromHandle(info_handle)) return;
    defer caller.deinit();

    const local = &caller.local;

    const argc = info.length();
    var args: [8]f64 = undefined;
    if (argc > args.len) return;

    for (0..argc) |i| {
        args[i] = info.getArg(@intCast(i), local).toF64() catch return;
    }
    const arg_slice = args[0..argc];

    if (findMatch(state, arg_slice)) |result| {
        const num = js.Number.init(local.isolate.handle, result);
        info.getReturnValue().set(js.Value{ .local = local, .handle = @ptrCast(num.handle) });
        return;
    }

    var v8_args: [8]?*const v8.Value = undefined;
    for (0..argc) |i| {
        v8_args[i] = info.getArg(@intCast(i), local).handle;
    }

    const orig = state.original.local(local);
    const result_handle = v8.v8__Function__Call(
        orig.handle,
        local.handle,
        info.getThis(),
        @intCast(argc),
        @ptrCast(v8_args[0..argc].ptr),
    ) orelse return;
    info.getReturnValue().setValueHandle(result_handle);
}

fn findMatch(state: *const MethodState, args: []const f64) ?f64 {
    for (state.cases) |entry| {
        if (argsMatch(entry.args, args)) return entry.result;
    }
    return null;
}

fn argsMatch(expected: []const f64, actual: []const f64) bool {
    if (expected.len != actual.len) return false;
    for (expected, actual) |a, b| {
        if (!floatEq(a, b)) return false;
    }
    return true;
}

fn floatEq(a: f64, b: f64) bool {
    if (std.math.isNan(a) and std.math.isNan(b)) return true;
    if (@as(u64, @bitCast(a)) == @as(u64, @bitCast(b))) return true;
    if (!std.math.isNan(a) and !std.math.isNan(b) and @abs(a - b) < arg_match_eps) return true;
    return false;
}
