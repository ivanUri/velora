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
const milliTimestamp = @import("../../support/datetime.zig").milliTimestamp;

const log = @import("../../support/log.zig");
const IS_DEBUG = builtin.mode == .Debug;

const Queue = std.PriorityQueue(Task, void, struct {
    fn compare(_: void, a: Task, b: Task) std.math.Order {
        const time_order = std.math.order(a.run_at, b.run_at);
        if (time_order != .eq) return time_order;
        // Break ties with sequence number to maintain FIFO order
        return std.math.order(a.sequence, b.sequence);
    }
}.compare);

const Scheduler = @This();

_sequence: u64,
allocator: std.mem.Allocator,
/// Bumped by `reset`/`deinit` so an in-flight `run`/`runOne` stops after the
/// current callback instead of peeking a freed PriorityQueue (about:blank
/// iframe detach mid agent collection → SIGSEGV in runOneFromQueue).
_generation: u64 = 0,
low_priority: Queue,
high_priority: Queue,
timers: Queue,

pub fn init(allocator: std.mem.Allocator) Scheduler {
    return .{
        ._sequence = 0,
        .allocator = allocator,
        ._generation = 0,
        .low_priority = .initContext({}),
        .high_priority = .initContext({}),
        .timers = .initContext({}),
    };
}

pub fn deinit(self: *Scheduler) void {
    self._generation +%= 1;
    finalizeTasks(&self.low_priority);
    finalizeTasks(&self.high_priority);
    finalizeTasks(&self.timers);
    self.low_priority.deinit(self.allocator);
    self.high_priority.deinit(self.allocator);
    self.timers.deinit(self.allocator);
}

pub fn reset(self: *Scheduler) void {
    self._generation +%= 1;
    finalizeTasks(&self.low_priority);
    finalizeTasks(&self.high_priority);
    finalizeTasks(&self.timers);
    self.low_priority.clearRetainingCapacity();
    self.high_priority.clearRetainingCapacity();
    self.timers.clearRetainingCapacity();
}

/// Remove matching tasks and invoke their finalizers. Used when tearing down a
/// Worker while deferred script tasks may still be queued on the parent frame.
pub fn cancelTasks(self: *Scheduler, matcher: *const fn (ctx: *anyopaque, callback: Callback) bool) void {
    cancelTasksInQueue(&self.high_priority, self.allocator, matcher);
    cancelTasksInQueue(&self.timers, self.allocator, matcher);
    cancelTasksInQueue(&self.low_priority, self.allocator, matcher);
}

fn cancelTasksInQueue(queue: *Queue, allocator: std.mem.Allocator, matcher: *const fn (ctx: *anyopaque, callback: Callback) bool) void {
    if (queue.count() == 0) return;
    var kept: std.ArrayList(Task) = .empty;
    defer kept.deinit(allocator);

    while (queue.pop()) |task| {
        if (matcher(task.ctx, task.callback)) {
            if (task.finalizer) |func| func(task.ctx);
        } else {
            kept.append(allocator, task) catch {
                if (task.finalizer) |func| func(task.ctx);
            };
        }
    }

    for (kept.items) |task| {
        queue.push(allocator, task) catch {
            if (task.finalizer) |func| func(task.ctx);
        };
    }
}

pub const TaskSource = enum { generic, timer };

const AddOpts = struct {
    name: []const u8 = "",
    low_priority: bool = false,
    source: TaskSource = .generic,
    finalizer: ?Finalizer = null,
};
pub fn add(self: *Scheduler, ctx: *anyopaque, cb: Callback, run_in_ms: u32, opts: AddOpts) !void {
    if (comptime IS_DEBUG) {
        log.debug(.scheduler, "scheduler.add", .{ .name = opts.name, .run_in_ms = run_in_ms, .low_priority = opts.low_priority });
    }
    var queue = if (opts.source == .timer)
        &self.timers
    else if (opts.low_priority)
        &self.low_priority
    else
        &self.high_priority;
    const seq = self._sequence + 1;
    self._sequence = seq;
    return queue.push(self.allocator, .{
        .ctx = ctx,
        .callback = cb,
        .sequence = seq,
        .name = opts.name,
        .finalizer = opts.finalizer,
        .low_priority = opts.low_priority,
        .source = opts.source,
        .run_at = milliTimestamp(.monotonic) + run_in_ms,
    });
}

pub fn run(self: *Scheduler) !void {
    const gen = self._generation;
    const now = milliTimestamp(.monotonic);
    // High-priority tasks (promise follow-ups, audio resolve) must not lose to
    // repeating low-priority timers (CreepJS setTimeout polling).
    try self.runQueue(&self.high_priority, now, gen);
    if (self._generation != gen) return;
    try self.runQueue(&self.timers, now, gen);
    if (self._generation != gen) return;
    try self.runQueue(&self.low_priority, now, gen);
}

pub fn runNonTimerTasks(self: *Scheduler) !void {
    const gen = self._generation;
    const now = milliTimestamp(.monotonic);
    try self.runQueue(&self.high_priority, now, gen);
    if (self._generation != gen) return;
    try self.runQueue(&self.low_priority, now, gen);
}

/// Run at most one ready task (high priority first). Used for knitsail timer milestones.
pub fn runOne(self: *Scheduler) !bool {
    const gen = self._generation;
    const now = milliTimestamp(.monotonic);
    if (try self.runOneFromQueue(&self.high_priority, now, gen)) return true;
    if (self._generation != gen) return false;
    if (try self.runOneFromQueue(&self.timers, now, gen)) return true;
    if (self._generation != gen) return false;
    if (try self.runOneFromQueue(&self.low_priority, now, gen)) return true;
    return false;
}

pub fn runOneNonTimerTask(self: *Scheduler) !bool {
    const gen = self._generation;
    const now = milliTimestamp(.monotonic);
    if (try self.runOneFromQueue(&self.high_priority, now, gen)) return true;
    if (self._generation != gen) return false;
    return try self.runOneFromQueue(&self.low_priority, now, gen);
}

pub fn hasReadyTasks(self: *Scheduler) bool {
    const now = milliTimestamp(.monotonic);
    return queueHasReadyTask(&self.low_priority, now) or
        queueHasReadyTask(&self.high_priority, now) or
        queueHasReadyTask(&self.timers, now);
}

pub fn hasReadyNonTimerTasks(self: *Scheduler) bool {
    const now = milliTimestamp(.monotonic);
    return queueHasReadyTask(&self.low_priority, now) or queueHasReadyTask(&self.high_priority, now);
}

pub fn msToNextHigh(self: *Scheduler) ?u64 {
    return msToNextInQueue(&self.high_priority);
}

pub fn msToNextLow(self: *Scheduler) ?u64 {
    return msToNextInQueue(&self.low_priority);
}

pub fn msToNext(self: *Scheduler) ?u64 {
    const high = msToNextInQueue(&self.high_priority);
    const low = msToNextInQueue(&self.low_priority);
    const timer = msToNextInQueue(&self.timers);
    var result = high orelse low orelse timer orelse return null;
    if (low) |value| result = @min(result, value);
    if (timer) |value| result = @min(result, value);
    return result;
}

fn msToNextInQueue(queue: *Queue) ?u64 {
    const task = queue.peek() orelse return null;
    const now = milliTimestamp(.monotonic);
    if (task.run_at <= now) {
        return 0;
    }
    return @intCast(task.run_at - now);
}

fn runQueue(self: *Scheduler, queue: *Queue, now: u64, gen: u64) !void {
    while (self._generation == gen) {
        if (!try self.runOneFromQueue(queue, now, gen)) break;
    }
}

fn runOneFromQueue(self: *Scheduler, queue: *Queue, now: u64, gen: u64) !bool {
    if (self._generation != gen) return false;
    if (queue.count() == 0) return false;
    const head = queue.peek() orelse return false;
    if (head.run_at > now) return false;

    var task = queue.pop().?;
    if (comptime IS_DEBUG) {
        log.debug(.scheduler, "scheduler.runTask", .{ .name = task.name });
    }

    // Callback may destroy the owning frame/worker and `reset` this scheduler
    // (iframe detach during fingerprint agent). Stop using `queue` after that.
    const repeat_in_ms = task.callback(task.ctx) catch |err| {
        if (self._generation != gen) return false;
        log.warn(.scheduler, "task.callback", .{ .name = task.name, .err = err });
        return true;
    };

    if (self._generation != gen) return false;

    if (repeat_in_ms) |ms| {
        // Debug forbids 0-delay repeats (tight loop). Treat 0 as 1ms.
        const delay: u32 = if (ms == 0) 1 else ms;
        task.run_at = now + delay;
        // Re-arm into the **same** priority queue the task was scheduled with.
        // Page timers (setTimeout/setInterval) use high_priority via AddOpts;
        // requestIdleCallback stays low. No string matching on task.name.
        if (task.source == .timer) {
            try self.timers.push(self.allocator, task);
        } else if (task.low_priority) {
            try self.low_priority.push(self.allocator, task);
        } else {
            try self.high_priority.push(self.allocator, task);
        }
    }
    return true;
}

fn queueHasReadyTask(queue: *Queue, now: u64) bool {
    const task = queue.peek() orelse return false;
    return task.run_at <= now;
}

fn finalizeTasks(queue: *Queue) void {
    var it = queue.iterator();
    while (it.next()) |t| {
        if (t.finalizer) |func| {
            func(t.ctx);
        }
    }
}

const Task = struct {
    run_at: u64,
    sequence: u64,
    ctx: *anyopaque,
    name: []const u8,
    callback: Callback,
    finalizer: ?Finalizer,
    /// When re-arming a repeating task, keep the original priority band.
    low_priority: bool = false,
    source: TaskSource = .generic,
};

pub const Callback = *const fn (ctx: *anyopaque) anyerror!?u32;
const Finalizer = *const fn (ctx: *anyopaque) void;

test "Scheduler: parser turns run non-timer task sources" {
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    const CallbackState = struct {
        generic_ran: bool = false,
        timer_ran: bool = false,

        fn generic(ctx: *anyopaque) !?u32 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.generic_ran = true;
            return null;
        }

        fn timer(ctx: *anyopaque) !?u32 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.timer_ran = true;
            return null;
        }
    };

    var state = CallbackState{};
    try scheduler.add(&state, CallbackState.timer, 0, .{ .source = .timer });
    try scheduler.add(&state, CallbackState.generic, 0, .{});

    try scheduler.runNonTimerTasks();
    try std.testing.expect(state.generic_ran);
    try std.testing.expect(!state.timer_ran);
    try std.testing.expect(scheduler.hasReadyTasks());
    try std.testing.expect(!scheduler.hasReadyNonTimerTasks());

    try scheduler.run();
    try std.testing.expect(state.timer_ran);
}
