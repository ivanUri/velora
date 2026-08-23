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

//! DTLS 1.2 transport — RFC 6347.
//!
//! Uses BoringSSL memory BIOs so the network thread drives I/O explicitly:
//!   1. Incoming UDP → BIO_write(read_bio) → SSL_do_handshake() / SSL_read()
//!   2. SSL_write() / SSL_do_handshake() → BIO_read(write_bio) → sendto()
//!
//! No internal socket ownership. The WebRtcThread owns the socket and calls
//! injectIncoming() / drainOutgoing() on each poll() iteration.
//!
//! Certificate is generated once per RTCPeerConnection at init().
//! Fingerprint (SHA-256) is exported for SDP inclusion.
//!
//! SRTP key material is NOT exported here (DataChannel-only phase).
//! SCTP runs directly over DTLS (draft-ietf-mmusic-sctp-sdp).

const std = @import("std");
const posix = @import("../../../../support/posix.zig");
const Allocator = std.mem.Allocator;

const log = @import("../../../../support/log.zig");
const RtcEventQueue = @import("../../../../runtime/network/RtcEventQueue.zig");

const ssl_c = @cImport({
    @cInclude("boringssl_zig_compat.h");
    @cInclude("openssl/bio.h");
    @cInclude("openssl/x509.h");
    @cInclude("openssl/evp.h");
    @cInclude("openssl/rsa.h");
    @cInclude("openssl/ec.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/sha.h");
});

const DtlsTransport = @This();

pub const Role = enum { client, server };

pub const State = enum {
    new,
    connecting,
    connected,
    failed,
    closed,
};

// ---------------------------------------------------------------------------
// Fields
// ---------------------------------------------------------------------------

_alloc: Allocator,
_event_queue: *RtcEventQueue,

_ctx: *ssl_c.SSL_CTX,
_ssl: *ssl_c.SSL,
_read_bio: *ssl_c.BIO, // network → SSL
_write_bio: *ssl_c.BIO, // SSL → network

_state: State,
_role: Role,

/// SHA-256 fingerprint of our certificate (hex, "AA:BB:CC:..." format).
_fingerprint: [95]u8, // 32 bytes × 3 chars (2 hex + colon) - 1 = 95
_fingerprint_len: u8,

/// Pending outgoing data from write_bio (to be sent over UDP).
_out_buf: [65536]u8,

// ---------------------------------------------------------------------------
// Init / deinit
// ---------------------------------------------------------------------------

/// Initialize DTLS transport, generate ephemeral ECDSA certificate.
pub fn init(alloc: Allocator, event_queue: *RtcEventQueue, role: Role) !DtlsTransport {
    // Create SSL_CTX for DTLS 1.2
    const method = ssl_c.DTLS_method() orelse return error.SslInitFailed;
    const ctx = ssl_c.SSL_CTX_new(method) orelse return error.SslInitFailed;
    errdefer ssl_c.SSL_CTX_free(ctx);

    // Disable SSLv3 / TLS 1.0 / TLS 1.1
    _ = ssl_c.SSL_CTX_set_min_proto_version(ctx, ssl_c.DTLS1_2_VERSION);

    // Generate ECDSA P-256 key
    const pkey = blk: {
        const ec_key = ssl_c.EC_KEY_new_by_curve_name(ssl_c.NID_X9_62_prime256v1) orelse return error.KeyGenFailed;
        errdefer ssl_c.EC_KEY_free(ec_key);
        if (ssl_c.EC_KEY_generate_key(ec_key) != 1) return error.KeyGenFailed;
        const pk = ssl_c.EVP_PKEY_new() orelse return error.KeyGenFailed;
        errdefer ssl_c.EVP_PKEY_free(pk);
        if (ssl_c.EVP_PKEY_assign_EC_KEY(pk, ec_key) != 1) return error.KeyGenFailed;
        // ec_key ownership transferred to pk
        break :blk pk;
    };
    defer ssl_c.EVP_PKEY_free(pkey);

    // Generate self-signed X.509 certificate valid for 30 days
    const cert = blk: {
        const x = ssl_c.X509_new() orelse return error.CertGenFailed;
        errdefer ssl_c.X509_free(x);

        _ = ssl_c.X509_set_version(x, 2); // v3
        _ = ssl_c.ASN1_INTEGER_set(ssl_c.X509_get_serialNumber(x), 1);
        _ = ssl_c.X509_gmtime_adj(ssl_c.X509_get_notBefore(x), 0);
        _ = ssl_c.X509_gmtime_adj(ssl_c.X509_get_notAfter(x), 60 * 60 * 24 * 30);

        if (ssl_c.X509_set_pubkey(x, pkey) != 1) return error.CertGenFailed;

        const name = ssl_c.X509_get_subject_name(x) orelse return error.CertGenFailed;
        _ = ssl_c.X509_NAME_add_entry_by_txt(name, "CN", ssl_c.MBSTRING_ASC, "koko-webrtc", -1, -1, 0);
        if (ssl_c.X509_set_issuer_name(x, name) != 1) return error.CertGenFailed;
        if (ssl_c.X509_sign(x, pkey, ssl_c.EVP_sha256()) == 0) return error.CertGenFailed;

        break :blk x;
    };
    defer ssl_c.X509_free(cert);

    if (ssl_c.SSL_CTX_use_certificate(ctx, cert) != 1) return error.CertGenFailed;
    if (ssl_c.SSL_CTX_use_PrivateKey(ctx, pkey) != 1) return error.CertGenFailed;

    // Verify key matches cert
    if (ssl_c.SSL_CTX_check_private_key(ctx) != 1) return error.CertGenFailed;

    // Accept any remote certificate (fingerprint checked via SDP)
    ssl_c.SSL_CTX_set_verify(ctx, ssl_c.SSL_VERIFY_NONE, null);

    // Cipher list: ECDHE-ECDSA preferred for DataChannel
    _ = ssl_c.SSL_CTX_set_cipher_list(ctx, "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256");

    // Create SSL object
    const ssl = ssl_c.SSL_new(ctx) orelse return error.SslInitFailed;
    errdefer ssl_c.SSL_free(ssl);

    // Memory BIOs (non-blocking)
    const read_bio = ssl_c.BIO_new(ssl_c.BIO_s_mem()) orelse return error.SslInitFailed;
    const write_bio = ssl_c.BIO_new(ssl_c.BIO_s_mem()) orelse {
        _ = ssl_c.BIO_free(read_bio);
        return error.SslInitFailed;
    };

    // SSL takes ownership of the BIOs
    ssl_c.SSL_set_bio(ssl, read_bio, write_bio);

    switch (role) {
        .client => ssl_c.SSL_set_connect_state(ssl),
        .server => ssl_c.SSL_set_accept_state(ssl),
    }

    // Compute fingerprint
    var fp_buf: [95]u8 = std.mem.zeroes([95]u8);
    var fp_len: u8 = 0;
    computeFingerprint(cert, &fp_buf, &fp_len);

    return DtlsTransport{
        ._alloc = alloc,
        ._event_queue = event_queue,
        ._ctx = ctx,
        ._ssl = ssl,
        ._read_bio = read_bio,
        ._write_bio = write_bio,
        ._state = .new,
        ._role = role,
        ._fingerprint = fp_buf,
        ._fingerprint_len = fp_len,
        ._out_buf = std.mem.zeroes([65536]u8),
    };
}

pub fn deinit(self: *DtlsTransport) void {
    ssl_c.SSL_free(self._ssl); // also frees BIOs
    ssl_c.SSL_CTX_free(self._ctx);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Returns our certificate fingerprint for SDP (SHA-256, colon-separated hex).
pub fn fingerprint(self: *const DtlsTransport) []const u8 {
    return self._fingerprint[0..self._fingerprint_len];
}

/// Called by WebRtcThread when poll() indicates data on the UDP socket.
/// `data` is a single incoming UDP datagram (possibly DTLS record).
/// Returns true if data was consumed by DTLS.
pub fn injectIncoming(self: *DtlsTransport, data: []const u8, sock: posix.socket_t, peer: *const posix.sockaddr, peer_len: posix.socklen_t) !bool {
    if (self._state == .closed or self._state == .failed) return false;

    // DTLS records start with content_type (20–63), followed by version (0xFE...)
    if (data.len < 1) return false;
    const ct = data[0];
    const is_dtls = ct >= 20 and ct <= 63;
    if (!is_dtls) return false;

    // Feed data into the read BIO
    const written = ssl_c.BIO_write(self._read_bio, data.ptr, @intCast(data.len));
    if (written <= 0) return true; // DTLS but BIO full — drop silently

    // Drive the SSL state machine
    try self.driveHandshake(sock, peer, peer_len);
    return true;
}

/// Drive handshake or read application data after injecting incoming bytes.
/// Sends any pending outgoing DTLS records over `sock`.
fn driveHandshake(self: *DtlsTransport, sock: posix.socket_t, peer: *const posix.sockaddr, peer_len: posix.socklen_t) !void {
    if (self._state == .new or self._state == .connecting) {
        self._state = .connecting;

        const rc = ssl_c.SSL_do_handshake(self._ssl);
        const err = ssl_c.SSL_get_error(self._ssl, rc);

        if (rc == 1) {
            // Handshake complete
            self._state = .connected;
            log.info(.webrtc, "DTLS handshake complete", .{ .role = self._role });
            const node = try self._alloc.create(RtcEventQueue.Node);
            node.* = .{ .event = .dtls_handshake_done };
            self._event_queue.push(node);
        } else if (err != ssl_c.SSL_ERROR_WANT_READ and err != ssl_c.SSL_ERROR_WANT_WRITE) {
            // Fatal error
            self._state = .failed;
            log.warn(.webrtc, "DTLS handshake failed", .{ .ssl_err = err });
            const node = try self._alloc.create(RtcEventQueue.Node);
            node.* = .{ .event = .{ .dtls_failed = .internal } };
            self._event_queue.push(node);
        }
    }

    // Drain outgoing records and send over UDP
    try self.flushWriteBio(sock, peer, peer_len);
}

/// Initiate the DTLS handshake (client role: call once after ICE connected).
pub fn startHandshake(self: *DtlsTransport, sock: posix.socket_t, peer: *const posix.sockaddr, peer_len: posix.socklen_t) !void {
    if (self._state != .new) return;
    self._state = .connecting;
    try self.driveHandshake(sock, peer, peer_len);
}

/// Encrypt and send application data (SCTP payload) over DTLS.
pub fn send(self: *DtlsTransport, data: []const u8, sock: posix.socket_t, peer: *const posix.sockaddr, peer_len: posix.socklen_t) !void {
    if (self._state != .connected) return error.DtlsNotConnected;

    var offset: usize = 0;
    while (offset < data.len) {
        const chunk = @min(data.len - offset, 16384);
        const rc = ssl_c.SSL_write(self._ssl, data[offset..].ptr, @intCast(chunk));
        if (rc <= 0) {
            const err = ssl_c.SSL_get_error(self._ssl, rc);
            log.warn(.webrtc, "DTLS SSL_write failed", .{ .err = err });
            return error.DtlsWriteFailed;
        }
        offset += @intCast(rc);
    }
    try self.flushWriteBio(sock, peer, peer_len);
}

/// Read decrypted application data (SCTP payload) into `buf`.
/// Returns number of bytes read, or 0 if no data available.
pub fn recv(self: *DtlsTransport, buf: []u8) usize {
    if (self._state != .connected) return 0;
    const rc = ssl_c.SSL_read(self._ssl, buf.ptr, @intCast(buf.len));
    if (rc <= 0) return 0;
    return @intCast(rc);
}

pub fn close(self: *DtlsTransport) void {
    if (self._state == .closed) return;
    self._state = .closed;
    _ = ssl_c.SSL_shutdown(self._ssl);
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

fn flushWriteBio(self: *DtlsTransport, sock: posix.socket_t, peer: *const posix.sockaddr, peer_len: posix.socklen_t) !void {
    while (true) {
        const n = ssl_c.BIO_read(self._write_bio, &self._out_buf, @intCast(self._out_buf.len));
        if (n <= 0) break;
        _ = posix.sendto(sock, self._out_buf[0..@intCast(n)], 0, peer, peer_len) catch |err| {
            log.warn(.webrtc, "DTLS flush sendto failed", .{ .err = err });
            break;
        };
    }
}

fn computeFingerprint(cert: *ssl_c.X509, buf: *[95]u8, out_len: *u8) void {
    var digest: [32]u8 = undefined;
    var digest_len: c_uint = 32;
    _ = ssl_c.X509_digest(cert, ssl_c.EVP_sha256(), &digest, &digest_len);

    var pos: usize = 0;
    for (digest[0..digest_len], 0..) |byte, i| {
        if (i > 0 and pos < buf.len - 2) {
            buf[pos] = ':';
            pos += 1;
        }
        if (pos + 2 <= buf.len) {
            _ = std.fmt.bufPrint(buf[pos..][0..2], "{X:0>2}", .{byte}) catch {};
            pos += 2;
        }
    }
    out_len.* = @intCast(pos);
}
