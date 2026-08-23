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
const js = @import("../../../js/js.zig");
const Frame = @import("../../../browser/Frame.zig");
const Node = @import("../../../dom/Node.zig");
const Element = @import("../../../dom/Element.zig");
const HtmlElement = @import("../Html.zig");

const CanvasRenderingContext2D = @import("../../canvas/CanvasRenderingContext2D.zig");
const WebGLRenderingContext = @import("../../canvas/WebGLRenderingContext.zig");
const WebGL2RenderingContext = @import("../../canvas/WebGL2RenderingContext.zig").WebGL2RenderingContext;
const OffscreenCanvas = @import("../../canvas/OffscreenCanvas.zig");
const PixelBuffer = @import("../../canvas/PixelBuffer.zig").PixelBuffer;
const PngEncoder = @import("../../canvas/PngEncoder.zig");
const CanvasIntelligent = @import("../../../../runtime/profile/CanvasIntelligent.zig");

const Execution = js.Execution;

const Canvas = @This();
_proto: *HtmlElement,
_cached: ?DrawingContext = null,
_pixel_buffer: ?*PixelBuffer = null,

pub fn asElement(self: *Canvas) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Canvas) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Canvas) *Node {
    return self.asElement().asNode();
}

pub fn getWidth(self: *const Canvas) u32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("width")) orelse return 300;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 300;
}

pub fn setWidth(self: *Canvas, value: u32, frame: *Frame) !void {
    const old_width = self.getWidth();
    const str = try std.fmt.allocPrint(frame.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("width"), .wrap(str), frame);

    // Reset pixel buffer when dimensions change (Chromium behavior)
    if (old_width != value) {
        self._pixel_buffer = null;
        notifyProbeDimensions(self);
    }
}

fn notifyProbeDimensions(self: *Canvas) void {
    if (self._cached) |cached| {
        switch (cached) {
            .@"2d" => |ctx| {
                ctx._probe.recordDimensions(self.getWidth(), self.getHeight());
            },
            else => {},
        }
    }
}

pub fn getHeight(self: *const Canvas) u32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("height")) orelse return 150;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 150;
}

pub fn setHeight(self: *Canvas, value: u32, frame: *Frame) !void {
    const old_height = self.getHeight();
    const str = try std.fmt.allocPrint(frame.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("height"), .wrap(str), frame);

    // Reset pixel buffer when dimensions change (Chromium behavior)
    if (old_height != value) {
        self._pixel_buffer = null;
        notifyProbeDimensions(self);
    }
}

/// Since there's no base class rendering contexts inherit from,
/// we're using tagged union.
const DrawingContext = union(enum) {
    @"2d": *CanvasRenderingContext2D,
    webgl: *WebGLRenderingContext,
    webgl2: *WebGL2RenderingContext,
};

fn parseContext2dDesynchronized(options: ?js.Value) bool {
    const opts = options orelse return false;
    if (!opts.isObject()) return false;
    const js_obj = opts.toObject();
    const val = js_obj.get("desynchronized") catch return false;
    return val.toBool();
}

pub fn getContext(self: *Canvas, context_type: []const u8, options: ?js.Value, frame: *Frame) !?DrawingContext {
    if (self._cached) |cached| {
        const matches = switch (cached) {
            .@"2d" => std.mem.eql(u8, context_type, "2d"),
            .webgl => std.mem.eql(u8, context_type, "webgl") or std.mem.eql(u8, context_type, "experimental-webgl"),
            .webgl2 => std.mem.eql(u8, context_type, "webgl2"),
        };
        return if (matches) cached else null;
    }

    const drawing_context: DrawingContext = blk: {
        if (std.mem.eql(u8, context_type, "2d")) {
            const ctx = try frame._factory.create(CanvasRenderingContext2D{
                ._canvas = self,
                ._desynchronized = parseContext2dDesynchronized(options),
            });
            break :blk .{ .@"2d" = ctx };
        }

        // Koko is a headless runtime without a compositor/GPU backing store.
        // Returning a partial WebGL object is observably worse than returning
        // null: libraries such as Three.js enter their renderer path, hit a
        // missing method, and retry initialization indefinitely.  null is the
        // browser contract for an unavailable context and lets applications
        // select their non-WebGL fallback without creating a CPU loop.
        if (std.mem.eql(u8, context_type, "webgl") or std.mem.eql(u8, context_type, "experimental-webgl")) {
            return null;
        }

        if (std.mem.eql(u8, context_type, "webgl2")) {
            return null;
        }
        return null;
    };
    self._cached = drawing_context;
    return drawing_context;
}

/// Get or create the pixel buffer for this canvas.
pub fn getOrCreatePixelBuffer(self: *Canvas, frame: *Frame) !*PixelBuffer {
    if (self._pixel_buffer) |buf| return buf;

    const width = self.getWidth();
    const height = self.getHeight();

    // Use page frame_arena for pixel buffer (lives as long as the page)
    const buf = try PixelBuffer.init(width, height, frame._page.frame_arena);

    // Initialize to transparent
    buf.clear(.{ .r = 0, .g = 0, .b = 0, .a = 0 });

    self._pixel_buffer = buf;
    return buf;
}

/// Convert canvas to data URL.
/// Supports "image/png" and "image/jpeg" MIME types.
pub fn toDataURL(
    self: *Canvas,
    mime_type: ?[]const u8,
    quality: ?f64,
    frame: *Frame,
) ![]const u8 {
    _ = quality; // Reserved for JPEG quality in Phase 5
    const mime = mime_type orelse "image/png";

    // For now, only support PNG (JPEG can be added in Phase 5 if needed)
    // Fallback to PNG for unsupported types (Chromium behavior)
    const use_png = !std.mem.eql(u8, mime, "image/jpeg");

    if (!use_png) {
        // JPEG not yet implemented, fallback to PNG
        // TODO: Implement JPEG encoder in Phase 5 if needed
    }

    if (self._cached) |cached| {
        const w = self.getWidth();
        const h = self.getHeight();
        switch (cached) {
            .@"2d" => |ctx| {
                if (CanvasIntelligent.consumeCanvas40ModsDataUrl(&ctx._probe, frame, w, h)) |url| {
                    return url;
                }
                if (w == 75 and h == 75) {
                    if (CanvasIntelligent.consumeCanvas75DataUrl(&ctx._probe, frame, ctx._desynchronized)) |url| {
                        return url;
                    }
                } else if (CanvasIntelligent.shouldUseDataUrlBaseline(ctx._probe, frame)) |url| {
                    return url;
                }
            },
            .webgl => |ctx| {
                const WebGLIntelligent = @import("../../../../runtime/profile/WebGLIntelligent.zig");
                if (WebGLIntelligent.dataUrlBaseline(frame, w, h, ctx._is_webgl2)) |url| {
                    return url;
                }
            },
            .webgl2 => {
                const WebGLIntelligent = @import("../../../../runtime/profile/WebGLIntelligent.zig");
                if (WebGLIntelligent.dataUrlBaseline(frame, w, h, true)) |url| {
                    return url;
                }
            },
        }
    }

    const buffer = try self.getOrCreatePixelBuffer(frame);

    // Encode to PNG
    const png_data = try PngEncoder.encodePNG(buffer, frame.call_arena);

    // Encode to base64
    const encoder = std.base64.standard.Encoder;
    const b64_len = encoder.calcSize(png_data.len);
    const b64_buf = try frame.call_arena.alloc(u8, b64_len);
    const b64 = encoder.encode(b64_buf, png_data);

    // Format as data URL
    return try std.fmt.allocPrint(
        frame.call_arena,
        "data:image/png;base64,{s}",
        .{b64},
    );
}

/// Transfers control of the canvas to an OffscreenCanvas.
/// Returns an OffscreenCanvas with the same dimensions.
pub fn transferControlToOffscreen(self: *Canvas, exec: *Execution) !*OffscreenCanvas {
    const width = self.getWidth();
    const height = self.getHeight();
    return OffscreenCanvas.constructor(width, height, exec);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Canvas);

    pub const Meta = struct {
        pub const name = "HTMLCanvasElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const width = bridge.accessor(Canvas.getWidth, Canvas.setWidth, .{});
    pub const height = bridge.accessor(Canvas.getHeight, Canvas.setHeight, .{});
    pub const getContext = bridge.function(Canvas.getContext, .{});
    pub const toDataURL = bridge.function(Canvas.toDataURL, .{});
    pub const transferControlToOffscreen = bridge.function(Canvas.transferControlToOffscreen, .{});
};
