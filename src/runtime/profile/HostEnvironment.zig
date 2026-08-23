// Host environment probes for antidetect profile coherence.
// When the canonical profile JSON disagrees with the machine Koko runs on,
// Google Knitsail-style checks can flag the mismatch (screen vs window, TZ, CPU).

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const Profile = @import("Profile.zig");
const runtime_io = @import("../../support/io.zig");

pub const Screen = struct {
    width: u32,
    height: u32,
    avail_width: u32,
    avail_height: u32,
    device_pixel_ratio: f64,
};

pub const Window = struct {
    inner_width: u32,
    inner_height: u32,
    outer_width: u32,
    outer_height: u32,
};

pub const Snapshot = struct {
    timezone: ?[]const u8 = null,
    hardware_concurrency: ?u32 = null,
    device_memory: ?f64 = null,
    screen: ?Screen = null,
    window: ?Window = null,
    // CPU brand is intentionally kept separate from graphics identity. A
    // CPU model is not evidence of the WebGL vendor/renderer exposed by the
    // browser and must never be used to synthesize one.
    cpu_brand: ?[]const u8 = null,
};

pub fn detect(allocator: std.mem.Allocator) !Snapshot {
    return switch (builtin.os.tag) {
        .macos => try detectMacos(allocator),
        else => .{},
    };
}

fn detectMacos(allocator: std.mem.Allocator) !Snapshot {
    var snap: Snapshot = .{};

    if (readMacosTimezone(allocator)) |tz| {
        snap.timezone = tz;
    } else |_| {}

    if (sysctlU32("hw.logicalcpu")) |cpus| {
        snap.hardware_concurrency = cpus;
    }
    if (sysctlU64("hw.memsize")) |bytes| {
        snap.device_memory = roundChromeDeviceMemory(bytes);
    }
    if (readMacosScreen()) |screen| {
        snap.screen = screen;
        snap.window = defaultWindowForScreen(screen);
    }
    if (try readSysctlString(allocator, "machdep.cpu.brand_string")) |brand| {
        snap.cpu_brand = brand;
    }

    return snap;
}

fn defaultWindowForScreen(screen: Screen) Window {
    const profile_screen = Profile.ScreenProfile{
        .width = screen.width,
        .height = screen.height,
        .avail_width = screen.avail_width,
        .avail_height = screen.avail_height,
        .device_pixel_ratio = screen.device_pixel_ratio,
        .color_depth = 24,
        .pixel_depth = 24,
        .touch = false,
    };
    const win = Profile.defaultWindowForScreen(profile_screen);
    return .{
        .inner_width = win.inner_width,
        .inner_height = win.inner_height,
        .outer_width = win.outer_width,
        .outer_height = win.outer_height,
    };
}

fn sysctlU32(name: [*:0]const u8) ?u32 {
    var value: c_int = 0;
    var size: usize = @sizeOf(c_int);
    if (c.sysctlbyname(name, &value, &size, null, 0) != 0) return null;
    if (value <= 0) return null;
    return @intCast(value);
}

fn sysctlU64(name: [*:0]const u8) ?u64 {
    var value: u64 = 0;
    var size: usize = @sizeOf(u64);
    if (c.sysctlbyname(name, &value, &size, null, 0) != 0) return null;
    if (value == 0) return null;
    return value;
}

/// Largest power-of-two GiB bucket not exceeding physical RAM (Chrome 149 reports 16 on 16 GiB Macs).
fn roundChromeDeviceMemory(bytes: u64) f64 {
    const gb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0);
    var step: f64 = 0.25;
    var picked: f64 = step;
    while (step <= gb) : (step *= 2) {
        picked = step;
    }
    return picked;
}

fn readSysctlString(allocator: std.mem.Allocator, name: [*:0]const u8) !?[]const u8 {
    var size: usize = 0;
    if (c.sysctlbyname(name, null, &size, null, 0) != 0 or size == 0) return null;

    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    if (c.sysctlbyname(name, buf.ptr, &size, null, 0) != 0) return null;

    const trimmed = std.mem.trimEnd(u8, buf[0..size], "\x00");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn readMacosTimezone(allocator: std.mem.Allocator) !?[]const u8 {
    var buf: [512]u8 = undefined;
    const path_len = std.Io.Dir.readLinkAbsolute(runtime_io.get(), "/etc/localtime", &buf) catch return null;
    const path = buf[0..path_len];

    const prefixes = [_][]const u8{
        "/var/db/timezone/zoneinfo/",
        "/usr/share/zoneinfo/",
    };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, path, prefix)) {
            return try allocator.dupe(u8, path[prefix.len..]);
        }
    }
    return null;
}

const CGRect = extern struct {
    origin: extern struct { x: f64, y: f64 },
    size: extern struct { width: f64, height: f64 },
};

const CoreGraphics = struct {
    pub extern fn CGMainDisplayID() u32;
    pub extern fn CGDisplayPixelsWide(display: u32) usize;
    pub extern fn CGDisplayPixelsHigh(display: u32) usize;
    pub extern fn CGDisplayBounds(display: u32) CGRect;
};

fn readMacosScreen() ?Screen {
    const display = CoreGraphics.CGMainDisplayID();
    if (display == 0) return null;

    const bounds = CoreGraphics.CGDisplayBounds(display);
    const width = bounds.size.width;
    const height = bounds.size.height;
    if (width <= 0 or height <= 0) return null;

    const pixels_wide = CoreGraphics.CGDisplayPixelsWide(display);
    const dpr = if (width > 0)
        @as(f64, @floatFromInt(pixels_wide)) / width
    else
        1.0;

    const w: u32 = @intFromFloat(@round(width));
    const h: u32 = @intFromFloat(@round(height));
    const avail_h = if (h > 25) h - 25 else h;

    return .{
        .width = w,
        .height = h,
        .avail_width = w,
        .avail_height = avail_h,
        .device_pixel_ratio = if (dpr < 1.0) 1.0 else dpr,
    };
}

pub fn applyIdentity(profile: *Profile.IdentityProfile, snap: Snapshot, allocator: std.mem.Allocator) !void {
    if (snap.timezone) |tz| {
        profile.timezone = try allocator.dupe(u8, tz);
    }
    if (snap.hardware_concurrency) |cpus| {
        profile.hardware_concurrency = cpus;
    }
    if (snap.device_memory) |mem| {
        profile.device_memory = mem;
    }
    if (snap.screen) |screen| {
        profile.screen.width = screen.width;
        profile.screen.height = screen.height;
        profile.screen.avail_width = screen.avail_width;
        profile.screen.avail_height = screen.avail_height;
        profile.screen.device_pixel_ratio = screen.device_pixel_ratio;
    }
    if (snap.window) |window| {
        profile.window.inner_width = window.inner_width;
        profile.window.inner_height = window.inner_height;
        profile.window.outer_width = window.outer_width;
        profile.window.outer_height = window.outer_height;
    }
    // Do not derive WebGL identity from `cpu_brand`. A real renderer must
    // come from a graphics capability probe or an explicitly imported
    // profile; otherwise retain the profile's declared value.
}

const testing = @import("../../testing/testing.zig");

test "HostEnvironment: roundChromeDeviceMemory" {
    try testing.expectEqual(@as(f64, 16), roundChromeDeviceMemory(16 * 1024 * 1024 * 1024));
    try testing.expectEqual(@as(f64, 8), roundChromeDeviceMemory(12 * 1024 * 1024 * 1024));
    try testing.expectEqual(@as(f64, 4), roundChromeDeviceMemory(6 * 1024 * 1024 * 1024));
    try testing.expectEqual(@as(f64, 0.5), roundChromeDeviceMemory(600 * 1024 * 1024));
}

test "HostEnvironment: CPU brand does not rewrite WebGL identity" {
    var identity = Profile.defaultIdentity().*;
    const before = identity.webgl.unmasked_renderer;
    const snapshot = Snapshot{ .cpu_brand = "Apple M3" };
    try applyIdentity(&identity, snapshot, std.testing.allocator);
    try std.testing.expectEqualStrings(before, identity.webgl.unmasked_renderer);
}
