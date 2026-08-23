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

//! WebRTC network thread — owns all network I/O for a single RTCPeerConnection.
//!
//! Architecture:
//!   JS thread  ←──RtcEventQueue──  WebRtcThread  ──RtcCommandQueue──→  JS thread
//!
//! One WebRtcThread per RTCPeerConnection. The thread:
//!   1. Opens a UDP socket (via IceAgent)
//!   2. Runs a poll() loop with a 20 ms timeout
//!   3. On readable UDP:
//!      a. Tries IceAgent.handleIncoming() — if STUN, consumed
//!      b. Else injects into DtlsTransport.injectIncoming()
//!      c. If DTLS consumed, reads decrypted data → SctpTransport.injectIncoming()
//!   4. On tick:
//!      a. IceAgent.tick() — STUN timeout, connectivity checks
//!      b. DtlsTransport state transitions (retransmits handled by BoringSSL)
//!      c. Drains RtcCommandQueue from JS thread
//!   5. Posts events to RtcEventQueue for JS thread
//!
//! Lifecycle:
//!   WebRtcThread.spawn() → runs on OS thread → WebRtcThread.requestStop() → join
//!
//! Ownership:
//!   - IceAgent is inline (value type) inside WebRtcThread
//!   - DtlsTransport is inline (value type)
//!   - SctpTransport is heap-allocated (needs stable address for usrsctp)
//!   - All three are created/destroyed on the WebRTC thread

const std = @import("std");
const net = @import("../../support/net.zig");
const posix = @import("../../support/posix.zig");
const runtime_io = @import("../../support/io.zig");
const datetime = @import("../../support/datetime.zig");
const Allocator = std.mem.Allocator;

const log = @import("../../support/log.zig");
const RtcEventQueue = @import("RtcEventQueue.zig");
const RtcCommandQueue = @import("RtcCommandQueue.zig");
const IceAgent = @import("../../core/webapi/net/rtc/IceAgent.zig");
const DtlsTransport = @import("../../core/webapi/net/rtc/DtlsTransport.zig");
const SctpTransport = @import("../../core/webapi/net/rtc/SctpTransport.zig");
const SdpParser = @import("../../core/webapi/net/rtc/SdpParser.zig");

const WebRtcThread = @This();

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

pub const Config = struct {
    stun_server: ?net.Address = null,
    sctp_local_port: u16 = 5000,
    sctp_remote_port: u16 = 5000,
    /// ICE role (offerer = controlling)
    ice_role: IceAgent.Role = .controlling,
    allow_non_proxied_udp: bool = true,
};

// ---------------------------------------------------------------------------
// Fields
// ---------------------------------------------------------------------------

_alloc: Allocator,
_config: Config,

// Cross-thread communication
_event_queue: *RtcEventQueue,
_cmd_queue: *RtcCommandQueue,

// Network stack (all touched only from WebRTC thread after init)
_ice: IceAgent,
_dtls: DtlsTransport,
_sctp: ?*SctpTransport,

// Peer address (set when ICE nominates a pair)
_peer_addr: ?net.Address,
_peer_sockaddr: posix.sockaddr.storage,
_peer_sockaddr_len: posix.socklen_t,

// Credentials
_local_ufrag: [8]u8,
_local_pwd: [24]u8,

// Thread control
_thread: std.Thread,
_stop: std.atomic.Value(bool),

// Wake pipe (write end woken from JS thread to unblock poll())
_wake_r: posix.fd_t,
_wake_w: posix.fd_t,

// Next outgoing SCTP stream ID (even for offerer, odd for answerer)
_next_stream_id: u16,

// ---------------------------------------------------------------------------
// Init / deinit (called from JS thread before spawn)
// ---------------------------------------------------------------------------

pub fn create(alloc: Allocator, event_queue: *RtcEventQueue, cmd_queue: *RtcCommandQueue, config: Config) !*WebRtcThread {
    const self = try alloc.create(WebRtcThread);
    errdefer alloc.destroy(self);

    // Generate ICE credentials
    var ufrag: [8]u8 = undefined;
    var pwd: [24]u8 = undefined;
    genIceCredentials(&ufrag, &pwd);

    // Create wake pipe for poll() interruption
    const pipe_fds = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });

    // Init ICE agent (opens UDP socket)
    const ice = try IceAgent.init(
        alloc,
        event_queue,
        ufrag,
        pwd,
        config.ice_role,
        config.allow_non_proxied_udp,
    );

    // Init DTLS transport (generates certificate)
    const dtls_role: DtlsTransport.Role = if (config.ice_role == .controlling) .client else .server;
    const dtls = try DtlsTransport.init(alloc, event_queue, dtls_role);

    self.* = WebRtcThread{
        ._alloc = alloc,
        ._config = config,
        ._event_queue = event_queue,
        ._cmd_queue = cmd_queue,
        ._ice = ice,
        ._dtls = dtls,
        ._sctp = null,
        ._peer_addr = null,
        ._peer_sockaddr = std.mem.zeroes(posix.sockaddr.storage),
        ._peer_sockaddr_len = 0,
        ._local_ufrag = ufrag,
        ._local_pwd = pwd,
        ._thread = undefined,
        ._stop = .init(false),
        ._wake_r = pipe_fds[0],
        ._wake_w = pipe_fds[1],
        ._next_stream_id = if (config.ice_role == .controlling) 0 else 1,
    };

    return self;
}

pub fn destroy(self: *WebRtcThread) void {
    if (self._sctp) |s| s.deinit();
    self._dtls.deinit();
    self._ice.deinit();
    posix.close(self._wake_r);
    posix.close(self._wake_w);
    self._alloc.destroy(self);
}

// ---------------------------------------------------------------------------
// Public API (called from JS thread)
// ---------------------------------------------------------------------------

pub fn localUfrag(self: *const WebRtcThread) []const u8 {
    return &self._local_ufrag;
}

pub fn localPwd(self: *const WebRtcThread) []const u8 {
    return &self._local_pwd;
}

pub fn dtlsFingerprint(self: *const WebRtcThread) []const u8 {
    return self._dtls.fingerprint();
}

/// Spawn the WebRTC network thread.
pub fn spawn(self: *WebRtcThread) !void {
    self._thread = try std.Thread.spawn(.{}, threadMain, .{self});
}

/// Signal the thread to stop and wait for it to exit.
pub fn stop(self: *WebRtcThread) void {
    self._stop.store(true, .release);
    self.wake();
    self._thread.join();
}

/// Interrupt poll() — called from JS thread when a command is enqueued.
pub fn wake(self: *WebRtcThread) void {
    const byte: [1]u8 = .{1};
    _ = posix.write(self._wake_w, &byte) catch {};
}

// ---------------------------------------------------------------------------
// Thread main loop
// ---------------------------------------------------------------------------

fn threadMain(self: *WebRtcThread) void {
    SctpTransport.globalInit();
    defer SctpTransport.globalDeinit();

    self.run() catch |err| {
        log.err(.webrtc, "WebRTC thread fatal error", .{ .err = err });
    };
}

fn run(self: *WebRtcThread) !void {
    const ice_fd = self._ice.fd();
    var last_tick_ms: u64 = monoMs();

    while (!self._stop.load(.acquire)) {
        // Build poll set: [0] = wake pipe, [1] = ICE UDP socket
        var fds = [2]posix.pollfd{
            .{ .fd = self._wake_r, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = ice_fd, .events = posix.POLL.IN, .revents = 0 },
        };

        _ = posix.poll(&fds, 20) catch |err| {
            log.warn(.webrtc, "poll failed", .{ .err = err });
            continue;
        };

        const now_ms = monoMs();

        // Drain wake pipe
        if (fds[0].revents & posix.POLL.IN != 0) {
            var tmp: [64]u8 = undefined;
            _ = posix.read(self._wake_r, &tmp) catch {};
        }

        // Drain incoming UDP datagrams
        if (fds[1].revents & posix.POLL.IN != 0) {
            self.drainUdp(now_ms) catch |err| {
                log.warn(.webrtc, "UDP drain error", .{ .err = err });
            };
        }

        // Periodic tick
        if (now_ms -| last_tick_ms >= 20) {
            last_tick_ms = now_ms;
            self.tick(now_ms) catch |err| {
                log.warn(.webrtc, "tick error", .{ .err = err });
            };
        }

        // Process commands from JS thread
        self.drainCommands() catch |err| {
            log.warn(.webrtc, "command drain error", .{ .err = err });
        };
    }

    // Cleanup
    if (self._sctp) |s| s.close();
    self._dtls.close();
}

// ---------------------------------------------------------------------------
// UDP drain
// ---------------------------------------------------------------------------

fn drainUdp(self: *WebRtcThread, now_ms: u64) !void {
    var buf: [65536]u8 = undefined;
    var from: posix.sockaddr.storage = undefined;
    var from_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);

    while (true) {
        const n = posix.recvfrom(
            self._ice.fd(),
            &buf,
            0,
            @ptrCast(&from),
            &from_len,
        ) catch |err| {
            if (err == error.WouldBlock) break;
            log.warn(.webrtc, "recvfrom failed", .{ .err = err });
            break;
        };

        if (n == 0) break;
        const data = buf[0..n];
        const from_addr = net.Address.initPosix(@ptrCast(@alignCast(&from)));

        // Try ICE (STUN demux)
        const consumed_by_ice = self._ice.handleIncoming(data, from_addr, now_ms) catch false;
        if (consumed_by_ice) {
            // ICE connected → start DTLS if not started
            if (self._ice._connection == .connected and self._dtls._state == .new) {
                if (self._peer_addr == null) {
                    self._peer_addr = from_addr;
                    self._peer_sockaddr = from;
                    self._peer_sockaddr_len = from_len;
                }
                if (self._dtls._role == .client) {
                    try self._dtls.startHandshake(
                        self._ice.fd(),
                        @ptrCast(&self._peer_sockaddr),
                        self._peer_sockaddr_len,
                    );
                }
            }
            continue;
        }

        // Try DTLS
        const consumed_by_dtls = try self._dtls.injectIncoming(
            data,
            self._ice.fd(),
            @ptrCast(&self._peer_sockaddr),
            self._peer_sockaddr_len,
        );

        if (consumed_by_dtls) {
            // Read any decrypted application data (SCTP)
            var dec_buf: [65536]u8 = undefined;
            while (true) {
                const dec_n = self._dtls.recv(&dec_buf);
                if (dec_n == 0) break;
                if (self._sctp) |sctp| {
                    const send_ctx = SctpTransport.SendCtx{
                        .sock = self._ice.fd(),
                        .peer = @ptrCast(&self._peer_sockaddr),
                        .peer_len = self._peer_sockaddr_len,
                    };
                    sctp.setCallbackContext(&send_ctx);
                    sctp.injectIncoming(dec_buf[0..dec_n]);
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Periodic tick
// ---------------------------------------------------------------------------

fn tick(self: *WebRtcThread, now_ms: u64) !void {
    try self._ice.tick(now_ms);

    // If ICE just connected and DTLS is server, wait for client to initiate
    if (self._ice._connection == .connected and self._dtls._state == .new) {
        if (self._dtls._role == .server) {
            // Server-side: DTLS handshake will start when client sends first packet
            self._dtls._state = .connecting;
        }
    }

    // After DTLS connected, start SCTP if not yet started
    if (self._dtls._state == .connected) {
        if (self._sctp == null) {
            const sctp = SctpTransport.init(
                self._alloc,
                self._event_queue,
                &self._dtls,
                self._config.sctp_local_port,
                self._config.sctp_remote_port,
            ) catch |err| {
                log.err(.webrtc, "SCTP init failed", .{ .err = err });
                return;
            };
            self._sctp = sctp;

            // As DTLS client (offerer), initiate SCTP connection
            if (self._dtls._role == .client) {
                sctp.connect() catch |err| {
                    log.err(.webrtc, "SCTP connect failed", .{ .err = err });
                };
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Command processing
// ---------------------------------------------------------------------------

fn drainCommands(self: *WebRtcThread) !void {
    while (true) {
        const node = self._cmd_queue.pop() orelse break;
        defer self._alloc.destroy(node);

        try self.handleCommand(node.cmd);
    }
}

fn handleCommand(self: *WebRtcThread, cmd: RtcCommandQueue.RtcCommand) !void {
    switch (cmd) {
        .start_gathering => |stun_addr| {
            try self._ice.startGathering(stun_addr);
        },

        .set_remote_description => |sdp_info| {
            // sdp_info.sdp_buf is caller-owned; we parse and extract credentials.
            // The ParsedSdp borrows from sdp_info.sdp_buf.
            const parsed = SdpParser.parse(sdp_info.sdp_buf) catch |err| {
                log.warn(.webrtc, "SDP parse failed", .{ .err = err });
                return;
            };

            // Copy credentials (fixed-size arrays)
            var remote_ufrag: [8]u8 = std.mem.zeroes([8]u8);
            var remote_pwd: [24]u8 = std.mem.zeroes([24]u8);
            const ul = @min(parsed.ice_ufrag.len, 8);
            @memcpy(remote_ufrag[0..ul], parsed.ice_ufrag[0..ul]);
            const pl = @min(parsed.ice_pwd.len, 24);
            @memcpy(remote_pwd[0..pl], parsed.ice_pwd[0..pl]);

            self._ice.setRemoteCredentials(remote_ufrag, remote_pwd);

            // Add remote candidates embedded in the SDP
            for (parsed.candidates[0..parsed.candidate_count]) |pc| {
                const cand = parsedCandidateToIce(pc) orelse continue;
                self._ice.addRemoteCandidate(cand) catch |err| {
                    log.warn(.webrtc, "addRemoteCandidate failed", .{ .err = err });
                };
            }

            // Free the SDP buffer (was heap-allocated by the JS command sender)
            self._alloc.free(sdp_info.sdp_buf);
        },

        .add_ice_candidate => |cand_info| {
            defer self._alloc.free(cand_info.candidate_str);
            const parsed = SdpParser.parseCandidate(cand_info.candidate_str) orelse return;
            const cand = parsedCandidateToIce(parsed) orelse return;
            self._ice.addRemoteCandidate(cand) catch |err| {
                log.warn(.webrtc, "addIceCandidate failed", .{ .err = err });
            };
        },

        .create_data_channel => |info| {
            defer self._alloc.free(info.label);
            defer if (info.protocol.len > 0) self._alloc.free(info.protocol);

            const stream_id = self.allocStreamId();
            if (self._sctp) |sctp| {
                sctp.openChannel(
                    stream_id,
                    info.label,
                    info.protocol,
                    info.ordered,
                    info.max_retransmits,
                ) catch |err| {
                    log.warn(.webrtc, "openChannel failed", .{ .err = err });
                    return;
                };

                // Emit event so JS side creates RTCDataChannel JS object
                const node = try self._alloc.create(RtcEventQueue.Node);
                node.* = .{ .event = .{ .channel_created = .{
                    .stream_id = stream_id,
                    .js_channel_id = info.js_channel_id,
                } } };
                self._event_queue.push(node);
            }
        },

        .send_data => |data_info| {
            defer self._alloc.free(data_info.data);
            if (self._sctp) |sctp| {
                sctp.sendData(
                    data_info.stream_id,
                    data_info.ppid,
                    data_info.ordered,
                    null,
                    data_info.data,
                ) catch |err| {
                    log.warn(.webrtc, "sendData failed", .{ .err = err });
                };
            }
        },

        .close_channel => |stream_id| {
            if (self._sctp) |sctp| {
                sctp.closeChannel(stream_id);
            }
        },

        .close => {
            self._stop.store(true, .release);
        },
    }
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

fn parsedCandidateToIce(pc: SdpParser.ParsedCandidate) ?IceAgent.Candidate {
    // Only handle UDP candidates for now
    if (!std.ascii.eqlIgnoreCase(pc.transport, "UDP")) return null;

    const addr = net.Address.parseIp(pc.address, pc.port) catch return null;

    const typ: IceAgent.CandidateType = blk: {
        if (std.mem.eql(u8, pc.typ, "host")) break :blk .host;
        if (std.mem.eql(u8, pc.typ, "srflx")) break :blk .srflx;
        if (std.mem.eql(u8, pc.typ, "prflx")) break :blk .prflx;
        if (std.mem.eql(u8, pc.typ, "relay")) break :blk .relay;
        return null;
    };

    var foundation: [32]u8 = std.mem.zeroes([32]u8);
    const fl = @min(pc.foundation.len, 32);
    @memcpy(foundation[0..fl], pc.foundation[0..fl]);

    const related_addr: ?net.Address = if (pc.related_address) |ra|
        net.Address.parseIp(ra, pc.related_port orelse 0) catch null
    else
        null;

    return IceAgent.Candidate{
        .foundation = foundation,
        .foundation_len = @intCast(fl),
        .component = pc.component,
        .priority = pc.priority,
        .addr = addr,
        .typ = typ,
        .related_addr = related_addr,
    };
}

fn allocStreamId(self: *WebRtcThread) u16 {
    const id = self._next_stream_id;
    self._next_stream_id += 2; // offerer: even, answerer: odd
    return id;
}

fn genIceCredentials(ufrag: *[8]u8, pwd: *[24]u8) void {
    const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/";
    runtime_io.get().random(ufrag);
    runtime_io.get().random(pwd);
    for (ufrag) |*b| b.* = chars[b.* % chars.len];
    for (pwd) |*b| b.* = chars[b.* % chars.len];
}

fn monoMs() u64 {
    return datetime.milliTimestamp(.monotonic);
}
