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
const RC = @import("../../support/rc.zig").RC;

const js = @import("../js/js.zig");

const Page = @import("../browser/Page.zig");
const Frame = @import("../browser/Frame.zig");

const Node = @import("../dom/Node.zig");
const Element = @import("../dom/Element.zig");
const DOMRect = @import("../dom/DOMRect.zig");

const log = @import("../../support/log.zig");
const Allocator = std.mem.Allocator;

pub fn registerTypes() []const type {
    return &.{
        IntersectionObserver,
        IntersectionObserverEntry,
    };
}

const IntersectionObserver = @This();

const max_pending_entries: usize = 4096;

_rc: RC(u8) = .{},
_arena: Allocator,
// Owning frame registry. This is cleared before the frame releases its
// registration reference, so a late V8 finalizer cannot leave a stale pointer
// in Frame._intersection_observers.
_registered_frame: ?*Frame = null,
_callback: js.Function.Temp,
_observing: std.ArrayList(*Element) = .empty,
_root: ?*Element = null,
_root_margin: []const u8 = "0px",
_threshold: []const f64 = &.{0.0},
_pending_entries: std.ArrayList(*IntersectionObserverEntry) = .empty,
// Store the last intersection ratio, not only a boolean. Threshold arrays
// must generate callbacks when an element crosses an intermediate ratio while
// remaining intersecting.
_previous_states: std.AutoHashMapUnmanaged(*Element, f64) = .{},

// Shared zero DOMRect to avoid repeated allocations for non-intersecting elements
var zero_rect: DOMRect = .{
    ._x = 0.0,
    ._y = 0.0,
    ._width = 0.0,
    ._height = 0.0,
};

pub const ObserverInit = struct {
    root: ?*Node = null,
    rootMargin: ?[]const u8 = null,
    threshold: Threshold = .{ .scalar = 0.0 },

    const Threshold = union(enum) {
        scalar: f64,
        array: []const f64,
    };
};

pub fn init(callback: js.Function.Temp, options: ?ObserverInit, frame: *Frame) !*IntersectionObserver {
    const arena = try frame.getArena(.small, "IntersectionObserver");
    errdefer frame.releaseArena(arena);

    const opts = options orelse ObserverInit{};
    const root_margin = if (opts.rootMargin) |rm| try arena.dupe(u8, rm) else "0px";

    const threshold = switch (opts.threshold) {
        .scalar => |s| blk: {
            const arr = try arena.alloc(f64, 1);
            arr[0] = s;
            break :blk arr;
        },
        .array => |arr| try arena.dupe(f64, arr),
    };

    const root: ?*Element = blk: {
        const root_opt = opts.root orelse break :blk null;
        switch (root_opt._type) {
            .element => |el| break :blk el,
            .document => {
                // not strictly correct, `null` means the viewport, not the
                // entire document, but since we don't render anything, this
                // should be fine.
                break :blk null;
            },
            else => return error.TypeError,
        }
    };

    const self = try arena.create(IntersectionObserver);
    self.* = .{
        ._arena = arena,
        ._callback = callback,
        ._root = root,
        ._root_margin = root_margin,
        ._threshold = threshold,
    };
    return self;
}

pub fn deinit(self: *IntersectionObserver, page: *Page) void {
    if (self._registered_frame) |frame| {
        frame.detachIntersectionObserver(self);
        self._registered_frame = null;
    }
    self._callback.release();
    for (self._pending_entries.items) |entry| {
        // These were never handed to v8, they do not have a corresponding
        // FinalizerCallback. We 100% own them.
        entry.deinit(page);
    }
    page.releaseArena(self._arena);
}

pub fn releaseRef(self: *IntersectionObserver, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *IntersectionObserver) void {
    self._rc.acquire();
}

pub fn observe(self: *IntersectionObserver, target: *Element, frame: *Frame) !void {
    // Check if already observing this target
    for (self._observing.items) |elem| {
        if (elem == target) {
            return;
        }
    }

    try self._observing.append(self._arena, target);
    if (self._observing.items.len == 1) {
        try frame.registerIntersectionObserver(self);
    }

    // Don't initialize previous state yet - let checkIntersection do it
    // This ensures we get an entry on first observation

    // Check intersection for this new target and schedule delivery
    try self.checkIntersection(target, frame);
    if (self._pending_entries.items.len > 0) {
        try frame.scheduleIntersectionDelivery();
    }
}

pub fn unobserve(self: *IntersectionObserver, target: *Element, frame: *Frame) void {
    const original_length = self._observing.items.len;
    for (self._observing.items, 0..) |elem, i| {
        if (elem == target) {
            _ = self._observing.swapRemove(i);
            _ = self._previous_states.remove(target);

            // Remove any pending entries for this target.
            // Entries will be cleaned up by V8 GC via the finalizer.
            var j: usize = 0;
            while (j < self._pending_entries.items.len) {
                if (self._pending_entries.items[j]._target == target) {
                    const entry = self._pending_entries.swapRemove(j);
                    entry.deinit(frame._page);
                } else {
                    j += 1;
                }
            }
            break;
        }
    }

    if (original_length > 0 and self._observing.items.len == 0) {
        frame.unregisterIntersectionObserver(self);
    }
}

pub fn disconnect(self: *IntersectionObserver, frame: *Frame) void {
    for (self._pending_entries.items) |entry| {
        entry.deinit(frame._page);
    }
    self._pending_entries.clearRetainingCapacity();
    self._previous_states.clearRetainingCapacity();
    self._observing.clearRetainingCapacity();
    frame.unregisterIntersectionObserver(self);
}

pub fn takeRecords(self: *IntersectionObserver, frame: *Frame) ![]*IntersectionObserverEntry {
    const entries = try frame.call_arena.dupe(*IntersectionObserverEntry, self._pending_entries.items);
    self._pending_entries.clearRetainingCapacity();
    return entries;
}

fn calculateIntersection(
    self: *IntersectionObserver,
    target: *Element,
    frame: *Frame,
) !IntersectionData {
    const target_rect = target.getBoundingClientRect(frame);

    const profile = frame.identityProfile();
    const viewport_width = @as(f64, @floatFromInt(profile.window.inner_width));
    const viewport_height = @as(f64, @floatFromInt(profile.window.inner_height));

    const root_rect = if (self._root) |root|
        root.getBoundingClientRect(frame)
    else
        DOMRect{
            ._x = 0.0,
            ._y = 0.0,
            ._width = viewport_width,
            ._height = viewport_height,
        };

    // IntersectionObserver is a viewport contract, not a DOM-connectivity
    // signal.  Treating every connected node as fully visible causes sentinel
    // based infinite lists to fire before the user reaches the sentinel and
    // makes scrolling unable to activate deferred content.
    const has_parent = target.asNode().parentNode() != null;
    if (!has_parent or target_rect._width <= 0 or target_rect._height <= 0) {
        return .{
            .is_intersecting = false,
            .intersection_ratio = 0.0,
            .intersection_rect = zero_rect,
            .bounding_client_rect = target_rect,
            .root_bounds = root_rect,
        };
    }

    const margins = parseRootMargin(self._root_margin, root_rect._width, root_rect._height);
    const root_left = root_rect._x - margins.left;
    const root_top = root_rect._y - margins.top;
    const root_right = root_rect._x + root_rect._width + margins.right;
    const root_bottom = root_rect._y + root_rect._height + margins.bottom;
    const target_right = target_rect._x + target_rect._width;
    const target_bottom = target_rect._y + target_rect._height;
    const left = @max(root_left, target_rect._x);
    const top = @max(root_top, target_rect._y);
    const right = @min(root_right, target_right);
    const bottom = @min(root_bottom, target_bottom);
    const intersection_width = @max(0.0, right - left);
    const intersection_height = @max(0.0, bottom - top);
    const intersection_area = intersection_width * intersection_height;
    const target_area = target_rect._width * target_rect._height;
    const is_intersecting = intersection_width > 0 and intersection_height > 0;
    const intersection_ratio = if (target_area > 0) intersection_area / target_area else 0.0;
    const intersection_rect = if (is_intersecting)
        DOMRect{ ._x = left, ._y = top, ._width = intersection_width, ._height = intersection_height }
    else
        zero_rect;

    return .{
        .is_intersecting = is_intersecting,
        .intersection_ratio = intersection_ratio,
        .intersection_rect = intersection_rect,
        .bounding_client_rect = target_rect,
        .root_bounds = root_rect,
    };
}

const RootMargins = struct { top: f64, right: f64, bottom: f64, left: f64 };
const MarginValue = struct { scalar: f64, percent: bool };

fn parseRootMargin(value: []const u8, root_width: f64, root_height: f64) RootMargins {
    var parsed: [4]MarginValue = .{
        .{ .scalar = 0.0, .percent = false },
        .{ .scalar = 0.0, .percent = false },
        .{ .scalar = 0.0, .percent = false },
        .{ .scalar = 0.0, .percent = false },
    };
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, value, " \t\r\n");
    while (it.next()) |token| {
        if (count == 4) break;
        const is_percent = std.mem.endsWith(u8, token, "%");
        const is_px = std.mem.endsWith(u8, token, "px");
        const number = if (is_percent)
            token[0 .. token.len - 1]
        else if (is_px)
            token[0 .. token.len - 2]
        else
            token;
        const scalar = std.fmt.parseFloat(f64, number) catch return .{
            .top = 0.0,
            .right = 0.0,
            .bottom = 0.0,
            .left = 0.0,
        };
        parsed[count] = .{ .scalar = if (is_percent) scalar / 100.0 else scalar, .percent = is_percent };
        count += 1;
    }
    if (count == 0) return .{ .top = 0.0, .right = 0.0, .bottom = 0.0, .left = 0.0 };
    if (count == 1) {
        parsed[1] = parsed[0];
        parsed[2] = parsed[0];
        parsed[3] = parsed[0];
    } else if (count == 2) {
        parsed[2] = parsed[0];
        parsed[3] = parsed[1];
    } else if (count == 3) {
        parsed[3] = parsed[1];
    }

    // Percentages are relative to the corresponding root dimension.  The
    // parser stores unitless px values as-is and percentage values as ratios;
    // this conversion keeps the geometry calculation allocation-free.
    const top = if (parsed[0].percent) parsed[0].scalar * root_height else parsed[0].scalar;
    const right = if (parsed[1].percent) parsed[1].scalar * root_width else parsed[1].scalar;
    const bottom = if (parsed[2].percent) parsed[2].scalar * root_height else parsed[2].scalar;
    const left = if (parsed[3].percent) parsed[3].scalar * root_width else parsed[3].scalar;
    return .{ .top = top, .right = right, .bottom = bottom, .left = left };
}

const IntersectionData = struct {
    is_intersecting: bool,
    intersection_ratio: f64,
    intersection_rect: DOMRect,
    bounding_client_rect: DOMRect,
    root_bounds: DOMRect,
};

fn meetsThreshold(self: *IntersectionObserver, ratio: f64) bool {
    for (self._threshold) |threshold| {
        if (ratio >= threshold) {
            return true;
        }
    }
    return false;
}

fn checkIntersection(self: *IntersectionObserver, target: *Element, frame: *Frame) !void {
    const data = try self.calculateIntersection(target, frame);
    const was_ratio_opt = self._previous_states.get(target);
    const current_ratio = if (data.is_intersecting) data.intersection_ratio else 0.0;

    // The first observation always queues an entry, including the initial
    // non-intersecting state. Subsequent entries are emitted only when the
    // threshold state changes.
    const crossed_threshold = if (was_ratio_opt) |was_ratio| blk: {
        var crossed = false;
        for (self._threshold) |threshold| {
            if ((was_ratio < threshold and current_ratio >= threshold) or
                (was_ratio >= threshold and current_ratio < threshold))
            {
                crossed = true;
                break;
            }
        }
        break :blk crossed;
    } else false;
    const changed_intersection = if (was_ratio_opt) |was_ratio|
        ((was_ratio > 0.0) != data.is_intersecting)
    else
        true;
    const should_report = changed_intersection or crossed_threshold;

    if (should_report) {
        const arena = try frame.getArena(.tiny, "IntersectionObserverEntry");
        errdefer frame.releaseArena(arena);

        const entry = try arena.create(IntersectionObserverEntry);
        entry.* = .{
            ._arena = arena,
            ._target = target,
            ._time = frame.window._performance.now(),
            ._is_intersecting = data.is_intersecting,
            ._root_bounds = try frame._factory.create(data.root_bounds),
            ._intersection_rect = try frame._factory.create(data.intersection_rect),
            ._bounding_client_rect = try frame._factory.create(data.bounding_client_rect),
            ._intersection_ratio = data.intersection_ratio,
        };
        // A DOM mutation and a scroll checkpoint can both observe the same
        // target before the delivery microtask runs. Keep only the newest
        // entry for each target; retaining every intermediate geometry state
        // lets ad-heavy pages grow the queue until the tiny arena is exhausted.
        var replaced = false;
        for (self._pending_entries.items, 0..) |pending, index| {
            if (pending._target != target) continue;
            pending.deinit(frame._page);
            self._pending_entries.items[index] = entry;
            replaced = true;
            break;
        }
        if (!replaced) {
            if (self._pending_entries.items.len >= max_pending_entries) {
                const oldest = self._pending_entries.orderedRemove(0);
                oldest.deinit(frame._page);
            }
            try self._pending_entries.append(self._arena, entry);
        }
    }

    // Always update the previous state, even if we didn't report
    // This ensures we can detect state changes on subsequent checks
    try self._previous_states.put(self._arena, target, current_ratio);
}

pub fn checkIntersections(self: *IntersectionObserver, frame: *Frame) !void {
    if (self._observing.items.len == 0) {
        return;
    }

    for (self._observing.items) |target| {
        try self.checkIntersection(target, frame);
    }

    if (self._pending_entries.items.len > 0) {
        try frame.scheduleIntersectionDelivery();
    }
}

pub fn deliverEntries(self: *IntersectionObserver, frame: *Frame) !void {
    if (frame._realm_state != .active) return;
    if (self._pending_entries.items.len == 0) {
        return;
    }

    // The callback is allowed to call disconnect()/unobserve(), which can
    // release the frame's registration reference while this dispatch is still
    // on the stack. Keep an explicit in-flight reference so the observer (and
    // its arena-backed callback/entries) cannot be destroyed until the JS
    // callback has returned.
    self.acquireRef();
    defer self.releaseRef(frame._page);

    const entries = try self.takeRecords(frame);
    errdefer for (entries) |entry| entry.deinit(frame._page);

    var caught: js.TryCatch.Caught = undefined;

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    ls.toLocal(self._callback).tryCall(void, .{ entries, self }, &caught) catch |err| {
        log.err(.frame, "IntsctObserver.deliverEntries", .{ .err = err, .caught = caught });
        return err;
    };
}

pub const IntersectionObserverEntry = struct {
    _rc: RC(u8) = .{},
    _arena: Allocator,
    _time: f64,
    _target: *Element,
    _bounding_client_rect: *DOMRect,
    _intersection_rect: *DOMRect,
    _root_bounds: *DOMRect,
    _intersection_ratio: f64,
    _is_intersecting: bool,

    pub fn deinit(self: *IntersectionObserverEntry, page: *Page) void {
        page.releaseArena(self._arena);
    }

    pub fn releaseRef(self: *IntersectionObserverEntry, page: *Page) void {
        self._rc.release(self, page);
    }

    pub fn acquireRef(self: *IntersectionObserverEntry) void {
        self._rc.acquire();
    }

    pub fn getTarget(self: *const IntersectionObserverEntry) *Element {
        return self._target;
    }

    pub fn getTime(self: *const IntersectionObserverEntry) f64 {
        return self._time;
    }

    pub fn getBoundingClientRect(self: *const IntersectionObserverEntry) *DOMRect {
        return self._bounding_client_rect;
    }

    pub fn getIntersectionRect(self: *const IntersectionObserverEntry) *DOMRect {
        return self._intersection_rect;
    }

    pub fn getRootBounds(self: *const IntersectionObserverEntry) ?*DOMRect {
        return self._root_bounds;
    }

    pub fn getIntersectionRatio(self: *const IntersectionObserverEntry) f64 {
        return self._intersection_ratio;
    }

    pub fn getIsIntersecting(self: *const IntersectionObserverEntry) bool {
        return self._is_intersecting;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(IntersectionObserverEntry);

        pub const Meta = struct {
            pub const name = "IntersectionObserverEntry";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const target = bridge.accessor(IntersectionObserverEntry.getTarget, null, .{});
        pub const time = bridge.accessor(IntersectionObserverEntry.getTime, null, .{});
        pub const boundingClientRect = bridge.accessor(IntersectionObserverEntry.getBoundingClientRect, null, .{});
        pub const intersectionRect = bridge.accessor(IntersectionObserverEntry.getIntersectionRect, null, .{});
        pub const rootBounds = bridge.accessor(IntersectionObserverEntry.getRootBounds, null, .{});
        pub const intersectionRatio = bridge.accessor(IntersectionObserverEntry.getIntersectionRatio, null, .{});
        pub const isIntersecting = bridge.accessor(IntersectionObserverEntry.getIsIntersecting, null, .{});
    };
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(IntersectionObserver);

    pub const Meta = struct {
        pub const name = "IntersectionObserver";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(init, .{});

    pub const observe = bridge.function(IntersectionObserver.observe, .{});
    pub const unobserve = bridge.function(IntersectionObserver.unobserve, .{});
    pub const disconnect = bridge.function(IntersectionObserver.disconnect, .{});
    pub const takeRecords = bridge.function(IntersectionObserver.takeRecords, .{});
};

const testing = @import("../../testing/testing.zig");
test "WebApi: IntersectionObserver" {
    try testing.htmlRunner("intersection_observer", .{});
}

test "WebApi: IntersectionObserver scroll checkpoint" {
    try testing.htmlRunner("regression/intersection_observer_scroll.html", .{});
}

test "WebApi: IntersectionObserver callback may disconnect itself" {
    try testing.htmlRunner("regression/intersection_observer_callback_disconnect.html", .{});
}
