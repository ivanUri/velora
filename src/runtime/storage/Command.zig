const std = @import("std");
const sync = @import("../../support/sync.zig");

pub const Allocator = std.mem.Allocator;

pub const CookieKey = struct {
    partition_site: []u8,
    name: []u8,
    domain: []u8,
    path: []u8,

    pub fn deinit(self: CookieKey, allocator: Allocator) void {
        allocator.free(self.partition_site);
        allocator.free(self.name);
        allocator.free(self.domain);
        allocator.free(self.path);
    }
};

pub const CookieRecord = struct {
    key: CookieKey,
    value: []u8,
    expires: ?f64,
    secure: bool,
    http_only: bool,
    same_site: u8,
    source_secure: bool,
    source_port: u16,
    partitioned: bool,

    pub fn deinit(self: CookieRecord, allocator: Allocator) void {
        self.key.deinit(allocator);
        allocator.free(self.value);
    }
};

pub const LocalSet = struct {
    origin: []u8,
    key: []u8,
    value: []u8,

    pub fn deinit(self: LocalSet, allocator: Allocator) void {
        allocator.free(self.origin);
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

pub const StorageKey = struct {
    origin: []u8,
    key: []u8,

    pub fn deinit(self: StorageKey, allocator: Allocator) void {
        allocator.free(self.origin);
        allocator.free(self.key);
    }
};

pub const Barrier = struct {
    mutex: sync.Mutex = .{},
    cond: sync.Condition = .{},
    done: bool = false,
    failed: bool = false,
};

pub const Operation = union(enum) {
    local_set: LocalSet,
    local_remove: StorageKey,
    local_clear_origin: []u8,
    cookie_upsert: CookieRecord,
    cookie_delete: CookieKey,
    cookie_clear: void,
    barrier: *Barrier,
    shutdown: void,
};

pub const Command = struct {
    sequence: u64,
    bytes: usize,
    operation: Operation,

    pub fn deinit(self: Command, allocator: Allocator) void {
        switch (self.operation) {
            .local_set => |v| v.deinit(allocator),
            .local_remove => |v| v.deinit(allocator),
            .local_clear_origin => |origin| allocator.free(origin),
            .cookie_upsert => |v| v.deinit(allocator),
            .cookie_delete => |v| v.deinit(allocator),
            .cookie_clear, .barrier, .shutdown => {},
        }
    }
};

pub const StoredLocal = struct {
    origin: []u8,
    key: []u8,
    value: []u8,

    pub fn deinit(self: StoredLocal, allocator: Allocator) void {
        allocator.free(self.origin);
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

pub const StoredCookie = CookieRecord;
