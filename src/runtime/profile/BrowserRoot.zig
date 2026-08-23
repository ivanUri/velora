const std = @import("std");
const builtin = @import("builtin");
const log = @import("../../support/log.zig");
const runtime_io = @import("../../support/io.zig");

const Allocator = std.mem.Allocator;

var cached_root: ?[]const u8 = null;

/// Resolved install root containing `browser/` (absolute path, no trailing slash).
pub fn get(allocator: Allocator) ![]const u8 {
    if (cached_root) |root| return root;

    const root = try resolve(allocator);
    cached_root = root;
    return root;
}

pub fn deinitCache(allocator: Allocator) void {
    if (cached_root) |root| allocator.free(root);
    cached_root = null;
}

fn resolve(allocator: Allocator) ![]const u8 {
    if (builtin.is_test) {
        return try allocator.dupe(u8, ".");
    }

    const io = runtime_io.get();
    if (runtime_io.getenv("KOKO_ROOT")) |env_root| {
        const abs = try std.Io.Dir.cwd().realPathFileAlloc(io, env_root, allocator);
        if (browserBundleExists(abs)) return abs;
        allocator.free(abs);
        log.warn(.app, "browser_root.koko_root_invalid", .{ .path = env_root });
    }

    const exe = std.process.executablePathAlloc(io, allocator) catch null;
    if (exe) |exe_path| {
        defer allocator.free(exe_path);
        const exe_dir = std.fs.path.dirname(exe_path) orelse "";

        const dev_root = try std.fs.path.join(allocator, &.{ exe_dir, "..", ".." });
        if (browserBundleExists(dev_root)) {
            const abs = try std.Io.Dir.cwd().realPathFileAlloc(io, dev_root, allocator);
            allocator.free(dev_root);
            return abs;
        }
        allocator.free(dev_root);

        const share_root = try std.fs.path.join(allocator, &.{ exe_dir, "..", "share", "koko" });
        if (browserBundleExists(share_root)) {
            const abs = try std.Io.Dir.cwd().realPathFileAlloc(io, share_root, allocator);
            allocator.free(share_root);
            return abs;
        }
        allocator.free(share_root);
    }

    if (browserBundleExists(".")) {
        return try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    }

    return try allocator.dupe(u8, ".");
}

fn browserBundleExists(root: []const u8) bool {
    var buf: [512]u8 = undefined;
    const koko_json = std.fmt.bufPrint(
        &buf,
        "{s}/browser/fingerprints/koko/fingerprint.json",
        .{root},
    ) catch return false;
    std.Io.Dir.cwd().access(runtime_io.get(), koko_json, .{}) catch return false;
    return true;
}

pub fn joinPath(allocator: Allocator, root: []const u8, suffix: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ root, suffix });
}

const testing = @import("../../testing/testing.zig");

test "BrowserRoot: dev layout finds default fingerprint folder" {
    const root = try get(std.testing.allocator);
    var buf: [512]u8 = undefined;
    const path = try joinPath(std.testing.allocator, root, "browser/fingerprints/koko/fingerprint.json");
    defer std.testing.allocator.free(path);
    _ = std.fmt.bufPrint(&buf, "{s}", .{path}) catch unreachable;
    try std.Io.Dir.cwd().access(runtime_io.get(), path, .{});
}
