const std = @import("std");
const runtime_io = @import("../../../support/io.zig");

const js = @import("../../js/js.zig");
const TaggedOpaque = @import("../../js/TaggedOpaque.zig");

const Blob = @import("../Blob.zig");
const FormData = @import("FormData.zig");
const URLSearchParams = @import("URLSearchParams.zig");
const ReadableStream = @import("../streams/ReadableStream.zig");

const Execution = js.Execution;
const Allocator = std.mem.Allocator;

pub const Materialized = struct {
    bytes: ?[]const u8 = null,
    stream: ?*ReadableStream = null,
    content_type: ?[]const u8 = null,
};

pub fn materialize(body_val: ?js.Value, exec: *const Execution) !Materialized {
    const b = body_val orelse return .{ .bytes = null, .content_type = null };
    if (b.isNullOrUndefined()) return .{ .bytes = null, .content_type = null };

    if (b.isBranded(URLSearchParams)) {
        const usp = try TaggedOpaque.fromJS(*URLSearchParams, @ptrCast(b.toObject().handle));
        var buf = std.Io.Writer.Allocating.init(exec.arena);
        try usp.toString(&buf.writer);
        return .{
            .bytes = try exec.arena.dupe(u8, buf.written()),
            .content_type = "application/x-www-form-urlencoded;charset=UTF-8",
        };
    }

    if (b.isBranded(FormData)) {
        const fd = try TaggedOpaque.fromJS(*FormData, @ptrCast(b.toObject().handle));
        const boundary = try generateBoundary(exec.arena);
        var buf = std.Io.Writer.Allocating.init(exec.arena);
        try fd.write(.{ .encoding = .{ .formdata = boundary } }, &buf.writer);
        const ct = try std.fmt.allocPrint(exec.arena, "multipart/form-data; boundary={s}", .{boundary});
        return .{
            .bytes = try exec.arena.dupe(u8, buf.written()),
            .content_type = ct,
        };
    }

    if (b.isTypedArray() or b.isArrayBufferView() or b.isArrayBuffer()) {
        const bytes = try b.toStringSmart();
        return .{
            .bytes = try exec.arena.dupe(u8, bytes),
            .content_type = null,
        };
    }

    if (b.local.jsValueToZig(*Blob, b) catch null) |blob| {
        const ct: ?[]const u8 = if (blob._mime.len > 0) blob._mime else null;
        return .{
            .bytes = try exec.arena.dupe(u8, blob.getSlice()),
            .content_type = ct,
        };
    }

    if (b.isString() != null) {
        const s = try b.toStringSlice();
        return .{
            .bytes = try exec.arena.dupe(u8, s),
            .content_type = "text/plain;charset=UTF-8",
        };
    }

    if (b.isBranded(ReadableStream)) {
        const stream = try TaggedOpaque.fromJS(*ReadableStream, @ptrCast(b.toObject().handle));
        return .{ .stream = stream };
    }

    return error.InvalidArgument;
}

fn generateBoundary(allocator: Allocator) ![]const u8 {
    var bytes: [16]u8 = undefined;
    runtime_io.get().random(&bytes);
    var hex: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{s}", .{std.fmt.bytesToHex(&bytes, .lower)}) catch unreachable;
    return try std.fmt.allocPrint(allocator, "----kokoboundary{s}", .{hex});
}
