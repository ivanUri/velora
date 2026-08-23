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

fn appendPrint(list: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime format: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(text);
    try list.appendSlice(allocator, text);
}
const idna = @import("../../support/sys/idna.zig");

const Allocator = std.mem.Allocator;

pub const ResolveOpts = struct {
    /// null = don't encode, "UTF-8" = standard percent encoding,
    /// other charset = encode query string using that charset with NCR fallback
    encoding: ?[]const u8 = null,
    always_dupe: bool = false,
};

// path is anytype, so that it can be used with both []const u8 and [:0]const u8
fn trimLeadingUrlInput(path: []const u8) []const u8 {
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        switch (path[i]) {
            '\t', '\n', '\r', ' ' => {},
            else => return path[i..],
        }
    }
    return path[i..];
}

fn trimTrailingUrlInput(path: []const u8) []const u8 {
    var end: usize = path.len;
    while (end > 0 and isC0ControlOrSpace(path[end - 1])) : (end -= 1) {}
    return path[0..end];
}

fn removeTabsAndNewlines(allocator: Allocator, input: []const u8) ![:0]const u8 {
    if (std.mem.indexOfAny(u8, input, "\t\n\r") == null) {
        return try allocator.dupeZ(u8, input);
    }
    var buf = try std.ArrayList(u8).initCapacity(allocator, input.len);
    for (input) |c| {
        if (c != '\t' and c != '\n' and c != '\r') try buf.append(allocator, c);
    }
    try buf.append(allocator, 0);
    return buf.items[0 .. buf.items.len - 1 :0];
}

/// Trim and backslash→slash. Does not expand scheme-relative shorthands (http:foo).
pub fn preprocessInput(allocator: Allocator, input: []const u8) ![:0]const u8 {
    const no_crlf = try removeTabsAndNewlines(allocator, input);
    const trimmed = trimTrailingUrlInput(trimLeadingUrlInput(no_crlf));
    var path: [:0]const u8 = try allocator.dupeZ(u8, trimmed);

    // Fragment/query-only references keep backslashes (WPT: #\\ against a base).
    // Opaque schemes (sc:\../) also keep backslashes.
    const apply_backslash = path.len > 0 and path[0] != '#' and path[0] != '?';
    if (apply_backslash and std.mem.indexOfScalar(u8, path, '\\') != null) {
        const convert_bs = blk: {
            const colon = std.mem.indexOfScalar(u8, path, ':') orelse break :blk false;
            if (colon == 0) break :blk false;
            break :blk isSpecialSchemeName(path[0..colon]);
        };
        if (convert_bs) {
            var bs_buf = try std.ArrayList(u8).initCapacity(allocator, path.len);
            for (path) |c| try bs_buf.append(allocator, if (c == '\\') '/' else c);
            try bs_buf.append(allocator, 0);
            path = bs_buf.items[0 .. bs_buf.items.len - 1 :0];
        }
    }

    return path;
}

/// Trim, backslash→slash, and expand http:/ / http: shorthands for absolute parsing.
pub fn preprocessAbsoluteInput(allocator: Allocator, input: []const u8) ![:0]const u8 {
    const path = try preprocessInput(allocator, input);
    const stripped = stripLeadingGarbageBeforeScheme(path);
    const trimmed = trimTrailingUrlInput(stripped);
    const normalized_input = try allocator.dupeZ(u8, trimmed);
    return normalizeSpecialSchemeForm(allocator, normalized_input);
}

pub fn resolve(allocator: Allocator, base: [:0]const u8, source_path: anytype, opts: ResolveOpts) ![:0]const u8 {
    const PT = @TypeOf(source_path);

    const needs_dupe = comptime !isNullTerminated(PT);
    var path: [:0]const u8 = if (needs_dupe or opts.always_dupe) try allocator.dupeZ(u8, source_path) else source_path;
    path = try preprocessInput(allocator, path);

    if (base.len == 0) {
        const absolute = try normalizeSpecialSchemeForm(allocator, path);
        return processResolved(allocator, absolute, opts);
    }

    // Minimum is "x:" and skip relative path (very common case)
    if (path.len >= 2 and path[0] != '/') {
        if (std.mem.indexOfScalar(u8, path[0..], ':')) |scheme_path_end| {
            scheme_check: {
                const scheme_path = path[0..scheme_path_end];
                //from "ws" to "https"
                if (scheme_path_end >= 2 and scheme_path_end <= 5) {
                    const has_double_slashes: bool = scheme_path_end + 3 <= path.len and path[scheme_path_end + 1] == '/' and path[scheme_path_end + 2] == '/';
                    const special_schemes = [_][]const u8{ "https", "http", "ws", "wss", "file", "ftp" };

                    for (special_schemes) |special_scheme| {
                        if (std.ascii.eqlIgnoreCase(scheme_path, special_scheme)) {
                            const base_scheme_end = std.mem.indexOf(u8, base, "://") orelse 0;

                            if (base_scheme_end > 0 and std.mem.eql(u8, base[0..base_scheme_end], scheme_path) and !has_double_slashes) {
                                //Skip ":" and exit as relative state
                                path = path[scheme_path_end + 1 ..];
                                break :scheme_check;
                            } else {
                                var rest_start: usize = scheme_path_end + 1;
                                //Skip any slashas after "scheme:"
                                while (rest_start < path.len and (path[rest_start] == '/' or path[rest_start] == '\\')) {
                                    rest_start += 1;
                                }
                                // A special scheme (exclude "file") must contain at least any chars after "://"
                                if (rest_start == path.len and !std.ascii.eqlIgnoreCase(scheme_path, "file")) {
                                    return error.TypeError;
                                }
                                //File scheme allow empty host
                                const separator: []const u8 = if (!has_double_slashes and std.ascii.eqlIgnoreCase(scheme_path, "file")) ":///" else "://";

                                path = try std.mem.joinZ(allocator, "", &.{ scheme_path, separator, path[rest_start..] });
                                return processResolved(allocator, path, opts);
                            }
                        }
                    }
                }
                if (scheme_path.len > 0 and std.ascii.isAlphabetic(scheme_path[0])) {
                    for (scheme_path[1..]) |c| {
                        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') {
                            //Exit as relative state
                            break :scheme_check;
                        }
                    }
                    // Opaque absolute URL (e.g. mailto:x, javascript:alert(1))
                    return processResolved(allocator, path, opts);
                }
                // Leading ':' (e.g. :foo.com/) — relative to base
                break :scheme_check;
            }
        }
    }

    if (path.len == 0) {
        if (opts.always_dupe) {
            const dupe = try allocator.dupeZ(u8, base);
            return processResolved(allocator, dupe, opts);
        }
        return processResolved(allocator, base, opts);
    }

    if (isCannotBeABase(base) and path[0] != '#') {
        if (opts.always_dupe) return error.TypeError;
    }

    // Relative inputs against a special-scheme base: \ → / (WPT: \x, \\x\hello, :foo.com\).
    if (base.len > 0 and path[0] != '#' and path[0] != '?' and std.mem.indexOfScalar(u8, path, '\\') != null) {
        if (baseHasSpecialScheme(base)) {
            path = try convertBackslashesInPath(allocator, path);
        }
    }

    if (path[0] == '?') {
        const base_path_end = std.mem.indexOfAny(u8, base, "?#") orelse base.len;
        const result = try std.mem.joinZ(allocator, "", &.{ base[0..base_path_end], path });
        return processResolved(allocator, result, opts);
    }
    if (path[0] == '#') {
        const base_fragment_start = std.mem.indexOfScalar(u8, base, '#') orelse base.len;
        const result = try std.mem.joinZ(allocator, "", &.{ base[0..base_fragment_start], path });
        return processResolved(allocator, result, opts);
    }

    if (std.mem.startsWith(u8, path, "//")) {
        // network-path reference
        const index = std.mem.indexOfScalar(u8, base, ':') orelse {
            return processResolved(allocator, path, opts);
        };
        const protocol = base[0 .. index + 1];
        const result = try std.mem.joinZ(allocator, "", &.{ protocol, path });
        return processResolved(allocator, result, opts);
    }

    const scheme_end = std.mem.indexOf(u8, base, "://");
    const authority_start = if (scheme_end) |end| end + 3 else 0;
    const path_start = std.mem.indexOfScalarPos(u8, base, authority_start, '/') orelse base.len;

    if (path[0] == '/') {
        const result = try std.mem.joinZ(allocator, "", &.{ base[0..path_start], path });
        return processResolved(allocator, result, opts);
    }

    var normalized_base: []const u8 = base[0..path_start];
    if (path_start < base.len) {
        const path_and_rest = base[path_start..];
        const path_only_len = std.mem.indexOfAny(u8, path_and_rest, "?#") orelse path_and_rest.len;
        const path_only = path_and_rest[0..path_only_len];
        if (path_only.len > 1) {
            if (std.mem.lastIndexOfScalar(u8, path_only, '/')) |pos| {
                normalized_base = base[0 .. path_start + pos];
            }
        }
    }

    // trailing space so that we always have space to append the null terminator
    // and so that we can compare the next two characters without needing to length check
    var out = try std.mem.join(allocator, "", &.{ normalized_base, "/", path, "  " });

    const end = out.len - 2;

    const path_marker = path_start + 1;

    // Strip out ./ and ../. This is done in-place, because doing so can
    // only ever make `out` smaller. After this, `out` cannot be freed by
    // an allocator, which is ok, because we expect allocator to be an arena.
    var in_i: usize = 0;
    var out_i: usize = 0;
    while (in_i < end) {
        if (out[in_i] == '.' and (out_i == 0 or out[out_i - 1] == '/')) {
            if (out[in_i + 1] == '/') { // always safe, because we added a whitespace
                // /./
                in_i += 2;
                continue;
            }
            if (out[in_i + 1] == '.' and out[in_i + 2] == '/') { // always safe, because we added two whitespaces
                // /../
                if (out_i > path_marker) {
                    // go back before the /
                    out_i -= 2;
                    while (out_i > 1 and out[out_i - 1] != '/') {
                        out_i -= 1;
                    }
                } else {
                    // if out_i == path_marker, than we've reached the start of
                    // the path. We can't ../ any more. E.g.:
                    //    http://www.example.com/../hello.
                    // You might think that's an error, but, at least with
                    //     new URL('../hello', 'http://www.example.com/')
                    // it just ignores the extra ../
                }
                in_i += 3;
                continue;
            }
            if (in_i == end - 1) {
                // ignore trailing dot
                break;
            }
        }

        const c = out[in_i];
        out[out_i] = c;
        in_i += 1;
        out_i += 1;
    }

    // we always have an extra space
    out[out_i] = 0;
    return processResolved(allocator, out[0..out_i :0], opts);
}

fn isC0ControlOrSpace(c: u8) bool {
    return c <= 0x20 or c == 0x7F;
}

fn hostnameIsIpv4Literal(hostname: []const u8) bool {
    if (hostname.len == 0) return false;
    for (hostname) |c| {
        const ipv4_char = (c >= '0' and c <= '9') or c == '.' or c == 'x' or c == 'X' or
            (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!ipv4_char) return false;
    }
    if (std.mem.indexOfScalar(u8, hostname, '.')) |_| {
        for (hostname) |c| {
            if (c >= '0' and c <= '9') return true;
        }
    }
    var all_decimal = hostname.len > 0;
    for (hostname) |c| {
        if (c < '0' or c > '9') {
            all_decimal = false;
            break;
        }
    }
    if (all_decimal) return true;
    if (hostname.len >= 2 and hostname[0] == '0' and
        (hostname[1] == 'x' or hostname[1] == 'X' or (hostname[1] >= '0' and hostname[1] <= '7')))
        return true;
    return parseIpv4Number(hostname) != null;
}

fn hostPercentEncodingIsValid(hostname: []const u8, is_special: bool) bool {
    if (!is_special) return true;
    var i: usize = 0;
    while (i < hostname.len) : (i += 1) {
        const c = hostname[i];
        if (c == '%') {
            if (i + 2 >= hostname.len) return false;
            const h1 = hostname[i + 1];
            const h2 = hostname[i + 2];
            if (!std.ascii.isHex(h1) or !std.ascii.isHex(h2)) return false;
            const byte = std.fmt.parseInt(u8, hostname[i + 1 .. i + 3], 16) catch return false;
            if (isForbiddenHostCodePoint(byte)) return false;
            i += 2;
        }
    }
    return true;
}

fn percentDecodeHost(allocator: Allocator, hostname: []const u8) ![]u8 {
    var needs_decode = false;
    for (hostname) |c| {
        if (c == '%') {
            needs_decode = true;
            break;
        }
    }
    if (!needs_decode) return try allocator.dupe(u8, hostname);

    var buf = try std.ArrayList(u8).initCapacity(allocator, hostname.len);
    var i: usize = 0;
    while (i < hostname.len) : (i += 1) {
        const c = hostname[i];
        if (c == '%' and i + 2 < hostname.len) {
            const h1 = hostname[i + 1];
            const h2 = hostname[i + 2];
            if (std.ascii.isHex(h1) and std.ascii.isHex(h2)) {
                const byte = std.fmt.parseInt(u8, hostname[i + 1 .. i + 3], 16) catch unreachable;
                try buf.append(allocator, byte);
                i += 2;
                continue;
            }
        }
        try buf.append(allocator, c);
    }
    return buf.items;
}

fn stripLeadingGarbageBeforeScheme(input: []const u8) []const u8 {
    const scheme_sep = std.mem.indexOf(u8, input, "://") orelse return input;
    var scheme_start = scheme_sep;
    while (scheme_start > 0) {
        const c = input[scheme_start - 1];
        if (std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.') {
            scheme_start -= 1;
        } else break;
    }
    if (scheme_start == 0 or scheme_start >= scheme_sep) return input;
    for (input[0..scheme_start]) |c| {
        if (!isC0ControlOrSpace(c) and c != ' ') return input;
    }
    return input[scheme_start..];
}

fn isForbiddenHostCodePoint(c: u8) bool {
    return c == 0x00 or c == 0x09 or c == 0x0A or c == 0x0D or c == 0x20 or
        c == '#' or c == '/' or c == ':' or c == '<' or c == '>' or c == '?' or
        c == '@' or c == '[' or c == '\\' or c == ']' or c == '^' or c == '|';
}

fn hostnameForValidation(host: []const u8) []const u8 {
    const raw = if (findPortSeparator(host)) |sep| host[0..sep] else host;
    if (raw.len > 0 and raw[raw.len - 1] == ':' and findPortSeparator(host) == null)
        return raw[0 .. raw.len - 1];
    return raw;
}

fn percentDecodeHostInto(hostname: []const u8, out: []u8) ?[]const u8 {
    var out_i: usize = 0;
    var i: usize = 0;
    while (i < hostname.len) : (i += 1) {
        const c = hostname[i];
        if (c == '%' and i + 2 < hostname.len) {
            const h1 = hostname[i + 1];
            const h2 = hostname[i + 2];
            if (std.ascii.isHex(h1) and std.ascii.isHex(h2)) {
                if (out_i >= out.len) return null;
                const byte = std.fmt.parseInt(u8, hostname[i + 1 .. i + 3], 16) catch return null;
                out[out_i] = byte;
                out_i += 1;
                i += 2;
                continue;
            }
        }
        if (out_i >= out.len) return null;
        out[out_i] = c;
        out_i += 1;
    }
    return out[0..out_i];
}

fn hostnameUnicodeLabelForbidden(cp: u21) bool {
    return cp == 0xFF05 or cp == 0x00A0 or cp == 0x3000;
}

fn hostnameForHostValidation(hostname: []const u8, is_special: bool) bool {
    if (!is_special) return hostPercentEncodingIsValid(hostname, false);

    var decoded_buf: [512]u8 = undefined;
    const decoded = percentDecodeHostInto(hostname, &decoded_buf) orelse return false;
    for (decoded) |c| {
        if (is_special and c == '%') return false;
        if (is_special and isC0ControlOrSpace(c)) return false;
        if (isForbiddenHostCodePoint(c)) return false;
    }
    if (!std.unicode.utf8ValidateSlice(decoded)) return false;
    var iter: std.unicode.Utf8Iterator = .{ .bytes = decoded, .i = 0 };
    while (iter.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch return false;
        if (is_special and hostnameUnicodeLabelForbidden(cp)) return false;
    }
    return true;
}

fn isTabOrNewline(c: u8) bool {
    return c == 0x09 or c == 0x0A or c == 0x0D;
}

fn sanitizeAuthorityC0(allocator: Allocator, url: [:0]const u8) ![:0]const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return url;
    const authority_start = scheme_end + 3;
    const rel_end = std.mem.indexOfAny(u8, url[authority_start..], "/?#") orelse url.len - authority_start;
    const authority_end = authority_start + rel_end;

    var needs_sanitize = false;
    for (url[authority_start..authority_end]) |c| {
        if (isTabOrNewline(c)) {
            needs_sanitize = true;
            break;
        }
    }
    if (!needs_sanitize) return url;

    var buf = try std.ArrayList(u8).initCapacity(allocator, url.len);
    try buf.appendSlice(allocator, url[0..authority_start]);
    for (url[authority_start..authority_end]) |c| {
        if (!isTabOrNewline(c)) try buf.append(allocator, c);
    }
    try buf.appendSlice(allocator, url[authority_end..]);
    try buf.append(allocator, 0);
    return buf.items[0 .. buf.items.len - 1 :0];
}

fn parsePortNumber(port: []const u8) ?u16 {
    if (port.len == 0) return null;
    var val: u32 = 0;
    for (port) |c| {
        if (c < '0' or c > '9') return null;
        val = val * 10 + (c - '0');
        if (val > 65535) return null;
    }
    return @intCast(val);
}

fn isDefaultPort(protocol: []const u8, port: u16) bool {
    return (std.ascii.eqlIgnoreCase(protocol, "http:") and port == 80) or
        (std.ascii.eqlIgnoreCase(protocol, "https:") and port == 443) or
        (std.ascii.eqlIgnoreCase(protocol, "ftp:") and port == 21) or
        (std.ascii.eqlIgnoreCase(protocol, "ws:") and port == 80) or
        (std.ascii.eqlIgnoreCase(protocol, "wss:") and port == 443);
}

fn normalizeAuthorityPort(allocator: Allocator, url: [:0]const u8) ![:0]const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return url;
    const protocol = url[0 .. scheme_end + 1];
    const authority_start = scheme_end + 3;
    const rel_end = std.mem.indexOfAny(u8, url[authority_start..], "/?#") orelse url.len - authority_start;
    const authority_end = authority_start + rel_end;

    const auth = url[authority_start..authority_end];
    const host_start_in_auth = std.mem.lastIndexOfScalar(u8, auth, '@');
    const host_start = if (host_start_in_auth) |at| authority_start + at + 1 else authority_start;
    const host_part = url[host_start..authority_end];

    if (host_part.len > 0 and host_part[host_part.len - 1] == ':') {
        const is_ipv6_close = host_part[0] == '[' and std.mem.indexOfScalar(u8, host_part, ']') != null;
        if (!is_ipv6_close) {
            var buf = try std.ArrayList(u8).initCapacity(allocator, url.len);
            try buf.appendSlice(allocator, url[0..host_start]);
            try buf.appendSlice(allocator, host_part[0 .. host_part.len - 1]);
            try buf.appendSlice(allocator, url[authority_end..]);
            try buf.append(allocator, 0);
            return buf.items[0 .. buf.items.len - 1 :0];
        }
    }

    const port_sep = findPortSeparator(host_part) orelse return url;
    const hostname = host_part[0..port_sep];
    const port_str = host_part[port_sep + 1 ..];

    if (port_str.len == 0) {
        var buf = try std.ArrayList(u8).initCapacity(allocator, url.len);
        try buf.appendSlice(allocator, url[0..host_start]);
        try buf.appendSlice(allocator, hostname);
        try buf.appendSlice(allocator, url[authority_end..]);
        try buf.append(allocator, 0);
        return buf.items[0 .. buf.items.len - 1 :0];
    }

    const port_num = parsePortNumber(port_str) orelse return url;
    const normalized = try std.fmt.allocPrint(allocator, "{d}", .{port_num});
    const drop_default = isDefaultPort(protocol, port_num);

    if (!drop_default and std.mem.eql(u8, port_str, normalized)) return url;

    var buf = try std.ArrayList(u8).initCapacity(allocator, url.len);
    try buf.appendSlice(allocator, url[0..host_start]);
    try buf.appendSlice(allocator, hostname);
    if (!drop_default) {
        try buf.append(allocator, ':');
        try buf.appendSlice(allocator, normalized);
    }
    try buf.appendSlice(allocator, url[authority_end..]);
    try buf.append(allocator, 0);
    return buf.items[0 .. buf.items.len - 1 :0];
}

fn processResolved(allocator: Allocator, url: [:0]const u8, opts: ResolveOpts) ![:0]const u8 {
    if (opts.always_dupe and !isValidForCanParse(url)) return error.TypeError;
    const sanitized = try sanitizeAuthorityC0(allocator, url);
    const port_norm = try normalizeAuthorityPort(allocator, sanitized);
    if (opts.always_dupe and !isValidForCanParse(port_norm)) return error.TypeError;
    const encoding = opts.encoding orelse {
        return canonicalizeHref(allocator, port_norm) catch |err| {
            if (opts.always_dupe) return error.TypeError;
            return err;
        };
    };
    return ensureEncoded(allocator, port_norm, encoding) catch |err| {
        if (opts.always_dupe) return error.TypeError;
        return err;
    };
}

fn serializeOpaqueFragment(allocator: Allocator, fragment: []const u8) ![]const u8 {
    if (fragment.len == 0) return fragment;
    if (fragment[fragment.len - 1] != ' ') return fragment;
    const prefix = fragment[0 .. fragment.len - 1];
    var buf = try std.ArrayList(u8).initCapacity(allocator, prefix.len + 3);
    try buf.appendSlice(allocator, prefix);
    try buf.appendSlice(allocator, "%20");
    return buf.items;
}

/// Opaque path: percent-encode C0/non-ASCII only; a single trailing U+0020 is special-cased.
fn serializeOpaquePath(allocator: Allocator, path: []const u8) ![]const u8 {
    if (path.len == 0) return path;
    if (path[path.len - 1] != ' ') {
        return percentEncodeSegment(allocator, path, .opaque_path);
    }
    const prefix = path[0 .. path.len - 1];
    const encoded_prefix = try percentEncodeSegment(allocator, prefix, .opaque_path);
    var buf = try std.ArrayList(u8).initCapacity(allocator, encoded_prefix.len + 3);
    try buf.appendSlice(allocator, encoded_prefix);
    try buf.appendSlice(allocator, "%20");
    return buf.items;
}

fn canonicalizeOpaqueHref(allocator: Allocator, url: [:0]const u8) ![:0]const u8 {
    const protocol = getProtocol(url);
    const pathname_raw = getPathname(url);
    const pathname = if (pathname_raw.len > 0)
        try shortenPathname(allocator, pathname_raw)
    else
        pathname_raw;
    const search = getSearchSerialized(url);
    const hash = getHashSerialized(url);

    const encoded_path = try serializeOpaquePath(allocator, pathname);
    const encoded_fragment = if (hash.len > 1)
        try percentEncodeSegment(allocator, hash[1..], .fragment)
    else
        @as([]const u8, "");

    var buf = try std.ArrayList(u8).initCapacity(allocator, protocol.len + encoded_path.len + search.len + encoded_fragment.len + 2);
    try buf.appendSlice(allocator, protocol);
    try buf.appendSlice(allocator, encoded_path);
    try buf.appendSlice(allocator, search);
    if (hash.len > 0) {
        try buf.append(allocator, '#');
        try buf.appendSlice(allocator, encoded_fragment);
    }
    try buf.append(allocator, 0);
    return buf.items[0 .. buf.items.len - 1 :0];
}

fn segmentIsDot(seg: []const u8) bool {
    if (seg.len == 1 and seg[0] == '.') return true;
    return seg.len == 3 and std.ascii.eqlIgnoreCase(seg, "%2e");
}

fn segmentIsDotDot(seg: []const u8) bool {
    if (seg.len == 2 and seg[0] == '.' and seg[1] == '.') return true;
    if (seg.len == 6 and std.ascii.eqlIgnoreCase(seg, "%2e%2e")) return true;
    if (seg.len == 4 and std.ascii.eqlIgnoreCase(seg, ".%2e")) return true;
    return seg.len == 4 and std.ascii.eqlIgnoreCase(seg, "%2e.");
}

fn hasExplicitHierarchicalPath(url: []const u8) bool {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return false;
    return std.mem.indexOfScalarPos(u8, url, scheme_end + 3, '/') != null;
}

fn shortenPathname(allocator: Allocator, pathname: []const u8) ![]const u8 {
    if (pathname.len == 0) return try allocator.dupeZ(u8, "/");
    if (pathname.len == 1 and pathname[0] == '/') return try allocator.dupeZ(u8, "/");

    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(allocator);

    var ends_with_slash = pathname[pathname.len - 1] == '/';
    var start: usize = 0;
    var idx: usize = 0;
    while (idx <= pathname.len) : (idx += 1) {
        if (idx == pathname.len or pathname[idx] == '/') {
            const seg = pathname[start..idx];
            if (segmentIsDot(seg)) {
                if (idx >= pathname.len) ends_with_slash = true;
            } else if (segmentIsDotDot(seg)) {
                if (segments.items.len > 1) {
                    const popped = segments.pop().?;
                    if (idx >= pathname.len) {
                        if (popped.len > 0) {
                            ends_with_slash = true;
                        } else if (segments.items.len > 0 and segments.items[segments.items.len - 1].len > 0) {
                            ends_with_slash = true;
                        }
                    }
                } else if (segments.items.len == 1 and segments.items[0].len > 0) {
                    _ = segments.pop();
                    if (idx >= pathname.len) ends_with_slash = true;
                }
            } else {
                try segments.append(allocator, seg);
            }
            start = idx + 1;
        }
    }

    var buf: std.ArrayList(u8) = .empty;
    var all_empty = segments.items.len > 0;
    for (segments.items) |seg| {
        if (seg.len > 0) {
            all_empty = false;
            break;
        }
    }
    if (all_empty and segments.items.len >= 2) {
        try buf.append(allocator, '/');
        try buf.append(allocator, '/');
    } else if (all_empty and segments.items.len == 1) {
        try buf.append(allocator, '/');
    } else {
        for (segments.items, 0..) |seg, seg_idx| {
            if (seg_idx > 0) try buf.append(allocator, '/');
            try buf.appendSlice(allocator, seg);
        }
        if (buf.items.len == 0) try buf.append(allocator, '/');
    }
    if (ends_with_slash and buf.items.len > 0 and buf.items[buf.items.len - 1] != '/') {
        try buf.append(allocator, '/');
    }
    try buf.append(allocator, 0);
    return buf.items[0 .. buf.items.len - 1 :0];
}

const Ipv4Number = struct { value: u32, non_decimal: bool };

fn parseIpv4Number(part: []const u8) ?Ipv4Number {
    if (part.len == 0) return null;
    var non_decimal = false;
    var radix: u32 = 10;
    var input = part;

    if (input.len >= 2 and input[0] == '0' and (input[1] == 'x' or input[1] == 'X')) {
        non_decimal = true;
        input = input[2..];
        radix = 16;
    } else if (input.len >= 2 and input[0] == '0') {
        non_decimal = true;
        input = input[1..];
        radix = 8;
    }

    if (input.len == 0) return .{ .value = 0, .non_decimal = true };

    var output: u32 = 0;
    for (input) |c| {
        const digit: u32 = switch (radix) {
            10 => blk: {
                if (c < '0' or c > '9') return null;
                break :blk c - '0';
            },
            8 => blk: {
                if (c < '0' or c > '7') return null;
                break :blk c - '0';
            },
            16 => blk: {
                if (c >= '0' and c <= '9') break :blk c - '0';
                if (c >= 'a' and c <= 'f') break :blk c - 'a' + 10;
                if (c >= 'A' and c <= 'F') break :blk c - 'A' + 10;
                return null;
            },
            else => unreachable,
        };
        const mul = @mulWithOverflow(output, radix);
        if (mul[1] != 0) return null;
        output = mul[0];
        const add = @addWithOverflow(output, digit);
        if (add[1] != 0) return null;
        output = add[0];
    }
    return .{ .value = output, .non_decimal = non_decimal };
}

fn ipv4Pow256(exp: u32) u64 {
    var result: u64 = 1;
    var i: u32 = 0;
    while (i < exp) : (i += 1) result *= 256;
    return result;
}

fn parseIpv4Address(host: []const u8) ?u32 {
    var parts: [5][]const u8 = undefined;
    var part_count: usize = 0;
    var start: usize = 0;

    for (0..host.len + 1) |i| {
        if (i < host.len and host[i] != '.') continue;
        if (part_count == parts.len) return null;
        parts[part_count] = host[start..i];
        part_count += 1;
        start = i + 1;
    }
    if (part_count == 0) return null;

    if (parts[part_count - 1].len == 0) {
        if (part_count > 1) part_count -= 1;
    }
    if (part_count > 4) return null;

    var numbers: [4]u32 = undefined;
    var count: usize = 0;
    for (parts[0..part_count]) |part| {
        const parsed = parseIpv4Number(part) orelse return null;
        _ = parsed.non_decimal;
        if (count == 4) return null;
        numbers[count] = parsed.value;
        count += 1;
    }
    if (count == 0) return null;

    for (numbers[0..count]) |n| {
        if (n > 255) {
            // validation error; only non-last parts cause hard failure below
        }
    }
    for (numbers[0 .. count - 1]) |n| {
        if (n > 255) return null;
    }

    const limit = ipv4Pow256(5 - @as(u32, @intCast(count)));
    if (numbers[count - 1] >= limit) return null;

    var ipv4: u64 = numbers[count - 1];
    for (numbers[0 .. count - 1], 0..) |n, counter| {
        const exp: u32 = 3 - @as(u32, @intCast(counter));
        ipv4 += n * ipv4Pow256(exp);
    }
    if (ipv4 > 0xFFFFFFFF) return null;
    return @intCast(ipv4);
}

fn formatIpv4Address(allocator: Allocator, addr: u32) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{
        (addr >> 24) & 0xFF,
        (addr >> 16) & 0xFF,
        (addr >> 8) & 0xFF,
        addr & 0xFF,
    });
}

fn normalizeHostCodepoints(allocator: Allocator, host: []const u8) ![]const u8 {
    if (!std.unicode.utf8ValidateSlice(host)) return try allocator.dupe(u8, host);

    var needs_norm = false;
    var iter: std.unicode.Utf8Iterator = .{ .bytes = host, .i = 0 };
    while (iter.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch return try allocator.dupe(u8, host);
        if (cp >= 0xFF01 and cp <= 0xFF5E) {
            needs_norm = true;
            break;
        }
    }
    if (!needs_norm) return try allocator.dupe(u8, host);

    var buf: std.ArrayList(u8) = .empty;
    iter = .{ .bytes = host, .i = 0 };
    while (iter.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch {
            try buf.appendSlice(allocator, slice);
            continue;
        };
        const mapped: u21 = if (cp >= 0xFF01 and cp <= 0xFF5E) cp - 0xFEE0 else cp;
        var enc: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(mapped, &enc);
        try buf.appendSlice(allocator, enc[0..len]);
    }
    return try buf.toOwnedSlice(allocator);
}

fn percentDecodeHostSlice(allocator: Allocator, host: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, host, '%') == null) return try allocator.dupe(u8, host);
    const decoded = try unescape(allocator, host);
    return try allocator.dupe(u8, decoded);
}

fn readIpv6Hextets(addr: [16]u8) [8]u16 {
    var parts: [8]u16 = undefined;
    for (0..8) |i| {
        parts[i] = std.mem.readInt(u16, addr[i * 2 ..][0..2], .big);
    }
    return parts;
}

fn parseIpv6Hextet(part: []const u8) ?u16 {
    if (part.len == 0 or part.len > 4) return null;
    var value: u16 = 0;
    for (part) |c| {
        const digit: u16 = if (c >= '0' and c <= '9')
            c - '0'
        else if (c >= 'a' and c <= 'f')
            c - 'a' + 10
        else if (c >= 'A' and c <= 'F')
            c - 'A' + 10
        else
            return null;
        value = (value << 4) | digit;
    }
    return value;
}

fn segmentLooksLikeIpv4(input: []const u8, pointer: usize) bool {
    const end = std.mem.indexOfScalarPos(u8, input, pointer, ':') orelse input.len;
    return std.mem.indexOfScalar(u8, input[pointer..end], '.') != null;
}

/// WHATWG URL IPv6 parser (incl. IPv4 suffix like `::127.0.0.1`).
fn parseIpv6AddressBytes(input: []const u8) ?[16]u8 {
    if (input.len == 0) return null;
    if (input.len == 1 and input[0] == ':') return null;
    if (input.len > 0 and input[input.len - 1] == ':' and
        (input.len < 2 or input[input.len - 2] != ':'))
        return null;
    if (std.Io.net.Ip6Address.parse(input, 0)) |ip6| return ip6.bytes else |_| {}

    var pieces: [8]u16 = .{0} ** 8;
    var piece_index: usize = 0;
    var compress: ?usize = null;
    var pointer: usize = 0;

    if (input.len >= 2 and input[0] == ':' and input[1] == ':') {
        pointer = 2;
        piece_index = 1;
        compress = 1;
    }

    while (pointer < input.len) {
        if (piece_index > 7) return null;

        if (segmentLooksLikeIpv4(input, pointer)) {
            const ipv4_part = input[pointer..];
            if (ipv4_part.len > 0 and ipv4_part[ipv4_part.len - 1] == '.') return null;
            const ipv4 = parseIpv4Address(ipv4_part) orelse return null;
            if (piece_index > 6) return null;
            pieces[piece_index] = @intCast((ipv4 >> 16) & 0xFFFF);
            pieces[piece_index + 1] = @intCast(ipv4 & 0xFFFF);
            piece_index += 2;
            break;
        }

        if (input[pointer] == ':') {
            if (compress != null and pointer > 0 and input[pointer - 1] == ':') return null;
            if (compress == null) compress = piece_index;
            pointer += 1;
            continue;
        }

        const colon = std.mem.indexOfScalarPos(u8, input, pointer, ':') orelse input.len;
        const hextet = parseIpv6Hextet(input[pointer..colon]) orelse return null;
        pieces[piece_index] = hextet;
        piece_index += 1;
        pointer = if (colon < input.len) colon + 1 else colon;
    }

    if (compress) |at| {
        const swaps = piece_index - at;
        var i: usize = 0;
        while (i < swaps) : (i += 1) {
            pieces[7 - i] = pieces[at + swaps - 1 - i];
        }
        var j: usize = at;
        while (j < 8 - swaps) : (j += 1) {
            pieces[j] = 0;
        }
    }

    var addr: [16]u8 = undefined;
    for (pieces, 0..) |p, i| {
        std.mem.writeInt(u16, addr[i * 2 ..][0..2], p, .big);
    }
    return addr;
}

fn formatIpv6Canonical(allocator: Allocator, inner: []const u8) ![]const u8 {
    const addr = parseIpv6AddressBytes(inner) orelse return error.InvalidIpv6;
    const parts = readIpv6Hextets(addr);

    var longest_start: usize = 8;
    var longest_len: usize = 0;
    var current_start: usize = 0;
    var current_len: usize = 0;
    for (parts, 0..) |part, i| {
        if (part == 0) {
            if (current_len == 0) current_start = i;
            current_len += 1;
            if (current_len > longest_len) {
                longest_start = current_start;
                longest_len = current_len;
            }
        } else {
            current_len = 0;
        }
    }
    if (longest_len < 2) {
        longest_start = 8;
        longest_len = 0;
    }

    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var abbrv = false;
    while (i < parts.len) : (i += 1) {
        if (i == longest_start) {
            if (!abbrv) {
                try buf.appendSlice(allocator, if (i == 0) "::" else ":");
                abbrv = true;
            }
            i += longest_len - 1;
            continue;
        }
        if (abbrv) abbrv = false;
        try appendPrint(&buf, allocator, "{x}", .{parts[i]});
        if (i != parts.len - 1) try buf.append(allocator, ':');
    }
    return buf.items;
}

fn normalizeIpv6HostForHref(allocator: Allocator, host: []const u8) ![]const u8 {
    const bracket_end = std.mem.indexOfScalar(u8, host, ']') orelse return allocator.dupe(u8, host);
    const inner = host[1..bracket_end];
    const port_suffix = host[bracket_end + 1 ..];
    const canonical = try formatIpv6Canonical(allocator, inner);
    defer allocator.free(canonical);
    return std.fmt.allocPrint(allocator, "[{s}]{s}", .{ canonical, port_suffix });
}

fn normalizeHostForHref(allocator: Allocator, host: []const u8) ![]const u8 {
    const port_sep = findPortSeparator(host);
    const hostname = if (port_sep) |sep| host[0..sep] else host;
    const port_suffix = if (port_sep) |sep| host[sep..] else "";

    if (hostname.len > 0 and hostname[0] == '[') {
        return normalizeIpv6HostForHref(allocator, host);
    }

    const decoded = try percentDecodeHostSlice(allocator, hostname);
    defer allocator.free(decoded);
    const ascii_host = try normalizeHostCodepoints(allocator, decoded);
    defer if (!std.mem.eql(u8, ascii_host, decoded)) allocator.free(ascii_host);

    if (parseIpv4Address(ascii_host)) |ipv4| {
        const formatted = try formatIpv4Address(allocator, ipv4);
        if (port_suffix.len == 0) return formatted;
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ formatted, port_suffix });
    }

    var needs_lower = false;
    for (ascii_host) |c| {
        if (c >= 'A' and c <= 'Z') {
            needs_lower = true;
            break;
        }
    }
    if (!needs_lower) return allocator.dupe(u8, host);

    var buf = try std.ArrayList(u8).initCapacity(allocator, host.len);
    for (ascii_host) |c| {
        try buf.append(allocator, if (c >= 'A' and c <= 'Z') c + 32 else c);
    }
    try buf.appendSlice(allocator, port_suffix);
    return buf.items;
}

fn serializeQueryForHref(allocator: Allocator, url: [:0]const u8) ![]const u8 {
    const search = getSearchSerialized(url);
    if (search.len == 0) return "";
    const protocol = getProtocol(url);
    const body = if (isSpecialScheme(protocol))
        try percentEncodeSegment(allocator, search[1..], .special_query)
    else
        try percentEncodeSegment(allocator, search[1..], .query);
    return std.fmt.allocPrint(allocator, "?{s}", .{body});
}

fn serializeFragmentForHref(allocator: Allocator, url: [:0]const u8) ![]const u8 {
    const hash = getHashSerialized(url);
    if (hash.len == 0) return "";
    const body = try percentEncodeSegment(allocator, hash[1..], .fragment);
    return std.fmt.allocPrint(allocator, "#{s}", .{body});
}

fn percentEncodeHost(allocator: Allocator, host: []const u8) ![]const u8 {
    const port_sep = findPortSeparator(host);
    const hostname = if (port_sep) |sep| host[0..sep] else host;
    const port_suffix = if (port_sep) |sep| host[sep..] else "";
    if (hostname.len > 0 and hostname[0] == '[') {
        return normalizeIpv6HostForHref(allocator, host);
    }
    const enc = try percentEncodeSegment(allocator, hostname, .host);
    if (port_suffix.len == 0) return allocator.dupe(u8, enc);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ enc, port_suffix });
}

fn normalizeFilePathname(allocator: Allocator, pathname: []const u8) ![]const u8 {
    if (pathname.len == 0) return "/";
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(allocator, '/');
    var i: usize = if (pathname[0] == '/') 1 else 0;
    while (i < pathname.len) : (i += 1) {
        const c = pathname[i];
        if (c == '|' and i + 1 < pathname.len and pathname[i + 1] == '/') {
            try buf.append(allocator, ':');
            i += 1;
        } else if (c == '|' and i + 1 < pathname.len and pathname[i + 1] == '|') {
            try buf.append(allocator, '|');
            i += 1;
        } else {
            try buf.append(allocator, c);
        }
    }
    try buf.append(allocator, 0);
    return buf.items[0 .. buf.items.len - 1 :0];
}

fn canonicalizeFileHref(allocator: Allocator, url: [:0]const u8) ![:0]const u8 {
    const protocol = getProtocol(url);
    var host = getHost(url);
    var pathname = getPathname(url);
    const search = getSearchSerialized(url);
    const hash = getHashSerialized(url);

    if (std.ascii.eqlIgnoreCase(host, "localhost")) {
        host = "";
    }

    if (host.len > 0 and pathname.len == 0) pathname = "/";

    if (host.len == 0) {
        pathname = try normalizeFilePathname(allocator, pathname);
        return std.fmt.allocPrintSentinel(allocator, "{s}//{s}{s}{s}", .{ protocol, pathname, search, hash }, 0);
    }
    return std.fmt.allocPrintSentinel(allocator, "{s}//{s}{s}{s}{s}", .{ protocol, host, pathname, search, hash }, 0);
}

/// Canonicalize `scheme:/path` URLs without an authority.
/// Special: `about:/../` style (after special-scheme rewrite elsewhere).
/// Non-special: `javascript:/../` → path-state shorten → `javascript:/` (URL Standard).
fn canonicalizeSchemeSlashHref(allocator: Allocator, url: [:0]const u8) ![:0]const u8 {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return url;
    if (colon == 0 or colon + 1 >= url.len or url[colon + 1] != '/') return url;
    // Non-special scheme:/… still uses path-state segment shortening.
    // Special schemes with single slash are usually rewritten to :// first.

    const path_start = colon + 1;
    const fragment_start = std.mem.indexOfScalarPos(u8, url, path_start, '#');
    const query_start = findQueryStartFrom(url, path_start);
    const path_end = query_start orelse fragment_start orelse url.len;

    const raw_path = url[path_start..path_end];
    const shortened = try shortenPathname(allocator, raw_path);
    const pathname_short = if (shortened.len == 2 and std.mem.eql(u8, shortened, "//") and
        !std.mem.startsWith(u8, raw_path, "//"))
        try allocator.dupeZ(u8, "/")
    else
        shortened;
    const search = if (query_start) |qs| url[qs .. fragment_start orelse url.len] else @as([]const u8, "");
    const hash = if (fragment_start) |fs| url[fs..] else @as([]const u8, "");

    // Lowercase scheme for non-special absolute form consistency
    var buf = try std.ArrayList(u8).initCapacity(allocator, url.len);
    for (url[0..colon]) |c| {
        try buf.append(allocator, if (c >= 'A' and c <= 'Z') c + 32 else c);
    }
    try buf.append(allocator, ':');
    try buf.appendSlice(allocator, pathname_short);
    try buf.appendSlice(allocator, search);
    try buf.appendSlice(allocator, hash);
    try buf.append(allocator, 0);
    return buf.items[0 .. buf.items.len - 1 :0];
}

/// Re-serialize a parsed hierarchical URL (userinfo, path, query, fragment encoding).
fn canonicalizeHref(allocator: Allocator, url: [:0]const u8) ![:0]const u8 {
    if (isCannotBeABase(url)) {
        return canonicalizeOpaqueHref(allocator, url);
    }

    if (std.mem.indexOf(u8, url, "://") == null) {
        return canonicalizeSchemeSlashHref(allocator, url);
    }

    const protocol = getProtocol(url);
    if (std.ascii.eqlIgnoreCase(protocol, "file:")) {
        return canonicalizeFileHref(allocator, url);
    }

    const is_special = isSpecialScheme(protocol);
    const idn_url = if (is_special) try ensureHostAscii(allocator, url) else url;
    const host = if (is_special)
        try normalizeHostForHref(allocator, getHost(idn_url))
    else
        try percentEncodeHost(allocator, getHost(idn_url));
    const pathname_raw = getPathname(idn_url);
    const pathname_short = if (!hasExplicitHierarchicalPath(idn_url)) blk: {
        if (is_special) break :blk try allocator.dupeZ(u8, "/");
        break :blk "";
    } else if (!is_special) blk: {
        break :blk try allocator.dupeZ(u8, pathname_raw);
    } else if (pathname_raw.len == 1 and pathname_raw[0] == '/')
        try allocator.dupeZ(u8, "/")
    else
        try shortenPathname(allocator, pathname_raw);
    const encoded_path = if (pathname_short.len == 0)
        ""
    else
        try percentEncodeSegment(allocator, pathname_short, .path);
    const search = try serializeQueryForHref(allocator, idn_url);
    const hash = try serializeFragmentForHref(allocator, idn_url);
    const username = getUsername(idn_url);
    const password = getPassword(idn_url);

    const enc_user = try percentEncodeSegment(allocator, username, .userinfo);
    const enc_pass = try percentEncodeSegment(allocator, password, .userinfo);
    return buildUrlWithUserInfo(allocator, protocol, enc_user, enc_pass, host, encoded_path, search, hash);
}

/// IDNA-only pass: converts a non-ASCII host (`räksmörgås.se`) to its
/// punycode form (`xn--rksmrgs-5wao1o.se`) and leaves everything else alone.
fn ensureHostAscii(allocator: Allocator, url: [:0]const u8) ![:0]const u8 {
    const hostname = getHostname(url);
    if (hostname.len == 0) return url;
    if (hostname[0] == '[') return url;

    const decoded = try percentDecodeHost(allocator, hostname);
    defer allocator.free(decoded);

    if (!idna.needsAscii(decoded)) return url;

    const ascii = try idna.toAscii(allocator, decoded);
    if (std.mem.eql(u8, ascii, decoded)) {
        allocator.free(ascii);
        return url;
    }

    // hostname is a slice of url, so its start offset is just pointer arithmetic.
    const start = @intFromPtr(hostname.ptr) - @intFromPtr(url.ptr);
    const end = start + hostname.len;
    var buf = try std.ArrayList(u8).initCapacity(allocator, url.len - hostname.len + ascii.len + 1);
    buf.appendSliceAssumeCapacity(url[0..start]);
    buf.appendSliceAssumeCapacity(ascii);
    buf.appendSliceAssumeCapacity(url[end..]);
    buf.appendAssumeCapacity(0);
    return buf.items[0 .. buf.items.len - 1 :0];
}

pub fn ensureEncoded(allocator: Allocator, url_in: [:0]const u8, encoding: []const u8) ![:0]const u8 {
    const url = if (std.mem.indexOf(u8, url_in, "://")) |scheme_end| blk: {
        const protocol = url_in[0 .. scheme_end + 1];
        if (isSpecialScheme(protocol)) break :blk try ensureHostAscii(allocator, url_in);
        break :blk url_in;
    } else url_in;

    const scheme_end = std.mem.indexOf(u8, url, "://");
    const authority_start = if (scheme_end) |end| end + 3 else 0;
    const path_start = std.mem.indexOfScalarPos(u8, url, authority_start, '/') orelse return url;

    const fragment_start = std.mem.indexOfScalarPos(u8, url, path_start, '#');
    const query_start = findQueryStartFrom(url, path_start);
    const path_end = query_start orelse fragment_start orelse url.len;
    const query_end = if (query_start != null) (fragment_start orelse url.len) else path_end;

    const path_to_encode = url[path_start..path_end];
    // Path is always UTF-8 percent encoded per URL spec
    const encoded_path = try percentEncodeSegment(allocator, path_to_encode, .path);

    // Query string uses document encoding
    const encoded_query = if (query_start) |qs| blk: {
        const query_to_encode = url[qs + 1 .. query_end];
        break :blk try encodeQueryString(allocator, query_to_encode, encoding);
    } else null;

    const encoded_fragment = if (fragment_start) |fs| blk: {
        const fragment_to_encode = trimTrailingUrlInput(url[fs + 1 ..]);
        break :blk try percentEncodeSegment(allocator, fragment_to_encode, .fragment);
    } else null;

    if (encoded_path.ptr == path_to_encode.ptr and
        (encoded_query == null or encoded_query.?.ptr == url[query_start.? + 1 .. query_end].ptr) and
        (encoded_fragment == null or encoded_fragment.?.ptr == url[fragment_start.? + 1 ..].ptr))
    {
        // nothing has changed
        return url;
    }

    var buf = try std.ArrayList(u8).initCapacity(allocator, url.len + 20);
    try buf.appendSlice(allocator, url[0..path_start]);
    try buf.appendSlice(allocator, encoded_path);
    if (encoded_query) |eq| {
        try buf.append(allocator, '?');
        try buf.appendSlice(allocator, eq);
    }
    if (encoded_fragment) |ef| {
        try buf.append(allocator, '#');
        try buf.appendSlice(allocator, ef);
    }
    try buf.append(allocator, 0);
    return buf.items[0 .. buf.items.len - 1 :0];
}

const EncodeSet = enum { path, query, query_legacy, special_query, userinfo, fragment, host, opaque_path };

fn percentEncodeSegment(allocator: Allocator, segment: []const u8, comptime encode_set: EncodeSet) ![]const u8 {
    // Check if encoding is needed
    var needs_encoding = false;
    for (segment) |c| {
        if (shouldPercentEncode(c, encode_set)) {
            needs_encoding = true;
            break;
        }
    }
    if (!needs_encoding) {
        return segment;
    }

    var buf = try std.ArrayList(u8).initCapacity(allocator, segment.len + 10);

    var i: usize = 0;
    while (i < segment.len) : (i += 1) {
        const c = segment[i];

        // Check if this is an already-encoded sequence (%XX)
        if (c == '%' and i + 2 < segment.len) {
            const end = i + 2;
            const h1 = segment[i + 1];
            const h2 = segment[end];
            if (std.ascii.isHex(h1) and std.ascii.isHex(h2)) {
                try buf.appendSlice(allocator, segment[i .. end + 1]);
                i = end;
                continue;
            }
        }

        if (c == '%') {
            // Preserve incomplete percent-sequences (WPT: %2e%2 must not become %2e%252).
            try buf.append(allocator, '%');
            continue;
        }

        if (shouldPercentEncode(c, encode_set)) {
            try appendPrint(&buf, allocator, "%{X:0>2}", .{c});
        } else {
            try buf.append(allocator, c);
        }
    }

    return buf.items;
}

const h5e = @import("../parser/html5ever.zig");

/// Encode a query string using the specified encoding.
/// For UTF-8, this is standard percent encoding.
/// For legacy encodings, unmappable characters are replaced with NCRs (&#codepoint;).
fn encodeQueryString(allocator: Allocator, query: []const u8, encoding: []const u8) ![]const u8 {
    // For UTF-8, use standard percent encoding
    if (std.mem.eql(u8, encoding, "UTF-8")) {
        return percentEncodeSegment(allocator, query, .query);
    }

    // For legacy encodings, first encode to the target charset with NCR fallback
    const enc_info = h5e.encoding_for_label(encoding.ptr, encoding.len);
    if (!enc_info.isValid()) {
        // Unknown encoding, fall back to UTF-8
        return percentEncodeSegment(allocator, query, .query);
    }

    // Calculate max buffer size for encoded output
    const max_encoded_len = h5e.encoding_max_encode_buffer_length(enc_info.handle.?, query.len);
    if (max_encoded_len == 0) {
        return percentEncodeSegment(allocator, query, .query);
    }

    const encode_buf = try allocator.alloc(u8, max_encoded_len);
    defer allocator.free(encode_buf);

    // Encode UTF-8 to legacy encoding with NCR fallback
    const result = h5e.encoding_encode_with_ncr(
        enc_info.handle.?,
        query.ptr,
        query.len,
        encode_buf.ptr,
        encode_buf.len,
    );

    if (!result.isSuccess()) {
        // Encoding failed, fall back to UTF-8
        return percentEncodeSegment(allocator, query, .query);
    }

    // Now percent-encode the result using query_legacy to preserve NCRs
    const encoded_bytes = encode_buf[0..result.bytes_written];
    return percentEncodeSegment(allocator, encoded_bytes, .query_legacy);
}

fn isC0OrNonAscii(c: u8) bool {
    return c <= 0x1F or c == 0x7F or c > 0x7F;
}

fn shouldPercentEncode(c: u8, comptime encode_set: EncodeSet) bool {
    if (encode_set == .query_legacy) {
        return switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => false,
            '!', '$', '\'', '(', ')', '*', '+', ',', '/', ':', '@' => false,
            '&', ';' => true,
            else => isC0OrNonAscii(c),
        };
    }

    if (isC0OrNonAscii(c)) return true;

    return switch (encode_set) {
        .userinfo => switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => false,
            '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => false,
            else => true,
        },
        .path => switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => false,
            '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', '/', '?', '#', '[', ']', '@' => false,
            '"', '<', '>', '^', '`', '{', '}', ' ' => true,
            else => false,
        },
        .query => switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => false,
            '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', '/', '?', '#', '[', ']', '@' => false,
            '"', '<', '>', '`', ' ' => true,
            else => false,
        },
        .fragment => switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => false,
            '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', '/', '?', '#', '[', ']', '@' => false,
            '"', '<', '>', '`', ' ' => true,
            else => false,
        },
        .host => isC0OrNonAscii(c),
        .opaque_path => isC0OrNonAscii(c),
        .special_query => switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => false,
            '!', '$', '&', '(', ')', '*', '+', ',', ';', '=', '/', '?', '#', '[', ']', '@', '`', '{', '}' => false,
            '"', '<', '>', ' ' => true,
            '\'' => true,
            else => false,
        },
        .query_legacy => unreachable,
    };
}

fn isNullTerminated(comptime value: type) bool {
    return @typeInfo(value).pointer.sentinel_ptr != null;
}

pub fn canParse(url_: ?[]const u8, base_: ?[]const u8) bool {
    const url = url_ orelse "";
    const base = base_ orelse "";

    if (url.len == 0 and base.len == 0) return false;

    var buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    if (url.len == 0) {
        const base_z = allocator.dupeZ(u8, base) catch return false;
        return isValidBaseURL(base_z);
    }

    const base_z: [:0]const u8 = if (base.len > 0)
        allocator.dupeZ(u8, base) catch return false
    else
        "";

    const resolved = resolve(allocator, base_z, url, .{}) catch return false;
    return isValidForCanParse(resolved);
}

/// Strict base URL check for `URL.canParse("", base)` — opaque bases need `/` after `:`.
pub fn isValidBaseURL(base: [:0]const u8) bool {
    if (base.len == 0) return false;

    if (std.mem.indexOf(u8, base, "://")) |_| {
        return isValidForCanParse(base);
    }

    const colon = std.mem.indexOfScalar(u8, base, ':') orelse return false;
    if (colon == 0) return false;

    const after_colon = base[colon + 1 ..];
    if (after_colon.len == 0) return false;
    return after_colon[0] == '/';
}

/// Permissive base check for `new URL(input, base)` — any valid opaque or hierarchical URL.
pub fn isValidParserBase(base: [:0]const u8) bool {
    if (base.len == 0) return false;

    if (std.mem.indexOf(u8, base, "://")) |_| {
        return isValidForCanParse(base);
    }

    const colon = std.mem.indexOfScalar(u8, base, ':') orelse return false;
    if (colon == 0) return false;

    const scheme = base[0..colon];
    if (!std.ascii.isAlphabetic(scheme[0])) return false;
    for (scheme[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') {
            return false;
        }
    }
    return colon + 1 < base.len;
}

pub fn isValidParsedUrl(url: [:0]const u8) bool {
    return isValidForCanParse(url);
}

fn isValidForCanParse(url: [:0]const u8) bool {
    if (std.mem.indexOf(u8, url, "://")) |_| {
        const protocol = getProtocol(url);
        const is_file = std.ascii.eqlIgnoreCase(protocol, "file:");
        const auth = parseAuthority(url) orelse return false;
        const host = auth.getHost(url);
        const is_special = isSpecialScheme(protocol);

        if (is_file) {
            if (host.len == 0) return true;
            if (host[0] == '[') return false;
            if (std.mem.indexOfScalar(u8, host, '%')) |_| return false;
            if (findPortSeparator(host)) |_| return false;
            return true;
        }

        if (host.len == 0) {
            if (auth.has_user_info) return false;
            return !is_special;
        }

        if (host[0] == '[') {
            const bracket_end = std.mem.indexOfScalar(u8, host, ']') orelse return false;
            const inner = host[1..bracket_end];
            if (parseIpv6AddressBytes(inner) == null) return false;
            if (bracket_end + 1 < host.len and host[bracket_end + 1] == ':') {
                const port = host[bracket_end + 2 ..];
                if (port.len == 0) return false;
                for (port) |c| {
                    if (c < '0' or c > '9') return false;
                }
            }
            return true;
        }

        var colon_count: usize = 0;
        for (host) |c| {
            if (c == ':') colon_count += 1;
        }
        if (colon_count > 1) return false;

        const hostname = hostnameForValidation(host);
        if (hostname.len == 0) return false;

        if (is_special and hostnameIsIpv4Literal(hostname)) {
            if (parseIpv4Address(hostname) == null) return false;
        }
        if (!hostPercentEncodingIsValid(hostname, is_special)) return false;
        if (!hostnameForHostValidation(hostname, is_special)) return false;
        for (hostname) |c| {
            if (is_special) {
                if (isC0ControlOrSpace(c) or isForbiddenHostCodePoint(c)) return false;
            } else if (isForbiddenHostCodePoint(c)) {
                return false;
            }
        }

        if (std.mem.indexOfScalar(u8, host, ':')) |_| {
            if (findPortSeparator(host)) |sep| {
                const port = host[sep + 1 ..];
                if (port.len == 0) {
                    // `http://f:/c` — trailing colon on host is normalized away.
                    return sep + 1 == host.len;
                }
                if (parsePortNumber(port) == null) return false;
            } else if (host.len > 0 and host[host.len - 1] == ':') {
                // `http://f:/c` — trailing colon on host is normalized away.
            } else {
                return false;
            }
        }
        return true;
    }
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return false;
    return colon > 0;
}

/// True when `input` is a same-scheme special URL like `http:/path` that must resolve against `base`.
pub fn shouldResolveAgainstBase(input: []const u8, base: []const u8) bool {
    if (!isAbsoluteUrl(input)) return true;
    if (isCompleteHTTPUrl(input)) return false;

    const in_colon = std.mem.indexOfScalar(u8, input, ':') orelse return false;
    const base_colon = std.mem.indexOfScalar(u8, base, ':') orelse return false;
    if (!std.ascii.eqlIgnoreCase(input[0..in_colon], base[0..base_colon])) return false;

    const after = input[in_colon + 1 ..];
    if (after.len >= 2 and after[0] == '/' and after[1] == '/') return false;
    return isSpecialSchemeName(input[0..in_colon]);
}

pub fn isAbsoluteUrl(url: []const u8) bool {
    if (isCompleteHTTPUrl(url)) return true;
    if (url.len == 0 or url[0] == '/') return false;

    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return false;
    if (colon == 0) return false;

    const scheme = url[0..colon];
    if (!std.ascii.isAlphabetic(scheme[0])) return false;
    for (scheme[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') {
            return false;
        }
    }
    if (colon + 1 >= url.len) return false;

    const after_colon = url[colon + 1 ..];
    if (isSpecialSchemeName(scheme)) {
        if (after_colon.len >= 2 and after_colon[0] == '/' and after_colon[1] == '/') return true;
        if (after_colon.len >= 1 and after_colon[0] == '/') return true;
        return false;
    }
    return true;
}

pub fn isCompleteHTTPUrl(url: []const u8) bool {
    if (url.len < 3) { // Minimum is "x://"
        return false;
    }

    // very common case
    if (url[0] == '/') {
        return false;
    }

    // blob: and data: URLs are complete but don't follow scheme:// pattern
    if (std.mem.startsWith(u8, url, "blob:") or std.mem.startsWith(u8, url, "data:")) {
        return true;
    }

    // Check if there's a scheme (protocol) ending with ://
    const colon_pos = std.mem.indexOfScalar(u8, url, ':') orelse return false;

    // Check if it's followed by //
    if (colon_pos + 2 >= url.len or url[colon_pos + 1] != '/' or url[colon_pos + 2] != '/') {
        return false;
    }

    // Validate that everything before the colon is a valid scheme
    // A scheme must start with a letter and contain only letters, digits, +, -, .
    if (colon_pos == 0) {
        return false;
    }

    const scheme = url[0..colon_pos];
    if (!std.ascii.isAlphabetic(scheme[0])) {
        return false;
    }

    for (scheme[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') {
            return false;
        }
    }

    return true;
}

pub fn getUsername(raw: [:0]const u8) []const u8 {
    const user_info = getUserInfo(raw) orelse return "";
    const pos = std.mem.indexOfScalarPos(u8, user_info, 0, ':') orelse return user_info;
    return user_info[0..pos];
}

pub fn getPassword(raw: [:0]const u8) []const u8 {
    const user_info = getUserInfo(raw) orelse return "";
    const pos = std.mem.indexOfScalarPos(u8, user_info, 0, ':') orelse return "";
    return user_info[pos + 1 ..];
}

pub fn isCannotBeABase(raw: []const u8) bool {
    // blob:/data: embed an origin-bearing URL (blob:http://host/uuid) but remain opaque.
    if (std.mem.startsWith(u8, raw, "blob:") or std.mem.startsWith(u8, raw, "data:")) {
        return true;
    }
    if (std.mem.indexOf(u8, raw, "://") != null) return false;
    const colon = std.mem.indexOfScalar(u8, raw, ':') orelse return false;
    if (colon == 0) return false;
    const after = raw[colon + 1 ..];
    if (after.len > 0 and after[0] == '/') return false;
    return true;
}

fn isSpecialScheme(protocol: []const u8) bool {
    const schemes = [_][]const u8{ "http:", "https:", "ftp:", "file:", "ws:", "wss:" };
    for (schemes) |s| {
        if (std.ascii.eqlIgnoreCase(protocol, s)) return true;
    }
    return false;
}

fn isSpecialSchemeName(scheme: []const u8) bool {
    if (scheme.len == 0) return false;
    var buf: [12]u8 = undefined;
    const with_colon = if (scheme[scheme.len - 1] == ':')
        scheme
    else
        std.fmt.bufPrint(&buf, "{s}:", .{scheme}) catch return false;
    return isSpecialScheme(with_colon);
}

fn baseHasSpecialScheme(base: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, base, ':') orelse return false;
    if (colon == 0) return false;
    return isSpecialSchemeName(base[0..colon]);
}

fn convertBackslashesInPath(allocator: Allocator, path: [:0]const u8) ![:0]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, path.len);
    for (path) |c| try buf.append(allocator, if (c == '\\') '/' else c);
    try buf.append(allocator, 0);
    return buf.items[0 .. buf.items.len - 1 :0];
}

fn normalizeSpecialSchemeForm(allocator: Allocator, url: [:0]const u8) ![:0]const u8 {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return url;
    if (colon == 0) return url;

    const scheme = url[0..colon];
    if (!isSpecialSchemeName(scheme)) return url;

    const after = url[colon + 1 ..];
    if (after.len >= 2 and after[0] == '/' and after[1] == '/') return url;

    if (after.len >= 1 and after[0] == '/') {
        return try std.fmt.allocPrintSentinel(allocator, "{s}//{s}", .{ url[0 .. colon + 1], after[1..] }, 0);
    }
    if (after.len > 0) {
        return try std.fmt.allocPrintSentinel(allocator, "{s}//{s}", .{ url[0 .. colon + 1], after }, 0);
    }
    return url;
}

fn originBearingScheme(protocol: []const u8) bool {
    const schemes = [_][]const u8{ "http:", "https:", "ftp:", "ws:", "wss:" };
    for (schemes) |s| {
        if (std.ascii.eqlIgnoreCase(protocol, s)) return true;
    }
    return false;
}

fn appendLowercaseOriginHost(buf: *std.ArrayList(u8), allocator: Allocator, host: []const u8) !void {
    const port_sep = findPortSeparator(host);
    const hostname = if (port_sep) |sep| host[0..sep] else host;
    const port_suffix = if (port_sep) |sep| host[sep..] else "";

    if (hostname.len > 0 and hostname[0] == '[') {
        try buf.appendSlice(allocator, host);
        return;
    }
    for (hostname) |c| {
        try buf.append(allocator, if (c >= 'A' and c <= 'Z') c + 32 else c);
    }
    try buf.appendSlice(allocator, port_suffix);
}

fn buildOpaqueUrl(
    allocator: Allocator,
    protocol: []const u8,
    pathname: []const u8,
    search: []const u8,
    hash: []const u8,
) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(allocator, "{s}{s}{s}{s}", .{
        protocol,
        pathname,
        search,
        hash,
    }, 0);
}

/// Serialize an opaque (cannot-be-a-base) path for URLSearchParams-driven href updates.
/// Uses the cannot-be-a-base-URL path percent-encode set (C0 + non-ASCII only);
/// a single trailing U+0020 is percent-encoded, earlier spaces stay U+0020.
pub fn serializeCannotBeABasePath(allocator: Allocator, path: []const u8) ![]const u8 {
    if (path.len == 0) return path;
    if (path[path.len - 1] != ' ') {
        return percentEncodeSegment(allocator, path, .opaque_path);
    }
    const prefix = path[0 .. path.len - 1];
    const encoded_prefix = try percentEncodeSegment(allocator, prefix, .opaque_path);
    var buf = try std.ArrayList(u8).initCapacity(allocator, encoded_prefix.len + 3);
    try buf.appendSlice(allocator, encoded_prefix);
    try buf.appendSlice(allocator, "%20");
    return buf.items;
}

pub fn getPathname(raw: [:0]const u8) []const u8 {
    // blob: URLs embed an origin-bearing URL; the inner "://" must not be parsed as hierarchical.
    if (std.mem.startsWith(u8, raw, "blob:")) {
        const path = raw["blob:".len..];
        const query_or_hash = std.mem.indexOfAny(u8, path, "?#") orelse path.len;
        return path[0..query_or_hash];
    }

    const protocol_end = std.mem.indexOf(u8, raw, "://");

    // Handle scheme:path URLs like about:blank (no "://")
    if (protocol_end == null) {
        const colon_pos = std.mem.indexOfScalar(u8, raw, ':') orelse return "";
        const path = raw[colon_pos + 1 ..];
        const query_or_hash = std.mem.indexOfAny(u8, path, "?#") orelse path.len;
        return path[0..query_or_hash];
    }

    const path_start = std.mem.indexOfScalarPos(u8, raw, protocol_end.? + 3, '/') orelse raw.len;

    const query_or_hash_start = std.mem.indexOfAnyPos(u8, raw, path_start, "?#") orelse raw.len;

    if (path_start >= query_or_hash_start) {
        const protocol = getProtocol(raw);
        if (isSpecialScheme(protocol)) return "/";
        return "";
    }

    return raw[path_start..query_or_hash_start];
}

pub fn getProtocol(raw: [:0]const u8) []const u8 {
    const pos = std.mem.indexOfScalarPos(u8, raw, 0, ':') orelse return "";
    return raw[0 .. pos + 1];
}

pub fn isHTTPS(raw: [:0]const u8) bool {
    return std.mem.startsWith(u8, raw, "https:");
}

/// True for origins that may set or send Secure cookies (https and wss).
pub fn isSecureOrigin(raw: [:0]const u8) bool {
    return std.mem.startsWith(u8, raw, "https:") or std.mem.startsWith(u8, raw, "wss:");
}

pub fn getHostname(raw: [:0]const u8) []const u8 {
    const host = getHost(raw);
    const port_sep = findPortSeparator(host) orelse return host;
    return host[0..port_sep];
}

pub fn getPort(raw: [:0]const u8) []const u8 {
    const host = getHost(raw);
    const port_sep = findPortSeparator(host) orelse return "";
    return host[port_sep + 1 ..];
}

// Finds the colon separating host from port, handling IPv6 bracket notation.
// For IPv6 like "[::1]:8080", returns position of ":" after "]".
// For IPv6 like "[::1]" (no port), returns null.
// For regular hosts, returns position of last ":" if followed by digits.
fn findPortSeparator(host: []const u8) ?usize {
    if (host.len > 0 and host[0] == '[') {
        // IPv6: find closing bracket, port separator must be after it
        const bracket_end = std.mem.indexOfScalar(u8, host, ']') orelse return null;
        if (bracket_end + 1 < host.len and host[bracket_end + 1] == ':') {
            return bracket_end + 1;
        }
        return null;
    }

    // Regular host: find last colon and verify it's followed by digits
    const pos = std.mem.lastIndexOfScalar(u8, host, ':') orelse return null;
    if (pos + 1 >= host.len) return null;

    for (host[pos + 1 ..]) |c| {
        if (c < '0' or c > '9') return null;
    }
    return pos;
}

fn findQueryStartFrom(raw: []const u8, from: usize) ?usize {
    const hash_pos = std.mem.indexOfScalarPos(u8, raw, from, '#') orelse raw.len;
    const pos = std.mem.indexOfScalarPos(u8, raw, from, '?') orelse return null;
    if (pos >= hash_pos) return null;
    return pos;
}

pub fn getSearch(raw: [:0]const u8) []const u8 {
    const pos = findQueryStartFrom(raw, 0) orelse return "";
    const query_end = std.mem.indexOfScalarPos(u8, raw, pos, '#') orelse raw.len;
    if (pos + 1 >= query_end) return "";
    return raw[pos..query_end];
}

fn getSearchSerialized(raw: []const u8) []const u8 {
    const pos = findQueryStartFrom(raw, 0) orelse return "";
    const query_end = std.mem.indexOfScalarPos(u8, raw, pos, '#') orelse raw.len;
    return raw[pos..query_end];
}

pub fn getHash(raw: [:0]const u8) []const u8 {
    const start = std.mem.indexOfScalarPos(u8, raw, 0, '#') orelse return "";
    if (start + 1 >= raw.len) return "";
    return raw[start..];
}

fn getHashSerialized(raw: []const u8) []const u8 {
    const start = std.mem.indexOfScalarPos(u8, raw, 0, '#') orelse return "";
    return raw[start..];
}

/// Returns `url` without its fragment (Fetch response URL serialization).
pub fn withoutFragment(allocator: Allocator, url: []const u8) ![:0]const u8 {
    const end = std.mem.indexOfScalar(u8, url, '#') orelse url.len;
    return try allocator.dupeZ(u8, url[0..end]);
}

pub fn getOrigin(allocator: Allocator, raw: [:0]const u8) !?[]const u8 {
    if (std.mem.startsWith(u8, raw, "blob:")) {
        const inner = raw["blob:".len..];
        if (inner.len == 0) return null;
        if (!std.mem.startsWith(u8, inner, "http://") and !std.mem.startsWith(u8, inner, "https://")) {
            return null;
        }
        const inner_z = try allocator.dupeZ(u8, inner);
        return getOrigin(allocator, inner_z);
    }

    const scheme_end = std.mem.indexOf(u8, raw, "://") orelse return null;
    const protocol = raw[0 .. scheme_end + 1];
    if (!originBearingScheme(protocol)) return null;

    const auth = parseAuthority(raw) orelse return null;
    const has_user_info = auth.has_user_info;
    var host_part = auth.getHost(raw);

    if (host_part.len > 0 and host_part[host_part.len - 1] == ':' and host_part[0] != '[') {
        host_part = host_part[0 .. host_part.len - 1];
    } else if (findPortSeparator(host_part)) |sep| {
        if (host_part[sep + 1 ..].len == 0) {
            host_part = host_part[0..sep];
        }
    }

    const port_sep = findPortSeparator(host_part);
    const hostname = if (port_sep) |sep| host_part[0..sep] else host_part;
    const port = if (port_sep) |sep| host_part[sep + 1 ..] else "";

    const drop_port = if (port.len > 0) blk: {
        const port_num = parsePortNumber(port) orelse break :blk false;
        break :blk isDefaultPort(protocol, port_num);
    } else false;
    const origin_host = if (drop_port) hostname else host_part;

    var needs_lower = false;
    if (hostname.len > 0 and hostname[0] != '[') {
        for (hostname) |c| {
            if (c >= 'A' and c <= 'Z') {
                needs_lower = true;
                break;
            }
        }
    }

    if (!has_user_info and !drop_port and !needs_lower) {
        return raw[0 .. auth.host_start + origin_host.len];
    }

    var buf = try std.ArrayList(u8).initCapacity(allocator, 64);
    try buf.appendSlice(allocator, protocol);
    try buf.appendSlice(allocator, "//");
    try appendLowercaseOriginHost(&buf, allocator, origin_host);
    return try buf.toOwnedSlice(allocator);
}

fn getUserInfo(raw: [:0]const u8) ?[]const u8 {
    const auth = parseAuthority(raw) orelse return null;
    if (!auth.has_user_info) return null;

    // User info is from authority_start to host_start - 1 (excluding the @)
    const scheme_end = std.mem.indexOf(u8, raw, "://").?;
    const authority_start = scheme_end + 3;
    return raw[authority_start .. auth.host_start - 1];
}

pub fn getHost(raw: []const u8) []const u8 {
    const auth = parseAuthority(raw) orelse return "";
    return auth.getHost(raw);
}

// Returns true if these two URLs point to the same document.
pub fn eqlDocument(first: [:0]const u8, second: [:0]const u8) bool {
    // First '#' signifies the start of the fragment.
    const first_hash_index = std.mem.indexOfScalar(u8, first, '#') orelse first.len;
    const second_hash_index = std.mem.indexOfScalar(u8, second, '#') orelse second.len;
    return std.mem.eql(u8, first[0..first_hash_index], second[0..second_hash_index]);
}

// Helper function to build a URL from components
pub fn buildUrl(
    allocator: Allocator,
    protocol: []const u8,
    host: []const u8,
    pathname: []const u8,
    search: []const u8,
    hash: []const u8,
) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(allocator, "{s}//{s}{s}{s}{s}", .{
        protocol,
        host,
        pathname,
        search,
        hash,
    }, 0);
}

/// URL Standard protocol setter: basic URL parser with scheme start state.
/// Strips leading C0/space, lowercases ASCII scheme, validates, then applies
/// special-scheme / cannot-be-a-base / file-empty-host rules (no test hardcoding).
pub fn setProtocol(current: [:0]const u8, value: []const u8, allocator: Allocator) ![:0]const u8 {
    // 1) leading C0 controls + spaces (URL basic URL parser buffer prep)
    var i: usize = 0;
    while (i < value.len and isC0ControlOrSpace(value[i])) : (i += 1) {}
    const trimmed = value[i..];

    // 2) collect scheme characters; trailing ':' is optional in the setter input
    var end: usize = 0;
    while (end < trimmed.len) : (end += 1) {
        const c = trimmed[end];
        if (c == ':') break;
        // scheme state: ALPHA / DIGIT / + / - / .
        const ok = std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.';
        if (!ok) {
            // invalid scheme → no-op
            return allocator.dupeZ(u8, current);
        }
    }
    const scheme_raw = trimmed[0..end];
    if (scheme_raw.len == 0) {
        // empty scheme (including empty string after strip) → no-op
        return allocator.dupeZ(u8, current);
    }
    if (!std.ascii.isAlphabetic(scheme_raw[0])) {
        return allocator.dupeZ(u8, current);
    }

    // 3) lowercase ASCII scheme + colon
    var scheme_buf: [64]u8 = undefined;
    if (scheme_raw.len >= scheme_buf.len) return allocator.dupeZ(u8, current);
    for (scheme_raw, 0..) |c, idx| {
        scheme_buf[idx] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    scheme_buf[scheme_raw.len] = ':';
    const protocol = scheme_buf[0 .. scheme_raw.len + 1];

    const pathname = getPathname(current);
    const search = getSearch(current);
    const hash = getHash(current);
    const current_protocol = getProtocol(current);
    const new_is_special = isSpecialScheme(protocol);

    // cannot-be-a-base-URL: special scheme switch is a no-op; non-special rewrites scheme.
    if (isCannotBeABase(current)) {
        if (new_is_special) return allocator.dupeZ(u8, current);
        return buildOpaqueUrl(allocator, protocol, pathname, search, hash);
    }

    // file URL with empty / localhost host cannot switch to another special scheme
    // (URL Standard: "file" + no host).
    if (std.ascii.eqlIgnoreCase(current_protocol, "file:")) {
        const host = getHost(current);
        const empty_or_localhost = host.len == 0 or std.ascii.eqlIgnoreCase(host, "localhost");
        if (empty_or_localhost and new_is_special and !std.ascii.eqlIgnoreCase(protocol, "file:")) {
            return allocator.dupeZ(u8, current);
        }
    }

    // Cannot switch to file: if URL has username, password, or non-default port
    // (URL Standard protocol setter).
    if (std.ascii.eqlIgnoreCase(protocol, "file:")) {
        const username = getUsername(current);
        const password = getPassword(current);
        const port = getPort(current);
        if (username.len > 0 or password.len > 0 or port.len > 0) {
            return allocator.dupeZ(u8, current);
        }
    }

    const host = getHost(current);
    return buildUrl(allocator, protocol, host, pathname, search, hash);
}

pub fn setHost(current: [:0]const u8, value: []const u8, allocator: Allocator) ![:0]const u8 {
    if (isCannotBeABase(current)) return allocator.dupeZ(u8, current);
    const protocol = getProtocol(current);
    const pathname = getPathname(current);
    const search = getSearch(current);
    const hash = getHash(current);

    // Check if the new value includes a port
    const colon_pos = std.mem.lastIndexOfScalar(u8, value, ':');
    const clean_host = if (colon_pos) |pos| blk: {
        const port_str = value[pos + 1 ..];
        // Remove default ports
        if (std.mem.eql(u8, protocol, "https:") and std.mem.eql(u8, port_str, "443")) {
            break :blk value[0..pos];
        }
        if (std.mem.eql(u8, protocol, "http:") and std.mem.eql(u8, port_str, "80")) {
            break :blk value[0..pos];
        }
        break :blk value;
    } else blk: {
        // No port in new value - preserve existing port
        const current_port = getPort(current);
        if (current_port.len > 0) {
            break :blk try std.fmt.allocPrint(allocator, "{s}:{s}", .{ value, current_port });
        }
        break :blk value;
    };

    return buildUrl(allocator, protocol, clean_host, pathname, search, hash);
}

pub fn setHostname(current: [:0]const u8, value: []const u8, allocator: Allocator) ![:0]const u8 {
    if (isCannotBeABase(current)) return allocator.dupeZ(u8, current);
    const current_port = getPort(current);
    const new_host = if (current_port.len > 0)
        try std.fmt.allocPrint(allocator, "{s}:{s}", .{ value, current_port })
    else
        value;

    return setHost(current, new_host, allocator);
}

pub fn setPort(current: [:0]const u8, value: ?[]const u8, allocator: Allocator) ![:0]const u8 {
    if (isCannotBeABase(current)) return allocator.dupeZ(u8, current);
    const hostname = getHostname(current);
    const protocol = getProtocol(current);
    const pathname = getPathname(current);
    const search = getSearch(current);
    const hash = getHash(current);

    // Handle null or default ports
    const new_host = if (value) |port_str| blk: {
        if (port_str.len == 0) {
            break :blk hostname;
        }
        // Check if this is a default port for the protocol
        if (std.mem.eql(u8, protocol, "https:") and std.mem.eql(u8, port_str, "443")) {
            break :blk hostname;
        }
        if (std.mem.eql(u8, protocol, "http:") and std.mem.eql(u8, port_str, "80")) {
            break :blk hostname;
        }
        break :blk try std.fmt.allocPrint(allocator, "{s}:{s}", .{ hostname, port_str });
    } else hostname;

    return buildUrl(allocator, protocol, new_host, pathname, search, hash);
}

pub fn setPathname(current: [:0]const u8, value: []const u8, allocator: Allocator) ![:0]const u8 {
    if (isCannotBeABase(current)) return allocator.dupeZ(u8, current);
    const protocol = getProtocol(current);
    const host = getHost(current);
    const search = getSearch(current);
    const hash = getHash(current);

    const encoded = try percentEncodeSegment(allocator, value, .path);

    // Add / prefix if not present and value is not empty
    const pathname = if (encoded.len > 0 and encoded[0] != '/')
        try std.fmt.allocPrint(allocator, "/{s}", .{encoded})
    else
        encoded;

    return buildUrl(allocator, protocol, host, pathname, search, hash);
}

pub fn setSearch(current: [:0]const u8, value: []const u8, allocator: Allocator) ![:0]const u8 {
    const protocol = getProtocol(current);
    const pathname = getPathname(current);
    const hash = getHash(current);

    const encoded = try percentEncodeSegment(allocator, value, .query);

    // Add ? prefix if not present and value is not empty
    const search = if (encoded.len > 0 and value[0] != '?')
        try std.fmt.allocPrint(allocator, "?{s}", .{encoded})
    else
        encoded;

    if (isCannotBeABase(current)) {
        return buildOpaqueUrl(allocator, protocol, pathname, search, hash);
    }

    const host = getHost(current);
    return buildUrl(allocator, protocol, host, pathname, search, hash);
}

pub fn setHash(current: [:0]const u8, value: []const u8, allocator: Allocator) ![:0]const u8 {
    const protocol = getProtocol(current);
    const pathname = getPathname(current);
    const search = getSearch(current);

    const encoded = try percentEncodeSegment(allocator, value, .fragment);

    // Add # prefix if not present and value is not empty
    const hash = if (encoded.len > 0 and encoded[0] != '#')
        try std.fmt.allocPrint(allocator, "#{s}", .{encoded})
    else
        encoded;

    if (isCannotBeABase(current)) {
        return buildOpaqueUrl(allocator, protocol, pathname, search, hash);
    }

    const host = getHost(current);
    return buildUrl(allocator, protocol, host, pathname, search, hash);
}

pub fn setUsername(current: [:0]const u8, value: []const u8, allocator: Allocator) ![:0]const u8 {
    if (isCannotBeABase(current)) return allocator.dupeZ(u8, current);
    const protocol = getProtocol(current);
    const host = getHost(current);
    const pathname = getPathname(current);
    const search = getSearch(current);
    const hash = getHash(current);
    const password = getPassword(current);

    const encoded_username = try percentEncodeSegment(allocator, value, .userinfo);
    return buildUrlWithUserInfo(allocator, protocol, encoded_username, password, host, pathname, search, hash);
}

pub fn setPassword(current: [:0]const u8, value: []const u8, allocator: Allocator) ![:0]const u8 {
    if (isCannotBeABase(current)) return allocator.dupeZ(u8, current);
    const protocol = getProtocol(current);
    const host = getHost(current);
    const pathname = getPathname(current);
    const search = getSearch(current);
    const hash = getHash(current);
    const username = getUsername(current);

    const encoded_password = try percentEncodeSegment(allocator, value, .userinfo);
    return buildUrlWithUserInfo(allocator, protocol, username, encoded_password, host, pathname, search, hash);
}

fn buildUrlWithUserInfo(
    allocator: Allocator,
    protocol: []const u8,
    username: []const u8,
    password: []const u8,
    host: []const u8,
    pathname: []const u8,
    search: []const u8,
    hash: []const u8,
) ![:0]const u8 {
    if (username.len == 0 and password.len == 0) {
        return buildUrl(allocator, protocol, host, pathname, search, hash);
    } else if (password.len == 0) {
        return std.fmt.allocPrintSentinel(allocator, "{s}//{s}@{s}{s}{s}{s}", .{
            protocol,
            username,
            host,
            pathname,
            search,
            hash,
        }, 0);
    } else {
        return std.fmt.allocPrintSentinel(allocator, "{s}//{s}:{s}@{s}{s}{s}{s}", .{
            protocol,
            username,
            password,
            host,
            pathname,
            search,
            hash,
        }, 0);
    }
}

pub fn concatQueryString(arena: Allocator, url: []const u8, query_string: []const u8) ![:0]const u8 {
    if (query_string.len == 0) {
        return arena.dupeZ(u8, url);
    }

    var buf: std.ArrayList(u8) = .empty;

    // the most space well need is the url + ('?' or '&') + the query_string + null terminator
    try buf.ensureTotalCapacity(arena, url.len + 2 + query_string.len);
    buf.appendSliceAssumeCapacity(url);

    if (std.mem.indexOfScalar(u8, url, '?')) |index| {
        const last_index = url.len - 1;
        if (index != last_index and url[last_index] != '&') {
            buf.appendAssumeCapacity('&');
        }
    } else {
        buf.appendAssumeCapacity('?');
    }
    buf.appendSliceAssumeCapacity(query_string);
    buf.appendAssumeCapacity(0);
    return buf.items[0 .. buf.items.len - 1 :0];
}

pub fn getRobotsUrl(arena: Allocator, url: [:0]const u8) ![:0]const u8 {
    const origin = try getOrigin(arena, url) orelse return error.NoOrigin;
    return try std.fmt.allocPrintSentinel(
        arena,
        "{s}/robots.txt",
        .{origin},
        0,
    );
}

pub fn unescape(arena: Allocator, input: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, input, '%') == null) {
        return input;
    }

    // Determine the exact decoded size before allocating. Callers that receive
    // an allocated result must be able to release it using the returned slice;
    // allocating input.len and returning a shorter view violates that contract
    // for allocators which validate the free size.
    var decoded_len = input.len;
    var size_index: usize = 0;
    while (size_index < input.len) {
        if (input[size_index] == '%' and size_index + 2 < input.len) {
            _ = std.fmt.parseInt(u8, input[size_index + 1 .. size_index + 3], 16) catch {
                size_index += 1;
                continue;
            };
            decoded_len -= 2;
            size_index += 3;
        } else {
            size_index += 1;
        }
    }

    const result = try arena.alloc(u8, decoded_len);

    var i: usize = 0;
    var output_index: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hex = input[i + 1 .. i + 3];
            const byte = std.fmt.parseInt(u8, hex, 16) catch {
                result[output_index] = input[i];
                output_index += 1;
                i += 1;
                continue;
            };
            result[output_index] = byte;
            output_index += 1;
            i += 3;
        } else {
            result[output_index] = input[i];
            output_index += 1;
            i += 1;
        }
    }

    return result;
}

const AuthorityInfo = struct {
    host_start: usize,
    host_end: usize,
    has_user_info: bool,

    fn getHost(self: AuthorityInfo, raw: []const u8) []const u8 {
        return raw[self.host_start..self.host_end];
    }
};

// Parses the authority component of a URL, correctly handling userinfo.
// Returns null if the URL doesn't have a valid scheme (no "://").
// SECURITY: Only looks for @ within the authority portion (before /?#)
// to prevent path-based @ injection attacks.
fn parseAuthority(raw: []const u8) ?AuthorityInfo {
    const scheme_end = std.mem.indexOf(u8, raw, "://") orelse return null;
    const authority_start = scheme_end + 3;

    // Find end of authority FIRST (start of path/query/fragment or end of string)
    const authority_end = if (std.mem.indexOfAny(u8, raw[authority_start..], "/?#")) |end|
        authority_start + end
    else
        raw.len;

    // Only look for @ within the authority portion, not in path/query/fragment
    const authority_portion = raw[authority_start..authority_end];
    if (std.mem.lastIndexOf(u8, authority_portion, "@")) |pos| {
        return .{
            .host_start = authority_start + pos + 1,
            .host_end = authority_end,
            .has_user_info = true,
        };
    }

    return .{
        .host_start = authority_start,
        .host_end = authority_end,
        .has_user_info = false,
    };
}

const testing = @import("../../testing/testing.zig");
test "URL: isCompleteHTTPUrl" {
    try testing.expectEqual(true, isCompleteHTTPUrl("http://example.com/about"));
    try testing.expectEqual(true, isCompleteHTTPUrl("HttP://example.com/about"));
    try testing.expectEqual(true, isCompleteHTTPUrl("httpS://example.com/about"));
    try testing.expectEqual(true, isCompleteHTTPUrl("HTTPs://example.com/about"));
    try testing.expectEqual(true, isCompleteHTTPUrl("ftp://example.com/about"));

    try testing.expectEqual(false, isCompleteHTTPUrl("/example.com"));
    try testing.expectEqual(false, isCompleteHTTPUrl("../../about"));
    try testing.expectEqual(false, isCompleteHTTPUrl("about"));
}

test "URL: resolve regression (#1093)" {
    defer testing.reset();

    const Case = struct {
        base: [:0]const u8,
        path: [:0]const u8,
        expected: [:0]const u8,
    };

    const cases = [_]Case{
        .{
            .base = "https://alas.aws.amazon.com/alas2.html",
            .path = "../static/bootstrap.min.css",
            .expected = "https://alas.aws.amazon.com/static/bootstrap.min.css",
        },
    };

    for (cases) |case| {
        const result = try resolve(testing.arena_allocator, case.base, case.path, .{});
        try testing.expectString(case.expected, result);
    }
}

test "URL: resolve" {
    defer testing.reset();

    const Case = struct {
        base: [:0]const u8,
        path: [:0]const u8,
        expected: [:0]const u8,
    };

    const cases = [_]Case{
        .{
            .base = "https://example/dir",
            .path = "abc../test",
            .expected = "https://example/abc../test",
        },
        .{
            .base = "https://example/dir",
            .path = "abc.",
            .expected = "https://example/abc.",
        },
        .{
            .base = "https://example/dir",
            .path = "abc/.",
            .expected = "https://example/abc/",
        },
        .{
            .base = "https://example/xyz/abc/123",
            .path = "something.js",
            .expected = "https://example/xyz/abc/something.js",
        },
        .{
            .base = "https://example/xyz/abc/123",
            .path = "/something.js",
            .expected = "https://example/something.js",
        },
        .{
            .base = "https://example/",
            .path = "something.js",
            .expected = "https://example/something.js",
        },
        .{
            .base = "https://example/",
            .path = "/something.js",
            .expected = "https://example/something.js",
        },
        .{
            .base = "https://example",
            .path = "something.js",
            .expected = "https://example/something.js",
        },
        .{
            .base = "https://example",
            .path = "abc/something.js",
            .expected = "https://example/abc/something.js",
        },
        .{
            .base = "https://example/nested",
            .path = "abc/something.js",
            .expected = "https://example/abc/something.js",
        },
        .{
            .base = "https://example/nested/",
            .path = "abc/something.js",
            .expected = "https://example/nested/abc/something.js",
        },
        .{
            .base = "https://example/nested/",
            .path = "/abc/something.js",
            .expected = "https://example/abc/something.js",
        },
        .{
            .base = "https://example/nested/",
            .path = "http://www.github.com/example/",
            .expected = "http://www.github.com/example/",
        },
        .{
            .base = "https://example/nested/",
            .path = "",
            .expected = "https://example/nested/",
        },
        .{
            .base = "https://example/abc/aaa",
            .path = "./hello/./world",
            .expected = "https://example/abc/hello/world",
        },
        .{
            .base = "https://example/abc/aaa/",
            .path = "../hello",
            .expected = "https://example/abc/hello",
        },
        .{
            .base = "https://example/abc/aaa",
            .path = "../hello",
            .expected = "https://example/hello",
        },
        .{
            .base = "https://example/abc/aaa/",
            .path = "./.././.././hello",
            .expected = "https://example/hello",
        },
        .{
            .base = "some/page",
            .path = "hello",
            .expected = "some/hello",
        },
        .{
            .base = "some/page/",
            .path = "hello",
            .expected = "some/page/hello",
        },
        .{
            .base = "some/page/other",
            .path = ".././hello",
            .expected = "some/hello",
        },
        .{
            .base = "https://www.example.com/hello/world",
            .path = "//example/about",
            .expected = "https://example/about",
        },
        .{
            .base = "http:",
            .path = "//example.com/over/9000",
            .expected = "http://example.com/over/9000",
        },
        .{
            .base = "https://example.com/",
            .path = "../hello",
            .expected = "https://example.com/hello",
        },
        .{
            .base = "https://www.example.com/hello/world/",
            .path = "../../../../example/about",
            .expected = "https://www.example.com/example/about",
        },
    };

    for (cases) |case| {
        const result = try resolve(testing.arena_allocator, case.base, case.path, .{});
        try testing.expectString(case.expected, result);
    }
}

test "URL: ensureEncoded" {
    defer testing.reset();

    const Case = struct {
        url: [:0]const u8,
        expected: [:0]const u8,
    };

    const cases = [_]Case{
        .{
            .url = "https://example.com/over 9000!",
            .expected = "https://example.com/over%209000!",
        },
        .{
            .url = "http://example.com/hello world.html",
            .expected = "http://example.com/hello%20world.html",
        },
        .{
            .url = "https://example.com/file[1].html",
            .expected = "https://example.com/file[1].html",
        },
        .{
            .url = "https://example.com/file{name}.html",
            .expected = "https://example.com/file%7Bname%7D.html",
        },
        .{
            .url = "https://example.com/page?query=hello world",
            .expected = "https://example.com/page?query=hello%20world",
        },
        .{
            .url = "https://example.com/page?a=1&b=value with spaces",
            .expected = "https://example.com/page?a=1&b=value%20with%20spaces",
        },
        .{
            .url = "https://example.com/page#section one",
            .expected = "https://example.com/page#section%20one",
        },
        .{
            .url = "https://example.com/my path?query=my value#my anchor",
            .expected = "https://example.com/my%20path?query=my%20value#my%20anchor",
        },
        .{
            .url = "https://example.com/already%20encoded",
            .expected = "https://example.com/already%20encoded",
        },
        .{
            .url = "https://example.com/file%5B1%5D.html",
            .expected = "https://example.com/file%5B1%5D.html",
        },
        .{
            .url = "https://example.com/caf%C3%A9",
            .expected = "https://example.com/caf%C3%A9",
        },
        .{
            .url = "https://example.com/page?query=already%20encoded",
            .expected = "https://example.com/page?query=already%20encoded",
        },
        .{
            .url = "https://example.com/page?a=1&b=value%20here",
            .expected = "https://example.com/page?a=1&b=value%20here",
        },
        .{
            .url = "https://example.com/page#section%20one",
            .expected = "https://example.com/page#section%20one",
        },
        .{
            .url = "https://example.com/part%20encoded and not",
            .expected = "https://example.com/part%20encoded%20and%20not",
        },
        .{
            .url = "https://example.com/page?a=encoded%20value&b=not encoded",
            .expected = "https://example.com/page?a=encoded%20value&b=not%20encoded",
        },
        .{
            .url = "https://example.com/my%20path?query=not encoded#encoded%20anchor",
            .expected = "https://example.com/my%20path?query=not%20encoded#encoded%20anchor",
        },
        .{
            .url = "https://example.com/fully%20encoded?query=also%20encoded#and%20this",
            .expected = "https://example.com/fully%20encoded?query=also%20encoded#and%20this",
        },
        .{
            .url = "https://example.com/path-with_under~tilde",
            .expected = "https://example.com/path-with_under~tilde",
        },
        .{
            .url = "https://example.com/sub-delims!$&'()*+,;=",
            .expected = "https://example.com/sub-delims!$&'()*+,;=",
        },
        .{
            .url = "https://example.com",
            .expected = "https://example.com",
        },
        .{
            .url = "https://example.com?query=value",
            .expected = "https://example.com?query=value",
        },
        .{
            .url = "https://example.com/clean/path",
            .expected = "https://example.com/clean/path",
        },
        .{
            .url = "https://example.com/path?clean=query#clean-fragment",
            .expected = "https://example.com/path?clean=query#clean-fragment",
        },
        .{
            .url = "https://example.com/100% complete",
            .expected = "https://example.com/100%%20complete",
        },
        .{
            .url = "https://example.com/path?value=100% done",
            .expected = "https://example.com/path?value=100%%20done",
        },
        .{
            .url = "about:blank",
            .expected = "about:blank",
        },
    };

    for (cases) |case| {
        const result = try ensureEncoded(testing.arena_allocator, case.url, "UTF-8");
        try testing.expectString(case.expected, result);
    }
}

test "URL: resolve with encoding" {
    defer testing.reset();

    const Case = struct {
        base: [:0]const u8,
        path: [:0]const u8,
        expected: [:0]const u8,
    };

    const cases = [_]Case{
        // Spaces should be encoded as %20, but ! is allowed
        .{
            .base = "https://example.com/dir/",
            .path = "over 9000!",
            .expected = "https://example.com/dir/over%209000!",
        },
        .{
            .base = "https://example.com/",
            .path = "hello world.html",
            .expected = "https://example.com/hello%20world.html",
        },
        // Multiple spaces
        .{
            .base = "https://example.com/",
            .path = "path with  multiple   spaces",
            .expected = "https://example.com/path%20with%20%20multiple%20%20%20spaces",
        },
        // Special characters that need encoding
        .{
            .base = "https://example.com/",
            .path = "file[1].html",
            .expected = "https://example.com/file[1].html",
        },
        .{
            .base = "https://example.com/",
            .path = "file{name}.html",
            .expected = "https://example.com/file%7Bname%7D.html",
        },
        .{
            .base = "https://example.com/",
            .path = "file<test>.html",
            .expected = "https://example.com/file%3Ctest%3E.html",
        },
        .{
            .base = "https://example.com/",
            .path = "file\"quote\".html",
            .expected = "https://example.com/file%22quote%22.html",
        },
        .{
            .base = "https://example.com/",
            .path = "file|pipe.html",
            .expected = "https://example.com/file|pipe.html",
        },
        .{
            .base = "https://example.com/",
            .path = "file\\backslash.html",
            .expected = "https://example.com/file/backslash.html",
        },
        .{
            .base = "https://example.com/",
            .path = "file^caret.html",
            .expected = "https://example.com/file%5Ecaret.html",
        },
        .{
            .base = "https://example.com/",
            .path = "file`backtick`.html",
            .expected = "https://example.com/file%60backtick%60.html",
        },
        // Characters that should NOT be encoded
        .{
            .base = "https://example.com/",
            .path = "path-with_under~tilde.html",
            .expected = "https://example.com/path-with_under~tilde.html",
        },
        .{
            .base = "https://example.com/",
            .path = "path/with/slashes",
            .expected = "https://example.com/path/with/slashes",
        },
        .{
            .base = "https://example.com/",
            .path = "sub-delims!$&'()*+,;=.html",
            .expected = "https://example.com/sub-delims!$&'()*+,;=.html",
        },
        // Already encoded characters should not be double-encoded
        .{
            .base = "https://example.com/",
            .path = "already%20encoded",
            .expected = "https://example.com/already%20encoded",
        },
        .{
            .base = "https://example.com/",
            .path = "file%5B1%5D.html",
            .expected = "https://example.com/file%5B1%5D.html",
        },
        // Mix of encoded and unencoded
        .{
            .base = "https://example.com/",
            .path = "part%20encoded and not",
            .expected = "https://example.com/part%20encoded%20and%20not",
        },
        // Query strings and fragments ARE encoded
        .{
            .base = "https://example.com/",
            .path = "file name.html?query=value with spaces",
            .expected = "https://example.com/file%20name.html?query=value%20with%20spaces",
        },
        .{
            .base = "https://example.com/",
            .path = "file name.html#anchor with spaces",
            .expected = "https://example.com/file%20name.html#anchor%20with%20spaces",
        },
        .{
            .base = "https://example.com/",
            .path = "file.html?hello=world !",
            .expected = "https://example.com/file.html?hello=world%20!",
        },
        // Query structural characters should NOT be encoded
        .{
            .base = "https://example.com/",
            .path = "file.html?a=1&b=2",
            .expected = "https://example.com/file.html?a=1&b=2",
        },
        // Relative paths with encoding
        .{
            .base = "https://example.com/dir/frame.html",
            .path = "../other dir/file.html",
            .expected = "https://example.com/other%20dir/file.html",
        },
        .{
            .base = "https://example.com/dir/",
            .path = "./sub dir/file.html",
            .expected = "https://example.com/dir/sub%20dir/file.html",
        },
        // Absolute paths with encoding
        .{
            .base = "https://example.com/some/path",
            .path = "/absolute path/file.html",
            .expected = "https://example.com/absolute%20path/file.html",
        },
        // Unicode/high bytes (though ideally these should be UTF-8 encoded first)
        .{
            .base = "https://example.com/",
            .path = "café",
            .expected = "https://example.com/caf%C3%A9",
        },
        // Empty path
        .{
            .base = "https://example.com/",
            .path = "",
            .expected = "https://example.com/",
        },
        // Complete URL as path (should not be encoded)
        .{
            .base = "https://example.com/",
            .path = "https://other.com/path with spaces",
            .expected = "https://other.com/path%20with%20spaces",
        },
    };

    for (cases) |case| {
        const result = try resolve(testing.arena_allocator, case.base, case.path, .{ .encoding = "UTF-8" });
        try testing.expectString(case.expected, result);
    }
}

test "URL: eqlDocument" {
    defer testing.reset();
    {
        const url = "https://kokoio.com/about";
        try testing.expectEqual(true, eqlDocument(url, url));
    }
    {
        const url1 = "https://kokoio.com/about";
        const url2 = "http://kokoio.com/about";
        try testing.expectEqual(false, eqlDocument(url1, url2));
    }
    {
        const url1 = "https://kokoio.com/about";
        const url2 = "https://example.com/about";
        try testing.expectEqual(false, eqlDocument(url1, url2));
    }
    {
        const url1 = "https://kokoio.com:8080/about";
        const url2 = "https://kokoio.com:9090/about";
        try testing.expectEqual(false, eqlDocument(url1, url2));
    }
    {
        const url1 = "https://kokoio.com/about";
        const url2 = "https://kokoio.com/contact";
        try testing.expectEqual(false, eqlDocument(url1, url2));
    }
    {
        const url1 = "https://kokoio.com/about?foo=bar";
        const url2 = "https://kokoio.com/about?baz=qux";
        try testing.expectEqual(false, eqlDocument(url1, url2));
    }
    {
        const url1 = "https://kokoio.com/about#section1";
        const url2 = "https://kokoio.com/about#section2";
        try testing.expectEqual(true, eqlDocument(url1, url2));
    }
    {
        const url1 = "https://kokoio.com/about";
        const url2 = "https://kokoio.com/about/";
        try testing.expectEqual(false, eqlDocument(url1, url2));
    }
    {
        const url1 = "https://kokoio.com/about?foo=bar";
        const url2 = "https://kokoio.com/about";
        try testing.expectEqual(false, eqlDocument(url1, url2));
    }
    {
        const url1 = "https://kokoio.com/about";
        const url2 = "https://kokoio.com/about?foo=bar";
        try testing.expectEqual(false, eqlDocument(url1, url2));
    }
    {
        const url1 = "https://kokoio.com/about?foo=bar";
        const url2 = "https://kokoio.com/about?foo=bar";
        try testing.expectEqual(true, eqlDocument(url1, url2));
    }
    {
        const url1 = "https://kokoio.com/about?";
        const url2 = "https://kokoio.com/about";
        try testing.expectEqual(false, eqlDocument(url1, url2));
    }
    {
        const url1 = "https://duckduckgo.com/";
        const url2 = "https://duckduckgo.com/?q=koko";
        try testing.expectEqual(false, eqlDocument(url1, url2));
    }
}

test "URL: concatQueryString" {
    defer testing.reset();
    const arena = testing.arena_allocator;

    {
        const url = try concatQueryString(arena, "https://www.kokoio.com/", "");
        try testing.expectEqual("https://www.kokoio.com/", url);
    }

    {
        const url = try concatQueryString(arena, "https://www.kokoio.com/index?", "");
        try testing.expectEqual("https://www.kokoio.com/index?", url);
    }

    {
        const url = try concatQueryString(arena, "https://www.kokoio.com/index?", "a=b");
        try testing.expectEqual("https://www.kokoio.com/index?a=b", url);
    }

    {
        const url = try concatQueryString(arena, "https://www.kokoio.com/index?1=2", "a=b");
        try testing.expectEqual("https://www.kokoio.com/index?1=2&a=b", url);
    }

    {
        const url = try concatQueryString(arena, "https://www.kokoio.com/index?1=2&", "a=b");
        try testing.expectEqual("https://www.kokoio.com/index?1=2&a=b", url);
    }
}

test "URL: getRobotsUrl" {
    defer testing.reset();
    const arena = testing.arena_allocator;

    {
        const url = try getRobotsUrl(arena, "https://www.kokoio.com");
        try testing.expectEqual("https://www.kokoio.com/robots.txt", url);
    }

    {
        const url = try getRobotsUrl(arena, "https://www.kokoio.com/some/path");
        try testing.expectString("https://www.kokoio.com/robots.txt", url);
    }

    {
        const url = try getRobotsUrl(arena, "https://www.kokoio.com:8080/page");
        try testing.expectString("https://www.kokoio.com:8080/robots.txt", url);
    }
    {
        const url = try getRobotsUrl(arena, "http://example.com/deep/nested/path?query=value#fragment");
        try testing.expectString("http://example.com/robots.txt", url);
    }
    {
        const url = try getRobotsUrl(arena, "https://user:pass@example.com/page");
        try testing.expectString("https://example.com/robots.txt", url);
    }
}

test "URL: unescape" {
    defer testing.reset();
    const arena = testing.arena_allocator;

    {
        const result = try unescape(arena, "hello world");
        try testing.expectEqual("hello world", result);
    }

    {
        const result = try unescape(arena, "hello%20world");
        try testing.expectEqual("hello world", result);
    }

    {
        const result = try unescape(arena, "%48%65%6c%6c%6f");
        try testing.expectEqual("Hello", result);
    }

    {
        const result = try unescape(arena, "%48%65%6C%6C%6F");
        try testing.expectEqual("Hello", result);
    }

    {
        const result = try unescape(arena, "a%3Db");
        try testing.expectEqual("a=b", result);
    }

    {
        const result = try unescape(arena, "a%3DB");
        try testing.expectEqual("a=B", result);
    }

    {
        const result = try unescape(arena, "ZDIgPSAndHdvJzs%3D");
        try testing.expectEqual("ZDIgPSAndHdvJzs=", result);
    }

    {
        const result = try unescape(arena, "%5a%44%4d%67%50%53%41%6e%64%47%68%79%5a%57%55%6e%4f%77%3D%3D");
        try testing.expectEqual("ZDMgPSAndGhyZWUnOw==", result);
    }

    {
        const result = try unescape(arena, "hello%2world");
        try testing.expectEqual("hello%2world", result);
    }

    {
        const result = try unescape(arena, "hello%ZZworld");
        try testing.expectEqual("hello%ZZworld", result);
    }

    {
        const result = try unescape(arena, "hello%");
        try testing.expectEqual("hello%", result);
    }

    {
        const result = try unescape(arena, "hello%2");
        try testing.expectEqual("hello%2", result);
    }
}

test "URL: unescape returns exactly sized owned storage when decoding" {
    const result = try unescape(std.testing.allocator, "hello%20world");
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("hello world", result);
}

test "URL: getHost" {
    try testing.expectEqualSlices(u8, "example.com:8080", getHost("https://example.com:8080/path"));
    try testing.expectEqualSlices(u8, "example.com", getHost("https://example.com/path"));
    try testing.expectEqualSlices(u8, "example.com:443", getHost("https://example.com:443/"));
    try testing.expectEqualSlices(u8, "example.com", getHost("https://user:pass@example.com/page"));
    try testing.expectEqualSlices(u8, "example.com:8080", getHost("https://user:pass@example.com:8080/page"));
    try testing.expectEqualSlices(u8, "", getHost("not-a-url"));

    // SECURITY: @ in path must NOT be treated as userinfo separator
    try testing.expectEqualSlices(u8, "evil.example.com", getHost("http://evil.example.com/@victim.example.com/"));
    try testing.expectEqualSlices(u8, "evil.example.com", getHost("https://evil.example.com/path/@victim.example.com"));

    // IPv6 addresses
    try testing.expectEqualSlices(u8, "[::1]:8080", getHost("http://[::1]:8080/path"));
    try testing.expectEqualSlices(u8, "[::1]", getHost("http://[::1]/path"));
    try testing.expectEqualSlices(u8, "[2001:db8::1]", getHost("https://[2001:db8::1]/"));
}

test "URL: getHostname" {
    // Regular hosts
    try testing.expectEqualSlices(u8, "example.com", getHostname("https://example.com:8080/path"));
    try testing.expectEqualSlices(u8, "example.com", getHostname("https://example.com/path"));

    // IPv6 with port
    try testing.expectEqualSlices(u8, "[::1]", getHostname("http://[::1]:8080/path"));

    // IPv6 without port - must return full bracket notation
    try testing.expectEqualSlices(u8, "[::1]", getHostname("http://[::1]/path"));
    try testing.expectEqualSlices(u8, "[2001:db8::1]", getHostname("https://[2001:db8::1]/"));
}

test "URL: getPort" {
    // Regular hosts
    try testing.expectEqualSlices(u8, "8080", getPort("https://example.com:8080/path"));
    try testing.expectEqualSlices(u8, "", getPort("https://example.com/path"));

    // IPv6 with port
    try testing.expectEqualSlices(u8, "8080", getPort("http://[::1]:8080/path"));
    try testing.expectEqualSlices(u8, "3000", getPort("http://[2001:db8::1]:3000/"));

    // IPv6 without port - colons inside brackets must not be treated as port separator
    try testing.expectEqualSlices(u8, "", getPort("http://[::1]/path"));
    try testing.expectEqualSlices(u8, "", getPort("https://[2001:db8::1]/"));
}

test "URL: setPathname percent-encodes" {
    // Use arena allocator to match production usage (setPathname makes intermediate allocations)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Spaces must be encoded as %20
    const result1 = try setPathname("http://a/", "c d", allocator);
    try testing.expectEqualSlices(u8, "http://a/c%20d", result1);

    // Already-encoded sequences must not be double-encoded
    const result2 = try setPathname("https://example.com/path", "/already%20encoded", allocator);
    try testing.expectEqualSlices(u8, "https://example.com/already%20encoded", result2);

    // Query and hash must be preserved
    const result3 = try setPathname("https://example.com/path?a=b#hash", "/new path", allocator);
    try testing.expectEqualSlices(u8, "https://example.com/new%20path?a=b#hash", result3);
}

test "URL: canonicalize href userinfo and opaque" {
    defer testing.reset();
    const allocator = testing.arena_allocator;

    const result1 = try resolve(allocator, "", "https://test:@test", .{});
    try testing.expectEqualSlices(u8, "https://test@test/", result1);
    try testing.expectEqualSlices(u8, "test", getUsername(result1));

    const result2 = try resolve(allocator, "", "https://:@test", .{});
    try testing.expectEqualSlices(u8, "https://test/", result2);

    const result3 = try resolve(allocator, "http://doesnotmatter/", "https://@@@example", .{});
    try testing.expectEqualSlices(u8, "https://%40%40@example/", result3);
    try testing.expectEqualSlices(u8, "%40%40", getUsername(result3));

    const result4 = try resolve(allocator, "", "lolscheme:x x#x x", .{});
    try testing.expectEqualSlices(u8, "lolscheme:x x#x%20x", result4);

    try testing.expectError(error.TypeError, resolve(allocator, "http://example.org/", "http://f:b/c", .{ .always_dupe = true }));
}

test "URL: getOrigin" {
    defer testing.reset();

    const Case = struct {
        url: [:0]const u8,
        expected: ?[]const u8,
    };

    const cases = [_]Case{
        // Basic HTTP/HTTPS origins
        .{ .url = "http://example.com/path", .expected = "http://example.com" },
        .{ .url = "https://example.com/path", .expected = "https://example.com" },
        .{ .url = "https://example.com:8080/path", .expected = "https://example.com:8080" },

        // Default ports should be stripped
        .{ .url = "http://example.com:80/path", .expected = "http://example.com" },
        .{ .url = "https://example.com:443/path", .expected = "https://example.com" },

        // User info should be stripped from origin
        .{ .url = "http://user:pass@example.com/path", .expected = "http://example.com" },
        .{ .url = "https://user@example.com:8080/path", .expected = "https://example.com:8080" },

        // Non-HTTP(S) tuple origins
        .{ .url = "ftp://example.com/path", .expected = "ftp://example.com" },
        .{ .url = "file:///path/to/file", .expected = null },
        .{ .url = "about:blank", .expected = null },

        // Query and fragment should not affect origin
        .{ .url = "https://example.com?query=1", .expected = "https://example.com" },
        .{ .url = "https://example.com#fragment", .expected = "https://example.com" },
        .{ .url = "https://example.com/path?q=1#frag", .expected = "https://example.com" },

        // SECURITY: @ in path must NOT be treated as userinfo separator
        // This would be a Same-Origin Policy bypass if mishandled
        .{ .url = "http://evil.example.com/@victim.example.com/", .expected = "http://evil.example.com" },
        .{ .url = "https://evil.example.com/path/@victim.example.com/steal", .expected = "https://evil.example.com" },
        .{ .url = "http://evil.example.com/@victim.example.com:443/", .expected = "http://evil.example.com" },

        // @ in query/fragment must also not affect origin
        .{ .url = "https://example.com/path?user=foo@bar.com", .expected = "https://example.com" },
        .{ .url = "https://example.com/path#user@host", .expected = "https://example.com" },
    };

    for (cases) |case| {
        const result = try getOrigin(testing.arena_allocator, case.url);
        if (case.expected) |expected| {
            try testing.expectString(expected, result.?);
        } else {
            try testing.expectEqual(null, result);
        }
    }
}

test "URL: resolve path scheme" {
    const Case = struct {
        base: [:0]const u8,
        path: [:0]const u8,
        expected: [:0]const u8,
        expected_error: bool = false,
    };

    const cases = [_]Case{
        //same schemes and path as relative path (one slash)
        .{
            .base = "https://www.example.com/example",
            .path = "https:/about",
            .expected = "https://www.example.com/about",
        },
        //same schemes and path as relative path (without slash)
        .{
            .base = "https://www.example.com/example",
            .path = "https:about",
            .expected = "https://www.example.com/about",
        },
        //same schemes and path as absolute path (two slashes)
        .{
            .base = "https://www.example.com/example",
            .path = "https://about",
            .expected = "https://about/",
        },
        //different schemes and path as absolute (without slash)
        .{
            .base = "https://www.example.com/example",
            .path = "http:about",
            .expected = "http://about/",
        },
        //different schemes and path as absolute (with one slash)
        .{
            .base = "https://www.example.com/example",
            .path = "http:/about",
            .expected = "http://about/",
        },
        //different schemes and path as absolute (with two slashes)
        .{
            .base = "https://www.example.com/example",
            .path = "http://about",
            .expected = "http://about/",
        },
        //same schemes and path as absolute (with more slashes)
        .{
            .base = "https://site/",
            .path = "https://path",
            .expected = "https://path/",
        },
        //path scheme is not special and path as absolute (without additional slashes)
        .{
            .base = "http://localhost/",
            .path = "data:test",
            .expected = "data:test",
        },
        //different schemes and path as absolute (pathscheme=ws)
        .{
            .base = "https://www.example.com/example",
            .path = "ws://about",
            .expected = "ws://about/",
        },
        //different schemes and path as absolute (path scheme=wss)
        .{
            .base = "https://www.example.com/example",
            .path = "wss://about",
            .expected = "wss://about/",
        },
        //different schemes and path as absolute (path scheme=ftp)
        .{
            .base = "https://www.example.com/example",
            .path = "ftp://about",
            .expected = "ftp://about/",
        },
        //different schemes and path as absolute (path scheme=file)
        .{
            .base = "https://www.example.com/example",
            .path = "file://path/to/file",
            .expected = "file://path/to/file",
        },
        //different schemes and path as absolute (path scheme=file, host is empty)
        .{
            .base = "https://www.example.com/example",
            .path = "file:/path/to/file",
            .expected = "file:///path/to/file",
        },
        //different schemes and path as absolute (path scheme=file, host is empty)
        .{
            .base = "https://www.example.com/example",
            .path = "file:/",
            .expected = "file:///",
        },
        //different schemes without :// and normalize "file" scheme, absolute path
        .{
            .base = "https://www.example.com/example",
            .path = "file:path/to/file",
            .expected = "file:///path/to/file",
        },
        //same schemes without :// in path and rest starts with scheme:/, relative path
        .{
            .base = "https://www.example.com/example",
            .path = "https:/file:/relative/path/",
            .expected = "https://www.example.com/file:/relative/path/",
        },
        //same schemes without :// in path and rest starts with scheme://, relative path
        .{
            .base = "https://www.example.com/example",
            .path = "https:/http://relative/path/",
            .expected = "https://www.example.com/http://relative/path/",
        },
        //same schemes without :// in path , relative state
        .{
            .base = "http://www.example.com/example",
            .path = "http:relative:path",
            .expected = "http://www.example.com/relative:path",
        },
        //repeat different schemes in path
        .{
            .base = "http://www.example.com/example",
            .path = "http:http:/relative/path/",
            .expected = "http://www.example.com/http:/relative/path/",
        },
        //repeat different schemes in path
        .{
            .base = "http://www.example.com/example",
            .path = "http:https://relative:path",
            .expected = "http://www.example.com/https://relative:path",
        },
        //NOT required :// for blob scheme
        .{
            .base = "http://www.example.com/example",
            .path = "blob:other",
            .expected = "blob:other",
        },
        //NOT required :// for NON-special schemes and can contains "+" or "-" or "." in scheme
        .{
            .base = "http://www.example.com/example",
            .path = "custom+foo:other",
            .expected = "custom+foo:other",
        },
        //NOT required :// for NON-special schemes
        .{
            .base = "http://www.example.com/example",
            .path = "blob:",
            .expected = "blob:",
        },
        //NOT required :// for special scheme equal base scheme
        .{
            .base = "http://www.example.com/example",
            .path = "http:",
            .expected = "http://www.example.com/example",
        },
        //required :// for special scheme, so throw error.InvalidURL
        .{
            .base = "http://www.example.com/example",
            .path = "https:",
            .expected = "",
            .expected_error = true,
        },
        //incorrect symbols in path scheme
        .{
            .base = "https://site",
            .path = "http?://host/some",
            .expected = "https://site/http?://host/some",
        },
    };

    for (cases) |case| {
        if (case.expected_error) {
            const result = resolve(testing.arena_allocator, case.base, case.path, .{});
            try testing.expectError(error.TypeError, result);
        } else {
            const result = try resolve(testing.arena_allocator, case.base, case.path, .{});
            try testing.expectString(case.expected, result);
        }
    }
}
