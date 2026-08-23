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
const runtime_io = @import("../support/io.zig");
const Timer = @import("../support/timer.zig");
const WaitGroup = @import("../support/wait_group.zig");

const log = @import("../support/log.zig");
const Allocator = std.mem.Allocator;

pub const allocator = std.testing.allocator;
pub const expectError = std.testing.expectError;
pub const expect = std.testing.expect;
pub const expectString = std.testing.expectEqualStrings;
pub const expectEqualStrings = std.testing.expectEqualStrings;
pub const expectEqualSlices = std.testing.expectEqualSlices;
pub const expectApproxEqAbs = std.testing.expectApproxEqAbs;

// sometimes it's super useful to have an arena you don't really care about
// in a test. Like, you need a mutable string, so you just want to dupe a
// string literal. It has nothing to do with the code under test, it's just
// infrastructure for the test itself.
pub var arena_instance = std.heap.ArenaAllocator.init(std.heap.c_allocator);
pub const arena_allocator = arena_instance.allocator();

pub fn reset() void {
    _ = arena_instance.reset(.retain_capacity);
}

const App = @import("../runtime/App.zig");
const js = @import("../core/js/js.zig");
const Config = @import("../runtime/Config.zig");
const HttpClient = @import("../core/browser/HttpClient.zig");
const Frame = @import("../core/browser/Frame.zig");
const Browser = @import("../core/browser/Browser.zig");
const Session = @import("../core/browser/Session.zig");
const Notification = @import("../runtime/Notification.zig");

// Merged std.testing.expectEqual and std.testing.expectString
// can be useful when testing fields of an anytype an you don't know
// exactly how to assert equality
pub fn expectEqual(expected: anytype, actual: anytype) !void {
    switch (@typeInfo(@TypeOf(expected))) {
        .null => return std.testing.expectEqual(null, actual),
        .optional => {
            if (expected) |value| {
                return expectEqual(value, actual);
            }
            return std.testing.expectEqual(null, actual);
        },
        else => {},
    }

    switch (@typeInfo(@TypeOf(actual))) {
        .array => |arr| if (arr.child == u8) {
            return std.testing.expectEqualStrings(expected, &actual);
        },
        .pointer => |ptr| {
            if (ptr.child == u8) {
                return std.testing.expectEqualStrings(expected, actual);
            } else if (comptime isStringArray(ptr.child)) {
                return std.testing.expectEqualStrings(expected, actual);
            } else if (ptr.child == []u8 or ptr.child == []const u8) {
                return expectString(expected, actual);
            }
        },
        .@"struct" => |structType| {
            inline for (structType.fields) |field| {
                try expectEqual(@field(expected, field.name), @field(actual, field.name));
            }
            return;
        },
        .optional => {
            if (@typeInfo(@TypeOf(expected)) == .null) {
                return std.testing.expectEqual(null, actual);
            }
            if (actual) |_actual| {
                return expectEqual(expected, _actual);
            }
            return std.testing.expectEqual(expected, null);
        },
        .@"union" => |union_info| {
            if (union_info.tag_type == null) {
                @compileError("Unable to compare untagged union values");
            }
            const Tag = std.meta.Tag(@TypeOf(expected));

            const expectedTag = @as(Tag, expected);
            const actualTag = @as(Tag, actual);
            try expectEqual(expectedTag, actualTag);

            inline for (std.meta.fields(@TypeOf(actual))) |fld| {
                if (std.mem.eql(u8, fld.name, @tagName(actualTag))) {
                    try expectEqual(@field(expected, fld.name), @field(actual, fld.name));
                    return;
                }
            }
            unreachable;
        },
        else => {},
    }
    return std.testing.expectEqual(expected, actual);
}

pub fn expectDelta(expected: anytype, actual: anytype, delta: anytype) !void {
    if (@typeInfo(@TypeOf(expected)) == .null) {
        return std.testing.expectEqual(null, actual);
    }

    switch (@typeInfo(@TypeOf(actual))) {
        .optional => {
            if (actual) |value| {
                return expectDelta(expected, value, delta);
            }
            return std.testing.expectEqual(null, expected);
        },
        else => {},
    }

    switch (@typeInfo(@TypeOf(expected))) {
        .optional => {
            if (expected) |value| {
                return expectDelta(value, actual, delta);
            }
            return std.testing.expectEqual(null, actual);
        },
        else => {},
    }

    var diff = expected - actual;
    if (diff < 0) {
        diff = -diff;
    }
    if (diff <= delta) {
        return;
    }

    print("Expected {} to be within {} of {}. Actual diff: {}", .{ expected, delta, actual, diff });
    return error.NotWithinDelta;
}

fn isStringArray(comptime T: type) bool {
    if (!is(.array)(T) and !isPtrTo(.array)(T)) {
        return false;
    }
    return std.meta.Elem(T) == u8;
}

pub const TraitFn = fn (type) bool;
pub fn is(comptime id: std.builtin.TypeId) TraitFn {
    const Closure = struct {
        pub fn trait(comptime T: type) bool {
            return id == @typeInfo(T);
        }
    };
    return Closure.trait;
}

pub fn isPtrTo(comptime id: std.builtin.TypeId) TraitFn {
    const Closure = struct {
        pub fn trait(comptime T: type) bool {
            if (!comptime isSingleItemPtr(T)) return false;
            return id == @typeInfo(std.meta.Child(T));
        }
    };
    return Closure.trait;
}

pub fn isSingleItemPtr(comptime T: type) bool {
    if (comptime is(.pointer)(T)) {
        return @typeInfo(T).pointer.size == .one;
    }
    return false;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint(fmt, args));
    } else {
        std.debug.print(fmt, args);
    }
}

pub const Random = struct {
    var instance: ?std.Random.DefaultPrng = null;

    pub fn fill(buf: []u8) void {
        var r = random();
        r.bytes(buf);
    }

    pub fn fillAtLeast(buf: []u8, min: usize) []u8 {
        var r = random();
        const l = r.intRangeAtMost(usize, min, buf.len);
        r.bytes(buf[0..l]);
        return buf;
    }

    pub fn intRange(comptime T: type, min: T, max: T) T {
        var r = random();
        return r.intRangeAtMost(T, min, max);
    }

    pub fn random() std.Random {
        if (instance == null) {
            var seed: u64 = undefined;
            std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
            instance = std.Random.DefaultPrng.init(seed);
            // instance = std.Random.DefaultPrng.init(0);
        }
        return instance.?.random();
    }
};

pub fn expectJson(a: anytype, b: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const aa = arena.allocator();

    const a_value = try convertToJson(aa, a);
    const b_value = try convertToJson(aa, b);

    errdefer {
        const a_json = std.json.Stringify.valueAlloc(aa, a_value, .{ .whitespace = .indent_2 }) catch unreachable;
        const b_json = std.json.Stringify.valueAlloc(aa, b_value, .{ .whitespace = .indent_2 }) catch unreachable;
        std.debug.print("== Expected ==\n{s}\n\n== Actual ==\n{s}", .{ a_json, b_json });
    }

    try expectJsonValue(a_value, b_value);
}

pub fn isEqualJson(a: anytype, b: anytype) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const aa = arena.allocator();
    const a_value = try convertToJson(aa, a);
    const b_value = try convertToJson(aa, b);
    return isJsonValue(a_value, b_value);
}

fn convertToJson(arena: Allocator, value: anytype) !std.json.Value {
    const T = @TypeOf(value);
    if (T == std.json.Value) {
        return value;
    }

    var str: []const u8 = undefined;
    if (T == []u8 or T == []const u8 or comptime isStringArray(T)) {
        str = value;
    } else {
        str = try std.json.Stringify.valueAlloc(arena, value, .{});
    }
    return std.json.parseFromSliceLeaky(std.json.Value, arena, str, .{});
}

fn expectJsonValue(a: std.json.Value, b: std.json.Value) !void {
    try expectEqual(@tagName(a), @tagName(b));

    // at this point, we know that if a is an int, b must also be an int
    switch (a) {
        .null => return,
        .bool => try expectEqual(a.bool, b.bool),
        .integer => try expectEqual(a.integer, b.integer),
        .float => try expectEqual(a.float, b.float),
        .number_string => try expectEqual(a.number_string, b.number_string),
        .string => try expectEqual(a.string, b.string),
        .array => {
            const a_len = a.array.items.len;
            const b_len = b.array.items.len;
            try expectEqual(a_len, b_len);
            for (a.array.items, b.array.items) |a_item, b_item| {
                try expectJsonValue(a_item, b_item);
            }
        },
        .object => {
            var it = a.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (b.object.get(key)) |b_item| {
                    try expectJsonValue(entry.value_ptr.*, b_item);
                } else {
                    return error.MissingKey;
                }
            }
        },
    }
}

fn isJsonValue(a: std.json.Value, b: std.json.Value) bool {
    if (std.mem.eql(u8, @tagName(a), @tagName(b)) == false) {
        return false;
    }

    // at this point, we know that if a is an int, b must also be an int
    switch (a) {
        .null => return true,
        .bool => return a.bool == b.bool,
        .integer => return a.integer == b.integer,
        .float => return a.float == b.float,
        .number_string => return std.mem.eql(u8, a.number_string, b.number_string),
        .string => return std.mem.eql(u8, a.string, b.string),
        .array => {
            const a_len = a.array.items.len;
            const b_len = b.array.items.len;
            if (a_len != b_len) {
                return false;
            }
            for (a.array.items, b.array.items) |a_item, b_item| {
                if (isJsonValue(a_item, b_item) == false) {
                    return false;
                }
            }
            return true;
        },
        .object => {
            var it = a.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (b.object.get(key)) |b_item| {
                    if (isJsonValue(entry.value_ptr.*, b_item) == false) {
                        return false;
                    }
                } else {
                    return false;
                }
            }
            return true;
        },
    }
}

pub var test_app: *App = undefined;
pub var test_browser: Browser = undefined;
pub var test_notification: *Notification = undefined;
pub var test_session: *Session = undefined;

const WEB_API_TEST_ROOT = "src/browser/tests/";
const HtmlRunnerOpts = struct {};

pub fn htmlRunner(comptime path: []const u8, opts: HtmlRunnerOpts) !void {
    _ = opts;
    defer reset();

    const root = try std.fs.path.joinZ(arena_allocator, &.{ WEB_API_TEST_ROOT, path });
    const io = runtime_io.get();
    const stat = std.Io.Dir.cwd().statFile(io, root, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    switch (stat.kind) {
        .file => {
            if (@import("root").shouldRun(std.fs.path.basename(root)) == false) {
                return;
            }
            try @import("root").subtest(root);
            try runWebApiTest(root);
        },
        .directory => {
            const dir = try std.Io.Dir.cwd().openDir(io, root, .{
                .iterate = true,
                .follow_symlinks = false,
                .access_sub_paths = false,
            });
            defer dir.close(io);

            var it = dir.iterateAssumeFirstIteration();
            while (try it.next(io)) |entry| {
                if (entry.kind != .file) {
                    continue;
                }

                if (!std.mem.endsWith(u8, entry.name, ".html")) {
                    continue;
                }

                if (@import("root").shouldRun(entry.name) == false) {
                    continue;
                }

                const full_path = try std.fs.path.joinZ(arena_allocator, &.{ root, entry.name });
                try @import("root").subtest(entry.name);
                try runWebApiTest(full_path);
            }
        },
        else => |kind| {
            std.debug.print("Unknown file type: {s} for {s}\n", .{ @tagName(kind), root });
            return error.InvalidTestPath;
        },
    }
}

fn runWebApiTest(test_file: [:0]const u8) !void {
    const frame = try test_session.createPage();
    defer test_session.removePage();

    const url = try std.fmt.allocPrintSentinel(
        arena_allocator,
        "http://127.0.0.1:9582/{s}",
        .{test_file},
        0,
    );

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    {
        var try_catch: js.TryCatch = undefined;
        try_catch.init(&ls.local);
        defer try_catch.deinit();

        try frame.navigate(url, .{});
    }

    var runner = try test_session.runner(.{});
    try runner.wait(.{ .ms = 2000, .until = .load });

    var wait_ms: u32 = 2000;
    var timer = try Timer.start();
    while (true) {
        var try_catch: js.TryCatch = undefined;
        try_catch.init(&ls.local);
        defer try_catch.deinit();

        const js_val = ls.local.exec("testing.assertOk()", "testing.assertOk()") catch |err| {
            const caught = try_catch.caughtOrError(arena_allocator, err);
            const state = blk: {
                const value = ls.local.exec(
                    "String(document.body?.textContent ?? '')",
                    "testing.failureState()",
                ) catch break :blk "";
                break :blk value.toStringSliceWithAlloc(arena_allocator) catch "";
            };
            std.debug.print("{s}: test failure\nState: {s}\nError: {f}\n", .{ test_file, state, caught });
            return err;
        };
        if (js_val.isTrue()) {
            return;
        }
        const sleep_ms: usize = switch (try runner.tick(.{ .ms = 20 })) {
            .done => 20,
            .ok => |next_ms| @min(next_ms, 20),
        };

        const ms_elapsed = timer.lap() / 1_000_000;
        if (ms_elapsed >= wait_ms) {
            ls.local.eval("testing.printTimeoutState()", "testing.printTimeoutState()") catch {};
            return error.TestTimedOut;
        }
        wait_ms -= @intCast(ms_elapsed);
        Timer.sleepNanoseconds(std.time.ns_per_ms * sleep_ms);
    }
}

const PageTestOpts = struct {
    wait_until_done: bool = true,
};
pub fn pageTest(comptime test_file: []const u8, opts: PageTestOpts) !*Frame {
    const fixture_path = try std.fs.path.joinZ(arena_allocator, &.{ WEB_API_TEST_ROOT, test_file });
    std.Io.Dir.cwd().access(runtime_io.get(), fixture_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    const frame = try test_session.createPage();
    errdefer test_session.removePage();

    const url = try std.fmt.allocPrintSentinel(
        arena_allocator,
        "http://127.0.0.1:9582/{s}{s}",
        .{ WEB_API_TEST_ROOT, test_file },
        0,
    );

    try frame.navigate(url, .{});
    var runner = try test_session.runner(.{});
    if (opts.wait_until_done) {
        try runner.wait(.{ .ms = 2000 });
    }
    return frame;
}

const TestHTTPServer = @import("TestHTTPServer.zig");
const TestWSServer = @import("TestWSServer.zig");

const Server = @import("../adapters/server/Server.zig");
var test_cdp_server: ?*Server = null;
var test_cdp_server_thread: ?std.Thread = null;
var test_http_server: ?TestHTTPServer = null;
var test_http_server_thread: ?std.Thread = null;
var test_ws_server: ?TestWSServer = null;
var test_ws_server_thread: ?std.Thread = null;

var test_config: Config = undefined;

test "tests:beforeAll" {
    log.opts.level = .warn;
    log.opts.format = .pretty;

    const test_allocator = @import("root").tracking_allocator;

    try test_config.initInPlace(test_allocator, "test", .{ .serve = .{
        .insecure_disable_tls_host_verification = true,
        .user_agent_suffix = "internal-tester",
        .ws_max_concurrent = 50,
    } });

    test_app = try App.init(test_allocator, &test_config);
    errdefer test_app.deinit();

    try test_browser.init(test_app, .{}, null);
    errdefer test_browser.deinit();

    // Create notification for testing
    test_notification = try Notification.init(test_app.allocator);
    errdefer test_notification.deinit();

    test_session = try test_browser.newSession(test_notification);

    var wg: WaitGroup = .{};
    wg.startMany(3);

    test_cdp_server_thread = try std.Thread.spawn(.{}, serveCDP, .{&wg});

    test_http_server = TestHTTPServer.init(testHTTPHandler);
    test_http_server_thread = try std.Thread.spawn(.{}, TestHTTPServer.run, .{ &test_http_server.?, &wg });

    test_ws_server = TestWSServer.init();
    test_ws_server_thread = try std.Thread.spawn(.{}, TestWSServer.run, .{ &test_ws_server.?, &wg });

    // need to wait for the servers to be listening, else tests will fail because
    // they aren't able to connect.
    wg.wait();
}

test "resource policy: no-images completes without an image transfer" {
    defer reset();
    const previous = test_config.mode.serve.resource_policy;
    defer test_config.mode.serve.resource_policy = previous;
    test_config.mode.serve.resource_policy = .no_images;
    try htmlRunner("regression/resource_policy_no_images.html", .{});
}

test "resource policy: no-css skips external stylesheet transfer" {
    defer reset();
    const previous = test_config.mode.serve.resource_policy;
    defer test_config.mode.serve.resource_policy = previous;
    test_config.mode.serve.resource_policy = .no_css;
    try htmlRunner("regression/resource_policy_no_css.html", .{});
}

test "tests:afterAll" {
    test_app.network.stop();
    if (test_cdp_server_thread) |thread| {
        thread.join();
    }
    if (test_cdp_server) |server| {
        server.deinit();
    }

    if (test_http_server) |*server| {
        server.stop();
    }
    if (test_http_server_thread) |thread| {
        thread.join();
    }
    if (test_http_server) |*server| {
        server.deinit();
    }

    if (test_ws_server) |*server| {
        server.stop();
    }
    if (test_ws_server_thread) |thread| {
        thread.join();
    }

    @import("root").v8_peak_memory = test_browser.env.isolate.getHeapStatistics().total_physical_size;

    test_notification.deinit();
    test_browser.deinit();
    test_app.deinit();
    test_config.deinit(@import("root").tracking_allocator);
}

fn serveCDP(wg: *WaitGroup) !void {
    var ready = false;
    defer if (!ready) wg.finish();
    const address = try @import("../support/net.zig").Address.parseIp("127.0.0.1", 9583);

    test_cdp_server = Server.init(test_app, address) catch |err| {
        std.debug.print("CDP server error: {}", .{err});
        return err;
    };
    wg.finish();
    ready = true;

    test_app.network.run();
}

fn testHTTPHandler(req: *std.http.Server.Request) !void {
    const path = req.head.target;

    if (std.mem.eql(u8, path, "/lazy-image.png")) {
        // Keep the response deterministic but non-zero latency so a
        // wait_until=done regression test can observe whether lazy activation
        // actually owns the network request before returning.
        Timer.sleepNanoseconds(50 * std.time.ns_per_ms);
        const png = [_]u8{
            0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n',
            0,    0,   0,   13,  'I',  'H',  'D',  'R',
            0,    0,   0,   1,   0,    0,    0,    1,
        };
        return req.respond(&png, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "image/png" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/policy.css")) {
        return req.respond("#policy-target { color: rgb(1, 2, 3); }", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/css" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/static-module-delayed-dependency.js")) {
        // Ensure the entry module reaches V8 instantiation while this import is
        // still in flight. Its terminal callback must be allowed to run after
        // the outer entry-script HTTP callback unwinds.
        Timer.sleepNanoseconds(50 * std.time.ns_per_ms);
        return req.respond("export const dependencyValue = 42;", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/javascript" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/fetch-stream-hold")) {
        var send_buffer: [1024]u8 = undefined;
        var res = try req.respondStreaming(&send_buffer, .{
            .respond_options = .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            },
        });
        try res.writer.writeAll("first-");
        try res.writer.flush();
        try res.flush();

        Timer.sleepNanoseconds(1500 * std.time.ns_per_ms);
        try res.writer.writeAll("second");
        try res.writer.flush();
        return res.end();
    }

    if (std.mem.eql(u8, path, "/xhr")) {
        return req.respond("1234567890" ** 10, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr_empty")) {
        return req.respond("", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/json")) {
        return req.respond("{\"over\":\"9000!!!\",\"updated_at\":1765867200000}", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/redirect")) {
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "http://127.0.0.1:9582/xhr" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect-stream-hold")) {
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "/fetch-stream-hold" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect-no-fragment")) {
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "/redirect-target" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect-target")) {
        return req.respond("<!DOCTYPE html><title>landed</title>", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect-with-fragment")) {
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "/redirect-target#target_fragment" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/404")) {
        return req.respond("Not Found", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/500")) {
        return req.respond("Internal Server Error", .{
            .status = .internal_server_error,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/binary")) {
        return req.respond(&.{ 0, 0, 1, 2, 0, 0, 9 }, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/octet-stream" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/echo_referer")) {
        // Echo the request's Referer header back as HTML so tests can assert
        // what Referer the navigation sent. Used by the cross-page Referer test.
        var it = req.iterateHeaders();
        var referer: []const u8 = "NONE";
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Referer")) {
                referer = h.value;
                break;
            }
        }
        var html_buf: [512]u8 = undefined;
        const html = try std.fmt.bufPrint(&html_buf, "<html><body>referer={s}</body></html>", .{referer});
        return req.respond(html, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/referer_link.html")) {
        // Page with an anchor link to /echo_referer. The test clicks the link
        // via JS and asserts the resulting page reports Referer = this page.
        return req.respond(
            "<html><body><a id=\"link\" href=\"/echo_referer\">go</a></body></html>",
            .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                },
            },
        );
    }

    if (std.mem.eql(u8, path, "/echo_method")) {
        // Echo the request method back as HTML so tests can assert on what
        // method the navigation used. Used by the Page.reload-replays-POST test.
        const method_name = @tagName(req.head.method);
        var html_buf: [128]u8 = undefined;
        const html = try std.fmt.bufPrint(&html_buf, "<html><body>method={s}</body></html>", .{method_name});
        return req.respond(html, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect_to_echo")) {
        // 302 to /echo_method. Used by the Page.reload-after-redirect test to
        // confirm a POST→302→GET chain doesn't replay POST on reload.
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "/echo_method" },
            },
        });
    }

    if (std.mem.startsWith(u8, path, "/src/browser/tests/")) {
        // strip off leading / so that it's relative to CWD
        return TestHTTPServer.sendFile(req, path[1..]);
    }

    std.debug.print("TestHTTPServer was asked to serve an unknown file: {s}\n", .{path});
    return req.respond("not found", .{
        .status = .not_found,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
        },
    });
}

/// LogFilter provides a scoped way to suppress specific log categories during tests.
/// This is useful for tests that trigger expected errors or warnings.
pub const LogFilter = struct {
    old_filter: []const log.Scope,

    /// Sets the log filter to suppress the specified scope(s).
    /// Returns a LogFilter that should be deinitialized to restore previous filters.
    pub fn init(comptime scopes: []const log.Scope) LogFilter {
        comptime std.debug.assert(@TypeOf(scopes) == []const log.Scope);
        const old_filter = log.opts.filter_scopes;
        log.opts.filter_scopes = scopes;
        return .{ .old_filter = old_filter };
    }

    /// Restores the log filters to their previous state.
    pub fn deinit(self: LogFilter) void {
        log.opts.filter_scopes = self.old_filter;
    }
};
