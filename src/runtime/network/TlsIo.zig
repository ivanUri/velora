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

//! TLS client I/O over a connected TCP socket (BoringSSL).

const std = @import("std");
const posix = std.posix;

const ssl_c = @cImport({
    @cInclude("boringssl_zig_compat.h");
});

const TlsIo = @This();

ctx: *ssl_c.SSL_CTX,
ssl: *ssl_c.SSL,

/// ALPN offering h2 + http/1.1 (Chrome-like) for WPT wss and h2 echo ports.
const alpn_protos = [_]u8{
    0x02, 'h', '2',
    0x08, 'h', 't',
    't',  'p', '/',
    '1',  '.', '1',
};

pub fn init(hostname: []const u8, socket: posix.socket_t, verify_peer: bool) !TlsIo {
    const method = ssl_c.TLS_client_method() orelse return error.SslInitFailed;
    const ctx = ssl_c.SSL_CTX_new(method) orelse return error.SslInitFailed;
    errdefer ssl_c.SSL_CTX_free(ctx);

    if (ssl_c.SSL_CTX_set_alpn_protos(ctx, &alpn_protos, @intCast(alpn_protos.len)) != 0) {
        return error.SslInitFailed;
    }

    if (!verify_peer) {
        _ = ssl_c.SSL_CTX_set_verify(ctx, ssl_c.SSL_VERIFY_NONE, null);
    }

    const ssl = ssl_c.SSL_new(ctx) orelse return error.SslInitFailed;
    errdefer ssl_c.SSL_free(ssl);

    _ = ssl_c.SSL_set_mode(ssl, ssl_c.SSL_MODE_ENABLE_PARTIAL_WRITE);

    if (ssl_c.SSL_set_fd(ssl, @intCast(socket)) != 1) return error.SslInitFailed;

    const host_z = try std.heap.c_allocator.dupeZ(u8, hostname);
    defer std.heap.c_allocator.free(host_z);
    _ = ssl_c.SSL_set_tlsext_host_name(ssl, host_z.ptr);

    return .{ .ctx = ctx, .ssl = ssl };
}

pub fn deinit(self: *TlsIo) void {
    _ = ssl_c.SSL_shutdown(self.ssl);
    ssl_c.SSL_free(self.ssl);
    ssl_c.SSL_CTX_free(self.ctx);
}

pub fn connectBlocking(self: *TlsIo) !void {
    while (true) {
        const rc = ssl_c.SSL_connect(self.ssl);
        if (rc == 1) return;
        const err = ssl_c.SSL_get_error(self.ssl, rc);
        switch (err) {
            ssl_c.SSL_ERROR_WANT_READ, ssl_c.SSL_ERROR_WANT_WRITE => {
                if (ssl_c.SSL_pending(self.ssl) > 0) continue;
                continue;
            },
            ssl_c.SSL_ERROR_SSL => return error.SslProtocolError,
            else => return error.TlsHandshakeFailed,
        }
    }
}

/// Blocking read for handshake/bootstrap (e.g. nghttp2 session init). Returns >0 bytes,
/// 0 on clean EOF, or an error.
pub fn readBlocking(self: *TlsIo, buf: []u8) !usize {
    while (true) {
        const n = ssl_c.SSL_read(self.ssl, buf.ptr, @intCast(buf.len));
        if (n > 0) return @intCast(n);
        const err = ssl_c.SSL_get_error(self.ssl, n);
        switch (err) {
            ssl_c.SSL_ERROR_ZERO_RETURN => return 0,
            ssl_c.SSL_ERROR_WANT_READ, ssl_c.SSL_ERROR_WANT_WRITE => {
                if (ssl_c.SSL_pending(self.ssl) > 0) continue;
                continue;
            },
            ssl_c.SSL_ERROR_SSL => return error.SslProtocolError,
            else => return error.TlsIoError,
        }
    }
}

/// Blocking write of the full buffer (used during TLS/H2 handshake on a blocking socket).
pub fn writeBlocking(self: *TlsIo, data: []const u8) !void {
    var pos: usize = 0;
    while (pos < data.len) {
        const n = ssl_c.SSL_write(self.ssl, data[pos..].ptr, @intCast(data.len - pos));
        if (n > 0) {
            pos += @intCast(n);
            continue;
        }
        const err = ssl_c.SSL_get_error(self.ssl, n);
        switch (err) {
            ssl_c.SSL_ERROR_WANT_READ, ssl_c.SSL_ERROR_WANT_WRITE => {
                if (ssl_c.SSL_pending(self.ssl) > 0) continue;
                continue;
            },
            ssl_c.SSL_ERROR_SSL => return error.SslProtocolError,
            else => return error.TlsIoError,
        }
    }
}

pub fn read(self: *TlsIo, buf: []u8) !usize {
    const n = ssl_c.SSL_read(self.ssl, buf.ptr, @intCast(buf.len));
    if (n > 0) return @intCast(n);
    return try mapSslError(self.ssl, n);
}

pub fn write(self: *TlsIo, data: []const u8) !usize {
    const n = ssl_c.SSL_write(self.ssl, data.ptr, @intCast(data.len));
    if (n > 0) return @intCast(n);
    return try mapSslError(self.ssl, n);
}

/// Negotiated ALPN protocol after `connectBlocking` (e.g. `"h2"` or `"http/1.1"`).
pub fn alpnProtocol(self: *const TlsIo) []const u8 {
    var data: ?[*]const u8 = null;
    var len: c_uint = 0;
    ssl_c.SSL_get0_alpn_selected(self.ssl, &data, &len);
    if (data == null or len == 0) return "";
    return data.?[0..len];
}

fn mapSslError(ssl: *ssl_c.SSL, rc: c_int) !usize {
    const err = ssl_c.SSL_get_error(ssl, rc);
    switch (err) {
        ssl_c.SSL_ERROR_ZERO_RETURN => return 0,
        ssl_c.SSL_ERROR_WANT_READ, ssl_c.SSL_ERROR_WANT_WRITE => return error.WouldBlock,
        ssl_c.SSL_ERROR_SSL => return error.SslProtocolError,
        else => return error.TlsIoError,
    }
}
