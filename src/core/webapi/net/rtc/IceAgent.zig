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

//! ICE Agent — RFC 8445.
//!
//! Responsibilities (on the WebRTC network thread):
//!   - Enumerate local network interfaces → host candidates
//!   - Send STUN Binding Request to STUN server → srflx candidate
//!   - Maintain candidate pairs and run connectivity checks
//!   - Nominate best candidate pair
//!   - Demux incoming UDP datagrams (STUN / DTLS / SCTP)
//!   - Notify RTCPeerConnection via RtcEventQueue
//!
//! State machine (IceGatheringState):
//!   new → gathering → complete
//!
//! Connection state (IceConnectionState):
//!   new → checking → connected → completed
//!          ↓
//!        failed
//!
//! Ownership: IceAgent is owned inline by WebRtcThread.
//! UDP socket is opened by IceAgent.init() and closed by IceAgent.deinit().
//!
//! Priority formula (RFC 8445 §5.1.2.1):
//!   priority = (2^24)(type_pref) + (2^8)(local_pref) + (256 - component_id)
//!   type_pref: host=126, srflx=100, prflx=110, relay=0
//!   local_pref: IPv4 default interface = 65535, others lower

const std = @import("std");
const net = @import("../../../../support/net.zig");
const posix = @import("../../../../support/posix.zig");
const runtime_io = @import("../../../../support/io.zig");
const datetime = @import("../../../../support/datetime.zig");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = @import("../../../../support/log.zig");
const StunClient = @import("StunClient.zig");
const RtcEventQueue = @import("../../../../runtime/network/RtcEventQueue.zig");

const IceAgent = @This();
const net_c = @cImport({
    @cInclude("ifaddrs.h");
    @cInclude("net/if.h");
    if (builtin.os.tag == .macos) {
        @cInclude("sys/ioctl.h");
        @cInclude("netinet6/in6_var.h");
    }
});

fn FixedList(comptime T: type, comptime capacity: usize) type {
    return struct {
        buffer: [capacity]T = undefined,
        len: usize = 0,

        pub fn append(self: *@This(), item: T) !void {
            if (self.len >= capacity) return error.Overflow;
            self.buffer[self.len] = item;
            self.len += 1;
        }

        pub fn slice(self: *const @This()) []const T {
            return self.buffer[0..self.len];
        }

        pub fn sliceMut(self: *@This()) []T {
            return self.buffer[0..self.len];
        }
    };
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub const GatheringState = enum { new, gathering, complete };
pub const ConnectionState = enum { new, checking, connected, completed, failed, disconnected };
pub const Role = enum { controlling, controlled };

pub const CandidateType = enum { host, srflx, prflx, relay };

pub const Candidate = struct {
    foundation: [32]u8,
    foundation_len: u8,
    component: u8,
    priority: u32,
    addr: net.Address,
    typ: CandidateType,
    related_addr: ?net.Address,
    expose: bool = true,
    temporary_ipv6: bool = false,
};

pub const CandidatePair = struct {
    local: Candidate,
    remote: Candidate,
    state: PairState,
    nominated: bool,
    /// Last STUN transaction ID sent for this pair's check.
    check_tid: [12]u8,
    /// ms timestamp of last check sent.
    last_check_ms: u64,
    /// Accumulated RTT (ms) — 0 if not yet measured.
    rtt_ms: u32,

    pub const PairState = enum { waiting, in_progress, succeeded, failed, frozen };
};

/// TYPE_PREF values per RFC 8445 §5.1.2.2
const TYPE_PREF_HOST: u24 = 126;
const TYPE_PREF_SRFLX: u24 = 100;
const TYPE_PREF_PRFLX: u24 = 110;
const TYPE_PREF_RELAY: u24 = 0;

/// STUN server state machine
const StunState = enum { idle, sent, received, failed };

/// Gather timeout for STUN srflx: 5 seconds
const STUN_TIMEOUT_MS: u64 = 5000;

/// ICE connectivity check interval (ms)
const CHECK_INTERVAL_MS: u64 = 20;

/// Maximum local candidates to gather
const MAX_LOCAL_CANDIDATES: usize = 8;

/// Maximum remote candidates
const MAX_REMOTE_CANDIDATES: usize = 32;

/// Maximum candidate pairs
const MAX_PAIRS: usize = MAX_LOCAL_CANDIDATES * MAX_REMOTE_CANDIDATES;

// ---------------------------------------------------------------------------
// Fields
// ---------------------------------------------------------------------------

_alloc: Allocator,
_event_queue: *RtcEventQueue,

// Credentials (set by RTCPeerConnection)
_local_ufrag: [8]u8,
_local_pwd: [24]u8,
_remote_ufrag: [8]u8,
_remote_pwd: [24]u8,
_have_remote_creds: bool,

// Browser network policy. False means the configured proxy cannot carry UDP,
// so host enumeration, STUN, and ICE connectivity checks must remain inert.
_allow_non_proxied_udp: bool,

// UDP socket (single socket for all candidates per RFC 8445 §4.1.1.2)
_sock: posix.socket_t,
_sock_port: u16,

// ICE role
_role: Role,
_tiebreaker: u64,

// Candidates
_local: FixedList(Candidate, MAX_LOCAL_CANDIDATES) = .{},
_remote: FixedList(Candidate, MAX_REMOTE_CANDIDATES) = .{},
_pairs: FixedList(CandidatePair, MAX_PAIRS) = .{},

// Nominated pair (valid after .connected)
_nominated: ?*CandidatePair,

// State
_gathering: GatheringState,
_connection: ConnectionState,

// STUN srflx gathering
_stun_server: ?net.Address,
_stun_state: StunState,
_stun_tid: [12]u8,
_stun_sent_ms: u64,

// Controlling tiebreaker random
_check_seq: u64,

// ---------------------------------------------------------------------------
// Init / deinit
// ---------------------------------------------------------------------------

pub fn init(
    alloc: Allocator,
    event_queue: *RtcEventQueue,
    local_ufrag: [8]u8,
    local_pwd: [24]u8,
    role: Role,
    allow_non_proxied_udp: bool,
) !IceAgent {
    // Open a single non-blocking UDP socket bound to any local port.
    const sock = try posix.socket(
        posix.AF.INET,
        posix.SOCK.DGRAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
        posix.IPPROTO.UDP,
    );
    errdefer posix.close(sock);

    // Bind to 0.0.0.0:0 — OS assigns ephemeral port
    var addr = net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    try posix.bind(sock, &addr.any, addr.getOsSockLen());

    // Read back assigned port
    var bound: posix.sockaddr.storage = undefined;
    var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
    try posix.getsockname(sock, @ptrCast(&bound), &bound_len);
    const bound_addr = net.Address.initPosix(@ptrCast(@alignCast(&bound)));
    const port = bound_addr.getPort();

    var self = IceAgent{
        ._alloc = alloc,
        ._event_queue = event_queue,
        ._local_ufrag = local_ufrag,
        ._local_pwd = local_pwd,
        ._remote_ufrag = std.mem.zeroes([8]u8),
        ._remote_pwd = std.mem.zeroes([24]u8),
        ._have_remote_creds = false,
        ._allow_non_proxied_udp = allow_non_proxied_udp,
        ._sock = sock,
        ._sock_port = port,
        ._role = role,
        ._tiebreaker = randomU64(),
        ._local = .{},
        ._remote = .{},
        ._pairs = .{},
        ._nominated = null,
        ._gathering = .new,
        ._connection = .new,
        ._stun_server = null,
        ._stun_state = .idle,
        ._stun_tid = std.mem.zeroes([12]u8),
        ._stun_sent_ms = 0,
        ._check_seq = 0,
    };

    if (allow_non_proxied_udp) {
        _ = try self.gatherHostCandidates();
    }
    return self;
}

pub fn deinit(self: *IceAgent) void {
    posix.close(self._sock);
}

/// Returns the UDP socket fd (for registration with poll()).
pub fn fd(self: *const IceAgent) posix.socket_t {
    return self._sock;
}

// ---------------------------------------------------------------------------
// Credential management
// ---------------------------------------------------------------------------

pub fn setRemoteCredentials(
    self: *IceAgent,
    ufrag: [8]u8,
    pwd: [24]u8,
) void {
    self._remote_ufrag = ufrag;
    self._remote_pwd = pwd;
    self._have_remote_creds = true;
}

// ---------------------------------------------------------------------------
// Gathering
// ---------------------------------------------------------------------------

/// Begin ICE gathering. Called from the network thread after
/// setLocalDescription has been processed.
pub fn startGathering(self: *IceAgent, stun_server: ?net.Address) !void {
    self._gathering = .gathering;
    self._stun_server = stun_server;

    // HTTP CONNECT proxies do not provide a UDP route. Complete gathering
    // with no candidates instead of exposing host/srflx addresses over the
    // machine's direct interface. This preserves the WebRTC event lifecycle.
    if (!self._allow_non_proxied_udp) {
        // An HTTP proxy does not provide an ICE transport. Do not synthesize
        // a host/srflx/relay candidate from the proxy gateway address: it was
        // not learned from STUN and cannot participate in connectivity checks.
        self._gathering = .complete;
        try self.emitGatheringComplete();
        return;
    }

    // Emit all host candidates immediately
    for (self._local.slice()) |*cand| {
        try self.emitCandidate(cand);
    }

    // Initiate STUN srflx if server provided
    if (stun_server != null) {
        try self.sendStunBindingRequest();
    } else {
        // No STUN server → gathering complete immediately
        self._gathering = .complete;
        try self.emitGatheringComplete();
    }
}

/// Add a remote candidate received via setRemoteDescription / addIceCandidate.
/// Triggers formation of new candidate pairs.
pub fn addRemoteCandidate(self: *IceAgent, cand: Candidate) !void {
    if (self._remote.len == MAX_REMOTE_CANDIDATES) return; // silently drop
    try self._remote.append(cand);

    // Form new pairs with all local candidates
    for (self._local.slice()) |*local| {
        if (!addressFamilyMatches(local.addr, cand.addr)) continue;
        if (self._pairs.len == MAX_PAIRS) break;
        try self._pairs.append(CandidatePair{
            .local = local.*,
            .remote = cand,
            .state = .waiting,
            .nominated = false,
            .check_tid = std.mem.zeroes([12]u8),
            .last_check_ms = 0,
            .rtt_ms = 0,
        });
    }

    // If we are in checking state, immediately schedule a check
    if (self._connection == .checking or self._connection == .new) {
        if (self._have_remote_creds) {
            self._connection = .checking;
        }
    }
}

// ---------------------------------------------------------------------------
// Network thread tick — called periodically from WebRtcThread
// ---------------------------------------------------------------------------

/// Drive the ICE state machine: handle STUN timeout, run connectivity checks.
/// `now_ms` is the current monotonic timestamp.
pub fn tick(self: *IceAgent, now_ms: u64) !void {
    // STUN timeout handling
    if (self._stun_state == .sent and now_ms -| self._stun_sent_ms > STUN_TIMEOUT_MS) {
        log.warn(.webrtc, "STUN timeout", .{});
        self._stun_state = .failed;
        self._gathering = .complete;
        try self.emitGatheringComplete();
    }

    // Connectivity checks
    if (self._connection == .checking) {
        try self.runConnectivityChecks(now_ms);
    }
}

/// Process an incoming UDP datagram. Returns true if consumed (STUN),
/// false if it should be forwarded to DTLS.
pub fn handleIncoming(self: *IceAgent, data: []const u8, from: net.Address, now_ms: u64) !bool {
    // STUN magic cookie at bytes 4-7
    if (data.len >= 8) {
        const magic = std.mem.readInt(u32, data[4..8], .big);
        if (magic == StunClient.STUN_MAGIC_COOKIE) {
            return self.handleStunMessage(data, from, now_ms);
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Private: host candidate gathering
// ---------------------------------------------------------------------------

fn gatherHostCandidates(self: *IceAgent) !usize {
    var count: usize = 0;

    var ifaddr: ?*net_c.struct_ifaddrs = null;
    if (net_c.getifaddrs(&ifaddr) != 0) {
        // Fallback: add loopback only
        return self.addHostCandidate(
            net.Address.initIp4(.{ 127, 0, 0, 1 }, self._sock_port),
            65534,
            false,
        );
    }
    defer net_c.freeifaddrs(ifaddr);

    var ifa = ifaddr;
    while (ifa) |iface| : (ifa = iface.ifa_next) {
        const sa = iface.ifa_addr orelse continue;
        const sa_generic: *posix.sockaddr = @ptrCast(@alignCast(sa));

        // Skip loopback and down interfaces
        if (iface.ifa_flags & @as(c_uint, @bitCast(net_c.IFF_LOOPBACK)) != 0) continue;
        if (iface.ifa_flags & @as(c_uint, @bitCast(net_c.IFF_UP)) == 0) continue;

        if (sa_generic.family == posix.AF.INET) {
            const sin: *const posix.sockaddr.in = @ptrCast(@alignCast(sa_generic));
            const ip_bytes: [4]u8 = @bitCast(sin.addr);
            const addr = net.Address.initIp4(ip_bytes, self._sock_port);
            // local_pref: default route interface gets higher pref
            const local_pref: u16 = if (isDefaultRouteIface(iface.ifa_name)) 65535 else 65000;
            _ = try self.addHostCandidate(addr, local_pref, false);
            count += 1;
        } else if (sa_generic.family == posix.AF.INET6) {
            const sin6: *const posix.sockaddr.in6 = @ptrCast(@alignCast(sa_generic));
            const ip_bytes: [16]u8 = sin6.addr;
            // Skip link-local (fe80::)
            if (ip_bytes[0] == 0xFE and ip_bytes[1] == 0x80) continue;
            const addr = net.Address.initIp6(ip_bytes, self._sock_port, sin6.flowinfo, sin6.scope_id);
            _ = try self.addHostCandidate(
                addr,
                64000,
                isTemporaryIpv6(iface.ifa_name, sin6),
            );
            count += 1;
        }

        if (count >= MAX_LOCAL_CANDIDATES) break;
    }

    if (count == 0) {
        // Absolute fallback
        _ = try self.addHostCandidate(
            net.Address.initIp4(.{ 127, 0, 0, 1 }, self._sock_port),
            65534,
            false,
        );
    }

    // RFC 6724 source selection prefers temporary addresses for outbound
    // public connections when privacy addressing is enabled. Keep stable IPv6
    // candidates for transport fallback, but expose only temporary candidates
    // when the OS reports that such an address is available.
    applyIpv6ExposurePreference(self._local.sliceMut());

    return count;
}

fn applyIpv6ExposurePreference(candidates: []Candidate) void {
    var has_temporary_ipv6 = false;
    for (candidates) |cand| {
        if (cand.temporary_ipv6) {
            has_temporary_ipv6 = true;
            break;
        }
    }
    if (!has_temporary_ipv6) return;

    for (candidates) |*cand| {
        if (cand.addr.any.family == posix.AF.INET6 and !cand.temporary_ipv6) {
            cand.expose = false;
        }
    }
}

fn addHostCandidate(
    self: *IceAgent,
    addr: net.Address,
    local_pref: u16,
    temporary_ipv6: bool,
) !usize {
    if (self._local.len >= MAX_LOCAL_CANDIDATES) return 0;

    const priority = computePriority(TYPE_PREF_HOST, local_pref, 1);

    var foundation: [32]u8 = std.mem.zeroes([32]u8);
    const flen: u8 = blk: {
        const written = std.fmt.bufPrint(&foundation, "host{d}", .{self._local.len}) catch {
            @memcpy(foundation[0..4], "host");
            break :blk 4;
        };
        break :blk @intCast(written.len);
    };

    try self._local.append(Candidate{
        .foundation = foundation,
        .foundation_len = flen,
        .component = 1,
        .priority = priority,
        .addr = addr,
        .typ = .host,
        .related_addr = null,
        .temporary_ipv6 = temporary_ipv6,
    });

    return 1;
}

fn isTemporaryIpv6(ifname: [*:0]u8, sin6: *const posix.sockaddr.in6) bool {
    if (comptime builtin.os.tag != .macos) return false;

    const sock = posix.socket(
        posix.AF.INET6,
        posix.SOCK.DGRAM | posix.SOCK.CLOEXEC,
        posix.IPPROTO.UDP,
    ) catch return false;
    defer posix.close(sock);

    var req = std.mem.zeroes(net_c.struct_in6_ifreq);
    const name = std.mem.span(ifname);
    const name_len = @min(name.len, req.ifr_name.len - 1);
    @memcpy(req.ifr_name[0..name_len], name[0..name_len]);
    req.ifr_ifru.ifru_addr = @bitCast(sin6.*);

    if (net_c.ioctl(sock, net_c.SIOCGIFAFLAG_IN6, &req) != 0) return false;
    const flags = req.ifr_ifru.ifru_flags6;
    return flags & net_c.IN6_IFF_TEMPORARY != 0 and
        flags & (net_c.IN6_IFF_DEPRECATED | net_c.IN6_IFF_NOTREADY) == 0;
}

// ---------------------------------------------------------------------------
// Private: STUN srflx
// ---------------------------------------------------------------------------

fn sendStunBindingRequest(self: *IceAgent) !void {
    const server = self._stun_server orelse return;

    self._stun_tid = StunClient.randomTransactionId();
    self._stun_state = .sent;
    self._stun_sent_ms = currentMs();

    var buf: [512]u8 = undefined;
    const len = try StunClient.buildBindingRequest(
        &buf,
        self._stun_tid,
        null, // no USERNAME for server reflexive STUN
        null, // no MESSAGE-INTEGRITY
        null,
        false,
        null,
    );

    _ = try posix.sendto(
        self._sock,
        buf[0..len],
        0,
        &server.any,
        server.getOsSockLen(),
    );

    log.info(.webrtc, "STUN binding request sent", .{ .port = self._sock_port });
}

fn handleSrflxResponse(self: *IceAgent, resp: StunClient.BindingResponse) !void {
    // Verify transaction ID
    if (!std.mem.eql(u8, &resp.transaction_id, &self._stun_tid)) return;

    self._stun_state = .received;

    // Base host for raddr must share address family with the mapped STUN addr
    // (IPv4 srflx must not cite an IPv6 host as related).
    const base_addr = blk: {
        const want_v4 = resp.mapped_addr.any.family == std.posix.AF.INET;
        var fallback: ?net.Address = null;
        for (self._local.slice()) |*c| {
            if (c.typ != .host) continue;
            const is_v4 = c.addr.any.family == std.posix.AF.INET;
            if (is_v4 == want_v4) break :blk c.addr;
            if (fallback == null) fallback = c.addr;
        }
        break :blk fallback orelse return;
    };

    const priority = computePriority(TYPE_PREF_SRFLX, 65535, 1);
    var foundation: [32]u8 = std.mem.zeroes([32]u8);
    const flen: u8 = blk: {
        const written = std.fmt.bufPrint(&foundation, "srflx0", .{}) catch {
            @memcpy(foundation[0..6], "srflx0");
            break :blk 6;
        };
        break :blk @intCast(written.len);
    };

    const cand = Candidate{
        .foundation = foundation,
        .foundation_len = flen,
        .component = 1,
        .priority = priority,
        .addr = resp.mapped_addr,
        .typ = .srflx,
        .related_addr = base_addr,
    };

    if (self._local.len < MAX_LOCAL_CANDIDATES) {
        try self._local.append(cand);
    }

    // Emit srflx candidate event
    try self.emitCandidate(&cand);

    // Gathering complete
    self._gathering = .complete;
    try self.emitGatheringComplete();

    log.info(.webrtc, "STUN srflx candidate", .{ .addr = resp.mapped_addr });
}

// ---------------------------------------------------------------------------
// Private: ICE connectivity checks
// ---------------------------------------------------------------------------

fn runConnectivityChecks(self: *IceAgent, now_ms: u64) !void {
    // Find the highest-priority waiting pair
    var best_idx: ?usize = null;
    var best_pri: u64 = 0;

    for (self._pairs.slice(), 0..) |*pair, i| {
        if (pair.state != .waiting and pair.state != .in_progress) continue;
        if (pair.state == .in_progress and now_ms -| pair.last_check_ms < CHECK_INTERVAL_MS) continue;

        // RFC 8445 §6.1.4.2 pair priority
        const local_pri: u64 = pair.local.priority;
        const remote_pri: u64 = pair.remote.priority;
        const pair_pri = if (self._role == .controlling)
            (local_pri << 32) | remote_pri
        else
            (remote_pri << 32) | local_pri;

        if (pair_pri > best_pri) {
            best_pri = pair_pri;
            best_idx = i;
        }
    }

    const idx = best_idx orelse return;
    try self.sendConnectivityCheck(idx, now_ms);
}

fn sendConnectivityCheck(self: *IceAgent, pair_idx: usize, now_ms: u64) !void {
    const pair = &self._pairs.sliceMut()[pair_idx];

    // Build USERNAME: remote_ufrag:local_ufrag
    var username_buf: [64]u8 = undefined;
    const username = std.fmt.bufPrint(&username_buf, "{s}:{s}", .{
        self._remote_ufrag[0..ufragLen(self._remote_ufrag)],
        self._local_ufrag[0..ufragLen(self._local_ufrag)],
    }) catch return;

    const tid = StunClient.randomTransactionId();
    pair.check_tid = tid;
    pair.last_check_ms = now_ms;
    pair.state = .in_progress;

    const is_nominating = self._role == .controlling and pair.state == .in_progress;
    const pwd = self._remote_pwd[0..pwdLen(self._remote_pwd)];

    var buf: [1024]u8 = undefined;
    const len = StunClient.buildBindingRequest(
        &buf,
        tid,
        username,
        pwd,
        pair.local.priority,
        is_nominating,
        if (self._role == .controlling) self._tiebreaker else null,
    ) catch return;

    _ = posix.sendto(
        self._sock,
        buf[0..len],
        0,
        &pair.remote.addr.any,
        pair.remote.addr.getOsSockLen(),
    ) catch |err| {
        log.warn(.webrtc, "ICE check send failed", .{ .err = err });
        pair.state = .failed;
        return;
    };
}

// ---------------------------------------------------------------------------
// Private: STUN message dispatch
// ---------------------------------------------------------------------------

fn handleStunMessage(self: *IceAgent, data: []const u8, from: net.Address, now_ms: u64) !bool {
    if (data.len < 2) return false;

    const msg_type_raw = std.mem.readInt(u16, data[0..2], .big);

    switch (@as(StunClient.MessageType, @enumFromInt(msg_type_raw))) {
        .binding_success => {
            // Could be STUN server response or ICE check response
            if (self._stun_state == .sent) {
                const resp = StunClient.parseBindingResponse(data) catch return true;
                // Check if tid matches our server STUN request
                if (std.mem.eql(u8, &resp.transaction_id, &self._stun_tid)) {
                    try self.handleSrflxResponse(resp);
                    return true;
                }
            }
            // ICE connectivity check success
            try self.handleCheckResponse(data, now_ms);
            return true;
        },
        .binding_request => {
            // Inbound ICE connectivity check from remote
            try self.handleInboundCheck(data, from, now_ms);
            return true;
        },
        .binding_error => return true,
        _ => return false,
    }
}

fn handleCheckResponse(self: *IceAgent, data: []const u8, now_ms: u64) !void {
    if (data.len < 20) return;
    var tid: [12]u8 = undefined;
    @memcpy(&tid, data[8..20]);

    for (self._pairs.sliceMut()) |*pair_ptr| {
        if (!std.mem.eql(u8, &pair_ptr.check_tid, &tid)) continue;

        const resp = StunClient.parseBindingResponse(data) catch {
            pair_ptr.state = .failed;
            return;
        };
        _ = resp;

        pair_ptr.state = .succeeded;
        pair_ptr.rtt_ms = @intCast(now_ms -| pair_ptr.last_check_ms);

        if (self._nominated == null) {
            pair_ptr.nominated = true;
            self._nominated = pair_ptr;
            self._connection = .connected;
            log.info(.webrtc, "ICE connected", .{ .rtt = pair_ptr.rtt_ms });
            try self.emitConnectionState(.connected);
        }
        return;
    }
}

fn handleInboundCheck(self: *IceAgent, data: []const u8, from: net.Address, now_ms: u64) !void {
    _ = now_ms;

    // Verify MESSAGE-INTEGRITY with our local password
    if (!StunClient.verifyMessageIntegrity(data, self._local_pwd[0..pwdLen(self._local_pwd)])) {
        log.warn(.webrtc, "ICE check bad MI ignored", .{});
        return;
    }

    // Send success response
    var tid: [12]u8 = undefined;
    @memcpy(&tid, data[8..20]);

    var resp_buf: [256]u8 = undefined;
    const resp_len = buildBindingSuccessResponse(&resp_buf, &tid, from, self._local_pwd[0..pwdLen(self._local_pwd)]) catch return;

    _ = posix.sendto(self._sock, resp_buf[0..resp_len], 0, &from.any, from.getOsSockLen()) catch |err| {
        log.warn(.webrtc, "ICE response send", .{ .err = err });
    };
}

fn buildBindingSuccessResponse(buf: []u8, tid: *const [12]u8, mapped: net.Address, pwd: []const u8) !usize {
    if (buf.len < 20) return error.AttributeOverflow;

    std.mem.writeInt(u16, buf[0..2], @intFromEnum(StunClient.MessageType.binding_success), .big);
    std.mem.writeInt(u16, buf[2..4], 0, .big);
    std.mem.writeInt(u32, buf[4..8], StunClient.STUN_MAGIC_COOKIE, .big);
    @memcpy(buf[8..20], tid);
    var pos: usize = 20;

    // XOR-MAPPED-ADDRESS
    pos = try writeXorMappedAddress(buf, pos, mapped, tid);

    // MESSAGE-INTEGRITY
    const mi_len: u16 = @intCast((pos - 20) + 4 + 20);
    std.mem.writeInt(u16, buf[2..4], mi_len, .big);
    var hmac: [20]u8 = undefined;
    computeHmacSha1ForResponse(buf[0..pos], pwd, &hmac);

    if (pos + 4 + 20 > buf.len) return error.AttributeOverflow;
    std.mem.writeInt(u16, buf[pos..][0..2], @intFromEnum(StunClient.AttributeType.message_integrity), .big);
    std.mem.writeInt(u16, buf[pos + 2 ..][0..2], 20, .big);
    @memcpy(buf[pos + 4 ..][0..20], &hmac);
    pos += 24;

    std.mem.writeInt(u16, buf[2..4], @intCast(pos - 20), .big);
    return pos;
}

fn writeXorMappedAddress(buf: []u8, pos: usize, addr: net.Address, tid: *const [12]u8) !usize {
    _ = tid;
    if (pos + 4 + 8 > buf.len) return error.AttributeOverflow;
    std.mem.writeInt(u16, buf[pos..][0..2], @intFromEnum(StunClient.AttributeType.xor_mapped_address), .big);
    std.mem.writeInt(u16, buf[pos + 2 ..][0..2], 8, .big);
    buf[pos + 4] = 0; // reserved
    buf[pos + 5] = 0x01; // IPv4

    switch (addr.any.family) {
        posix.AF.INET => {
            const in: *const posix.sockaddr.in = @ptrCast(@alignCast(&addr.any));
            const port: u16 = std.mem.bigToNative(u16, in.port);
            const xport = port ^ @as(u16, @truncate(StunClient.STUN_MAGIC_COOKIE >> 16));
            std.mem.writeInt(u16, buf[pos + 6 ..][0..2], xport, .big);
            const ip = std.mem.bigToNative(u32, in.addr) ^ StunClient.STUN_MAGIC_COOKIE;
            std.mem.writeInt(u32, buf[pos + 8 ..][0..4], ip, .big);
        },
        else => return error.AttributeOverflow,
    }
    return pos + 12;
}

fn computeHmacSha1ForResponse(msg: []const u8, key: []const u8, out: *[20]u8) void {
    const c_ssl = @cImport({
        @cInclude("openssl/hmac.h");
    });
    var md_len: c_uint = 20;
    _ = c_ssl.HMAC(c_ssl.EVP_sha1(), key.ptr, @intCast(key.len), msg.ptr, @intCast(msg.len), out, &md_len);
}

// ---------------------------------------------------------------------------
// Private: event emission helpers
// ---------------------------------------------------------------------------

fn formatCandidateAddress(addr: net.Address, out: *[64]u8) ?u8 {
    switch (addr.any.family) {
        posix.AF.INET => {
            const sin: *const posix.sockaddr.in = @ptrCast(@alignCast(&addr.any));
            const ip: [4]u8 = @bitCast(sin.addr);
            const written = std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch return null;
            return @intCast(written.len);
        },
        posix.AF.INET6 => {
            // std.net owns canonical RFC 5952 compression. Address.format also
            // includes brackets and a port for IPv6, so expose only the text
            // between '[' and ']'.
            var formatted_buf: [96]u8 = undefined;
            const formatted = std.fmt.bufPrint(&formatted_buf, "{f}", .{addr}) catch return null;
            if (formatted.len < 2 or formatted[0] != '[') return null;
            const end = std.mem.indexOfScalar(u8, formatted, ']') orelse return null;
            if (end - 1 > out.len) return null;
            @memcpy(out[0 .. end - 1], formatted[1..end]);
            return @intCast(end - 1);
        },
        else => return null,
    }
}

fn emitCandidate(self: *IceAgent, cand: *const Candidate) !void {
    if (!cand.expose) return;
    // Raw LAN addresses are transport state, not script-visible identity.
    // Chrome protects these host candidates with mDNS. Until Koko owns an
    // mDNS responder, omit only the exposure event while retaining the real
    // candidate internally for ICE connectivity.
    if (cand.typ == .host and isPrivateOrLocalAddress(cand.addr)) return;

    var ev = RtcEventQueue.RtcEvent.IceCandidateEvent{
        .foundation = cand.foundation,
        .foundation_len = cand.foundation_len,
        .component = cand.component,
        .protocol = .udp,
        .priority = cand.priority,
        .address = std.mem.zeroes([64]u8),
        .address_len = 0,
        .port = cand.addr.getPort(),
        .typ = switch (cand.typ) {
            .host => .host,
            .srflx => .srflx,
            .prflx => .prflx,
            .relay => .relay,
        },
        .related_address = std.mem.zeroes([64]u8),
        .related_address_len = 0,
        .related_port = 0,
    };

    if (formatCandidateAddress(cand.addr, &ev.address)) |ip_len| {
        ev.address_len = ip_len;
    }

    if (cand.related_addr) |rel| {
        if (formatCandidateAddress(rel, &ev.related_address)) |rel_len| {
            ev.related_address_len = rel_len;
            ev.related_port = rel.getPort();
        }
    }

    const node = try self._alloc.create(RtcEventQueue.Node);
    node.* = .{ .event = .{ .ice_candidate = ev } };
    self._event_queue.push(node);
}

fn isPrivateOrLocalAddress(addr: net.Address) bool {
    switch (addr.any.family) {
        posix.AF.INET => {
            const sin: *const posix.sockaddr.in = @ptrCast(@alignCast(&addr.any));
            const ip: [4]u8 = @bitCast(sin.addr);
            return ip[0] == 10 or
                ip[0] == 127 or
                (ip[0] == 169 and ip[1] == 254) or
                (ip[0] == 172 and ip[1] >= 16 and ip[1] <= 31) or
                (ip[0] == 192 and ip[1] == 168);
        },
        posix.AF.INET6 => {
            const sin6: *const posix.sockaddr.in6 = @ptrCast(@alignCast(&addr.any));
            const ip = sin6.addr;
            const loopback = std.mem.allEqual(u8, ip[0..15], 0) and ip[15] == 1;
            return loopback or
                (ip[0] & 0xfe) == 0xfc or
                (ip[0] == 0xfe and (ip[1] & 0xc0) == 0x80);
        },
        else => return true,
    }
}

fn emitGatheringComplete(self: *IceAgent) !void {
    const node = try self._alloc.create(RtcEventQueue.Node);
    node.* = .{ .event = .ice_gathering_complete };
    self._event_queue.push(node);
}

fn emitConnectionState(self: *IceAgent, state: RtcEventQueue.RtcEvent.IceConnectionState) !void {
    const node = try self._alloc.create(RtcEventQueue.Node);
    node.* = .{ .event = .{ .ice_connection_state = state } };
    self._event_queue.push(node);
}

// ---------------------------------------------------------------------------
// Private: utilities
// ---------------------------------------------------------------------------

/// RFC 8445 §5.1.2.1 priority formula.
pub fn computePriority(type_pref: u24, local_pref: u16, component_id: u8) u32 {
    return (@as(u32, type_pref) << 24) |
        (@as(u32, local_pref) << 8) |
        (256 - @as(u32, component_id));
}

fn addressFamilyMatches(a: net.Address, b: net.Address) bool {
    return a.any.family == b.any.family;
}

fn isDefaultRouteIface(name: [*:0]u8) bool {
    const s = std.mem.span(name);
    // Heuristic: eth0, en0, wlan0 are likely default
    return std.mem.startsWith(u8, s, "eth") or
        std.mem.startsWith(u8, s, "en") or
        std.mem.startsWith(u8, s, "wlan") or
        std.mem.startsWith(u8, s, "ens") or
        std.mem.startsWith(u8, s, "eno");
}

fn ufragLen(buf: [8]u8) usize {
    for (buf, 0..) |b, i| {
        if (b == 0) return i;
    }
    return 8;
}

fn pwdLen(buf: [24]u8) usize {
    for (buf, 0..) |b, i| {
        if (b == 0) return i;
    }
    return 24;
}

fn currentMs() u64 {
    return datetime.milliTimestamp(.monotonic);
}

fn randomU64() u64 {
    var bytes: [8]u8 = undefined;
    runtime_io.get().random(&bytes);
    return std.mem.readInt(u64, &bytes, .little);
}

test "proxy network policy completes ICE without direct candidates" {
    const alloc = std.testing.allocator;
    var events = RtcEventQueue.init();
    var agent = try IceAgent.init(
        alloc,
        &events,
        [_]u8{'u'} ** 8,
        [_]u8{'p'} ** 24,
        .controlling,
        false,
    );
    defer agent.deinit();

    // Supplying a STUN address must not matter: the network-context policy
    // owns whether a direct UDP route may be used.
    try agent.startGathering(net.Address.initIp4(.{ 203, 0, 113, 1 }, 3478));

    try std.testing.expectEqual(@as(usize, 0), agent._local.len);
    try std.testing.expectEqual(GatheringState.complete, agent._gathering);
    try std.testing.expectEqual(StunState.idle, agent._stun_state);

    const node = events.pop() orelse return error.MissingGatheringComplete;
    defer alloc.destroy(node);
    try std.testing.expect(node.event == .ice_gathering_complete);
    try std.testing.expect(events.pop() == null);
}

test "proxy policy never emits a synthetic candidate" {
    const alloc = std.testing.allocator;
    var events = RtcEventQueue.init();
    var agent = try IceAgent.init(
        alloc,
        &events,
        [_]u8{'u'} ** 8,
        [_]u8{'p'} ** 24,
        .controlling,
        false,
    );
    defer agent.deinit();

    try agent.startGathering(net.Address.initIp4(.{ 198, 51, 100, 1 }, 3478));
    try std.testing.expectEqual(@as(usize, 0), agent._local.len);
    try std.testing.expectEqual(StunState.idle, agent._stun_state);

    const complete = events.pop() orelse return error.MissingGatheringComplete;
    defer alloc.destroy(complete);
    try std.testing.expect(complete.event == .ice_gathering_complete);
    try std.testing.expect(events.pop() == null);
}

test "ICE exposure canonicalizes IPv6 and classifies local addresses" {
    const ipv6 = try net.Address.parseIp(
        "2402:0800:61c3:c20a:0197:d6e9:3856:5d5e",
        50689,
    );
    var text: [64]u8 = undefined;
    const len = formatCandidateAddress(ipv6, &text) orelse
        return error.CouldNotFormatCandidate;
    try std.testing.expectEqualStrings(
        "2402:800:61c3:c20a:197:d6e9:3856:5d5e",
        text[0..len],
    );

    try std.testing.expect(isPrivateOrLocalAddress(
        try net.Address.parseIp("192.168.1.21", 1234),
    ));
    try std.testing.expect(isPrivateOrLocalAddress(
        try net.Address.parseIp("fd00::1", 1234),
    ));
    try std.testing.expect(!isPrivateOrLocalAddress(ipv6));
}

test "ICE exposure prefers OS temporary IPv6 without removing transport state" {
    const stable = try net.Address.parseIp("2001:db8::1", 5000);
    const temporary = try net.Address.parseIp("2001:db8::2", 5000);
    const ipv4 = try net.Address.parseIp("198.51.100.8", 5000);
    var candidates = [_]Candidate{
        .{
            .foundation = std.mem.zeroes([32]u8),
            .foundation_len = 0,
            .component = 1,
            .priority = 1,
            .addr = stable,
            .typ = .host,
            .related_addr = null,
        },
        .{
            .foundation = std.mem.zeroes([32]u8),
            .foundation_len = 0,
            .component = 1,
            .priority = 1,
            .addr = temporary,
            .typ = .host,
            .related_addr = null,
            .temporary_ipv6 = true,
        },
        .{
            .foundation = std.mem.zeroes([32]u8),
            .foundation_len = 0,
            .component = 1,
            .priority = 1,
            .addr = ipv4,
            .typ = .srflx,
            .related_addr = null,
        },
    };

    applyIpv6ExposurePreference(&candidates);
    try std.testing.expect(!candidates[0].expose);
    try std.testing.expect(candidates[1].expose);
    try std.testing.expect(candidates[2].expose);
    // Selection changes only script exposure; all transport candidates remain.
    try std.testing.expectEqual(@as(usize, 3), candidates.len);
}
