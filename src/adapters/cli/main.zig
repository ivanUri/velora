const v = @import("koko");

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
const Allocator = std.mem.Allocator;

const log = v.log;
const App = v.App;
const Config = v.Config;
const SigHandler = @import("Sighandler.zig");
pub const panic = v.crash_handler.panic;

pub fn main(init: std.process.Init) !void {
    v.io.set(init.io);
    v.io.setEnviron(init.environ_map);

    // Raise soft stack limit toward hard (macOS default soft ~8MB). V8 module
    // graphs (InnerModuleEvaluation) and SPA script eval need headroom beyond
    // the default or they V8_Fatal before DOMContentLoaded.
    if (std.posix.getrlimit(.STACK)) |lim| {
        var raised = lim;
        if (raised.cur < raised.max) {
            raised.cur = raised.max;
            _ = std.posix.setrlimit(.STACK, raised) catch {};
        }
    } else |_| {}

    // allocator
    // - in Debug mode we use the General Purpose Allocator to detect memory leaks
    // - in Release mode we use the c allocator
    var gpa_instance: std.heap.DebugAllocator(.{ .stack_trace_frames = 10 }) = .init;
    const gpa = if (builtin.mode == .Debug) gpa_instance.allocator() else std.heap.c_allocator;

    defer if (builtin.mode == .Debug) {
        if (gpa_instance.detectLeaks()) std.posix.exit(1);
    };

    // arena for main-specific allocations
    var main_arena_instance = std.heap.ArenaAllocator.init(gpa);
    const main_arena = main_arena_instance.allocator();
    defer main_arena_instance.deinit();

    run(gpa, main_arena, init.minimal.args) catch |err| {
        log.fatal(.app, "exit", .{ .err = err });
        std.c.exit(1);
    };
}

fn run(allocator: Allocator, main_arena: Allocator, process_args: std.process.Args) !void {
    // Config must live on the heap: fetch/curl worker threads read app.config
    // while the main thread is in network.run(). Stack-allocated Config caused
    // torn reads of profile.policies (segfault in PolicyRegistry.policyEnabled).
    const config = try allocator.create(Config);
    var config_owned_by_error_path = true;
    try Config.parseArgsInPlace(config, main_arena, allocator, process_args);
    errdefer if (config_owned_by_error_path) {
        config.deinit(allocator);
        allocator.destroy(config);
    };

    switch (config.mode) {
        .profile => |opts| {
            v.profile_cmd.run(main_arena, .{
                .action = opts.action,
                .name = opts.name,
                .fingerprint = opts.fingerprint,
                .from = opts.from,
                .to = opts.to,
                .user_data_dir = opts.user_data_dir,
            }) catch |err| {
                log.fatal(.app, "profile command failed", .{ .err = err });
            };
            config.deinit(allocator);
            allocator.destroy(config);
            return std.process.cleanExit(v.io.get());
        },
        .help => {
            config.printUsageAndExit(true);
            config.deinit(allocator);
            allocator.destroy(config);
            return std.process.cleanExit(v.io.get());
        },
        .version => {
            var stdout = std.Io.File.stdout().writerStreaming(v.io.get(), &.{});
            try stdout.interface.print("{s}\n", .{v.build_config.version});
            config.deinit(allocator);
            allocator.destroy(config);
            return std.process.cleanExit(v.io.get());
        },
        else => {},
    }

    if (config.logLevel()) |ll| {
        log.opts.level = ll;
    }
    if (config.logFormat()) |lf| {
        log.opts.format = lf;
    }

    // Set log filter scopes.
    log.opts.filter_scopes = config.logFilterScopes().items;

    defer log.deinitSink();

    if (config.logDir()) |base_dir| {
        const level_name = if (config.logLevel()) |ll| @tagName(ll) else @tagName(log.opts.level);
        try log.initSink(allocator, .{
            .base_dir = base_dir,
            .run_id = config.logRunId(),
            .no_combined = config.logNoCombined(),
            .cdp_trace = config.logCdpTrace(),
            .channel_levels = config.logChannelLevels(),
            .version = v.build_config.version,
            .mode = config.runModeName(),
            .profile = config.browserProfile(),
            .log_level = level_name,
        });
        if (log.logRunDir()) |run_dir| {
            log.info(.app, "log dir ready", .{ .path = run_dir, .cdp_trace = log.cdp_trace_enabled });
        }
    }

    // must be installed before any other threads
    const sighandler = try main_arena.create(SigHandler);
    sighandler.* = .{ .arena = main_arena };
    try sighandler.install();

    // _app is global to handle graceful shutdown.
    var app = try App.init(allocator, config);
    defer app.deinit();
    defer allocator.destroy(config);
    defer config.deinit(allocator);
    // From this point the ordinary defers own Config. The outer errdefer is
    // still active for errors from this function, so explicitly transfer
    // ownership to prevent error unwinding from freeing Config twice.
    config_owned_by_error_path = false;

    try sighandler.on(v.Network.stop, .{&app.network});

    app.telemetry.record(.{ .run = {} });

    switch (config.mode) {
        .serve => |opts| {
            log.debug(.app, "startup", .{ .mode = "serve", .snapshot = app.snapshot.fromEmbedded() });
            const address = v.net.Address.parseIp(opts.host, opts.port) catch |err| {
                log.fatal(.app, "invalid server address", .{ .err = err, .host = opts.host, .port = opts.port });
                return config.printUsageAndExit(false);
            };

            var server = v.Server.init(app, address) catch |err| {
                if (err == error.AddressInUse) {
                    log.fatal(.app, "address already in use", .{
                        .host = opts.host,
                        .port = opts.port,
                        .hint = "Another process is already listening on this address. " ++
                            "Stop the other process or use --port to choose a different port.",
                    });
                } else {
                    log.fatal(.app, "server run error", .{ .err = err });
                }
                return err;
            };
            defer server.deinit();

            try sighandler.on(v.Server.shutdown, .{server});

            app.network.run();
        },
        .fetch => |opts| {
            const url = opts.url;
            log.debug(.app, "startup", .{ .mode = "fetch", .dump_mode = opts.dump, .url = url, .snapshot = app.snapshot.fromEmbedded() });

            var fetch_opts = v.FetchOpts{
                .wait_ms = opts.wait_ms,
                .wait_until = opts.wait_until orelse .done,
                .observe_ms = opts.observe_ms,
                .expand_lazy = opts.expand_lazy,
                .max_scrolls = opts.max_scrolls,
                .scroll_settle_ms = opts.scroll_settle_ms,
                .wait_script = opts.wait_script,
                .wait_selector = opts.wait_selector,
                .click_selector = opts.click_selector,
                .click_offset_x = opts.click_offset_x,
                .click_offset_y = opts.click_offset_y,
                .dump_mode = opts.dump,
                .dump = .{
                    .strip = opts.strip_mode,
                    .with_base = opts.with_base,
                    .with_frames = opts.with_frames,
                },
                .dump_html_file = opts.dump_html_file,
            };

            const stdout = std.Io.File.stdout();
            var writer = stdout.writerStreaming(v.io.get(), &.{});
            if (opts.dump != null) {
                fetch_opts.writer = &writer.interface;
            }

            // Browser owns a V8 isolate, which has thread affinity — it must
            // be init/used/deinit on the same thread (fetchThread, below). So
            // we can't treat Browser like the above serve path treats Server.
            // We need Browser to be createdin fetchThread and to get a reference
            // to it here.
            var ft: FetchTerminator = .{};
            try sighandler.on(FetchTerminator.terminate, .{&ft});
            if (opts.terminate_ms) |ms| {
                try sighandler.deadline(ms);
            }

            var worker_thread = try std.Thread.spawn(.{}, fetchThread, .{ app, &ft, url.?, fetch_opts });
            defer worker_thread.join();

            app.network.run();
        },
        .mcp => |opts| {
            log.info(.mcp, "starting server", .{});

            log.opts.format = .logfmt;

            if (opts.port != null and opts.cdp_port != null) {
                log.fatal(.mcp, "MCP HTTP and CDP cannot share the process listener", .{
                    .hint = "Run CDP and MCP HTTP as separate Koko processes.",
                });
                return error.TooManyListeners;
            }

            var cdp_server: ?*v.Server = null;
            if (opts.cdp_port) |port| {
                const address = v.net.Address.parseIp("127.0.0.1", port) catch |err| {
                    log.fatal(.mcp, "invalid cdp address", .{ .err = err, .port = port });
                    return;
                };
                cdp_server = try v.Server.init(app, address);
                try sighandler.on(v.Server.shutdown, .{cdp_server.?});
            }
            defer if (cdp_server) |s| s.deinit();

            if (opts.port) |port| {
                const address = v.net.Address.parseIp(opts.host, port) catch |err| {
                    log.fatal(.mcp, "invalid MCP HTTP address", .{
                        .err = err,
                        .host = opts.host,
                        .port = port,
                    });
                    return;
                };
                const http_server = try v.mcp.HttpServer.init(
                    allocator,
                    app,
                    address,
                    opts.max_sessions,
                );
                defer http_server.deinit();
                app.network.run();
            } else {
                var worker_thread = try std.Thread.spawn(.{}, mcpThread, .{ allocator, app });
                defer worker_thread.join();
                app.network.run();
            }
        },
        else => unreachable,
    }
}

const FetchTerminator = struct {
    mutex: v.sync.Mutex = .{},
    browser: ?*v.Browser = null,
    requested: bool = false,

    fn storeBrowser(self: *FetchTerminator, browser: *v.Browser) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.browser = browser;
        // Preserve a deadline that races browser initialization. Listener
        // registration happens before the worker is spawned, so cancellation
        // must be durable even while there is no isolate to interrupt yet.
        if (self.requested) browser.requestHostTermination();
    }

    fn releaseBrowser(self: *FetchTerminator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const b = self.browser orelse return;
        b.clearHostTermination();
        self.browser = null;
    }

    fn terminate(self: *FetchTerminator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.requested = true;
        const b = self.browser orelse return;
        b.requestHostTermination();
    }
};

fn fetchThread(app: *App, ft: *FetchTerminator, url: [:0]const u8, fetch_opts: v.FetchOpts) void {
    defer app.network.stop();

    var browser: v.Browser = undefined;
    browser.init(app, .{}, null) catch |err| {
        log.fatal(.app, "browser init error", .{ .err = err });
        return;
    };
    defer browser.deinit();

    const notification = v.Notification.init(app.allocator) catch |err| {
        log.fatal(.app, "notification init error", .{ .err = err });
        return;
    };
    defer notification.deinit();

    const session = browser.newSession(notification) catch |err| {
        log.fatal(.app, "session init error", .{ .err = err });
        return;
    };
    v.profile_session.bootstrapCookies(session, app.config);

    ft.storeBrowser(&browser);
    // if this exits normally, we want to disarm the FetchTerminator so that
    // any subsequent sighandlers don't try to shutdown an already (or in-the-
    // process-of) shutting down browser/env
    defer ft.releaseBrowser();

    v.fetch(app, &browser, url, fetch_opts) catch |err| {
        log.fatal(.app, "fetch error", .{ .err = err, .url = url });
    };

    v.profile_session.persistCookies(session, app.config);
}

fn mcpThread(allocator: std.mem.Allocator, app: *App) void {
    defer app.network.stop();

    var stdout = std.Io.File.stdout().writerStreaming(v.io.get(), &.{});
    var mcp_server: *v.mcp.Server = v.mcp.Server.init(allocator, app, &stdout.interface) catch |err| {
        log.fatal(.mcp, "mcp init error", .{ .err = err });
        return;
    };
    defer mcp_server.deinit();

    var stdin_buf: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(v.io.get(), &stdin_buf);
    v.mcp.router.processRequests(mcp_server, &stdin.interface) catch |err| {
        log.fatal(.mcp, "mcp error", .{ .err = err });
    };
}
