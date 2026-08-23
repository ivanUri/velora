const std = @import("std");
const Timer = @import("../../support/timer.zig");
const Frame = @import("Frame.zig");
const InputController = @import("InputController.zig");

pub const MoveOpts = struct {
    steps: u8 = 14,
    step_delay_ms: u32 = 6,
    curve: f64 = 0.35,
};

pub const WheelOpts = struct {
    steps: u8 = 8,
    step_delay_ms: u32 = 12,
};

fn sleepMs(ms: u32) void {
    if (ms == 0) return;
    Timer.sleepNanoseconds(ms * std.time.ns_per_ms);
}

fn bezier(t: f64, p0: f64, p1: f64, p2: f64, p3: f64) f64 {
    const u = 1.0 - t;
    return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3;
}

/// Move pointer along a eased cubic bezier from last position to (x, y).
pub fn movePointerTo(root_frame: *Frame, x: f64, y: f64, opts: MoveOpts) !void {
    const from_x = root_frame._last_pointer_x;
    const from_y = root_frame._last_pointer_y;
    if (from_x == x and from_y == y) return;

    const ctrl1_x = from_x + (x - from_x) * opts.curve;
    const ctrl1_y = from_y + (y - from_y) * 0.1;
    const ctrl2_x = from_x + (x - from_x) * (1.0 - opts.curve);
    const ctrl2_y = from_y + (y - from_y) * 0.9;

    const steps = @max(opts.steps, 1);
    var i: u8 = 1;
    while (i <= steps) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const eased = t * t * (3.0 - 2.0 * t);
        const px = bezier(eased, from_x, ctrl1_x, ctrl2_x, x);
        const py = bezier(eased, from_y, ctrl1_y, ctrl2_y, y);
        try InputController.dispatchPointerMoveAt(root_frame, px, py);
        sleepMs(opts.step_delay_ms);
    }
    root_frame._last_pointer_x = x;
    root_frame._last_pointer_y = y;
}

/// Human-like click: move along path, brief pause, then activate.
pub fn humanClick(root_frame: *Frame, x: f64, y: f64) !void {
    try movePointerTo(root_frame, x, y, .{});
    sleepMs(40 + @as(u32, @intCast(@mod(@as(u64, @bitCast(x)), 30))));
    try InputController.dispatchPointerClick(root_frame, x, y);
}

/// Dispatch wheel events in steps (scroll simulation).
pub fn wheelScroll(root_frame: *Frame, delta_y: f64, opts: WheelOpts) !void {
    const steps = @max(opts.steps, 1);
    const step_delta = delta_y / @as(f64, @floatFromInt(steps));
    var i: u8 = 0;
    while (i < steps) : (i += 1) {
        try InputController.dispatchWheelAt(root_frame, root_frame._last_pointer_x, root_frame._last_pointer_y, step_delta);
        sleepMs(opts.step_delay_ms);
    }
}

pub fn charDelay(ch: u8) u32 {
    return 35 + @as(u32, @intCast(@mod(@as(u64, ch), 25)));
}
