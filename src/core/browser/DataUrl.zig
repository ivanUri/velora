const std = @import("std");

const URL = @import("URL.zig");

const Allocator = std.mem.Allocator;

/// Decode the body of a `data:` URL. The returned bytes belong to `allocator`.
/// Network transports must never receive this scheme; the resource loader that
/// consumes the URL owns decoding and completion.
pub fn decodeBody(allocator: Allocator, url: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, url, "data:")) return error.InvalidDataUrl;

    const comma = std.mem.indexOfScalarPos(u8, url, 5, ',') orelse
        return error.InvalidDataUrl;
    const metadata = url[5..comma];
    const escaped_body = url[comma + 1 ..];
    const was_escaped = std.mem.indexOfScalar(u8, escaped_body, '%') != null;
    const body = try URL.unescape(allocator, escaped_body);

    var token_it = std.mem.splitScalar(u8, metadata, ';');
    _ = token_it.next();
    var is_base64 = false;
    while (token_it.next()) |token| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, token, " \t\r\n"), "base64")) {
            is_base64 = true;
        }
    }
    if (!is_base64) {
        if (was_escaped) return body;
        return allocator.dupe(u8, body);
    }
    defer if (was_escaped) allocator.free(body);

    var compact = try std.ArrayList(u8).initCapacity(allocator, body.len);
    defer compact.deinit(allocator);
    for (body) |byte| {
        if (!std.ascii.isWhitespace(byte)) compact.appendAssumeCapacity(byte);
    }
    const unpadded = std.mem.trimEnd(u8, compact.items, "=");
    if (unpadded.len % 4 == 1) return error.InvalidDataUrl;

    const decoded_len = std.base64.standard_no_pad.Decoder
        .calcSizeForSlice(unpadded) catch return error.InvalidDataUrl;
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    std.base64.standard_no_pad.Decoder.decode(decoded, unpadded) catch
        return error.InvalidDataUrl;
    return decoded;
}

test "DataUrl: decodes percent-encoded and forgiving base64 bodies" {
    const allocator = std.testing.allocator;

    const plain = try decodeBody(allocator, "data:text/plain,hello%20world");
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("hello world", plain);

    const encoded = try decodeBody(allocator, "data:image/gif;BASE64,R0lGODlhAQABAA==");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("GIF89a\x01\x00\x01\x00", encoded);
}

test "DataUrl: rejects malformed URLs and base64" {
    try std.testing.expectError(
        error.InvalidDataUrl,
        decodeBody(std.testing.allocator, "data:image/gif;base64"),
    );
    try std.testing.expectError(
        error.InvalidDataUrl,
        decodeBody(std.testing.allocator, "data:image/gif;base64,A"),
    );
}
