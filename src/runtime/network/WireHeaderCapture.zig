const std = @import("std");
const runtime_io = @import("../../support/io.zig");
const libcurl = @import("../../support/sys/libcurl.zig");
const HttpClient = @import("../../core/browser/HttpClient.zig");
const build_config = @import("build_config");

const Allocator = std.mem.Allocator;

pub fn enabled() bool {
    if (comptime !build_config.curl_impersonate) return false;
    return runtime_io.getenv("KOKO_WIRE_HEADERS") != null;
}

fn outputPath() ?[]const u8 {
    return runtime_io.getenv("KOKO_WIRE_HEADERS_FILE");
}

pub fn shouldCapture(url: []const u8, resource_type: HttpClient.RequestParams.ResourceType) bool {
    _ = url;
    _ = resource_type;
    return enabled();
}

pub const Session = struct {
    url: []const u8,
    resource_type: HttpClient.RequestParams.ResourceType,
    lines: std.ArrayList([]const u8),
    arena: Allocator,
    flushed: bool = false,

    pub fn init(
        allocator: Allocator,
        url: []const u8,
        resource_type: HttpClient.RequestParams.ResourceType,
    ) !*Session {
        const self = try allocator.create(Session);
        self.* = .{
            .url = try allocator.dupe(u8, url),
            .resource_type = resource_type,
            .lines = try std.ArrayList([]const u8).initCapacity(allocator, 32),
            .arena = allocator,
        };
        return self;
    }

    pub fn pushChunk(self: *Session, raw: []const u8) !void {
        var iter = std.mem.splitScalar(u8, raw, '\n');
        while (iter.next()) |part| {
            const line = std.mem.trim(u8, part, " \t\r");
            if (line.len == 0) continue;
            try self.lines.append(self.arena, try self.arena.dupe(u8, line));
        }
    }

    pub fn flush(self: *Session, status: ?u16, protocol: []const u8) !void {
        if (self.flushed) return;
        self.flushed = true;

        const path = outputPath() orelse return;
        const io = runtime_io.get();
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
        defer file.close(io);
        if (std.c.lseek(file.handle, 0, std.c.SEEK.END) < 0) return error.Unexpected;

        var request_lines = try std.ArrayList([]const u8).initCapacity(self.arena, 4);
        var headers = try std.ArrayList(HeaderEntry).initCapacity(self.arena, 32);
        var order = try std.ArrayList([]const u8).initCapacity(self.arena, 32);

        for (self.lines.items) |line| {
            if (line.len > 0 and line[0] == '>') {
                try request_lines.append(self.arena, line);
                continue;
            }
            if (isRequestLine(line)) {
                try request_lines.append(self.arena, line);
                continue;
            }
            if (std.mem.indexOf(u8, line, ":") == null) continue;
            const parsed = parseHeaderLine(line) orelse continue;
            try headers.append(self.arena, parsed);
            try order.append(self.arena, parsed.name);
        }

        var out = try std.Io.Writer.Allocating.initCapacity(self.arena, 4096);
        defer out.deinit();
        const w = &out.writer;
        try w.print("{{\"url\":", .{});
        try writeJsonString(w, self.url);
        try w.print(",\"resourceType\":", .{});
        try writeJsonString(w, @tagName(self.resource_type));
        try w.print(",\"status\":", .{});
        if (status) |s| try w.print("{d}", .{s}) else try w.writeAll("null");
        try w.print(",\"protocol\":", .{});
        try writeJsonString(w, protocol);
        try w.print(",\"headerCount\":{d},\"requestLines\":[", .{headers.items.len});
        for (request_lines.items, 0..) |line, i| {
            if (i > 0) try w.writeAll(",");
            try writeJsonString(w, line);
        }
        try w.writeAll("],\"headerOrder\":[");
        for (order.items, 0..) |name, i| {
            if (i > 0) try w.writeAll(",");
            try writeJsonString(w, name);
        }
        try w.writeAll("],\"headers\":[");
        for (headers.items, 0..) |hdr, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"name\":", .{});
            try writeJsonString(w, hdr.name);
            try w.print(",\"value\":", .{});
            try writeJsonString(w, hdr.value);
            try w.writeAll("}");
        }
        try w.writeAll("]}\n");
        try file.writeStreamingAll(io, out.written());
    }
};

const HeaderEntry = struct {
    name: []const u8,
    value: []const u8,
};

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn isRequestLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "GET ") or
        std.mem.startsWith(u8, line, "POST ") or
        std.mem.startsWith(u8, line, "HEAD ");
}

fn parseHeaderLine(line: []const u8) ?HeaderEntry {
    const colon = std.mem.indexOf(u8, line, ":") orelse return null;
    const name = std.mem.trim(u8, line[0..colon], " \t");
    const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
    if (name.len == 0) return null;
    return .{ .name = name, .value = value };
}

pub fn debugCallback(
    _: *libcurl.Curl,
    typ: libcurl.CurlInfoType,
    raw: [*c]u8,
    len: usize,
    user: ?*anyopaque,
) callconv(.c) c_int {
    const session: *Session = @ptrCast(@alignCast(user orelse return 0));
    const slice = raw[0..len];
    switch (typ) {
        .header_out => session.pushChunk(slice) catch {},
        .text => {
            if (slice.len > 0 and slice[0] == '>') session.pushChunk(slice) catch {};
        },
        else => {},
    }
    return 0;
}

const testing = @import("../../testing/testing.zig");

test "WireHeaderCapture: parseHeaderLine" {
    const parsed = parseHeaderLine("Accept-Language: en-US,en;q=0.9").?;
    try testing.expectEqualStrings("Accept-Language", parsed.name);
    try testing.expectEqualStrings("en-US,en;q=0.9", parsed.value);
}
