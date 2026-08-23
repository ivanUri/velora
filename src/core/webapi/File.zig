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
const datetime = @import("../../support/datetime.zig");

const js = @import("../js/js.zig");
const Page = @import("../browser/Page.zig");

const Blob = @import("Blob.zig");

const File = @This();

_proto: *Blob,
_name: []const u8,
_last_modified: i64,

pub const InitOptions = struct {
    type: []const u8 = "",
    lastModified: ?f64 = null,
};

pub fn init(
    parts_: ?[]const js.Value,
    file_name: []const u8,
    opts_: ?InitOptions,
    page: *Page,
) !*File {
    const session = page.session;
    const arena = try session.getArena(.large, "File");
    errdefer session.releaseArena(arena);

    const opts: InitOptions = opts_ orelse .{};
    const mime = try Blob.validateMimeType(arena, opts.type, false);

    const data = blk: {
        if (parts_) |blob_parts| {
            var w: std.Io.Writer.Allocating = .init(arena);
            for (blob_parts) |js_val| {
                const part = try js_val.toStringSmart();
                try w.writer.writeAll(part);
            }
            break :blk w.written();
        }
        break :blk "";
    };

    const last_modified: i64 = if (opts.lastModified) |lm| @intFromFloat(lm) else @intCast(datetime.milliTimestamp(.clock));

    const self = try page.factory.blob(arena, File{
        ._proto = undefined,
        ._name = try arena.dupe(u8, file_name),
        ._last_modified = last_modified,
    });
    self._proto.adoptBytes(data, mime);
    return self;
}

pub fn getName(self: *const File) []const u8 {
    return self._name;
}

pub fn getLastModified(self: *const File) f64 {
    return @floatFromInt(self._last_modified);
}

pub fn getDataSlice(self: *const File) []const u8 {
    return self._proto.getSlice();
}

pub fn getDataType(self: *const File) []const u8 {
    return self._proto.getType();
}

pub fn adoptBlobBytes(self: *File, slice: []const u8, mime: []const u8) void {
    self._proto.adoptBytes(slice, mime);
}

pub fn asBlob(self: *const File) *Blob {
    return self._proto;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(File);

    pub const Meta = struct {
        pub const name = "File";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(File.init, .{});
    pub const name = bridge.accessor(File.getName, null, .{});
    pub const lastModified = bridge.accessor(File.getLastModified, null, .{});
};

const testing = @import("../../testing/testing.zig");
test "WebApi: File" {
    try testing.htmlRunner("file.html", .{});
}
