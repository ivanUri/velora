const std = @import("std");
const runtime_io = @import("io.zig");

const Timer = @This();

started: std.Io.Timestamp,

pub fn start() !Timer {
    return .{ .started = .now(runtime_io.get(), .boot) };
}

pub fn read(self: *const Timer) u64 {
    const elapsed = self.started.durationTo(.now(runtime_io.get(), .boot)).nanoseconds;
    return if (elapsed <= 0) 0 else @intCast(elapsed);
}

pub fn reset(self: *Timer) void {
    self.started = .now(runtime_io.get(), .boot);
}

pub fn lap(self: *Timer) u64 {
    const elapsed = self.read();
    self.reset();
    return elapsed;
}

pub fn sleepNanoseconds(ns: u64) void {
    std.Io.sleep(runtime_io.get(), .fromNanoseconds(ns), .awake) catch {};
}
