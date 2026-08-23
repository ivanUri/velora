const std = @import("std");

var process_io: std.Io = std.Io.Threaded.global_single_threaded.io();
var process_environ: ?*std.process.Environ.Map = null;

pub fn set(io: std.Io) void {
    process_io = io;
}

pub fn get() std.Io {
    return process_io;
}

pub fn setEnviron(environ_map: *std.process.Environ.Map) void {
    process_environ = environ_map;
}

pub fn environ() ?*const std.process.Environ.Map {
    return process_environ;
}

pub fn getenv(name: []const u8) ?[]const u8 {
    const environ_map = process_environ orelse return null;
    return environ_map.get(name);
}
