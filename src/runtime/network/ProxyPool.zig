const std = @import("std");
const net = @import("../../support/net.zig");
const runtime_io = @import("../../support/io.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    EmptyProxyFile,
    InvalidProxyLine,
    UnsupportedProxyScheme,
};

const supported_schemes = [_][]const u8{"http://"};

/// Load and validate a proxy list, then choose exactly one entry for the
/// lifetime of the browser process. Selection is performed once during Config
/// initialization; requests never rotate proxies mid-session.
pub fn loadRandom(allocator: Allocator, path: []const u8) ![:0]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), path, allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(bytes);

    const count = try validateAndCount(allocator, bytes);
    if (count == 0) return Error.EmptyProxyFile;
    var random_source = std.Random.IoSource{ .io = runtime_io.get() };
    return selectAt(allocator, bytes, random_source.interface().uintLessThan(usize, count));
}

fn validateAndCount(allocator: Allocator, bytes: []const u8) !usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = normalizedLine(raw) orelse continue;
        const parsed = try parseLine(allocator, line);
        allocator.free(parsed);
        count += 1;
    }
    return count;
}

fn selectAt(allocator: Allocator, bytes: []const u8, wanted: usize) ![:0]u8 {
    var index: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = normalizedLine(raw) orelse continue;
        if (index == wanted) return parseLine(allocator, line);
        index += 1;
    }
    return Error.EmptyProxyFile;
}

fn normalizedLine(raw: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0 or line[0] == '#') return null;
    return line;
}

/// Accept standard proxy URLs and the common `host:port:user:password`
/// format. URL form should be used when the host is IPv6 or a credential
/// contains `:`.
pub fn parseLine(allocator: Allocator, line: []const u8) ![:0]u8 {
    if (std.mem.indexOf(u8, line, "://") != null) {
        for (supported_schemes) |scheme| {
            if (std.mem.startsWith(u8, line, scheme)) {
                if (containsAsciiWhitespace(line) or line.len == scheme.len) return Error.InvalidProxyLine;
                return allocator.dupeZ(u8, line);
            }
        }
        return Error.UnsupportedProxyScheme;
    }

    var parts = std.mem.splitScalar(u8, line, ':');
    const host = parts.next() orelse return Error.InvalidProxyLine;
    const port_text = parts.next() orelse return Error.InvalidProxyLine;
    const username = parts.next() orelse return Error.InvalidProxyLine;
    const password = parts.next() orelse return Error.InvalidProxyLine;
    if (parts.next() != null or host.len == 0 or username.len == 0 or password.len == 0) {
        return Error.InvalidProxyLine;
    }
    if (containsAsciiWhitespace(host)) return Error.InvalidProxyLine;
    const port = std.fmt.parseInt(u16, port_text, 10) catch return Error.InvalidProxyLine;
    if (port == 0) return Error.InvalidProxyLine;

    const encoded_user = try percentEncodeCredential(allocator, username);
    defer allocator.free(encoded_user);
    const encoded_password = try percentEncodeCredential(allocator, password);
    defer allocator.free(encoded_password);
    return std.fmt.allocPrintSentinel(
        allocator,
        "http://{s}:{s}@{s}:{d}",
        .{ encoded_user, encoded_password, host, port },
        0,
    );
}

/// Safe diagnostic view of a normalized proxy URL. Credentials are never
/// included, even when the source URL contains userinfo.
pub fn redactedEndpoint(proxy: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, proxy, "://") orelse 0;
    const authority_start = if (scheme_end == 0) 0 else scheme_end + 3;
    const authority_tail = proxy[authority_start..];
    const authority_len = std.mem.indexOfScalar(u8, authority_tail, '/') orelse authority_tail.len;
    const authority = authority_tail[0..authority_len];
    const userinfo_end = std.mem.lastIndexOfScalar(u8, authority, '@');
    return if (userinfo_end) |at| authority[at + 1 ..] else authority;
}

/// Return the proxy endpoint as an IP identity when its host is already an IP
/// literal. This is deliberately not a DNS lookup: a gateway hostname may
/// rotate to an exit address unrelated to the gateway itself. Callers must
/// fail closed when the actual exit identity is unknown.
pub fn literalHostAddress(proxy: []const u8) ?net.Address {
    const endpoint = redactedEndpoint(proxy);
    if (endpoint.len == 0) return null;

    if (endpoint[0] == '[') {
        const end = std.mem.indexOfScalar(u8, endpoint, ']') orelse return null;
        return net.Address.parseIp(endpoint[1..end], 0) catch null;
    }

    const colon = std.mem.lastIndexOfScalar(u8, endpoint, ':') orelse return null;
    return net.Address.parseIp(endpoint[0..colon], 0) catch null;
}

fn containsAsciiWhitespace(value: []const u8) bool {
    for (value) |c| if (std.ascii.isWhitespace(c)) return true;
    return false;
}

fn percentEncodeCredential(allocator: Allocator, value: []const u8) ![]u8 {
    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(allocator);
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try encoded.append(allocator, c);
        } else {
            const hex = "0123456789ABCDEF";
            try encoded.appendSlice(allocator, &.{ '%', hex[c >> 4], hex[c & 0x0f] });
        }
    }
    return encoded.toOwnedSlice(allocator);
}

test "proxy pool parses authenticated colon format" {
    const allocator = std.testing.allocator;
    const proxy = try parseLine(allocator, "103.74.100.142:47050:basi2t3i:bAsI2t3I");
    defer allocator.free(proxy);
    try std.testing.expectEqualStrings("http://basi2t3i:bAsI2t3I@103.74.100.142:47050", proxy);
}

test "proxy pool percent-encodes credentials" {
    const allocator = std.testing.allocator;
    const proxy = try parseLine(allocator, "127.0.0.1:8080:user@example:p@ss/word");
    defer allocator.free(proxy);
    try std.testing.expectEqualStrings("http://user%40example:p%40ss%2Fword@127.0.0.1:8080", proxy);
}

test "proxy pool preserves HTTP URL form" {
    const allocator = std.testing.allocator;
    const proxy = try parseLine(allocator, "http://user:pass@127.0.0.1:8080");
    defer allocator.free(proxy);
    try std.testing.expectEqualStrings("http://user:pass@127.0.0.1:8080", proxy);
}

test "proxy pool redacts credentials from diagnostics" {
    try std.testing.expectEqualStrings(
        "127.0.0.1:8080",
        redactedEndpoint("http://secret-user:secret-pass@127.0.0.1:8080"),
    );
}

test "proxy pool exposes only literal endpoint identity" {
    const ipv4 = literalHostAddress("http://user:pass@103.99.2.15:20211") orelse
        return error.MissingLiteralProxyIp;
    const expected = try net.Address.parseIp("103.99.2.15", 0);
    try std.testing.expectEqual(expected.in.addr, ipv4.in.addr);
    try std.testing.expectEqual(expected.in.port, ipv4.in.port);
    try std.testing.expect(literalHostAddress("http://gateway.example:8080") == null);
}

test "proxy pool rejects malformed entries" {
    try std.testing.expectError(Error.InvalidProxyLine, parseLine(std.testing.allocator, "127.0.0.1:8080"));
    try std.testing.expectError(Error.InvalidProxyLine, parseLine(std.testing.allocator, "127.0.0.1:0:user:pass"));
    try std.testing.expectError(Error.UnsupportedProxyScheme, parseLine(std.testing.allocator, "ftp://127.0.0.1:21"));
    try std.testing.expectError(Error.UnsupportedProxyScheme, parseLine(std.testing.allocator, "socks5://127.0.0.1:1080"));
}
