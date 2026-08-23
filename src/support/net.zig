const std = @import("std");
const posix = std.posix;

/// Sockaddr-compatible address retained for subsystems that use direct POSIX
/// sockets. Zig 0.16 moved its high-level networking API to std.Io.net, while
/// WebRTC and curl interop still need the native sockaddr representation.
pub const Address = extern union {
    any: posix.sockaddr,
    in: posix.sockaddr.in,
    in6: posix.sockaddr.in6,

    pub fn initIp4(bytes: [4]u8, port: u16) Address {
        return .{ .in = .{
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast(bytes),
        } };
    }

    pub fn initIp6(bytes: [16]u8, port: u16, flowinfo: u32, scope_id: u32) Address {
        return .{ .in6 = .{
            .port = std.mem.nativeToBig(u16, port),
            .flowinfo = flowinfo,
            .addr = bytes,
            .scope_id = scope_id,
        } };
    }

    pub fn initPosix(address: *const posix.sockaddr) Address {
        return switch (address.family) {
            posix.AF.INET => .{ .in = @as(*const posix.sockaddr.in, @ptrCast(@alignCast(address))).* },
            posix.AF.INET6 => .{ .in6 = @as(*const posix.sockaddr.in6, @ptrCast(@alignCast(address))).* },
            else => .{ .any = address.* },
        };
    }

    pub fn parseIp(text: []const u8, port: u16) !Address {
        if (std.Io.net.IpAddress.parse(text, port)) |address| {
            return switch (address) {
                .ip4 => |ip4| initIp4(ip4.bytes, ip4.port),
                .ip6 => |ip6| initIp6(ip6.bytes, ip6.port, ip6.flow, ip6.interface.index),
            };
        } else |err| return err;
    }

    pub fn parseIp6(text: []const u8, port: u16) !Address {
        const ip6 = try std.Io.net.Ip6Address.parse(text, port);
        return initIp6(ip6.bytes, ip6.port, ip6.flow, ip6.interface.index);
    }

    pub fn getPort(self: Address) u16 {
        return switch (self.any.family) {
            posix.AF.INET => std.mem.bigToNative(u16, self.in.port),
            posix.AF.INET6 => std.mem.bigToNative(u16, self.in6.port),
            else => 0,
        };
    }

    pub fn getOsSockLen(self: Address) posix.socklen_t {
        return switch (self.any.family) {
            posix.AF.INET => @sizeOf(posix.sockaddr.in),
            posix.AF.INET6 => @sizeOf(posix.sockaddr.in6),
            else => @sizeOf(posix.sockaddr),
        };
    }

    pub fn format(self: Address, writer: *std.Io.Writer) !void {
        switch (self.any.family) {
            posix.AF.INET => {
                const bytes: [4]u8 = @bitCast(self.in.addr);
                try writer.print("{d}.{d}.{d}.{d}:{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3], self.getPort() });
            },
            posix.AF.INET6 => try writer.print("[{f}]:{d}", .{
                std.Io.net.Ip6Address{ .bytes = self.in6.addr, .port = 0 },
                self.getPort(),
            }),
            else => try writer.writeAll("unknown"),
        }
    }
};
