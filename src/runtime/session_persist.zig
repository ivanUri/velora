const std = @import("std");
const runtime_io = @import("../support/io.zig");
const Session = @import("../core/browser/Session.zig");
const log = @import("../support/log.zig");

const KeyValue = struct { key: []const u8, value: []const u8 };

const JsonEntry = struct {
    origin: []const u8,
    // Keep `local` optional on read so storage.json written by older Koko
    // versions remains a valid restore source.
    local: []const KeyValue = &.{},
    session: []const KeyValue = &.{},
};

pub const storage_filename = "storage.json";

pub fn storageFilePath(dir: []const u8, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, storage_filename }) catch null;
}

pub fn loadStorageDir(session: *Session, dir: []const u8) void {
    var path_buf: [512]u8 = undefined;
    const path = storageFilePath(dir, &path_buf) orelse return;
    loadStorage(session, path);
}

pub fn saveStorageDir(session: *Session, dir: []const u8) void {
    std.Io.Dir.cwd().createDirPath(runtime_io.get(), dir) catch {};
    var path_buf: [512]u8 = undefined;
    const path = storageFilePath(dir, &path_buf) orelse return;
    saveStorage(session, path);
}

/// @deprecated Sidecar format; use loadStorageDir.
pub fn storagePathForCookieJar(cookie_jar_path: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.storage.json", .{cookie_jar_path});
}

pub fn loadStorage(session: *Session, path: []const u8) void {
    _loadStorage(session, path) catch |err| {
        log.err(.app, "session_persist.loadStorage", .{ .path = path, .err = err });
    };
}

fn _loadStorage(session: *Session, path: []const u8) !void {
    const arena = try session.getArena(.medium, "session_persist.load");
    defer session.releaseArena(arena);

    const content = std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), path, arena, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };

    const entries = try std.json.parseFromSliceLeaky([]const JsonEntry, arena, content, .{
        .ignore_unknown_fields = true,
    });

    // Storage belongs to the browsing session. Allocate it from the session
    // arena so keys, values, buckets and hash-map backing storage share one
    // lifetime and are reclaimed together on Session.deinit.
    const allocator = session.arena;
    for (entries) |entry| {
        const bucket = try session.storage_shed.getOrPut(allocator, entry.origin);
        for (entry.local) |kv| {
            try bucket.local.put(allocator, kv.key, kv.value);
        }
        for (entry.session) |kv| {
            try bucket.session.put(allocator, kv.key, kv.value);
        }
    }
    log.info(.app, "session_persist.loadStorage", .{ .path = path, .origins = entries.len });
}

pub fn saveStorage(session: *Session, path: []const u8) void {
    _saveStorage(session, path) catch |err| {
        log.err(.app, "session_persist.saveStorage", .{ .path = path, .err = err });
    };
}

fn _saveStorage(session: *Session, path: []const u8) !void {
    // The JSON view is temporary; do not leave its owned slices on the app
    // allocator after every profile shutdown.
    const allocator = try session.getArena(.medium, "session_persist.save");
    defer session.releaseArena(allocator);
    var origins = try std.ArrayList(JsonEntry).initCapacity(allocator, 8);
    defer origins.deinit(allocator);

    var it = session.storage_shed._origins.iterator();
    while (it.next()) |kv| {
        var local_pairs = try std.ArrayList(KeyValue).initCapacity(allocator, 16);
        defer local_pairs.deinit(allocator);

        var lit = kv.value_ptr.*.local._data.iterator();
        while (lit.next()) |item| {
            try local_pairs.append(allocator, .{ .key = item.key_ptr.*, .value = item.value_ptr.* });
        }

        var session_pairs = try std.ArrayList(KeyValue).initCapacity(allocator, 16);
        defer session_pairs.deinit(allocator);
        var sit = kv.value_ptr.*.session._data.iterator();
        while (sit.next()) |item| {
            try session_pairs.append(allocator, .{ .key = item.key_ptr.*, .value = item.value_ptr.* });
        }

        if (local_pairs.items.len == 0 and session_pairs.items.len == 0) continue;
        try origins.append(allocator, .{
            .origin = kv.key_ptr.*,
            .local = try local_pairs.toOwnedSlice(allocator),
            .session = try session_pairs.toOwnedSlice(allocator),
        });
    }

    if (std.fs.path.dirname(path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(runtime_io.get(), parent);
    }

    const io = runtime_io.get();
    var buf: [8192]u8 = undefined;
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer atomic_file.deinit(io);
    var file_writer = atomic_file.file.writer(io, &buf);
    try std.json.Stringify.value(origins.items, .{}, &file_writer.interface);
    try file_writer.interface.writeByte('\n');
    try file_writer.interface.flush();
    try atomic_file.file.sync(io);
    try atomic_file.replace(io);
    log.info(.app, "session_persist.saveStorage", .{ .path = path, .origins = origins.items.len });
}
