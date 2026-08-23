const std = @import("std");
const runtime_io = @import("../support/io.zig");
const datetime = @import("../support/datetime.zig");
const Session = @import("../core/browser/Session.zig");
const Config = @import("Config.zig");
const cookies = @import("cookies.zig");
const session_persist = @import("session_persist.zig");
const Checkpoint = @import("execution/Checkpoint.zig");
const log = @import("../support/log.zig");
const Cookie = @import("../core/webapi/storage/Cookie.zig");
const StoredCookie = @import("storage/Command.zig").StoredCookie;

fn cookieFileUsable(path: []const u8) bool {
    const io = runtime_io.get();
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    const size = (file.stat(io) catch return false).size;
    return size > 2;
}

/// Load cookies + localStorage from the active profile directory.
pub fn bootstrapCookies(session: *Session, config: *const Config) void {
    if (session.browser.app.storage.usesSqlite()) {
        bootstrapSqlite(session, config);
    } else {
        bootstrapJson(session, config);
    }
    // Restore is last so an explicit execution checkpoint wins over the
    // profile baseline and any CLI cookie seed.
    restoreExecutionCheckpoint(session, config);
}

/// Restores a checkpoint only when the caller explicitly supplies its local
/// directory. This is intentionally separate from profile state: a replay
/// should be able to override the profile baseline without changing it.
pub fn restoreExecutionCheckpoint(session: *Session, config: *const Config) void {
    const allocator = session.browser.app.allocator;
    const directory = config.executionRestoreDir() orelse return;

    Checkpoint.validate(allocator, directory) catch |err| {
        log.err(.app, "execution checkpoint manifest", .{ .directory = directory, .err = err });
        return;
    };

    const cookies_path = std.fs.path.join(allocator, &.{ directory, "cookies.json" }) catch |err| {
        log.err(.app, "execution checkpoint cookie path", .{ .directory = directory, .err = err });
        return;
    };
    defer allocator.free(cookies_path);
    if (!checkpointFilesPresent(directory, cookies_path)) {
        log.err(.app, "execution checkpoint files", .{ .directory = directory, .err = error.FileNotFound });
        return;
    }
    cookies.loadFromFile(session, cookies_path);
    session_persist.loadStorageDir(session, directory);
    log.info(.app, "execution checkpoint restored", .{ .directory = directory });
}

/// Save browser state that can be reconstructed by a future process. The
/// directory contains cookie and web-storage values, so callers must choose a
/// private, non-versioned location.
pub fn saveExecutionCheckpoint(session: *Session, url: []const u8) void {
    const allocator = session.browser.app.allocator;
    const directory = session.browser.app.config.executionCheckpointDir() orelse return;

    std.Io.Dir.cwd().createDirPath(runtime_io.get(), directory) catch |err| {
        log.err(.app, "execution checkpoint directory", .{ .directory = directory, .err = err });
        return;
    };
    const cookies_path = std.fs.path.join(allocator, &.{ directory, "cookies.json" }) catch |err| {
        log.err(.app, "execution checkpoint cookie path", .{ .directory = directory, .err = err });
        return;
    };
    defer allocator.free(cookies_path);

    cookies.saveToFile(&session.cookie_jar, cookies_path);
    session_persist.saveStorageDir(session, directory);
    if (!checkpointFilesPresent(directory, cookies_path)) {
        log.err(.app, "execution checkpoint write", .{ .directory = directory, .err = error.FileNotFound });
        return;
    }

    const counts = storageCounts(session);
    Checkpoint.write(directory, .{
        .createdAtMs = @intCast(datetime.milliTimestamp(.clock)),
        .url = url,
        .cookieCount = session.cookie_jar.cookies.items.len,
        .localStorageEntries = counts.local,
        .sessionStorageEntries = counts.session,
    }) catch |err| {
        log.err(.app, "execution checkpoint manifest", .{ .directory = directory, .err = err });
        return;
    };

    session.browser.app.network.emitExecutionCheckpoint(url, session.cookie_jar.cookies.items.len, counts.local, counts.session);
    log.info(.app, "execution checkpoint saved", .{ .directory = directory, .cookies = session.cookie_jar.cookies.items.len, .local_storage = counts.local, .session_storage = counts.session });
}

const StorageCounts = struct { local: usize = 0, session: usize = 0 };

fn storageCounts(session: *const Session) StorageCounts {
    var result: StorageCounts = .{};
    var origins = session.storage_shed._origins.iterator();
    while (origins.next()) |origin| {
        result.local += origin.value_ptr.*.local._data.count();
        result.session += origin.value_ptr.*.session._data.count();
    }
    return result;
}

fn checkpointFilesPresent(directory: []const u8, cookies_path: []const u8) bool {
    std.Io.Dir.cwd().access(runtime_io.get(), cookies_path, .{}) catch return false;
    var storage_path_buf: [512]u8 = undefined;
    const storage_path = session_persist.storageFilePath(directory, &storage_path_buf) orelse return false;
    std.Io.Dir.cwd().access(runtime_io.get(), storage_path, .{}) catch return false;
    return true;
}

fn bootstrapJson(session: *Session, config: *const Config) void {
    var jar_buf: [512]u8 = undefined;
    if (config.cookieJarFile(&jar_buf)) |jar_path| {
        if (cookieFileUsable(jar_path)) {
            cookies.loadFromFile(session, jar_path);
            log.info(.app, "profile_session.bootstrap", .{ .source = "profile", .path = jar_path });
        }
    }

    // Cookies and Web Storage are independent profile state. A missing or
    // empty cookie jar must not suppress a valid localStorage snapshot.
    var ls_buf: [512]u8 = undefined;
    if (config.localStorageDir(&ls_buf)) |ls_dir| {
        session_persist.loadStorageDir(session, ls_dir);
    }

    if (config.cookieCliOverride()) |cli_path| {
        cookies.loadFromFile(session, cli_path);
    }
}

fn bootstrapSqlite(session: *Session, config: *const Config) void {
    const storage = &session.browser.app.storage;
    // Bootstrap is a state restore, not a new mutation stream. Re-enable the
    // sink after the baseline is installed to avoid echoing every loaded row.
    session.cookie_jar.setMutationSink(null);
    // A new session must observe every mutation accepted from older sessions
    // before reading its profile snapshot.
    storage.flush() catch |err| log.err(.storage, "profile sqlite pre-load flush", .{ .err = err });
    const has_profile = storage.hasProfile() catch |err| {
        log.err(.storage, "profile sqlite probe", .{ .err = err });
        bootstrapJson(session, config);
        session.enableProfilePersistence();
        restoreExecutionCheckpoint(session, config);
        return;
    };

    if (has_profile) {
        loadSqliteState(session) catch |err| {
            log.err(.storage, "profile sqlite bootstrap", .{ .err = err });
        };
    } else {
        // First open: import the existing JSON state without deleting it. The
        // first durable SQLite transaction creates the profile marker.
        bootstrapJson(session, config);
    }

    session.enableProfilePersistence();
    if (!has_profile) {
        session.enqueueCurrentProfileState();
        storage.flush() catch |err| log.err(.storage, "profile sqlite import", .{ .err = err });
    }

    // CLI cookie input remains an explicit override and is applied after the
    // durable profile baseline. Jar hooks enqueue those mutations.
    if (config.cookieCliOverride()) |cli_path| cookies.loadFromFile(session, cli_path);
}

fn loadSqliteState(session: *Session) !void {
    const storage = &session.browser.app.storage;
    const dto_allocator = session.browser.app.allocator;

    const local_rows = try storage.loadLocal(dto_allocator);
    defer {
        for (local_rows) |row| row.deinit(dto_allocator);
        dto_allocator.free(local_rows);
    }
    for (local_rows) |row| {
        const bucket = try session.storage_shed.getOrPut(session.arena, row.origin);
        try bucket.local.put(session.arena, row.key, row.value);
    }

    const stored_cookies = try storage.loadCookies(dto_allocator);
    defer {
        for (stored_cookies) |stored| stored.deinit(dto_allocator);
        dto_allocator.free(stored_cookies);
    }
    const now: i64 = @intCast(datetime.timestamp(.clock));
    for (stored_cookies) |stored| {
        if (stored.same_site > @intFromEnum(Cookie.SameSite.none)) continue;
        const cookie = try restoreCookie(session.cookie_jar.allocator, stored);
        try session.cookie_jar.add(cookie, now, true);
    }
}

fn restoreCookie(backing_allocator: std.mem.Allocator, stored: StoredCookie) !Cookie {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    // ArenaAllocator carries mutable allocation state. Finish every allocation
    // before copying it into Cookie; copying an empty arena first and allocating
    // through the original would leave Cookie.deinit() with a stale empty owner.
    const name = try allocator.dupe(u8, stored.key.name);
    const value = try allocator.dupe(u8, stored.value);
    const domain = try allocator.dupe(u8, stored.key.domain);
    const path = try allocator.dupe(u8, stored.key.path);
    const partition_site = if (stored.key.partition_site.len == 0) null else try allocator.dupe(u8, stored.key.partition_site);

    return .{
        .arena = arena,
        .name = name,
        .value = value,
        .domain = domain,
        .path = path,
        .expires = stored.expires,
        .secure = stored.secure,
        .http_only = stored.http_only,
        .same_site = @enumFromInt(stored.same_site),
        .source_secure = stored.source_secure,
        .source_port = stored.source_port,
        .partitioned = stored.partitioned,
        .partition_site = partition_site,
    };
}

fn ensureParentDir(path: []const u8) void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;
    std.Io.Dir.cwd().createDirPath(runtime_io.get(), parent) catch {};
}

/// Persist cookies into runtime jar (CLI `--cookie-jar` or profile `Cookies.json`).
/// Also mirrors into CLI override when both profile and `--cookie` seed paths exist.
pub fn persistCookies(session: *Session, config: *const Config) void {
    if (session.browser.app.storage.usesSqlite()) {
        session.browser.app.storage.flush() catch |err| log.err(.storage, "profile sqlite flush", .{ .err = err });
        return;
    }

    var jar_buf: [512]u8 = undefined;
    if (config.cookieJarFile(&jar_buf)) |jar_path| {
        ensureParentDir(jar_path);
        cookies.saveToFile(&session.cookie_jar, jar_path);
        log.info(.app, "profile_session.persist", .{ .path = jar_path, .count = session.cookie_jar.cookies.items.len });
    }

    // Optional second write when `--cookie` seed path differs from runtime jar.
    if (config.cookieCliOverride()) |cli_path| {
        var jar_buf2: [512]u8 = undefined;
        const primary = config.cookieJarFile(&jar_buf2);
        if (primary == null or !std.mem.eql(u8, primary.?, cli_path)) {
            ensureParentDir(cli_path);
            cookies.saveToFile(&session.cookie_jar, cli_path);
        }
    }

    var ls_buf: [512]u8 = undefined;
    if (config.localStorageDir(&ls_buf)) |ls_dir| {
        session_persist.saveStorageDir(session, ls_dir);
    }
}

test "profile sqlite restore transfers the populated cookie arena" {
    const testing = std.testing;
    var partition_site = [_]u8{};
    var name = [_]u8{ 's', 'i', 'd' };
    var domain = [_]u8{ 'e', 'x', 'a', 'm', 'p', 'l', 'e', '.', 't', 'e', 's', 't' };
    var path = [_]u8{'/'};
    var value = [_]u8{ 'v', 'a', 'l', 'u', 'e' };
    var cookie = try restoreCookie(testing.allocator, .{
        .key = .{
            .partition_site = &partition_site,
            .name = &name,
            .domain = &domain,
            .path = &path,
        },
        .value = &value,
        .expires = null,
        .secure = true,
        .http_only = true,
        .same_site = @intFromEnum(Cookie.SameSite.lax),
        .source_secure = true,
        .source_port = 443,
        .partitioned = false,
    });
    defer cookie.deinit();

    try testing.expectEqualStrings("sid", cookie.name);
    try testing.expectEqualStrings("value", cookie.value);
    try testing.expectEqualStrings("example.test", cookie.domain);
    try testing.expectEqualStrings("/", cookie.path);
    try testing.expect(cookie.partition_site == null);
}
