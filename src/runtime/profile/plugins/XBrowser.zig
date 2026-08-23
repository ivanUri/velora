const std = @import("std");
const HttpClient = @import("../../../core/browser/HttpClient.zig");
const ClientVariations = @import("ClientVariations.zig");
const runtime_io = @import("../../../support/io.zig");

const Allocator = std.mem.Allocator;

pub const Config = struct {
    channel: []const u8,
    copyright: []const u8,
    year: []const u8,
    api_key_macos: []const u8,
    api_key_windows: []const u8,
    api_key_linux: []const u8,
};

pub const Plugin = struct {
    config: Config,

    pub fn load(allocator: Allocator) !Plugin {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), "browser/policies/plugins/x-browser.json", allocator, .limited(1024 * 1024));
        defer allocator.free(bytes);

        var parsed = try std.json.parseFromSlice(JsonPlugin, allocator, bytes, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const doc = parsed.value;
        if (doc.version != 1) return error.UnsupportedPluginVersion;

        return .{
            .config = .{
                .channel = try allocator.dupe(u8, doc.channel),
                .copyright = try allocator.dupe(u8, doc.copyright),
                .year = try allocator.dupe(u8, doc.year),
                .api_key_macos = try allocator.dupe(u8, doc.apiKeys.macos),
                .api_key_windows = try allocator.dupe(u8, doc.apiKeys.windows),
                .api_key_linux = try allocator.dupe(u8, doc.apiKeys.linux),
            },
        };
    }

    pub fn deinit(self: *Plugin, allocator: Allocator) void {
        allocator.free(self.config.channel);
        allocator.free(self.config.copyright);
        allocator.free(self.config.year);
        allocator.free(self.config.api_key_macos);
        allocator.free(self.config.api_key_windows);
        allocator.free(self.config.api_key_linux);
        self.* = undefined;
    }

    pub fn appendHeaders(
        self: *const Plugin,
        headers: *HttpClient.Headers,
        allocator: Allocator,
        user_agent: []const u8,
        fingerprint_seed: u64,
    ) !void {
        // A diagnostic override remains available for capture comparison.
        // Production behavior is derived from the current persona UA and its
        // platform-specific key; it never selects a frozen browser capture.
        const validation = if (runtime_io.getenv("KOKO_X_BROWSER_VALIDATION")) |override|
            try allocator.dupeZ(u8, override)
        else
            try validationToken(allocator, &self.config, user_agent);
        errdefer allocator.free(validation);

        const channel_hdr = try std.fmt.allocPrintSentinel(
            allocator,
            "X-Browser-Channel: {s}",
            .{self.config.channel},
            0,
        );
        try headers.add(channel_hdr);

        const copyright_hdr = try std.fmt.allocPrintSentinel(
            allocator,
            "X-Browser-Copyright: {s}",
            .{self.config.copyright},
            0,
        );
        try headers.add(copyright_hdr);

        const validation_hdr = try std.fmt.allocPrintSentinel(
            allocator,
            "X-Browser-Validation: {s}",
            .{validation},
            0,
        );
        try headers.add(validation_hdr);

        const year_hdr = try std.fmt.allocPrintSentinel(
            allocator,
            "X-Browser-Year: {s}",
            .{self.config.year},
            0,
        );
        try headers.add(year_hdr);

        // X-Client-Data: Chromium ClientVariations formula (never a frozen base64).
        // Priority:
        // 1) KOKO_X_CLIENT_DATA — full base64 override for A/B only
        // 2) KOKO_VARIATION_IDS — comma-separated study IDs → encodeBase64
        // 3) session entropy → one google-web variation_id → encodeBase64
        // Empty encode → omit header (Chromium when total_id_count == 0).
        try appendClientDataHeader(headers, allocator, fingerprint_seed);
    }
};

fn appendClientDataHeader(
    headers: *HttpClient.Headers,
    allocator: Allocator,
    fingerprint_seed: u64,
) !void {
    if (runtime_io.getenv("KOKO_X_CLIENT_DATA")) |override| {
        if (override.len == 0) return;
        const xcd_hdr = try std.fmt.allocPrintSentinel(
            allocator,
            "X-Client-Data: {s}",
            .{override},
            0,
        );
        try headers.add(xcd_hdr);
        return;
    }

    const b64 = blk: {
        if (runtime_io.getenv("KOKO_VARIATION_IDS")) |csv| {
            const ids = try ClientVariations.parseIdList(allocator, csv);
            defer allocator.free(ids);
            break :blk try ClientVariations.encodeBase64(allocator, ids, &[_]i32{});
        }
        var session_ids: [1]i32 = undefined;
        ClientVariations.sessionGoogleWebIds(fingerprint_seed, &session_ids);
        break :blk try ClientVariations.encodeBase64(allocator, session_ids[0..], &[_]i32{});
    };
    defer allocator.free(b64);
    if (b64.len == 0) return;

    const xcd_hdr = try std.fmt.allocPrintSentinel(
        allocator,
        "X-Client-Data: {s}",
        .{b64},
        0,
    );
    try headers.add(xcd_hdr);
}

const JsonApiKeys = struct {
    macos: []const u8,
    windows: []const u8,
    linux: []const u8,
};

const JsonPlugin = struct {
    version: u32,
    id: []const u8,
    channel: []const u8,
    copyright: []const u8,
    year: []const u8,
    apiKeys: JsonApiKeys,
};

fn apiKeyForUserAgent(config: *const Config, user_agent: []const u8) []const u8 {
    var lower_buf: [512]u8 = undefined;
    const ua_lower = if (user_agent.len <= lower_buf.len) blk: {
        for (user_agent, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
        break :blk lower_buf[0..user_agent.len];
    } else user_agent;
    if (std.mem.indexOf(u8, ua_lower, "windows") != null) return config.api_key_windows;
    if (std.mem.indexOf(u8, ua_lower, "linux") != null) return config.api_key_linux;
    if (std.mem.indexOf(u8, ua_lower, "macintosh") != null or
        std.mem.indexOf(u8, ua_lower, "mac os x") != null)
        return config.api_key_macos;
    return config.api_key_macos;
}

pub fn validationToken(allocator: Allocator, config: *const Config, user_agent: []const u8) ![:0]const u8 {
    const api_key = apiKeyForUserAgent(config, user_agent);
    var data = try std.ArrayList(u8).initCapacity(allocator, api_key.len + user_agent.len);
    defer data.deinit(allocator);
    try data.appendSlice(allocator, api_key);
    try data.appendSlice(allocator, user_agent);

    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(data.items, &digest, .{});

    const enc = std.base64.standard.Encoder;
    var out_buf: [32]u8 = undefined;
    const encoded = out_buf[0..enc.calcSize(digest.len)];
    _ = enc.encode(encoded, &digest);
    return try allocator.dupeZ(u8, encoded);
}

const testing = @import("../../../testing/testing.zig");

test "XBrowser: validation macOS Chrome 149" {
    const config = Config{
        .channel = "stable",
        .copyright = "Copyright 2026 Google LLC. All Rights Reserved.",
        .year = "2026",
        .api_key_macos = "AIzaSyDr2UxVnv_U85AbhhY8XSHSIavUW0DC-sY",
        .api_key_windows = "AIzaSyA2KlwBX3mkFo30om9LUFYQhpqLoa_BNhE",
        .api_key_linux = "AIzaSyBqJZh-7pA44blAaAkH6490hUFOwX0KCYM",
    };
    const ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36";
    const val = try validationToken(testing.allocator, &config, ua);
    defer testing.allocator.free(val);
    try testing.expectEqualStrings("H+o9v6cagVZd2pOTUnzHRIkqiWI=", val);
}

test "XBrowser: loads plugin JSON without clientData hardcode" {
    var plugin = try Plugin.load(testing.allocator);
    defer plugin.deinit(testing.allocator);
    try testing.expectEqualStrings("stable", plugin.config.channel);
    try testing.expectEqualStrings("2026", plugin.config.year);
}

test "XBrowser: client data is formula-encoded from session seed" {
    // Two seeds → two different base64 strings (not a fixed capture).
    const a = blk: {
        var ids: [1]i32 = undefined;
        ClientVariations.sessionGoogleWebIds(1, &ids);
        break :blk try ClientVariations.encodeBase64(testing.allocator, ids[0..], &[_]i32{});
    };
    defer testing.allocator.free(a);
    const b = blk: {
        var ids: [1]i32 = undefined;
        ClientVariations.sessionGoogleWebIds(2, &ids);
        break :blk try ClientVariations.encodeBase64(testing.allocator, ids[0..], &[_]i32{});
    };
    defer testing.allocator.free(b);
    try testing.expect(a.len > 0);
    try testing.expect(b.len > 0);
    try testing.expect(!std.mem.eql(u8, a, b));
    // Must not freeze either historical capture as the only legal value.
    try testing.expect(!std.mem.eql(u8, a, "CLaAywE=") or !std.mem.eql(u8, b, "CLaAywE="));
}
