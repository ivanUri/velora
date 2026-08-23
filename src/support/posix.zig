//! Compatibility layer for low-level POSIX calls removed from std.posix in Zig 0.16.
//! Keep raw descriptor networking here while higher-level code migrates to std.Io.
const std = @import("std");
const c = std.c;

pub const AF = std.posix.AF;
pub const F = std.posix.F;
pub const IPPROTO = std.posix.IPPROTO;
pub const O = std.posix.O;
pub const POLL = std.posix.POLL;
pub const SO = std.posix.SO;
pub const SOCK = std.posix.SOCK;
pub const SOL = std.posix.SOL;
pub const TCP = std.posix.TCP;
pub const W = std.posix.W;
pub const fd_t = std.posix.fd_t;
pub const pollfd = std.posix.pollfd;
pub const sockaddr = std.posix.sockaddr;
pub const socklen_t = std.posix.socklen_t;
pub const socket_t = std.posix.socket_t;
pub const timeval = std.posix.timeval;

pub const poll = std.posix.poll;
pub const setsockopt = std.posix.setsockopt;
pub const getpeername = std.posix.getpeername;
pub const errno = c.errno;

const Error = error{
    WouldBlock,
    ConnectionAborted,
    ConnectionRefused,
    NetworkUnreachable,
    AddressInUse,
    PermissionDenied,
    SocketNotListening,
    Unexpected,
};

fn result(rc: anytype) Error!usize {
    return switch (c.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .AGAIN => error.WouldBlock,
        .CONNABORTED => error.ConnectionAborted,
        .CONNREFUSED => error.ConnectionRefused,
        .NETUNREACH => error.NetworkUnreachable,
        .ADDRINUSE => error.AddressInUse,
        .ACCES, .PERM => error.PermissionDenied,
        .INVAL => error.SocketNotListening,
        else => error.Unexpected,
    };
}

pub fn close(fd: fd_t) void {
    _ = c.close(fd);
}

pub fn waitpid(pid: std.c.pid_t, flags: u32) struct { pid: std.c.pid_t, status: u32 } {
    var status: c_int = 0;
    const waited = c.waitpid(pid, &status, @intCast(flags));
    return .{ .pid = waited, .status = @bitCast(status) };
}

pub fn fcntl(fd: fd_t, command: c_int, arg: usize) Error!usize {
    return try result(c.fcntl(fd, command, arg));
}

pub fn read(fd: fd_t, buffer: []u8) Error!usize {
    return result(c.read(fd, buffer.ptr, buffer.len));
}

pub fn write(fd: fd_t, buffer: []const u8) Error!usize {
    return result(c.write(fd, buffer.ptr, buffer.len));
}

pub fn socket(domain: u32, socket_type: u32, protocol: u32) Error!socket_t {
    const emulated: u32 = SOCK.NONBLOCK | SOCK.CLOEXEC;
    const fd: socket_t = @intCast(try result(c.socket(domain, socket_type & ~emulated, protocol)));
    errdefer close(fd);
    if (socket_type & SOCK.NONBLOCK != 0) {
        const current = try fcntl(fd, F.GETFL, 0);
        _ = try fcntl(fd, F.SETFL, current | @as(u32, @bitCast(O{ .NONBLOCK = true })));
    }
    if (socket_type & SOCK.CLOEXEC != 0) _ = try fcntl(fd, F.SETFD, std.posix.FD_CLOEXEC);
    return fd;
}

pub fn bind(fd: socket_t, address: *const sockaddr, address_len: socklen_t) Error!void {
    _ = try result(c.bind(fd, address, address_len));
}

pub fn connect(fd: socket_t, address: *const sockaddr, address_len: socklen_t) Error!void {
    _ = try result(c.connect(fd, address, address_len));
}

pub fn listen(fd: socket_t, backlog: u31) Error!void {
    _ = try result(c.listen(fd, backlog));
}

pub fn getsockname(fd: socket_t, address: *sockaddr, address_len: *socklen_t) Error!void {
    _ = try result(c.getsockname(fd, address, address_len));
}

pub fn sendto(fd: socket_t, buffer: []const u8, flags: u32, address: *const sockaddr, address_len: socklen_t) Error!usize {
    return result(c.sendto(fd, buffer.ptr, buffer.len, flags, address, address_len));
}

pub fn recvfrom(fd: socket_t, buffer: []u8, flags: u32, address: ?*sockaddr, address_len: ?*socklen_t) Error!usize {
    return result(c.recvfrom(fd, buffer.ptr, buffer.len, flags, address, address_len));
}

pub fn accept(fd: socket_t, address: ?*sockaddr, address_len: ?*socklen_t, flags: u32) Error!socket_t {
    const accepted: socket_t = @intCast(try result(c.accept(fd, address, address_len)));
    if (flags & SOCK.NONBLOCK != 0) {
        const current = try fcntl(accepted, F.GETFL, 0);
        _ = try fcntl(accepted, F.SETFL, current | @as(u32, @bitCast(O{ .NONBLOCK = true })));
    }
    return accepted;
}

pub fn shutdown(fd: socket_t, how: std.Io.net.ShutdownHow) Error!void {
    const native_how: c_int = switch (how) {
        .recv => 0,
        .send => 1,
        .both => 2,
    };
    _ = try result(c.shutdown(fd, native_how));
}

pub fn pipe2(options: O) Error![2]fd_t {
    var fds: [2]fd_t = undefined;
    _ = try result(c.pipe(&fds));
    errdefer {
        close(fds[0]);
        close(fds[1]);
    }
    if (options.NONBLOCK) {
        for (fds) |fd| {
            const current = try fcntl(fd, F.GETFL, 0);
            _ = try fcntl(fd, F.SETFL, current | @as(u32, @bitCast(O{ .NONBLOCK = true })));
        }
    }
    if (options.CLOEXEC) {
        for (fds) |fd| _ = try fcntl(fd, F.SETFD, std.posix.FD_CLOEXEC);
    }
    return fds;
}
