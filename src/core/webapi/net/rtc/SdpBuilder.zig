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

//! SDP offer/answer builder for WebRTC sessions.
//!
//! Supports DataChannel (m=application) and fingerprint-oriented audio/video
//! m-lines (Chrome-like codec lists) without a real RTP stack.

const std = @import("std");

pub const SdpRole = enum { offerer, answerer };
pub const DtlsSetup = enum { actpass, active, passive, holdconn };

pub const SdpParams = struct {
    local_ufrag: []const u8,
    local_pwd: []const u8,
    fingerprint: []const u8,
    setup: DtlsSetup,
    sctp_port: u16,
    max_message_size: u64,
    role: SdpRole,
    candidates: []const CandidateLine,
    session_id: u64,
    session_version: u64,
    include_audio: bool = false,
    include_video: bool = false,
    include_datachannel: bool = true,
};

pub const CandidateLine = struct {
    foundation: []const u8,
    component: u8,
    transport: []const u8,
    priority: u32,
    address: []const u8,
    port: u16,
    typ: []const u8,
    related_address: ?[]const u8,
    related_port: ?u16,
};

pub fn build(out: *std.ArrayList(u8), params: SdpParams) ![]const u8 {
    const start = out.items.len;
    var allocating: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer allocating.deinit();
    const w = &allocating.writer;

    try w.writeAll("v=0\r\n");
    try w.print("o=- {d} {d} IN IP4 127.0.0.1\r\n", .{ params.session_id, params.session_version });
    try w.writeAll("s=-\r\n");
    try w.writeAll("t=0 0\r\n");

    var mid: u8 = 0;
    var bundle_count: usize = 0;
    if (params.include_audio) {
        bundle_count += 1;
        mid += 1;
    }
    if (params.include_video) {
        bundle_count += 1;
        mid += 1;
    }
    if (params.include_datachannel) {
        bundle_count += 1;
    }

    if (bundle_count > 0) {
        try w.writeAll("a=group:BUNDLE");
        var m: u8 = 0;
        while (m < bundle_count) : (m += 1) {
            try w.print(" {d}", .{m});
        }
        try w.writeAll("\r\n");
    }

    try w.writeAll("a=extmap-allow-mixed\r\n");
    try w.writeAll("a=msid-semantic: WMS *\r\n");

    mid = 0;
    if (params.include_audio) {
        try writeAudioSection(w, params, mid);
        mid += 1;
    }
    if (params.include_video) {
        try writeVideoSection(w, params, mid);
        mid += 1;
    }
    if (params.include_datachannel) {
        try writeDataChannelSection(w, params, mid);
    }

    try out.appendSlice(std.heap.page_allocator, allocating.written());
    return out.items[start..];
}

fn writeIceAttrs(w: anytype, params: SdpParams) !void {
    try w.print("a=ice-ufrag:{s}\r\n", .{params.local_ufrag});
    try w.print("a=ice-pwd:{s}\r\n", .{params.local_pwd});
    try w.writeAll("a=ice-options:trickle\r\n");
    try w.print("a=fingerprint:sha-256 {s}\r\n", .{params.fingerprint});
    const setup_str: []const u8 = switch (params.setup) {
        .actpass => "actpass",
        .active => "active",
        .passive => "passive",
        .holdconn => "holdconn",
    };
    try w.print("a=setup:{s}\r\n", .{setup_str});
}

fn writeAudioSection(w: anytype, params: SdpParams, mid: u8) !void {
    try w.writeAll("m=audio 9 UDP/TLS/RTP/SAVPF 111 63 9 0 8 13 110 126\r\n");
    try w.writeAll("c=IN IP4 0.0.0.0\r\n");
    try writeIceAttrs(w, params);
    try w.print("a=mid:{d}\r\n", .{mid});
    try w.writeAll("a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level\r\n");
    try w.writeAll("a=extmap:2 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time\r\n");
    try w.writeAll("a=extmap:3 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01\r\n");
    try w.writeAll("a=extmap:4 urn:ietf:params:rtp-hdrext:sdes:mid\r\n");
    try w.writeAll("a=sendrecv\r\n");
    try w.writeAll("a=rtcp-mux\r\n");
    try w.writeAll("a=rtpmap:111 opus/48000/2\r\n");
    try w.writeAll("a=rtcp-fb:111 transport-cc\r\n");
    try w.writeAll("a=fmtp:111 minptime=10;useinbandfec=1\r\n");
    try w.writeAll("a=rtpmap:63 red/48000/2\r\n");
    try w.writeAll("a=fmtp:63 111/111\r\n");
    try w.writeAll("a=rtpmap:9 G722/8000\r\n");
    try w.writeAll("a=rtpmap:0 PCMU/8000\r\n");
    try w.writeAll("a=rtpmap:8 PCMA/8000\r\n");
    try w.writeAll("a=rtpmap:13 CN/8000\r\n");
    try w.writeAll("a=rtpmap:110 telephone-event/48000\r\n");
    try w.writeAll("a=rtpmap:126 telephone-event/8000\r\n");
    for (params.candidates) |cand| try writeCandidateLine(w, cand);
}

fn writeVideoSection(w: anytype, params: SdpParams, mid: u8) !void {
    try w.writeAll("m=video 9 UDP/TLS/RTP/SAVPF 96 97 98 99 100 101 35 36 37 38 103 104 107 108 109 114 115 116 117 118 39 40 41 42 43 44 45 46 47 48 119 120 121 122 49 50 51 52 123 124 125 53\r\n");
    try w.writeAll("c=IN IP4 0.0.0.0\r\n");
    try writeIceAttrs(w, params);
    try w.print("a=mid:{d}\r\n", .{mid});
    try w.writeAll("a=extmap:14 urn:ietf:params:rtp-hdrext:toffset\r\n");
    try w.writeAll("a=extmap:2 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time\r\n");
    try w.writeAll("a=extmap:13 urn:3gpp:video-orientation\r\n");
    try w.writeAll("a=extmap:3 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01\r\n");
    try w.writeAll("a=extmap:5 http://www.webrtc.org/experiments/rtp-hdrext/playout-delay\r\n");
    try w.writeAll("a=extmap:6 http://www.webrtc.org/experiments/rtp-hdrext/video-content-type\r\n");
    try w.writeAll("a=extmap:7 http://www.webrtc.org/experiments/rtp-hdrext/video-timing\r\n");
    try w.writeAll("a=extmap:8 http://www.webrtc.org/experiments/rtp-hdrext/color-space\r\n");
    try w.writeAll("a=extmap:4 urn:ietf:params:rtp-hdrext:sdes:mid\r\n");
    try w.writeAll("a=extmap:10 urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id\r\n");
    try w.writeAll("a=extmap:11 urn:ietf:params:rtp-hdrext:sdes:repaired-rtp-stream-id\r\n");
    try w.writeAll("a=sendrecv\r\n");
    try w.writeAll("a=rtcp-mux\r\n");
    try w.writeAll("a=rtcp-rsize\r\n");
    try w.writeAll("a=rtpmap:96 VP8/90000\r\n");
    try w.writeAll("a=rtcp-fb:96 goog-remb\r\n");
    try w.writeAll("a=rtcp-fb:96 transport-cc\r\n");
    try w.writeAll("a=rtcp-fb:96 ccm fir\r\n");
    try w.writeAll("a=rtcp-fb:96 nack\r\n");
    try w.writeAll("a=rtcp-fb:96 nack pli\r\n");
    try w.writeAll("a=rtpmap:97 rtx/90000\r\n");
    try w.writeAll("a=fmtp:97 apt=96\r\n");
    try w.writeAll("a=rtpmap:98 VP9/90000\r\n");
    try w.writeAll("a=rtcp-fb:98 goog-remb\r\n");
    try w.writeAll("a=rtcp-fb:98 transport-cc\r\n");
    try w.writeAll("a=rtcp-fb:98 ccm fir\r\n");
    try w.writeAll("a=rtcp-fb:98 nack\r\n");
    try w.writeAll("a=rtcp-fb:98 nack pli\r\n");
    try w.writeAll("a=fmtp:98 profile-id=0\r\n");
    try w.writeAll("a=rtpmap:99 rtx/90000\r\n");
    try w.writeAll("a=fmtp:99 apt=98\r\n");
    try w.writeAll("a=rtpmap:100 H264/90000\r\n");
    try w.writeAll("a=rtcp-fb:100 goog-remb\r\n");
    try w.writeAll("a=rtcp-fb:100 transport-cc\r\n");
    try w.writeAll("a=rtcp-fb:100 ccm fir\r\n");
    try w.writeAll("a=rtcp-fb:100 nack\r\n");
    try w.writeAll("a=rtcp-fb:100 nack pli\r\n");
    try w.writeAll("a=fmtp:100 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f\r\n");
    try w.writeAll("a=rtpmap:101 rtx/90000\r\n");
    try w.writeAll("a=fmtp:101 apt=100\r\n");
    for (params.candidates) |cand| try writeCandidateLine(w, cand);
}

fn writeDataChannelSection(w: anytype, params: SdpParams, mid: u8) !void {
    try w.print("m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n", .{});
    try w.writeAll("c=IN IP4 0.0.0.0\r\n");
    try writeIceAttrs(w, params);
    try w.print("a=mid:{d}\r\n", .{mid});
    try w.print("a=sctp-port:{d}\r\n", .{params.sctp_port});
    try w.print("a=max-message-size:{d}\r\n", .{params.max_message_size});
    for (params.candidates) |cand| try writeCandidateLine(w, cand);
}

fn writeCandidateLine(w: anytype, cand: CandidateLine) !void {
    if (cand.related_address) |raddr| {
        try w.print(
            "a=candidate:{s} {d} {s} {d} {s} {d} typ {s} raddr {s} rport {d}\r\n",
            .{ cand.foundation, cand.component, cand.transport, cand.priority, cand.address, cand.port, cand.typ, raddr, cand.related_port orelse 0 },
        );
    } else {
        try w.print(
            "a=candidate:{s} {d} {s} {d} {s} {d} typ {s}\r\n",
            .{ cand.foundation, cand.component, cand.transport, cand.priority, cand.address, cand.port, cand.typ },
        );
    }
}

pub fn formatCandidateLine(buf: []u8, cand: CandidateLine) ![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    try writeCandidateLine(&writer, cand);
    return writer.buffered();
}
