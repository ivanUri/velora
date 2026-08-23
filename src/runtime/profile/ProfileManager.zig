const std = @import("std");
const runtime_io = @import("../../support/io.zig");
const ProfilePaths = @import("ProfilePaths.zig");
const FingerprintStore = @import("FingerprintStore.zig");
const log = @import("../../support/log.zig");

const Allocator = std.mem.Allocator;

pub const local_state_filename = "Local State.json";

pub const LocalState = struct {
    version: u32 = 1,
    profiles: []const []const u8 = &.{},
    last_used: []const u8 = ProfilePaths.default_profile_name,
};

pub const ProfileEntry = struct {
    name: []const u8,
    fingerprint: []const u8,
    profile_dir: []const u8,
};

pub fn defaultFingerprintForName(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, ProfilePaths.default_profile_name)) return "koko";
    return name;
}

pub fn localStatePath(user_data_dir: []const u8, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ user_data_dir, local_state_filename }) catch null;
}

fn isValidProfileName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name) |c| {
        if (c < 0x20 or c == '/' or c == '\\') return false;
    }
    return true;
}

fn emptyLocalState(allocator: Allocator) !LocalState {
    return .{
        .profiles = try allocator.alloc([]const u8, 0),
        .last_used = try allocator.dupe(u8, ProfilePaths.default_profile_name),
    };
}

/// JSON parse may leave struct defaults as static literals; filter corrupt entries.
fn sanitizeLocalState(allocator: Allocator, state: LocalState) !LocalState {
    var profiles = try std.ArrayList([]const u8).initCapacity(allocator, state.profiles.len);
    errdefer {
        for (profiles.items) |n| allocator.free(n);
        profiles.deinit(allocator);
    }

    for (state.profiles) |name| {
        if (!isValidProfileName(name)) continue;
        try profiles.append(allocator, try allocator.dupe(u8, name));
    }

    const last_used = if (isValidProfileName(state.last_used))
        try allocator.dupe(u8, state.last_used)
    else
        try allocator.dupe(u8, ProfilePaths.default_profile_name);

    return .{
        .version = state.version,
        .profiles = try profiles.toOwnedSlice(allocator),
        .last_used = last_used,
    };
}

pub fn loadLocalState(allocator: Allocator, user_data_dir: []const u8) !LocalState {
    var path_buf: [512]u8 = undefined;
    const path = localStatePath(user_data_dir, &path_buf) orelse return error.PathTooLong;

    const bytes = std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), path, allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return try emptyLocalState(allocator),
        else => return err,
    };
    defer allocator.free(bytes);

    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(LocalState, parse_arena.allocator(), bytes, .{
        .ignore_unknown_fields = true,
    }) catch return try emptyLocalState(allocator);
    return try sanitizeLocalState(allocator, parsed);
}

pub fn saveLocalState(allocator: Allocator, user_data_dir: []const u8, state: LocalState) !void {
    const io = runtime_io.get();
    try std.Io.Dir.cwd().createDirPath(io, user_data_dir);
    var path_buf: [512]u8 = undefined;
    const path = localStatePath(user_data_dir, &path_buf) orelse return error.PathTooLong;

    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try std.json.Stringify.value(state, .{}, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.end();
    _ = allocator;
}

pub fn discoverProfiles(allocator: Allocator, user_data_dir: []const u8) ![][]const u8 {
    var names = try std.ArrayList([]const u8).initCapacity(allocator, 8);
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    const io = runtime_io.get();
    var dir = try std.Io.Dir.cwd().openDir(io, user_data_dir, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name[0] == '.') continue;
        if (!isValidProfileName(entry.name)) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    return try names.toOwnedSlice(allocator);
}

pub fn syncLocalState(allocator: Allocator, user_data_dir: []const u8) !LocalState {
    const discovered = try discoverProfiles(allocator, user_data_dir);
    defer {
        for (discovered) |n| allocator.free(n);
        allocator.free(discovered);
    }

    var state = try loadLocalState(allocator, user_data_dir);
    errdefer freeLocalState(allocator, &state);

    for (state.profiles) |n| allocator.free(n);
    allocator.free(state.profiles);

    var profiles = try std.ArrayList([]const u8).initCapacity(allocator, discovered.len);
    errdefer {
        for (profiles.items) |n| allocator.free(n);
        profiles.deinit(allocator);
    }
    for (discovered) |name| {
        try profiles.append(allocator, try allocator.dupe(u8, name));
    }
    state.profiles = try profiles.toOwnedSlice(allocator);

    var last_ok = false;
    for (state.profiles) |n| {
        if (std.mem.eql(u8, n, state.last_used)) {
            last_ok = true;
            break;
        }
    }
    if (!last_ok and state.profiles.len > 0) {
        allocator.free(state.last_used);
        state.last_used = try allocator.dupe(u8, state.profiles[0]);
    } else if (!last_ok) {
        allocator.free(state.last_used);
        state.last_used = try allocator.dupe(u8, ProfilePaths.default_profile_name);
    }

    try saveLocalState(allocator, user_data_dir, state);
    return state;
}

pub fn freeLocalState(allocator: Allocator, state: *LocalState) void {
    for (state.profiles) |n| allocator.free(n);
    allocator.free(state.profiles);
    allocator.free(state.last_used);
    state.* = .{};
}

pub fn recordLastUsed(allocator: Allocator, user_data_dir: []const u8, profile_name: []const u8) !void {
    var state = try syncLocalState(allocator, user_data_dir);
    defer freeLocalState(allocator, &state);

    allocator.free(state.last_used);
    state.last_used = try allocator.dupe(u8, profile_name);
    try saveLocalState(allocator, user_data_dir, state);
}

pub fn resolveActiveProfileName(
    allocator: Allocator,
    user_data_dir: []const u8,
    cli_name: ?[]const u8,
    pool_pick: ?[]const u8,
) ![]const u8 {
    if (cli_name) |name| return try allocator.dupe(u8, name);
    if (pool_pick) |name| return try allocator.dupe(u8, name);
    _ = user_data_dir;
    return try allocator.dupe(u8, ProfilePaths.default_profile_name);
}

pub fn fingerprintExists(id: []const u8) !bool {
    const folder = FingerprintStore.installedFolder(std.heap.page_allocator, id) catch return false;
    defer std.heap.page_allocator.free(folder);
    const definition = try std.fs.path.join(std.heap.page_allocator, &.{ folder, FingerprintStore.definition_filename });
    defer std.heap.page_allocator.free(definition);
    return fileExists(definition);
}

fn fileExists(path: []const u8) !bool {
    std.Io.Dir.cwd().access(runtime_io.get(), path, .{}) catch return false;
    return true;
}

pub fn createProfile(
    allocator: Allocator,
    user_data_dir: []const u8,
    name: []const u8,
    fingerprint: []const u8,
) !void {
    if (name.len == 0) return error.InvalidProfileName;
    if (!try fingerprintExists(fingerprint)) return error.UnknownFingerprint;

    var paths = try ProfilePaths.ProfilePaths.init(allocator, user_data_dir, name, null);
    defer paths.deinit();

    var prefs_buf: [512]u8 = undefined;
    const prefs_path = paths.preferencesPath(&prefs_buf) orelse return error.PathTooLong;

    if (try fileExists(prefs_path)) return error.ProfileAlreadyExists;

    const io = runtime_io.get();
    try std.Io.Dir.cwd().createDirPath(io, paths.user_data_dir);
    try std.Io.Dir.cwd().createDirPath(io, paths.profile_dir);
    try writePreferences(prefs_path, .{
        .version = 3,
        .name = name,
        .fingerprint = fingerprint,
    });

    var state = try syncLocalState(allocator, user_data_dir);
    defer freeLocalState(allocator, &state);
    try recordLastUsed(allocator, user_data_dir, name);

    log.info(.app, "profile_manager.create", .{ .name = name, .fingerprint = fingerprint, .dir = paths.profile_dir });
}

pub fn deleteProfile(allocator: Allocator, user_data_dir: []const u8, name: []const u8) !void {
    if (std.mem.eql(u8, name, ProfilePaths.default_profile_name)) return error.CannotDeleteDefaultProfile;

    var paths = try ProfilePaths.ProfilePaths.init(allocator, user_data_dir, name, null);
    defer paths.deinit();

    try std.Io.Dir.cwd().deleteTree(runtime_io.get(), paths.profile_dir);

    var state = try syncLocalState(allocator, user_data_dir);
    defer freeLocalState(allocator, &state);

    var kept = try std.ArrayList([]const u8).initCapacity(allocator, state.profiles.len);
    defer kept.deinit(allocator);

    for (state.profiles) |n| {
        if (!std.mem.eql(u8, n, name)) {
            try kept.append(allocator, try allocator.dupe(u8, n));
        }
    }
    allocator.free(state.profiles);
    state.profiles = try kept.toOwnedSlice(allocator);

    if (std.mem.eql(u8, state.last_used, name)) {
        allocator.free(state.last_used);
        state.last_used = if (state.profiles.len > 0)
            try allocator.dupe(u8, state.profiles[0])
        else
            try allocator.dupe(u8, ProfilePaths.default_profile_name);
    }

    try saveLocalState(allocator, user_data_dir, state);
    log.info(.app, "profile_manager.delete", .{ .name = name });
}

pub fn importCookies(
    allocator: Allocator,
    user_data_dir: []const u8,
    name: []const u8,
    from_path: []const u8,
) !void {
    var paths = try ProfilePaths.ProfilePaths.init(allocator, user_data_dir, name, null);
    defer paths.deinit();

    var prefs_buf: [512]u8 = undefined;
    const prefs_path = paths.preferencesPath(&prefs_buf) orelse return error.PathTooLong;
    if (try fileExists(prefs_path)) {
        try paths.ensureProfileReadyWithFingerprint(defaultFingerprintForName(name));
    } else {
        try createProfile(allocator, user_data_dir, name, defaultFingerprintForName(name));
    }

    const cookies_path = try paths.cookiesPathAlloc();
    defer allocator.free(cookies_path);

    const io = runtime_io.get();
    try std.Io.Dir.cwd().createDirPath(io, paths.profile_dir);
    try std.Io.Dir.cwd().copyFile(from_path, .cwd(), cookies_path, io, .{});

    var state = try syncLocalState(allocator, user_data_dir);
    defer freeLocalState(allocator, &state);
    log.info(.app, "profile_manager.import_cookies", .{ .name = name, .from = from_path, .to = cookies_path });
}

pub fn listProfileEntries(allocator: Allocator, user_data_dir: []const u8) ![]ProfileEntry {
    var state = try syncLocalState(allocator, user_data_dir);
    defer freeLocalState(allocator, &state);

    var out = try std.ArrayList(ProfileEntry).initCapacity(allocator, state.profiles.len);
    errdefer out.deinit(allocator);

    for (state.profiles) |name| {
        var paths = try ProfilePaths.ProfilePaths.init(allocator, user_data_dir, name, null);
        defer paths.deinit();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const prefs = paths.readPreferences(arena.allocator()) catch ProfilePaths.Preferences{
            .name = name,
            .fingerprint = defaultFingerprintForName(name),
        };

        try out.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .fingerprint = try allocator.dupe(u8, prefs.fingerprint),
            .profile_dir = try allocator.dupe(u8, paths.profile_dir),
        });
    }

    return try out.toOwnedSlice(allocator);
}

pub fn freeProfileEntries(allocator: Allocator, entries: []ProfileEntry) void {
    for (entries) |e| {
        allocator.free(e.name);
        allocator.free(e.fingerprint);
        allocator.free(e.profile_dir);
    }
    allocator.free(entries);
}

pub fn ensureFirstRun(allocator: Allocator, user_data_dir: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(runtime_io.get(), user_data_dir);
    if (!try fingerprintExists("koko")) return;

    var default_paths = try ProfilePaths.ProfilePaths.init(allocator, user_data_dir, ProfilePaths.default_profile_name, null);
    defer default_paths.deinit();
    try default_paths.ensureProfileReadyWithFingerprint("koko");

    var state = try syncLocalState(allocator, user_data_dir);
    defer freeLocalState(allocator, &state);
}

fn writePreferences(path: []const u8, prefs: ProfilePaths.Preferences) !void {
    const io = runtime_io.get();
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    try std.json.Stringify.value(.{
        .version = 3,
        .name = prefs.name,
        .fingerprint = prefs.fingerprint,
        .created = prefs.created,
    }, .{}, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.end();
}

const testing = @import("../../testing/testing.zig");

test "ProfileManager: default fingerprint mapping" {
    try testing.expectEqualStrings("koko", defaultFingerprintForName("Default"));
    try testing.expectEqualStrings("chrome-macos-sonoma", defaultFingerprintForName("chrome-macos-sonoma"));
}
