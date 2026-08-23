const std = @import("std");
const BrowserRoot = @import("profile/BrowserRoot.zig");
const ProfileManager = @import("profile/ProfileManager.zig");
const ProfilePaths = @import("profile/ProfilePaths.zig");
const runtime_io = @import("../support/io.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    action: ?[]const u8 = null,
    name: ?[]const u8 = null,
    fingerprint: ?[]const u8 = null,
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    user_data_dir: ?[]const u8 = null,
};

pub fn run(allocator: Allocator, opts: Options) !void {
    const user_data_dir_cli = opts.user_data_dir;
    const user_data_dir = if (user_data_dir_cli) |p|
        try allocator.dupe(u8, p)
    else
        try defaultUserDataDir(allocator);
    defer allocator.free(user_data_dir);

    const action = opts.action orelse {
        try printUsage();
        return error.MissingProfileAction;
    };

    if (std.mem.eql(u8, action, "list")) {
        try runList(allocator, user_data_dir);
        return;
    }
    if (std.mem.eql(u8, action, "create")) {
        const name = opts.name orelse {
            std.debug.print("error: --name required for profile create\n", .{});
            return error.MissingProfileName;
        };
        const fingerprint = opts.fingerprint orelse ProfileManager.defaultFingerprintForName(name);
        try ProfileManager.createProfile(allocator, user_data_dir, name, fingerprint);
        std.debug.print("created profile '{s}' (fingerprint: {s})\n", .{ name, fingerprint });
        return;
    }
    if (std.mem.eql(u8, action, "delete")) {
        const name = opts.name orelse {
            std.debug.print("error: --name required for profile delete\n", .{});
            return error.MissingProfileName;
        };
        try ProfileManager.deleteProfile(allocator, user_data_dir, name);
        std.debug.print("deleted profile '{s}'\n", .{name});
        return;
    }
    if (std.mem.eql(u8, action, "import-cookies") or std.mem.eql(u8, action, "import_cookies")) {
        const name = opts.name orelse ProfilePaths.default_profile_name;
        const from_path = opts.from orelse {
            std.debug.print("error: --from required for profile import-cookies\n", .{});
            return error.MissingImportPath;
        };
        try ProfileManager.importCookies(allocator, user_data_dir, name, from_path);
        std.debug.print("imported cookies into profile '{s}' from {s}\n", .{ name, from_path });
        return;
    }
    if (std.mem.eql(u8, action, "export")) {
        const name = opts.name orelse {
            std.debug.print("error: --name required for profile export\n", .{});
            return error.MissingProfileName;
        };
        try runBundleScript(allocator, &.{
            "export",
            "--name",
            name,
            "--user-data-dir",
            user_data_dir,
        }, opts.to);
        return;
    }
    if (std.mem.eql(u8, action, "import")) {
        const name = opts.name orelse {
            std.debug.print("error: --name required for profile import\n", .{});
            return error.MissingProfileName;
        };
        const from_path = opts.from orelse {
            std.debug.print("error: --from required for profile import\n", .{});
            return error.MissingImportPath;
        };
        try runBundleScript(allocator, &.{
            "import",
            "--from",
            from_path,
            "--name",
            name,
            "--user-data-dir",
            user_data_dir,
        }, null);
        return;
    }
    std.debug.print("error: unknown profile action '{s}'\n", .{action});
    try printUsage();
    return error.UnknownProfileAction;
}

fn runBundleScript(allocator: Allocator, args: []const []const u8, out_path: ?[]const u8) !void {
    const root = try BrowserRoot.get(allocator);
    const script = try BrowserRoot.joinPath(allocator, root, "scripts/profile-bundle.mjs");
    defer allocator.free(script);

    var argv = try std.ArrayList([]const u8).initCapacity(allocator, 4 + args.len + 2);
    defer argv.deinit(allocator);
    try argv.append(allocator, "node");
    try argv.append(allocator, script);
    try argv.append(allocator, "--koko-root");
    try argv.append(allocator, root);
    for (args) |arg| try argv.append(allocator, arg);
    if (out_path) |out| {
        try argv.append(allocator, "--out");
        try argv.append(allocator, out);
    }

    const io = runtime_io.get();
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer child.kill(io);
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) return error.BundleScriptFailed;
        },
        else => return error.BundleScriptFailed,
    }
}

fn runList(allocator: Allocator, user_data_dir: []const u8) !void {
    try ProfileManager.ensureFirstRun(allocator, user_data_dir);

    var state = try ProfileManager.loadLocalState(allocator, user_data_dir);
    defer ProfileManager.freeLocalState(allocator, &state);

    const entries = try ProfileManager.listProfileEntries(allocator, user_data_dir);
    defer ProfileManager.freeProfileEntries(allocator, entries);

    std.debug.print("user-data-dir: {s}\n", .{user_data_dir});
    std.debug.print("last-created: {s}\n\n", .{state.last_used});
    std.debug.print("{s:<24} {s:<32} {s}\n", .{ "NAME", "FINGERPRINT", "PATH" });
    for (entries) |e| {
        const marker = if (std.mem.eql(u8, e.name, state.last_used)) " *" else "";
        std.debug.print("{s:<24} {s:<32} {s}{s}\n", .{ e.name, e.fingerprint, e.profile_dir, marker });
    }
}

fn defaultUserDataDir(allocator: Allocator) ![]const u8 {
    return ProfilePaths.defaultUserDataDir(allocator);
}

fn printUsage() !void {
    var stdout = std.Io.File.stdout().writerStreaming(runtime_io.get(), &.{});
    try stdout.interface.writeAll(
        \\profile commands:
        \\  koko profile list
        \\  koko profile create --name <id> [--fingerprint <id>]
        \\  koko profile delete --name <id>
        \\  koko profile import-cookies [--name <id>] --from <cookies.json>
        \\  koko profile export --name <id> [--to <bundle-dir>]
        \\  koko profile import --name <id> --from <bundle-dir>
        \\
    );
}
