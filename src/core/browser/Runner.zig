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
const Timer = @import("../../support/timer.zig");
const builtin = @import("builtin");

const js = @import("../js/js.zig");
const Frame = @import("Frame.zig");
const Session = @import("Session.zig");
const HttpClient = @import("HttpClient.zig");
const HostIdle = @import("HostIdle.zig");

const Node = @import("../dom/Node.zig");
const Selector = @import("../webapi/selector/Selector.zig");

const log = @import("../../support/log.zig");
const IS_DEBUG = builtin.mode == .Debug;

const Runner = @This();

frame: *Frame,
session: *Session,
http_client: *HttpClient,
dom_stability: HostIdle.DomStability = .{},
/// Independent observer used to report milestones even when the caller waits
/// for a different condition (for example DCL) and keeps the page alive.
lifecycle_dom_stability: HostIdle.DomStability = .{},
lifecycle_domstable_frame_identity: usize = 0,
lifecycle_domstable_loader_id: u32 = 0,
progress_hook: ?ProgressHook = null,
last_progress_ms: u64 = 0,

pub const Opts = struct {};

pub fn init(session: *Session, _: Opts) !Runner {
    const frame = session.currentFrame() orelse return error.NoPage;

    return .{
        .frame = frame,
        .session = session,
        .http_client = &session.browser.http_client,
    };
}

pub const WaitOpts = struct {
    ms: u32,
    until: @import("../../runtime/Config.zig").WaitUntil = .done,
};

pub const ExpandLazyOpts = struct {
    /// Maximum number of viewport-sized scroll steps. This is a safety limit
    /// for pages that append content forever.
    max_scrolls: u32 = 80,
    /// Maximum time to service timers, scroll handlers, DOM mutations and
    /// requests after each step. Adaptive idle can finish earlier.
    settle_ms: u32 = 250,
    /// Number of unchanged bottom passes required before declaring expansion
    /// complete.
    stable_rounds: u8 = 3,
    /// Short quiet interval used between scroll steps. `settle_ms` remains the
    /// maximum budget for a step, but a page that has no new work can advance
    /// after this interval instead of always paying the full budget.
    adaptive_quiet_ms: u32 = 125,
};

const LazyIdleState = struct {
    frame_identity: usize = 0,
    height: f64 = -1.0,
    quiet_ms: u32 = 0,
    initialized: bool = false,

    fn observe(
        self: *LazyIdleState,
        frame_identity: usize,
        height: f64,
        slice_ms: u32,
        required_quiet_ms: u32,
    ) bool {
        const changed = !self.initialized or
            self.frame_identity != frame_identity or
            self.height != height;

        if (changed) {
            self.quiet_ms = 0;
        } else {
            self.quiet_ms +|= slice_ms;
        }

        self.frame_identity = frame_identity;
        self.height = height;
        self.initialized = true;

        return !changed and self.quiet_ms >= required_quiet_ms;
    }
};

fn pumpLazyStep(self: *Runner, opts: ExpandLazyOpts) !u32 {
    if (opts.settle_ms == 0) return 0;

    const slice_ms: u32 = 50;
    var elapsed_ms: u32 = 0;
    var idle = LazyIdleState{};

    while (elapsed_ms < opts.settle_ms) {
        const tick_ms = @min(slice_ms, opts.settle_ms - elapsed_ms);
        try self.pumpFor(tick_ms);
        elapsed_ms += tick_ms;

        const frame = self.session.currentFrame() orelse return elapsed_ms;
        const root = frame.document.getDocumentElement() orelse return elapsed_ms;
        const height = root.getScrollHeight(frame);
        if (idle.observe(
            @intFromPtr(frame),
            height,
            tick_ms,
            opts.adaptive_quiet_ms,
        )) return elapsed_ms;
    }
    return elapsed_ms;
}

/// A low-frequency hook for consumers that need an intermediate document
/// snapshot while a wait policy is still running. This deliberately lives on
/// Runner rather than the telemetry sink: progress snapshots are artifacts,
/// not one telemetry event per parser/layout tick.
pub const ProgressHook = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque, frame: *Frame) void,
    interval_ms: u64 = 250,
};

pub fn setProgressHook(self: *Runner, hook: ?ProgressHook) void {
    self.progress_hook = hook;
    self.last_progress_ms = 0;
}

fn maybeEmitProgress(self: *Runner) void {
    const hook = self.progress_hook orelse return;
    const now = @import("../../support/datetime.zig").milliTimestamp(.monotonic);
    if (self.last_progress_ms != 0 and now -| self.last_progress_ms < hook.interval_ms) return;
    self.last_progress_ms = now;
    hook.callback(hook.context, self.frame);
}

pub fn wait(self: *Runner, opts: WaitOpts) !void {
    _ = try self._wait(false, opts);
}

pub const CDPWaitResult = enum {
    done,
    cdp_socket,
};
pub fn waitCDP(self: *Runner, opts: WaitOpts) !CDPWaitResult {
    return self._wait(true, opts);
}

/// Keep servicing the page for a bounded observation window after a lifecycle
/// milestone. This mirrors an interactive browser: the document can be
/// presented while hydration, lazy resources and background work continue.
/// A bounded window prevents pages with polling/WebSockets from living forever
/// in one-shot CLI executions.
pub fn pumpFor(self: *Runner, ms: u32) !void {
    if (ms == 0) return;
    var timer = try Timer.start();
    while (true) {
        if (self.session.browser.isHostTerminationRequested()) return;
        const elapsed: u32 = @intCast(timer.read() / std.time.ns_per_ms);
        if (elapsed >= ms) return;
        const result = self._tick(false, .{ .ms = @min(ms - elapsed, 200), .until = .done }) catch |err| {
            if (self.session.browser.isHostTerminationRequested()) return;
            return err;
        };
        self.maybeEmitLifecycle();
        self.maybeEmitProgress();
        const after_tick_elapsed: u32 = @intCast(timer.read() / std.time.ns_per_ms);
        if (after_tick_elapsed >= ms) return;
        const remaining: u32 = ms - after_tick_elapsed;
        const sleep_ms = switch (result) {
            .done => @min(remaining, 50),
            .ok => |next_ms| @min(remaining, next_ms),
            .cdp_socket => @min(remaining, 5),
        };
        if (sleep_ms > 0) Timer.sleepNanoseconds(std.time.ns_per_ms * sleep_ms);
    }
}

/// Progressively expand viewport-driven lazy content. This models a user
/// scrolling in bounded increments, allowing scroll listeners, Intersection-
/// Observer callbacks, timers and network responses to run between steps.
/// It intentionally lives in Runner rather than dump/export code so all
/// consumers get the same browser lifecycle semantics.
pub fn expandLazy(self: *Runner, opts: ExpandLazyOpts) !void {
    if (opts.max_scrolls == 0) return;

    var stable: u8 = 0;
    var previous_height: f64 = -1.0;
    var previous_y: u32 = 0;

    var step_index: u32 = 0;
    while (step_index < opts.max_scrolls) : (step_index += 1) {
        const frame = self.session.currentFrame() orelse return;
        const profile = frame.identityProfile();
        const viewport_height = @as(f64, @floatFromInt(profile.window.inner_height));
        const root = frame.document.getDocumentElement() orelse return;
        const scroll_height = root.getScrollHeight(frame);
        const max_y = @max(0.0, scroll_height - viewport_height);
        const current_y = @as(f64, @floatFromInt(frame.window.getScrollY()));
        // Advance one full viewport per pass. Consecutive viewport edges are
        // contiguous, so IntersectionObserver targets are still visited while
        // avoiding the redundant 20% overlap that inflated scroll count.
        const step = @max(viewport_height, 1.0);
        const next_y = @min(max_y, current_y + step);

        frame.window.scrollTo(.{ .x = @intCast(frame.window.getScrollX()) }, @intFromFloat(next_y), frame) catch |err| {
            log.warn(.browser, "expand lazy scroll failed", .{ .err = err, .step = step_index });
            return err;
        };
        const pump_ms = try self.pumpLazyStep(opts);
        log.debug(.browser, "expand lazy step settled", .{ .step = step_index, .pump_ms = pump_ms });

        const after_frame = self.session.currentFrame() orelse return;
        const after_root = after_frame.document.getDocumentElement() orelse return;
        const after_height = after_root.getScrollHeight(after_frame);
        const after_y = after_frame.window.getScrollY();
        const at_bottom = @as(f64, @floatFromInt(after_y)) + viewport_height >= after_height - 1.0;

        // A pass is stable only when the page was already at its bottom and
        // neither the scroll position nor document extent changed. New lazy
        // content resets the counter and receives more scroll/pump passes.
        if (at_bottom and after_height <= previous_height and after_y == previous_y) {
            stable +|= 1;
        } else {
            stable = 0;
        }
        previous_height = after_height;
        previous_y = after_y;

        if (stable >= opts.stable_rounds) return;
    }
}

fn _wait(self: *Runner, comptime is_cdp: bool, opts: WaitOpts) !CDPWaitResult {
    var timer = try Timer.start();
    var done_confirmations: u8 = 0;
    if (opts.until == .domstable) self.dom_stability.reset();

    const tick_opts = TickOpts{
        .ms = 200,
        .until = opts.until,
    };

    // Periodic V8 GC hint during long waits. V8 is otherwise only nudged on
    // session/page teardown (Browser.zig, Page.zig), so a page that stays
    // alive for seconds while running heavy JS accumulates wrappers and
    // external-ref'd Zig allocations V8 has no reason to drop. `.moderate`
    // speeds up incremental GC without stalling the tick.
    // Every 1s put too much pressure on V8 (high CPU on complex pages); 5s is enough.
    const gc_hint_period_ns: u64 = std.time.ns_per_s * 5;
    var gc_hint_timer = Timer.start() catch unreachable;

    while (true) {
        // A host deadline is an operation-level cancellation, not merely a V8
        // evaluation interruption. Finish the wait so callers can serialize the
        // last committed document and then run normal ownership-safe teardown.
        if (self.session.browser.isHostTerminationRequested()) return .done;

        if (gc_hint_timer.read() >= gc_hint_period_ns) {
            gc_hint_timer.reset();
            self.frame._page.cleanupClosedPopups();
            self.session.browser.env.memoryPressureNotification(.moderate);
        }

        // A previous _tick iteration may have parked a pending root navigation
        // commit because JS was on the V8 stack at the time HttpClient.perform
        // reentrantly drained the pending response (see
        // Session._deferred_commit_pending). By the top of this loop the script
        // has unwound, so it is safe to promote the pending page now. Without
        // this drain, the loop would block on http_client.tick for the full
        // wait window (up to ~1s) before the commit happens, adding per-
        // navigation latency for any page that issues fetch() from JS.
        self.session.drainDeferredCommit();

        const tick_result = self._tick(is_cdp, tick_opts) catch |err| {
            if (self.session.browser.isHostTerminationRequested()) return .done;
            switch (err) {
                error.JsError => {}, // already logged (with hopefully more context)
                else => log.err(.browser, "session wait", .{
                    .err = err,
                    .url = self.frame.url,
                }),
            }
            return err;
        };
        self.maybeEmitLifecycle();
        self.maybeEmitProgress();

        const next_ms = switch (tick_result) {
            .ok => |next_ms| next_ms,
            .done => blk: {
                // A network callback may settle the last transfer and enqueue
                // its DOM event at the same idle edge. Require a short stable
                // quiescence window so load/error handlers and their immediate
                // microtasks are reflected in an HTML snapshot.
                if (!is_cdp and opts.until == .done and done_confirmations < 2) {
                    done_confirmations += 1;
                    const js_mod = @import("../js/js.zig");
                    js_mod.EventLoop.spin(&self.frame.js.execution, .{
                        .max_tasks = 48,
                        .stop_when_idle = true,
                    });
                    self.session.browser.env.runMicrotasks(.macrotask_loop);
                    break :blk 5;
                }
                return .done;
            },
            .cdp_socket => if (comptime is_cdp) return .cdp_socket else unreachable,
        };
        if (tick_result != .done) done_confirmations = 0;

        const ms_elapsed: u32 = @intCast(timer.read() / std.time.ns_per_ms);
        if (ms_elapsed >= opts.ms) {
            return .done;
        }
        if (next_ms > 0) {
            Timer.sleepNanoseconds(std.time.ns_per_ms * next_ms);
        }
    }
}

fn maybeEmitLifecycle(self: *Runner) void {
    const frame = self.session.pendingOrCurrentFrame() orelse return;
    const now = @import("../../support/datetime.zig").milliTimestamp(.monotonic);
    if (!self.lifecycle_dom_stability.observe(frame, now)) return;
    const identity = @intFromPtr(frame);
    if (self.lifecycle_domstable_frame_identity == identity and self.lifecycle_domstable_loader_id == frame._loader_id) return;
    self.lifecycle_domstable_frame_identity = identity;
    self.lifecycle_domstable_loader_id = frame._loader_id;
    frame.observeLifecycleForRunner("domstable");
}

pub const TickOpts = struct {
    ms: u32,
    until: @import("../../runtime/Config.zig").WaitUntil = .done,
};

pub const TickResult = union(enum) {
    done,
    ok: u32,
};

fn nonCdpTickResult(result: CDPTickResult) TickResult {
    return switch (result) {
        .ok => |ms| .{ .ok = ms },
        .done => .done,
        // HttpClient multiplexes browser traffic and the optional CDP socket.
        // Readability is a wake-up for a non-CDP runner too; it is not an
        // impossible state.
        .cdp_socket => .{ .ok = 0 },
    };
}

pub fn tick(self: *Runner, opts: TickOpts) !TickResult {
    const result = nonCdpTickResult(try self._tick(false, opts));
    self.maybeEmitProgress();
    return result;
}

pub const CDPTickResult = union(enum) {
    done,
    cdp_socket,
    ok: u32,
};

test "Runner: CDP socket readiness wakes a non-CDP runner" {
    const result = nonCdpTickResult(.cdp_socket);
    try std.testing.expectEqual(@as(u32, 0), result.ok);
}
pub fn tickCDP(self: *Runner, opts: TickOpts) !CDPTickResult {
    const result = try self._tick(true, opts);
    self.maybeEmitProgress();
    return result;
}

fn drainDeferredDocumentParse(self: *Runner, comptime is_cdp: bool) void {
    _ = is_cdp;
    self.drainDeferredDocumentParseFrame(self.frame);
}

/// Drain parser tasks in their owning browsing-context scheduler. Child-frame
/// documents complete on independent HTTP transfers and therefore may become
/// parse-ready while the root document is already complete. Moving their task
/// to the root scheduler would break realm cancellation and teardown ownership;
/// walk the live frame tree instead.
fn drainDeferredDocumentParseFrame(self: *Runner, frame: *Frame) void {
    const http_client = self.http_client;
    if (frame.hasDeferredDocumentParsePending()) {
        // Do not gate on http_active: the document transfer is already done when
        // frameDoneCallback schedules parse. Waiting for all subresource fetches
        // leaves HTML unparseable and DCL unable to fire.
        if (!frame.canRunOwnedScheduler()) {
            frame.cancelOwnedSchedulerWork();
            return;
        }

        const env = &self.session.browser.env;
        var slices: u8 = 0;
        while (slices < 48) : (slices += 1) {
            if (!frame.canRunOwnedScheduler()) {
                frame.cancelOwnedSchedulerWork();
                return;
            }
            env.runMicrotasks(.macrotask_loop);
            if (!frame.js.scheduler.hasReadyTasks()) break;
            var hs: js.HandleScope = undefined;
            const entered = frame.js.enter(&hs) orelse break;
            const ran = frame.runOwnedSchedulerOne() catch false;
            entered.exit();
            if (!ran) break;
            env.runMicrotasks(.macrotask_loop);
            // CDP may start re-nav; next loop iteration cancels if realm left active.
            http_client.serviceInboundCdpIfReadable();
            if (!frame.hasDeferredDocumentParsePending() and !frame._document_parse_active) break;
        }
    }

    // Parse callbacks can append nested browsing contexts. Index against the
    // current list length so newly committed descendants are visited too.
    var child_index: usize = 0;
    while (child_index < frame.child_frames.items.len) : (child_index += 1) {
        self.drainDeferredDocumentParseFrame(frame.child_frames.items[child_index]);
    }
}

fn _tick(self: *Runner, comptime is_cdp: bool, opts: TickOpts) !CDPTickResult {
    // Refresh self.frame from session. In case of pending page, we want to
    // take its state while loading. If we use only the current frame, we will
    // return a .done result immediately.
    self.frame = self.session.pendingOrCurrentFrame() orelse return .done;
    const frame = self.frame;
    const http_client = self.http_client;

    switch (frame._parse_state) {
        .pre, .raw, .text, .image, .html, .deferred_html => {
            // The main frame hasn't started/finished navigating.
            // There's no JS to run, and no reason to run the scheduler.
            // Include queue/ready_queue: SPA inject mid-callback parks transfers

            // HostIdle queues (not raw http_active alone).
            if (HostIdle.isNetworkIdle(http_client) and (comptime is_cdp) == false) {
                // Deferred HTML parse is scheduled from the HTTP callback; without
                // draining it here MCP runner.wait() returned .done while the URL
                // was set but the document was still empty (github.com).
                self.drainDeferredDocumentParse(is_cdp);
                if (frame._parse_state == .pre and !frame.hasDeferredDocumentParsePending() and !frame._document_parse_active) {
                    return .done;
                }
            }

            if (comptime is_cdp) {
                self.drainDeferredDocumentParse(is_cdp);
                // At this point the document has not reached a runnable
                // realm yet. Avoid paying the normal 1 ms fairness quantum
                // on the first I/O turn; later turns use tick() so scripts
                // and timers retain starvation protection.
                const early = try http_client.tickImmediate();
                if (early == .cdp_socket) return .cdp_socket;
                // scheduleDeferredFrameNavigated queues the CDP Page.navigate ack at
                // header time. Waiting for http_active==0 delayed the response by
                // the full document body transfer (ebay.com ~400KB).
                var slices: u8 = 0;
                while (slices < 8) : (slices += 1) {
                    // Network completion above may enqueue parser/script work,
                    // but a static document often has nothing runnable here.
                    // Avoid entering Env.runOneMacrotaskRound when all realms
                    // are idle; the next HttpClient tick still owns I/O.
                    if (!self.session.browser.hasReadyMacrotasks()) break;
                    if (!try self.session.browser.runMacrotasksCdpSlice()) break;
                }
                frame._script_manager.base.pumpDocumentLifecycle(frame);
            }

            // Either we have active http connections, or we're in CDP
            // mode with an extra socket. Either way, we're waiting
            // for http traffic
            const http_result = try http_client.tick(@intCast(opts.ms));
            self.drainDeferredDocumentParse(is_cdp);
            if ((comptime is_cdp) and http_result == .cdp_socket) {
                return .cdp_socket;
            }
            return .{ .ok = 0 };
        },
        .complete => {
            // Root completion does not imply child document completion. A child
            // transfer may have queued its parser task after the root entered
            // `.complete`; drain those realm-owned tasks on every complete-state
            // turn as well as during root document loading.
            self.drainDeferredDocumentParse(is_cdp);

            // Service inbound CDP commands before macrotasks / background-task pumps.
            // ebay.com document load otherwise starves Runtime.evaluate for tens of seconds.
            if (comptime is_cdp) {
                const early = try http_client.tick(0);
                if (early == .cdp_socket) return .cdp_socket;
            }

            const session = self.session;
            if (session.currentPage()) |page| {
                if (page.queued_navigation.items.len != 0) {
                    try session.processQueuedNavigation();
                    // Root navigations (e.g. Google sg_ss via location.replace) may
                    // promote a pending Page; follow it so the next state machine
                    // pass ticks the in-flight document transfer.
                    // Navigation callbacks may synchronously close the last
                    // browsing context. Absence of both pending and active
                    // pages is a terminal runner state, not an invariant
                    // violation.
                    self.frame = session.pendingOrCurrentFrame() orelse return .done;
                    // Do not drive curl from the same stack that installs the
                    // navigation. A transfer completion may enter browser
                    // lifecycle code before the pending page/realm transition
                    // has reached a stable boundary. The next Runner tick owns
                    // network progress.
                    return .{ .ok = 0 };
                }
            }
            const browser = session.browser;

            // The HTML page was parsed. We now either have JS scripts to
            // download, or scheduled tasks to execute, or both.

            // scheduler.run could trigger new http transfers, so do not
            // store http_client.http_active BEFORE this call and then use
            // it AFTER.
            if (comptime is_cdp) {
                var slices: u8 = 0;
                while (slices < 64) : (slices += 1) {
                    const early = try http_client.tick(0);
                    if (early == .cdp_socket) return .cdp_socket;
                    if (!browser.hasReadyMacrotasks()) break;
                    if (!try browser.runMacrotasksCdpSlice()) break;
                }
            } else {
                try browser.runMacrotasks();
            }
            self.drainDeferredDocumentParse(is_cdp);
            // commitPendingPage may have swapped active/pending during tick/macrotasks;
            // do not drain RTC (or read load/idle state) through a stale Frame ptr.
            self.frame = session.pendingOrCurrentFrame() orelse return .done;
            const live_frame = self.frame;

            // Macrotasks and their microtask checkpoint may schedule a root or
            // iframe navigation (location assignment, form submission, etc.).
            // Re-check the queue before evaluating the current document's wait
            // condition. Otherwise `wait_until=load` can report completion for
            // the departing document and abandon the newly queued navigation.
            if (session.currentPage()) |page| {
                if (page.queued_navigation.items.len != 0) {
                    try session.processQueuedNavigation();
                    self.frame = session.pendingOrCurrentFrame() orelse return .done;
                    return .{ .ok = 0 };
                }
            }

            // Single wait-edge spin (architecture v0.2): MessageChannel / delay-0
            // chains. Do not also spin inside Browser.runMacrotasks.
            const js_mod = @import("../js/js.zig");
            js_mod.EventLoop.spin(&live_frame.js.execution, .{
                .max_tasks = 48,
                .stop_when_idle = true,
            });
            live_frame._script_manager.base.pumpDocumentLifecycle(live_frame);
            live_frame.drainRtcEvents();

            // The wait-edge spin above is also script execution and can enqueue
            // navigation. No completion decision is valid until that queue has
            // been handed back to the Session navigation state machine.
            if (session.currentPage()) |page| {
                if (page.queued_navigation.items.len != 0) {
                    try session.processQueuedNavigation();
                    self.frame = session.pendingOrCurrentFrame() orelse return .done;
                    return .{ .ok = 0 };
                }
            }

            // HostIdle: one formula for wait_until=done / networkIdle (queues included).
            const total_http_activity = HostIdle.totalHttpActivity(http_client);
            const network_idle = HostIdle.isNetworkIdle(http_client);
            const ms_to_next_macrotask = browser.msToNextMacrotask();
            const script_pending = live_frame._script_manager.base.hasPendingJsWork();
            // Lazy images intentionally do not block `load`, but their
            // activation task is still part of the navigation's eventual
            // `done` state. Without this edge, a page can be reported done
            // in the small window after load dispatch and before the queued
            // fallback activation starts the image request.
            const lazy_image_activation_pending = live_frame.hasPendingLazyImageActivation();
            const is_done = !lazy_image_activation_pending and
                HostIdle.isFullyIdle(http_client, live_frame, browser);
            const immediate_host_work =
                js_mod.EventLoop.hasReadyWork(&live_frame.js.execution) or
                (ms_to_next_macrotask != null and ms_to_next_macrotask.? == 0);

            live_frame.checkIdleNotifications(total_http_activity);

            // `_we_` have nothing to run, but v8 is working on background tasks.
            // Wait for them (non-CDP only — CDP messages can arrive any time).
            if ((comptime is_cdp) == false and network_idle and browser.hasBackgroundTasks()) {
                browser.waitForBackgroundTasks();
                return .{ .ok = 0 };
            }

            const met = switch (opts.until) {
                .done => is_done,
                .domcontentloaded => live_frame._load_state == .load or live_frame._load_state == .complete,
                .load => live_frame._load_state == .complete,
                .networkidle => live_frame._notified_network_idle == .done,
                .domstable => self.dom_stability.observe(
                    live_frame,
                    @import("../../support/datetime.zig").milliTimestamp(.monotonic),
                ),
            };

            // `met` resolves the wait goal. Otherwise, if the page is fully
            // idle (`is_done`) there is nothing left to wait on — resolve rather
            const allow_fully_idle_shortcut = opts.until != .domstable;
            if ((met and !immediate_host_work) or (is_done and allow_fully_idle_shortcut)) {
                if (comptime is_cdp) {
                    // CDP event loop keeps ticking for commands; only leave when
                    // the explicit wait condition is met (not is_done alone for
                    // long-lived pages with ads that never go fully quiet).
                    if (met) return .done;
                } else {
                    return .done;
                }
            }

            // Keep ticking: network, scripts, or macrotasks still in flight (or CDP).
            var ms_to_wait = @min(opts.ms, ms_to_next_macrotask orelse 200);
            if (comptime is_cdp) {
                ms_to_wait = @min(ms_to_wait, 5);
            } else if (script_pending) {
                // Unevaluated SPA chunks: re-enter pumpDocumentLifecycle ASAP.
                ms_to_wait = 0;
            } else if (ms_to_wait > 10 and browser.hasBackgroundTasks()) {
                // if we have background tasks, we don't want to wait too
                // long for a message from the client. We want to go back
                // to the top of the loop and run macrotasks.
                ms_to_wait = 10;
            } else if (!network_idle and ms_to_wait > 50) {
                // Queued/active HTTP: poll more often so ready_queue promotes
                // and SPA post-load fetches make progress before wait timeout.
                ms_to_wait = 50;
            }
            const http_result = try http_client.tick(@intCast(@min(opts.ms, ms_to_wait)));
            if ((comptime is_cdp) and http_result == .cdp_socket) {
                return .cdp_socket;
            }
            // HttpClient.tick may no-op when there is nothing to poll (I/O idle,
            // only macrotasks pending). Returning .ok=0 would spin the wait loop;
            // instead sleep until the next scheduled task (LP #2999).
            if ((comptime is_cdp) == false and http_result == .idle) {
                return .{ .ok = @intCast(ms_to_wait) };
            }
            return .{ .ok = 0 };
        },
        .err => |err| {
            frame._parse_state = .{ .raw_done = @errorName(err) };
            return err;
        },
        .raw_done => {
            if (comptime is_cdp) {
                const http_result = try http_client.tick(@intCast(opts.ms));
                if (http_result == .cdp_socket) {
                    return .cdp_socket;
                }
                return .{ .ok = 0 };
            }
            return .done;
        },
    }
}

pub fn waitForSelector(self: *Runner, selector: [:0]const u8, timeout_ms: u32) !*Node.Element {
    const arena = try self.session.getArena(.small, "Runner.waitForSelector");
    defer self.session.releaseArena(arena);

    var timer = try Timer.start();
    const parsed_selector = try Selector.parseLeaky(arena, selector);

    while (true) {
        // self.frame can change between ticks
        const frame = self.frame;
        if (try parsed_selector.query(frame.document.asNode(), frame)) |el| {
            return el;
        }

        const elapsed: u32 = @intCast(timer.read() / std.time.ns_per_ms);
        if (elapsed >= timeout_ms) {
            return error.Timeout;
        }
        // Page may be idle (.done) while wait condition not yet true — keep
        // spinning until wall timeout (architecture D1).
        switch (try self.tick(.{ .ms = timeout_ms - elapsed })) {
            .done => {
                // Still pump host tasks; only fail on wall clock.
                const js_mod = @import("../js/js.zig");
                js_mod.EventLoop.spin(&self.frame.js.execution, .{ .max_tasks = 16, .stop_when_idle = true });
                Timer.sleepNanoseconds(std.time.ns_per_ms * 5);
            },
            .ok => |recommended_sleep_ms| {
                if (recommended_sleep_ms > 0) {
                    Timer.sleepNanoseconds(std.time.ns_per_ms * recommended_sleep_ms);
                }
            },
        }
    }
}

fn evaluateWaitScript(frame: *Frame, script: [:0]const u8) !bool {
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const value = ls.local.exec(script, "wait_script") catch |err| {
        const caught = try_catch.caughtOrError(frame.call_arena, err);
        log.warn(.app, "wait script retry after exception", .{ .err = caught });
        return false;
    };
    return value.toBool();
}

pub fn waitForScript(runner: *Runner, script: [:0]const u8, timeout_ms: u32) !void {
    var timer = try Timer.start();

    while (true) {
        // Evaluation owns a short-lived V8 handle scope. It must be closed
        // before runner.tick(), because tick may commit a navigation and
        // replace the active realm/context.
        // runner.frame may point at a pending document so the load state
        // machine can progress it. Script evaluation, like browser automation,
        // remains bound to the active browsing context until navigation
        // commits.
        if (runner.session.currentFrame()) |active_frame| {
            if (try evaluateWaitScript(active_frame, script)) return;
        }

        const elapsed: u32 = @intCast(timer.read() / std.time.ns_per_ms);
        if (elapsed >= timeout_ms) {
            return error.Timeout;
        }
        // Idle page (.done) is not wait_script timeout — keep EventLoop spinning.
        switch (try runner.tick(.{ .ms = timeout_ms - elapsed })) {
            .done => {
                const js_mod = @import("../js/js.zig");
                if (runner.session.currentFrame()) |active_frame| {
                    js_mod.EventLoop.spin(&active_frame.js.execution, .{ .max_tasks = 16, .stop_when_idle = true });
                }
                Timer.sleepNanoseconds(std.time.ns_per_ms * 5);
            },
            .ok => |recommended_sleep_ms| {
                if (recommended_sleep_ms > 0) {
                    Timer.sleepNanoseconds(std.time.ns_per_ms * recommended_sleep_ms);
                }
            },
        }
    }
}

const testing = @import("../../testing/testing.zig");
test "Runner: no page" {
    try testing.expectError(error.NoPage, Runner.init(testing.test_session, .{}));
}

test "Runner: waitForSelector timeout" {
    const frame = try testing.pageTest("runner/runner1.html", .{});
    defer frame._session.removePage();

    var runner = try frame._session.runner(.{});
    try testing.expectError(error.Timeout, runner.waitForSelector("#nope", 10));
}

test "Runner: waitForSelector" {
    defer testing.reset();
    const frame = try testing.pageTest("runner/runner1.html", .{});
    defer frame._session.removePage();

    var runner = try frame._session.runner(.{});
    const el = try runner.waitForSelector("#sel1", 10);
    try testing.expectEqual("selector-1-content", try el.asNode().getTextContentAlloc(testing.arena_allocator));
}

test "Runner: waitForScript timeout" {
    const frame = try testing.pageTest("runner/runner1.html", .{});
    defer frame._session.removePage();

    var runner = try frame._session.runner(.{});
    try testing.expectError(error.Timeout, runner.waitForScript("document.querySelector('#nope')", 10));
}

test "Runner: waitForScript" {
    const frame = try testing.pageTest("runner/runner1.html", .{});
    defer frame._session.removePage();

    var runner = try frame._session.runner(.{});
    try runner.waitForScript("document.querySelector('#sel1')", 10);
}

test "Runner: host termination ends a browser wait" {
    defer testing.reset();
    const frame = try testing.pageTest("runner/runner1.html", .{});
    defer frame._session.removePage();

    const browser = frame._session.browser;
    browser.requestHostTermination();
    defer browser.clearHostTermination();

    var runner = try frame._session.runner(.{});
    try runner.wait(.{ .ms = 60_000, .until = .done });
}

test "Runner: done waits for deferred lazy image activation" {
    defer testing.reset();
    const frame = try testing.pageTest("regression/lazy_image_done_wait.html", .{ .wait_until_done = false });
    defer frame._session.removePage();

    var runner = try frame._session.runner(.{});
    try runner.wait(.{ .ms = 2_000, .until = .done });

    // Assert immediately after wait() returns. Do not use waitForScript here:
    // that helper intentionally keeps ticking after a page is otherwise idle,
    // which would hide an early `done` result.
    try testing.expect(try evaluateWaitScript(
        frame,
        "document.querySelector('#lazy').complete && document.querySelector('#lazy').naturalWidth === 1",
    ));
}

test "Runner: text navigation completes after the response body" {
    defer testing.reset();
    const frame = try testing.test_session.createPage();
    defer frame._session.removePage();

    try frame.navigate("http://127.0.0.1:9582/xhr/json", .{});
    var runner = try frame._session.runner(.{});
    var timer = try Timer.start();
    try runner.wait(.{ .ms = 2_000, .until = .domstable });

    // JSON is represented as a synthetic preview document, but it must not
    // inherit the lifecycle wait used by an HTML document.
    try testing.expect(timer.read() < 1 * std.time.ns_per_s);
    try testing.expectEqual(std.meta.activeTag(frame._parse_state), .raw_done);
}

test "Runner: domstable resets for delayed DOM mutation and ignores recurring background work" {
    defer testing.reset();
    const frame = try testing.pageTest("runner/dom_stable.html", .{ .wait_until_done = false });
    defer frame._session.removePage();

    var runner = try frame._session.runner(.{});
    var timer = try Timer.start();
    try runner.wait(.{ .ms = 2000, .until = .domstable });
    const elapsed_ms = timer.read() / std.time.ns_per_ms;

    // The 120ms mutation must restart the 500ms stability interval.
    try testing.expect(elapsed_ms >= 600);
    // The recurring timer is still alive, proving domstable is not full-idle.
    try testing.expect(elapsed_ms < 1500);
    const content = try frame.document.querySelector(comptime .wrap("#content"), frame) orelse return error.MissingStableContent;
    try testing.expectEqualStrings("settled", try content.asNode().getTextContentAlloc(testing.arena_allocator));
}

test "Runner: adaptive lazy idle resets on document extent changes" {
    var idle = LazyIdleState{};

    // The first observation establishes the generation and cannot be idle.
    try std.testing.expect(!idle.observe(1, 100, 50, 100));
    try std.testing.expect(!idle.observe(1, 100, 50, 100));
    try std.testing.expect(idle.observe(1, 100, 50, 100));

    // A lazy response that changes document extent resets the quiet interval
    // instead of allowing an early advance.
    try std.testing.expect(!idle.observe(1, 120, 50, 100));
    try std.testing.expect(!idle.observe(1, 120, 50, 100));
    try std.testing.expect(idle.observe(1, 120, 50, 100));
}
