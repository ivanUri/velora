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
const datetime = @import("../../../support/datetime.zig");

const URL = @import("../../browser/URL.zig");
const DateTime = @import("../../../support/datetime.zig").DateTime;
const public_suffix_list = @import("../../../data/public_suffix_list.zig").lookup;

const log = @import("../../../support/log.zig");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Cookie = @This();

/// RFC6265bis §5.4 / WPT: name+value octets are limited to 4096 bytes total;
/// the "=" separator is not counted. A name-only or value-only pair may use
/// the full 4096 bytes on that side.
const max_cookie_octets = 4 * 1024;
const max_attribute_value_size = 1024;
const max_jar_size = 1024;

arena: ArenaAllocator,
name: []const u8,
value: []const u8,
domain: []const u8,
path: []const u8,
expires: ?f64,
secure: bool = false,
http_only: bool = false,
same_site: SameSite = .none,
/// Minimum `Jar.document_nav_generation` before this cookie is attached to HTTP
/// requests. Reserved for generic lifecycle-controlled cookie visibility.
available_from_nav: u64 = 0,
/// Origin that set this cookie (scheme + port binding).
source_secure: bool = false,
source_port: u16 = 0,
/// CHIPS: cookie is scoped to a top-level schemeful site partition.
partitioned: bool = false,
partition_site: ?[]const u8 = null,

pub const SameSite = enum {
    strict,
    lax,
    none,
};

pub fn deinit(self: *const Cookie) void {
    self.arena.deinit();
}

// There's https://datatracker.ietf.org/doc/html/rfc6265 but browsers are
// far less strict. Cookie names and values reject CTL bytes (%x00-1F and
// %x7F) except tab (%x09); UTF-8 is allowed. Domain attribute shenanigans
// are rejected separately - the domain has to be the current domain or one
// of higher order, excluding TLD.
// Anything else, will turn into a cookie.
// Single value? That's a cookie with an empty name and a value
// Key or Values with characters the RFC says aren't allowed? Allowed!
// Invalid attributes? Ignored.
// Invalid attribute values? Ignore.
// Duplicate attributes - use the last valid
// Value-less attributes with a value? Ignore the value
pub fn parse(allocator: Allocator, url: [:0]const u8, str: []const u8) !Cookie {
    if (str.len == 0) {
        return error.Empty;
    }

    const cookie_name, const cookie_value, const rest = parseNameValue(str) catch |err| {
        return if (err == error.Empty) error.InvalidNameValue else err;
    };

    try validateNameValue(cookie_name, cookie_value);
    try validateAttributeSection(rest);

    if (!isCookieNameValuePairValid(cookie_name, cookie_value)) {
        return error.CookieSizeExceeded;
    }

    if (cookie_name.len == 0 and cookie_value.len == 0) {
        return error.InvalidNameValue;
    }

    if (cookie_name.len == 0 and (std.ascii.startsWithIgnoreCase(cookie_value, "__Host-") or
        std.ascii.startsWithIgnoreCase(cookie_value, "__Secure-") or
        std.ascii.startsWithIgnoreCase(cookie_value, "__Http-")))
    {
        // A nameless cookie whose value begins with __Host-, __Secure-, or __Http-
        // (case-insensitive) would otherwise impersonate a cookie with that
        // prefix. Reject per the cookie-name-prefix rules.
        return error.InvalidNameValue;
    }

    var scrap: [16]u8 = undefined;

    var path: ?[]const u8 = null;
    var domain: ?[]const u8 = null;
    var secure: ?bool = null;
    var max_age: ?i64 = null;
    var http_only: ?bool = null;
    var expires: ?[]const u8 = null;
    var same_site: ?Cookie.SameSite = null;
    var partitioned: ?bool = null;

    var it = std.mem.splitScalar(u8, rest, ';');
    while (it.next()) |attribute| {
        const sep = std.mem.indexOfScalarPos(u8, attribute, 0, '=') orelse attribute.len;
        const key_string = trim(attribute[0..sep]);

        if (key_string.len > scrap.len) {
            // not valid, ignore
            continue;
        }

        const key = std.meta.stringToEnum(enum {
            path,
            domain,
            secure,
            @"max-age",
            expires,
            httponly,
            samesite,
            partitioned,
        }, std.ascii.lowerString(&scrap, key_string)) orelse continue;

        const value = if (sep == attribute.len) "" else trim(attribute[sep + 1 ..]);
        if (value.len > max_attribute_value_size) {
            continue;
        }
        switch (key) {
            .path => path = value,
            .domain => domain = value,
            .secure => secure = true,
            .@"max-age" => max_age = parseMaxAge(value) catch continue,
            .expires => expires = value,
            .httponly => http_only = true,
            .samesite => {
                if (value.len > scrap.len) {
                    continue;
                }
                same_site = std.meta.stringToEnum(Cookie.SameSite, std.ascii.lowerString(&scrap, value)) orelse continue;
            },
            .partitioned => partitioned = true,
        }
    }

    if (same_site == .none and secure == null) {
        return error.InsecureSameSite;
    }

    if (partitioned != null and secure == null) {
        return error.InsecurePartitionedCookie;
    }

    // Enforce cookie-name-prefix rules. Match is case-insensitive to
    // cover impersonation attempts (e.g. "__HoSt-").
    // https://datatracker.ietf.org/doc/html/draft-ietf-httpbis-rfc6265bis#name-cookie-name-prefixes
    if (std.ascii.startsWithIgnoreCase(cookie_name, "__Host-Http-")) {
        // __Host-Http-: Secure, host-only, Path=/, HttpOnly; HTTP Set-Cookie only.
        if (secure == null or http_only == null) {
            return error.InvalidPrefixedCookie;
        }

        if (!URL.isSecureOrigin(url)) {
            return error.InvalidPrefixedCookie;
        }

        if (domain != null and domain.?.len > 0) {
            return error.InvalidPrefixedCookie;
        }

        if (path == null or !std.mem.eql(u8, path.?, "/")) {
            return error.InvalidPrefixedCookie;
        }
    } else if (std.ascii.startsWithIgnoreCase(cookie_name, "__Host-")) {
        if (secure == null) {
            return error.InvalidPrefixedCookie;
        }

        if (!URL.isSecureOrigin(url)) {
            return error.InvalidPrefixedCookie;
        }

        if (domain != null and domain.?.len > 0) {
            return error.InvalidPrefixedCookie;
        }

        if (path == null or !std.mem.eql(u8, path.?, "/")) {
            return error.InvalidPrefixedCookie;
        }
    } else if (std.ascii.startsWithIgnoreCase(cookie_name, "__Http-")) {
        // __Http-: Secure + HttpOnly; HTTP Set-Cookie only (Path unrestricted).
        if (secure == null or http_only == null) {
            return error.InvalidPrefixedCookie;
        }

        if (!URL.isSecureOrigin(url)) {
            return error.InvalidPrefixedCookie;
        }
    } else if (std.ascii.startsWithIgnoreCase(cookie_name, "__Secure-")) {
        if (secure == null) {
            return error.InvalidPrefixedCookie;
        }
        if (!URL.isSecureOrigin(url)) {
            return error.InvalidPrefixedCookie;
        }
    }

    // Secure cookies may only be set from secure origins (https, wss).
    if (secure != null and !URL.isSecureOrigin(url)) {
        return error.InsecureSecureCookie;
    }

    var arena = ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const owned_name = try aa.dupe(u8, cookie_name);
    const owned_value = try aa.dupe(u8, cookie_value);
    const owned_path = try parsePath(aa, url, path);
    const owned_domain = try parseDomain(aa, url, domain);

    var normalized_expires: ?f64 = null;
    if (max_age) |ma| {
        normalized_expires = @floatFromInt(@as(i64, @intCast(datetime.timestamp(.clock))) + ma);
    } else {
        // max age takes priority over expires
        if (expires) |expires_| {
            var exp_dt = DateTime.parse(expires_, .rfc822) catch null;
            if (exp_dt == null) {
                if ((expires_.len > 11 and expires_[7] == '-' and expires_[11] == '-')) {
                    // Replace dashes and try again
                    const output = try aa.dupe(u8, expires_);
                    output[7] = ' ';
                    output[11] = ' ';
                    exp_dt = DateTime.parse(output, .rfc822) catch null;
                }
            }
            if (exp_dt) |dt| {
                normalized_expires = @floatFromInt(dt.unix(.seconds));
            } else {
                // Algolia, for example, will call document.setCookie with
                // an expired value which is literally 'Invalid Date'
                // (it's trying to do something like: `new Date() + undefined`).
                log.debug(.frame, "cookie expires date", .{ .date = expires_ });
            }
        }
    }

    return .{
        .arena = arena,
        .name = owned_name,
        .value = owned_value,
        .path = owned_path,
        .same_site = same_site orelse .lax,
        .secure = secure orelse false,
        .http_only = http_only orelse false,
        .domain = owned_domain,
        .expires = normalized_expires,
        .partitioned = partitioned != null,
        .source_secure = URL.isSecureOrigin(url),
        .source_port = canonicalPort(url),
    };
}

const ValidateCookieError = error{ Empty, InvalidByteSequence };

/// RFC 5234 CTL: %x00-1F / %x7F. Tab (%x09) is allowed in cookie names and
/// values per browser behavior and WPT. UTF-8 bytes above 0x7F are allowed.
fn isCookieCtl(c: u8) bool {
    return (c < 0x20 and c != 0x09) or c == 0x7F;
}

fn validateNameValue(name: []const u8, value: []const u8) ValidateCookieError!void {
    for (name) |c| {
        if (isCookieCtl(c)) return error.InvalidByteSequence;
    }
    for (value) |c| {
        if (isCookieCtl(c)) return error.InvalidByteSequence;
    }
}

/// WPT attributes-ctl: CTL bytes in the attribute section reject the entire
/// cookie line. Tab (%x09) is allowed in attribute values (e.g. `path\t=/`).
fn validateAttributeSection(rest: []const u8) ValidateCookieError!void {
    for (rest) |c| {
        if (isCookieCtl(c)) return error.InvalidByteSequence;
    }
}

pub fn parsePath(arena: Allocator, url_: ?[:0]const u8, explicit_path: ?[]const u8) ![]const u8 {
    // path attribute value either begins with a '/' or we
    // ignore it and use the "default-path" algorithm
    if (explicit_path) |path| {
        if (path.len > 0 and path[0] == '/') {
            return try arena.dupe(u8, path);
        }
    }

    // default-path (RFC 6265bis section 5.7.2)
    const url = url_ orelse return try arena.dupe(u8, "/");
    const uri_path = URL.getPathname(url);
    if (uri_path.len == 0 or uri_path[0] != '/') {
        return try arena.dupe(u8, "/");
    }
    if (uri_path.len == 1) {
        return try arena.dupe(u8, "/");
    }
    const index = std.mem.lastIndexOfScalar(u8, uri_path, '/') orelse return try arena.dupe(u8, "/");
    if (index == 0) return try arena.dupe(u8, "/");
    return try arena.dupe(u8, uri_path[0..index]);
}

fn isCookieNameValuePairValid(name: []const u8, value: []const u8) bool {
    if (name.len == 0) {
        return value.len <= max_cookie_octets;
    }
    if (value.len == 0) {
        return name.len <= max_cookie_octets;
    }
    return name.len + value.len <= max_cookie_octets;
}

const SanitizedHttpCookie = struct {
    slice: []const u8,
    owned: bool,
};

/// RFC 9110 / WPT: NUL/LF/CR in the cookie *name* are replaced with SP; in the
/// *value* (and trailing attribute text) they truncate the cookie string.
fn sanitizeHttpSetCookie(allocator: Allocator, set_cookie: []const u8) !SanitizedHttpCookie {
    const pair_end = std.mem.indexOfScalar(u8, set_cookie, ';') orelse set_cookie.len;
    const eq = std.mem.indexOfScalarPos(u8, set_cookie, 0, '=');
    const value_start: ?usize = if (eq) |e| if (e < pair_end) e + 1 else null else null;

    var end = set_cookie.len;
    if (value_start) |vs| {
        const value_and_attrs = set_cookie[vs..];
        if (std.mem.indexOfAny(u8, value_and_attrs, &.{ 0, '\n', '\r' })) |off| {
            end = vs + off;
        }
    }

    const truncated = set_cookie[0..end];
    const name_end = value_start orelse truncated.len;

    var needs_copy = false;
    for (truncated[0..name_end]) |c| {
        if (c == 0 or c == '\n' or c == '\r') {
            needs_copy = true;
            break;
        }
    }
    if (!needs_copy) return .{ .slice = truncated, .owned = false };

    const buf = try allocator.alloc(u8, truncated.len);
    for (truncated, 0..) |c, i| {
        buf[i] = if (i < name_end and (c == 0 or c == '\n' or c == '\r')) ' ' else c;
    }
    return .{ .slice = buf, .owned = true };
}

/// RFC 6265 section 5.1.4 path-match algorithm.
pub fn pathMatches(cookie_path: []const u8, request_path: []const u8) bool {
    if (std.mem.eql(u8, cookie_path, request_path)) {
        return true;
    }
    if (!std.mem.startsWith(u8, request_path, cookie_path)) {
        return false;
    }
    if (cookie_path[cookie_path.len - 1] == '/') {
        return true;
    }
    return request_path.len > cookie_path.len and request_path[cookie_path.len] == '/';
}

pub fn parseDomain(arena: Allocator, url_: ?[:0]const u8, explicit_domain: ?[]const u8) ![]const u8 {
    var encoded_host: ?[]const u8 = null;
    if (url_) |url| {
        const host = try percentEncode(arena, URL.getHostname(url), isHostChar);
        _ = toLower(host);
        encoded_host = host;
    }

    if (explicit_domain) |domain| {
        if (domain.len > 0) {
            const no_leading_dot = if (domain[0] == '.') domain[1..] else domain;

            var aw = try std.Io.Writer.Allocating.initCapacity(arena, no_leading_dot.len + 1);
            try aw.writer.writeByte('.');
            try std.Uri.Component.percentEncode(&aw.writer, no_leading_dot, isHostChar);
            const owned_domain = toLower(aw.written());

            if (std.mem.indexOfScalarPos(u8, owned_domain, 1, '.') == null and std.mem.eql(u8, "localhost", owned_domain[1..]) == false) {
                // can't set a cookie for a TLD
                return error.InvalidDomain;
            }

            // Can't set a cookie for a public suffix (e.g. co.uk, com.au).
            if (public_suffix_list(owned_domain[1..])) {
                return error.InvalidDomain;
            }

            if (encoded_host) |host| {
                // The host must match the requested domain exactly or as a
                // proper subdomain. A raw suffix check would incorrectly
                // accept "attackerexample.com" as matching "example.com",
                // letting a lookalike origin overwrite cookies on the victim
                // domain. `owned_domain` always has a leading dot, so
                // endsWith against it enforces the label boundary.
                const exact_match = std.mem.eql(u8, host, owned_domain[1..]);
                const subdomain_match = std.mem.endsWith(u8, host, owned_domain);
                if (exact_match == false and subdomain_match == false) {
                    return error.InvalidDomain;
                }
            }

            return owned_domain;
        }
    }

    if (encoded_host) |host| {
        if (host.len > 0) return host;
    }
    return error.InvalidDomain;
}

pub fn percentEncode(arena: Allocator, part: []const u8, comptime isValidChar: fn (u8) bool) ![]u8 {
    var aw = try std.Io.Writer.Allocating.initCapacity(arena, part.len);
    try std.Uri.Component.percentEncode(&aw.writer, part, isValidChar);
    return aw.written(); // @memory retains memory used before growing
}

pub fn isHostChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => true,
        ':' => true,
        '[', ']' => true,
        else => false,
    };
}

pub fn isPathChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => true,
        '/', ':', '@' => true,
        else => false,
    };
}

fn parseNameValue(str: []const u8) !struct { []const u8, []const u8, []const u8 } {
    const key_value_end = std.mem.indexOfScalarPos(u8, str, 0, ';') orelse str.len;
    const rest = if (key_value_end == str.len) "" else str[key_value_end + 1 ..];

    const sep = std.mem.indexOfScalarPos(u8, str[0..key_value_end], 0, '=') orelse {
        const value = trim(str[0..key_value_end]);
        if (value.len == 0) {
            return error.Empty;
        }
        return .{ "", value, rest };
    };

    const name = trim(str[0..sep]);
    const value = trim(str[sep + 1 .. key_value_end]);
    if (name.len == 0 and value.len == 0) {
        return error.Empty;
    }
    return .{ name, value, rest };
}

pub fn appliesTo(self: *const Cookie, url: *const PreparedUri, same_site: bool, is_navigation: bool, is_http: bool) bool {
    if (self.http_only and is_http == false) {
        // http only cookies cannot be accessed from Javascript
        return false;
    }

    if (url.secure == false and self.secure) {
        // secure cookie can only be sent over HTTPs
        return false;
    }

    if (same_site == false) {
        // If we aren't on the "same site" (matching 2nd level domain
        // taking into account public suffix list), then the cookie
        // can only be sent if cookie.same_site == .none, or if
        // we're navigating to (as opposed to, say, loading an image)
        // and cookie.same_site == .lax
        switch (self.same_site) {
            .strict => return false,
            .lax => if (is_navigation == false) return false,
            .none => {},
        }
    }

    {
        if (self.domain.len == 0) {
            return false;
        }
        if (self.domain[0] == '.') {
            // When a Set-Cookie header has a Domain attribute
            // Then we will _always_ prefix it with a dot, extending its
            // availability to all subdomains (yes, setting the Domain
            // attributes EXPANDS the domains which the cookie will be
            // sent to, to always include all subdomains).
            if (std.mem.eql(u8, url.host, self.domain[1..]) == false and std.mem.endsWith(u8, url.host, self.domain) == false) {
                return false;
            }
        } else if (std.mem.eql(u8, url.host, self.domain) == false) {
            // When the Domain attribute isn't specific, then the cookie
            // is only sent on an exact match (with WPT loopback aliasing).
            if (!loopbackHostsShareCookies(self.domain, url.host)) {
                return false;
            }
        }
    }

    if (!pathMatches(self.path, url.path)) {
        return false;
    }
    return true;
}

pub const Jar = struct {
    pub const Mutation = union(enum) {
        upsert: *const Cookie,
        delete: *const Cookie,
        clear: void,
    };

    pub const MutationSink = struct {
        ctx: *anyopaque,
        notify: *const fn (*anyopaque, Mutation) void,
    };

    allocator: Allocator,
    cookies: std.ArrayList(Cookie),
    /// Incremented at the start of each document navigation (see `beginDocumentNavigation`).
    document_nav_generation: u64 = 0,
    mutation_sink: ?MutationSink = null,

    pub fn init(allocator: Allocator) Jar {
        return .{
            .cookies = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Jar) void {
        for (self.cookies.items) |c| {
            c.deinit();
        }
        self.cookies.deinit(self.allocator);
    }

    pub fn clearRetainingCapacity(self: *Jar) void {
        self.notifyMutation(.clear);
        for (self.cookies.items) |c| {
            c.deinit();
        }
        self.cookies.clearRetainingCapacity();
    }

    pub fn setMutationSink(self: *Jar, sink: ?MutationSink) void {
        self.mutation_sink = sink;
    }

    fn notifyMutation(self: *Jar, mutation: Mutation) void {
        const sink = self.mutation_sink orelse return;
        sink.notify(sink.ctx, mutation);
    }

    /// Call when a document navigation begins, before the HTTP request is issued.
    pub fn beginDocumentNavigation(self: *Jar) void {
        self.document_nav_generation +%= 1;
    }

    pub fn add(
        self: *Jar,
        cookie: Cookie,
        request_time: i64,
        /// Checks if addition comes from HTTP request or JS context.
        comptime is_http: bool,
    ) !void {
        try self.addWithTopLevel(cookie, request_time, is_http, null);
    }

    pub fn addWithTopLevel(
        self: *Jar,
        cookie: Cookie,
        request_time: i64,
        /// Checks if addition comes from HTTP request or JS context.
        comptime is_http: bool,
        top_level_url: ?[]const u8,
    ) !void {
        var c = cookie;

        if (c.partitioned) {
            const tl = top_level_url orelse {
                c.deinit();
                return;
            };
            c.partition_site = try schemefulSiteKey(c.arena.allocator(), tl);
        }
        // Set-Cookie takes effect as soon as the response is processed.
        c.available_from_nav = self.document_nav_generation;

        const is_expired = isCookieExpired(&c, request_time);
        defer if (is_expired) {
            c.deinit();
        };

        if (!isCookieNameValuePairValid(c.name, c.value)) {
            return error.CookieSizeExceeded;
        }

        for (self.cookies.items, 0..) |*existing, i| {
            // We're only looking for the equal one.
            if (areCookiesEqual(&c, existing) == false) {
                continue;
            }

            // RFC 6265bis 5.7.2: a non-HTTP API (e.g. document.cookie) must
            // not replace an HttpOnly cookie.
            if (existing.http_only and is_http == false) {
                if (is_expired == false) c.deinit();
                return;
            }

            if (is_expired) {
                self.notifyMutation(.{ .delete = existing });
                existing.deinit();
                _ = self.cookies.swapRemove(i);
            } else {
                existing.deinit();
                self.cookies.items[i] = c;
                self.notifyMutation(.{ .upsert = &self.cookies.items[i] });
            }
            return;
        }

        if (!is_expired) {
            if (self.cookies.items.len >= max_jar_size) {
                return error.CookieJarQuotaExceeded;
            }
            try self.cookies.append(self.allocator, c);
            self.notifyMutation(.{ .upsert = &self.cookies.items[self.cookies.items.len - 1] });
        }
    }

    pub fn removeExpired(self: *Jar, request_time: ?i64) void {
        if (self.cookies.items.len == 0) return;
        const time = request_time orelse @as(i64, @intCast(datetime.timestamp(.clock)));
        var i: usize = self.cookies.items.len;
        while (i > 0) {
            i -= 1;
            const cookie = &self.cookies.items[i];
            if (isCookieExpired(cookie, time)) {
                self.notifyMutation(.{ .delete = cookie });
                self.cookies.swapRemove(i).deinit();
            }
        }
    }

    pub const LookupOpts = struct {
        is_http: bool,
        request_time: ?i64 = null,
        is_navigation: bool = true,
        prefix: ?[]const u8 = null,
        origin_url: ?[:0]const u8 = null,
        /// Top-level browsing context for CHIPS partition keys and third-party blocking.
        top_level_url: ?[]const u8 = null,
        /// Active document navigation generation; defaults to `Jar.document_nav_generation`.
        nav_generation: ?u64 = null,
    };
    pub fn forRequest(self: *Jar, target_url: [:0]const u8, writer: anytype, opts: LookupOpts) !void {
        const nav_generation = opts.nav_generation orelse self.document_nav_generation;
        const target = PreparedUri{
            .host = URL.getHostname(target_url),
            .path = URL.getPathname(target_url),
            .secure = URL.isSecureOrigin(target_url),
        };
        const same_site = areSameSite(opts.origin_url, target_url);
        const top_level = opts.top_level_url orelse opts.origin_url;
        const third_party = if (opts.origin_url) |origin|
            isThirdPartyContext(top_level orelse origin, target_url)
        else
            false;

        removeExpired(self, opts.request_time);

        var matching: std.ArrayList(usize) = .empty;
        defer matching.deinit(self.allocator);

        for (self.cookies.items, 0..) |*cookie, i| {
            if (!originBindingMatches(cookie, target_url)) {
                continue;
            }
            if (!opts.is_http and third_party and !cookie.partitioned) {
                continue;
            }
            if (!partitionSiteMatches(cookie, top_level)) {
                continue;
            }
            if (!cookie.appliesTo(&target, same_site, opts.is_navigation, opts.is_http)) {
                continue;
            }
            if (opts.is_http and nav_generation < cookie.available_from_nav) {
                continue;
            }
            try matching.append(self.allocator, i);
        }

        // WPT path.html: longer matching paths appear first in document.cookie.
        const items = self.cookies.items;
        std.mem.sort(usize, matching.items, items, struct {
            fn lessThan(ctx: []Cookie, a: usize, b: usize) bool {
                if (ctx[a].path.len != ctx[b].path.len) {
                    return ctx[a].path.len > ctx[b].path.len;
                }
                return a < b;
            }
        }.lessThan);

        var first = true;
        for (matching.items) |i| {
            const cookie = &items[i];
            if (first) {
                if (opts.prefix) |prefix| {
                    try writer.writeAll(prefix);
                }
                first = false;
            } else {
                try writer.writeAll("; ");
            }
            try writeCookie(cookie, writer);
        }
    }

    pub fn populateFromResponse(self: *Jar, url: [:0]const u8, set_cookie: []const u8, top_level_url: ?[:0]const u8) !void {
        const tl = top_level_url orelse url;
        if (isThirdPartyContext(tl, url)) {
            // Peek for Partitioned before full parse to avoid work on blocked cookies.
            if (std.ascii.indexOfIgnoreCase(set_cookie, "partitioned") == null) {
                return;
            }
        }

        const sanitized = sanitizeHttpSetCookie(self.allocator, set_cookie) catch return;
        defer if (sanitized.owned) self.allocator.free(sanitized.slice);

        const c = Cookie.parse(self.allocator, url, sanitized.slice) catch |err| {
            log.warn(.frame, "cookie parse failed", .{ .raw = set_cookie, .err = err });
            return;
        };

        if (isThirdPartyContext(tl, url) and !c.partitioned) {
            c.deinit();
            return;
        }

        const now: i64 = @intCast(datetime.timestamp(.clock));
        try self.addWithTopLevel(c, now, true, tl);
    }

    fn writeCookie(cookie: *const Cookie, writer: anytype) !void {
        if (cookie.name.len > 0) {
            try writer.writeAll(cookie.name);
            try writer.writeByte('=');
        }
        if (cookie.value.len > 0) {
            try writer.writeAll(cookie.value);
        }
    }
};

fn isCookieExpired(cookie: *const Cookie, now: i64) bool {
    const ce = cookie.expires orelse return false;
    return ce <= @as(f64, @floatFromInt(now));
}

fn areCookiesEqual(a: *const Cookie, b: *const Cookie) bool {
    if (std.mem.eql(u8, a.name, b.name) == false) {
        return false;
    }
    if (std.mem.eql(u8, a.domain, b.domain) == false) {
        return false;
    }
    if (std.mem.eql(u8, a.path, b.path) == false) {
        return false;
    }
    if (a.source_secure != b.source_secure or a.source_port != b.source_port) {
        return false;
    }
    if (a.partitioned != b.partitioned) {
        return false;
    }
    const a_part = a.partition_site != null;
    const b_part = b.partition_site != null;
    if (a_part != b_part) return false;
    if (a_part and !std.mem.eql(u8, a.partition_site.?, b.partition_site.?)) return false;
    return true;
}

pub fn canonicalPort(url: [:0]const u8) u16 {
    const port_str = URL.getPort(url);
    if (port_str.len > 0) {
        return std.fmt.parseInt(u16, port_str, 10) catch defaultPortForUrl(url);
    }
    return defaultPortForUrl(url);
}

fn defaultPortForUrl(url: [:0]const u8) u16 {
    if (std.mem.startsWith(u8, url, "wss:") or std.mem.startsWith(u8, url, "https:")) return 443;
    if (std.mem.startsWith(u8, url, "ws:") or std.mem.startsWith(u8, url, "http:")) return 80;
    return if (URL.isSecureOrigin(url)) 443 else 80;
}

fn originBindingMatches(cookie: *const Cookie, target_url: [:0]const u8) bool {
    const target_secure = URL.isSecureOrigin(target_url);
    if (cookie.source_secure != target_secure) return false;
    // Insecure cookies remain port-bound (WPT origin-bound-cookies/port-bound).
    if (!cookie.source_secure) {
        return cookie.source_port == canonicalPort(target_url);
    }
    // Secure cookies (https/wss) share a jar across ports on the same host so
    // Set-Cookie on a WSS handshake is visible to the embedding HTTPS document.
    return true;
}

fn hostFromUrl(url: []const u8) []const u8 {
    const protocol_end = std.mem.indexOf(u8, url, "://") orelse return "";
    const authority = url[protocol_end + 3 ..];
    const end = std.mem.indexOfAny(u8, authority, "/?#") orelse authority.len;
    var host = authority[0..end];
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| {
        host = host[at + 1 ..];
    }
    if (host.len > 0 and host[0] == '[') {
        const bracket_end = std.mem.indexOfScalar(u8, host, ']') orelse return host;
        if (bracket_end + 1 < host.len and host[bracket_end + 1] == ':') {
            return host[0 .. bracket_end + 1];
        }
        return host[0 .. bracket_end + 1];
    }
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| {
        var all_digits = true;
        for (host[colon + 1 ..]) |c| {
            if (c < '0' or c > '9') {
                all_digits = false;
                break;
            }
        }
        if (all_digits and colon + 1 < host.len) {
            return host[0..colon];
        }
    }
    return host;
}

fn parseMaxAge(value: []const u8) !i64 {
    return std.fmt.parseInt(i64, value, 10) catch |err| switch (err) {
        error.Overflow => if (value.len > 0 and value[0] == '-') std.math.minInt(i64) else std.math.maxInt(i64),
        else => return err,
    };
}

/// Serialized schemeful site key: `{scheme}:{registrable-domain}`.
/// Map WebSocket schemes to HTTP cookie-site equivalents for schemeful checks.
fn cookieSiteScheme(url: []const u8) []const u8 {
    if (std.mem.startsWith(u8, url, "wss:")) return "https";
    if (std.mem.startsWith(u8, url, "ws:")) return "http";
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return "";
    return url[0..scheme_end];
}

fn schemefulSiteKey(allocator: Allocator, url: []const u8) ![]const u8 {
    const scheme = cookieSiteScheme(url);
    const host = hostFromUrl(url);
    const registrable = if (isLoopbackRelatedHost(host)) host else findSecondLevelDomain(host);
    return try std.fmt.allocPrint(allocator, "{s}:{s}", .{ scheme, registrable });
}

fn partitionSiteMatches(cookie: *const Cookie, top_level_url: ?[]const u8) bool {
    if (!cookie.partitioned) return true;
    const tl = top_level_url orelse return false;
    const site = cookie.partition_site orelse return false;
    var buf: [128]u8 = undefined;
    const tl_site = schemefulSiteKeyInto(tl, &buf) catch return false;
    return std.mem.eql(u8, site, tl_site);
}

fn schemefulSiteKeyInto(url: []const u8, buf: []u8) ![]const u8 {
    const scheme = cookieSiteScheme(url);
    const host = hostFromUrl(url);
    const registrable = if (isLoopbackRelatedHost(host)) host else findSecondLevelDomain(host);
    return try std.fmt.bufPrint(buf, "{s}:{s}", .{ scheme, registrable });
}

/// Schemeful same-site: scheme and registrable domain must match.
pub fn isSchemefulSameSite(url_a: []const u8, url_b: []const u8) bool {
    const host_a = hostFromUrl(url_a);
    const host_b = hostFromUrl(url_b);
    // WPT loopback aliases (localhost, 127.0.0.1, *.localhost) share a schemeful site.
    if (isLoopbackRelatedHost(host_a) and isLoopbackRelatedHost(host_b)) {
        return std.mem.eql(u8, cookieSiteScheme(url_a), cookieSiteScheme(url_b));
    }
    var buf_a: [128]u8 = undefined;
    var buf_b: [128]u8 = undefined;
    const site_a = schemefulSiteKeyInto(url_a, &buf_a) catch return false;
    const site_b = schemefulSiteKeyInto(url_b, &buf_b) catch return false;
    return std.mem.eql(u8, site_a, site_b);
}

/// True when `context_url` is a third-party context relative to `top_level_url`.
pub fn isThirdPartyContext(top_level_url: []const u8, context_url: []const u8) bool {
    return !isSchemefulSameSite(top_level_url, context_url);
}

fn isLoopbackHost(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "[::1]");
}

/// WPT local hosts: www1.localhost, 127.0.0.1, localhost share a cookie jar.
fn isLoopbackRelatedHost(host: []const u8) bool {
    return isLoopbackHost(host) or std.mem.endsWith(u8, host, ".localhost");
}

fn loopbackHostsShareCookies(cookie_domain: []const u8, request_host: []const u8) bool {
    // WPT treats numeric loopback (127.0.0.1 / [::1]) host-only cookies as
    // visible on *.localhost, but the hostname "localhost" itself stays
    // host-only exact-match (domain-attribute-missing must not leak to www1).
    if (std.mem.eql(u8, cookie_domain, "127.0.0.1") or std.mem.eql(u8, cookie_domain, "[::1]")) {
        return isLoopbackRelatedHost(request_host);
    }
    return false;
}

fn areSameSite(origin_url_: ?[:0]const u8, target_url: [:0]const u8) bool {
    const origin_url = origin_url_ orelse return true;
    return isSchemefulSameSite(origin_url, target_url);
}

fn findSecondLevelDomain(host: []const u8) []const u8 {
    var i = std.mem.lastIndexOfScalar(u8, host, '.') orelse return host;
    while (true) {
        i = std.mem.lastIndexOfScalar(u8, host[0..i], '.') orelse return host;
        const strip = i + 1;
        if (public_suffix_list(host[strip..]) == false) {
            return host[strip..];
        }
    }
}

pub const PreparedUri = struct {
    host: []const u8, // Percent encoded, lower case
    path: []const u8, // Percent encoded
    secure: bool, // True if scheme is https
};

fn trim(str: []const u8) []const u8 {
    return std.mem.trim(u8, str, &std.ascii.whitespace);
}

fn trimLeft(str: []const u8) []const u8 {
    return std.mem.trimStart(u8, str, &std.ascii.whitespace);
}

fn trimRight(str: []const u8) []const u8 {
    return std.mem.trimEnd(u8, str, &std.ascii.whitespace);
}

fn toLower(str: []u8) []u8 {
    for (str, 0..) |c, i| {
        str[i] = std.ascii.toLower(c);
    }
    return str;
}

const testing = @import("../../../testing/testing.zig");
const test_url = "http://kokoio.com/";
test "cookie: findSecondLevelDomain" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "", "" },
        .{ "com", "com" },
        .{ "kokoio.com", "kokoio.com" },
        .{ "kokoio.com", "test.kokoio.com" },
        .{ "kokoio.com", "first.test.kokoio.com" },
        .{ "www.gov.uk", "www.gov.uk" },
        .{ "stats.gov.uk", "www.stats.gov.uk" },
        .{ "api.gov.uk", "api.gov.uk" },
        .{ "dev.api.gov.uk", "dev.api.gov.uk" },
        .{ "dev.api.gov.uk", "1.dev.api.gov.uk" },
    };
    for (cases) |c| {
        try testing.expectEqual(c.@"0", findSecondLevelDomain(c.@"1"));
    }
}

test "Jar: add" {
    const expectCookies = struct {
        fn expect(expected: []const struct { []const u8, []const u8 }, jar: Jar) !void {
            try testing.expectEqual(expected.len, jar.cookies.items.len);
            LOOP: for (expected) |e| {
                for (jar.cookies.items) |c| {
                    if (std.mem.eql(u8, e.@"0", c.name) and std.mem.eql(u8, e.@"1", c.value)) {
                        continue :LOOP;
                    }
                }
                std.debug.print("Cookie ({s}={s}) not found", .{ e.@"0", e.@"1" });
                return error.CookieNotFound;
            }
        }
    }.expect;

    const now: i64 = @intCast(datetime.timestamp(.clock));

    var jar = Jar.init(testing.allocator);
    defer jar.deinit();
    try expectCookies(&.{}, jar);

    try jar.add(try Cookie.parse(testing.allocator, test_url, "over=9000;Max-Age=0"), now, true);
    try expectCookies(&.{}, jar);

    try jar.add(try Cookie.parse(testing.allocator, test_url, "over=9000"), now, true);
    try expectCookies(&.{.{ "over", "9000" }}, jar);

    try jar.add(try Cookie.parse(testing.allocator, test_url, "over=9000!!"), now, true);
    try expectCookies(&.{.{ "over", "9000!!" }}, jar);

    try jar.add(try Cookie.parse(testing.allocator, test_url, "spice=flow"), now, true);
    try expectCookies(&.{ .{ "over", "9000!!" }, .{ "spice", "flow" } }, jar);

    try jar.add(try Cookie.parse(testing.allocator, test_url, "spice=flows;Path=/"), now, true);
    try expectCookies(&.{ .{ "over", "9000!!" }, .{ "spice", "flows" } }, jar);

    try jar.add(try Cookie.parse(testing.allocator, test_url, "over=9001;Path=/other"), now, true);
    try expectCookies(&.{ .{ "over", "9000!!" }, .{ "spice", "flows" }, .{ "over", "9001" } }, jar);

    try jar.add(try Cookie.parse(testing.allocator, test_url, "over=9002;Path=/;Domain=kokoio.com"), now, true);
    try expectCookies(&.{ .{ "over", "9000!!" }, .{ "spice", "flows" }, .{ "over", "9001" }, .{ "over", "9002" } }, jar);

    try jar.add(try Cookie.parse(testing.allocator, test_url, "over=x;Path=/other;Max-Age=-200"), now, true);
    try expectCookies(&.{ .{ "over", "9000!!" }, .{ "spice", "flows" }, .{ "over", "9002" } }, jar);
}

test "Jar: non-HTTP add must not replace or duplicate an HttpOnly cookie" {
    const now: i64 = @intCast(datetime.timestamp(.clock));

    var jar = Jar.init(testing.allocator);
    defer jar.deinit();

    try jar.add(try Cookie.parse(testing.allocator, test_url, "session=REAL;Path=/;HttpOnly"), now, true);
    try testing.expectEqual(@as(usize, 1), jar.cookies.items.len);

    try jar.add(try Cookie.parse(testing.allocator, test_url, "session=ATTACKER;Path=/"), now, false);
    try testing.expectEqual(@as(usize, 1), jar.cookies.items.len);
    try testing.expectEqual("REAL", jar.cookies.items[0].value);
    try testing.expectEqual(true, jar.cookies.items[0].http_only);

    try jar.add(try Cookie.parse(testing.allocator, test_url, "session=REFRESHED;Path=/;HttpOnly"), now, true);
    try testing.expectEqual(@as(usize, 1), jar.cookies.items.len);
    try testing.expectEqual("REFRESHED", jar.cookies.items[0].value);
}

test "Jar: add limit" {
    var jar = Jar.init(testing.allocator);
    defer jar.deinit();

    const now: i64 = @intCast(datetime.timestamp(.clock));

    // add a too big cookie value.
    try testing.expectError(error.CookieSizeExceeded, jar.add(.{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .name = "v",
        .domain = "kokoio.com",
        .path = "/",
        .expires = null,
        .value = "v" ** 4096 ++ "v",
    }, now, true));

    // generate unique names.
    const names = comptime blk: {
        @setEvalBranchQuota(max_jar_size);
        var result: [max_jar_size][]const u8 = undefined;
        for (0..max_jar_size) |i| {
            result[i] = "v" ** i;
        }
        break :blk result;
    };

    // test the max number limit
    var i: usize = 0;
    while (i < max_jar_size) : (i += 1) {
        const c = Cookie{
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
            .name = names[i],
            .domain = "kokoio.com",
            .path = "/",
            .expires = null,
            .value = "v",
        };

        try jar.add(c, now, true);
    }

    try testing.expectError(error.CookieJarQuotaExceeded, jar.add(.{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .name = "last",
        .domain = "kokoio.com",
        .path = "/",
        .expires = null,
        .value = "v",
    }, now, true));
}

test "Jar: replacement succeeds at jar capacity" {
    var jar = Jar.init(testing.allocator);
    defer jar.deinit();

    const now: i64 = @intCast(datetime.timestamp(.clock));
    var names: [max_jar_size][8]u8 = undefined;
    var lines: [max_jar_size][16]u8 = undefined;
    for (0..max_jar_size) |i| {
        const name = try std.fmt.bufPrint(&names[i], "c{d}", .{i});
        const line = try std.fmt.bufPrint(&lines[i], "{s}=old", .{name});
        try jar.add(try Cookie.parse(testing.allocator, test_url, line), now, true);
    }

    try jar.add(try Cookie.parse(testing.allocator, test_url, "c0=new"), now, true);
    try testing.expectEqual(@as(usize, max_jar_size), jar.cookies.items.len);
    try testing.expectEqual("new", jar.cookies.items[0].value);
}

test "Jar: HTTP and script cookies commit immediately for all names" {
    const now: i64 = @intCast(datetime.timestamp(.clock));
    var jar = Jar.init(testing.allocator);
    defer jar.deinit();

    jar.beginDocumentNavigation(); // generation 1
    try jar.add(try Cookie.parse(testing.allocator, test_url, "AEC=1"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, test_url, "session_state=value"), now, false);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try jar.forRequest(test_url, &buf.writer, .{
        .is_http = true,
        .is_navigation = true,
        .nav_generation = jar.document_nav_generation,
    });
    try testing.expectEqualStrings("AEC=1; session_state=value", buf.written());
}

test "Jar: forRequest" {
    const expectCookies = struct {
        fn expect(expected: []const u8, jar: *Jar, target_url: [:0]const u8, opts: Jar.LookupOpts) !void {
            var arr: std.Io.Writer.Allocating = .init(testing.allocator);
            defer arr.deinit();
            try jar.forRequest(target_url, &arr.writer, opts);
            try testing.expectEqual(expected, arr.written());
        }
    }.expect;

    const now: i64 = @intCast(datetime.timestamp(.clock));

    var jar = Jar.init(testing.allocator);
    defer jar.deinit();

    const url2 = "http://test.kokoio.com/";

    {
        // test with no cookies
        try expectCookies("", &jar, test_url, .{ .is_http = true });
    }

    try jar.add(try Cookie.parse(testing.allocator, test_url, "global1=1"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, test_url, "global2=2;Max-Age=30;domain=kokoio.com"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, test_url, "path1=3;Path=/about"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, test_url, "path2=4;Path=/docs/"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, "https://kokoio.com/", "secure=5;Secure"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, "https://kokoio.com/", "sitenone=6;SameSite=None;Path=/x/;Secure"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, test_url, "sitelax=7;SameSite=Lax;Path=/x/"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, test_url, "sitestrict=8;SameSite=Strict;Path=/x/"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, url2, "domain1=9;domain=test.kokoio.com"), now, true);

    // nothing fancy here
    try expectCookies("global1=1; global2=2", &jar, test_url, .{ .is_http = true });
    try expectCookies("global1=1; global2=2", &jar, test_url, .{ .origin_url = test_url, .is_navigation = false, .is_http = true });

    // We have a cookie where Domain=kokoio.com
    // This should _not_ match xyxkokoio.com
    try expectCookies("", &jar, "http://anothersitekokoio.com/", .{
        .origin_url = test_url,
        .is_http = true,
    });

    // matching path without trailing /
    try expectCookies("path1=3; global1=1; global2=2", &jar, "http://kokoio.com/about", .{
        .origin_url = test_url,
        .is_http = true,
    });

    // incomplete prefix path
    try expectCookies("global1=1; global2=2", &jar, "http://kokoio.com/abou", .{
        .origin_url = test_url,
        .is_http = true,
    });

    // path doesn't match
    try expectCookies("global1=1; global2=2", &jar, "http://kokoio.com/aboutus", .{
        .origin_url = test_url,
        .is_http = true,
    });

    // path doesn't match cookie directory
    try expectCookies("global1=1; global2=2", &jar, "http://kokoio.com/docs", .{
        .origin_url = test_url,
        .is_http = true,
    });

    // exact directory match
    try expectCookies("path2=4; global1=1; global2=2", &jar, "http://kokoio.com/docs/", .{
        .origin_url = test_url,
        .is_http = true,
    });

    // sub directory match
    try expectCookies("path2=4; global1=1; global2=2", &jar, "http://kokoio.com/docs/more", .{
        .origin_url = test_url,
        .is_http = true,
    });

    // secure
    try expectCookies("secure=5", &jar, "https://kokoio.com/", .{
        .origin_url = test_url,
        .is_http = true,
    });

    // navigational cross domain, secure
    try expectCookies("sitenone=6; secure=5", &jar, "https://kokoio.com/x/", .{
        .origin_url = "https://example.com/",
        .is_http = true,
    });

    // navigational cross domain, insecure
    try expectCookies("sitelax=7; global1=1; global2=2", &jar, "http://kokoio.com/x/", .{
        .origin_url = "https://example.com/",
        .is_http = true,
    });

    // non-navigational cross domain, insecure
    try expectCookies("", &jar, "http://kokoio.com/x/", .{
        .origin_url = "https://example.com/",
        .is_http = true,
        .is_navigation = false,
    });

    // non-navigational cross domain, secure
    try expectCookies("sitenone=6", &jar, "https://kokoio.com/x/", .{
        .origin_url = "https://example.com/",
        .is_http = true,
        .is_navigation = false,
    });

    // non-navigational cross-scheme (schemeful: http vs https are cross-site)
    try expectCookies("", &jar, "http://kokoio.com/x/", .{
        .origin_url = "https://kokoio.com/",
        .is_http = true,
        .is_navigation = false,
    });

    // exact domain match + suffix
    try expectCookies("global2=2; domain1=9", &jar, "http://test.kokoio.com/", .{
        .origin_url = test_url,
        .is_http = true,
    });

    // domain suffix match + suffix
    try expectCookies("global2=2; domain1=9", &jar, "http://1.test.kokoio.com/", .{
        .origin_url = test_url,
        .is_http = true,
    });

    // non-matching domain
    try expectCookies("global2=2", &jar, "http://other.kokoio.com/", .{
        .origin_url = test_url,
        .is_http = true,
    });

    const l = jar.cookies.items.len;
    try expectCookies("global1=1", &jar, test_url, .{
        .request_time = now + 100,
        .origin_url = test_url,
        .is_http = true,
    });
    try testing.expectEqual(l - 1, jar.cookies.items.len);

    // If you add more cases after this point, note that the above test removes
    // the 'global2' cookie
}

test "Jar: document.cookie orders by path length then creation time" {
    const now: i64 = @intCast(datetime.timestamp(.clock));
    var jar = Jar.init(testing.allocator);
    defer jar.deinit();

    const target = "http://localhost:8000/cookies/attributes/resources/path/one.html";
    try jar.add(try Cookie.parse(testing.allocator, target, "testZ=4; path=/cookies"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, target, "testB=4; path=/cookies/attributes/resources/path"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, target, "testA=4; path=/cookies"), now, true);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try jar.forRequest(target, &buf.writer, .{
        .is_http = false,
        .is_navigation = true,
        .origin_url = target,
    });
    try testing.expectEqualStrings("testB=4; testZ=4; testA=4", buf.written());
}

test "Jar: loopback aliases share same-site for cookie attachment" {
    const now: i64 = @intCast(datetime.timestamp(.clock));
    var jar = Jar.init(testing.allocator);
    defer jar.deinit();

    try jar.add(try Cookie.parse(testing.allocator, "http://127.0.0.1:8000/", "COOKIE_NAME=1;Path=/workers/modules/"), now, true);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try jar.forRequest("http://www1.localhost:8000/workers/modules/resources/export-credentials.py", &buf.writer, .{
        .origin_url = "http://localhost:8000/",
        .is_http = true,
        .is_navigation = false,
    });
    try testing.expectEqualStrings("COOKIE_NAME=1", buf.written());
}

test "Jar: host-only localhost cookie does not leak to subdomains" {
    const now: i64 = @intCast(datetime.timestamp(.clock));
    var jar = Jar.init(testing.allocator);
    defer jar.deinit();

    try jar.add(try Cookie.parse(testing.allocator, "https://localhost:8443/", "domain-attribute-missing=b;Path=/"), now, true);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try jar.forRequest("https://www1.localhost:8443/cookies/resources/list.py", &buf.writer, .{
        .origin_url = "https://localhost:8443/",
        .is_http = true,
        .is_navigation = false,
    });
    try testing.expectEqualStrings("", buf.written());
}

test "Cookie: parse key=value" {
    try expectError(error.Empty, null, "");
    try expectError(error.InvalidByteSequence, null, &.{ 'a', 30, '=', 'b' });
    try expectError(error.InvalidByteSequence, null, &.{ 'a', 127, '=', 'b' });
    try expectError(error.InvalidByteSequence, null, &.{ 'a', '=', 'b', 20 });
    // UTF-8 bytes above 0x7F are allowed in names and values (WPT encoding/charset).
    try expectAttribute(.{ .name = "a", .value = "b\u{0080}" }, null, "a=b\u{0080}");
    try expectAttribute(.{ .name = "тест", .value = "2" }, null, "тест=2");
    try expectAttribute(.{ .name = "test", .value = "1春节回家路·春运完全手册" }, null, "test=1春节回家路·春运完全手册");
    try expectAttribute(.{ .name = "春节回", .value = "4家路·春运完全手册" }, null, "春节回=4家路·春运完全手册");

    // Tab (0x09) is allowed in name and value, matching browser/WPT behavior.
    try expectAttribute(.{ .name = "a\tb", .value = "c" }, null, "a\tb=c");
    try expectAttribute(.{ .name = "a", .value = "b\tc" }, null, "a=b\tc");
    // Other control characters remain rejected in name/value.
    try expectError(error.InvalidByteSequence, null, "a\nb=c");
    try expectError(error.InvalidByteSequence, null, "a\rb=c");
    try expectError(error.InvalidByteSequence, null, &.{ 'a', '=', 'b', 0 });

    // Nameless cookies whose value contains '='.
    try expectAttribute(.{ .name = "", .value = "test=2" }, null, "=test=2");
    try expectAttribute(.{ .name = "", .value = "==test=2b" }, null, "===test=2b");
    try expectAttribute(.{ .name = "", .value = "test2c" }, null, "=test2c");

    // Empty name and empty value is ignored.
    try expectError(error.InvalidNameValue, null, "=");

    // Nameless cookies whose value begins with __Host- or __Secure-
    // (case-insensitive) are rejected so they can't impersonate prefixed cookies.
    try expectError(error.InvalidNameValue, null, "=__Host-abc=1");
    try expectError(error.InvalidNameValue, null, "=__Secure-abc=1");
    try expectError(error.InvalidNameValue, null, "=__HoSt-abc");
    try expectError(error.InvalidNameValue, null, "__Secure-abc");

    // __Host- cookie-name-prefix rules:
    //   - must be Secure
    //   - must be set from an https origin
    //   - must not have a Domain attribute
    //   - must have Path=/
    try expectAttribute(.{ .name = "__Host-abc", .value = "1" }, "https://kokoio.com/", "__Host-abc=1; Secure; Path=/");
    try expectAttribute(.{ .name = "__HoSt-abc", .value = "1" }, "https://kokoio.com/", "__HoSt-abc=1; Secure; Path=/");
    try expectError(error.InvalidPrefixedCookie, "https://kokoio.com/", "__Host-abc=1; Path=/");
    try expectError(error.InvalidPrefixedCookie, null, "__Host-abc=1; Secure; Path=/");
    try expectError(error.InvalidPrefixedCookie, "https://kokoio.com/", "__Host-abc=1; Secure");
    try expectError(error.InvalidPrefixedCookie, "https://kokoio.com/", "__Host-abc=1; Secure; Path=/foo");
    try expectError(error.InvalidPrefixedCookie, "https://kokoio.com/", "__Host-abc=1; Secure; Path=/; Domain=kokoio.com");

    // __Secure- cookie-name-prefix rules: must be Secure and from https.
    try expectAttribute(.{ .name = "__Secure-abc", .value = "1" }, "https://kokoio.com/", "__Secure-abc=1; Secure");
    try expectAttribute(.{ .name = "__SeCuRe-abc", .value = "1" }, "https://kokoio.com/", "__SeCuRe-abc=1; Secure; Domain=kokoio.com");
    try expectError(error.InvalidPrefixedCookie, "https://kokoio.com/", "__Secure-abc=1");
    try expectError(error.InvalidPrefixedCookie, null, "__Secure-abc=1; Secure");

    // Empty Domain= is treated as no Domain and accepted on __Host-.
    try expectAttribute(.{ .name = "__Host-abc", .value = "1" }, "https://kokoio.com/", "__Host-abc=1; Secure; Path=/; Domain=");

    // __Host- with additional unrelated attributes remains valid.
    try expectAttribute(.{ .name = "__Host-abc", .value = "1" }, "https://kokoio.com/", "__Host-abc=1; Secure; Path=/; Max-Age=60; HttpOnly");

    // __Host-Http-: Secure, Path=/, host-only, HttpOnly.
    try expectAttribute(.{ .name = "__Host-Http-abc", .value = "1", .http_only = true }, "https://kokoio.com/", "__Host-Http-abc=1; Secure; Path=/; HttpOnly");
    try expectError(error.InvalidPrefixedCookie, "https://kokoio.com/", "__Host-Http-abc=1; Secure; Path=/");
    try expectError(error.InvalidPrefixedCookie, "https://kokoio.com/", "__Host-Http-abc=1; Secure; Path=/cookies/; HttpOnly");
    try expectError(error.InvalidPrefixedCookie, "https://kokoio.com/", "__Host-Http-abc=1; Secure; Path=/; HttpOnly; Domain=kokoio.com");

    // __Http-: Secure + HttpOnly (Path unrestricted).
    try expectAttribute(.{ .name = "__Http-abc", .value = "1", .http_only = true }, "https://kokoio.com/", "__Http-abc=1; Secure; Path=/; HttpOnly");
    try expectAttribute(.{ .name = "__Http-abc", .value = "1", .http_only = true, .path = "/cookies/" }, "https://kokoio.com/", "__Http-abc=1; Secure; Path=/cookies/; HttpOnly");
    try expectError(error.InvalidPrefixedCookie, "https://kokoio.com/", "__Http-abc=1; Secure; Path=/");
    try expectError(error.InvalidPrefixedCookie, "https://kokoio.com/", "__Http-abc=1; Path=/; HttpOnly");

    // Near-misses are not subject to the prefix rules.
    try expectAttribute(.{ .name = "__Host", .value = "1" }, null, "__Host=1");
    try expectAttribute(.{ .name = "_Host-abc", .value = "1" }, null, "_Host-abc=1");
    try expectAttribute(.{ .name = "__Hos-abc", .value = "1" }, null, "__Hos-abc=1");
    try expectAttribute(.{ .name = "__Secure", .value = "1" }, null, "__Secure=1");

    try expectAttribute(.{ .name = "", .value = "a" }, null, "a");
    try expectAttribute(.{ .name = "", .value = "a" }, null, "a;");
    try expectAttribute(.{ .name = "", .value = "a b" }, null, "a b");
    try expectAttribute(.{ .name = "a b", .value = "b" }, null, "a b=b");
    try expectAttribute(.{ .name = "a,", .value = "b" }, null, "a,=b");
    try expectAttribute(.{ .name = ":a>", .value = "b>><" }, null, ":a>=b>><");

    try expectAttribute(.{ .name = "abc", .value = "" }, null, "abc=");
    try expectAttribute(.{ .name = "abc", .value = "" }, null, "abc=;");

    // Values may contain commas, semicolons (before first ';'), and '='.
    try expectAttribute(.{ .name = "test", .value = "1, baz=qux" }, null, "test=1, baz=qux");
    try expectAttribute(.{ .name = "test24", .value = "=" }, null, "test24==");
    try expectAttribute(.{ .name = "test", .value = "25=25" }, null, "test=25=25");
    try expectAttribute(.{ .name = "test", .value = "26=26=26" }, null, "test=26=26=26");

    try expectAttribute(.{ .name = "a", .value = "b" }, null, "a=b");
    try expectAttribute(.{ .name = "a", .value = "b" }, null, "a=b;");

    try expectAttribute(.{ .name = "abc", .value = "fe f" }, null, "abc=  fe f");
    try expectAttribute(.{ .name = "abc", .value = "fe f" }, null, "abc=  fe f  ");
    try expectAttribute(.{ .name = "abc", .value = "fe f" }, null, "abc=  fe f;");
    try expectAttribute(.{ .name = "abc", .value = "fe f" }, null, "abc=  fe f   ;");
    try expectAttribute(.{ .name = "abc", .value = "\"  fe f\"" }, null, "abc=\"  fe f\"");
    try expectAttribute(.{ .name = "abc", .value = "\"  fe f   \"" }, null, "abc=\"  fe f   \"");
    try expectAttribute(.{ .name = "ab4344c", .value = "1ads23" }, null, "  ab4344c=1ads23  ");

    try expectAttribute(.{ .name = "ab4344c", .value = "1ads23" }, null, "  ab4344c  =  1ads23  ;");
}

test "Cookie: parse path" {
    try expectAttribute(.{ .path = "/" }, "http://a/", "b");
    try expectAttribute(.{ .path = "/" }, "http://a/", "b;path");
    try expectAttribute(.{ .path = "/" }, "http://a/", "b;Path=");
    try expectAttribute(.{ .path = "/" }, "http://a/", "b;Path=;");
    try expectAttribute(.{ .path = "/" }, "http://a/", "b; Path=other");
    try expectAttribute(.{ .path = "/" }, "http://a/23", "b; path=other ");

    try expectAttribute(.{ .path = "/" }, "http://a/abc", "b");
    try expectAttribute(.{ .path = "/abc" }, "http://a/abc/", "b");
    try expectAttribute(.{ .path = "/abc" }, "http://a/abc/123", "b");
    try expectAttribute(.{ .path = "/abc/123" }, "http://a/abc/123/", "b");

    try expectAttribute(.{ .path = "/a" }, "http://a/", "b;Path=/a");
    try expectAttribute(.{ .path = "/aa" }, "http://a/", "b;path=/aa;");
    try expectAttribute(.{ .path = "/aabc/" }, "http://a/", "b;  path=  /aabc/ ;");

    try expectAttribute(.{ .path = "/bbb/" }, "http://a/", "b;  path=/a/; path=/bbb/");
    try expectAttribute(.{ .path = "/cc" }, "http://a/", "b;  path=/a/; path=/bbb/; path = /cc");
}

test "Cookie: parse secure" {
    try expectAttribute(.{ .secure = false }, null, "b");
    try expectAttribute(.{ .secure = false }, null, "b;secured");
    try expectAttribute(.{ .secure = false }, null, "b;security");
    try expectAttribute(.{ .secure = false }, null, "b;SecureX");
    try expectError(error.InsecureSecureCookie, null, "b; Secure");
    try expectAttribute(.{ .secure = true }, "https://kokoio.com/", "b; Secure");
    try expectAttribute(.{ .secure = true }, "https://kokoio.com/", "b; Secure  ");
    try expectAttribute(.{ .secure = true }, "https://kokoio.com/", "b; Secure=on  ");
    try expectAttribute(.{ .secure = true }, "https://kokoio.com/", "b; Secure=Off  ");
    try expectAttribute(.{ .secure = true }, "https://kokoio.com/", "b; secure=Off  ");
    try expectAttribute(.{ .secure = true }, "https://kokoio.com/", "b; seCUre=Off  ");
}

test "Cookie: parse HttpOnly" {
    try expectAttribute(.{ .http_only = false }, null, "b");
    try expectAttribute(.{ .http_only = false }, null, "b;HttpOnly0");
    try expectAttribute(.{ .http_only = false }, null, "b;H ttpOnly");
    try expectAttribute(.{ .http_only = true }, null, "b; HttpOnly");
    try expectAttribute(.{ .http_only = true }, null, "b; Httponly  ");
    try expectAttribute(.{ .http_only = true }, null, "b; Httponly=on  ");
    try expectAttribute(.{ .http_only = true }, null, "b; httpOnly=Off  ");
    try expectAttribute(.{ .http_only = true }, null, "b; httpOnly=Off  ");
    try expectAttribute(.{ .http_only = true }, null, "b;    HttpOnly=Off  ");
}

test "Cookie: parse SameSite" {
    try expectAttribute(.{ .same_site = .lax }, null, "b;samesite");
    try expectAttribute(.{ .same_site = .lax }, null, "b;samesite=lax");
    try expectAttribute(.{ .same_site = .lax }, null, "b;  SameSite=Lax  ");
    try expectAttribute(.{ .same_site = .lax }, null, "b;  SameSite=Other  ");
    try expectAttribute(.{ .same_site = .lax }, null, "b;  SameSite=Nope  ");

    // SameSite=none is only valid when Secure is set. The whole cookie is
    // rejected otherwise
    try expectError(error.InsecureSameSite, null, "b;samesite=none");
    try expectError(error.InsecureSameSite, null, "b;SameSite=None");
    try expectAttribute(.{ .same_site = .none }, "https://kokoio.com/", "b;  samesite=none; secure  ");
    try expectAttribute(.{ .same_site = .none }, "https://kokoio.com/", "b;  SameSite=None  ; SECURE");
    try expectAttribute(.{ .same_site = .none }, "https://kokoio.com/", "b;Secure;  SameSite=None");
    try expectAttribute(.{ .same_site = .none }, "https://kokoio.com/", "b; SameSite=None; Secure");

    try expectAttribute(.{ .same_site = .strict }, null, "b;  samesite=Strict  ");
    try expectAttribute(.{ .same_site = .strict }, null, "b;  SameSite=  STRICT  ");
    try expectAttribute(.{ .same_site = .strict }, null, "b;  SameSITE=strict;");
    try expectAttribute(.{ .same_site = .strict }, null, "b; SameSite=Strict");

    try expectAttribute(.{ .same_site = .strict }, null, "b; SameSite=None; SameSite=lax; SameSite=Strict");
}

test "Cookie: attribute section CTL rejects cookie" {
    const host = "kokoio.com";
    const path = "/cookies/attributes";
    // Non-tab CTL in attribute section rejects the line (WPT attributes-ctl).
    try expectError(error.InvalidByteSequence, null, "test=t; Domain=bad\x01.co; Domain=" ++ host);
    try expectError(error.InvalidByteSequence, null, "test=t; Path=/bad\x7f; Path=" ++ path);
    try expectError(error.InvalidByteSequence, null, "test=t; Max-Age=10\x0100; Max-Age=1000");
    try expectError(error.InvalidByteSequence, null, "test=t; Sec\x01ure");
    try expectError(error.InvalidByteSequence, null, "test=t; Secure\x7f");
    // Tab in attribute values is allowed.
    try expectAttribute(.{ .name = "test", .value = "t", .path = path }, null, "test=t;\tpath\t=\t" ++ path);
}

test "Cookie: parse max-age" {
    const now: i64 = @intCast(datetime.timestamp(.clock));
    try expectAttribute(.{ .expires = null }, null, "b;max-age");
    try expectAttribute(.{ .expires = null }, null, "b;max-age=abc");
    try expectAttribute(.{ .expires = null }, null, "b;max-age=13.22");
    try expectAttribute(.{ .expires = null }, null, "b;max-age=13abc");

    try expectAttribute(.{ .expires = now + 13 }, null, "b;max-age=13");
    try expectAttribute(.{ .expires = now - 22 }, null, "b;max-age=-22");
    try expectAttribute(.{ .expires = now + 4294967296 }, null, "b;max-age=4294967296");
    try expectAttribute(.{ .expires = now - 4294967296 }, null, "b;Max-Age= -4294967296");
    try expectAttribute(.{ .expires = now }, null, "b; Max-Age=0");
    try expectAttribute(.{ .expires = now + 500 }, null, "b; Max-Age = 500  ; Max-Age=invalid");
    try expectAttribute(.{ .expires = now + 1000 }, null, "b;max-age=600;max-age=0;max-age = 1000");
}

test "Cookie: parse expires" {
    try expectAttribute(.{ .expires = null }, null, "b;expires=");
    try expectAttribute(.{ .expires = null }, null, "b;expires=abc");
    try expectAttribute(.{ .expires = null }, null, "b;expires=13.22");
    try expectAttribute(.{ .expires = null }, null, "b;expires=33");

    try expectAttribute(.{ .expires = 1918798080 }, null, "b;expires=Wed, 21 Oct 2030 07:28:00 GMT");
    try expectAttribute(.{ .expires = 1784275395 }, null, "b;expires=Fri, 17-Jul-2026 08:03:15 GMT");
    // max-age has priority over expires
    try expectAttribute(.{ .expires = datetime.timestamp(.clock) + 10 }, null, "b;Max-Age=10; expires=Wed, 21 Oct 2030 07:28:00 GMT");
}

test "Cookie: parse all" {
    try expectCookie(.{
        .name = "user-id",
        .value = "9000",
        .path = "/cms",
        .domain = "kokoio.com",
    }, "https://kokoio.com/cms/users", "user-id=9000");

    try expectCookie(.{
        .name = "user-id",
        .value = "9000",
        .path = "/",
        .http_only = true,
        .secure = true,
        .domain = ".kokoio.com",
        .expires = @floatFromInt(datetime.timestamp(.clock) + 30),
    }, "https://kokoio.com/cms/users", "user-id=9000; HttpOnly; Max-Age=30; Secure; path=/; Domain=kokoio.com");

    try expectCookie(.{
        .name = "app_session",
        .value = "123",
        .path = "/",
        .http_only = true,
        .secure = false,
        .domain = ".localhost",
        .same_site = .lax,
        .expires = @floatFromInt(datetime.timestamp(.clock) + 7200),
    }, "http://localhost:8000/login", "app_session=123; Max-Age=7200; path=/; domain=localhost; httponly; samesite=lax");
}

test "Cookie: parse domain" {
    try expectAttribute(.{ .domain = "kokoio.com" }, "http://kokoio.com/", "b");
    try expectAttribute(.{ .domain = "dev.kokoio.com" }, "http://dev.kokoio.com/", "b");
    try expectAttribute(.{ .domain = ".kokoio.com" }, "http://kokoio.com/", "b;domain=kokoio.com");
    try expectAttribute(.{ .domain = ".kokoio.com" }, "http://kokoio.com/", "b;domain=.kokoio.com");
    try expectAttribute(.{ .domain = ".dev.kokoio.com" }, "http://dev.kokoio.com/", "b;domain=dev.kokoio.com");
    try expectAttribute(.{ .domain = ".kokoio.com" }, "http://dev.kokoio.com/", "b;domain=kokoio.com");
    try expectAttribute(.{ .domain = ".kokoio.com" }, "http://dev.kokoio.com/", "b;domain=.kokoio.com");
    try expectAttribute(.{ .domain = ".localhost" }, "http://localhost/", "b;domain=localhost");
    try expectAttribute(.{ .domain = ".localhost" }, "http://localhost/", "b;domain=.localhost");

    try expectError(error.InvalidDomain, "http://kokoio.com/", "b;domain=io");
    try expectError(error.InvalidDomain, "http://kokoio.com/", "b;domain=.io");
    try expectError(error.InvalidDomain, "http://kokoio.com/", "b;domain=other.kokoio.com");
    try expectError(error.InvalidDomain, "http://kokoio.com/", "b;domain=other.koko.com");
    try expectError(error.InvalidDomain, "http://kokoio.com/", "b;domain=other.example.com");

    try expectError(error.InvalidDomain, "http://attackerexample.com/", "b;domain=example.com");
    try expectError(error.InvalidDomain, "http://attackerexample.com/", "b;domain=.example.com");
    try expectError(error.InvalidDomain, "http://xyzkokoio.com/", "b;domain=kokoio.com");
    try expectError(error.InvalidDomain, "http://notlocalhost/", "b;domain=localhost");

    // Public suffixes should be rejected (test PSL entries: "gov.uk", "api.gov.uk")
    try expectError(error.InvalidDomain, "http://example.gov.uk/", "b;domain=gov.uk");
    try expectError(error.InvalidDomain, "http://example.gov.uk/", "b;domain=.gov.uk");
    try expectError(error.InvalidDomain, "http://test.api.gov.uk/", "b;domain=api.gov.uk");

    // Subdomains of public suffixes should still be accepted
    try expectAttribute(.{ .domain = ".example.gov.uk" }, "http://example.gov.uk/", "b;domain=example.gov.uk");
    try expectAttribute(.{ .domain = ".example.gov.uk" }, "http://sub.example.gov.uk/", "b;domain=example.gov.uk");
}

test "Cookie: parse limit" {
    try expectError(error.CookieSizeExceeded, "http://kokoio.com/", "v" ** 4097 ++ ";domain=kokoio.com");
    try expectError(error.CookieSizeExceeded, "http://kokoio.com/", "n" ** 4097 ++ "=1;domain=kokoio.com");
    try expectError(error.CookieSizeExceeded, "http://kokoio.com/", "n=1" ++ "v" ** 4096 ++ ";domain=kokoio.com");
    try expectError(error.CookieSizeExceeded, "http://kokoio.com/", "v" ** 4097 ++ ";domain=kokoio.com");
    // WPT /cookies/size/name-and-value.html
    try expectCookie(.{ .name = "t" ** 2048, .value = "1" ** 2048, .path = "/", .domain = "kokoio.com" }, "http://kokoio.com/", "t" ** 2048 ++ "=" ++ "1" ** 2048);
    try expectError(error.CookieSizeExceeded, "http://kokoio.com/", "t" ** 4097 ++ "=1");
    try expectCookie(.{ .name = "t" ** 4096, .value = "", .path = "/", .domain = "kokoio.com" }, "http://kokoio.com/", "t" ** 4096 ++ "=");
    try expectError(error.CookieSizeExceeded, "http://kokoio.com/", "t" ** 4097 ++ "=");
    try expectCookie(.{ .name = "t", .value = "1" ** 4095, .path = "/", .domain = "kokoio.com" }, "http://kokoio.com/", "t=" ++ "1" ** 4095);
    try expectError(error.CookieSizeExceeded, "http://kokoio.com/", "t=" ++ "1" ** 4096);
    try expectError(error.CookieSizeExceeded, "http://kokoio.com/", "t" ** 4096 ++ "=1");
    try expectCookie(.{ .name = "", .value = "1" ** 4096, .path = "/", .domain = "kokoio.com" }, "http://kokoio.com/", "=" ++ "1" ** 4096);
    try expectError(error.CookieSizeExceeded, "http://kokoio.com/", "=" ++ "1" ** 4097);

    const large_name_value = "t" ** 2048 ++ "=" ++ "1" ** 2048;
    const large_attrs = large_name_value ++ "; domain=" ++ "a" ** 1020 ++ ".com; domain=" ++ "a" ** 1020 ++ ".com; domain=" ++ "a" ** 1020 ++ ".com; domain=" ++ "a" ** 1020 ++ ".com; domain=kokoio.com";
    try expectCookie(.{
        .name = "t" ** 2048,
        .value = "1" ** 2048,
        .path = "/",
        .domain = ".kokoio.com",
    }, "http://kokoio.com/", large_attrs);

    // WPT /cookies/value/value.html combined name+value budget.
    try expectAttribute(.{ .name = "test", .value = "11" ++ "a" ** 4090 }, null, "test=11" ++ "a" ** 4090);
    try expectError(error.CookieSizeExceeded, null, "test=12" ++ "a" ** 4091);
}

test "Cookie: sanitizeHttpSetCookie" {
    const alloc = testing.allocator;

    const lf = try sanitizeHttpSetCookie(alloc, "test=13\nZYX");
    defer if (lf.owned) alloc.free(lf.slice);
    try testing.expectEqualStrings("test=13", lf.slice);
    try testing.expect(!lf.owned);

    const nul_name = try sanitizeHttpSetCookie(alloc, "test0\x00name=0");
    defer if (nul_name.owned) alloc.free(nul_name.slice);
    try testing.expectEqualStrings("test0 name=0", nul_name.slice);
    try testing.expect(nul_name.owned);

    const lf_name = try sanitizeHttpSetCookie(alloc, "test10\nname=10");
    defer if (lf_name.owned) alloc.free(lf_name.slice);
    try testing.expectEqualStrings("test10 name=10", lf_name.slice);
    try testing.expect(lf_name.owned);

    const cr_value = try sanitizeHttpSetCookie(alloc, "test=1\r2");
    defer if (cr_value.owned) alloc.free(cr_value.slice);
    try testing.expectEqualStrings("test=1", cr_value.slice);
    try testing.expect(!cr_value.owned);
}

test "Cookie: default path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqual("/cookies/resources", try parsePath(allocator, "http://example.com/cookies/resources/echo-cookie.html", null));
    try testing.expectEqual("/cookies/resources", try parsePath(allocator, "http://example.com/cookies/resources/set.py", null));
    try testing.expectEqual("/", try parsePath(allocator, "http://example.com/", null));
    try testing.expectEqual("/", try parsePath(allocator, "http://example.com/foo", null));
}

test "Cookie: pathMatches" {
    try testing.expect(!pathMatches("/doc/", "/doc"));
    try testing.expect(pathMatches("/doc", "/doc/"));
    try testing.expect(pathMatches("/hello", "/hello/extra"));
    try testing.expect(!pathMatches("/hello", "/helloextra"));
    try testing.expect(pathMatches("/cookies/", "/cookies/resources/echo-cookie.html"));
    try testing.expect(pathMatches("/cookies", "/cookies/resources/echo-cookie.html"));
    try testing.expect(!pathMatches("/cook", "/cookies/resources/echo-cookie.html"));
}

const ExpectedCookie = struct {
    name: []const u8,
    value: []const u8,
    path: []const u8,
    domain: []const u8,
    expires: ?f64 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: Cookie.SameSite = .lax,
};

fn expectCookie(expected: ExpectedCookie, url: [:0]const u8, set_cookie: []const u8) !void {
    var cookie = try Cookie.parse(testing.allocator, url, set_cookie);
    defer cookie.deinit();

    try testing.expectEqual(expected.name, cookie.name);
    try testing.expectEqual(expected.value, cookie.value);
    try testing.expectEqual(expected.secure, cookie.secure);
    try testing.expectEqual(expected.http_only, cookie.http_only);
    try testing.expectEqual(expected.same_site, cookie.same_site);
    try testing.expectEqual(expected.path, cookie.path);
    try testing.expectEqual(expected.domain, cookie.domain);

    try testing.expectDelta(expected.expires, cookie.expires, 2.0);
}

fn expectAttribute(expected: anytype, url_: ?[:0]const u8, set_cookie: []const u8) !void {
    var cookie = try Cookie.parse(testing.allocator, url_ orelse test_url, set_cookie);
    defer cookie.deinit();

    inline for (@typeInfo(@TypeOf(expected)).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "expires")) {
            switch (@typeInfo(@TypeOf(expected.expires))) {
                .int, .comptime_int => try testing.expectDelta(@as(f64, @floatFromInt(expected.expires)), cookie.expires, 1.0),
                else => try testing.expectDelta(expected.expires, cookie.expires, 1.0),
            }
        } else {
            try testing.expectEqual(@field(expected, f.name), @field(cookie, f.name));
        }
    }
}

fn expectError(expected: anyerror, url: ?[:0]const u8, set_cookie: []const u8) !void {
    try testing.expectError(expected, Cookie.parse(testing.allocator, url orelse test_url, set_cookie));
}

test "Cookie: appliesTo with empty domain" {
    const cookie = Cookie{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .name = "test",
        .value = "value",
        .domain = "",
        .path = "/",
        .expires = null,
    };
    defer cookie.deinit();

    const target = PreparedUri{
        .host = "example.com",
        .path = "/",
        .secure = false,
    };

    try testing.expectEqual(false, cookie.appliesTo(&target, true, true, true));
}

test "Cookie: parse rejects URL with empty host" {
    try testing.expectError(error.InvalidDomain, Cookie.parse(testing.allocator, "http:///path", "name=value"));
    try testing.expectError(error.InvalidDomain, Cookie.parse(testing.allocator, "http://", "name=value"));
}

test "Cookie: schemeful same-site treats http/https as cross-site" {
    try testing.expect(!isSchemefulSameSite("http://kokoio.com/", "https://kokoio.com/"));
    try testing.expect(isSchemefulSameSite("http://kokoio.com/", "http://test.kokoio.com/"));
    try testing.expect(isThirdPartyContext("https://kokoio.com/", "http://kokoio.com/"));
}

test "Cookie: origin port binding" {
    const now: i64 = @intCast(datetime.timestamp(.clock));
    var jar = Jar.init(testing.allocator);
    defer jar.deinit();

    try jar.add(try Cookie.parse(testing.allocator, "http://kokoio.com:8000/", "port=1;Path=/"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, "http://kokoio.com:9000/", "port=2;Path=/"), now, true);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try jar.forRequest("http://kokoio.com:8000/", &buf.writer, .{
        .origin_url = "http://kokoio.com:8000/",
        .is_http = true,
    });
    try testing.expectEqualStrings("port=1", buf.written());

    buf.clearRetainingCapacity();
    try jar.forRequest("http://kokoio.com:9000/", &buf.writer, .{
        .origin_url = "http://kokoio.com:9000/",
        .is_http = true,
    });
    try testing.expectEqualStrings("port=2", buf.written());
}

test "Cookie: third-party context blocks non-partitioned cookies" {
    const now: i64 = @intCast(datetime.timestamp(.clock));
    var jar = Jar.init(testing.allocator);
    defer jar.deinit();

    try jar.addWithTopLevel(try Cookie.parse(testing.allocator, "https://kokoio.com/", "blocked=1;Path=/;Secure;SameSite=None"), now, true, "https://kokoio.com/");
    try jar.addWithTopLevel(try Cookie.parse(testing.allocator, "https://kokoio.com/", "allowed=1;Path=/;Secure;SameSite=None;Partitioned"), now, true, "https://other.com/");
    try testing.expectEqual(@as(usize, 2), jar.cookies.items.len);
    try testing.expect(jar.cookies.items[1].partitioned);
    try testing.expectEqualStrings("https:other.com", jar.cookies.items[1].partition_site.?);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try jar.forRequest("https://kokoio.com/", &buf.writer, .{
        .origin_url = "https://other.com/",
        .top_level_url = "https://other.com/",
        .is_http = false,
        .is_navigation = false,
    });
    try testing.expectEqualStrings("allowed=1", buf.written());
}
