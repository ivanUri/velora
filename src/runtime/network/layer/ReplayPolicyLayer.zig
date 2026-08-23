//! Opt-in network fulfillment for controlled execution replay.
//!
//! This layer is intentionally configured from an explicit local JSON file.
//! Its strict mode blocks every unmatched request, preventing a replay from
//! accidentally creating an external side effect. A breakpoint is a deliberate
//! stop before a matching response is fulfilled; the caller can inspect that
//! failed execution and run the checkpoint again after removing it.

const std = @import("std");
const runtime_io = @import("../../../support/io.zig");

const http = @import("../http.zig");
const Client = @import("../../../core/browser/HttpClient.zig").Client;
const Request = @import("../../../core/browser/HttpClient.zig").Request;
const Layer = @import("../../../core/browser/HttpClient.zig").Layer;
const InterceptionLayer = @import("InterceptionLayer.zig");

const Self = @This();

const Header = struct { name: []const u8, value: []const u8 };
const Rule = struct {
    method: ?[]const u8 = null,
    url: []const u8,
    status: u16 = 200,
    headers: []const Header = &.{},
    body: ?[]const u8 = null,
};
const Breakpoint = struct {
    method: ?[]const u8 = null,
    url: []const u8,
    label: ?[]const u8 = null,
};
const Document = struct {
    mode: enum { strict, fallback } = .strict,
    rules: []const Rule = &.{},
    breakpoints: []const Breakpoint = &.{},
};

arena: std.heap.ArenaAllocator,
strict: bool = false,
rules: []const Rule = &.{},
breakpoints: []const Breakpoint = &.{},
next: Layer = undefined,

pub fn init(allocator: std.mem.Allocator, policy_path: ?[]const u8) !Self {
    var self: Self = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    errdefer self.arena.deinit();
    const path = policy_path orelse return self;
    const raw = try std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), path, self.arena.allocator(), .limited(16 * 1024 * 1024));
    const document = try std.json.parseFromSliceLeaky(Document, self.arena.allocator(), raw, .{
        .ignore_unknown_fields = false,
    });
    self.strict = document.mode == .strict;
    self.rules = document.rules;
    self.breakpoints = document.breakpoints;
    return self;
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
}

pub fn enabled(self: *const Self) bool {
    return self.rules.len > 0 or self.strict;
}

pub fn layer(self: *Self) Layer {
    return .{ .ptr = self, .vtable = &.{ .request = request } };
}

fn request(ptr: *anyopaque, client: *Client, req: Request) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    for (self.breakpoints) |breakpoint| {
        if (!matches(breakpoint, req)) continue;
        // A breakpoint is an intentional, deterministic stop before the
        // response is fulfilled. The caller can inspect the failed execution
        // and run the same checkpoint again after removing the breakpoint.
        req.error_callback(req.ctx, error.ExecutionReplayBreakpoint);
        client.deinitRequest(req);
        return;
    }
    for (self.rules) |rule| {
        if (!matches(rule, req)) continue;
        const headers = try materializeHeaders(req.params.arena, rule.headers);
        client.network.emitExecutionReplay(.{
            .method = @tagName(req.params.method),
            .resource_type = req.params.resource_type.string(),
            .request_id = req.params.request_id,
            .frame_id = req.params.frame_id,
            .loader_id = req.params.loader_id,
            .redirect_count = 0,
            .content_type = headerValue(rule.headers, "content-type"),
        }, req.params.url, rule.status, req.params.headers, headers, req.params.body, rule.body);
        return InterceptionLayer.fulfillDirect(client, req, rule.status, headers, rule.body);
    }
    if (self.strict) {
        req.error_callback(req.ctx, error.ExecutionReplayMiss);
        client.deinitRequest(req);
        return;
    }
    return self.next.request(client, req);
}

fn headerValue(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn matches(rule: anytype, req: Request) bool {
    if (!std.mem.eql(u8, rule.url, req.params.url)) return false;
    if (rule.method) |method| return std.ascii.eqlIgnoreCase(method, @tagName(req.params.method));
    return true;
}

fn materializeHeaders(allocator: std.mem.Allocator, source: []const Header) ![]http.Header {
    const headers = try allocator.alloc(http.Header, source.len);
    for (source, headers) |header, *out| out.* = .{ .name = header.name, .value = header.value };
    return headers;
}

test "replay rule matches only its canonical method and URL" {
    const testing = std.testing;
    const rule = Rule{ .method = "GET", .url = "https://example.test/products" };
    try testing.expect(std.ascii.eqlIgnoreCase(rule.method.?, "get"));
    try testing.expect(std.mem.eql(u8, rule.url, "https://example.test/products"));
}

test "replay breakpoint uses the same method and URL contract" {
    const testing = std.testing;
    const breakpoint = Breakpoint{ .method = "POST", .url = "https://example.test/checkout", .label = "before checkout" };
    try testing.expect(std.ascii.eqlIgnoreCase(breakpoint.method.?, "post"));
    try testing.expect(std.mem.eql(u8, breakpoint.url, "https://example.test/checkout"));
}
