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

//! STUN client — RFC 5389 / RFC 8445.
//!
//! Handles:
//!   - Formatting STUN Binding Request (with or without MESSAGE-INTEGRITY)
//!   - Parsing STUN Binding Response / Error Response
//!   - XOR-MAPPED-ADDRESS decoding
//!   - HMAC-SHA1 MESSAGE-INTEGRITY for ICE connectivity checks
//!   - CRC32 FINGERPRINT attribute
//!
//! All I/O is synchronous and caller-driven; no internal socket ownership.
//! The IceAgent holds the UDP socket and calls into StunClient for message
//! formatting and parsing.

const std = @import("std");
const runtime_io = @import("../../../../support/io.zig");
const net = @import("../../../../support/net.zig");
const builtin = @import("builtin");

// BoringSSL HMAC — already linked via build.zig (boringssl-zig dep).
const c = @cImport({
    @cInclude("openssl/hmac.h");
    @cInclude("openssl/sha.h");
});

pub const STUN_MAGIC_COOKIE: u32 = 0x2112_A442;

pub const MessageType = enum(u16) {
    binding_request = 0x0001,
    binding_success = 0x0101,
    binding_error = 0x0111,
    _,
};

pub const AttributeType = enum(u16) {
    mapped_address = 0x0001,
    username = 0x0006,
    message_integrity = 0x0008,
    error_code = 0x0009,
    xor_mapped_address = 0x0020,
    fingerprint = 0x8028,
    ice_controlled = 0x8029,
    ice_controlling = 0x802A,
    priority = 0x0024,
    use_candidate = 0x0025,
    _,
};

pub const StunError = error{
    TooShort,
    BadMagicCookie,
    BadMessageType,
    AttributeOverflow,
    BadXorMappedAddress,
    BadMessageIntegrity,
    ErrorResponse,
    UnknownAddress,
};

/// A parsed STUN Binding Success response.
pub const BindingResponse = struct {
    transaction_id: [12]u8,
    /// The reflexive (srflx) address observed by the STUN server.
    mapped_addr: net.Address,
};

// ---------------------------------------------------------------------------
// STUN message building
// ---------------------------------------------------------------------------

/// Build a STUN Binding Request into `buf`.
/// Returns the number of bytes written.
///
/// If `username` / `password` are provided, appends USERNAME and
/// MESSAGE-INTEGRITY (HMAC-SHA1) as required for ICE connectivity checks.
/// Always appends FINGERPRINT.
pub fn buildBindingRequest(
    buf: []u8,
    transaction_id: [12]u8,
    username: ?[]const u8,
    password: ?[]const u8,
    priority: ?u32,
    use_candidate: bool,
    ice_controlling_tiebreaker: ?u64,
) !usize {
    var pos: usize = 0;

    // --- STUN header (20 bytes) ---
    if (buf.len < 20) return error.AttributeOverflow;

    // Message type = Binding Request
    std.mem.writeInt(u16, buf[0..2], @intFromEnum(MessageType.binding_request), .big);
    // Message length placeholder (filled in later)
    std.mem.writeInt(u16, buf[2..4], 0, .big);
    // Magic cookie
    std.mem.writeInt(u32, buf[4..8], STUN_MAGIC_COOKIE, .big);
    // Transaction ID
    @memcpy(buf[8..20], &transaction_id);
    pos = 20;

    // --- Optional: ICE_CONTROLLING ---
    if (ice_controlling_tiebreaker) |tb| {
        pos = try writeAttr(buf, pos, @intFromEnum(AttributeType.ice_controlling), 8);
        std.mem.writeInt(u64, buf[pos..][0..8], tb, .big);
        pos += 8;
    }

    // --- Optional: PRIORITY ---
    if (priority) |p| {
        pos = try writeAttr(buf, pos, @intFromEnum(AttributeType.priority), 4);
        std.mem.writeInt(u32, buf[pos..][0..4], p, .big);
        pos += 4;
    }

    // --- Optional: USE-CANDIDATE (for ICE nomination) ---
    if (use_candidate) {
        pos = try writeAttr(buf, pos, @intFromEnum(AttributeType.use_candidate), 0);
    }

    // --- Optional: USERNAME ---
    if (username) |uname| {
        const padded_len = std.mem.alignForward(usize, uname.len, 4);
        pos = try writeAttr(buf, pos, @intFromEnum(AttributeType.username), @intCast(uname.len));
        if (pos + padded_len > buf.len) return error.AttributeOverflow;
        @memcpy(buf[pos..][0..uname.len], uname);
        // Zero-pad to 4-byte boundary
        @memset(buf[pos + uname.len ..][0 .. padded_len - uname.len], 0);
        pos += padded_len;
    }

    // --- MESSAGE-INTEGRITY (HMAC-SHA1 over header + preceding attrs) ---
    if (password) |pwd| {
        // Update the length field to include MI attr (header + 20 bytes HMAC).
        // The length in the header covers everything AFTER the 20-byte header,
        // up to and including the MI attribute (but NOT the fingerprint).
        // MI attr = 4-byte type+len header + 20-byte HMAC = 24 bytes.
        const mi_total_len: u16 = @intCast((pos - 20) + 4 + 20);
        std.mem.writeInt(u16, buf[2..4], mi_total_len, .big);

        // Compute HMAC-SHA1 over buf[0..pos]
        var hmac: [20]u8 = undefined;
        computeHmacSha1(buf[0..pos], pwd, &hmac);

        pos = try writeAttr(buf, pos, @intFromEnum(AttributeType.message_integrity), 20);
        if (pos + 20 > buf.len) return error.AttributeOverflow;
        @memcpy(buf[pos..][0..20], &hmac);
        pos += 20;
    }

    // --- FINGERPRINT (CRC32 XOR 0x5354554E) ---
    // Update length to include fingerprint (8 bytes: 4 attr header + 4 CRC).
    const fp_msg_len: u16 = @intCast((pos - 20) + 8);
    std.mem.writeInt(u16, buf[2..4], fp_msg_len, .big);

    const crc = crc32(buf[0..pos]) ^ 0x5354554E;
    pos = try writeAttr(buf, pos, @intFromEnum(AttributeType.fingerprint), 4);
    if (pos + 4 > buf.len) return error.AttributeOverflow;
    std.mem.writeInt(u32, buf[pos..][0..4], crc, .big);
    pos += 4;

    // Final length in header
    std.mem.writeInt(u16, buf[2..4], @intCast(pos - 20), .big);

    return pos;
}

/// Parse a STUN Binding Response from `data`.
/// Verifies magic cookie and returns the mapped address.
pub fn parseBindingResponse(data: []const u8) !BindingResponse {
    if (data.len < 20) return StunError.TooShort;

    const msg_type: MessageType = @enumFromInt(std.mem.readInt(u16, data[0..2], .big));
    const msg_len = std.mem.readInt(u16, data[2..4], .big);
    const magic = std.mem.readInt(u32, data[4..8], .big);

    if (magic != STUN_MAGIC_COOKIE) return StunError.BadMagicCookie;
    if (msg_type == .binding_error) return StunError.ErrorResponse;
    if (msg_type != .binding_success) return StunError.BadMessageType;
    if (data.len < 20 + msg_len) return StunError.TooShort;

    var tid: [12]u8 = undefined;
    @memcpy(&tid, data[8..20]);

    // Parse attributes
    var mapped_addr: ?net.Address = null;
    var offset: usize = 20;
    const end = 20 + msg_len;

    while (offset + 4 <= end) {
        const attr_type = std.mem.readInt(u16, data[offset..][0..2], .big);
        const attr_len = std.mem.readInt(u16, data[offset + 2 ..][0..2], .big);
        const val_start = offset + 4;
        const val_end = val_start + attr_len;
        if (val_end > end) break;

        const padded = std.mem.alignForward(usize, attr_len, 4);
        offset = val_start + padded;

        switch (@as(AttributeType, @enumFromInt(attr_type))) {
            .xor_mapped_address => {
                mapped_addr = try parseXorMappedAddress(data[val_start..val_end], &tid);
            },
            .mapped_address => {
                // Fallback if no XOR-MAPPED-ADDRESS
                if (mapped_addr == null) {
                    mapped_addr = parseMappedAddress(data[val_start..val_end]) catch null;
                }
            },
            else => {},
        }
    }

    const addr = mapped_addr orelse return StunError.UnknownAddress;
    return .{ .transaction_id = tid, .mapped_addr = addr };
}

// ---------------------------------------------------------------------------
// ICE connectivity check: verify inbound STUN request MESSAGE-INTEGRITY
// ---------------------------------------------------------------------------

/// Verify the MESSAGE-INTEGRITY of an inbound ICE STUN Binding Request.
/// `data` is the raw UDP payload, `local_pwd` is our local password.
pub fn verifyMessageIntegrity(data: []const u8, local_pwd: []const u8) bool {
    if (data.len < 20) return false;

    // Find MESSAGE-INTEGRITY attribute offset
    const msg_len = std.mem.readInt(u16, data[2..4], .big);
    var offset: usize = 20;
    const end = @min(data.len, 20 + msg_len);

    while (offset + 4 <= end) {
        const attr_type = std.mem.readInt(u16, data[offset..][0..2], .big);
        const attr_len = std.mem.readInt(u16, data[offset + 2 ..][0..2], .big);
        const val_start = offset + 4;

        if (@as(AttributeType, @enumFromInt(attr_type)) == .message_integrity) {
            if (attr_len != 20) return false;
            if (val_start + 20 > data.len) return false;

            // The HMAC is computed over the message up to (but not including)
            // the MI attribute, with the length field patched to reflect only
            // the content up to the MI attr.
            const mi_msg_end = offset; // end of content before MI
            const content_len: u16 = @intCast(mi_msg_end - 20 + 4 + 20); // +MI attr itself

            // We need a temporary copy to patch the length field
            var tmp: [2048]u8 = undefined;
            if (mi_msg_end > tmp.len) return false;
            @memcpy(tmp[0..mi_msg_end], data[0..mi_msg_end]);
            std.mem.writeInt(u16, tmp[2..4], content_len, .big);

            var expected: [20]u8 = undefined;
            computeHmacSha1(tmp[0..mi_msg_end], local_pwd, &expected);

            return std.mem.eql(u8, &expected, data[val_start..][0..20]);
        }

        const padded = std.mem.alignForward(usize, attr_len, 4);
        offset = val_start + padded;
    }

    return false; // No MI attribute found
}

/// Generate a random 12-byte STUN transaction ID.
pub fn randomTransactionId() [12]u8 {
    var tid: [12]u8 = undefined;
    runtime_io.get().random(&tid);
    return tid;
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

fn writeAttr(buf: []u8, pos: usize, attr_type: u16, attr_len: u16) !usize {
    if (pos + 4 > buf.len) return error.AttributeOverflow;
    std.mem.writeInt(u16, buf[pos..][0..2], attr_type, .big);
    std.mem.writeInt(u16, buf[pos + 2 ..][0..2], attr_len, .big);
    return pos + 4;
}

fn parseXorMappedAddress(data: []const u8, tid: *const [12]u8) !net.Address {
    // Byte 0: reserved, Byte 1: family (0x01=IPv4, 0x02=IPv6)
    if (data.len < 4) return StunError.BadXorMappedAddress;

    const family = data[1];
    const xport = std.mem.readInt(u16, data[2..4], .big);
    const port = xport ^ @as(u16, @truncate(STUN_MAGIC_COOKIE >> 16));

    if (family == 0x01) {
        // IPv4: 4 bytes
        if (data.len < 8) return StunError.BadXorMappedAddress;
        const xaddr = std.mem.readInt(u32, data[4..8], .big);
        const addr = xaddr ^ STUN_MAGIC_COOKIE;
        const bytes: [4]u8 = @bitCast(std.mem.nativeToBig(u32, addr));
        return net.Address.initIp4(bytes, port);
    } else if (family == 0x02) {
        // IPv6: 16 bytes
        if (data.len < 20) return StunError.BadXorMappedAddress;
        var xaddr: [16]u8 = undefined;
        @memcpy(&xaddr, data[4..20]);
        // XOR with magic + tid
        const magic_bytes: [4]u8 = @bitCast(std.mem.nativeToBig(u32, STUN_MAGIC_COOKIE));
        for (0..4) |i| xaddr[i] ^= magic_bytes[i];
        for (0..12) |i| xaddr[4 + i] ^= tid[i];
        return net.Address.initIp6(xaddr, port, 0, 0);
    }

    return StunError.BadXorMappedAddress;
}

fn parseMappedAddress(data: []const u8) !net.Address {
    if (data.len < 4) return StunError.BadXorMappedAddress;
    const family = data[1];
    const port = std.mem.readInt(u16, data[2..4], .big);
    if (family == 0x01) {
        if (data.len < 8) return StunError.BadXorMappedAddress;
        const bytes: [4]u8 = data[4..8].*;
        return net.Address.initIp4(bytes, port);
    }
    return StunError.BadXorMappedAddress;
}

fn computeHmacSha1(msg: []const u8, key: []const u8, out: *[20]u8) void {
    var md_len: c_uint = 20;
    _ = c.HMAC(
        c.EVP_sha1(),
        key.ptr,
        @intCast(key.len),
        msg.ptr,
        @intCast(msg.len),
        out,
        &md_len,
    );
}

/// Standard CRC-32 (ISO 3309 / ITU-T V.42).
fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFF_FFFF;
    for (data) |byte| {
        crc ^= byte;
        for (0..8) |_| {
            const mask: u32 = if (crc & 1 != 0) 0xEDB8_8320 else 0;
            crc = (crc >> 1) ^ mask;
        }
    }
    return crc ^ 0xFFFF_FFFF;
}
