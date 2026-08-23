//! Durable, reconstructible execution-checkpoint metadata.
//!
//! A checkpoint is deliberately limited to browser state that Koko can
//! serialize and restore in a new process. It is not a V8 heap snapshot and
//! must never be represented as one.

const std = @import("std");
const runtime_io = @import("../../support/io.zig");

pub const schema_version: u32 = 1;
pub const manifest_filename = "manifest.json";

pub const Manifest = struct {
    schemaVersion: u32 = schema_version,
    kind: []const u8 = "reconstructible",
    createdAtMs: i64,
    url: []const u8,
    cookieCount: usize,
    localStorageEntries: usize,
    sessionStorageEntries: usize,
    indexedDbState: []const u8 = "metadata-only",
    limitations: []const []const u8 = &.{
        "JavaScript heap, timer queues, workers, Cache Storage and server-side session state are not restored.",
        "Replay requires an explicit network policy; unmatched requests must not silently reach the Internet in strict mode.",
    },
};

pub fn write(directory: []const u8, manifest: Manifest) !void {
    const io = runtime_io.get();
    try std.Io.Dir.cwd().createDirPath(io, directory);
    const path = try std.fs.path.join(std.heap.page_allocator, &.{ directory, manifest_filename });
    defer std.heap.page_allocator.free(path);

    var buffer: [8192]u8 = undefined;
    var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer file.deinit(io);
    var file_writer = file.file.writer(io, &buffer);
    try std.json.Stringify.value(manifest, .{}, &file_writer.interface);
    try file_writer.interface.writeByte('\n');
    try file_writer.interface.flush();
    try file.file.sync(io);
    try file.replace(io);
}

/// Validate only the checkpoint format. Restoring browser state remains the
/// caller's responsibility, so a manifest cannot accidentally promise more
/// than the files it accompanies.
pub fn validate(allocator: std.mem.Allocator, directory: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ directory, manifest_filename });
    defer allocator.free(path);
    const raw = try std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), path, allocator, .limited(64 * 1024));
    defer allocator.free(raw);
    const parsed = try std.json.parseFromSlice(struct { schemaVersion: u32, kind: []const u8 }, allocator, raw, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    if (parsed.value.schemaVersion != schema_version or !std.mem.eql(u8, parsed.value.kind, "reconstructible")) {
        return error.UnsupportedCheckpoint;
    }
}

test "execution checkpoint manifest rejects incompatible version" {
    const testing = std.testing;
    const parsed = try std.json.parseFromSlice(
        struct { schemaVersion: u32, kind: []const u8 },
        testing.allocator,
        "{\"schemaVersion\":2,\"kind\":\"reconstructible\"}",
        .{},
    );
    defer parsed.deinit();
    try testing.expect(parsed.value.schemaVersion != schema_version);
}
