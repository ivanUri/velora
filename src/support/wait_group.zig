const std = @import("std");
const Timer = @import("timer.zig");

const WaitGroup = @This();

remaining: std.atomic.Value(usize) = .init(0),

pub fn startMany(self: *WaitGroup, count: usize) void {
    _ = self.remaining.fetchAdd(count, .release);
}

pub fn finish(self: *WaitGroup) void {
    _ = self.remaining.fetchSub(1, .release);
}

pub fn wait(self: *WaitGroup) void {
    while (self.remaining.load(.acquire) != 0) {
        Timer.sleepNanoseconds(std.time.ns_per_ms);
    }
}
