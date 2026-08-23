//
// Adapted for Koko: FileList is a lightweight stub surface; DataTransfer
// keeps the public JS API (items/files/types/getData/setData/clearData) without
// depending on Koko-only FileList tracking.

const std = @import("std");
const RC = @import("../../support/rc.zig").RC;

const js = @import("../js/js.zig");
const Frame = @import("../browser/Frame.zig");
const Page = @import("../browser/Page.zig");

const File = @import("File.zig");
const FileList = @import("FileList.zig");
const DataTransferItem = @import("DataTransferItem.zig");
const DataTransferItemList = @import("DataTransferItemList.zig");

const Allocator = std.mem.Allocator;

const DataTransfer = @This();

pub fn registerTypes() []const type {
    return &.{
        DataTransfer,
        DataTransferItem,
        DataTransferItemList,
    };
}

_arena: Allocator,
_rc: RC(u32) = .{},
_items: std.ArrayList(*DataTransferItem) = .empty,
_item_list: *DataTransferItemList,
_files: *FileList,
_drop_effect: []const u8 = "none",
_effect_allowed: []const u8 = "uninitialized",

pub fn init(frame: *Frame) !*DataTransfer {
    const arena = try frame.getArena(.medium, "DataTransfer");
    errdefer frame.releaseArena(arena);

    const fl = try frame._factory.create(FileList{});
    const self = try arena.create(DataTransfer);
    const list = try arena.create(DataTransferItemList);
    self.* = .{
        ._arena = arena,
        ._item_list = list,
        ._files = fl,
    };
    list.* = .{ ._data_transfer = self };
    return self;
}

pub fn deinit(self: *DataTransfer, page: *Page) void {
    page.releaseArena(self._arena);
}

pub fn acquireRef(self: *DataTransfer) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *DataTransfer, page: *Page) void {
    self._rc.release(self, page);
}

fn normalizeFormat(arena: Allocator, format: []const u8) ![]const u8 {
    if (std.ascii.eqlIgnoreCase(format, "text")) {
        return "text/plain";
    }
    if (std.ascii.eqlIgnoreCase(format, "url")) {
        return "text/uri-list";
    }
    return try arena.dupe(u8, format);
}

pub fn getData(self: *DataTransfer, format: []const u8, frame: *Frame) ![]const u8 {
    const norm = try normalizeFormat(frame.call_arena, format);
    for (self._items.items) |it| {
        if (it._kind == .string and std.ascii.eqlIgnoreCase(it._type, norm)) {
            return it._payload.string;
        }
    }
    return "";
}

pub fn setData(self: *DataTransfer, format: []const u8, data: []const u8, frame: *Frame) !void {
    const norm = try normalizeFormat(self._arena, format);
    const owned = try self._arena.dupe(u8, data);
    // Replace existing string item of the same type.
    for (self._items.items) |it| {
        if (it._kind == .string and std.ascii.eqlIgnoreCase(it._type, norm)) {
            it._payload = .{ .string = owned };
            return;
        }
    }
    const item = try self._arena.create(DataTransferItem);
    item.* = .{
        ._kind = .string,
        ._type = norm,
        ._payload = .{ .string = owned },
        ._data_transfer = self,
    };
    try self._items.append(self._arena, item);
    _ = frame;
}

pub fn clearData(self: *DataTransfer, format_: ?[]const u8, frame: *Frame) !void {
    _ = frame;
    if (format_) |format| {
        const norm = try normalizeFormat(self._arena, format);
        var i: usize = 0;
        while (i < self._items.items.len) {
            const it = self._items.items[i];
            if (it._kind == .string and std.ascii.eqlIgnoreCase(it._type, norm)) {
                _ = self._items.orderedRemove(i);
                continue;
            }
            i += 1;
        }
        return;
    }
    self._items.clearRetainingCapacity();
}

pub fn setDragImage(_: *DataTransfer, _: ?js.Value, _: i32, _: i32) void {}

pub fn getFiles(self: *DataTransfer) *FileList {
    return self._files;
}

pub fn getItems(self: *DataTransfer) *DataTransferItemList {
    return self._item_list;
}

pub fn getTypes(self: *DataTransfer, frame: *Frame) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var has_files = false;
    for (self._items.items) |it| {
        switch (it._kind) {
            .string => try out.append(frame.call_arena, it._type),
            .file => has_files = true,
        }
    }
    if (has_files) {
        try out.append(frame.call_arena, "Files");
    }
    return try out.toOwnedSlice(frame.call_arena);
}

pub fn getDropEffect(self: *const DataTransfer) []const u8 {
    return self._drop_effect;
}

pub fn setDropEffect(self: *DataTransfer, value: []const u8) void {
    const allowed = [_][]const u8{ "none", "copy", "link", "move" };
    for (allowed) |a| {
        if (std.ascii.eqlIgnoreCase(value, a)) {
            self._drop_effect = a;
            return;
        }
    }
}

pub fn getEffectAllowed(self: *const DataTransfer) []const u8 {
    return self._effect_allowed;
}

pub fn setEffectAllowed(self: *DataTransfer, value: []const u8) void {
    const allowed = [_][]const u8{
        "none",     "copy", "copyLink", "copyMove",      "link",
        "linkMove", "move", "all",      "uninitialized",
    };
    for (allowed) |a| {
        if (std.mem.eql(u8, value, a)) {
            self._effect_allowed = a;
            return;
        }
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DataTransfer);

    pub const Meta = struct {
        pub const name = "DataTransfer";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(DataTransfer.init, .{});
    pub const dropEffect = bridge.accessor(DataTransfer.getDropEffect, DataTransfer.setDropEffect, .{});
    pub const effectAllowed = bridge.accessor(DataTransfer.getEffectAllowed, DataTransfer.setEffectAllowed, .{});
    pub const files = bridge.accessor(DataTransfer.getFiles, null, .{});
    pub const items = bridge.accessor(DataTransfer.getItems, null, .{});
    pub const types = bridge.accessor(DataTransfer.getTypes, null, .{});
    pub const getData = bridge.function(DataTransfer.getData, .{});
    pub const setData = bridge.function(DataTransfer.setData, .{});
    pub const clearData = bridge.function(DataTransfer.clearData, .{});
    pub const setDragImage = bridge.function(DataTransfer.setDragImage, .{});
};
