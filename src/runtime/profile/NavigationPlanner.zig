const std = @import("std");
const runtime_io = @import("../../support/io.zig");
const PolicyRegistry = @import("PolicyRegistry.zig");
const ProfileStore = @import("ProfileStore.zig");

const Allocator = std.mem.Allocator;

pub const Reason = enum {
    anchor,
    address_bar,
    form,
    script,
    history,
    navigation,
    initial_frame_navigation,
};

pub const NavigationContext = struct {
    prior_url: []const u8,
    request_url: [:0]const u8,
    reason: Reason,
    referer: ?[]const u8 = null,
    prior_origin: ?[]const u8 = null,
    external_transport_enabled: bool = false,
};

pub const NavigationPlan = struct {
    effective_url: [:0]const u8,
    referer: ?[:0]const u8 = null,
    prior_origin: ?[]const u8 = null,
    omit_cookies: bool = false,
    omit_sec_fetch_user: bool = false,
    curl_defaults_only: bool = false,
    use_external_transport: bool = false,
    /// Transport preferences selected by an explicitly enabled policy.
    prefer_http3: bool = false,
    force_fresh_connection: bool = false,
};

pub fn navigationPlan(
    allocator: Allocator,
    mode: ProfileStore.Mode,
    enabled_policies: []const []const u8,
    registry: *const PolicyRegistry.PolicyRegistry,
    ctx: NavigationContext,
) !NavigationPlan {
    const policy = registry.matchNavigation(mode, enabled_policies, ctx.request_url);
    if (policy == null) {
        return defaultPlan(allocator, ctx);
    }
    return applyPolicy(allocator, policy.?, ctx);
}

fn defaultPlan(allocator: Allocator, ctx: NavigationContext) !NavigationPlan {
    return .{
        .effective_url = try allocator.dupeZ(u8, ctx.request_url),
        .referer = try defaultReferer(allocator, ctx),
        .prior_origin = ctx.prior_origin,
    };
}

fn defaultReferer(allocator: Allocator, ctx: NavigationContext) !?[:0]const u8 {
    if (ctx.referer) |ref| return try allocator.dupeZ(u8, ref);
    if (std.mem.startsWith(u8, ctx.prior_url, "http") and
        !std.mem.eql(u8, ctx.prior_url, ctx.request_url))
    {
        return try allocator.dupeZ(u8, ctx.prior_url);
    }
    return null;
}

fn defaultRefererFromPlan(allocator: Allocator, prior_url: []const u8, effective_url: []const u8, referer: ?[]const u8) !?[:0]const u8 {
    if (referer) |ref| return try allocator.dupeZ(u8, ref);
    if (std.mem.startsWith(u8, prior_url, "http") and !std.mem.eql(u8, prior_url, effective_url)) {
        return try allocator.dupeZ(u8, prior_url);
    }
    return null;
}

fn applyPolicy(allocator: Allocator, policy: *const PolicyRegistry.SitePolicy, ctx: NavigationContext) !NavigationPlan {
    const rules = policy.navigation;
    const flow_prior_url = resolveFlowPriorUrl(policy, ctx);
    const first_hop = isFirstHop(policy, flow_prior_url, ctx.request_url, ctx.reason);
    const policy_flow = isPolicyFlow(policy, flow_prior_url, ctx.request_url, ctx.reason);
    const in_session = policy_flow and !first_hop;

    var effective_url: [:0]const u8 = ctx.request_url;
    var effective_url_owned = false;
    if (rules.inject_param) |param| {
        if (param.when == .address_bar_in_session and
            !first_hop and
            ctx.reason == .address_bar)
        {
            effective_url = try appendQueryParamIfMissing(allocator, ctx.request_url, param.name);
            effective_url_owned = true;
        }
    }
    if (!effective_url_owned) {
        effective_url = try allocator.dupeZ(u8, ctx.request_url);
    }

    var prior_origin = ctx.prior_origin;
    var generated_referer: ?[:0]const u8 = null;
    errdefer if (generated_referer) |ref| allocator.free(ref);
    if (in_session) {
        if (rules.prior_origin) |origin| {
            if (prior_origin == null) prior_origin = try allocator.dupe(u8, origin);
        }
        if (rules.referer == .search_q_only) {
            const ref_src = if (policy.matchesNavigationUrl(ctx.prior_url)) ctx.prior_url else effective_url;
            generated_referer = try searchQOnlyReferer(allocator, ref_src);
        }
    }

    const nav_referer = generated_referer orelse
        try defaultRefererFromPlan(allocator, ctx.prior_url, effective_url, ctx.referer);

    const use_external_transport = blk: {
        const transport = rules.external_transport orelse break :blk false;
        if (!ctx.external_transport_enabled) break :blk false;
        if (!policy_flow) break :blk false;
        break :blk switch (transport.when) {
            .first_hop_or_query_contains => first_hop or urlContainsAny(ctx.request_url, transport.query_contains),
            .query_contains => urlContainsAny(ctx.request_url, transport.query_contains),
            .first_hop => first_hop,
            else => false,
        };
    };

    return .{
        .effective_url = effective_url,
        .referer = nav_referer,
        .prior_origin = prior_origin,
        .omit_cookies = whenActive(rules.omit_cookies, in_session, first_hop),
        .omit_sec_fetch_user = whenActive(rules.omit_sec_fetch_user, in_session, first_hop),
        .curl_defaults_only = whenActive(rules.curl_defaults_only, in_session, first_hop),
        .use_external_transport = use_external_transport,
        .prefer_http3 = whenActive(rules.prefer_http3, in_session, first_hop),
        .force_fresh_connection = whenActive(rules.force_fresh_connection, in_session, first_hop),
    };
}

fn whenActive(rule: PolicyRegistry.When, in_session: bool, first_hop: bool) bool {
    return switch (rule) {
        .never => false,
        .in_session => in_session,
        .first_hop => first_hop,
        else => false,
    };
}

fn resolveFlowPriorUrl(policy: *const PolicyRegistry.SitePolicy, ctx: NavigationContext) []const u8 {
    if (policy.matchesNavigationUrl(ctx.prior_url)) return ctx.prior_url;
    if (ctx.referer) |ref| {
        if (policy.matchesNavigationUrl(ref)) return ref;
        if (policy.matchesSiteUrl(ref)) return ref;
    }
    return ctx.prior_url;
}

fn isFirstHop(policy: *const PolicyRegistry.SitePolicy, flow_prior_url: []const u8, request_url: []const u8, reason: Reason) bool {
    return policy.matchesNavigationUrl(request_url) and
        !policy.matchesNavigationUrl(flow_prior_url) and
        (reason == .address_bar or reason == .form);
}

fn isPolicyFlow(policy: *const PolicyRegistry.SitePolicy, flow_prior_url: []const u8, request_url: []const u8, reason: Reason) bool {
    if (!policy.matchesNavigationUrl(request_url)) return false;
    if (reason == .address_bar) return true;
    if (reason == .form and policy.matchesSiteUrl(flow_prior_url)) return true;
    return policy.matchesNavigationUrl(flow_prior_url);
}

fn urlContainsAny(url: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, url, needle) != null) return true;
    }
    return false;
}

fn appendQueryParamIfMissing(allocator: Allocator, url: []const u8, name: []const u8) ![:0]const u8 {
    const marker = try std.fmt.allocPrint(allocator, "{s}=", .{name});
    defer allocator.free(marker);
    if (std.mem.indexOf(u8, url, marker) != null) return try allocator.dupeZ(u8, url);

    var rand: [16]u8 = undefined;
    runtime_io.get().random(&rand);
    const enc = std.base64.url_safe_no_pad.Encoder;
    var value_buf: [32]u8 = undefined;
    const value = value_buf[0..enc.calcSize(rand.len)];
    _ = enc.encode(value, &rand);

    const sep: []const u8 = if (std.mem.indexOf(u8, url, "?") != null) "&" else "?";
    return try std.fmt.allocPrintSentinel(allocator, "{s}{s}{s}={s}", .{ url, sep, name, value }, 0);
}

fn searchQOnlyReferer(allocator: Allocator, url: []const u8) ![:0]const u8 {
    const q_pos = std.mem.indexOf(u8, url, "q=") orelse return try allocator.dupeZ(u8, url);
    const q_start = q_pos + 2;
    const q_end = std.mem.indexOfPos(u8, url, q_start, "&") orelse url.len;
    const base_end = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
    const base = url[0..base_end];
    if (std.mem.indexOf(u8, url, "hl=")) |hl_pos| {
        const hl_start = hl_pos + 3;
        const hl_end = std.mem.indexOfPos(u8, url, hl_start, "&") orelse url.len;
        return try std.fmt.allocPrintSentinel(
            allocator,
            "{s}?q={s}&hl={s}",
            .{ base, url[q_start..q_end], url[hl_start..hl_end] },
            0,
        );
    }
    return try std.fmt.allocPrintSentinel(
        allocator,
        "{s}?q={s}",
        .{ base, url[q_start..q_end] },
        0,
    );
}

const testing = @import("../../testing/testing.zig");

const google_search_policy = [_][]const u8{"google-search"};

test "NavigationPlanner: koko mode is no-op" {
    var registry = try PolicyRegistry.PolicyRegistry.init(testing.allocator);
    defer registry.deinit();

    const plan = try navigationPlan(testing.allocator, .koko, &google_search_policy, &registry, .{
        .prior_url = "about:blank",
        .request_url = "https://www.google.com/search?q=test",
        .reason = .address_bar,
    });
    defer testing.allocator.free(plan.effective_url);
    defer if (plan.referer) |ref| testing.allocator.free(ref);

    try testing.expectString("https://www.google.com/search?q=test", plan.effective_url);
    try testing.expect(!plan.omit_cookies);
    try testing.expect(!plan.curl_defaults_only);
}

test "NavigationPlanner: antidetect first hop is cold omnibox (no priorOrigin, full headers)" {
    var registry = try PolicyRegistry.PolicyRegistry.init(testing.allocator);
    defer registry.deinit();

    const plan = try navigationPlan(testing.allocator, .antidetect, &google_search_policy, &registry, .{
        .prior_url = "about:blank",
        .request_url = "https://www.google.com/search?q=test",
        .reason = .address_bar,
    });
    defer testing.allocator.free(plan.effective_url);
    defer if (plan.referer) |ref| testing.allocator.free(ref);
    defer if (plan.prior_origin) |origin| testing.allocator.free(origin);

    try testing.expect(!plan.curl_defaults_only);
    try testing.expect(!plan.omit_cookies);
    try testing.expect(!plan.omit_sec_fetch_user);
    try testing.expect(plan.prior_origin == null);
    try testing.expect(!plan.use_external_transport);
}

test "NavigationPlanner: first hop uses Chrome transport when flag enabled" {
    var registry = try PolicyRegistry.PolicyRegistry.init(testing.allocator);
    defer registry.deinit();

    const plan = try navigationPlan(testing.allocator, .antidetect, &google_search_policy, &registry, .{
        .prior_url = "about:blank",
        .request_url = "https://www.google.com/search?q=test",
        .reason = .address_bar,
        .external_transport_enabled = true,
    });
    defer testing.allocator.free(plan.effective_url);
    defer if (plan.referer) |ref| testing.allocator.free(ref);
    defer if (plan.prior_origin) |origin| testing.allocator.free(origin);

    try testing.expect(plan.use_external_transport);
}

test "NavigationPlanner: sg_ss hop uses Chrome transport when flag enabled" {
    var registry = try PolicyRegistry.PolicyRegistry.init(testing.allocator);
    defer registry.deinit();

    const plan = try navigationPlan(testing.allocator, .antidetect, &google_search_policy, &registry, .{
        .prior_url = "https://www.google.com/search?q=prev",
        .request_url = "https://www.google.com/search?q=test&sg_ss=*abc",
        .reason = .navigation,
        .external_transport_enabled = true,
    });
    defer testing.allocator.free(plan.effective_url);
    defer if (plan.referer) |ref| testing.allocator.free(ref);
    defer if (plan.prior_origin) |origin| testing.allocator.free(origin);

    try testing.expect(plan.use_external_transport);
}

test "NavigationPlanner: in-session redirect hop uses navigation reason" {
    var registry = try PolicyRegistry.PolicyRegistry.init(testing.allocator);
    defer registry.deinit();

    const plan = try navigationPlan(testing.allocator, .antidetect, &google_search_policy, &registry, .{
        .prior_url = "https://www.google.com/search?q=test&hl=vi",
        .request_url = "https://www.google.com/search?q=test&hl=vi&sei=abc",
        .reason = .navigation,
    });
    defer testing.allocator.free(plan.effective_url);
    defer if (plan.referer) |ref| testing.allocator.free(ref);
    defer if (plan.prior_origin) |origin| testing.allocator.free(origin);

    try testing.expect(!plan.omit_cookies);
    try testing.expect(plan.omit_sec_fetch_user);
    try testing.expect(!plan.curl_defaults_only);
    try testing.expect(plan.prior_origin != null);
}

test "NavigationPlanner: antidetect in-session omits sec-fetch-user keeps cookies" {
    var registry = try PolicyRegistry.PolicyRegistry.init(testing.allocator);
    defer registry.deinit();

    const plan = try navigationPlan(testing.allocator, .antidetect, &google_search_policy, &registry, .{
        .prior_url = "https://www.google.com/search?q=prev&hl=en",
        .request_url = "https://www.google.com/search?q=test&hl=en&sg_ss=1",
        .reason = .address_bar,
    });
    defer testing.allocator.free(plan.effective_url);
    defer if (plan.referer) |ref| testing.allocator.free(ref);
    defer if (plan.prior_origin) |origin| testing.allocator.free(origin);

    try testing.expect(!plan.omit_cookies);
    try testing.expect(plan.omit_sec_fetch_user);
    try testing.expect(!plan.curl_defaults_only);
    try testing.expect(plan.referer != null);
    try testing.expectString("https://www.google.com/search?q=prev&hl=en", plan.referer.?);
}

test "NavigationPlanner: antidetect without profile opt-in is no-op" {
    var registry = try PolicyRegistry.PolicyRegistry.init(testing.allocator);
    defer registry.deinit();

    const plan = try navigationPlan(testing.allocator, .antidetect, &.{}, &registry, .{
        .prior_url = "about:blank",
        .request_url = "https://www.google.com/search?q=test",
        .reason = .address_bar,
    });
    defer testing.allocator.free(plan.effective_url);
    defer if (plan.referer) |ref| testing.allocator.free(ref);

    try testing.expect(!plan.curl_defaults_only);
    try testing.expect(!plan.omit_cookies);
}
