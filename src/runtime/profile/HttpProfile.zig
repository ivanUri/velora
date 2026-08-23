const std = @import("std");
const URL = @import("../../core/browser/URL.zig");
const HttpClient = @import("../../core/browser/HttpClient.zig");
const Profile = @import("Profile.zig");
const ProfileStore = @import("ProfileStore.zig");
const build_config = @import("build_config");

/// Chrome-like HTTP header order for document and subresource requests.
/// Document navigations follow Chrome 150 Accept-first order (live CDP ExtraInfo).
pub const document_accept =
    "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7";

pub const firefox_document_accept =
    "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8";

pub const subresource_accept = "Accept: */*";
pub const accept_encoding = "Accept-Encoding: gzip, deflate, br";
/// Chrome 150 document navigations: gzip, deflate, br, zstd (no dcb/dcz).
pub const accept_encoding_zstd = "Accept-Encoding: gzip, deflate, br, zstd";
pub const document_priority = "Priority: u=0, i";
pub const subresource_priority = "Priority: u=1, i";
pub const image_priority = "Priority: i";
pub const image_accept = "Accept: image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8";

/// Cold / first-hop Network Information estimates (rarely sent on hop-1; kept for non-search).
pub const document_downlink: f64 = 9.8;
pub const document_rtt: u32 = 50;

/// In-search sei=/sg_ss= hops: Chrome HAR 2026-07-17 sei SERP hop used Downlink 1.5, RTT 50.
pub const in_session_downlink: f64 = 1.5;
pub const in_session_rtt: u32 = 50;

fn isInSessionDocument(opts: ChromeHeadersOpts) bool {
    return opts.omit_sec_fetch_user or opts.referer_url != null;
}

fn documentNetworkEstimates(opts: ChromeHeadersOpts) struct { downlink: f64, rtt: u32 } {
    if (isInSessionDocument(opts)) {
        return .{ .downlink = in_session_downlink, .rtt = in_session_rtt };
    }
    return .{ .downlink = document_downlink, .rtt = document_rtt };
}

pub const RequestContext = struct {
    pub const NavigationDestination = enum {
        top_level,
        iframe,
    };

    request_url: [:0]const u8,
    resource_type: HttpClient.RequestParams.ResourceType,
    frame_origin: ?[]const u8 = null,
    prior_origin: ?[]const u8 = null,
    is_document_navigation: bool = false,
    navigation_destination: NavigationDestination = .top_level,
    origin: ?[]const u8 = null,
    /// Fetch Metadata mode supplied by the request algorithm. Resource type is
    /// only a fallback for callers such as images and scripts whose mode is
    /// implied by their fetch destination.
    fetch_mode: ?[]const u8 = null,
    storage_access_active: bool = true,
};

pub fn secFetchDest(ctx: RequestContext) []const u8 {
    return switch (ctx.resource_type) {
        .document => if (ctx.navigation_destination == .iframe) "iframe" else "document",
        .script => "script",
        .worker => "worker",
        .image => "image",
        .stylesheet => "style",
        .fetch, .xhr, .beacon => "empty",
    };
}

pub fn secFetchMode(resource_type: HttpClient.RequestParams.ResourceType) []const u8 {
    return switch (resource_type) {
        .document => "navigate",
        .script, .beacon, .image, .stylesheet => "no-cors",
        .worker => "same-origin",
        .fetch, .xhr => "cors",
    };
}

pub fn secFetchSite(ctx: RequestContext) []const u8 {
    if (ctx.is_document_navigation) {
        const origin = ctx.prior_origin orelse return "none";
        if (!std.mem.startsWith(u8, ctx.request_url, origin)) return "cross-site";
        if (std.mem.eql(u8, URL.getHost(ctx.request_url), URL.getHost(origin))) return "same-origin";
        return "cross-site";
    }

    const origin = ctx.frame_origin orelse return "none";
    if (!std.mem.startsWith(u8, ctx.request_url, origin)) return "cross-site";
    if (std.mem.eql(u8, URL.getHost(ctx.request_url), URL.getHost(origin))) return "same-origin";
    return "cross-site";
}

pub const StaticHeaders = struct {
    user_agent_header: [:0]const u8,
    sec_ch_ua_header: [:0]const u8,
    accept_language_header: [:0]const u8,
};

pub const ChromeHeadersOpts = struct {
    full_client_hints: bool = false,
    brands: []const ProfileStore.Brand = &.{},
    color_scheme: []const u8 = "light",
    /// Chrome omits Sec-Fetch-User on in-search sei= hops (still sends Dest/Mode/Site).
    omit_sec_fetch_user: bool = false,
    /// Referer URL for in-search sei=/sg_ss= hops (inserted after Priority, before RTT).
    referer_url: ?[]const u8 = null,
};

fn isBrowserBrand(brand: []const u8) bool {
    return std.mem.indexOf(u8, brand, "Chrome") != null or std.mem.indexOf(u8, brand, "Chromium") != null;
}

fn brandFullVersion(allocator: std.mem.Allocator, brand: ProfileStore.Brand, ua_full_version: []const u8) ![]const u8 {
    if (isBrowserBrand(brand.brand)) return ua_full_version;
    if (std.mem.indexOfScalar(u8, brand.version, '.') != null) return brand.version;
    return try std.fmt.allocPrint(allocator, "{s}.0.0.0", .{brand.version});
}

fn appendFullVersionListHeader(
    headers: *HttpClient.Headers,
    allocator: std.mem.Allocator,
    brands: []const ProfileStore.Brand,
    ua_full_version: []const u8,
) !void {
    var list = try std.ArrayList(u8).initCapacity(allocator, 128);
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, "Sec-Ch-Ua-Full-Version-List:");
    for (brands, 0..) |brand, i| {
        const sep = if (i == 0) " " else ", ";
        try list.appendSlice(allocator, sep);
        const full_ver = try brandFullVersion(allocator, brand, ua_full_version);
        const rendered = try std.fmt.allocPrint(allocator, "\"{s}\";v=\"{s}\"", .{ brand.brand, full_ver });
        defer allocator.free(rendered);
        try list.appendSlice(allocator, rendered);
    }
    try list.append(allocator, 0);
    const slice = try list.toOwnedSlice(allocator);
    try headers.add(slice[0 .. slice.len - 1 :0]);
}

/// Cold hop-1 Chrome: Arch, Bitness, Full-Version-List only (no Form-Factors / Full-Version).
fn appendColdClientHintsAfterSecChUa(
    headers: *HttpClient.Headers,
    allocator: std.mem.Allocator,
    identity: *const Profile.IdentityProfile,
    brands: []const ProfileStore.Brand,
) !void {
    const arch_hdr = try std.fmt.allocPrintSentinel(
        allocator,
        "Sec-Ch-Ua-Arch: \"{s}\"",
        .{identity.ua_architecture},
        0,
    );
    try headers.add(arch_hdr);

    const bitness_hdr = try std.fmt.allocPrintSentinel(
        allocator,
        "Sec-Ch-Ua-Bitness: \"{s}\"",
        .{identity.ua_bitness},
        0,
    );
    try headers.add(bitness_hdr);

    try appendFullVersionListHeader(headers, allocator, brands, identity.ua_full_version);
}

/// In-session Chrome: Arch, Bitness, Form-Factors, Full-Version, Full-Version-List.
fn appendHighEntropyClientHintsAfterSecChUa(
    headers: *HttpClient.Headers,
    allocator: std.mem.Allocator,
    identity: *const Profile.IdentityProfile,
    brands: []const ProfileStore.Brand,
) !void {
    const arch_hdr = try std.fmt.allocPrintSentinel(
        allocator,
        "Sec-Ch-Ua-Arch: \"{s}\"",
        .{identity.ua_architecture},
        0,
    );
    try headers.add(arch_hdr);

    const bitness_hdr = try std.fmt.allocPrintSentinel(
        allocator,
        "Sec-Ch-Ua-Bitness: \"{s}\"",
        .{identity.ua_bitness},
        0,
    );
    try headers.add(bitness_hdr);

    try headers.add("Sec-Ch-Ua-Form-Factors: \"Desktop\"");

    const full_ver_hdr = try std.fmt.allocPrintSentinel(
        allocator,
        "Sec-Ch-Ua-Full-Version: \"{s}\"",
        .{identity.ua_full_version},
        0,
    );
    try headers.add(full_ver_hdr);

    try appendFullVersionListHeader(headers, allocator, brands, identity.ua_full_version);
}

fn appendSecChUaMobilePlatform(
    headers: *HttpClient.Headers,
    allocator: std.mem.Allocator,
    identity: *const Profile.IdentityProfile,
    full_client_hints: bool,
) !void {
    const mobile_hdr = try std.fmt.allocPrintSentinel(
        allocator,
        "Sec-Ch-Ua-Mobile: {s}",
        .{if (identity.ua_mobile) "?1" else "?0"},
        0,
    );
    try headers.add(mobile_hdr);

    if (full_client_hints) {
        try headers.add("Sec-Ch-Ua-Model: \"\"");
    }

    const platform_hdr = try std.fmt.allocPrintSentinel(
        allocator,
        "Sec-Ch-Ua-Platform: \"{s}\"",
        .{identity.ua_data_platform},
        0,
    );
    try headers.add(platform_hdr);

    if (full_client_hints) {
        const platform_ver_hdr = try std.fmt.allocPrintSentinel(
            allocator,
            "Sec-Ch-Ua-Platform-Version: \"{s}\"",
            .{identity.platform_version},
            0,
        );
        try headers.add(platform_ver_hdr);
        try headers.add("Sec-Ch-Ua-Wow64: ?0");
    }
}

/// Chrome 150 document navigation order (live CDP requestWillBeSentExtraInfo).
///
/// Cold hop-1:
///   Accept → Accept-Encoding → Accept-Language → Priority → Sec-Ch-Prefers-Color-Scheme →
///   Sec-Ch-Ua → Arch → Bitness → Full-Version-List → Mobile → Model → Platform →
///   Platform-Version → Wow64 → Sec-Fetch-Dest/Mode/Site/User → UIR → User-Agent
///
/// In-session (sei=/sg_ss=):
///   Accept → AE → AL → Downlink → Priority → Referer → RTT → color-scheme → Sec-Ch-Ua →
///   full high-entropy CH → Sec-Fetch-Dest/Mode/Site (no User) → UIR → User-Agent
fn appendChromeDocumentNavigationHeaders(
    headers: *HttpClient.Headers,
    allocator: std.mem.Allocator,
    identity: *const Profile.IdentityProfile,
    static: *const StaticHeaders,
    ctx: RequestContext,
    opts: ChromeHeadersOpts,
) !void {
    try headers.add(document_accept);
    try headers.add(accept_encoding_zstd);
    try headers.add(static.accept_language_header);

    const in_session = isInSessionDocument(opts);
    const use_he_ch = in_session;
    const net = documentNetworkEstimates(opts);

    if (opts.full_client_hints and use_he_ch) {
        const downlink_hdr = try std.fmt.allocPrintSentinel(
            allocator,
            "Downlink: {d:.1}",
            .{net.downlink},
            0,
        );
        try headers.add(downlink_hdr);
    }

    try headers.add(document_priority);

    if (opts.referer_url) |ref| {
        const referer_hdr = try std.fmt.allocPrintSentinel(allocator, "Referer: {s}", .{ref}, 0);
        try headers.add(referer_hdr);
    }

    if (opts.full_client_hints and use_he_ch) {
        const rtt_hdr = try std.fmt.allocPrintSentinel(allocator, "RTT: {d}", .{net.rtt}, 0);
        try headers.add(rtt_hdr);
    }

    if (opts.full_client_hints) {
        const color_hdr = try std.fmt.allocPrintSentinel(
            allocator,
            "Sec-Ch-Prefers-Color-Scheme: {s}",
            .{opts.color_scheme},
            0,
        );
        try headers.add(color_hdr);
    }

    try headers.add(static.sec_ch_ua_header);

    if (opts.full_client_hints) {
        if (use_he_ch) {
            try appendHighEntropyClientHintsAfterSecChUa(headers, allocator, identity, opts.brands);
        } else {
            try appendColdClientHintsAfterSecChUa(headers, allocator, identity, opts.brands);
        }
    }

    try appendSecChUaMobilePlatform(headers, allocator, identity, opts.full_client_hints);

    // Chrome 150 always sends Dest/Mode/Site on document navigations.
    // Only Sec-Fetch-User is omitted on in-search sei= hops.
    {
        const site = secFetchSite(ctx);
        const mode = secFetchMode(ctx.resource_type);
        const dest = secFetchDest(ctx);

        const dest_hdr = try std.fmt.allocPrintSentinel(allocator, "Sec-Fetch-Dest: {s}", .{dest}, 0);
        try headers.add(dest_hdr);

        const mode_hdr = try std.fmt.allocPrintSentinel(allocator, "Sec-Fetch-Mode: {s}", .{mode}, 0);
        try headers.add(mode_hdr);

        const site_hdr = try std.fmt.allocPrintSentinel(allocator, "Sec-Fetch-Site: {s}", .{site}, 0);
        try headers.add(site_hdr);

        // Chromium marks embedded documents that have the browsing context's
        // storage-access grant active. This is a Fetch Metadata signal, not a
        // site policy; it belongs alongside the iframe destination metadata.
        if (ctx.navigation_destination == .iframe) {
            try headers.add("Sec-Fetch-Storage-Access: active");
        }

        if (ctx.navigation_destination == .top_level and !opts.omit_sec_fetch_user) {
            try headers.add("Sec-Fetch-User: ?1");
        }
    }

    // Upgrade-Insecure-Requests is a top-level navigation hint. Chrome does
    // not send it for embedded browsing contexts (iframe/object), where
    // emitting it changes the Fetch Metadata/header contract.
    if (ctx.navigation_destination == .top_level and
        std.mem.startsWith(u8, ctx.request_url, "https://"))
    {
        try headers.add("Upgrade-Insecure-Requests: 1");
    }

    // Full manual document lists include UA so wire order matches Chrome (UIR then UA).
    try headers.add(static.user_agent_header);
}

/// High-entropy client hints curl-impersonate defaults omit (legacy cold-supplement path).
/// Prefer `appendChromeDocumentNavigationHeaders` for Chrome 150 Accept-first order.
pub fn appendCurlImpersonateColdHopSupplements(
    headers: *HttpClient.Headers,
    allocator: std.mem.Allocator,
    identity: *const Profile.IdentityProfile,
    static: *const StaticHeaders,
    ctx: RequestContext,
    opts: ChromeHeadersOpts,
    antidetect: bool,
) !void {
    // Chrome 150 cold hop-1: full Accept-first list without Cache-Control/Pragma/Downlink/RTT.
    _ = antidetect;
    try appendChromeDocumentNavigationHeaders(headers, allocator, identity, static, ctx, opts);
}

/// Per-request overrides merged on top of curl_easy_impersonate default_headers.
/// Prefer full `appendChromeHeaders` for document navigations (Chrome 150 order).
pub fn appendCurlImpersonateDocumentOverrides(
    headers: *HttpClient.Headers,
    allocator: std.mem.Allocator,
    static: *const StaticHeaders,
    ctx: RequestContext,
    opts: ChromeHeadersOpts,
    antidetect: bool,
) !void {
    if (!std.mem.startsWith(u8, ctx.request_url, "http")) return;

    _ = opts;
    if (antidetect) {
        try headers.add(static.accept_language_header);
        try headers.add(static.sec_ch_ua_header);
    }
    const site = secFetchSite(ctx);
    // Cold omnibox uses curl default "none"; only override for real same-origin/cross-site hops.
    if (!std.mem.eql(u8, site, "none")) {
        const site_hdr = try std.fmt.allocPrintSentinel(allocator, "Sec-Fetch-Site: {s}", .{site}, 0);
        try headers.add(site_hdr);
    }
}

/// Append Chrome-ordered client hints + fetch metadata. Referer is set via CURLOPT_REFERER
/// when curl-impersonate is active — do not add it here unless `opts.referer_url` is set.
pub fn appendChromeHeaders(
    headers: *HttpClient.Headers,
    allocator: std.mem.Allocator,
    identity: *const Profile.IdentityProfile,
    static: *const StaticHeaders,
    ctx: RequestContext,
    opts: ChromeHeadersOpts,
) !void {
    if (!std.mem.startsWith(u8, ctx.request_url, "http")) return;

    if (ctx.resource_type == .document) {
        return appendChromeDocumentNavigationHeaders(headers, allocator, identity, static, ctx, opts);
    }

    // Priority and Accept are destination metadata selected by the browser,
    // not generic values shared by every subresource.
    try headers.add(if (ctx.resource_type == .image) image_priority else subresource_priority);
    try headers.add(static.sec_ch_ua_header);

    if (opts.full_client_hints) {
        try appendHighEntropyClientHintsAfterSecChUa(headers, allocator, identity, opts.brands);
    }

    try appendSecChUaMobilePlatform(headers, allocator, identity, opts.full_client_hints);

    if (opts.full_client_hints) {
        const color_hdr = try std.fmt.allocPrintSentinel(
            allocator,
            "Sec-Ch-Prefers-Color-Scheme: {s}",
            .{opts.color_scheme},
            0,
        );
        try headers.add(color_hdr);
    }

    if (comptime !build_config.curl_impersonate) {
        try headers.add(static.user_agent_header);
    }
    try headers.add(if (ctx.resource_type == .image) image_accept else subresource_accept);

    const site = secFetchSite(ctx);
    const mode = ctx.fetch_mode orelse secFetchMode(ctx.resource_type);
    const dest = secFetchDest(ctx);

    const site_hdr = try std.fmt.allocPrintSentinel(allocator, "Sec-Fetch-Site: {s}", .{site}, 0);
    try headers.add(site_hdr);

    const mode_hdr = try std.fmt.allocPrintSentinel(allocator, "Sec-Fetch-Mode: {s}", .{mode}, 0);
    try headers.add(mode_hdr);

    const dest_hdr = try std.fmt.allocPrintSentinel(allocator, "Sec-Fetch-Dest: {s}", .{dest}, 0);
    try headers.add(dest_hdr);

    // Storage access follows the request's effective credentials state. A
    // same-origin image is no-cors but still carries cookies/storage, whereas
    // a cross-origin fetch with credentials=same-origin does not.
    if (ctx.storage_access_active) {
        try headers.add("Sec-Fetch-Storage-Access: active");
    }

    try headers.add(accept_encoding_zstd);
    try headers.add(static.accept_language_header);

    if (ctx.origin) |origin| {
        const origin_hdr = try std.fmt.allocPrintSentinel(allocator, "Origin: {s}", .{origin}, 0);
        try headers.add(origin_hdr);
    }
}

/// Firefox document/subresource headers — no Sec-CH-UA client hints.
pub fn appendFirefoxHeaders(
    headers: *HttpClient.Headers,
    allocator: std.mem.Allocator,
    static: *const StaticHeaders,
    ctx: RequestContext,
) !void {
    try appendNonChromiumHeaders(headers, allocator, static, ctx, .firefox);
}

/// Safari 26-class headers (curl-impersonate safari260 order-ish) — no Sec-CH-UA / X-Browser.
pub const safari_document_accept =
    "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8";

pub fn appendSafariHeaders(
    headers: *HttpClient.Headers,
    allocator: std.mem.Allocator,
    static: *const StaticHeaders,
    ctx: RequestContext,
) !void {
    try appendNonChromiumHeaders(headers, allocator, static, ctx, .safari);
}

const NonChromiumFamily = enum { firefox, safari };

fn appendNonChromiumHeaders(
    headers: *HttpClient.Headers,
    allocator: std.mem.Allocator,
    static: *const StaticHeaders,
    ctx: RequestContext,
    family: NonChromiumFamily,
) !void {
    if (!std.mem.startsWith(u8, ctx.request_url, "http")) return;

    const is_document = ctx.resource_type == .document;

    // Safari curl wrapper: sec-fetch-dest → user-agent → accept → sec-fetch-site/mode →
    // accept-language → priority → accept-encoding. Firefox: UA-first simpler set.
    if (family == .safari and is_document) {
        const dest_hdr = try std.fmt.allocPrintSentinel(allocator, "Sec-Fetch-Dest: {s}", .{secFetchDest(ctx)}, 0);
        try headers.add(dest_hdr);
        try headers.add(static.user_agent_header);
        try headers.add(safari_document_accept);
        const site_hdr = try std.fmt.allocPrintSentinel(allocator, "Sec-Fetch-Site: {s}", .{secFetchSite(ctx)}, 0);
        try headers.add(site_hdr);
        try headers.add("Sec-Fetch-Mode: navigate");
        try headers.add(static.accept_language_header);
        try headers.add(document_priority);
        try headers.add(accept_encoding_zstd);
        if (std.mem.startsWith(u8, ctx.request_url, "https://")) {
            try headers.add("Upgrade-Insecure-Requests: 1");
        }
        if (ctx.navigation_destination == .top_level) {
            try headers.add("Sec-Fetch-User: ?1");
        }
        return;
    }

    try headers.add(static.user_agent_header);
    try headers.add(if (is_document) firefox_document_accept else subresource_accept);
    try headers.add(static.accept_language_header);
    try headers.add(accept_encoding);

    if (is_document and std.mem.startsWith(u8, ctx.request_url, "https://")) {
        try headers.add("Upgrade-Insecure-Requests: 1");
    }

    const dest = secFetchDest(ctx);
    const mode = secFetchMode(ctx.resource_type);
    const site = secFetchSite(ctx);

    const dest_hdr = try std.fmt.allocPrintSentinel(allocator, "Sec-Fetch-Dest: {s}", .{dest}, 0);
    try headers.add(dest_hdr);

    const mode_hdr = try std.fmt.allocPrintSentinel(allocator, "Sec-Fetch-Mode: {s}", .{mode}, 0);
    try headers.add(mode_hdr);

    const site_hdr = try std.fmt.allocPrintSentinel(allocator, "Sec-Fetch-Site: {s}", .{site}, 0);
    try headers.add(site_hdr);

    if (is_document and ctx.navigation_destination == .top_level) {
        try headers.add("Sec-Fetch-User: ?1");
    }

    if (!is_document) {
        if (ctx.origin) |origin| {
            const origin_hdr = try std.fmt.allocPrintSentinel(allocator, "Origin: {s}", .{origin}, 0);
            try headers.add(origin_hdr);
        }
    }
}

/// Fallback header order when curl-impersonate is unavailable (still Chrome-like).
pub fn appendFallbackHeaders(
    headers: *HttpClient.Headers,
    allocator: std.mem.Allocator,
    identity: *const Profile.IdentityProfile,
    static: *const StaticHeaders,
    ctx: RequestContext,
    referer_header: [:0]const u8,
) !void {
    if (referer_header.len > 0) {
        try headers.add(referer_header);
    }

    const mobile_hdr = try std.fmt.allocPrintSentinel(
        allocator,
        "Sec-Ch-Ua-Mobile: {s}",
        .{if (identity.ua_mobile) "?1" else "?0"},
        0,
    );
    try headers.add(mobile_hdr);

    const platform_hdr = try std.fmt.allocPrintSentinel(
        allocator,
        "Sec-Ch-Ua-Platform: \"{s}\"",
        .{identity.ua_data_platform},
        0,
    );
    try headers.add(platform_hdr);

    if (!std.mem.startsWith(u8, ctx.request_url, "http")) return;

    const is_document = ctx.resource_type == .document;
    try headers.add(if (is_document) document_accept else subresource_accept);

    if (!is_document) {
        if (ctx.origin) |origin| {
            const origin_hdr = try std.fmt.allocPrintSentinel(allocator, "Origin: {s}", .{origin}, 0);
            try headers.add(origin_hdr);
        }
    }

    const dest = secFetchDest(ctx);
    const mode = secFetchMode(ctx.resource_type);
    const site = secFetchSite(ctx);

    const dest_hdr = try std.fmt.allocPrintSentinel(allocator, "Sec-Fetch-Dest: {s}", .{dest}, 0);
    try headers.add(dest_hdr);

    const mode_hdr = try std.fmt.allocPrintSentinel(allocator, "Sec-Fetch-Mode: {s}", .{mode}, 0);
    try headers.add(mode_hdr);

    const site_hdr = try std.fmt.allocPrintSentinel(allocator, "Sec-Fetch-Site: {s}", .{site}, 0);
    try headers.add(site_hdr);

    if (is_document) {
        if (ctx.navigation_destination == .top_level) {
            try headers.add("Sec-Fetch-User: ?1");
        }
        if (std.mem.startsWith(u8, ctx.request_url, "https://")) {
            try headers.add("Upgrade-Insecure-Requests: 1");
        }
    }

    try headers.add(static.sec_ch_ua_header);
    try headers.add(static.user_agent_header);
    try headers.add(accept_encoding);
    try headers.add(static.accept_language_header);
}

const testing = @import("../../testing/testing.zig");

test "HttpProfile: secFetchSite same-origin" {
    const ctx = RequestContext{
        .request_url = "https://www.google.com/search",
        .resource_type = .document,
        .frame_origin = "https://www.google.com",
        .is_document_navigation = false,
    };
    try testing.expectEqualStrings("same-origin", secFetchSite(ctx));
}

test "HttpProfile: cold document hop has no Downlink and Sec-Fetch-User" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var headers = HttpClient.Headers.initEmpty();
    defer headers.deinit();

    const identity = Profile.macos_catalina_intel;
    const static = StaticHeaders{
        .user_agent_header = "User-Agent: test\x00",
        .sec_ch_ua_header = "Sec-Ch-Ua: \"Google Chrome\";v=\"149\"\x00",
        .accept_language_header = "Accept-Language: en-US,en;q=0.9\x00",
    };
    const ctx = RequestContext{
        .request_url = "https://www.google.com/search?q=test\x00",
        .resource_type = .document,
        .is_document_navigation = true,
        .prior_origin = null,
    };
    const opts = ChromeHeadersOpts{
        .full_client_hints = true,
        .brands = &.{.{ .brand = "Google Chrome", .version = "149" }},
        .color_scheme = "dark",
    };
    try appendChromeHeaders(&headers, alloc, &identity, &static, ctx, opts);

    var order = try std.ArrayList([]const u8).initCapacity(alloc, 32);
    defer order.deinit(alloc);
    var saw_downlink = false;
    var saw_rtt = false;
    var saw_cache = false;
    var saw_form_factors = false;
    var saw_full_version = false;
    var saw_full_version_list = false;
    var saw_sec_fetch_user = false;
    var saw_sec_fetch_site = false;
    var site_value: ?[]const u8 = null;
    var it = headers.iterator();
    while (it.next()) |hdr| {
        try order.append(alloc, hdr.name);
        if (std.mem.eql(u8, hdr.name, "Downlink")) saw_downlink = true;
        if (std.mem.eql(u8, hdr.name, "RTT")) saw_rtt = true;
        if (std.mem.eql(u8, hdr.name, "Cache-Control")) saw_cache = true;
        if (std.mem.eql(u8, hdr.name, "Sec-Ch-Ua-Form-Factors")) saw_form_factors = true;
        if (std.mem.eql(u8, hdr.name, "Sec-Ch-Ua-Full-Version")) saw_full_version = true;
        if (std.mem.eql(u8, hdr.name, "Sec-Ch-Ua-Full-Version-List")) saw_full_version_list = true;
        if (std.mem.eql(u8, hdr.name, "Sec-Fetch-User")) saw_sec_fetch_user = true;
        if (std.mem.eql(u8, hdr.name, "Sec-Fetch-Site")) {
            saw_sec_fetch_site = true;
            site_value = hdr.value;
        }
    }
    try testing.expect(!saw_downlink);
    try testing.expect(!saw_rtt);
    try testing.expect(!saw_cache);
    try testing.expect(!saw_form_factors);
    try testing.expect(!saw_full_version);
    try testing.expect(saw_full_version_list);
    try testing.expect(saw_sec_fetch_user);
    try testing.expect(saw_sec_fetch_site);
    try testing.expectEqualStrings("none", site_value.?);
    try testing.expectEqualStrings("Accept", order.items[0]);
    try testing.expectEqualStrings("Accept-Encoding", order.items[1]);
    try testing.expectEqualStrings("Accept-Language", order.items[2]);
    try testing.expectEqualStrings("Priority", order.items[3]);
}

test "HttpProfile: in-session document hop omits only Sec-Fetch-User" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var headers = HttpClient.Headers.initEmpty();
    defer headers.deinit();

    const identity = Profile.macos_catalina_intel;
    const static = StaticHeaders{
        .user_agent_header = "User-Agent: test\x00",
        .sec_ch_ua_header = "Sec-Ch-Ua: \"Google Chrome\";v=\"149\"\x00",
        .accept_language_header = "Accept-Language: en-US,en;q=0.9\x00",
    };
    const ctx = RequestContext{
        .request_url = "https://www.google.com/search?q=test&sei=abc\x00",
        .resource_type = .document,
        .is_document_navigation = true,
        .prior_origin = "https://www.google.com",
    };
    const opts = ChromeHeadersOpts{
        .full_client_hints = true,
        .brands = &.{.{ .brand = "Google Chrome", .version = "149" }},
        .color_scheme = "dark",
        .omit_sec_fetch_user = true,
        .referer_url = "https://www.google.com/search?q=test&hl=en",
    };
    try appendChromeHeaders(&headers, alloc, &identity, &static, ctx, opts);

    var downlink: ?f64 = null;
    var rtt: ?u32 = null;
    var saw_user = false;
    var saw_dest = false;
    var saw_mode = false;
    var saw_site = false;
    var saw_form_factors = false;
    var it = headers.iterator();
    while (it.next()) |hdr| {
        if (std.mem.eql(u8, hdr.name, "Downlink")) {
            downlink = try std.fmt.parseFloat(f64, hdr.value);
        }
        if (std.mem.eql(u8, hdr.name, "RTT")) {
            rtt = try std.fmt.parseInt(u32, hdr.value, 10);
        }
        if (std.mem.eql(u8, hdr.name, "Sec-Fetch-User")) saw_user = true;
        if (std.mem.eql(u8, hdr.name, "Sec-Fetch-Dest")) saw_dest = true;
        if (std.mem.eql(u8, hdr.name, "Sec-Fetch-Mode")) saw_mode = true;
        if (std.mem.eql(u8, hdr.name, "Sec-Fetch-Site")) saw_site = true;
        if (std.mem.eql(u8, hdr.name, "Sec-Ch-Ua-Form-Factors")) saw_form_factors = true;
    }
    try testing.expectEqual(in_session_downlink, downlink.?);
    try testing.expectEqual(in_session_rtt, rtt.?);
    try testing.expect(!saw_user);
    try testing.expect(saw_dest);
    try testing.expect(saw_mode);
    try testing.expect(saw_site);
    try testing.expect(saw_form_factors);
}

test "HttpProfile: iframe navigation uses iframe destination without user activation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var headers = HttpClient.Headers.initEmpty();
    defer headers.deinit();

    const identity = Profile.macos_catalina_intel;
    const static = StaticHeaders{
        .user_agent_header = "User-Agent: test\x00",
        .sec_ch_ua_header = "Sec-Ch-Ua: \"Google Chrome\";v=\"149\"\x00",
        .accept_language_header = "Accept-Language: en-US,en;q=0.9\x00",
    };
    const ctx = RequestContext{
        .request_url = "https://widget.example/challenge\x00",
        .resource_type = .document,
        .prior_origin = "https://embedder.example",
        .is_document_navigation = true,
        .navigation_destination = .iframe,
    };
    try appendChromeHeaders(&headers, alloc, &identity, &static, ctx, .{
        .full_client_hints = true,
        .brands = &.{.{ .brand = "Google Chrome", .version = "149" }},
    });

    var dest: ?[]const u8 = null;
    var mode: ?[]const u8 = null;
    var site: ?[]const u8 = null;
    var saw_user = false;
    var saw_uir = false;
    var it = headers.iterator();
    while (it.next()) |hdr| {
        if (std.mem.eql(u8, hdr.name, "Sec-Fetch-Dest")) dest = hdr.value;
        if (std.mem.eql(u8, hdr.name, "Sec-Fetch-Mode")) mode = hdr.value;
        if (std.mem.eql(u8, hdr.name, "Sec-Fetch-Site")) site = hdr.value;
        if (std.mem.eql(u8, hdr.name, "Sec-Fetch-User")) saw_user = true;
        if (std.mem.eql(u8, hdr.name, "Upgrade-Insecure-Requests")) saw_uir = true;
    }

    try testing.expectEqualStrings("iframe", dest.?);
    try testing.expectEqualStrings("navigate", mode.?);
    try testing.expectEqualStrings("cross-site", site.?);
    try testing.expect(!saw_user);
    try testing.expect(!saw_uir);
}

test "HttpProfile: XHR metadata never contains navigation-only headers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var headers = HttpClient.Headers.initEmpty();
    defer headers.deinit();

    const identity = Profile.macos_catalina_intel;
    const static = StaticHeaders{
        .user_agent_header = "User-Agent: test\x00",
        .sec_ch_ua_header = "Sec-Ch-Ua: \"Google Chrome\";v=\"149\"\x00",
        .accept_language_header = "Accept-Language: en-US,en;q=0.9\x00",
    };
    const ctx = RequestContext{
        .request_url = "https://widget.example/verify\x00",
        .resource_type = .xhr,
        .frame_origin = "https://widget.example",
        .origin = "https://widget.example",
    };
    try appendChromeHeaders(&headers, alloc, &identity, &static, ctx, .{});

    var dest: ?[]const u8 = null;
    var mode: ?[]const u8 = null;
    var saw_user = false;
    var saw_uir = false;
    var storage_access: ?[]const u8 = null;
    var priority: ?[]const u8 = null;
    var it = headers.iterator();
    while (it.next()) |hdr| {
        if (std.mem.eql(u8, hdr.name, "Sec-Fetch-Dest")) dest = hdr.value;
        if (std.mem.eql(u8, hdr.name, "Sec-Fetch-Mode")) mode = hdr.value;
        if (std.mem.eql(u8, hdr.name, "Sec-Fetch-User")) saw_user = true;
        if (std.mem.eql(u8, hdr.name, "Upgrade-Insecure-Requests")) saw_uir = true;
        if (std.mem.eql(u8, hdr.name, "Sec-Fetch-Storage-Access")) storage_access = hdr.value;
        if (std.mem.eql(u8, hdr.name, "Priority")) priority = hdr.value;
    }

    try testing.expectEqualStrings("empty", dest.?);
    try testing.expectEqualStrings("cors", mode.?);
    try testing.expect(!saw_user);
    try testing.expect(!saw_uir);
    try testing.expectEqualStrings("active", storage_access.?);
    try testing.expectEqualStrings("u=1, i", priority.?);
}

test "HttpProfile: explicit no-cors mode controls fetch metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var headers = HttpClient.Headers.initEmpty();
    defer headers.deinit();

    const identity = Profile.macos_catalina_intel;
    const static = StaticHeaders{
        .user_agent_header = "User-Agent: test\x00",
        .sec_ch_ua_header = "Sec-Ch-Ua: \"Google Chrome\";v=\"149\"\x00",
        .accept_language_header = "Accept-Language: en-US,en;q=0.9\x00",
    };
    const ctx = RequestContext{
        .request_url = "https://probe.example/status\x00",
        .resource_type = .fetch,
        .frame_origin = "https://embedder.example",
        .fetch_mode = "no-cors",
        .storage_access_active = false,
    };
    try appendChromeHeaders(&headers, alloc, &identity, &static, ctx, .{});

    var mode: ?[]const u8 = null;
    var storage_access: ?[]const u8 = null;
    var it = headers.iterator();
    while (it.next()) |hdr| {
        if (std.mem.eql(u8, hdr.name, "Sec-Fetch-Mode")) mode = hdr.value;
        if (std.mem.eql(u8, hdr.name, "Sec-Fetch-Storage-Access")) storage_access = hdr.value;
    }

    try testing.expectEqualStrings("no-cors", mode.?);
    try testing.expectEqual(@as(?[]const u8, null), storage_access);
}

test "HttpProfile: brandFullVersion maps Not A Brand to x.0.0.0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const ver = try brandFullVersion(alloc, .{ .brand = "Not)A;Brand", .version = "24" }, "149.0.7827.104");
    try testing.expectEqualStrings("24.0.0.0", ver);
    const chrome_ver = try brandFullVersion(alloc, .{ .brand = "Google Chrome", .version = "149" }, "149.0.7827.104");
    try testing.expectEqualStrings("149.0.7827.104", chrome_ver);
}
