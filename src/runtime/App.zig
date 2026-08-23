//
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

const std = @import("std");
const builtin = @import("builtin");
const runtime_io = @import("../support/io.zig");

const Config = @import("Config.zig");
const Snapshot = @import("../core/js/Snapshot.zig");
const Platform = @import("../core/js/Platform.zig");
const Telemetry = @import("telemetry/telemetry.zig").Telemetry;

const Storage = @import("storage/Storage.zig");
const Network = @import("network/Network.zig");
pub const ScaleMetrics = @import("ScaleMetrics.zig");
pub const ArenaPool = @import("ArenaPool.zig");

const log = @import("../support/log.zig");
const Allocator = std.mem.Allocator;

const App = @This();

network: Network,
config: *const Config,
storage: Storage,
platform: Platform,
snapshot: Snapshot,
telemetry: Telemetry,
allocator: Allocator,
arena_pool: ArenaPool,
metrics: ScaleMetrics,
app_dir_path: ?[]const u8,

pub fn init(allocator: Allocator, config: *const Config) !*App {
    const platform = try Platform.init();
    errdefer platform.deinit();

    const snapshot = try Snapshot.load();
    errdefer snapshot.deinit();

    var storage = try Storage.init(allocator, config);
    errdefer storage.deinit(allocator);

    const app = try allocator.create(App);
    errdefer allocator.destroy(app);

    app.* = .{
        .config = config,
        .allocator = allocator,
        .platform = platform,
        .snapshot = snapshot,
        .storage = storage,
        .network = undefined,
        .app_dir_path = undefined,
        .telemetry = undefined,
        .arena_pool = undefined,
        .metrics = .{},
    };
    app.network = try Network.init(allocator, app, config);
    app.network.metrics = &app.metrics;
    errdefer app.network.deinit();

    app.app_dir_path = getAndMakeAppDir(allocator);

    app.telemetry = try Telemetry.init(app, config.mode);
    errdefer app.telemetry.deinit(allocator);

    app.arena_pool = ArenaPool.init(allocator, .{});
    app.arena_pool.metrics = &app.metrics;
    errdefer app.arena_pool.deinit();

    return app;
}

pub fn shutdown(self: *const App) bool {
    return self.network.shutdown.load(.acquire);
}

/// Returns an immutable snapshot for diagnostics and benchmark adapters. The
/// counters are intentionally process-local and never participate in runtime
/// decisions, so reading them cannot change scheduling behavior.
pub fn scaleMetrics(self: *const App) ScaleMetrics.Snapshot {
    return self.metrics.snapshot();
}

pub fn deinit(self: *App) void {
    const allocator = self.allocator;
    if (self.app_dir_path) |app_dir_path| {
        allocator.free(app_dir_path);
        self.app_dir_path = null;
    }
    self.telemetry.deinit(allocator);
    self.network.deinit();
    self.snapshot.deinit();
    self.platform.deinit();
    self.arena_pool.deinit();
    self.storage.deinit(allocator);

    allocator.destroy(self);
}

fn getAndMakeAppDir(allocator: Allocator) ?[]const u8 {
    if (@import("builtin").is_test) {
        return allocator.dupe(u8, "/tmp") catch unreachable;
    }
    const base = switch (builtin.os.tag) {
        .macos => runtime_io.getenv("HOME"),
        .windows => runtime_io.getenv("LOCALAPPDATA"),
        else => runtime_io.getenv("XDG_DATA_HOME") orelse runtime_io.getenv("HOME"),
    } orelse return null;
    const suffix = switch (builtin.os.tag) {
        .macos => "Library/Application Support/koko",
        .windows => "koko",
        else => if (runtime_io.getenv("XDG_DATA_HOME") != null) "koko" else ".local/share/koko",
    };
    const app_dir_path = std.fs.path.join(allocator, &.{ base, suffix }) catch |err| {
        log.warn(.app, "get data dir", .{ .err = err });
        return null;
    };

    std.Io.Dir.cwd().createDirPath(runtime_io.get(), app_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => return app_dir_path,
        else => {
            allocator.free(app_dir_path);
            log.warn(.app, "create data dir", .{ .err = err, .path = app_dir_path });
            return null;
        },
    };
    return app_dir_path;
}
