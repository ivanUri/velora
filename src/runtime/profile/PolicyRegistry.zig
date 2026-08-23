const std = @import("std");
const ProfileStore = @import("ProfileStore.zig");
const runtime_io = @import("../../support/io.zig");

const Allocator = std.mem.Allocator;

pub const EnabledWhen = enum {
    always,
    antidetect,

    pub fn parse(raw: []const u8) ?EnabledWhen {
        if (std.mem.eql(u8, raw, "always")) return .always;
        if (std.mem.eql(u8, raw, "antidetect")) return .antidetect;
        return null;
    }

    pub fn allows(self: EnabledWhen, mode: ProfileStore.Mode) bool {
        return switch (self) {
            .always => true,
            .antidetect => mode == .antidetect,
        };
    }
};

pub const RefererMode = enum {
    none,
    search_q_only,
};

pub const When = enum {
    never,
    in_session,
    first_hop,
    address_bar_in_session,
    first_hop_or_query_contains,
    query_contains,
};

pub const InjectParam = struct {
    name: []const u8,
    when: When,
};

pub const ExternalTransport = struct {
    config_flag: []const u8,
    when: When,
    query_contains: []const []const u8,
};

pub const NavigationRules = struct {
    inject_param: ?InjectParam = null,
    referer: RefererMode = .none,
    prior_origin: ?[]const u8 = null,
    omit_cookies: When = .never,
    omit_sec_fetch_user: When = .never,
    curl_defaults_only: When = .never,
    prefer_http3: When = .never,
    force_fresh_connection: When = .never,
    external_transport: ?ExternalTransport = null,
};

pub const HttpRules = struct {
    header_plugin: ?[]const u8 = null,
    host_suffixes: []const []const u8,
    path_contains: []const []const u8,
};

pub const SitePolicy = struct {
    id: []const u8,
    enabled_when: EnabledWhen,
    host_suffixes: []const []const u8,
    path_contains: []const []const u8,
    navigation: NavigationRules,
    http: ?HttpRules = null,

    pub fn matchesNavigationUrl(self: *const SitePolicy, url: []const u8) bool {
        return policyMatchesUrl(self.host_suffixes, self.path_contains, url);
    }

    pub fn matchesSiteUrl(self: *const SitePolicy, url: []const u8) bool {
        return policyMatchesUrl(self.host_suffixes, &.{}, url);
    }
};

pub const PolicyRegistry = struct {
    arena: std.heap.ArenaAllocator,
    policies: []const SitePolicy,

    pub fn init(allocator: Allocator) !PolicyRegistry {
        var self: PolicyRegistry = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .policies = &.{},
        };
        errdefer self.deinit();

        const arena = self.arena.allocator();
        const bytes = try readPolicyFile(arena, "browser/policies/google-search.json");
        const policy = try parseSitePolicy(arena, bytes);
        const policies = try arena.alloc(SitePolicy, 1);
        policies[0] = policy;
        self.policies = policies;
        return self;
    }

    pub fn deinit(self: *PolicyRegistry) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn matchNavigation(
        self: *const PolicyRegistry,
        mode: ProfileStore.Mode,
        enabled_policies: []const []const u8,
        request_url: []const u8,
    ) ?*const SitePolicy {
        for (self.policies) |*policy| {
            if (!policyEnabled(enabled_policies, policy.id)) continue;
            if (!policy.enabled_when.allows(mode)) continue;
            if (!policyMatchesUrl(policy.host_suffixes, policy.path_contains, request_url)) continue;
            return policy;
        }
        return null;
    }

    pub fn matchHttpPlugin(
        self: *const PolicyRegistry,
        mode: ProfileStore.Mode,
        enabled_policies: []const []const u8,
        request_url: []const u8,
    ) ?[]const u8 {
        for (self.policies) |*policy| {
            if (!policyEnabled(enabled_policies, policy.id)) continue;
            if (!policy.enabled_when.allows(mode)) continue;
            const http = policy.http orelse continue;
            const plugin = http.header_plugin orelse continue;
            if (!policyMatchesUrl(http.host_suffixes, http.path_contains, request_url)) continue;
            return plugin;
        }
        return null;
    }
};

fn policyEnabled(enabled_policies: []const []const u8, policy_id: []const u8) bool {
    for (enabled_policies) |id| {
        if (std.mem.eql(u8, id, policy_id)) return true;
    }
    return false;
}

fn policyMatchesUrl(host_suffixes: []const []const u8, path_contains: []const []const u8, url: []const u8) bool {
    const parts = parseUrlForPolicy(url) orelse return false;
    var host_ok = host_suffixes.len == 0;
    for (host_suffixes) |suffix| {
        if (hostMatchesSuffix(parts.host, suffix)) {
            host_ok = true;
            break;
        }
    }
    if (!host_ok) return false;

    if (path_contains.len == 0) return true;
    for (path_contains) |needle| {
        if (std.mem.indexOf(u8, parts.path_query, needle) != null) return true;
    }
    return false;
}

const PolicyUrlParts = struct {
    host: []const u8,
    path_query: []const u8,
};

fn parseUrlForPolicy(url: []const u8) ?PolicyUrlParts {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const authority_start = scheme_end + 3;
    if (authority_start >= url.len) return null;
    const authority_tail = url[authority_start..];
    const authority_len = std.mem.indexOfAny(u8, authority_tail, "/?#") orelse authority_tail.len;
    const authority = authority_tail[0..authority_len];
    if (authority.len == 0) return null;

    const host_port = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at|
        authority[at + 1 ..]
    else
        authority;
    if (host_port.len == 0) return null;

    const host = if (host_port[0] == '[') blk: {
        const close = std.mem.indexOfScalar(u8, host_port, ']') orelse return null;
        break :blk host_port[0 .. close + 1];
    } else if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |colon|
        host_port[0..colon]
    else
        host_port;
    if (host.len == 0) return null;

    const path_start = authority_start + authority_len;
    return .{
        .host = host,
        .path_query = if (path_start < url.len) url[path_start..] else "/",
    };
}

fn hostMatchesSuffix(host: []const u8, suffix: []const u8) bool {
    if (suffix.len == 0 or host.len < suffix.len) return false;
    const offset = host.len - suffix.len;
    if (!std.ascii.eqlIgnoreCase(host[offset..], suffix)) return false;
    return offset == 0 or host[offset - 1] == '.';
}

fn readPolicyFile(allocator: Allocator, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), path, allocator, .unlimited);
}

const JsonInjectParam = struct {
    name: []const u8,
    when: []const u8,
};

const JsonExternalTransport = struct {
    configFlag: []const u8,
    when: []const u8,
    queryContains: []const []const u8 = &.{},
};

const JsonNavigation = struct {
    injectParam: ?JsonInjectParam = null,
    referer: []const u8 = "none",
    priorOrigin: ?[]const u8 = null,
    omitCookies: []const u8 = "never",
    omitSecFetchUser: []const u8 = "never",
    curlDefaultsOnly: []const u8 = "never",
    preferHttp3: []const u8 = "never",
    forceFreshConnection: []const u8 = "never",
    externalTransport: ?JsonExternalTransport = null,
};

const JsonHttp = struct {
    match: JsonMatch = .{},
    headerPlugin: ?[]const u8 = null,
};

const JsonMatch = struct {
    hostSuffix: []const []const u8 = &.{},
    pathContains: []const []const u8 = &.{},
};

const JsonSitePolicy = struct {
    version: u32,
    id: []const u8,
    enabledWhen: []const u8,
    match: JsonMatch,
    navigation: JsonNavigation,
    http: ?JsonHttp = null,
};

fn parseWhen(raw: []const u8) !When {
    if (std.mem.eql(u8, raw, "never")) return .never;
    if (std.mem.eql(u8, raw, "in_session")) return .in_session;
    if (std.mem.eql(u8, raw, "first_hop")) return .first_hop;
    if (std.mem.eql(u8, raw, "address_bar_in_session")) return .address_bar_in_session;
    if (std.mem.eql(u8, raw, "first_hop_or_query_contains")) return .first_hop_or_query_contains;
    if (std.mem.eql(u8, raw, "query_contains")) return .query_contains;
    return error.InvalidPolicy;
}

fn parseRefererMode(raw: []const u8) !RefererMode {
    if (std.mem.eql(u8, raw, "none")) return .none;
    if (std.mem.eql(u8, raw, "search_q_only")) return .search_q_only;
    return error.InvalidPolicy;
}

fn dupeStrings(allocator: Allocator, src: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, src.len);
    for (src, 0..) |s, i| out[i] = try allocator.dupe(u8, s);
    return out;
}

fn parseSitePolicy(allocator: Allocator, bytes: []const u8) !SitePolicy {
    var parsed = try std.json.parseFromSlice(JsonSitePolicy, allocator, bytes, .{});
    defer parsed.deinit();
    const doc = parsed.value;
    if (doc.version != 1) return error.UnsupportedPolicyVersion;

    const enabled_when = EnabledWhen.parse(doc.enabledWhen) orelse return error.InvalidPolicy;
    const nav = doc.navigation;

    var rules: NavigationRules = .{
        .referer = try parseRefererMode(nav.referer),
        .omit_cookies = try parseWhen(nav.omitCookies),
        .omit_sec_fetch_user = try parseWhen(nav.omitSecFetchUser),
        .curl_defaults_only = try parseWhen(nav.curlDefaultsOnly),
        .prefer_http3 = try parseWhen(nav.preferHttp3),
        .force_fresh_connection = try parseWhen(nav.forceFreshConnection),
    };

    if (nav.priorOrigin) |origin| {
        rules.prior_origin = try allocator.dupe(u8, origin);
    }

    if (nav.injectParam) |param| {
        rules.inject_param = .{
            .name = try allocator.dupe(u8, param.name),
            .when = try parseWhen(param.when),
        };
    }

    if (nav.externalTransport) |transport| {
        rules.external_transport = .{
            .config_flag = try allocator.dupe(u8, transport.configFlag),
            .when = try parseWhen(transport.when),
            .query_contains = try dupeStrings(allocator, transport.queryContains),
        };
    }

    var http_rules: ?HttpRules = null;
    if (doc.http) |http_doc| {
        http_rules = .{
            .header_plugin = if (http_doc.headerPlugin) |plugin| try allocator.dupe(u8, plugin) else null,
            .host_suffixes = try dupeStrings(allocator, http_doc.match.hostSuffix),
            .path_contains = try dupeStrings(allocator, http_doc.match.pathContains),
        };
    }

    return .{
        .id = try allocator.dupe(u8, doc.id),
        .enabled_when = enabled_when,
        .host_suffixes = try dupeStrings(allocator, doc.match.hostSuffix),
        .path_contains = try dupeStrings(allocator, doc.match.pathContains),
        .navigation = rules,
        .http = http_rules,
    };
}

const testing = @import("../../testing/testing.zig");

test "PolicyRegistry: loads google-search policy" {
    var registry = try PolicyRegistry.init(testing.allocator);
    defer registry.deinit();
    try testing.expect(registry.policies.len == 1);
    try testing.expectString("google-search", registry.policies[0].id);
}

const google_search_policy = [_][]const u8{"google-search"};

test "PolicyRegistry: antidetect match on google search URL" {
    var registry = try PolicyRegistry.init(testing.allocator);
    defer registry.deinit();
    const url = "https://www.google.com/search?q=koko";
    const policy = registry.matchNavigation(.antidetect, &google_search_policy, url);
    try testing.expect(policy != null);
    try testing.expectString("google-search", policy.?.id);
}

test "PolicyRegistry: koko mode skips antidetect-only policy" {
    var registry = try PolicyRegistry.init(testing.allocator);
    defer registry.deinit();
    const url = "https://www.google.com/search?q=koko";
    try testing.expect(registry.matchNavigation(.koko, &google_search_policy, url) == null);
}

test "PolicyRegistry: antidetect without profile opt-in skips policy" {
    var registry = try PolicyRegistry.init(testing.allocator);
    defer registry.deinit();
    const url = "https://www.google.com/search?q=koko";
    try testing.expect(registry.matchNavigation(.antidetect, &.{}, url) == null);
}

test "PolicyRegistry: http plugin matches any google.com URL" {
    var registry = try PolicyRegistry.init(testing.allocator);
    defer registry.deinit();
    const plugin = registry.matchHttpPlugin(.antidetect, &google_search_policy, "https://www.google.com/gen_204?x");
    try testing.expect(plugin != null);
    try testing.expectEqualStrings("x-browser", plugin.?);
}

test "PolicyRegistry: host suffix is matched on parsed hostname boundary" {
    try testing.expect(policyMatchesUrl(&.{"example.com"}, &.{"/search"}, "https://www.example.com/search?q=x"));
    try testing.expect(!policyMatchesUrl(&.{"example.com"}, &.{"/search"}, "https://example.com.attacker.test/search"));
    try testing.expect(!policyMatchesUrl(&.{"example.com"}, &.{"/search"}, "https://attacker.test/?next=https://example.com/search"));
    try testing.expect(!policyMatchesUrl(&.{"example.com"}, &.{"/search"}, "not a URL containing example.com/search"));
}
