//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const runtime_io = @import("../support/io.zig");
const ProfileStore = @import("profile/ProfileStore.zig");
const ProfilePaths = @import("profile/ProfilePaths.zig");
const ProfileManager = @import("profile/ProfileManager.zig");
const ProfileRotation = @import("profile/ProfileRotation.zig");
const ProfileRuntime = @import("profile/ProfileRuntime.zig");
const log = @import("../support/log.zig");
const builtin = @import("builtin");

const cli = @import("../support/cli.zig");
const dump = @import("../core/browser/dump.zig");

const mcp = @import("../protocols/mcp.zig");
const Storage = @import("storage/Storage.zig");
const WebBotAuthConfig = @import("network/WebBotAuth.zig").Config;
const ProxyPool = @import("network/ProxyPool.zig");

const Allocator = std.mem.Allocator;

pub const CDP_MAX_HTTP_REQUEST_SIZE = 4096;

// max message size
// +14 for max websocket payload overhead
// +140 for the max control packet that might be interleaved in a message
pub const CDP_MAX_MESSAGE_SIZE = 512 * 1024 + 14 + 140;

// TCP keepalive parameters applied to accepted CDP connections.
// Detection window ≈ IDLE + CNT * INTVL = 4 + 3*2 = 10s.
pub const CDP_KEEPALIVE_IDLE_S: c_int = 4;
pub const CDP_KEEPALIVE_INTVL_S: c_int = 2;
pub const CDP_KEEPALIVE_CNT: c_int = 3;
// Linux-only: abort when unacked writes (or silent peer) exceed this. Closes
// the gap where keepalive probes do not fire while a send buffer is full of
// unacked data (LP improve-dead-peer-detection).
pub const CDP_TCP_USER_TIMEOUT_MS: c_int = 10_000;

const Config = @This();

/// Controls optional document subresources. The policy is applied before a
/// network transfer is admitted, while image deferral is coordinated by the
/// owning Frame so DOM lifecycle and image completion remain coherent.
pub const ResourcePolicy = enum {
    full,
    no_images,
    no_css,
    text_only,
    defer_images,

    pub fn allowsImages(self: ResourcePolicy) bool {
        return self != .no_images and self != .text_only;
    }

    pub fn allowsExternalStylesheets(self: ResourcePolicy) bool {
        return self != .no_css and self != .text_only;
    }

    pub fn defersImages(self: ResourcePolicy) bool {
        return self == .defer_images;
    }
};

fn resourcePolicyValidator(_: Allocator, args: *cli.ArgIterator) !?ResourcePolicy {
    const raw = args.next() orelse {
        log.fatal(.app, "missing argument value", .{ .arg = "--resource-policy" });
        return error.MissingArgument;
    };

    if (std.ascii.eqlIgnoreCase(raw, "full")) return .full;
    if (std.ascii.eqlIgnoreCase(raw, "no-images") or std.ascii.eqlIgnoreCase(raw, "no_images")) return .no_images;
    if (std.ascii.eqlIgnoreCase(raw, "no-css") or std.ascii.eqlIgnoreCase(raw, "no_css")) return .no_css;
    if (std.ascii.eqlIgnoreCase(raw, "text-only") or std.ascii.eqlIgnoreCase(raw, "text_only")) return .text_only;
    if (std.ascii.eqlIgnoreCase(raw, "defer-images") or std.ascii.eqlIgnoreCase(raw, "defer_images")) return .defer_images;

    log.fatal(.app, "invalid option choice", .{ .arg = "--resource-policy", .value = raw });
    return error.InvalidArgument;
}

fn logFilterScopesValidator(allocator: Allocator, args: *cli.ArgIterator, list: *std.ArrayList(log.Scope)) !void {
    const str = args.next() orelse return error.InvalidOption;

    var it = std.mem.splitScalar(u8, str, ',');
    while (it.next()) |part| {
        const v = std.meta.stringToEnum(log.Scope, part) orelse {
            log.fatal(.app, "invalid option choice", .{ .arg = "--log-filter-scopes", .value = part });
            return error.InvalidOption;
        };

        try list.append(allocator, v);
    }
}

fn logLevelValidator(_: Allocator, args: *cli.ArgIterator) !?log.Level {
    const str = args.next() orelse return error.MissingArgument;
    if (std.mem.eql(u8, str, "error")) {
        return .err;
    }

    return std.meta.stringToEnum(log.Level, str) orelse {
        log.fatal(.app, "invalid option choice", .{ .arg = "--log-level", .value = str });
        return error.InvalidArgument;
    };
}

fn logDirValidator(allocator: Allocator, args: *cli.ArgIterator) !?[]const u8 {
    var peek_it = args.*;
    if (peek_it.next()) |val| {
        if (val.len > 0 and val[0] != '-') {
            _ = args.next();
            return try allocator.dupe(u8, val);
        }
    }
    return try allocator.dupe(u8, "logs");
}

/// Common CLI args.
const CommonOptions = .{
    .{ .name = "obey_robots", .type = bool },
    .{ .name = "proxy_bearer_token", .type = ?[:0]const u8 },
    .{ .name = "http_proxy", .type = ?[:0]const u8 },
    .{ .name = "proxy_file", .type = ?[]const u8 },
    .{ .name = "http_max_concurrent", .type = ?u8 },
    .{ .name = "http_max_host_open", .type = ?u8 },
    .{ .name = "http_timeout", .type = ?u31 },
    .{ .name = "http_connect_timeout", .type = ?u31 },
    .{ .name = "http_max_response_size", .type = ?usize },
    .{ .name = "resource_policy", .type = ?ResourcePolicy, .validator = resourcePolicyValidator },
    .{ .name = "ws_max_concurrent", .type = ?u8 },
    .{ .name = "insecure_disable_tls_host_verification", .type = bool },
    .{ .name = "log_level", .type = ?log.Level, .validator = logLevelValidator },
    .{ .name = "log_format", .type = ?log.Format },
    .{ .name = "log_filter_scopes", .type = log.Scope, .multiple = true, .validator = logFilterScopesValidator },
    .{ .name = "log_dir", .type = ?[]const u8, .validator = logDirValidator },
    .{ .name = "log_run_id", .type = ?[]const u8 },
    .{ .name = "log_no_combined", .type = bool },
    .{ .name = "log_cdp_trace", .type = bool },
    .{ .name = "log_level_js", .type = ?log.Level, .validator = logLevelValidator },
    .{ .name = "log_level_core", .type = ?log.Level, .validator = logLevelValidator },
    .{ .name = "log_level_network", .type = ?log.Level, .validator = logLevelValidator },
    .{ .name = "log_level_protocol", .type = ?log.Level, .validator = logLevelValidator },
    .{ .name = "log_level_system", .type = ?log.Level, .validator = logLevelValidator },
    .{ .name = "user_agent_suffix", .type = ?[]const u8 },
    .{ .name = "http_cache_dir", .type = ?[]const u8 },
    .{ .name = "web_bot_auth_key_file", .type = ?[]const u8 },
    .{ .name = "web_bot_auth_keyid", .type = ?[]const u8 },
    .{ .name = "web_bot_auth_domain", .type = ?[]const u8 },
    .{ .name = "user_agent", .type = ?[]const u8 },
    .{ .name = "user_data_dir", .type = ?[]const u8 },
    .{ .name = "browser_profile", .type = ?[]const u8 },
    .{ .name = "browser_profile_pool", .type = ?[]const u8 },
    .{ .name = "block_private_networks", .type = bool },
    .{ .name = "block_cidrs", .type = ?[]const u8 },
    .{ .name = "google_chrome_transport", .type = bool },
    .{ .name = "cookie", .type = ?[]const u8 },
    .{ .name = "cookie_jar", .type = ?[]const u8 },
    .{ .name = "fingerprint_folder", .type = ?[]const u8 },
    .{ .name = "storage_engine", .type = ?Storage.EngineType },
    .{ .name = "storage_sqlite_path", .type = ?[:0]const u8 },
};

fn dumpValidator(_: Allocator, args: *cli.ArgIterator) !?DumpFormat {
    // Peek next argument.
    var peek_args = args.*;
    if (peek_args.next()) |next_arg| {
        const mode = std.meta.stringToEnum(DumpFormat, next_arg) orelse {
            return .html;
        };

        // Skip the argument we peek if successful.
        _ = args.next();
        return mode;
    }

    // Means we couldn't get something like `--dump html` but we do have
    // `--dump`; which should fall to `html` by default.
    return .html;
}

fn waitScriptFileValidator(allocator: Allocator, args: *cli.ArgIterator) !?[:0]const u8 {
    const path = args.next() orelse {
        log.fatal(.app, "missing argument value", .{ .arg = "--wait-script-file" });
        return error.InvalidArgument;
    };

    return std.Io.Dir.cwd().readFileAllocOptions(runtime_io.get(), path, allocator, .limited(1024 * 1024), .of(u8), 0) catch |err| {
        log.fatal(.app, "failed to read file", .{ .arg = "--wait-script-file", .path = path, .err = err });
        return error.InvalidArgument;
    };
}

/// Definition for all the commands and its arguments. See @cli.zig for further.
const Commands = cli.Builder(.{
    .{
        .name = "serve",
        .options = .{
            .{ .name = "host", .type = []const u8, .default = "127.0.0.1" },
            .{ .name = "port", .type = u16, .default = 9222 },
            .{ .name = "advertise_host", .type = ?[]const u8 },
            .{ .name = "timeout", .type = ?u31 },
            .{ .name = "cdp_max_connections", .type = u16, .default = 16 },
            .{ .name = "cdp_max_pending_connections", .type = u16, .default = 128 },
            // Reclaim a CDP worker's V8 heap before long-lived sessions can
            // retain an unbounded site heap.
            .{ .name = "worker_max_pages", .type = u32, .default = 1 },
            .{ .name = "worker_max_rss", .type = u64, .default = 2 * 1024 * 1024 * 1024 },
        },
        .shared_options = CommonOptions,
    },
    .{
        .name = "fetch",
        // This argument can be given out of order.
        .positional = .{ .name = "url", .type = ?[:0]const u8 },
        .options = .{
            .{ .name = "dump", .type = ?DumpFormat, .validator = dumpValidator },
            .{ .name = "with_base", .type = bool },
            .{ .name = "with_frames", .type = bool },
            .{ .name = "strip_mode", .type = dump.Opts.Strip, .default = dump.Opts.Strip{} },
            .{ .name = "wait_ms", .type = u32, .default = 5_000 },
            .{ .name = "wait_until", .type = ?WaitUntil },
            .{ .name = "observe_ms", .type = u32, .default = 0 },
            .{ .name = "expand_lazy", .type = bool },
            .{ .name = "max_scrolls", .type = u32, .default = 80 },
            .{ .name = "scroll_settle_ms", .type = u32, .default = 250 },
            .{
                .name = "wait_script",
                .type = ?[:0]const u8,
                .variants = .{
                    .{ .name = "wait_script_file", .validator = waitScriptFileValidator },
                },
            },
            .{ .name = "wait_selector", .type = ?[:0]const u8 },
            .{ .name = "click_selector", .type = ?[:0]const u8 },
            .{ .name = "click_offset_x", .type = u16, .default = 28 },
            .{ .name = "click_offset_y", .type = ?u16 },
            .{ .name = "terminate_ms", .type = ?u32 },
            // Observatory supplies these fetch-only plumbing flags. They are
            // intentionally not shared with CDP/MCP process modes.
            .{ .name = "internet_journey_file", .type = ?[]const u8 },
            .{ .name = "execution_checkpoint_dir", .type = ?[]const u8 },
            .{ .name = "execution_restore_dir", .type = ?[]const u8 },
            .{ .name = "execution_replay_file", .type = ?[]const u8 },
            .{ .name = "telemetry_capture_bodies", .type = bool },
            .{ .name = "extra_headers_file", .type = ?[]const u8 },
            .{ .name = "dump_html_file", .type = ?[]const u8 },
        },
        .shared_options = CommonOptions,
    },
    .{
        .name = "mcp",
        .options = .{
            .{ .name = "cdp_port", .type = ?u16 },
            .{ .name = "host", .type = []const u8, .default = "127.0.0.1" },
            .{ .name = "port", .type = ?u16 },
            .{ .name = "max_sessions", .type = usize, .default = 64 },
        },
        .shared_options = CommonOptions,
    },
    .{
        .name = "profile",
        .positional = .{ .name = "action", .type = ?[]const u8 },
        .options = .{
            .{ .name = "name", .type = ?[]const u8 },
            .{ .name = "fingerprint", .type = ?[]const u8 },
            .{ .name = "from", .type = ?[]const u8 },
            .{ .name = "to", .type = ?[]const u8 },
            .{ .name = "user_data_dir", .type = ?[]const u8 },
        },
    },
    .{ .name = "version", .options = .{} },
    .{ .name = "help", .options = .{} },
});

pub const RunMode = Commands.Enum;
pub const Mode = Commands.Union;

mode: Mode,
exec_name: []const u8,
profile_paths: ProfilePaths.ProfilePaths,
profile: ProfileStore.LoadedProfile,
profile_runtime: ProfileRuntime.ProfileRuntime,
http_headers: HttpHeaders,
/// Default HTTP cache directory when --http-cache-dir is omitted.
http_cache_dir_default: ?[]u8 = null,
/// One proxy selected from --proxy-file during startup and held stable for
/// the entire engine lifetime. Owned by Config.
selected_proxy: ?[:0]u8 = null,

/// ProfileRuntime stores a pointer into Config.profile; must run after Config is at its final address.
pub fn rebindProfilePointers(self: *Config) void {
    self.profile_runtime.profile = &self.profile;
}

pub fn initInPlace(self: *Config, allocator: Allocator, exec_name: []const u8, mode: Mode) !void {
    self.mode = mode;
    self.exec_name = exec_name;
    self.profile = undefined;
    self.profile_runtime = undefined;
    self.http_headers = undefined;
    self.profile_paths = undefined;
    self.http_cache_dir_default = null;
    self.selected_proxy = null;

    if (modeSkipsProfileBootstrap(mode)) return;

    if (self.proxyFile()) |path| {
        if (self.explicitHttpProxy() != null) {
            log.fatal(.app, "proxy options are mutually exclusive", .{
                .options = "--http-proxy,--proxy-file",
            });
            return error.InvalidArgument;
        }
        self.selected_proxy = try ProxyPool.loadRandom(allocator, path);
        errdefer allocator.free(self.selected_proxy.?);
        log.info(.app, "proxy selected", .{
            .source = path,
            .endpoint = ProxyPool.redactedEndpoint(self.selected_proxy.?),
        });
    }

    const pool_pick = try self.resolveBrowserProfilePoolPick(allocator);
    defer if (pool_pick) |name| allocator.free(name);

    var bootstrap_paths = try ProfilePaths.ProfilePaths.init(
        allocator,
        self.userDataDir(),
        ProfilePaths.default_profile_name,
        self.fingerprintFolder(),
    );
    defer bootstrap_paths.deinit();
    try ProfileManager.ensureFirstRun(allocator, bootstrap_paths.user_data_dir);

    const active_name = try ProfileManager.resolveActiveProfileName(
        allocator,
        bootstrap_paths.user_data_dir,
        self.browserProfile(),
        pool_pick,
    );
    defer allocator.free(active_name);

    self.profile_paths = try ProfilePaths.ProfilePaths.init(
        allocator,
        self.userDataDir(),
        active_name,
        self.fingerprintFolder(),
    );
    errdefer self.profile_paths.deinit();
    try self.profile_paths.ensureProfileReady();

    self.profile = try ProfileStore.resolve(&self.profile_paths);
    errdefer self.profile.deinit();
    try ProfileStore.applyUserAgentOverlay(
        &self.profile,
        self.userAgent(),
        self.userAgentSuffix(),
    );
    self.profile_runtime = try ProfileRuntime.ProfileRuntime.init(allocator, &self.profile);
    errdefer self.profile_runtime.deinit(allocator);
    self.http_headers = try HttpHeaders.init(allocator, self);
    try self.ensureDefaultHttpCacheDir(allocator);
    self.rebindProfilePointers();
}

fn ensureDefaultHttpCacheDir(self: *Config, allocator: Allocator) !void {
    const explicit: ?[]const u8 = switch (self.mode) {
        .serve => |opts| opts.http_cache_dir,
        .mcp => |opts| opts.http_cache_dir,
        .fetch => |opts| opts.http_cache_dir,
        else => return,
    };
    if (explicit != null) return;

    const cache = try self.profile_paths.cacheDirAlloc();
    defer self.profile_paths.allocator.free(cache);
    self.http_cache_dir_default = try allocator.dupe(u8, cache);
    try std.Io.Dir.cwd().createDirPath(runtime_io.get(), self.http_cache_dir_default.?);
}

pub fn init(allocator: Allocator, exec_name: []const u8, mode: Mode) !Config {
    var config: Config = undefined;
    try initInPlace(&config, allocator, exec_name, mode);
    var out = config;
    out.rebindProfilePointers();
    return out;
}

fn modeSkipsProfileBootstrap(mode: Mode) bool {
    return mode == .profile or mode == .help or mode == .version;
}

pub fn deinit(self: *Config, allocator: Allocator) void {
    if (self.http_cache_dir_default) |path| allocator.free(path);
    if (self.selected_proxy) |proxy| allocator.free(proxy);
    if (!modeSkipsProfileBootstrap(self.mode)) {
        self.http_headers.deinit(allocator);
        self.profile_runtime.deinit(allocator);
        self.profile.deinit();
        self.profile_paths.deinit();
    }
}

pub fn tlsVerifyHost(self: *const Config) bool {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| !opts.insecure_disable_tls_host_verification,
        else => unreachable,
    };
}

pub fn obeyRobots(self: *const Config) bool {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.obey_robots,
        else => unreachable,
    };
}

pub fn httpProxy(self: *const Config) ?[:0]const u8 {
    return self.explicitHttpProxy() orelse self.selected_proxy;
}

fn explicitHttpProxy(self: *const Config) ?[:0]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.http_proxy,
        else => unreachable,
    };
}

pub fn proxyFile(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.proxy_file,
        .profile, .help, .version => null,
    };
}

pub fn proxyBearerToken(self: *const Config) ?[:0]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.proxy_bearer_token,
        .profile, .help, .version => null,
    };
}

pub fn httpMaxConcurrent(self: *const Config) u8 {
    return switch (self.mode) {
        // Ten handles were sufficient for single-page fetches but created a
        // hard queueing cliff once many CDP contexts navigated together. Keep
        // the value explicit/configurable while making the scale-safe default
        // large enough for a modest multi-session workload.
        inline .serve, .fetch, .mcp => |opts| opts.http_max_concurrent orelse 32,
        else => unreachable,
    };
}

pub fn httpMaxHostOpen(self: *const Config) u8 {
    return switch (self.mode) {
        // Match the larger transfer pool without opening an unbounded number
        // of sockets to one origin. Hosts can still opt into a different cap.
        inline .serve, .fetch, .mcp => |opts| opts.http_max_host_open orelse 16,
        else => unreachable,
    };
}

pub fn httpConnectTimeout(self: *const Config) u31 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.http_connect_timeout orelse 0,
        else => unreachable,
    };
}

pub fn httpTimeout(self: *const Config) u31 {
    return switch (self.mode) {
        // Browser subresource requests and Fetch have no implicit five-second
        // total timeout. A non-zero value is an explicit host policy; APIs
        // such as XMLHttpRequest.timeout still override it per request.
        inline .serve, .fetch, .mcp => |opts| opts.http_timeout orelse 0,
        else => unreachable,
    };
}

test "browser HTTP total timeout is opt-in" {
    var config: Config = undefined;
    config.mode = .{ .fetch = .{} };
    try std.testing.expectEqual(@as(u31, 0), config.httpTimeout());

    config.mode.fetch.http_timeout = 12_345;
    try std.testing.expectEqual(@as(u31, 12_345), config.httpTimeout());
}

test "browser HTTP scale defaults leave explicit overrides intact" {
    var config: Config = undefined;
    config.mode = .{ .serve = .{} };
    try std.testing.expectEqual(@as(u8, 32), config.httpMaxConcurrent());
    try std.testing.expectEqual(@as(u8, 16), config.httpMaxHostOpen());

    config.mode.serve.http_max_concurrent = 7;
    config.mode.serve.http_max_host_open = 3;
    try std.testing.expectEqual(@as(u8, 7), config.httpMaxConcurrent());
    try std.testing.expectEqual(@as(u8, 3), config.httpMaxHostOpen());
}

test "CDP worker recycle defaults are bounded and configurable" {
    var config: Config = undefined;
    config.mode = .{ .serve = .{} };
    try std.testing.expectEqual(@as(u32, 1), config.workerMaxPages());
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024 * 1024), config.workerMaxRssBytes());

    config.mode.serve.worker_max_pages = 12;
    config.mode.serve.worker_max_rss = 0;
    try std.testing.expectEqual(@as(u32, 12), config.workerMaxPages());
    try std.testing.expectEqual(@as(u64, 0), config.workerMaxRssBytes());
}

pub fn httpMaxRedirects(_: *const Config) u8 {
    return 20;
}

pub fn httpMaxResponseSize(self: *const Config) ?usize {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.http_max_response_size,
        else => unreachable,
    };
}

pub fn resourcePolicy(self: *const Config) ResourcePolicy {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.resource_policy orelse .full,
        else => .full,
    };
}

test "resource policy resource classes" {
    try std.testing.expect(ResourcePolicy.full.allowsImages());
    try std.testing.expect(ResourcePolicy.full.allowsExternalStylesheets());
    try std.testing.expect(!ResourcePolicy.no_images.allowsImages());
    try std.testing.expect(!ResourcePolicy.no_css.allowsExternalStylesheets());
    try std.testing.expect(!ResourcePolicy.text_only.allowsImages());
    try std.testing.expect(!ResourcePolicy.text_only.allowsExternalStylesheets());
    try std.testing.expect(ResourcePolicy.defer_images.defersImages());
}

pub fn wsMaxConcurrent(self: *const Config) u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.ws_max_concurrent orelse 8,
        else => unreachable,
    };
}

pub fn logLevel(self: *const Config) ?log.Level {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.log_level,
        else => unreachable,
    };
}

pub fn logFormat(self: *const Config) ?log.Format {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.log_format,
        else => unreachable,
    };
}

pub fn logFilterScopes(self: *const Config) std.ArrayList(log.Scope) {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.log_filter_scopes,
        else => unreachable,
    };
}

pub fn logDir(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.log_dir,
        else => unreachable,
    };
}

pub fn logRunId(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.log_run_id,
        else => unreachable,
    };
}

pub fn logNoCombined(self: *const Config) bool {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.log_no_combined,
        else => unreachable,
    };
}

pub fn logCdpTrace(self: *const Config) bool {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.log_cdp_trace,
        else => unreachable,
    };
}

pub fn logChannelLevels(self: *const Config) log.ChannelLevels {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| .{
            .js = opts.log_level_js,
            .core = opts.log_level_core,
            .network = opts.log_level_network,
            .protocol = opts.log_level_protocol,
            .system = opts.log_level_system,
        },
        else => unreachable,
    };
}

pub fn runModeName(self: *const Config) []const u8 {
    return @tagName(self.mode);
}

pub fn userAgentSuffix(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.user_agent_suffix,
        .profile, .help, .version => null,
    };
}

pub fn userAgent(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.user_agent,
        .profile, .help, .version => null,
    };
}

pub fn userDataDir(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.user_data_dir,
        .profile => |opts| opts.user_data_dir,
        .help, .version => null,
    };
}

pub fn browserProfile(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.browser_profile,
        .profile, .help, .version => null,
    };
}

pub fn activeProfileName(self: *const Config) []const u8 {
    return self.profile_paths.profile_name;
}

pub fn activeProfileDir(self: *const Config) []const u8 {
    return self.profile_paths.profile_dir;
}

pub fn browserProfilePool(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.browser_profile_pool,
        .profile, .help, .version => null,
    };
}

fn resolveBrowserProfilePoolPick(self: *const Config, allocator: Allocator) !?[]const u8 {
    const pool = self.browserProfilePool() orelse return null;
    if (self.browserProfile() != null) return null;
    var random_source = std.Random.IoSource{ .io = runtime_io.get() };
    return try ProfileRotation.pickFromPool(allocator, pool, random_source.interface());
}

pub fn httpCacheDir(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        .serve => |opts| opts.http_cache_dir orelse self.http_cache_dir_default,
        .mcp => |opts| opts.http_cache_dir orelse self.http_cache_dir_default,
        .fetch => |opts| opts.http_cache_dir orelse self.http_cache_dir_default,
        else => null,
    };
}

pub fn internetJourneyFile(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        .fetch => |opts| opts.internet_journey_file,
        else => null,
    };
}

pub fn executionCheckpointDir(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        .fetch => |opts| opts.execution_checkpoint_dir,
        else => null,
    };
}

pub fn executionRestoreDir(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        .fetch => |opts| opts.execution_restore_dir,
        else => null,
    };
}

pub fn executionReplayFile(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        .fetch => |opts| opts.execution_replay_file,
        else => null,
    };
}

pub fn telemetryCaptureBodies(self: *const Config) bool {
    return switch (self.mode) {
        .fetch => |opts| opts.telemetry_capture_bodies,
        else => false,
    };
}

pub fn extraHeadersFile(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        .fetch => |opts| opts.extra_headers_file,
        else => null,
    };
}

pub fn dumpHtmlFile(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        .fetch => |opts| opts.dump_html_file,
        else => null,
    };
}

/// Explicit CLI `--cookie` only (does not include profile seed).
pub fn cookieCliOverride(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.cookie,
        else => null,
    };
}

/// @deprecated Use cookieCliOverride or profileCookieSeedFile.
pub fn cookieFile(self: *const Config) ?[]const u8 {
    return self.cookieCliOverride();
}

/// Runtime cookie jar: CLI `--cookie-jar` overrides profile dir `Cookies.json`.
pub fn cookieJarFile(self: *const Config, buf: []u8) ?[]const u8 {
    const cli_jar = switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.cookie_jar,
        else => null,
    };
    if (cli_jar) |path| return path;
    return self.profile_paths.cookiesPath(buf);
}

/// Self-contained fingerprint folder (`--fingerprint-folder`).
pub fn fingerprintFolder(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.fingerprint_folder,
        else => null,
    };
}

pub fn localStorageDir(self: *const Config, buf: []u8) ?[]const u8 {
    return self.profile_paths.localStorageDir(buf);
}

pub fn port(self: *const Config) u16 {
    return switch (self.mode) {
        .serve => |opts| opts.port,
        .mcp => |opts| opts.cdp_port orelse 0,
        else => unreachable,
    };
}

pub fn advertiseHost(self: *const Config) []const u8 {
    return switch (self.mode) {
        .serve => |opts| opts.advertise_host orelse opts.host,
        .mcp => "127.0.0.1",
        else => unreachable,
    };
}

pub fn webBotAuth(self: *const Config) ?WebBotAuthConfig {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| WebBotAuthConfig{
            .key_file = opts.web_bot_auth_key_file orelse return null,
            .keyid = opts.web_bot_auth_keyid orelse return null,
            .domain = opts.web_bot_auth_domain orelse return null,
        },
        .profile, .help, .version => null,
    };
}

pub fn blockPrivateNetworks(self: *const Config) bool {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.block_private_networks,
        else => unreachable,
    };
}

pub fn blockCidrs(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.block_cidrs,
        else => unreachable,
    };
}

pub fn googleChromeTransport(self: *const Config) bool {
    const flag = switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.google_chrome_transport,
        else => unreachable,
    };
    // Explicit flag or env override. Antidetect profiles also enable this from
    // Frame.navigate (google-search sg_ss= policy uses real Chrome network).
    return flag or runtime_io.getenv("KOKO_CHROME_SPAWN") != null;
}

pub fn maxConnections(self: *const Config) u16 {
    return switch (self.mode) {
        .serve => |opts| opts.cdp_max_connections,
        .mcp => 16,
        else => unreachable,
    };
}

pub fn maxPendingConnections(self: *const Config) u31 {
    return switch (self.mode) {
        .serve => |opts| opts.cdp_max_pending_connections,
        .mcp => 128,
        else => unreachable,
    };
}

pub fn workerMaxPages(self: *const Config) u32 {
    return switch (self.mode) {
        .serve => |opts| opts.worker_max_pages,
        // MCP's optional CDP listener uses the same per-connection browser
        // worker but does not expose serve-only tuning flags.
        .mcp => 1,
        else => unreachable,
    };
}

pub fn workerMaxRssBytes(self: *const Config) u64 {
    return switch (self.mode) {
        .serve => |opts| opts.worker_max_rss,
        .mcp => 2 * 1024 * 1024 * 1024,
        else => unreachable,
    };
}

pub fn storageEngine(self: *const Config) ?Storage.EngineType {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.storage_engine,
        else => unreachable,
    };
}

pub fn storageSqlitePath(self: *const Config) ?[:0]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.storage_sqlite_path,
        else => unreachable,
    };
}
pub const DumpFormat = enum {
    html,
    markdown,
    wpt,
    semantic_tree,
    semantic_tree_text,
};

pub const WaitUntil = enum {
    load,
    domcontentloaded,
    networkidle,
    domstable,
    done,
};

/// Pre-formatted HTTP headers for reuse across Http and Client.
/// Must be initialized with an allocator that outlives all HTTP connections.
pub const HttpHeaders = struct {
    user_agent: [:0]const u8,
    user_agent_header: [:0]const u8,
    sec_ch_ua_header: [:0]const u8,
    accept_language_header: [:0]const u8,
    brands: []const ProfileStore.Brand,
    proxy_bearer_header: ?[:0]const u8,
    extra_headers: std.ArrayList([:0]const u8),
    user_agent_owned: bool,

    pub fn init(allocator: Allocator, config: *const Config) !HttpHeaders {
        const profile = &config.profile;
        const user_agent = profile.persona.network.user_agent;

        const user_agent_header = try std.fmt.allocPrintSentinel(allocator, "User-Agent: {s}", .{user_agent}, 0);
        errdefer allocator.free(user_agent_header);

        const sec_ch_ua_header = try allocator.dupeZ(u8, profile.persona.network.sec_ch_ua);
        errdefer allocator.free(sec_ch_ua_header);

        const accept_language_header = try allocator.dupeZ(u8, profile.persona.network.accept_language);
        errdefer allocator.free(accept_language_header);

        const proxy_bearer_header: ?[:0]const u8 = if (config.proxyBearerToken()) |token|
            try std.fmt.allocPrintSentinel(allocator, "Proxy-Authorization: Bearer {s}", .{token}, 0)
        else
            null;
        errdefer if (proxy_bearer_header) |header| allocator.free(header);

        var extra_headers: std.ArrayList([:0]const u8) = .empty;
        errdefer {
            for (extra_headers.items) |header| allocator.free(header);
            extra_headers.deinit(allocator);
        }
        if (config.extraHeadersFile()) |path| {
            const bytes = std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), path, allocator, .limited(256 * 1024)) catch |err| {
                log.warn(.app, "failed to read extra headers file", .{ .path = path, .err = err });
                return error.InvalidArgument;
            };
            defer allocator.free(bytes);
            var lines = std.mem.splitScalar(u8, bytes, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0 or trimmed[0] == '#') continue;
                const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse {
                    log.warn(.app, "ignoring malformed extra header", .{ .value = trimmed });
                    continue;
                };
                const name = std.mem.trim(u8, trimmed[0..colon], " \t");
                const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
                if (!validExtraHeaderName(name) or value.len == 0) {
                    log.warn(.app, "ignoring invalid extra header", .{ .name = name });
                    continue;
                }
                try extra_headers.append(allocator, try std.fmt.allocPrintSentinel(allocator, "{s}: {s}", .{ name, value }, 0));
            }
        }

        return .{
            .user_agent = user_agent,
            .user_agent_header = user_agent_header,
            .sec_ch_ua_header = sec_ch_ua_header,
            .accept_language_header = accept_language_header,
            .brands = profile.persona.network.brands,
            .proxy_bearer_header = proxy_bearer_header,
            .extra_headers = extra_headers,
            .user_agent_owned = false,
        };
    }

    pub fn deinit(self: *HttpHeaders, allocator: Allocator) void {
        for (self.extra_headers.items) |header| allocator.free(header);
        self.extra_headers.deinit(allocator);
        if (self.proxy_bearer_header) |hdr| allocator.free(hdr);
        allocator.free(self.accept_language_header);
        allocator.free(self.sec_ch_ua_header);
        allocator.free(self.user_agent_header);
        if (self.user_agent_owned) allocator.free(self.user_agent);
    }

    fn validExtraHeaderName(name: []const u8) bool {
        if (name.len == 0) return false;
        if (std.ascii.eqlIgnoreCase(name, "host") or
            std.ascii.eqlIgnoreCase(name, "content-length") or
            std.ascii.eqlIgnoreCase(name, "connection") or
            std.ascii.eqlIgnoreCase(name, "cookie")) return false;
        for (name) |character| {
            if (!(std.ascii.isAlphanumeric(character) or character == '-' or character == '_')) return false;
        }
        return true;
    }
};

test "fixed request headers accept safe names and reject transport-owned names" {
    try std.testing.expect(HttpHeaders.validExtraHeaderName("X-Run-Mode"));
    try std.testing.expect(HttpHeaders.validExtraHeaderName("authorization"));
    try std.testing.expect(!HttpHeaders.validExtraHeaderName("Host"));
    try std.testing.expect(!HttpHeaders.validExtraHeaderName("Content-Length"));
    try std.testing.expect(!HttpHeaders.validExtraHeaderName("bad header"));
}

pub fn printUsageAndExit(self: *const Config, success: bool) void {
    //                                                                     MAX_HELP_LEN|
    const common_options =
        \\
        \\--insecure-disable-tls-host-verification
        \\                Disables host verification on all HTTP requests. This is an
        \\                advanced option which should only be set if you understand
        \\                and accept the risk of disabling host verification.
        \\
        \\--obey-robots
        \\                Fetches and obeys the robots.txt (if available) of the web pages
        \\                we make requests towards.
        \\                Defaults to false.
        \\
        \\--block-private-networks
        \\                Blocks HTTP requests to private/internal IP addresses
        \\                after DNS resolution. Useful for sandboxing, multi-tenant
        \\                deployments, and preventing access to internal infrastructure
        \\                regardless of what triggers the request (JavaScript, HTML
        \\                resources, redirects, etc.).
        \\                Defaults to false.
        \\
        \\--google-chrome-transport
        \\                Route google.com/search document navigations through real
        \\                Chrome network (scripts/chrome-google-transport.mjs).
        \\                Bypasses curl QUIC fingerprint gap for Google SERP.
        \\                Defaults to false.
        \\
        \\--block-cidrs
        \\                Additional CIDR ranges to block, comma-separated.
        \\                Prefix with '-' to allow (exempt from blocking).
        \\                e.g. --block-cidrs 169.254.169.254/32,fd00:ec2::254/128
        \\                e.g. --block-cidrs 10.0.0.0/8,-10.0.0.42/32
        \\                Can be used standalone or combined with --block-private-networks.
        \\
        \\--http-proxy    The HTTP proxy to use for all HTTP requests.
        \\                A username:password can be included for basic authentication.
        \\                Defaults to none.
        \\
        \\--proxy-file    File containing one proxy per line. One entry is selected
        \\                at engine startup and remains fixed for the whole browser
        \\                session. Supports http:// proxy URLs and
        \\                host:port:user:password.
        \\                Cannot be combined with --http-proxy.
        \\
        \\--proxy-bearer-token
        \\                The <token> to send for bearer authentication with the proxy
        \\                Proxy-Authorization: Bearer <token>
        \\
        \\--http-max-concurrent
        \\                The maximum number of concurrent HTTP requests.
        \\                Defaults to 32.
        \\
        \\--http-max-host-open
        \\                The maximum number of open connection to a given host:port.
        \\                Defaults to 16.
        \\
        \\--http-connect-timeout
        \\                The time, in milliseconds, for establishing an HTTP connection
        \\                before timing out. 0 means it never times out.
        \\                Defaults to 0.
        \\
        \\--http-timeout
        \\                The maximum time, in milliseconds, the transfer is allowed
        \\                to complete. 0 means it never times out.
        \\                Defaults to 10000.
        \\
        \\--http-max-response-size
        \\                Limits the acceptable response size for any request
        \\                (e.g. XHR, fetch, script loading, ...).
        \\                Defaults to no limit.
        \\
        \\--resource-policy
        \\                Resource loading policy: full, no-images, no-css,
        \\                text-only, or defer-images. Applies to image and
        \\                external stylesheet subresources. Defaults to full.
        \\
        \\--ws-max-concurrent
        \\                The maximum number of concurrent WebSocket connections.
        \\                Defaults to 8.
        \\
        \\--log-level     The log level: debug, info, warn, error or fatal.
        \\                Defaults to
    ++ (if (builtin.mode == .Debug) " info." else "warn.") ++
        \\
        \\
        \\--log-format    The log format: pretty or logfmt.
        \\                Defaults to
    ++ (if (builtin.mode == .Debug) " pretty." else " logfmt.") ++
        \\
        \\
        \\--log-filter-scopes
        \\                Filter out too verbose logs per scope:
        \\                http, unknown_prop, event, ...
        \\
        \\--log-dir [PATH]
        \\                Write structured logs to PATH/<run-id>/ (default PATH: logs).
        \\                Creates js/, core/, network/, protocol/, system/ subfolders.
        \\
        \\--log-run-id ID
        \\                Override the per-run log folder name.
        \\
        \\--log-no-combined
        \\                Do not write combined.log in the run folder.
        \\
        \\--log-cdp-trace
        \\                Write raw CDP wire messages to protocol/cdp-wire.log.
        \\
        \\--log-level-js
        \\--log-level-core
        \\--log-level-network
        \\--log-level-protocol
        \\--log-level-system
        \\                Per-channel log level overrides (debug, info, warn, error, fatal).
        \\
        \\--user-data-dir
        \\                Chrome-style user data root (default: OS app data dir, e.g.
        \\                ~/Library/Application Support/koko on macOS).
        \\
        \\profile command
        \\Manage browser profiles (Chrome-style user-data-dir folders).
        \\Example: {0s} profile list
        \\
        \\  profile list
        \\  profile create --name <id> [--fingerprint <fingerprint-id>]
        \\  profile delete --name <id>
        \\  profile import-cookies [--name <id>] --from <cookies.json>
        \\  profile export --name <id> [--to <bundle-dir>]
        \\  profile import --name <id> --from <bundle-dir>
        \\
        \\--fingerprint-folder
        \\                Self-contained fingerprint bundle dir (SaaS / offline profile).
        \\
        \\
        \\--browser-profile
        \\                Profile folder name inside user-data-dir (default: Default).
        \\                On first use, creates the folder with Preferences.json pointing at
        \\                a fingerprint folder id (e.g. chrome-macos-sonoma).
        \\
        \\--browser-profile-pool
        \\                Comma-separated profile folder names; picks one at random when
        \\                --browser-profile is omitted.
        \\
        \\--cookie-jar
        \\                Override profile Cookies.json path (deprecated; prefer profile dir).
        \\
        \\--user-agent    Override the User-Agent header entirely
        \\                User-Agent mustn't impersonate other browser.
        \\                Any value containing "Mozilla" is forbidden (unless antidetect profile).
        \\                The browser will continue to send Sec-Ch-Ua header.
        \\                Incompatible with --user-agent-suffix
        \\
        \\--user-agent-suffix
        \\                Suffix to append to the Koko/X.Y User-Agent
        \\
        \\--web-bot-auth-key-file
        \\                Path to the Ed25519 private key PEM file.
        \\
        \\--web-bot-auth-keyid
        \\                The JWK thumbprint of your public key.
        \\
        \\--web-bot-auth-domain
        \\                Your domain e.g. yourdomain.com
        \\
        \\--http-cache-dir
        \\                HTTP cache directory. Defaults to profile Cache/ under user-data-dir.
        \\
        \\--storage-engine
        \\                The storage engine to use. Choices are: none, sqlite.
        \\                Defaults to sqlite. Use none for ephemeral/JSON compatibility mode.
        \\
        \\--storage-sqlite-path
        \\                Path to SQLite database file for persistent storage.
        \\                Use ":memory:" for in-memory storage.
    ;

    //                                                                     MAX_HELP_LEN|
    const usage =
        \\usage: {0s} command [options] [URL]
        \\
        \\Command can be 'fetch', 'serve', 'mcp', 'profile', or 'help'
        \\
        \\fetch command
        \\Fetches the specified URL
        \\Example: {0s} fetch --dump html https://kokoio.com/
        \\
        \\Options:
        \\--dump          Dumps document to stdout.
        \\                Argument must be 'html', 'markdown', 'semantic_tree', or 'semantic_tree_text'.
        \\                Defaults to no dump.
        \\
        \\--dump-html-file  Writes the final hydrated HTML DOM to a sidecar file.
        \\                Useful when stdout is used for a different dump format.
        \\                Defaults to no sidecar file.
        \\
        \\--strip-mode    Comma separated list of tag groups to remove from dump
        \\                the dump. e.g. --strip-mode js,css
        \\                  - "js" script and link[as=script, rel=preload]
        \\                  - "ui" includes img, picture, video, css and svg
        \\                  - "css" includes style and link[rel=stylesheet]
        \\                  - "full" includes js, ui and css
        \\
        \\--with-base     Add a <base> tag in dump. Defaults to false.
        \\
        \\--with-frames   Includes the contents of iframes. Defaults to false.
        \\
        \\--wait-ms       Wait time in milliseconds. Supersedes all other --wait
        \\                parameters.
        \\                Defaults to 5000.
        \\
        \\--wait-until    Wait until the specified event. Checked before the other
        \\                --wait- options. Supported events: load, domcontentloaded,
        \\                networkidle, domstable, done.
        \\                Defaults to 'done'. If --wait-selector, --wait-script or
        \\                --wait-script-file are specified, defaults to none.
        \\
        \\--observe-ms    Continue servicing the page after the wait milestone for
        \\                this bounded background-observation window. This is useful
        \\                for live previews and lazy resources; it does not change
        \\                the lifecycle milestone used for the initial snapshot.
        \\
        \\--expand-lazy   Scroll the page in bounded viewport-sized steps and
        \\                service timers, IntersectionObserver callbacks and
        \\                network work between steps. Disabled by default.
        \\--max-scrolls   Maximum expansion steps. Defaults to 80.
        \\--scroll-settle-ms
        \\                Milliseconds to service the page after each step.
        \\                Defaults to 250.
        \\
        \\--wait-selector Wait for an element matching the CSS selector to appear.
        \\                Checked after --wait-until condition is met.
        \\
        \\--wait-script   Wait for a JavaScript expression to return truthy.
        \\                Checked after --wait-until condition is met.
        \\
        \\--wait-script-file
        \\                Like --wait-script, but reads the script from a file.
        \\
        \\--click-selector
        \\                After --wait-selector/--wait-until, click inside the
        \\                element matching this CSS selector using core
        \\                triggerMouseClick (parent-frame coordinates).
        \\
        \\--click-offset-x
        \\                X offset from the element's left edge. Defaults to 28.
        \\
        \\--click-offset-y
        \\                Y offset from the element's top edge. Defaults to
        \\                vertical center of the element.
        \\
        \\--terminate-ms  Hard deadline in milliseconds. After this time elapses,
        \\                JavaScript execution is forcibly terminated (e.g. for
        \\                pages with endless scripts). Unlike --wait-ms, which
        \\                only stops waiting, --terminate-ms aborts the page.
        \\                Defaults to no terminate.
        \\
        \\--cookie        Path to a JSON file to load cookies from (CLI override; profile seed loads automatically).
        \\                Defaults to no cookie loading.
        \\
        \\--cookie-jar    Path to runtime cookie jar (overrides profile session.cookieRuntimeFile).
        \\                Available for fetch and mcp commands.
        \\                Defaults to no cookie saving.
        \\
        \\--extra-headers-file
        \\                Path to a UTF-8 file containing fixed request headers,
        \\                one `Name: value` entry per line. Applied to all requests.
        \\                Defaults to no additional headers.
        \\
    ++ common_options ++
        \\
        \\serve command
        \\Starts a websocket CDP server
        \\Example: {0s} serve --host 127.0.0.1 --port 9222
        \\
        \\Options:
        \\--host          Host of the CDP server
        \\                Defaults to "127.0.0.1"
        \\
        \\--port          Port of the CDP server
        \\                Defaults to 9222
        \\
        \\--advertise-host
        \\                The host to advertise, e.g. in the /json/version response.
        \\                Useful, for example, when --host is 0.0.0.0.
        \\                Defaults to --host value
        \\
        \\--cdp-max-connections
        \\                Maximum number of simultaneous CDP connections.
        \\                Defaults to 16.
        \\
        \\--cdp-max-pending-connections
        \\                Maximum pending connections in the accept queue.
        \\                Defaults to 128.
        \\
        \\--worker-max-pages
        \\                Recycle a CDP worker after this many browser contexts.
        \\                0 disables the page-count policy. Defaults to 1.
        \\
        \\--worker-max-rss
        \\                Recycle a CDP worker after RSS high-water growth
        \\                since worker start/recycle reaches these bytes.
        \\                0 disables the policy. Defaults to 2147483648.
        \\
        \\--cookie        Path to a JSON file to load cookies from (CLI override; profile seed loads automatically).
        \\                Defaults to no cookie loading.
        \\
    ++ common_options ++
        \\
        \\mcp command
        \\Starts an MCP (Model Context Protocol) server over stdio, or
        \\Streamable HTTP when --port is provided.
        \\Example: {0s} mcp
        \\Example: {0s} mcp --host 127.0.0.1 --port 9223
        \\
        \\--host          Host for MCP HTTP. Defaults to 127.0.0.1.
        \\--port          Enable MCP Streamable HTTP on this port.
        \\--max-sessions  Maximum isolated MCP HTTP sessions. Defaults to 64.
        \\
        \\--cookie        Path to a JSON file to load cookies from (one-shot CLI override).
        \\                Defaults to no cookie loading.
        \\
    ++ common_options ++
        \\
        \\version command
        \\Displays the version of {0s}
        \\
        \\help command
        \\Displays this message
        \\
    ;
    std.debug.print(usage, .{self.exec_name});
    if (success) {
        return std.process.cleanExit(runtime_io.get());
    }
    std.process.exit(1);
}

/// CLI option strings are allocated with `cli_allocator` (typically an arena).
/// Long-lived config state (`http_headers`, `profile_runtime`) uses `config_allocator`
/// so `deinit(config_allocator)` can free without allocator mismatch.
/// Must write in place: Config embeds non-copyable arena state in profile/runtime.
pub fn parseArgsInPlace(self: *Config, cli_allocator: Allocator, config_allocator: Allocator, process_args: std.process.Args) !void {
    // CommonOptions is intentionally shared by three commands. Raising this
    // quota keeps the generic CLI parser's compile-time field expansion below
    // Zig's default after controlled-execution options were added.
    @setEvalBranchQuota(4_000);
    const exec_name, const command = try Commands.parse(cli_allocator, process_args);
    if (command == .serve and command.serve.timeout != null) {
        log.warn(.app, "--timeout is deprecated", .{});
    }
    try initInPlace(self, config_allocator, exec_name, command);
    if (!modeSkipsProfileBootstrap(command)) {
        self.rebindProfilePointers();
    }
}

pub fn parseArgs(cli_allocator: Allocator, config_allocator: Allocator, process_args: std.process.Args) !Config {
    var config: Config = undefined;
    try parseArgsInPlace(&config, cli_allocator, config_allocator, process_args);
    return config;
}

pub fn validateUserAgent(ua: []const u8, allow_mozilla: bool) !void {
    for (ua) |c| {
        if (!std.ascii.isPrint(c)) {
            return error.NonPrintable;
        }
    }

    if (!allow_mozilla and std.ascii.indexOfIgnoreCase(ua, "mozilla") != null) {
        return error.Reserved;
    }
}
