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
const RC = @import("../../../support/rc.zig").RC;

const http = @import("../../../runtime/network/http.zig");
const WebSocketClient = @import("../../../runtime/network/WebSocketClient.zig");

const js = @import("../../js/js.zig");
const Blob = @import("../Blob.zig");
const URL = @import("../../browser/URL.zig");

const Page = @import("../../browser/Page.zig");
const Frame = @import("../../browser/Frame.zig");
const HttpClient = @import("../../browser/HttpClient.zig");

const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");
const CloseEvent = @import("../event/CloseEvent.zig");
const MessageEvent = @import("../event/MessageEvent.zig");

const log = @import("../../../support/log.zig");
const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

const WebSocket = @This();

_rc: RC(u8) = .{},
_frame: *Frame,
_page: *Page,
_proto: *EventTarget,
_arena: Allocator,

// Connection state
_ready_state: ReadyState = .connecting,
_url: [:0]const u8 = "",
_binary_type: BinaryType = .blob,

_client: ?WebSocketClient,
_http_client: *HttpClient,
_poll_node: std.DoublyLinkedList.Node = .{},
/// `pollNative` may reenter navigation teardown; defer `cleanup` until poll ends.
_poll_depth: u32 = 0,
_kill_pending: bool = false,

// buffered outgoing messages
_send_queue: std.ArrayList(Message) = .empty,
_send_offset: usize = 0,

// close info for event dispatch
_close_code: u16 = 1000,
_close_reason: []const u8 = "",

// negotiated protocol
_protocol: []const u8 = "",

// Event handlers
_on_open: ?js.Function.Temp = null,
_on_message: ?js.Function.Temp = null,
_on_error: ?js.Function.Temp = null,
_on_close: ?js.Function.Temp = null,

pub const ReadyState = enum(u8) {
    connecting = 0,
    open = 1,
    closing = 2,
    closed = 3,
};

pub const BinaryType = enum {
    blob,
    arraybuffer,
};

/// Resolve + normalize per WebSockets Standard §4.1 (http→ws, https→wss, reject fragment/non-ws).
/// WebSocket URLs always use UTF-8 percent-encoding (not the document encoding).
fn normalizeWebSocketUrl(allocator: Allocator, base: [:0]const u8, url: []const u8) ![:0]const u8 {
    if (std.mem.indexOfScalar(u8, url, '#') != null) {
        return error.SyntaxError;
    }
    const resolved = URL.resolve(allocator, base, url, .{ .always_dupe = true, .encoding = "UTF-8" }) catch |err| {
        if (err == error.TypeError) return error.SyntaxError;
        return err;
    };
    const protocol = URL.getProtocol(resolved);
    if (std.ascii.eqlIgnoreCase(protocol, "http:") or std.ascii.eqlIgnoreCase(protocol, "https:")) {
        const ws_scheme: []const u8 = if (std.ascii.eqlIgnoreCase(protocol, "http:")) "ws" else "wss";
        return URL.setProtocol(resolved, ws_scheme, allocator);
    }
    if (std.ascii.eqlIgnoreCase(protocol, "ws:") or std.ascii.eqlIgnoreCase(protocol, "wss:")) {
        return resolved;
    }
    return error.SyntaxError;
}

pub fn init(url: []const u8, protocols: [][]const u8, frame: *Frame) !*WebSocket {
    for (protocols) |protocol| {
        if (!isValidProtocol(protocol)) {
            return error.SyntaxError;
        }
    }
    for (protocols, 0..) |a, i| {
        for (protocols[i + 1 ..]) |b| {
            if (std.ascii.eqlIgnoreCase(a, b)) return error.SyntaxError;
        }
    }

    const arena = try frame.getArena(.medium, "WebSocket");
    errdefer frame.releaseArena(arena);

    const resolved_url = try normalizeWebSocketUrl(arena, frame.base(), url);

    const http_client = &frame._session.browser.http_client;
    const origin = try frame.requestOrigin();

    const protocols_copy = try arena.alloc([]const u8, protocols.len);
    for (protocols, 0..) |protocol, i| {
        protocols_copy[i] = try arena.dupe(u8, protocol);
    }

    const client = try WebSocketClient.create(arena, resolved_url, origin, protocols_copy);

    const self = try frame._factory.eventTargetWithAllocator(arena, WebSocket{
        ._frame = frame,
        ._page = frame._page,
        ._client = client,
        ._arena = arena,
        ._proto = undefined,
        ._url = resolved_url,
        ._http_client = http_client,
    });

    http_client.trackNativeWebSocket(self);

    if (comptime IS_DEBUG) {
        log.info(.websocket, "connecting", .{ .url = url });
    }

    self.acquireRef();
    return self;
}

pub fn deinit(self: *WebSocket, page: *Page) void {
    self.cleanup();

    if (self._on_open) |func| {
        func.release();
    }
    if (self._on_message) |func| {
        func.release();
    }
    if (self._on_error) |func| {
        func.release();
    }
    if (self._on_close) |func| {
        func.release();
    }

    for (self._send_queue.items) |msg| {
        msg.deinit(page);
    }

    page.releaseArena(self._arena);
}

pub fn releaseRef(self: *WebSocket, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *WebSocket) void {
    self._rc.acquire();
}

fn asEventTarget(self: *WebSocket) *EventTarget {
    return self._proto;
}

pub fn pollDepth(self: *const WebSocket) u32 {
    return self._poll_depth;
}

pub fn kill(self: *WebSocket) void {
    self._ready_state = .closed;
    self.finishDeferredCleanup();
}

fn finishDeferredCleanup(self: *WebSocket) void {
    if (self._poll_depth > 0) {
        self._kill_pending = true;
        return;
    }
    if (self._kill_pending) self._kill_pending = false;
    self.cleanup();
}

pub fn disconnected(self: *WebSocket, err_: ?anyerror) void {
    // H2/wss may surface EOF as ConnectionClosed after a completed close handshake.
    const was_clean = self._ready_state == .closing and
        (err_ == null or err_.? == error.ConnectionClosed);
    self._ready_state = .closed;

    if (err_) |err| {
        log.warn(.websocket, "disconnected", .{ .err = err, .url = self._url });
    } else {
        log.info(.websocket, "disconnected", .{ .url = self._url, .reason = "closed" });
    }

    defer self.finishDeferredCleanup();

    // Teardown / navigated-away: update state only — no DOM events (XHR pattern).
    if (!self._frame.js.execution.canEnterJs(.allow_draining)) return;

    const code = if (was_clean) self._close_code else 1006;
    const reason = if (was_clean) self._close_reason else "";

    if (!was_clean) {
        self.dispatchErrorEvent() catch |err| {
            log.err(.websocket, "error event dispatch failed", .{ .err = err });
        };
    }

    self.dispatchCloseEvent(code, reason, was_clean) catch |err| {
        log.err(.websocket, "close event dispatch failed", .{ .err = err });
    };
}

fn cleanup(self: *WebSocket) void {
    if (self._client) |*client| {
        self._http_client.untrackNativeWebSocket(self);
        client.deinit();
        self._client = null;
        self.releaseRef(self._page);
        self._send_queue.clearRetainingCapacity();
    }
}

fn applyHandshakeSetCookies(self: *WebSocket, set_cookies: []const []const u8) void {
    const jar = &self._frame._session.cookie_jar;
    for (set_cookies) |set_cookie| {
        jar.populateFromResponse(self._url, set_cookie, self._frame.topLevelUrl()) catch |err| {
            log.warn(.websocket, "handshake Set-Cookie ignored", .{ .raw = set_cookie, .err = err });
        };
    }
}

fn getHandshakeCookieHeader(self: *WebSocket) !?[]const u8 {
    var buf = std.Io.Writer.Allocating.init(self._arena);
    try self._frame._session.cookie_jar.forRequest(self._url, &buf.writer, .{
        .is_http = true,
        .origin_url = self._frame.url,
        .top_level_url = self._frame.topLevelUrl(),
        .is_navigation = false,
    });
    if (buf.written().len == 0) return null;
    return try self._arena.dupe(u8, buf.written());
}

/// Promote to OPEN and fire the open event when the native client is ready but
/// WebSocket._ready_state is still CONNECTING (sync h2/wss connect or race).
fn dispatchOpenIfReady(
    self: *WebSocket,
    client: *const WebSocketClient,
    protocol: ?[]const u8,
    set_cookies: []const []const u8,
) !bool {
    if (self._ready_state != .connecting or client.state != .open) return false;

    self.applyHandshakeSetCookies(set_cookies);

    self._ready_state = .open;
    self._protocol = protocol orelse client.negotiated_protocol;
    log.info(.websocket, "connected", .{ .url = self._url });
    if (self._frame.js.execution.canEnterJs(.allow_draining)) {
        self.dispatchOpenEvent() catch |err| {
            log.err(.websocket, "open event fail", .{ .err = err });
        };
    }
    try self.flushSendQueue();
    return true;
}

/// Called from HttpClient.tick to drive the native socket.
pub fn pollNative(self: *WebSocket) !bool {
    // Bump before any frame deref so `destroyPage` defers while this poll is on-stack.
    self._poll_depth += 1;
    defer {
        self._poll_depth -= 1;
        if (self._poll_depth == 0 and self._kill_pending) self.finishDeferredCleanup();
    }

    if (self._frame._realm_state == .dead or self._frame._realm_state == .draining or self._frame.isGoingAway()) {
        self.kill();
        return true;
    }
    if (self._ready_state == .closed) return false;

    const client = &(self._client orelse return false);

    if (client.state == .connecting) {
        const cookie_header = try self.getHandshakeCookieHeader();
        client.start(self._url, .{
            .ip_filter = self._http_client.network.ip_filter,
            .tls_verify = self._http_client.tls_verify,
            .cookie_header = cookie_header,
            .proxy = self._http_client.currentProxy(),
            .user_agent = self._http_client.getUserAgent(),
        });
        if (client.state == .closed) {
            self.disconnected(error.ConnectionRefused);
            return true;
        }
        if (client.state == .open and self._ready_state == .connecting) {
            if (try self.dispatchOpenIfReady(client, null, client.takeSetCookies())) return true;
            if (self._client == null or self._kill_pending) return true;
        }
        return false;
    }

    // start() may have completed synchronously (h2/wss) before this poll tick.
    if (client.state == .open and self._ready_state == .connecting) {
        if (try self.dispatchOpenIfReady(client, null, client.takeSetCookies())) return true;
        if (self._client == null or self._kill_pending) return true;
    }

    const result = client.poll() catch |err| {
        self.disconnected(err);
        return true;
    };

    switch (result) {
        .idle => {
            try self.flushSendQueue();
            return false;
        },
        .open => |info| {
            if (self._ready_state == .connecting) {
                if (try self.dispatchOpenIfReady(client, info.protocol, client.takeSetCookies())) return true;
                if (self._client == null or self._kill_pending) return true;
            }
            try self.flushSendQueue();
            return true;
        },
        .message => |msg| {
            defer if (msg.owned) self._arena.free(msg.data);
            try self.handleIncomingFrame(msg.frame_type, msg.data);
            if (self._client == null or self._kill_pending) return true;
            try self.flushSendQueue();
            return true;
        },
        .closed => {
            self.disconnected(null);
            return true;
        },
    }
}

fn handleIncomingFrame(self: *WebSocket, frame_type: WebSocketClient.FrameType, data: []const u8) !void {
    switch (frame_type) {
        .text, .binary => {
            const ws_type: http.WsFrameType = if (frame_type == .text) .text else .binary;
            try self.dispatchMessageEvent(data, ws_type);
        },
        .close => {
            const received_code = if (data.len >= 2)
                @as(u16, data[0]) << 8 | data[1]
            else
                1005;

            if (self._ready_state == .closing) {
                self.disconnected(null);
            } else {
                self._close_code = received_code;
                if (data.len > 2) {
                    self._close_reason = try self._arena.dupe(u8, data[2..]);
                } else {
                    self._close_reason = "";
                }
                self._ready_state = .closing;
                try self.queueMessage(.close);
            }
        },
        .ping => {
            if (self._client) |*client| {
                try client.queueFrame(.pong, data);
            }
        },
        .pong, .cont => {},
    }
}

fn flushSendQueue(self: *WebSocket) !void {
    const client = &(self._client orelse return);
    if (self._ready_state != .open and self._ready_state != .closing) return;

    while (self._send_queue.items.len > 0) {
        const msg = self._send_queue.items[0];
        switch (msg) {
            .close => {
                const code = self._close_code;
                const reason = self._close_reason;
                if (code == 1005) {
                    try client.queueFrame(.close, reason);
                } else {
                    const reason_len: usize = @min(reason.len, 123);
                    var payload: [125]u8 = undefined;
                    payload[0] = @intCast((code >> 8) & 0xFF);
                    payload[1] = @intCast(code & 0xFF);
                    if (reason_len > 0) {
                        @memcpy(payload[2..][0..reason_len], reason[0..reason_len]);
                    }
                    try client.queueFrame(.close, payload[0 .. 2 + reason_len]);
                }
                _ = self._send_queue.orderedRemove(0);
            },
            .text => |content| {
                try client.queueFrame(.text, content.data);
                const removed = self._send_queue.orderedRemove(0);
                removed.deinit(self._frame._page);
                self._send_offset = 0;
            },
            .binary => |content| {
                try client.queueFrame(.binary, content.data);
                const removed = self._send_queue.orderedRemove(0);
                removed.deinit(self._frame._page);
                self._send_offset = 0;
            },
        }
    }
}

fn queueMessage(self: *WebSocket, msg: Message) !void {
    try self._send_queue.append(self._arena, msg);
}

fn isValidProtocol(protocol: []const u8) bool {
    if (protocol.len == 0) return false;
    for (protocol) |c| {
        if (c <= 31 or c >= 127) return false;
        switch (c) {
            '(', ')', '<', '>', '@', ',', ';', ':', '\\', '"', '/', '[', ']', '?', '=', '{', '}', ' ', '\t' => return false,
            else => {},
        }
    }
    return true;
}

const SendData = union(enum) {
    blob: *Blob,
    js_val: js.Value,
};

const BinaryData = union(enum) {
    int8: []i8,
    uint8: []u8,
    int16: []i16,
    uint16: []u16,
    int32: []i32,
    uint32: []u32,
    int64: []i64,
    uint64: []u64,
    float32: []f32,
    float64: []f64,

    fn asBuffer(self: BinaryData) []u8 {
        return switch (self) {
            .int8 => |b| @as([*]u8, @ptrCast(b.ptr))[0..b.len],
            .uint8 => |b| b,
            inline .int16, .uint16 => |b| @as([*]u8, @ptrCast(b.ptr))[0 .. b.len * 2],
            inline .int32, .uint32, .float32 => |b| @as([*]u8, @ptrCast(b.ptr))[0 .. b.len * 4],
            inline .int64, .uint64, .float64 => |b| @as([*]u8, @ptrCast(b.ptr))[0 .. b.len * 8],
        };
    }
};

pub fn send(self: *WebSocket, data: SendData) !void {
    if (self._ready_state != .open) {
        return error.InvalidStateError;
    }

    switch (data) {
        .blob => |blob| {
            const arena = try self._frame.getArena(blob._slice.len, "WebSocket.message");
            errdefer self._frame.releaseArena(arena);
            try self.queueMessage(.{ .binary = .{
                .arena = arena,
                .data = try arena.dupe(u8, blob._slice),
            } });
        },
        .js_val => |js_val| {
            if (js_val.isNullOrUndefined()) {
                const arena = try self._frame.getArena(4, "WebSocket.message");
                errdefer self._frame.releaseArena(arena);
                try self.queueMessage(.{ .text = .{
                    .arena = arena,
                    .data = try arena.dupe(u8, "null"),
                } });
            } else if (js_val.isString()) |str| {
                const arena = try self._frame.getArena(str.len(), "WebSocket.message");
                errdefer self._frame.releaseArena(arena);
                try self.queueMessage(.{ .text = .{
                    .arena = arena,
                    .data = try str.toSliceWithAlloc(arena),
                } });
            } else if (js_val.isArrayBuffer() or js_val.isArrayBufferView() or js_val.isTypedArray()) {
                const view_bytes = try js_val.toStringSmart();
                const arena = try self._frame.getArena(view_bytes.len, "WebSocket.message");
                errdefer self._frame.releaseArena(arena);
                try self.queueMessage(.{ .binary = .{
                    .arena = arena,
                    .data = try arena.dupe(u8, view_bytes),
                } });
            } else {
                const binary = try js_val.toZig(BinaryData);
                const buffer = binary.asBuffer();

                const arena = try self._frame.getArena(buffer.len, "WebSocket.message");
                errdefer self._frame.releaseArena(arena);
                try self.queueMessage(.{ .binary = .{
                    .arena = arena,
                    .data = try arena.dupe(u8, buffer),
                } });
            }
        },
    }
}

pub fn close(self: *WebSocket, code_: ?u16, reason_: ?[]const u8) !void {
    if (self._ready_state == .closing or self._ready_state == .closed) {
        return;
    }

    if (code_) |code| {
        if (code != 1000 and (code < 3000 or code > 4999)) {
            return error.InvalidAccessError;
        }
    }

    if (reason_) |reason| {
        if (reason.len > 123) return error.SyntaxError;
    }

    // 1005 = no status code in the close frame (close() without a code argument).
    const code = code_ orelse 1005;
    const reason = reason_ orelse "";

    if (self._ready_state == .connecting) {
        self._ready_state = .closed;
        self.cleanup();
        if (self._frame.js.execution.canEnterJs(.allow_draining)) {
            try self.dispatchCloseEvent(code, reason, false);
        }
        return;
    }

    self._ready_state = .closing;
    self._close_code = code;
    self._close_reason = try self._arena.dupe(u8, reason);
    try self.queueMessage(.close);
}

pub fn getUrl(self: *const WebSocket) []const u8 {
    return self._url;
}

pub fn getReadyState(self: *const WebSocket) u16 {
    return @intFromEnum(self._ready_state);
}

pub fn getBufferedAmount(self: *const WebSocket) u32 {
    var buffered: u32 = 0;
    for (self._send_queue.items) |msg| {
        switch (msg) {
            .text, .binary => |byte_msg| buffered += @intCast(byte_msg.data.len),
            .close => buffered += @intCast(2 + self._close_reason.len),
        }
    }
    return buffered;
}

pub fn getBinaryType(self: *const WebSocket) []const u8 {
    return @tagName(self._binary_type);
}

pub fn getProtocol(self: *const WebSocket) []const u8 {
    return self._protocol;
}

pub fn setBinaryType(self: *WebSocket, value: []const u8) void {
    if (std.meta.stringToEnum(BinaryType, value)) |bt| {
        self._binary_type = bt;
    }
}

pub fn getOnOpen(self: *const WebSocket) ?js.Function.Temp {
    return self._on_open;
}

pub fn setOnOpen(self: *WebSocket, cb_: ?js.Function) !void {
    if (self._on_open) |old| old.release();
    if (cb_) |cb| {
        self._on_open = try cb.tempWithThis(self);
    } else {
        self._on_open = null;
    }
}

pub fn getOnMessage(self: *const WebSocket) ?js.Function.Temp {
    return self._on_message;
}

pub fn setOnMessage(self: *WebSocket, cb_: ?js.Function) !void {
    if (self._on_message) |old| old.release();
    if (cb_) |cb| {
        self._on_message = try cb.tempWithThis(self);
    } else {
        self._on_message = null;
    }
}

pub fn getOnError(self: *const WebSocket) ?js.Function.Temp {
    return self._on_error;
}

pub fn setOnError(self: *WebSocket, cb_: ?js.Function) !void {
    if (self._on_error) |old| old.release();
    if (cb_) |cb| {
        self._on_error = try cb.tempWithThis(self);
    } else {
        self._on_error = null;
    }
}

pub fn getOnClose(self: *const WebSocket) ?js.Function.Temp {
    return self._on_close;
}

pub fn setOnClose(self: *WebSocket, cb_: ?js.Function) !void {
    if (self._on_close) |old| old.release();
    if (cb_) |cb| {
        self._on_close = try cb.tempWithThis(self);
    } else {
        self._on_close = null;
    }
}

fn dispatchOpenEvent(self: *WebSocket) !void {
    const frame = self._frame;
    const target = self.asEventTarget();

    if (frame._event_manager.hasDirectListeners(target, "open", self._on_open)) {
        const event = try Event.initTrusted(comptime .wrap("open"), .{}, frame._page);
        try frame._event_manager.dispatchDirect(target, event, self._on_open, .{ .context = "WebSocket open" });
    }
}

fn dispatchMessageEvent(self: *WebSocket, data: []const u8, frame_type: http.WsFrameType) !void {
    const frame = self._frame;
    if (!frame.js.execution.canEnterJs(.allow_draining)) return;

    const target = self.asEventTarget();

    if (frame._event_manager.hasDirectListeners(target, "message", self._on_message)) {
        const msg_data: MessageEvent.Data = if (frame_type == .binary)
            switch (self._binary_type) {
                .arraybuffer => .{ .arraybuffer = .{ .values = data } },
                .blob => blk: {
                    const blob = try Blob.initFromBytes(data, "", false, frame._page);
                    blob.acquireRef();
                    break :blk .{ .blob = blob };
                },
            }
        else
            .{ .string = data };

        const event = try MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = msg_data,
            .origin = "",
        }, frame._page);
        try frame._event_manager.dispatchDirect(target, event.asEvent(), self._on_message, .{ .context = "WebSocket message" });
    }
}

fn dispatchErrorEvent(self: *WebSocket) !void {
    const frame = self._frame;
    const target = self.asEventTarget();

    if (frame._event_manager.hasDirectListeners(target, "error", self._on_error)) {
        const event = try Event.initTrusted(comptime .wrap("error"), .{}, frame._page);
        try frame._event_manager.dispatchDirect(target, event, self._on_error, .{ .context = "WebSocket error" });
    }
}

fn dispatchCloseEvent(self: *WebSocket, code: u16, reason: []const u8, was_clean: bool) !void {
    const frame = self._frame;
    const target = self.asEventTarget();

    if (frame._event_manager.hasDirectListeners(target, "close", self._on_close)) {
        const event = try CloseEvent.initTrusted(comptime .wrap("close"), .{
            .code = code,
            .reason = reason,
            .wasClean = was_clean,
        }, frame);
        try frame._event_manager.dispatchDirect(target, event.asEvent(), self._on_close, .{ .context = "WebSocket close" });
    }
}

const Message = union(enum) {
    close,
    text: Content,
    binary: Content,

    const Content = struct {
        arena: Allocator,
        data: []const u8,
    };
    fn deinit(self: Message, page: *Page) void {
        switch (self) {
            .text, .binary => |msg| page.releaseArena(msg.arena),
            .close => {},
        }
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(WebSocket);

    pub const Meta = struct {
        pub const name = "WebSocket";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(WebSocket.init, .{ .dom_exception = true });

    pub const CONNECTING = bridge.property(@intFromEnum(ReadyState.connecting), .{ .template = true });
    pub const OPEN = bridge.property(@intFromEnum(ReadyState.open), .{ .template = true });
    pub const CLOSING = bridge.property(@intFromEnum(ReadyState.closing), .{ .template = true });
    pub const CLOSED = bridge.property(@intFromEnum(ReadyState.closed), .{ .template = true });

    pub const url = bridge.accessor(WebSocket.getUrl, null, .{});
    pub const readyState = bridge.accessor(WebSocket.getReadyState, null, .{});
    pub const bufferedAmount = bridge.accessor(WebSocket.getBufferedAmount, null, .{});
    pub const binaryType = bridge.accessor(WebSocket.getBinaryType, WebSocket.setBinaryType, .{});

    pub const protocol = bridge.accessor(WebSocket.getProtocol, null, .{});
    pub const extensions = bridge.property("", .{ .template = false });

    pub const onopen = bridge.accessor(WebSocket.getOnOpen, WebSocket.setOnOpen, .{});
    pub const onmessage = bridge.accessor(WebSocket.getOnMessage, WebSocket.setOnMessage, .{});
    pub const onerror = bridge.accessor(WebSocket.getOnError, WebSocket.setOnError, .{});
    pub const onclose = bridge.accessor(WebSocket.getOnClose, WebSocket.setOnClose, .{});

    pub const send = bridge.function(WebSocket.send, .{ .dom_exception = true });
    pub const close = bridge.function(WebSocket.close, .{ .dom_exception = true });
};

const testing = @import("../../../testing/testing.zig");
test "WebApi: WebSocket" {
    try testing.htmlRunner("net/websocket.html", .{});
}
