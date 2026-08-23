const std = @import("std");

const datetime = @import("datetime.zig");
const runtime_io = @import("io.zig");
const Level = @import("log.zig").Level;
const Scope = @import("log.zig").Scope;

pub const Channel = enum {
    js,
    core,
    network,
    protocol,
    system,

    pub fn tag(self: Channel) []const u8 {
        return @tagName(self);
    }
};

pub const JsSubfile = enum {
    console,
    engine,
    calls,
};

pub const Context = struct {
    nav_id: ?u32 = null,
    frame_id: ?u32 = null,
    url: ?[]const u8 = null,
};

pub const ChannelLevels = struct {
    js: ?Level = null,
    core: ?Level = null,
    network: ?Level = null,
    protocol: ?Level = null,
    system: ?Level = null,

    pub fn get(self: ChannelLevels, channel: Channel) ?Level {
        return switch (channel) {
            .js => self.js,
            .core => self.core,
            .network => self.network,
            .protocol => self.protocol,
            .system => self.system,
        };
    }
};

pub const InitOpts = struct {
    base_dir: []const u8,
    run_id: ?[]const u8 = null,
    no_combined: bool = false,
    cdp_trace: bool = false,
    channel_levels: ChannelLevels = .{},
    version: []const u8 = "unknown",
    mode: []const u8 = "unknown",
    profile: ?[]const u8 = null,
    log_level: []const u8 = "info",
};

pub fn scopeChannel(scope: Scope) Channel {
    return switch (scope) {
        .js => .js,
        .browser, .frame, .dom, .scheduler, .event, .bug => .core,
        .http, .cache, .websocket, .webrtc => .network,
        .cdp, .mcp => .protocol,
        .app, .telemetry, .not_implemented, .unknown_prop, .storage, .console => .system,
    };
}

pub fn jsSubfile(msg: []const u8) JsSubfile {
    if (std.mem.eql(u8, msg, "koko-js-call")) return .calls;
    if (std.mem.startsWith(u8, msg, "console.")) return .console;
    return .engine;
}

pub fn isCdpWireMsg(msg: []const u8) bool {
    return std.mem.startsWith(u8, msg, "cdp-wire");
}

pub fn shouldRedactField(name: []const u8) bool {
    var buf: [64]u8 = undefined;
    const key = std.ascii.lowerString(&buf, name);
    const needles = [_][]const u8{
        "cookie", "authorization", "password", "token", "bearer", "secret", "apikey", "api_key",
    };
    for (needles) |n| {
        if (std.mem.indexOf(u8, key, n) != null) return true;
    }
    return false;
}

const Sink = struct {
    allocator: std.mem.Allocator,
    run_dir: []const u8,
    base_dir: []const u8,
    channel_files: [@typeInfo(Channel).@"enum".fields.len]?std.Io.File = .{null} ** @typeInfo(Channel).@"enum".fields.len,
    js_console: ?std.Io.File = null,
    js_engine: ?std.Io.File = null,
    js_calls: ?std.Io.File = null,
    cdp_wire: ?std.Io.File = null,
    combined: ?std.Io.File = null,
    errors: ?std.Io.File = null,
    mutex: std.Io.Mutex = .init,
    channel_levels: ChannelLevels = .{},
    cdp_trace: bool = false,
    started_at: u64 = 0,
    nav_counter: std.atomic.Value(u32) = .init(0),
    context: Context = .{},

    fn channelIndex(channel: Channel) usize {
        return @intFromEnum(channel);
    }

    pub fn channelLevel(self: *const Sink, channel: Channel) ?Level {
        return self.channel_levels.get(channel);
    }

    pub fn enabledForChannel(self: *const Sink, channel: Channel, level: Level, global: Level) bool {
        if (@intFromEnum(level) < @intFromEnum(global)) return false;
        if (self.channelLevel(channel)) |cl| {
            if (@intFromEnum(level) < @intFromEnum(cl)) return false;
        }
        return true;
    }

    pub fn bumpNavId(self: *Sink) u32 {
        return self.nav_counter.fetchAdd(1, .monotonic) + 1;
    }

    pub fn setContext(self: *Sink, ctx: Context) void {
        const io = runtime_io.get();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.context = ctx;
    }

    pub fn clearContext(self: *Sink) void {
        const io = runtime_io.get();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.context = .{};
    }

    pub fn getContext(self: *const Sink) Context {
        return self.context;
    }

    fn openFile(path: []const u8) !std.Io.File {
        return std.Io.Dir.cwd().createFile(runtime_io.get(), path, .{ .truncate = true });
    }

    pub fn init(allocator: std.mem.Allocator, opts: InitOpts) !*Sink {
        const self = try allocator.create(Sink);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .run_dir = undefined,
            .base_dir = try allocator.dupe(u8, opts.base_dir),
            .channel_levels = opts.channel_levels,
            .cdp_trace = opts.cdp_trace,
            .started_at = datetime.milliTimestamp(.clock),
        };
        errdefer allocator.free(self.base_dir);

        const run_name = if (opts.run_id) |id|
            try allocator.dupe(u8, id)
        else
            try formatRunName(allocator);
        defer if (opts.run_id == null) allocator.free(run_name);

        const run_dir = try std.fs.path.join(allocator, &.{ opts.base_dir, run_name });
        self.run_dir = run_dir;

        const io = runtime_io.get();
        try std.Io.Dir.cwd().createDirPath(io, opts.base_dir);
        try std.Io.Dir.cwd().createDirPath(io, run_dir);

        const subdirs = [_][]const u8{ "js", "core", "network", "protocol", "system" };
        for (subdirs) |sub| {
            const p = try std.fs.path.join(allocator, &.{ run_dir, sub });
            defer allocator.free(p);
            try std.Io.Dir.cwd().createDirPath(io, p);
        }

        {
            const p = try std.fs.path.join(allocator, &.{ run_dir, "js", "console.log" });
            defer allocator.free(p);
            self.js_console = try openFile(p);
        }
        {
            const p = try std.fs.path.join(allocator, &.{ run_dir, "js", "engine.log" });
            defer allocator.free(p);
            self.js_engine = try openFile(p);
        }
        {
            const p = try std.fs.path.join(allocator, &.{ run_dir, "js", "calls.log" });
            defer allocator.free(p);
            self.js_calls = try openFile(p);
        }

        inline for (@typeInfo(Channel).@"enum".fields) |f| {
            const ch: Channel = @enumFromInt(f.value);
            const path = try std.fs.path.join(allocator, &.{ run_dir, ch.tag(), "all.log" });
            defer allocator.free(path);
            self.channel_files[channelIndex(ch)] = try openFile(path);
        }

        if (!opts.no_combined) {
            const path = try std.fs.path.join(allocator, &.{ run_dir, "combined.log" });
            defer allocator.free(path);
            self.combined = try openFile(path);
        }

        {
            const path = try std.fs.path.join(allocator, &.{ run_dir, "errors.log" });
            defer allocator.free(path);
            self.errors = try openFile(path);
        }

        if (opts.cdp_trace) {
            const path = try std.fs.path.join(allocator, &.{ run_dir, "protocol", "cdp-wire.log" });
            defer allocator.free(path);
            self.cdp_wire = try openFile(path);
        }

        try writeMeta(self, opts);
        try updateLatestSymlink(allocator, opts.base_dir, run_dir);

        return self;
    }

    pub fn deinit(self: *Sink) void {
        const io = runtime_io.get();
        self.flushAll() catch {};
        if (self.js_console) |*f| f.close(io);
        if (self.js_engine) |*f| f.close(io);
        if (self.js_calls) |*f| f.close(io);
        if (self.cdp_wire) |*f| f.close(io);
        if (self.combined) |*f| f.close(io);
        if (self.errors) |*f| f.close(io);
        for (&self.channel_files) |*opt| {
            if (opt.*) |*f| f.close(io);
        }
        self.allocator.free(self.base_dir);
        self.allocator.free(self.run_dir);
        self.allocator.destroy(self);
    }

    pub fn routeFormattedLine(self: *Sink, scope: Scope, level: Level, msg: []const u8, line: []const u8) !void {
        const io = runtime_io.get();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const channel = scopeChannel(scope);

        if (channel == .js) {
            const sub = jsSubfile(msg);
            const f: *?std.Io.File = switch (sub) {
                .console => &self.js_console,
                .engine => &self.js_engine,
                .calls => &self.js_calls,
            };
            if (f.*) |*file| try writeLineFlush(file, line);
        } else if (channel == .protocol and isCdpWireMsg(msg)) {
            if (self.cdp_wire) |*file| try writeLineFlush(file, line);
            if (self.channel_files[channelIndex(channel)]) |*file| try writeLineFlush(file, line);
        } else if (self.channel_files[channelIndex(channel)]) |*file| {
            try writeLineFlush(file, line);
        }

        if (self.combined) |*file| try writeLineFlush(file, line);
        if (@intFromEnum(level) >= @intFromEnum(Level.warn)) {
            if (self.errors) |*file| try writeLineFlush(file, line);
        }
    }

    fn writeLineFlush(file: *std.Io.File, line: []const u8) !void {
        try file.writeStreamingAll(runtime_io.get(), line);
        // Avoid fsync per line — CDP/navigation threads share the sink mutex and
        // heavy sites (GitHub, eBay) can emit thousands of lines/sec, starving
        // inbound CDP command processing when every write syncs to disk.
    }

    fn flushAll(self: *Sink) !void {
        const io = runtime_io.get();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        inline for (&self.channel_files) |*opt| {
            if (opt.*) |*f| f.sync(io) catch {};
        }
        if (self.js_console) |*f| f.sync(io) catch {};
        if (self.js_engine) |*f| f.sync(io) catch {};
        if (self.js_calls) |*f| f.sync(io) catch {};
        if (self.cdp_wire) |*f| f.sync(io) catch {};
        if (self.combined) |*f| f.sync(io) catch {};
        if (self.errors) |*f| f.sync(io) catch {};
    }

    pub fn writeCdpWire(self: *Sink, direction: []const u8, payload: []const u8) void {
        if (!self.cdp_trace) return;
        var f = self.cdp_wire orelse return;
        const io = runtime_io.get();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var buf: [8704]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buf,
            "$time={d} $channel=protocol $scope=cdp $level=debug $msg=cdp-wire direction={s} payload={s}\n",
            .{ datetime.milliTimestamp(.clock), direction, truncatePayload(payload) },
        ) catch return;
        writeLineFlush(&f, line) catch {};
    }

    fn truncatePayload(payload: []const u8) []const u8 {
        const max = 2048;
        if (payload.len <= max) return payload;
        return payload[0..max];
    }

    fn writeMeta(self: *Sink, opts: InitOpts) !void {
        const path = try std.fs.path.join(self.allocator, &.{ self.run_dir, "meta.json" });
        defer self.allocator.free(path);
        const io = runtime_io.get();
        var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer file.close(io);

        var buf: [4096]u8 = undefined;
        var w = file.writer(io, &buf);
        const iw = &w.interface;
        try iw.writeAll("{\n");
        try iw.print("  \"version\": \"{s}\",\n", .{opts.version});
        try iw.print("  \"pid\": {d},\n", .{std.c.getpid()});
        try iw.print("  \"mode\": \"{s}\",\n", .{opts.mode});
        try iw.print("  \"log_level\": \"{s}\",\n", .{opts.log_level});
        try iw.print("  \"started_at\": {d},\n", .{self.started_at});
        if (opts.profile) |p| {
            try iw.print("  \"browser_profile\": \"{s}\",\n", .{p});
        } else {
            try iw.writeAll("  \"browser_profile\": null,\n");
        }
        try iw.print("  \"run_dir\": \"{s}\"\n", .{self.run_dir});
        try iw.writeAll("}\n");
        try iw.flush();
    }

    fn formatRunName(allocator: std.mem.Allocator) ![]const u8 {
        const ts = datetime.milliTimestamp(.clock);
        return std.fmt.allocPrint(allocator, "{d}-{d}", .{ ts, std.c.getpid() });
    }

    fn updateLatestSymlink(allocator: std.mem.Allocator, base_dir: []const u8, run_dir: []const u8) !void {
        const latest = try std.fs.path.join(allocator, &.{ base_dir, "latest" });
        defer allocator.free(latest);
        const io = runtime_io.get();
        std.Io.Dir.cwd().deleteFile(io, latest) catch {};
        const rel = std.fs.path.basename(run_dir);
        std.Io.Dir.cwd().symLink(io, rel, latest, .{}) catch {};
    }
};

pub var active: ?*Sink = null;
var active_ready: std.atomic.Value(bool) = .init(false);

pub fn init(allocator: std.mem.Allocator, opts: InitOpts) !void {
    if (active_ready.load(.acquire)) return error.SinkAlreadyInit;
    const sink_ptr = try Sink.init(allocator, opts);
    active = sink_ptr;
    active_ready.store(true, .release);
}

pub fn deinit() void {
    if (!active_ready.load(.acquire)) return;
    if (active) |s| {
        s.deinit();
        active = null;
    }
    active_ready.store(false, .release);
}

pub fn isActive() bool {
    return active_ready.load(.acquire);
}

fn getSink() ?*Sink {
    if (!active_ready.load(.acquire)) return null;
    return active;
}

pub fn runDir() ?[]const u8 {
    if (getSink()) |s| return s.run_dir;
    return null;
}

pub fn bumpNavId() ?u32 {
    if (getSink()) |s| return s.bumpNavId();
    return null;
}

pub fn setContext(ctx: Context) void {
    if (getSink()) |s| s.setContext(ctx);
}

pub fn clearContext() void {
    if (getSink()) |s| s.clearContext();
}

pub fn getContext() Context {
    if (getSink()) |s| return s.getContext();
    return .{};
}

pub fn writeCdpWire(direction: []const u8, payload: []const u8) void {
    if (getSink()) |s| s.writeCdpWire(direction, payload);
}

pub fn channelEnabled(scope: Scope, level: Level, global: Level) bool {
    if (getSink()) |s| {
        const ch = scopeChannel(scope);
        return s.enabledForChannel(ch, level, global);
    }
    return @intFromEnum(level) >= @intFromEnum(global);
}

pub fn routeFormattedLine(scope: Scope, level: Level, msg: []const u8, line: []const u8) void {
    if (getSink()) |s| s.routeFormattedLine(scope, level, msg, line) catch {};
}
