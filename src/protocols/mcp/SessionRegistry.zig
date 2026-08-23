const std = @import("std");
const runtime_io = @import("../../support/io.zig");

const App = @import("../../runtime/App.zig");
const Server = @import("Server.zig");
const router = @import("router.zig");

const Self = @This();

pub const Error = error{
    SessionLimitReached,
    SessionNotFound,
    OutOfMemory,
};

pub const Options = struct {
    max_sessions: usize = 64,
};

const Entry = struct {
    id: []u8,
    output: std.Io.Writer.Allocating,
    server: *Server,

    fn init(allocator: std.mem.Allocator, app: *App, id: []u8) !*Entry {
        const entry = try allocator.create(Entry);
        errdefer allocator.destroy(entry);
        entry.* = .{
            .id = id,
            .output = .init(allocator),
            .server = undefined,
        };
        errdefer entry.output.deinit();
        entry.server = try Server.init(allocator, app, &entry.output.writer);
        // Env.init leaves its isolate entered. A registry owns multiple
        // browsers on one worker, so park every isolate until dispatch.
        entry.server.exitIsolate();
        return entry;
    }

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        // Browser/Env teardown requires its isolate to be current and exits it
        // exactly once as part of Env.deinit.
        self.server.enterIsolate();
        self.server.deinit();
        self.output.deinit();
        allocator.free(self.id);
        allocator.destroy(self);
    }
};

allocator: std.mem.Allocator,
app: *App,
options: Options,
sessions: std.StringHashMap(*Entry),

/// SessionRegistry is deliberately not internally synchronized. Its owner is
/// the MCP browser worker; connection threads must marshal jobs to that worker.
pub fn init(allocator: std.mem.Allocator, app: *App, options: Options) Self {
    return .{
        .allocator = allocator,
        .app = app,
        .options = options,
        .sessions = std.StringHashMap(*Entry).init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    var it = self.sessions.valueIterator();
    while (it.next()) |entry| entry.*.deinit(self.allocator);
    self.sessions.deinit();
}

pub fn create(self: *Self) Error![]const u8 {
    if (self.sessions.count() >= self.options.max_sessions) {
        return error.SessionLimitReached;
    }

    var random: [16]u8 = undefined;
    runtime_io.get().random(&random);
    const id = std.fmt.allocPrint(self.allocator, "{x}", .{random}) catch return error.OutOfMemory;
    errdefer self.allocator.free(id);

    const entry = Entry.init(self.allocator, self.app, id) catch return error.OutOfMemory;
    errdefer entry.deinit(self.allocator);
    self.sessions.put(entry.id, entry) catch return error.OutOfMemory;
    return entry.id;
}

pub fn contains(self: *const Self, id: []const u8) bool {
    return self.sessions.contains(id);
}

pub fn count(self: *const Self) usize {
    return self.sessions.count();
}

pub fn close(self: *Self, id: []const u8) Error!void {
    const removed = self.sessions.fetchRemove(id) orelse return error.SessionNotFound;
    removed.value.deinit(self.allocator);
}

/// Handles exactly one JSON-RPC request and returns an owned response. The
/// caller owns the returned bytes. Requests for one session are serialized by
/// the registry's worker ownership.
pub fn dispatch(self: *Self, id: []const u8, body: []const u8) (Error || error{WriteFailed})![]u8 {
    const entry = self.sessions.get(id) orelse return error.SessionNotFound;
    entry.output.clearRetainingCapacity();
    entry.server.enterIsolate();
    defer entry.server.exitIsolate();

    var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_instance.deinit();
    router.handleMessage(entry.server, arena_instance.allocator(), body) catch return error.WriteFailed;

    return self.allocator.dupe(u8, entry.output.written()) catch error.OutOfMemory;
}

pub fn writeSessionList(self: *const Self, writer: *std.Io.Writer) !void {
    try writer.writeByte('[');
    var first = true;
    var it = self.sessions.keyIterator();
    while (it.next()) |id| {
        if (!first) try writer.writeByte(',');
        first = false;
        try std.json.Stringify.value(id.*, .{}, writer);
    }
    try writer.writeByte(']');
}

const testing = @import("../../testing/testing.zig");

test "MCP SessionRegistry isolates dispatch and closes exactly one session" {
    defer testing.reset();
    var registry = Self.init(testing.allocator, testing.test_app, .{ .max_sessions = 2 });
    defer registry.deinit();

    const first = try testing.allocator.dupe(u8, try registry.create());
    defer testing.allocator.free(first);
    const second = try testing.allocator.dupe(u8, try registry.create());
    defer testing.allocator.free(second);

    try testing.expect(!std.mem.eql(u8, first, second));
    try testing.expectEqual(@as(usize, 2), registry.count());

    const ping =
        \\{"jsonrpc":"2.0","id":7,"method":"ping"}
    ;
    const response = try registry.dispatch(first, ping);
    defer testing.allocator.free(response);
    try testing.expectJson(.{ .id = 7, .result = .{} }, response);

    try registry.close(first);
    try testing.expect(!registry.contains(first));
    try testing.expect(registry.contains(second));
    try testing.expectError(error.SessionNotFound, registry.dispatch(first, ping));
}

test "MCP SessionRegistry enforces capacity" {
    defer testing.reset();
    var registry = Self.init(testing.allocator, testing.test_app, .{ .max_sessions = 1 });
    defer registry.deinit();

    _ = try registry.create();
    try testing.expectError(error.SessionLimitReached, registry.create());
}
