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
const PixelBuffer = @import("PixelBuffer.zig").PixelBuffer;

// C interface to stb_image_write
// Implementation is in vendor/stb_image_write_impl.c
const c = @cImport({
    @cInclude("../../../vendor/stb_image_write.h");
});

/// Encode a pixel buffer to PNG format.
/// Returns PNG data as a byte slice allocated with the given allocator.
pub fn encodePNG(buffer: *const PixelBuffer, allocator: std.mem.Allocator) ![]u8 {
    if (buffer.width == 0 or buffer.height == 0) {
        return error.InvalidDimensions;
    }

    // stb_image_write_to_func callback context
    const Context = struct {
        data: std.ArrayList(u8),
        allocator: std.mem.Allocator,

        fn writeCallback(context: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
            const ctx = @as(*@This(), @ptrCast(@alignCast(context)));
            const bytes = @as([*]u8, @ptrCast(data))[0..@intCast(size)];
            ctx.data.appendSlice(ctx.allocator, bytes) catch return;
        }
    };

    var data_list: std.ArrayList(u8) = .empty;
    try data_list.ensureTotalCapacity(allocator, 4096); // Pre-allocate reasonable size

    var ctx = Context{
        .data = data_list,
        .allocator = allocator,
    };
    defer ctx.data.deinit(allocator);

    // Call stb_image_write_png_to_func
    // Parameters: callback, context, width, height, components, data, stride_in_bytes
    const result = c.stbi_write_png_to_func(
        Context.writeCallback,
        &ctx,
        @intCast(buffer.width),
        @intCast(buffer.height),
        4, // RGBA = 4 components
        buffer.pixels.ptr,
        @intCast(buffer.width * 4), // stride = width * 4 bytes
    );

    if (result == 0) {
        return error.PngEncodingFailed;
    }

    // Return owned slice
    return try ctx.data.toOwnedSlice(allocator);
}

const testing = @import("../../../testing/testing.zig");

test "PngEncoder: encode empty canvas" {
    const allocator = testing.allocator;

    const buffer = try PixelBuffer.init(1, 1, allocator);
    defer buffer.deinit();

    buffer.clear(.{ .r = 0, .g = 0, .b = 0, .a = 0 });

    const png_data = try encodePNG(buffer, allocator);
    defer allocator.free(png_data);

    // PNG should start with magic bytes
    try testing.expect(png_data.len > 8);
    try testing.expectEqual(@as(u8, 0x89), png_data[0]);
    try testing.expectEqual(@as(u8, 'P'), png_data[1]);
    try testing.expectEqual(@as(u8, 'N'), png_data[2]);
    try testing.expectEqual(@as(u8, 'G'), png_data[3]);
}

test "PngEncoder: encode colored canvas" {
    const allocator = testing.allocator;

    const buffer = try PixelBuffer.init(10, 10, allocator);
    defer buffer.deinit();

    // Fill with red
    buffer.clear(.{ .r = 255, .g = 0, .b = 0, .a = 255 });

    const png_data = try encodePNG(buffer, allocator);
    defer allocator.free(png_data);

    // A solid image compresses very efficiently, so byte length is not a
    // validity signal. Verify the PNG signature and IHDR dimensions instead.
    try testing.expect(png_data.len >= 33);
    try testing.expectEqual(@as(u8, 0x89), png_data[0]);
    try testing.expectEqualStrings("IHDR", png_data[12..16]);
    try testing.expectEqual(@as(u32, 10), std.mem.readInt(u32, png_data[16..20], .big));
    try testing.expectEqual(@as(u32, 10), std.mem.readInt(u32, png_data[20..24], .big));
    try testing.expectEqual(@as(u8, 6), png_data[25]); // RGBA
}

test "PngEncoder: deterministic output" {
    const allocator = testing.allocator;

    const buffer = try PixelBuffer.init(5, 5, allocator);
    defer buffer.deinit();

    buffer.clear(.{ .r = 100, .g = 150, .b = 200, .a = 255 });

    // Encode twice
    const png1 = try encodePNG(buffer, allocator);
    defer allocator.free(png1);

    const png2 = try encodePNG(buffer, allocator);
    defer allocator.free(png2);

    // Should produce identical output
    try testing.expectEqualSlices(u8, png1, png2);
}
