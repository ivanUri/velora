// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.

const std = @import("std");
const RC = @import("../../support/rc.zig").RC;
const js = @import("../js/js.zig");
const Page = @import("../browser/Page.zig");
const Frame = @import("../browser/Frame.zig");
const Element = @import("../dom/Element.zig");
const DOMRect = @import("../dom/DOMRect.zig");
const log = @import("../../support/log.zig");
const Allocator = std.mem.Allocator;

pub fn registerTypes() []const type {
    return &.{ ResizeObserver, ResizeObserverEntry, ResizeObserverSize };
}

pub const ResizeObserver = @This();

// The JS wrapper and queued deliveries are the only owners. Merely creating
// the observer must not pin its arena after the wrapper is collected.
_rc: RC(u8) = .init(0),
_arena: Allocator,
_callback: js.Function.Temp,
_observing: std.ArrayList(*Element) = .empty,
_delivery_scheduled: bool = false,

pub fn init(callback: js.Function.Temp, frame: *Frame) !*ResizeObserver {
    const arena = try frame.getArena(.small, "ResizeObserver");
    errdefer frame.releaseArena(arena);

    const self = try arena.create(ResizeObserver);
    self.* = .{ ._arena = arena, ._callback = callback };
    return self;
}

pub fn deinit(self: *ResizeObserver, page: *Page) void {
    self._callback.release();
    page.releaseArena(self._arena);
}

pub fn acquireRef(self: *ResizeObserver) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *ResizeObserver, page: *Page) void {
    self._rc.release(self, page);
}

pub const Options = struct {
    box: ?[]const u8 = null,
};

pub fn observe(self: *ResizeObserver, element: *Element, options: ?Options, frame: *Frame) !void {
    _ = options;
    for (self._observing.items) |target| {
        if (target == element) return;
    }
    try self._observing.append(self._arena, element);
    try self.scheduleDelivery(frame);
}

pub fn unobserve(self: *ResizeObserver, element: *Element) void {
    for (self._observing.items, 0..) |target, i| {
        if (target == element) {
            _ = self._observing.swapRemove(i);
            return;
        }
    }
}

pub fn disconnect(self: *ResizeObserver) void {
    self._observing.clearRetainingCapacity();
}

fn scheduleDelivery(self: *ResizeObserver, frame: *Frame) !void {
    if (self._delivery_scheduled) return;
    self._delivery_scheduled = true;

    const arena = try frame.getArena(.tiny, "ResizeObserver.delivery");
    errdefer frame.releaseArena(arena);
    const task = try arena.create(DeliveryTask);
    task.* = .{ .observer = self, .frame = frame, .arena = arena };
    self.acquireRef();
    errdefer self.releaseRef(frame._page);

    try frame.js.scheduler.add(task, DeliveryTask.run, 0, .{
        .name = "ResizeObserver.delivery",
        .low_priority = false,
        .finalizer = DeliveryTask.cancelled,
    });
}

const DeliveryTask = struct {
    observer: *ResizeObserver,
    frame: *Frame,
    arena: Allocator,

    fn cleanup(self: *DeliveryTask) void {
        const observer = self.observer;
        const frame = self.frame;
        const arena = self.arena;
        frame.releaseArena(arena);
        observer.releaseRef(frame._page);
    }

    fn cancelled(ctx: *anyopaque) void {
        const self: *DeliveryTask = @ptrCast(@alignCast(ctx));
        self.observer._delivery_scheduled = false;
        self.cleanup();
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DeliveryTask = @ptrCast(@alignCast(ctx));
        self.observer._delivery_scheduled = false;
        defer self.cleanup();
        if (self.frame._realm_state != .active) return null;
        self.observer.deliver(self.frame) catch |err| {
            log.err(.frame, "ResizeObserver.deliver", .{ .err = err });
        };
        return null;
    }
};

fn deliver(self: *ResizeObserver, frame: *Frame) !void {
    if (self._observing.items.len == 0) return;

    const entries = try frame.call_arena.alloc(*ResizeObserverEntry, self._observing.items.len);
    for (self._observing.items, 0..) |target, i| {
        const rect = target.getBoundingClientRect(frame);
        const size = try frame._factory.create(ResizeObserverSize{
            ._inline_size = rect._width,
            ._block_size = rect._height,
        });
        const entry = try frame._factory.create(ResizeObserverEntry{
            ._target = target,
            ._content_rect = try frame._factory.create(rect),
            ._content_box_size = size,
            ._border_box_size = size,
            ._device_pixel_content_box_size = size,
        });
        entries[i] = entry;
    }

    var caught: js.TryCatch.Caught = undefined;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    ls.toLocal(self._callback).tryCall(void, .{ entries, self }, &caught) catch |err| {
        log.err(.frame, "ResizeObserver.callback", .{ .err = err, .caught = caught });
        return err;
    };
}

pub const ResizeObserverSize = struct {
    _inline_size: f64,
    _block_size: f64,

    pub fn getInlineSize(self: *const ResizeObserverSize) f64 {
        return self._inline_size;
    }
    pub fn getBlockSize(self: *const ResizeObserverSize) f64 {
        return self._block_size;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ResizeObserverSize);
        pub const Meta = struct {
            pub const name = "ResizeObserverSize";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const inlineSize = bridge.accessor(ResizeObserverSize.getInlineSize, null, .{});
        pub const blockSize = bridge.accessor(ResizeObserverSize.getBlockSize, null, .{});
    };
};

pub const ResizeObserverEntry = struct {
    _target: *Element,
    _content_rect: *DOMRect,
    _content_box_size: *ResizeObserverSize,
    _border_box_size: *ResizeObserverSize,
    _device_pixel_content_box_size: *ResizeObserverSize,

    pub fn getTarget(self: *const ResizeObserverEntry) *Element {
        return self._target;
    }
    pub fn getContentRect(self: *const ResizeObserverEntry) *DOMRect {
        return self._content_rect;
    }
    // Browsers expose these as one-element frozen arrays. The bridge converts
    // slices to JavaScript arrays, preserving that observable API shape.
    pub fn getContentBoxSize(self: *const ResizeObserverEntry) []const *ResizeObserverSize {
        return @ptrCast(&self._content_box_size);
    }
    pub fn getBorderBoxSize(self: *const ResizeObserverEntry) []const *ResizeObserverSize {
        return @ptrCast(&self._border_box_size);
    }
    pub fn getDevicePixelContentBoxSize(self: *const ResizeObserverEntry) []const *ResizeObserverSize {
        return @ptrCast(&self._device_pixel_content_box_size);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ResizeObserverEntry);
        pub const Meta = struct {
            pub const name = "ResizeObserverEntry";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const target = bridge.accessor(ResizeObserverEntry.getTarget, null, .{});
        pub const contentRect = bridge.accessor(ResizeObserverEntry.getContentRect, null, .{});
        pub const contentBoxSize = bridge.accessor(ResizeObserverEntry.getContentBoxSize, null, .{});
        pub const borderBoxSize = bridge.accessor(ResizeObserverEntry.getBorderBoxSize, null, .{});
        pub const devicePixelContentBoxSize = bridge.accessor(ResizeObserverEntry.getDevicePixelContentBoxSize, null, .{});
    };
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(ResizeObserver);
    pub const Meta = struct {
        pub const name = "ResizeObserver";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const constructor = bridge.constructor(ResizeObserver.init, .{});
    pub const observe = bridge.function(ResizeObserver.observe, .{});
    pub const unobserve = bridge.function(ResizeObserver.unobserve, .{});
    pub const disconnect = bridge.function(ResizeObserver.disconnect, .{});
};
