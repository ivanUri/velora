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
const posix = @import("../../support/posix.zig");
const net = @import("../../support/net.zig");
const runtime_io = @import("../../support/io.zig");
const builtin = @import("builtin");

const log = @import("../../support/log.zig");
const URL = @import("../../core/browser/URL.zig");
const IpFilter = @import("IpFilter.zig");
const WsConnection = @import("WsConnection.zig");
const TlsIo = @import("TlsIo.zig");
const H2WsSession = @import("H2WsSession.zig");

const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;
const invalid_socket: posix.socket_t = -1;

pub const FrameType = enum {
    text,
    binary,
    close,
    ping,
    pong,
    cont,
};

pub const State = enum {
    connecting,
    handshake,
    open,
    closed,
};

const Transport = enum {
    plain,
    tls_h1,
    h2,
};

pub const StartOpts = struct {
    ip_filter: ?*const IpFilter = null,
    tls_verify: bool = true,
    cookie_header: ?[]const u8 = null,
    /// Stable browser-context proxy selected by Config/CDP. HTTP CONNECT is
    /// used for both ws:// and wss:// so the target never receives a direct
    /// socket from the browser process.
    proxy: ?[:0]const u8 = null,
    /// Canonical BrowserPersona User-Agent used by both HTTP/1.1 and RFC 8441.
    user_agent: []const u8 = "",
};

pub const WebSocketClient = @This();

socket: posix.socket_t = invalid_socket,
socket_flags: usize = 0,
allocator: Allocator,
reader: ?WsConnection.Reader(false) = null,
handshake_buf: std.ArrayList(u8) = .empty,
set_cookies: std.ArrayList([]const u8) = .empty,
outbound: std.ArrayList(u8) = .empty,
outbound_pos: usize = 0,
negotiated_protocol: []const u8 = "",
origin: []const u8 = "",
protocols: []const []const u8 = &.{},
cookie_header: ?[]const u8 = null,
user_agent: []const u8 = "",
state: State = .connecting,
transport: Transport = .plain,
tls: ?*TlsIo = null,
h2: ?H2WsSession = null,

/// Validate scheme and allocate state. TCP connect is deferred to `start`.
pub fn create(
    allocator: Allocator,
    url: [:0]const u8,
    origin: []const u8,
    protocols: []const []const u8,
) !WebSocketClient {
    if (!std.mem.startsWith(u8, url, "ws:") and !std.mem.startsWith(u8, url, "wss:")) {
        return error.SyntaxError;
    }

    var reader = try WsConnection.Reader(false).init(allocator);
    errdefer reader.deinit();

    return .{
        .allocator = allocator,
        .reader = reader,
        .origin = origin,
        .protocols = protocols,
    };
}

/// Begin async TCP connect + HTTP upgrade (must not throw to caller).
pub fn start(self: *WebSocketClient, url: [:0]const u8, opts: StartOpts) void {
    if (self.state != .connecting) return;
    self.cookie_header = opts.cookie_header;
    self.user_agent = opts.user_agent;
    self.startImpl(url, opts) catch {
        self.state = .closed;
    };
}

fn startImpl(self: *WebSocketClient, url: [:0]const u8, opts: StartOpts) !void {
    const is_tls = std.mem.startsWith(u8, url, "wss:");
    const hostname = URL.getHostname(url);
    const port_str = URL.getPort(url);
    const port: u16 = if (port_str.len > 0)
        try std.fmt.parseInt(u16, port_str, 10)
    else if (is_tls)
        443
    else
        80;

    const target_address = try resolveAddress(self.allocator, hostname, port);
    if (opts.ip_filter) |filter| {
        if (filter.isBlockedAddress(target_address)) return error.ConnectionRefused;
    }

    const connect_address = if (opts.proxy) |proxy| blk: {
        if (!std.mem.startsWith(u8, proxy, "http://")) return error.UnsupportedProxyScheme;
        const proxy_host = URL.getHostname(proxy);
        const proxy_port_text = URL.getPort(proxy);
        const proxy_port: u16 = if (proxy_port_text.len == 0)
            80
        else
            try std.fmt.parseInt(u16, proxy_port_text, 10);
        const proxy_address = try resolveAddress(self.allocator, proxy_host, proxy_port);
        if (opts.ip_filter) |filter| {
            if (filter.isBlockedAddress(proxy_address)) return error.ConnectionRefused;
        }
        break :blk proxy_address;
    } else target_address;

    const socket = connectTcp(connect_address) catch |err| fallback: {
        // Never fall back to a direct target socket when a proxy route was
        // requested. That would leak traffic outside the browser context.
        if (opts.proxy != null or err != error.ConnectionRefused or !isLocalhostHostname(hostname)) return err;
        const v4 = net.Address.parseIp("127.0.0.1", port) catch return err;
        if (opts.ip_filter) |filter| {
            if (filter.isBlockedAddress(v4)) return error.ConnectionRefused;
        }
        break :fallback try connectTcp(v4);
    };
    errdefer posix.close(socket);

    const socket_flags = try posix.fcntl(socket, posix.F.GETFL, 0);
    self.socket = socket;
    self.socket_flags = socket_flags;

    if (opts.proxy) |proxy| {
        try connectHttpProxyTunnel(self.allocator, socket, proxy, hostname, port);
    }

    if (is_tls) {
        try self.startTls(url, hostname, opts.tls_verify);
        return;
    }

    self.transport = .plain;
    self.state = .handshake;
    try self.sendHandshake(url, self.origin, self.protocols);
    try self.finishHandshakeSync();

    const nonblocking = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
    _ = try posix.fcntl(socket, posix.F.SETFL, socket_flags | nonblocking);
}

fn connectHttpProxyTunnel(
    allocator: Allocator,
    socket: posix.socket_t,
    proxy: [:0]const u8,
    target_host: []const u8,
    target_port: u16,
) !void {
    const request = try buildProxyConnectRequest(allocator, proxy, target_host, target_port);
    defer allocator.free(request);

    var written: usize = 0;
    while (written < request.len) {
        const n = try posix.write(socket, request[written..]);
        if (n == 0) return error.ConnectionRefused;
        written += n;
    }

    var response: [8192]u8 = undefined;
    var used: usize = 0;
    while (std.mem.indexOf(u8, response[0..used], "\r\n\r\n") == null) {
        if (used == response.len) return error.ProxyResponseTooLarge;
        const n = try posix.read(socket, response[used..]);
        if (n == 0) return error.ConnectionRefused;
        used += n;
    }

    const first_line_end = std.mem.indexOf(u8, response[0..used], "\r\n") orelse return error.InvalidProxyResponse;
    const first_line = response[0..first_line_end];
    var fields = std.mem.splitScalar(u8, first_line, ' ');
    _ = fields.next() orelse return error.InvalidProxyResponse;
    const status_text = fields.next() orelse return error.InvalidProxyResponse;
    const status = std.fmt.parseInt(u16, status_text, 10) catch return error.InvalidProxyResponse;
    if (status != 200) return error.ProxyConnectRejected;
}

fn buildProxyConnectRequest(
    allocator: Allocator,
    proxy: [:0]const u8,
    target_host: []const u8,
    target_port: u16,
) ![]u8 {
    var request: std.ArrayList(u8) = .empty;
    errdefer request.deinit(allocator);
    const first_line = try std.fmt.allocPrint(
        allocator,
        "CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\nProxy-Connection: Keep-Alive\r\n",
        .{ target_host, target_port, target_host, target_port },
    );
    defer allocator.free(first_line);
    try request.appendSlice(allocator, first_line);

    const encoded_user = URL.getUsername(proxy);
    if (encoded_user.len > 0) {
        const user = try percentDecode(allocator, encoded_user);
        defer allocator.free(user);
        const password = try percentDecode(allocator, URL.getPassword(proxy));
        defer allocator.free(password);
        const credentials = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ user, password });
        defer allocator.free(credentials);
        const encoded_len = std.base64.standard.Encoder.calcSize(credentials.len);
        const encoded = try allocator.alloc(u8, encoded_len);
        defer allocator.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, credentials);
        const authorization = try std.fmt.allocPrint(allocator, "Proxy-Authorization: Basic {s}\r\n", .{encoded});
        defer allocator.free(authorization);
        try request.appendSlice(allocator, authorization);
    }
    try request.appendSlice(allocator, "\r\n");
    return request.toOwnedSlice(allocator);
}

fn percentDecode(allocator: Allocator, encoded: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            const high = std.fmt.charToDigit(encoded[i + 1], 16) catch return error.InvalidProxyCredentials;
            const low = std.fmt.charToDigit(encoded[i + 2], 16) catch return error.InvalidProxyCredentials;
            try out.append(allocator, (high << 4) | low);
            i += 3;
        } else {
            try out.append(allocator, encoded[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

test "WebSocket HTTP proxy CONNECT uses decoded Basic credentials" {
    const allocator = std.testing.allocator;
    const request = try buildProxyConnectRequest(
        allocator,
        "http://user%40example:p%40ss@127.0.0.1:8080",
        "echo.example",
        443,
    );
    defer allocator.free(request);
    try std.testing.expect(std.mem.startsWith(u8, request, "CONNECT echo.example:443 HTTP/1.1\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, request, "Proxy-Authorization: Basic dXNlckBleGFtcGxlOnBAc3M=\r\n") != null);
}

fn startTls(self: *WebSocketClient, url: [:0]const u8, hostname: []const u8, tls_verify: bool) !void {
    _ = try posix.fcntl(self.socket, posix.F.SETFL, self.socket_flags);

    const tls = try self.allocator.create(TlsIo);
    errdefer self.allocator.destroy(tls);
    tls.* = try TlsIo.init(hostname, self.socket, tls_verify);
    errdefer tls.deinit();
    try tls.connectBlocking();

    const alpn = tls.alpnProtocol();
    if (std.mem.eql(u8, alpn, "h2")) {
        self.transport = .h2;
        self.tls = tls;
        const host = URL.getHost(url);
        var pathname = URL.getPathname(url);
        if (pathname.len == 0) pathname = "/";
        const search = URL.getSearch(url);

        self.h2 = H2WsSession.init(
            self.allocator,
            tls,
            &(self.reader orelse return error.InvalidState),
            host,
            pathname,
            search,
            self.origin,
            self.user_agent,
            self.protocols,
            &self.set_cookies,
        ) catch |err| {
            self.tls = null;
            self.transport = .plain;
            tls.deinit();
            self.allocator.destroy(tls);
            if (self.socket != invalid_socket) {
                posix.close(self.socket);
                self.socket = invalid_socket;
            }
            return err;
        };
        self.negotiated_protocol = self.h2.?.negotiated_protocol;
        self.state = .open;

        const nonblocking = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
        _ = try posix.fcntl(self.socket, posix.F.SETFL, self.socket_flags | nonblocking);
        return;
    }

    self.tls = tls;
    self.transport = .tls_h1;
    self.state = .handshake;
    try self.sendHandshake(url, self.origin, self.protocols);
    try self.finishHandshakeSync();

    const nonblocking = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
    _ = try posix.fcntl(self.socket, posix.F.SETFL, self.socket_flags | nonblocking);
}

/// Blocking send/receive for the HTTP 101 upgrade (reliable before event-loop poll).
fn finishHandshakeSync(self: *WebSocketClient) !void {
    errdefer self.setNonBlocking() catch {};

    while (self.outbound_pos < self.outbound.items.len) {
        const written = try self.transportWrite(self.outbound.items[self.outbound_pos..]);
        if (written == 0) return error.ConnectionRefused;
        self.outbound_pos += written;
    }
    self.outbound.clearRetainingCapacity();
    self.outbound_pos = 0;

    while (!std.mem.endsWith(u8, self.handshake_buf.items, "\r\n\r\n")) {
        var chunk: [4096]u8 = undefined;
        const n = try self.transportRead(&chunk);
        if (n == 0) return error.ConnectionRefused;
        try self.handshake_buf.appendSlice(self.allocator, chunk[0..n]);
    }

    try self.setNonBlocking();

    switch (try self.processHandshake()) {
        .open => {},
        else => {
            self.state = .closed;
            return error.ConnectionRefused;
        },
    }
}

fn setNonBlocking(self: *WebSocketClient) !void {
    const nonblocking = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
    _ = try posix.fcntl(self.socket, posix.F.SETFL, self.socket_flags | nonblocking);
}

fn transportRead(self: *WebSocketClient, buf: []u8) !usize {
    return switch (self.transport) {
        .plain => posix.read(self.socket, buf),
        .tls_h1, .h2 => self.tls.?.read(buf),
    };
}

fn transportWrite(self: *WebSocketClient, data: []const u8) !usize {
    return switch (self.transport) {
        .plain => posix.write(self.socket, data),
        .tls_h1, .h2 => self.tls.?.write(data),
    };
}

pub fn deinit(self: *WebSocketClient) void {
    if (self.h2) |*h2| h2.deinit();
    if (self.tls) |tls| {
        tls.deinit();
        self.allocator.destroy(tls);
    }
    if (self.reader) |*r| r.deinit();
    self.handshake_buf.deinit(self.allocator);
    for (self.set_cookies.items) |cookie| {
        self.allocator.free(cookie);
    }
    self.set_cookies.deinit(self.allocator);
    self.outbound.deinit(self.allocator);
    if (self.socket != invalid_socket) posix.close(self.socket);
    self.socket = invalid_socket;
    self.state = .closed;
}

pub fn poll(self: *WebSocketClient) !PollResult {
    if (self.state == .closed or self.state == .connecting) return .closed;

    if (self.transport == .h2) {
        if (self.h2) |*h2| {
            h2.pump() catch |err| switch (err) {
                error.ConnectionClosed => {
                    self.state = .closed;
                    return .closed;
                },
                else => return err,
            };
        }
        if (self.outbound_pos < self.outbound.items.len) {
            try self.flushOutbound();
        }
        return self.pollResultAfterRead(0);
    }

    if (self.outbound_pos < self.outbound.items.len) {
        try self.flushOutbound();
    }

    const reader = &(self.reader orelse return .closed);
    const n = self.transportRead(reader.readBuf()) catch |err| switch (err) {
        error.WouldBlock => return self.pollResultAfterRead(0),
        else => {
            self.state = .closed;
            return .closed;
        },
    };

    if (n == 0) {
        self.state = .closed;
        return .closed;
    }
    reader.len += n;

    const result = try self.pollResultAfterRead(n);

    if (self.outbound_pos < self.outbound.items.len) {
        try self.flushOutbound();
    }

    return result;
}

fn pollResultAfterRead(self: *WebSocketClient, _: usize) !PollResult {
    switch (self.state) {
        .handshake => return self.processHandshake(),
        .open => return self.processFrames(),
        .connecting, .closed => return .closed,
    }
}

pub fn queueFrame(self: *WebSocketClient, frame_type: FrameType, payload: []const u8) !void {
    if (self.state != .open and self.state != .handshake) return error.InvalidState;

    var mask_key: [4]u8 = undefined;
    runtime_io.get().random(&mask_key);

    var header_buf: [14]u8 = undefined;
    const opcode: u8 = switch (frame_type) {
        .text => 0x01,
        .binary => 0x02,
        .close => 0x08,
        .ping => 0x09,
        .pong => 0x0a,
        .cont => 0x00,
    };

    // Empty close frames (code 1005 / close() without a code) use payload_len == 0.
    const header = clientFrameHeader(&header_buf, opcode, payload.len, &mask_key);
    const prev_len = self.outbound.items.len;
    try self.outbound.ensureTotalCapacity(self.allocator, prev_len + header.len + payload.len);
    self.outbound.appendSliceAssumeCapacity(header);

    const payload_start = self.outbound.items.len;
    if (payload.len > 0) {
        try self.outbound.appendSlice(self.allocator, payload);
        maskPayload(mask_key, self.outbound.items[payload_start..]);
    }

    try self.flushOutbound();
}

fn flushOutbound(self: *WebSocketClient) !void {
    if (self.socket == invalid_socket) return;

    if (self.transport == .h2) {
        if (self.h2) |*h2| {
            const data = self.outbound.items[self.outbound_pos..];
            if (data.len == 0) return;
            h2.submitBytes(data) catch |err| switch (err) {
                error.H2Busy => return,
                else => return err,
            };
            self.outbound.clearRetainingCapacity();
            self.outbound_pos = 0;
        }
        return;
    }

    while (self.outbound_pos < self.outbound.items.len) {
        const written = self.transportWrite(self.outbound.items[self.outbound_pos..]) catch |err| switch (err) {
            error.WouldBlock => return,
            else => {
                self.state = .closed;
                return;
            },
        };
        if (written == 0) {
            self.state = .closed;
            return;
        }
        self.outbound_pos += written;
    }
    self.outbound.clearRetainingCapacity();
    self.outbound_pos = 0;
}

pub const PollResult = union(enum) {
    idle,
    open: struct {
        protocol: []const u8,
        set_cookies: []const []const u8,
    },
    message: struct { frame_type: FrameType, data: []const u8, owned: bool },
    closed,
};

pub fn takeSetCookies(self: *WebSocketClient) []const []const u8 {
    const items = self.set_cookies.items;
    self.set_cookies.clearRetainingCapacity();
    return items;
}

fn processHandshake(self: *WebSocketClient) !PollResult {
    const reader = &(self.reader orelse return .closed);
    try self.handshake_buf.appendSlice(self.allocator, reader.buf[0..reader.len]);
    reader.len = 0;

    const buf = self.handshake_buf.items;
    if (!std.mem.endsWith(u8, buf, "\r\n\r\n")) return .idle;

    if (std.mem.indexOf(u8, buf, " 101 ") == null) {
        self.state = .closed;
        return .closed;
    }

    var got_upgrade = false;
    var protocol: []const u8 = "";

    var lines = std.mem.splitSequence(u8, buf, "\r\n");
    _ = lines.next();

    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
            if (std.ascii.eqlIgnoreCase(value, "websocket")) got_upgrade = true;
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-protocol")) {
            protocol = try self.allocator.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(name, "set-cookie")) {
            try self.set_cookies.append(self.allocator, try self.allocator.dupe(u8, value));
        }
    }

    if (!got_upgrade) {
        self.state = .closed;
        return .closed;
    }

    self.negotiated_protocol = protocol;

    // Bytes after the HTTP headers may already contain WebSocket frames (common
    // when the TLS read returns the 101 response plus the first server frame).
    const header_end = (std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return .idle) + 4;
    const trailing = buf[header_end..];
    if (trailing.len > 0) {
        if (reader.len + trailing.len > reader.buf.len) return error.BufferOverflow;
        @memcpy(reader.buf[reader.len .. reader.len + trailing.len], trailing);
        reader.len += trailing.len;
    }

    self.handshake_buf.clearRetainingCapacity();
    self.state = .open;

    if (comptime IS_DEBUG) {
        log.debug(.websocket, "native handshake complete", .{ .protocol = protocol });
    }

    return .{ .open = .{ .protocol = protocol, .set_cookies = self.set_cookies.items } };
}

fn processFrames(self: *WebSocketClient) !PollResult {
    const reader = &(self.reader orelse return .closed);
    while (true) {
        const msg = reader.next() catch {
            self.state = .closed;
            return .closed;
        } orelse break;

        const frame_type: FrameType = switch (msg.type) {
            .text => .text,
            .binary => .binary,
            .close => .close,
            .ping => .ping,
            .pong => .pong,
        };

        if (msg.type == .ping) {
            try self.queueFrame(.pong, msg.data);
            if (msg.cleanup_fragment) reader.cleanup();
            continue;
        }

        if (msg.cleanup_fragment) {
            const data = try self.allocator.dupe(u8, msg.data);
            reader.cleanup();
            return .{ .message = .{ .frame_type = frame_type, .data = data, .owned = true } };
        }

        return .{ .message = .{ .frame_type = frame_type, .data = msg.data, .owned = false } };
    }

    reader.compact();
    return .idle;
}

fn sendHandshake(self: *WebSocketClient, url: [:0]const u8, origin: []const u8, protocols: []const []const u8) !void {
    var pathname = URL.getPathname(url);
    if (pathname.len == 0) pathname = "/";
    const search = URL.getSearch(url);

    var key_bytes: [16]u8 = undefined;
    runtime_io.get().random(&key_bytes);
    var key_b64_buf: [32]u8 = undefined;
    const key_b64 = std.base64.standard.Encoder.encode(&key_b64_buf, &key_bytes);

    var req: std.Io.Writer.Allocating = .init(self.allocator);
    defer req.deinit();
    const writer = &req.writer;

    const host = URL.getHost(url);
    try writer.print(
        "GET {s}{s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n",
        .{ pathname, search, host, key_b64 },
    );

    if (origin.len > 0 and !std.mem.eql(u8, origin, "null")) {
        try writer.print("Origin: {s}\r\n", .{origin});
    }
    if (self.user_agent.len > 0) {
        try writer.print("User-Agent: {s}\r\n", .{self.user_agent});
    }

    if (protocols.len > 0) {
        const joined = try std.mem.join(self.allocator, ", ", protocols);
        defer self.allocator.free(joined);
        try writer.print("Sec-WebSocket-Protocol: {s}\r\n", .{joined});
    }

    if (self.cookie_header) |cookies| {
        if (cookies.len > 0) {
            try writer.print("Cookie: {s}\r\n", .{cookies});
        }
    }

    try writer.writeAll("\r\n");
    try self.outbound.appendSlice(self.allocator, req.written());
}

fn clientFrameHeader(buf: []u8, opcode: u8, payload_len: usize, mask_key: *[4]u8) []const u8 {
    buf[0] = 0x80 | opcode;
    var header_len: usize = 2;

    if (payload_len <= 125) {
        buf[1] = 0x80 | @as(u8, @intCast(payload_len));
    } else if (payload_len <= 65535) {
        buf[1] = 0x80 | 126;
        buf[2] = @intCast((payload_len >> 8) & 0xFF);
        buf[3] = @intCast(payload_len & 0xFF);
        header_len = 4;
    } else {
        buf[1] = 0x80 | 127;
        @memset(buf[2..6], 0);
        buf[6] = @intCast((payload_len >> 24) & 0xFF);
        buf[7] = @intCast((payload_len >> 16) & 0xFF);
        buf[8] = @intCast((payload_len >> 8) & 0xFF);
        buf[9] = @intCast(payload_len & 0xFF);
        header_len = 10;
    }

    @memcpy(buf[header_len .. header_len + 4], mask_key);
    return buf[0 .. header_len + 4];
}

fn maskPayload(mask_key: [4]u8, payload: []u8) void {
    for (payload, 0..) |*b, i| {
        b.* ^= mask_key[i & 3];
    }
}

fn hostWithoutBrackets(host: []const u8) []const u8 {
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']')
        return host[1 .. host.len - 1];
    return host;
}

fn isLiteralIpv6Host(host: []const u8) bool {
    return std.mem.indexOfScalar(u8, hostWithoutBrackets(host), ':') != null;
}

fn isLocalhostHostname(host: []const u8) bool {
    const clean = hostWithoutBrackets(host);
    if (isLiteralIpv6Host(host)) return false;
    return std.ascii.eqlIgnoreCase(clean, "localhost") or std.mem.eql(u8, clean, "127.0.0.1");
}

fn connectTcp(address: net.Address) !posix.socket_t {
    const socket = try posix.socket(address.any.family, posix.SOCK.STREAM, 0);
    errdefer posix.close(socket);
    try posix.connect(socket, &address.any, address.getOsSockLen());
    return socket;
}

fn resolveAddress(allocator: Allocator, host: []const u8, port: u16) !net.Address {
    const clean = hostWithoutBrackets(host);

    // Literal IPv4/IPv6 (e.g. 127.0.0.1, ::1, [2001:db8::1]) bypass getaddrinfo.
    if (net.Address.parseIp(clean, port)) |addr| return addr else |_| {}

    const c = @cImport({
        @cInclude("netdb.h");
        @cInclude("sys/socket.h");
    });

    const host_z = try allocator.dupeZ(u8, clean);
    defer allocator.free(host_z);

    var port_buf: [16]u8 = undefined;
    const port_slice = try std.fmt.bufPrint(&port_buf, "{d}", .{port});
    const port_z = try allocator.dupeZ(u8, port_slice);
    defer allocator.free(port_z);

    var hints: c.struct_addrinfo = std.mem.zeroes(c.struct_addrinfo);
    hints.ai_family = c.AF_UNSPEC;
    hints.ai_socktype = c.SOCK_STREAM;

    var res: ?*c.struct_addrinfo = null;
    if (c.getaddrinfo(host_z.ptr, port_z.ptr, &hints, &res) != 0) return error.UnknownHost;
    defer c.freeaddrinfo(res);

    // Prefer IPv4 over IPv6: WPT h2 servers often bind IPv4-only while getaddrinfo
    // may list ::1 before 127.0.0.1 for "localhost".
    var cur = res;
    var fallback: ?net.Address = null;
    while (cur) |ai| : (cur = ai.ai_next) {
        if (ai.ai_addr == null) continue;
        const sa: *posix.sockaddr = @ptrCast(@alignCast(ai.ai_addr));
        const addr = net.Address.initPosix(@ptrCast(@alignCast(sa)));
        if (addr.any.family == posix.AF.INET) return addr;
        if (fallback == null) fallback = addr;
    }

    if (fallback) |addr| {
        if (addr.any.family == posix.AF.INET6 and isLocalhostHostname(host)) {
            if (net.Address.parseIp("127.0.0.1", port)) |v4| return v4 else |_| {}
        }
        return addr;
    }
    return error.UnknownHost;
}
