const std = @import("std");
pub const Runtime = @import("public/Runtime.zig").Runtime;
pub const Browser = @import("core/browser/Browser.zig");
pub const Session = @import("core/browser/Session.zig");
pub const Frame = @import("core/browser/Frame.zig");
pub const Config = @import("runtime/Config.zig");
pub const RealmLifecycleKernel = @import("runtime/RealmLifecycleKernel.zig");
pub const App = @import("runtime/App.zig");
pub const Network = @import("runtime/network/Network.zig");
pub const Notification = @import("runtime/Notification.zig");
pub const cookies = @import("runtime/cookies.zig");
pub const profile_session = @import("runtime/profile_session.zig");
pub const profile_cmd = @import("runtime/profile_cmd.zig");
pub const Server = @import("adapters/server/Server.zig");
pub const io = @import("support/io.zig");
pub const sync = @import("support/sync.zig");
pub const net = @import("support/net.zig");
pub const timer = @import("support/timer.zig");
pub const log = @import("support/log.zig");
pub const crash_handler = @import("support/crash_handler.zig");
pub const String = @import("support/string.zig").String;
pub const js = @import("core/js/js.zig");
pub const dump = @import("core/browser/dump.zig");
pub const markdown = @import("core/browser/markdown.zig");
pub const links = @import("core/browser/links.zig");
pub const actions = @import("core/browser/actions.zig");
pub const forms = @import("core/browser/forms.zig");
pub const interactive = @import("core/browser/interactive.zig");
pub const structured_data = @import("core/browser/structured_data.zig");
pub const SemanticTree = @import("core/semantic/SemanticTree.zig");
pub const Extractor = @import("core/semantic/Extractor.zig");
pub const CDP = @import("protocols/cdp/CDP.zig");
pub const MCP = @import("protocols/mcp.zig");
pub const mcp = @import("protocols/mcp.zig");
pub const ToolRegistry = @import("protocols/automation/ToolRegistry.zig");
pub const ActionJournal = @import("protocols/automation/ActionJournal.zig");
pub const WorkflowRunner = @import("protocols/automation/WorkflowRunner.zig");
pub const URL = @import("core/browser/URL.zig");
pub const build_config = @import("build_config");

test "storage modules" {
    _ = @import("runtime/storage/sqlite/Sqlite.zig");
    _ = @import("runtime/storage/sqlite/Store.zig");
}

pub const FetchOpts = struct {
    wait_ms: u32 = 0,
    wait_until: Config.WaitUntil = .done,
    /// Keep pumping the page after the requested lifecycle milestone so
    /// Observatory can show a live document while background work continues.
    observe_ms: u32 = 0,
    expand_lazy: bool = false,
    max_scrolls: u32 = 80,
    scroll_settle_ms: u32 = 250,
    wait_script: ?[:0]const u8 = null,
    wait_selector: ?[:0]const u8 = null,
    click_selector: ?[:0]const u8 = null,
    click_offset_x: u16 = 28,
    click_offset_y: ?u16 = null,
    dump_mode: ?Config.DumpFormat = null,
    dump: dump.Opts = .{},
    writer: ?*std.Io.Writer = null,
    dump_html_file: ?[]const u8 = null,
};

const ProgressSnapshot = struct {
    path: []const u8,
    dump: dump.Opts,
};

/// Serialize the current DOM to the export sidecar while Runner is still
/// waiting. The bridge treats this file as a best-effort live preview and the
/// final fetch dump rewrites it with the authoritative snapshot.
fn writeProgressSnapshot(context: *anyopaque, frame: *Frame) void {
    const progress: *ProgressSnapshot = @ptrCast(@alignCast(context));
    const process_io = io.get();
    const file = std.Io.Dir.cwd().createFile(process_io, progress.path, .{ .truncate = true }) catch return;
    defer file.close(process_io);
    var writer = file.writer(process_io, &.{});
    var opts = progress.dump;
    // Repeated progress snapshots must not mutate the live document by adding
    // a new <base> element on every tick. The final snapshot still honours the
    // caller's dump options below.
    opts.with_base = false;
    dump.root(frame.document, opts, &writer.interface, frame) catch return;
    writer.interface.flush() catch {};
}

pub fn fetch(_: *App, browser: *Browser, url: [:0]const u8, opts: FetchOpts) !void {
    const session = if (browser.session) |*session| session else return error.SessionNotAvailable;
    log.debug(.app, "fetch create page", .{ .url = url });
    const frame = try session.createPage();
    log.debug(.app, "fetch navigate start", .{ .url = url });
    try frame.navigate(url, .{});
    log.debug(.app, "fetch navigate submitted", .{ .url = url, .frame_url = frame.url });

    // A page with long-lived reCAPTCHA/analytics activity may never reach the
    // requested wait state. Application telemetry is still useful in that
    // case, so capture the browser state accumulated so far before returning
    // a wait/action error.
    var application_snapshot_emitted = false;
    errdefer if (!application_snapshot_emitted) {
        session.emitApplicationStorageSnapshot(frame);
        profile_session.saveExecutionCheckpoint(session, frame.url);
    };

    var runner = try session.runner(.{});
    var progress: ?ProgressSnapshot = if (opts.dump_html_file) |path| .{
        .path = path,
        .dump = opts.dump,
    } else null;
    if (progress) |*snapshot| {
        runner.setProgressHook(.{
            .context = snapshot,
            .callback = writeProgressSnapshot,
            .interval_ms = 250,
        });
    }
    log.debug(.app, "fetch wait start", .{ .url = url, .wait_ms = opts.wait_ms, .wait_until = opts.wait_until });
    try runner.wait(.{ .ms = opts.wait_ms, .until = opts.wait_until });
    if (opts.observe_ms > 0) {
        log.debug(.app, "fetch background observe start", .{ .url = url, .observe_ms = opts.observe_ms });
        try runner.pumpFor(opts.observe_ms);
        log.debug(.app, "fetch background observe done", .{ .url = url });
    }
    if (opts.expand_lazy) {
        log.debug(.app, "fetch expand lazy start", .{ .url = url, .max_scrolls = opts.max_scrolls, .settle_ms = opts.scroll_settle_ms });
        try runner.expandLazy(.{
            .max_scrolls = opts.max_scrolls,
            .settle_ms = opts.scroll_settle_ms,
        });
        log.debug(.app, "fetch expand lazy done", .{ .url = url });
    }
    const active_frame = session.currentFrame() orelse return error.SessionNotAvailable;
    log.debug(.app, "fetch wait done", .{ .url = url, .frame_url = active_frame.url });
    if (opts.wait_selector) |selector| {
        log.debug(.app, "fetch wait selector start", .{ .url = url, .selector = selector, .wait_ms = opts.wait_ms });
        _ = try runner.waitForSelector(selector, opts.wait_ms);
        log.debug(.app, "fetch wait selector done", .{ .url = url, .selector = selector });
    }
    if (opts.click_selector) |selector| {
        log.debug(.app, "fetch click start", .{ .url = url, .selector = selector });
        const el = try runner.waitForSelector(selector, opts.wait_ms);
        try el.scrollIntoViewIfNeeded(true, active_frame);
        const rect = el.getBoundingClientRect(active_frame);
        const x = rect.getLeft() + @as(f64, @floatFromInt(opts.click_offset_x));
        const y = rect.getTop() + (@as(f64, @floatFromInt(opts.click_offset_y orelse 0)) + if (opts.click_offset_y == null) rect.getHeight() / 2 else 0);
        log.info(.app, "fetch core click", .{
            .selector = selector,
            .x = x,
            .y = y,
            .left = rect.getLeft(),
            .top = rect.getTop(),
            .width = rect.getWidth(),
            .height = rect.getHeight(),
        });
        try active_frame.triggerMouseClick(x, y);
        log.debug(.app, "fetch click done", .{ .url = url, .selector = selector });
        @import("support/timer.zig").sleepNanoseconds(500 * std.time.ns_per_ms);
    }
    if (opts.wait_script) |script| {
        log.debug(.app, "fetch wait script start", .{ .url = url, .wait_ms = opts.wait_ms });
        try runner.waitForScript(script, opts.wait_ms);
        log.debug(.app, "fetch wait script done", .{ .url = url });
    }

    // Snapshot browser-owned storage after all requested waits/actions have
    // settled. This powers Observatory's Application panel without exposing
    // secret values in its persisted JSONL telemetry.
    const storage_frame = session.currentFrame() orelse return error.SessionNotAvailable;
    session.emitApplicationStorageSnapshot(storage_frame);
    profile_session.saveExecutionCheckpoint(session, storage_frame.url);
    application_snapshot_emitted = true;

    const dump_frame = session.currentFrame() orelse return error.SessionNotAvailable;

    // Observatory needs the hydrated document, not only the original HTTP
    // response body. Keep the normal stdout dump unchanged and optionally
    // serialize this final DOM to a sidecar file for consumers that need both
    // HTML and Markdown from the same browser run.
    if (opts.dump_html_file) |path| {
        const process_io = io.get();
        const file = try std.Io.Dir.cwd().createFile(process_io, path, .{ .truncate = true });
        defer file.close(process_io);
        var file_writer = file.writer(process_io, &.{});
        try dump.root(dump_frame.document, opts.dump, &file_writer.interface, dump_frame);
        try file_writer.interface.flush();
    }

    const writer = opts.writer orelse return;
    log.debug(.app, "fetch dump start", .{ .url = url, .frame_url = dump_frame.url, .dump_mode = opts.dump_mode });
    switch (opts.dump_mode orelse return) {
        .html, .wpt => try dump.root(dump_frame.document, opts.dump, writer, dump_frame),
        .markdown => try markdown.dump(dump_frame.document.asNode(), .{}, writer, dump_frame),
        .semantic_tree, .semantic_tree_text => {},
    }
    log.debug(.app, "fetch dump done", .{ .url = url, .frame_url = dump_frame.url });
}

pub fn RC(comptime T: type) type {
    return struct {
        const Self = @This();

        count: T = 1,

        pub fn init(count: T) Self {
            return .{ .count = count };
        }

        pub fn acquire(self: *Self) void {
            self.count += 1;
        }

        pub fn release(self: *Self, owner: anytype, page: anytype) void {
            self.count -= 1;
            if (self.count == 0) {
                owner.deinit(page);
            }
        }
    };
}

pub fn assert(ok: bool, comptime msg: []const u8, args: anytype) void {
    if (ok) return;
    log.err(.app, msg, args);
    std.debug.assert(ok);
}

test {
    std.testing.refAllDecls(@This());
}
