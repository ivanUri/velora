const std = @import("std");
const posix = @import("../../support/posix.zig");
const net = @import("../../support/net.zig");
const sync = @import("../../support/sync.zig");

const App = @import("../../runtime/App.zig");
const log = @import("../../support/log.zig");
const SessionRegistry = @import("SessionRegistry.zig");

const Self = @This();

const max_request_bytes = 16 * 1024 * 1024;
const max_header_bytes = 64 * 1024;

const Job = struct {
    kind: enum { rpc, close },
    body: []const u8,
    session_id: ?[]const u8,
    response: ?[]u8 = null,
    assigned_id: [32]u8 = undefined,
    assigned_len: usize = 0,
    status: u16 = 200,
    mutex: sync.Mutex = .{},
    condition: sync.Condition = .{},
    done: bool = false,
    next: ?*Job = null,

    fn finish(self: *Job) void {
        self.mutex.lock();
        self.done = true;
        self.condition.signal();
        self.mutex.unlock();
    }

    fn wait(self: *Job) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.done) self.condition.wait(&self.mutex);
    }

    fn setAssigned(self: *Job, id: []const u8) void {
        const len = @min(id.len, self.assigned_id.len);
        @memcpy(self.assigned_id[0..len], id[0..len]);
        self.assigned_len = len;
    }

    fn assigned(self: *const Job) []const u8 {
        return self.assigned_id[0..self.assigned_len];
    }
};

const Queue = struct {
    mutex: sync.Mutex = .{},
    condition: sync.Condition = .{},
    head: ?*Job = null,
    tail: ?*Job = null,
    closed: bool = false,
    length: usize = 0,
    max_length: usize,

    fn push(self: *Queue, job: *Job) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return error.ShuttingDown;
        if (self.length >= self.max_length) return error.QueueFull;
        job.next = null;
        if (self.tail) |tail| tail.next = job else self.head = job;
        self.tail = job;
        self.length += 1;
        self.condition.signal();
    }

    fn pop(self: *Queue) ?*Job {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.head == null and !self.closed) self.condition.wait(&self.mutex);
        const job = self.head orelse return null;
        self.head = job.next;
        if (self.head == null) self.tail = null;
        self.length -= 1;
        return job;
    }

    fn close(self: *Queue) void {
        self.mutex.lock();
        self.closed = true;
        self.condition.broadcast();
        self.mutex.unlock();
    }
};

allocator: std.mem.Allocator,
app: *App,
address: net.Address,
max_sessions: usize,
queue: Queue,
worker: std.Thread,
worker_mutex: sync.Mutex = .{},
worker_condition: sync.Condition = .{},
worker_ready: bool = false,
worker_ok: bool = false,
active_connections: std.atomic.Value(usize) = .init(0),

pub fn init(
    allocator: std.mem.Allocator,
    app: *App,
    address: net.Address,
    max_sessions: usize,
) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .app = app,
        .address = address,
        .max_sessions = max_sessions,
        .queue = .{ .max_length = 256 },
        .worker = undefined,
    };

    self.worker = try std.Thread.spawn(.{}, workerMain, .{self});
    self.worker_mutex.lock();
    while (!self.worker_ready) self.worker_condition.wait(&self.worker_mutex);
    const ok = self.worker_ok;
    self.worker_mutex.unlock();
    if (!ok) {
        self.worker.join();
        return error.WorkerInitFailed;
    }

    var bound = address;
    try app.network.bind(&bound, self, onAccept);
    self.address = bound;
    log.info(.mcp, "MCP HTTP server listening", .{ .address = bound });
    return self;
}

pub fn shutdown(self: *Self) void {
    self.app.network.unbind();
    self.queue.close();
}

pub fn deinit(self: *Self) void {
    self.shutdown();
    self.worker.join();
    while (self.active_connections.load(.acquire) != 0) {
        @import("../../support/timer.zig").sleepNanoseconds(std.time.ns_per_ms);
    }
    self.allocator.destroy(self);
}

fn workerMain(self: *Self) void {
    var registry = SessionRegistry.init(self.allocator, self.app, .{
        .max_sessions = self.max_sessions,
    });
    defer registry.deinit();

    self.worker_mutex.lock();
    self.worker_ok = true;
    self.worker_ready = true;
    self.worker_condition.signal();
    self.worker_mutex.unlock();

    while (self.queue.pop()) |job| {
        processJob(&registry, job);
        job.finish();
    }
}

fn processJob(registry: *SessionRegistry, job: *Job) void {
    const id = if (job.session_id) |existing| blk: {
        if (!registry.contains(existing)) {
            job.status = 404;
            return;
        }
        break :blk existing;
    } else blk: {
        if (job.kind == .close or !isInitialize(job.body)) {
            job.status = 400;
            return;
        }
        break :blk registry.create() catch |err| {
            job.status = if (err == error.SessionLimitReached) 429 else 500;
            return;
        };
    };
    job.setAssigned(id);

    if (job.kind == .close) {
        registry.close(id) catch {
            job.status = 404;
            return;
        };
        job.status = 204;
        return;
    }

    job.response = registry.dispatch(id, job.body) catch |err| {
        job.status = if (err == error.SessionNotFound) 404 else 500;
        return;
    };
    job.status = if (job.response.?.len == 0) 202 else 200;
}

fn isInitialize(body: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const InitRequest = struct { method: []const u8 };
    const request = std.json.parseFromSliceLeaky(InitRequest, arena.allocator(), body, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    return std.mem.eql(u8, request.method, "initialize");
}

fn onAccept(ctx: *anyopaque, socket: posix.socket_t) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const flags = posix.fcntl(socket, posix.F.GETFL, 0) catch {
        posix.close(socket);
        return;
    };
    _ = posix.fcntl(socket, posix.F.SETFL, flags & ~@as(u32, @bitCast(posix.O{ .NONBLOCK = true }))) catch {
        posix.close(socket);
        return;
    };
    _ = self.active_connections.fetchAdd(1, .acq_rel);
    const thread = std.Thread.spawn(.{}, handleConnection, .{ self, socket }) catch {
        _ = self.active_connections.fetchSub(1, .acq_rel);
        posix.close(socket);
        return;
    };
    thread.detach();
}

fn handleConnection(self: *Self, socket: posix.socket_t) void {
    defer _ = self.active_connections.fetchSub(1, .acq_rel);
    defer posix.close(socket);

    const timeout = std.mem.toBytes(posix.timeval{ .sec = 5, .usec = 0 });
    posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout) catch {};
    posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout) catch {};

    const request = readRequest(self.allocator, socket) catch {
        writeResponse(socket, 400, null, "") catch {};
        return;
    };
    defer self.allocator.free(request.storage);

    if (!std.mem.eql(u8, request.path, "/mcp")) {
        writeResponse(socket, 404, null, "") catch {};
        return;
    }

    var job: Job = .{
        .kind = if (std.mem.eql(u8, request.method, "DELETE")) .close else .rpc,
        .body = request.body,
        .session_id = request.session_id,
    };
    if (!std.mem.eql(u8, request.method, "POST") and job.kind != .close) {
        writeResponse(socket, 405, null, "") catch {};
        return;
    }
    self.queue.push(&job) catch {
        writeResponse(socket, 503, null, "") catch {};
        return;
    };
    job.wait();
    defer if (job.response) |response| self.allocator.free(response);
    writeResponse(socket, job.status, if (job.assigned_len > 0) job.assigned() else null, job.response orelse "") catch {};
}

const Request = struct {
    storage: []u8,
    method: []const u8,
    path: []const u8,
    session_id: ?[]const u8,
    body: []const u8,
};

fn readRequest(allocator: std.mem.Allocator, socket: posix.socket_t) !Request {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var header_end: ?usize = null;
    var content_length: usize = 0;
    var chunk: [8192]u8 = undefined;

    while (true) {
        const count = try posix.read(socket, &chunk);
        if (count == 0) return error.IncompleteRequest;
        try bytes.appendSlice(allocator, chunk[0..count]);
        if (bytes.items.len > max_request_bytes + max_header_bytes) return error.RequestTooLarge;

        if (header_end == null) {
            if (std.mem.indexOf(u8, bytes.items, "\r\n\r\n")) |end| {
                header_end = end + 4;
                if (end > max_header_bytes) return error.HeadersTooLarge;
                content_length = parseContentLength(bytes.items[0..end]) orelse 0;
                if (content_length > max_request_bytes) return error.RequestTooLarge;
            }
        }
        if (header_end) |end| {
            if (bytes.items.len >= end + content_length) break;
        }
    }

    const storage = try bytes.toOwnedSlice(allocator);
    const end = header_end.?;
    const first_line_end = std.mem.indexOf(u8, storage, "\r\n") orelse return error.InvalidRequest;
    var parts = std.mem.splitScalar(u8, storage[0..first_line_end], ' ');
    const method = parts.next() orelse return error.InvalidRequest;
    const path = parts.next() orelse return error.InvalidRequest;
    const session_id = parseHeader(storage[first_line_end + 2 .. end - 2], "Mcp-Session-Id");
    return .{
        .storage = storage,
        .method = method,
        .path = path,
        .session_id = session_id,
        .body = storage[end .. end + content_length],
    };
}

fn parseContentLength(headers: []const u8) ?usize {
    const raw = parseHeader(headers, "Content-Length") orelse return null;
    return std.fmt.parseInt(usize, raw, 10) catch null;
}

fn parseHeader(headers: []const u8, wanted: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), wanted)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn writeResponse(socket: posix.socket_t, status: u16, session_id: ?[]const u8, body: []const u8) !void {
    const reason = switch (status) {
        200 => "OK",
        202 => "Accepted",
        204 => "No Content",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        else => "Error",
    };
    var header: [1024]u8 = undefined;
    const rendered = if (session_id) |id|
        try std.fmt.bufPrint(
            &header,
            "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nMcp-Session-Id: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ status, reason, id, body.len },
        )
    else
        try std.fmt.bufPrint(
            &header,
            "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ status, reason, body.len },
        );
    try writeAll(socket, rendered);
    if (body.len > 0) try writeAll(socket, body);
}

fn writeAll(socket: posix.socket_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) offset += try posix.write(socket, bytes[offset..]);
}

const testing = @import("../../testing/testing.zig");

test "MCP HTTP parses headers case-insensitively" {
    try testing.expectString("abc", parseHeader(
        "Host: localhost\r\nmcp-session-id: abc\r\nContent-Length: 2",
        "Mcp-Session-Id",
    ).?);
    try testing.expectEqual(@as(?usize, 2), parseContentLength("content-length: 2"));
}

test "MCP HTTP requires initialize before minting a session" {
    try testing.expect(isInitialize(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize"}
    ));
    try testing.expect(!isInitialize(
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
    ));
}
