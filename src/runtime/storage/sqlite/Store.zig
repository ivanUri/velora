const std = @import("std");
const Sqlite = @import("Sqlite.zig");
const model = @import("../Command.zig");
const log = @import("../../../support/log.zig");
const runtime_io = @import("../../../support/io.zig");
const sync = @import("../../../support/sync.zig");

const Allocator = std.mem.Allocator;
const Store = @This();

const max_commands = 16 * 1024;
const max_pending_bytes = 64 * 1024 * 1024;
const batch_commands = 512;
const batch_bytes = 1024 * 1024;
const batch_delay_ns = 5 * std.time.ns_per_ms;

allocator: Allocator,
sqlite: Sqlite,
profile_id: []u8,
writer_lock: ?std.Io.File,
mutex: sync.Mutex = .{},
work_cond: sync.Condition = .{},
space_cond: sync.Condition = .{},
queue: std.ArrayList(model.Command) = .empty,
pending_bytes: usize = 0,
next_sequence: u64 = 1,
accepting: bool = true,
worker_failed: bool = false,
thread: std.Thread = undefined,

pub fn create(allocator: Allocator, path: ?[:0]const u8, profile_id: []const u8) !*Store {
    const self = try allocator.create(Store);
    errdefer allocator.destroy(self);

    const writer_lock = try acquireWriterLock(allocator, path);
    errdefer if (writer_lock) |file| file.close(runtime_io.get());
    var sqlite = try Sqlite.init(allocator, path);
    errdefer sqlite.deinit(allocator);
    const owned_profile_id = try allocator.dupe(u8, profile_id);
    errdefer allocator.free(owned_profile_id);

    self.* = .{
        .allocator = allocator,
        .sqlite = sqlite,
        .profile_id = owned_profile_id,
        .writer_lock = writer_lock,
    };

    self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
    return self;
}

pub fn destroy(self: *Store) void {
    _ = self.flush() catch {};
    self.mutex.lock();
    self.accepting = false;
    self.mutex.unlock();
    self.work_cond.signal();
    self.thread.join();

    for (self.queue.items) |command| command.deinit(self.allocator);
    self.queue.deinit(self.allocator);
    self.sqlite.deinit(self.allocator);
    if (self.writer_lock) |file| file.close(runtime_io.get());
    self.allocator.free(self.profile_id);
    const allocator = self.allocator;
    allocator.destroy(self);
}

fn push(self: *Store, operation: model.Operation, bytes: usize) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    while (self.accepting and !self.worker_failed and
        (self.queue.items.len >= max_commands or self.pending_bytes + bytes > max_pending_bytes))
    {
        self.space_cond.wait(&self.mutex);
    }
    if (!self.accepting) return error.StorageClosed;
    if (self.worker_failed) return error.StorageWorkerFailed;

    const sequence = self.next_sequence;
    self.next_sequence +%= 1;
    try self.queue.append(self.allocator, .{ .sequence = sequence, .bytes = bytes, .operation = operation });
    self.pending_bytes += bytes;
    self.work_cond.signal();
}

pub fn localSet(self: *Store, origin: []const u8, key: []const u8, value: []const u8) !void {
    const owned_origin = try self.allocator.dupe(u8, origin);
    errdefer self.allocator.free(owned_origin);
    const owned_key = try self.allocator.dupe(u8, key);
    errdefer self.allocator.free(owned_key);
    const owned_value = try self.allocator.dupe(u8, value);
    errdefer self.allocator.free(owned_value);
    try self.push(.{ .local_set = .{ .origin = owned_origin, .key = owned_key, .value = owned_value } }, origin.len + key.len + value.len);
}

pub fn localRemove(self: *Store, origin: []const u8, key: []const u8) !void {
    const owned_origin = try self.allocator.dupe(u8, origin);
    errdefer self.allocator.free(owned_origin);
    const owned_key = try self.allocator.dupe(u8, key);
    errdefer self.allocator.free(owned_key);
    try self.push(.{ .local_remove = .{ .origin = owned_origin, .key = owned_key } }, origin.len + key.len);
}

pub fn localClear(self: *Store, origin: []const u8) !void {
    const owned_origin = try self.allocator.dupe(u8, origin);
    errdefer self.allocator.free(owned_origin);
    try self.push(.{ .local_clear_origin = owned_origin }, origin.len);
}

fn copyCookieKey(self: *Store, key: anytype) !model.CookieKey {
    const partition_site = key.partition_site orelse "";
    const owned_partition = try self.allocator.dupe(u8, partition_site);
    errdefer self.allocator.free(owned_partition);
    const owned_name = try self.allocator.dupe(u8, key.name);
    errdefer self.allocator.free(owned_name);
    const owned_domain = try self.allocator.dupe(u8, key.domain);
    errdefer self.allocator.free(owned_domain);
    const owned_path = try self.allocator.dupe(u8, key.path);
    return .{ .partition_site = owned_partition, .name = owned_name, .domain = owned_domain, .path = owned_path };
}

pub fn cookieUpsert(self: *Store, cookie: anytype) !void {
    const key = try self.copyCookieKey(cookie);
    errdefer key.deinit(self.allocator);
    const value = try self.allocator.dupe(u8, cookie.value);
    errdefer self.allocator.free(value);
    const bytes = key.partition_site.len + key.name.len + key.domain.len + key.path.len + value.len;
    try self.push(.{ .cookie_upsert = .{
        .key = key,
        .value = value,
        .expires = cookie.expires,
        .secure = cookie.secure,
        .http_only = cookie.http_only,
        .same_site = @intFromEnum(cookie.same_site),
        .source_secure = cookie.source_secure,
        .source_port = cookie.source_port,
        .partitioned = cookie.partitioned,
    } }, bytes);
}

pub fn cookieDelete(self: *Store, cookie: anytype) !void {
    const key = try self.copyCookieKey(cookie);
    errdefer key.deinit(self.allocator);
    try self.push(.{ .cookie_delete = key }, key.partition_site.len + key.name.len + key.domain.len + key.path.len);
}

pub fn cookieClear(self: *Store) !void {
    try self.push(.cookie_clear, 0);
}

pub fn flush(self: *Store) !void {
    var barrier: model.Barrier = .{};
    try self.push(.{ .barrier = &barrier }, 0);
    barrier.mutex.lock();
    while (!barrier.done) barrier.cond.wait(&barrier.mutex);
    barrier.mutex.unlock();
    if (barrier.failed) return error.StorageCommitFailed;
}

fn workerMain(self: *Store) void {
    const conn = self.sqlite.pool.acquire() catch |err| {
        self.failWorker(err);
        return;
    };
    defer self.sqlite.pool.release(conn);

    conn.exec("pragma foreign_keys=on", .{}) catch |err| {
        self.failWorker(err);
        return;
    };
    conn.exec("pragma synchronous=full", .{}) catch |err| {
        self.failWorker(err);
        return;
    };

    while (true) {
        var batch: std.ArrayList(model.Command) = .empty;
        self.mutex.lock();
        while (self.queue.items.len == 0 and self.accepting) self.work_cond.wait(&self.mutex);
        if (self.queue.items.len == 0 and !self.accepting) {
            self.mutex.unlock();
            break;
        }
        if (self.queue.items.len < batch_commands and self.pending_bytes < batch_bytes and !containsBarrier(self.queue.items)) {
            self.mutex.unlock();
            std.Io.sleep(runtime_io.get(), .fromNanoseconds(batch_delay_ns), .awake) catch {};
            self.mutex.lock();
        }
        batch = self.queue;
        self.queue = .empty;
        self.pending_bytes = 0;
        self.mutex.unlock();
        self.space_cond.broadcast();

        const failed = applyBatch(self, conn, batch.items) catch |err| blk: {
            log.err(.storage, "storage writer batch", .{ .err = err, .commands = batch.items.len });
            break :blk true;
        };
        for (batch.items) |command| {
            switch (command.operation) {
                .barrier => |barrier| notifyBarrier(barrier, failed),
                else => {},
            }
            command.deinit(self.allocator);
        }
        batch.deinit(self.allocator);
        if (failed) {
            self.failWorker(error.StorageCommitFailed);
            return;
        }
    }
}

fn containsBarrier(commands: []const model.Command) bool {
    for (commands) |command| switch (command.operation) {
        .barrier => return true,
        else => {},
    };
    return false;
}

fn acquireWriterLock(allocator: Allocator, path: ?[:0]const u8) !?std.Io.File {
    const database_path = path orelse return null;
    if (std.mem.eql(u8, database_path, ":memory:")) return null;
    const io = runtime_io.get();
    if (std.fs.path.dirname(database_path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    const lock_path = try std.fmt.allocPrint(allocator, "{s}.writer.lock", .{database_path});
    defer allocator.free(lock_path);
    const file = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false });
    errdefer file.close(io);
    if (!try file.tryLock(io, .exclusive)) return error.StorageWriterAlreadyActive;
    return file;
}

fn applyBatch(self: *Store, conn: Sqlite.Conn, commands: []const model.Command) !bool {
    const skip = try coalesce(self.allocator, commands);
    defer self.allocator.free(skip);

    try conn.exec("begin immediate", .{});
    errdefer conn.exec("rollback", .{}) catch {};
    try conn.exec("insert into profiles(profile_id, created_at, updated_at) values (?1, unixepoch(), unixepoch()) on conflict(profile_id) do update set updated_at=excluded.updated_at", .{self.profile_id});

    for (commands, 0..) |command, i| {
        if (skip[i]) continue;
        switch (command.operation) {
            .local_set => |v| try conn.exec("insert into local_storage(profile_id, origin, key, value, update_seq) values (?1, ?2, ?3, ?4, ?5) on conflict(profile_id, origin, key) do update set value=excluded.value, update_seq=excluded.update_seq", .{ self.profile_id, v.origin, v.key, v.value, command.sequence }),
            .local_remove => |v| try conn.exec("delete from local_storage where profile_id=?1 and origin=?2 and key=?3", .{ self.profile_id, v.origin, v.key }),
            .local_clear_origin => |origin| try conn.exec("delete from local_storage where profile_id=?1 and origin=?2", .{ self.profile_id, origin }),
            .cookie_upsert => |v| try conn.exec("insert into cookies(profile_id, partition_site, name, domain, path, value, expires, secure, http_only, same_site, source_secure, source_port, partitioned, update_seq) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14) on conflict(profile_id, partition_site, name, domain, path) do update set value=excluded.value, expires=excluded.expires, secure=excluded.secure, http_only=excluded.http_only, same_site=excluded.same_site, source_secure=excluded.source_secure, source_port=excluded.source_port, partitioned=excluded.partitioned, update_seq=excluded.update_seq", .{ self.profile_id, v.key.partition_site, v.key.name, v.key.domain, v.key.path, v.value, v.expires, v.secure, v.http_only, v.same_site, v.source_secure, v.source_port, v.partitioned, command.sequence }),
            .cookie_delete => |v| try conn.exec("delete from cookies where profile_id=?1 and partition_site=?2 and name=?3 and domain=?4 and path=?5", .{ self.profile_id, v.partition_site, v.name, v.domain, v.path }),
            .cookie_clear => try conn.exec("delete from cookies where profile_id=?1", .{self.profile_id}),
            .barrier, .shutdown => {},
        }
    }
    try conn.exec("commit", .{});
    return false;
}

const CoalesceKey = union(enum) {
    local: struct { origin: []const u8, key: []const u8 },
    cookie: struct { partition_site: []const u8, name: []const u8, domain: []const u8, path: []const u8 },
};

const CoalesceContext = struct {
    pub fn hash(_: CoalesceContext, key: CoalesceKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(&.{@intFromEnum(std.meta.activeTag(key))});
        switch (key) {
            .local => |v| {
                hashPart(&hasher, v.origin);
                hashPart(&hasher, v.key);
            },
            .cookie => |v| {
                hashPart(&hasher, v.partition_site);
                hashPart(&hasher, v.name);
                hashPart(&hasher, v.domain);
                hashPart(&hasher, v.path);
            },
        }
        return hasher.final();
    }

    fn hashPart(hasher: *std.hash.Wyhash, part: []const u8) void {
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, &len, @intCast(part.len), .little);
        hasher.update(&len);
        hasher.update(part);
    }

    pub fn eql(_: CoalesceContext, a: CoalesceKey, b: CoalesceKey) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .local => |av| switch (b) {
                .local => |bv| std.mem.eql(u8, av.origin, bv.origin) and std.mem.eql(u8, av.key, bv.key),
                else => false,
            },
            .cookie => |av| switch (b) {
                .cookie => |bv| std.mem.eql(u8, av.partition_site, bv.partition_site) and
                    std.mem.eql(u8, av.name, bv.name) and
                    std.mem.eql(u8, av.domain, bv.domain) and
                    std.mem.eql(u8, av.path, bv.path),
                else => false,
            },
        };
    }
};

const CoalesceMap = std.HashMapUnmanaged(CoalesceKey, usize, CoalesceContext, std.hash_map.default_max_load_percentage);

fn coalesce(allocator: Allocator, commands: []const model.Command) ![]bool {
    const skip = try allocator.alloc(bool, commands.len);
    @memset(skip, false);
    errdefer allocator.free(skip);

    var latest: CoalesceMap = .empty;
    defer latest.deinit(allocator);

    for (commands, 0..) |command, i| {
        const key: ?CoalesceKey = switch (command.operation) {
            .local_set => |v| .{ .local = .{ .origin = v.origin, .key = v.key } },
            .local_remove => |v| .{ .local = .{ .origin = v.origin, .key = v.key } },
            .cookie_upsert => |v| .{ .cookie = .{ .partition_site = v.key.partition_site, .name = v.key.name, .domain = v.key.domain, .path = v.key.path } },
            .cookie_delete => |v| .{ .cookie = .{ .partition_site = v.partition_site, .name = v.name, .domain = v.domain, .path = v.path } },
            else => null,
        };
        if (key) |k| {
            const gop = try latest.getOrPut(allocator, k);
            if (gop.found_existing) skip[gop.value_ptr.*] = true;
            gop.value_ptr.* = i;
            continue;
        }

        switch (command.operation) {
            .local_clear_origin => |origin| {
                var j = i;
                while (j > 0) {
                    j -= 1;
                    switch (commands[j].operation) {
                        .barrier => break,
                        .local_set => |v| {
                            if (std.mem.eql(u8, v.origin, origin)) skip[j] = true;
                        },
                        .local_remove => |v| {
                            if (std.mem.eql(u8, v.origin, origin)) skip[j] = true;
                        },
                        .local_clear_origin => |prior| {
                            if (std.mem.eql(u8, prior, origin)) skip[j] = true;
                        },
                        else => {},
                    }
                }
                latest.clearRetainingCapacity();
            },
            .cookie_clear => {
                var j = i;
                while (j > 0) {
                    j -= 1;
                    switch (commands[j].operation) {
                        .barrier => break,
                        .cookie_upsert, .cookie_delete, .cookie_clear => skip[j] = true,
                        else => {},
                    }
                }
                latest.clearRetainingCapacity();
            },
            .barrier => latest.clearRetainingCapacity(),
            else => {},
        }
    }
    return skip;
}

fn notifyBarrier(barrier: *model.Barrier, failed: bool) void {
    barrier.mutex.lock();
    barrier.failed = failed;
    barrier.done = true;
    barrier.mutex.unlock();
    barrier.cond.signal();
}

fn failWorker(self: *Store, err: anyerror) void {
    log.err(.storage, "storage writer failed", .{ .err = err });
    self.mutex.lock();
    self.worker_failed = true;
    self.accepting = false;
    for (self.queue.items) |command| {
        switch (command.operation) {
            .barrier => |barrier| notifyBarrier(barrier, true),
            else => {},
        }
    }
    self.mutex.unlock();
    self.space_cond.broadcast();
}

pub fn loadLocal(self: *Store, allocator: Allocator) ![]model.StoredLocal {
    const conn = try self.sqlite.pool.acquire();
    defer self.sqlite.pool.release(conn);
    var rows = try conn.rows("select origin, key, value from local_storage where profile_id=?1 order by origin, key", .{self.profile_id});
    defer rows.deinit();
    var out: std.ArrayList(model.StoredLocal) = .empty;
    errdefer {
        for (out.items) |item| item.deinit(allocator);
        out.deinit(allocator);
    }
    while (try rows.next()) |row| {
        const origin = try allocator.dupe(u8, row.get([]const u8, 0));
        errdefer allocator.free(origin);
        const key = try allocator.dupe(u8, row.get([]const u8, 1));
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, row.get([]const u8, 2));
        try out.append(allocator, .{ .origin = origin, .key = key, .value = value });
    }
    return out.toOwnedSlice(allocator);
}

pub fn hasProfile(self: *Store) !bool {
    const conn = try self.sqlite.pool.acquire();
    defer self.sqlite.pool.release(conn);
    return try conn.scalar(bool, "select exists(select 1 from profiles where profile_id=?1)", .{self.profile_id}) orelse false;
}

pub fn loadCookies(self: *Store, allocator: Allocator) ![]model.StoredCookie {
    const conn = try self.sqlite.pool.acquire();
    defer self.sqlite.pool.release(conn);
    var rows = try conn.rows("select partition_site, name, domain, path, value, expires, secure, http_only, same_site, source_secure, source_port, partitioned from cookies where profile_id=?1 order by update_seq", .{self.profile_id});
    defer rows.deinit();
    var out: std.ArrayList(model.StoredCookie) = .empty;
    errdefer {
        for (out.items) |item| item.deinit(allocator);
        out.deinit(allocator);
    }
    while (try rows.next()) |row| {
        const partition_site = try allocator.dupe(u8, row.get([]const u8, 0));
        errdefer allocator.free(partition_site);
        const name = try allocator.dupe(u8, row.get([]const u8, 1));
        errdefer allocator.free(name);
        const domain = try allocator.dupe(u8, row.get([]const u8, 2));
        errdefer allocator.free(domain);
        const path = try allocator.dupe(u8, row.get([]const u8, 3));
        errdefer allocator.free(path);
        const value = try allocator.dupe(u8, row.get([]const u8, 4));
        try out.append(allocator, .{
            .key = .{ .partition_site = partition_site, .name = name, .domain = domain, .path = path },
            .value = value,
            .expires = row.get(?f64, 5),
            .secure = row.get(bool, 6),
            .http_only = row.get(bool, 7),
            .same_site = @intCast(row.get(i64, 8)),
            .source_secure = row.get(bool, 9),
            .source_port = @intCast(row.get(i64, 10)),
            .partitioned = row.get(bool, 11),
        });
    }
    return out.toOwnedSlice(allocator);
}

test "SQLite Store persists browser state across reopen" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(runtime_io.get(), ".", testing.allocator);
    defer testing.allocator.free(root);
    const path = try std.fs.path.joinZ(testing.allocator, &.{ root, "state.sqlite" });
    defer testing.allocator.free(path);

    var store = try Store.create(testing.allocator, path, "profile-a");
    try testing.expectError(error.StorageWriterAlreadyActive, Store.create(testing.allocator, path, "profile-b"));
    try store.localSet("https://example.com", "key", "one");
    try store.localSet("https://example.com", "key", "two");

    const SameSite = enum { strict, lax, none };
    try store.cookieUpsert(.{
        .partition_site = @as(?[]const u8, null),
        .name = "sid",
        .domain = "example.com",
        .path = "/",
        .value = "abc",
        .expires = @as(?f64, null),
        .secure = true,
        .http_only = true,
        .same_site = SameSite.lax,
        .source_secure = true,
        .source_port = @as(u16, 443),
        .partitioned = false,
    });
    try store.flush();
    store.destroy();

    store = try Store.create(testing.allocator, path, "profile-a");
    defer store.destroy();

    const local = try store.loadLocal(testing.allocator);
    defer {
        for (local) |item| item.deinit(testing.allocator);
        testing.allocator.free(local);
    }
    try testing.expectEqual(@as(usize, 1), local.len);
    try testing.expectEqualStrings("two", local[0].value);

    const stored_cookies = try store.loadCookies(testing.allocator);
    defer {
        for (stored_cookies) |item| item.deinit(testing.allocator);
        testing.allocator.free(stored_cookies);
    }
    try testing.expectEqual(@as(usize, 1), stored_cookies.len);
    try testing.expectEqualStrings("sid", stored_cookies[0].key.name);
    try testing.expectEqualStrings("abc", stored_cookies[0].value);

    try store.localClear("https://example.com");
    try store.cookieClear();
    try store.flush();
}
