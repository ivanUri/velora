const std = @import("std");
const runtime_io = @import("../../support/io.zig");
const BrowserRoot = @import("BrowserRoot.zig");
const ProfilePaths = @import("ProfilePaths.zig");

const Allocator = std.mem.Allocator;

pub const folder_name = "fingerprint";
pub const definition_filename = "fingerprint.json";

/// A fingerprint is one self-contained folder. All asset paths in
/// fingerprint.json are relative to `root`.
pub const Source = struct {
    root: []const u8,
    definition_path: []const u8,
    id: []const u8,

    pub fn deinit(self: *Source, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.definition_path);
        allocator.free(self.root);
        self.* = undefined;
    }
};

pub fn installedFolder(allocator: Allocator, id: []const u8) ![]const u8 {
    if (!isValidId(id)) return error.InvalidFingerprintId;
    const install_root = try BrowserRoot.get(allocator);
    return std.fs.path.join(allocator, &.{ install_root, "browser", "fingerprints", id });
}

pub fn embeddedFolder(allocator: Allocator, profile_dir: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ profile_dir, folder_name });
}

pub fn resolve(
    allocator: Allocator,
    paths: *const ProfilePaths.ProfilePaths,
    override_folder: ?[]const u8,
) !Source {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const prefs = try paths.readPreferences(arena.allocator());

    if (override_folder) |folder| {
        return sourceFromFolder(allocator, folder, "");
    }

    const embedded = try embeddedFolder(allocator, paths.profile_dir);
    if (folderContainsFingerprint(embedded)) {
        defer allocator.free(embedded);
        return sourceFromFolder(allocator, embedded, prefs.fingerprint);
    }
    allocator.free(embedded);

    const installed = try installedFolder(allocator, prefs.fingerprint);
    defer allocator.free(installed);
    return sourceFromFolder(allocator, installed, prefs.fingerprint);
}

fn sourceFromFolder(allocator: Allocator, folder: []const u8, expected_id: []const u8) !Source {
    if (std.mem.endsWith(u8, folder, ".json")) return error.FingerprintMustBeFolder;
    const definition = try std.fs.path.join(allocator, &.{ folder, definition_filename });
    errdefer allocator.free(definition);
    if (!fileExists(definition)) return error.FingerprintNotFound;

    return .{
        .root = try allocator.dupe(u8, folder),
        .definition_path = definition,
        .id = try allocator.dupe(u8, expected_id),
    };
}

fn folderContainsFingerprint(folder: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ folder, definition_filename }) catch return false;
    return fileExists(path);
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(runtime_io.get(), path, .{}) catch return false;
    return true;
}

fn isValidId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128 or std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return false;
    for (id) |c| {
        if (c < 0x20 or c == '/' or c == '\\') return false;
    }
    return true;
}

const testing = @import("../../testing/testing.zig");

test "FingerprintStore: explicit source is a folder" {
    const allocator = std.testing.allocator;
    const base = "/tmp/koko-fingerprint-folder-test";
    const profile_dir = "/tmp/koko-fingerprint-folder-test/profile";
    const fingerprint_dir = "/tmp/koko-fingerprint-folder-test/artifact";
    const io = runtime_io.get();
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, fingerprint_dir);
    var file = try std.Io.Dir.cwd().createFile(
        io,
        "/tmp/koko-fingerprint-folder-test/artifact/fingerprint.json",
        .{},
    );
    file.close(io);

    var paths = try ProfilePaths.ProfilePaths.init(allocator, base, "profile", fingerprint_dir);
    defer paths.deinit();
    try std.Io.Dir.cwd().createDirPath(io, profile_dir);

    var source = try resolve(allocator, &paths, fingerprint_dir);
    defer source.deinit(allocator);
    try testing.expectEqualStrings(fingerprint_dir, source.root);
}

test "FingerprintStore: json file override is rejected" {
    const allocator = std.testing.allocator;
    var paths = try ProfilePaths.ProfilePaths.init(allocator, "/tmp/unused", "profile", null);
    defer paths.deinit();
    try testing.expectError(
        error.FingerprintMustBeFolder,
        resolve(allocator, &paths, "/tmp/fingerprint.json"),
    );
}
