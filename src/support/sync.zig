const std = @import("std");
const runtime_io = @import("io.zig");

pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(runtime_io.get());
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(runtime_io.get());
    }
};

pub const Condition = struct {
    inner: std.Io.Condition = .init,

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        self.inner.waitUncancelable(runtime_io.get(), &mutex.inner);
    }

    pub fn signal(self: *Condition) void {
        self.inner.signal(runtime_io.get());
    }

    pub fn broadcast(self: *Condition) void {
        self.inner.broadcast(runtime_io.get());
    }
};
