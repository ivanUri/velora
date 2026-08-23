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

//! MPSC command queue: JS thread → WebRTC network thread.

const std = @import("std");
const net = @import("../../support/net.zig");

/// Commands flowing from the JS thread to the WebRTC network thread.
pub const RtcCommand = union(enum) {
    /// Begin ICE gathering after setLocalDescription.
    start_gathering: ?net.Address,
    /// Parse remote SDP and extract ICE/DTLS credentials.
    set_remote_description: struct { sdp_buf: []u8 },
    /// Add a trickle ICE candidate string (a=candidate:... or candidate:...).
    add_ice_candidate: struct { candidate_str: []u8 },
    /// Open a new SCTP data channel.
    create_data_channel: struct {
        js_channel_id: u32,
        label: []u8,
        protocol: []u8,
        ordered: bool,
        max_retransmits: ?u16,
    },
    /// Send SCTP user data on a stream.
    send_data: struct {
        stream_id: u16,
        ppid: u32,
        ordered: bool,
        data: []u8,
    },
    /// Close a single data channel stream.
    close_channel: u16,
    /// Graceful shutdown of the PeerConnection network thread.
    close,
};

pub const Node = struct {
    next: std.atomic.Value(?*Node) = .init(null),
    cmd: RtcCommand,
};

const RtcCommandQueue = @This();

_head: std.atomic.Value(?*Node) = .init(null),

pub fn init() RtcCommandQueue {
    return .{};
}

/// Push a command (JS thread).
pub fn push(self: *RtcCommandQueue, node: *Node) void {
    var old = self._head.load(.monotonic);
    while (true) {
        node.next.store(old, .monotonic);
        if (self._head.cmpxchgWeak(old, node, .release, .monotonic)) |actual| {
            old = actual;
        } else {
            break;
        }
    }
}

/// Pop one command (network thread). Returns nodes in LIFO order.
pub fn pop(self: *RtcCommandQueue) ?*Node {
    var head = self._head.load(.acquire);
    while (head) |node| {
        const next = node.next.load(.monotonic);
        if (self._head.cmpxchgWeak(head, next, .acquire, .monotonic)) |_| {
            head = self._head.load(.acquire);
        } else {
            return node;
        }
    }
    return null;
}

/// Drain all pending commands into `out` (FIFO order).
pub fn drainAll(self: *RtcCommandQueue, out: *std.ArrayList(*Node)) !void {
    var node = self._head.swap(null, .acquire);

    var tmp: [128]*Node = undefined;
    var count: usize = 0;

    while (node) |n| {
        if (count < tmp.len) {
            tmp[count] = n;
            count += 1;
        }
        node = n.next.load(.monotonic);
    }

    var i: usize = count;
    while (i > 0) {
        i -= 1;
        try out.append(tmp[i]);
    }
}

pub fn hasCmds(self: *const RtcCommandQueue) bool {
    return self._head.load(.monotonic) != null;
}
