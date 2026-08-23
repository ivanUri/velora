const std = @import("std");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../browser/Frame.zig");
const HttpClient = @import("../../../browser/HttpClient.zig");
const LoadGuard = @import("../../../browser/LoadGuard.zig");
const URL = @import("../../../browser/URL.zig");
const DataUrl = @import("../../../browser/DataUrl.zig");
const Event = @import("../../Event.zig");
const Node = @import("../../../dom/Node.zig");
const Element = @import("../../../dom/Element.zig");
const HtmlElement = @import("../Html.zig");
const String = @import("../../../../support/string.zig").String;

const Image = @This();
_proto: *HtmlElement,
_loading: bool = false,
_complete: bool = false,
_failed: bool = false,
_load_url: ?[:0]const u8 = null,
/// Monotonic request generation. Resource completion and its queued event are
/// deliverable only while they still belong to the element's current `src`.
_load_generation: u64 = 0,
/// Intrinsic size after successful load (attr or CSS default object size 300×150).
_natural_width: u32 = 0,
_natural_height: u32 = 0,

fn hasLazyLoading(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t\r\n"), "lazy");
}

pub fn constructor(w_: ?u32, h_: ?u32, frame: *Frame) !*Image {
    const node = try frame.createElementNS(.html, "img", null);
    const el = node.as(Element);

    if (w_) |w| blk: {
        const w_string = std.fmt.bufPrint(&frame.buf, "{d}", .{w}) catch break :blk;
        try el.setAttributeSafe(comptime .wrap("width"), .wrap(w_string), frame);
    }
    if (h_) |h| blk: {
        const h_string = std.fmt.bufPrint(&frame.buf, "{d}", .{h}) catch break :blk;
        try el.setAttributeSafe(comptime .wrap("height"), .wrap(h_string), frame);
    }
    return el.as(Image);
}

pub fn asElement(self: *Image) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Image) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Image) *Node {
    return self.asElement().asNode();
}

pub fn getSrc(self: *const Image, frame: *Frame) ![]const u8 {
    const element = self.asConstElement();
    const src = element.getAttributeSafe(comptime .wrap("src")) orelse return "";
    if (src.len == 0) {
        return "";
    }
    return element.asConstNode().resolveURL(src, frame, .{});
}

pub fn setSrc(self: *Image, value: []const u8, frame: *Frame) !void {
    const element = self.asElement();
    try element.setAttributeSafe(comptime .wrap("src"), .wrap(value), frame);
    // No need to check if `Image` is connected to DOM; this is a special case.
    return self.imageAddedCallback(frame);
}

pub fn getAlt(self: *const Image) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("alt")) orelse "";
}

pub fn setAlt(self: *Image, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("alt"), .wrap(value), frame);
}

// `name` reflects the content attribute of the same name (per HTML spec
// for HTMLImageElement / nameditem semantics).
pub fn getName(self: *const Image) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("name")) orelse "";
}

pub fn setName(self: *Image, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("name"), .wrap(value), frame);
}

/// HTML: rendered CSS-pixel width when laid out; else density-corrected
/// intrinsic width; else 0. Content-attribute alone is not enough — SPAs
/// gate visible images on `img.width > 0` after load.
pub fn getWidth(self: *const Image, frame: *Frame) u32 {
    const el_const = self.asConstElement();
    if (el_const.getAttributeSafe(comptime .wrap("width"))) |raw| {
        if (std.fmt.parseUnsigned(u32, raw, 10) catch null) |w| {
            if (w > 0) return w;
        }
    }
    // Prefer live layout box when connected.
    if (el_const.asConstNode().isConnected()) {
        const el = @constCast(self).asElement();
        const rect = el.getBoundingClientRect(frame);
        if (rect._width > 0.5) return @intFromFloat(@round(rect._width));
    }
    if (self._natural_width > 0) return self._natural_width;
    return 0;
}

pub fn setWidth(self: *Image, value: u32, frame: *Frame) !void {
    const str = try std.fmt.allocPrint(frame.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("width"), .wrap(str), frame);
}

pub fn getHeight(self: *const Image, frame: *Frame) u32 {
    const el_const = self.asConstElement();
    if (el_const.getAttributeSafe(comptime .wrap("height"))) |raw| {
        if (std.fmt.parseUnsigned(u32, raw, 10) catch null) |h| {
            if (h > 0) return h;
        }
    }
    if (el_const.asConstNode().isConnected()) {
        const el = @constCast(self).asElement();
        const rect = el.getBoundingClientRect(frame);
        if (rect._height > 0.5) return @intFromFloat(@round(rect._height));
    }
    if (self._natural_height > 0) return self._natural_height;
    return 0;
}

pub fn setHeight(self: *Image, value: u32, frame: *Frame) !void {
    const str = try std.fmt.allocPrint(frame.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("height"), .wrap(str), frame);
}

pub fn getCrossOrigin(self: *const Image) ?[]const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("crossorigin"));
}

pub fn setCrossOrigin(self: *Image, value: ?[]const u8, frame: *Frame) !void {
    if (value) |v| {
        return self.asElement().setAttributeSafe(comptime .wrap("crossorigin"), .wrap(v), frame);
    }
    return self.asElement().removeAttribute(comptime .wrap("crossorigin"), frame);
}

pub fn getLoading(self: *const Image) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("loading")) orelse "eager";
}

pub fn setLoading(self: *Image, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("loading"), .wrap(value), frame);
}

pub fn getNaturalWidth(self: *const Image) u32 {
    return self._natural_width;
}

pub fn getNaturalHeight(self: *const Image) u32 {
    return self._natural_height;
}

pub fn getComplete(self: *const Image) bool {
    const src = self.asConstElement().getAttributeSafe(comptime .wrap("src")) orelse return true;
    if (src.len == 0) return true;
    return self._complete and !self._loading;
}

const ImageDimensions = struct { w: u32, h: u32 };

/// Prefer width/height content attributes; else CSS default object size 300×150.
fn resolveNaturalDimensions(self: *const Image) ImageDimensions {
    var w: u32 = 0;
    var h: u32 = 0;
    if (self.asConstElement().getAttributeSafe(comptime .wrap("width"))) |raw| {
        w = std.fmt.parseUnsigned(u32, raw, 10) catch 0;
    }
    if (self.asConstElement().getAttributeSafe(comptime .wrap("height"))) |raw| {
        h = std.fmt.parseUnsigned(u32, raw, 10) catch 0;
    }
    // Default object size (CSS Images) when intrinsic pixels are unknown.
    if (w == 0) w = 300;
    if (h == 0) h = 150;
    return .{ .w = w, .h = h };
}

fn readU16Be(bytes: []const u8, at: usize) ?u16 {
    if (at + 2 > bytes.len) return null;
    return (@as(u16, bytes[at]) << 8) | bytes[at + 1];
}

fn readU16Le(bytes: []const u8, at: usize) ?u16 {
    if (at + 2 > bytes.len) return null;
    return @as(u16, bytes[at]) | (@as(u16, bytes[at + 1]) << 8);
}

fn readU24Le(bytes: []const u8, at: usize) ?u32 {
    if (at + 3 > bytes.len) return null;
    return @as(u32, bytes[at]) |
        (@as(u32, bytes[at + 1]) << 8) |
        (@as(u32, bytes[at + 2]) << 16);
}

fn readU32Be(bytes: []const u8, at: usize) ?u32 {
    if (at + 4 > bytes.len) return null;
    return (@as(u32, bytes[at]) << 24) |
        (@as(u32, bytes[at + 1]) << 16) |
        (@as(u32, bytes[at + 2]) << 8) |
        bytes[at + 3];
}

fn validDimensions(w: u32, h: u32) ?ImageDimensions {
    if (w == 0 or h == 0) return null;
    // Reject corrupt headers before their dimensions enter layout arithmetic.
    if (w > 1_000_000 or h > 1_000_000) return null;
    return .{ .w = w, .h = h };
}

/// Read dimensions from encoded image headers without decoding pixels.
/// Supports the formats commonly delivered to browsers by image CDNs.
fn encodedImageDimensions(bytes: []const u8) ?ImageDimensions {
    // PNG: signature + IHDR width/height.
    const png_signature = "\x89PNG\r\n\x1a\n";
    if (bytes.len >= 24 and std.mem.eql(u8, bytes[0..8], png_signature)) {
        return validDimensions(readU32Be(bytes, 16).?, readU32Be(bytes, 20).?);
    }

    // GIF87a / GIF89a logical screen dimensions.
    if (bytes.len >= 10 and
        (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a")))
    {
        return validDimensions(readU16Le(bytes, 6).?, readU16Le(bytes, 8).?);
    }

    // JPEG: scan marker segments until a Start Of Frame marker.
    if (bytes.len >= 4 and bytes[0] == 0xff and bytes[1] == 0xd8) {
        var pos: usize = 2;
        while (pos + 3 < bytes.len) {
            while (pos < bytes.len and bytes[pos] != 0xff) : (pos += 1) {}
            while (pos < bytes.len and bytes[pos] == 0xff) : (pos += 1) {}
            if (pos >= bytes.len) break;
            const marker = bytes[pos];
            pos += 1;
            if (marker == 0xd8 or marker == 0xd9 or marker == 0x01 or
                (marker >= 0xd0 and marker <= 0xd7))
            {
                continue;
            }
            const segment_len = readU16Be(bytes, pos) orelse break;
            if (segment_len < 2 or pos + segment_len > bytes.len) break;
            const is_sof = (marker >= 0xc0 and marker <= 0xc3) or
                (marker >= 0xc5 and marker <= 0xc7) or
                (marker >= 0xc9 and marker <= 0xcb) or
                (marker >= 0xcd and marker <= 0xcf);
            if (is_sof and segment_len >= 7) {
                const h = readU16Be(bytes, pos + 3).?;
                const w = readU16Be(bytes, pos + 5).?;
                return validDimensions(w, h);
            }
            pos += segment_len;
        }
    }

    // WebP extended, lossy, and lossless bitstream headers.
    if (bytes.len >= 30 and
        std.mem.eql(u8, bytes[0..4], "RIFF") and
        std.mem.eql(u8, bytes[8..12], "WEBP"))
    {
        if (std.mem.eql(u8, bytes[12..16], "VP8X")) {
            return validDimensions(readU24Le(bytes, 24).? + 1, readU24Le(bytes, 27).? + 1);
        }
        if (std.mem.eql(u8, bytes[12..16], "VP8 ") and
            bytes[23] == 0x9d and bytes[24] == 0x01 and bytes[25] == 0x2a)
        {
            return validDimensions(
                readU16Le(bytes, 26).? & 0x3fff,
                readU16Le(bytes, 28).? & 0x3fff,
            );
        }
        if (std.mem.eql(u8, bytes[12..16], "VP8L") and bytes[20] == 0x2f) {
            const w = 1 + @as(u32, bytes[21]) + ((@as(u32, bytes[22]) & 0x3f) << 8);
            const h = 1 +
                (@as(u32, bytes[22]) >> 6) +
                (@as(u32, bytes[23]) << 2) +
                ((@as(u32, bytes[24]) & 0x0f) << 10);
            return validDimensions(w, h);
        }
    }

    // AVIF/HEIF stores the display dimensions in an Image Spatial Extents
    // (`ispe`) box. Only accept a complete box with a version/flags field.
    var at: usize = 4;
    while (at + 16 <= bytes.len) : (at += 1) {
        if (!std.mem.eql(u8, bytes[at .. at + 4], "ispe")) continue;
        const box_start = at - 4;
        const box_size = readU32Be(bytes, box_start) orelse continue;
        if (box_size < 20 or box_start + box_size > bytes.len) continue;
        return validDimensions(readU32Be(bytes, at + 8).?, readU32Be(bytes, at + 12).?);
    }

    return null;
}

fn decodedImageDimensions(self: *const Image, bytes: []const u8) ?ImageDimensions {
    if (encodedImageDimensions(bytes)) |dims| return dims;

    // SVG has no binary dimension header. Treat a syntactically recognizable
    // SVG document as decoded and use its explicit attributes/default object
    // size. A 2xx response containing arbitrary HTML/JSON is not an image:
    // browsers fire `error` and keep naturalWidth/naturalHeight at zero.
    const trimmed = std.mem.trimStart(u8, bytes, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "<svg") or
        (std.mem.startsWith(u8, trimmed, "<?xml") and
            std.mem.indexOf(u8, trimmed[0..@min(trimmed.len, 1024)], "<svg") != null))
    {
        return self.resolveNaturalDimensions();
    }
    return null;
}

/// Used in `Page.nodeIsReady`.
pub fn imageAddedCallback(self: *Image, frame: *Frame) !void {
    // if we're planning on navigating to another frame, don't trigger load event.
    if (frame.isGoingAway()) {
        return;
    }

    const element = self.asElement();
    if (!frame.shouldLoadImages()) {
        // A resource policy block is intentional, so expose a completed
        // failed image to script instead of leaving complete=false forever.
        // No network transfer or error event is synthesized here; callers
        // that need the bytes can explicitly fetch the URL themselves.
        self._loading = false;
        self._complete = true;
        self._failed = true;
        self._natural_width = 0;
        self._natural_height = 0;
        return;
    }

    // A headless runtime has no compositor viewport to trigger lazy loading.
    // Defer the request until the frame's post-load scheduler turn instead of
    // starting every image during parse. This keeps the initial burst small
    // while preserving the essential contract that lazy images eventually load.
    const loading = element.getAttributeSafe(comptime .wrap("loading")) orelse "";
    if (hasLazyLoading(loading) or frame.shouldDeferImages()) {
        try frame.deferLazyImage(self);
        return;
    }
    return self.startImageLoad(frame);
}

/// Called by Frame after the document load event to bypass the lazy gate.
pub fn activateDeferredLoad(self: *Image, frame: *Frame) !void {
    return self.startImageLoad(frame);
}

fn startImageLoad(self: *Image, frame: *Frame) !void {
    if (frame.isGoingAway()) return;
    const element = self.asElement();
    const src = element.getAttributeSafe(comptime .wrap("src")) orelse return;
    if (src.len == 0) return;
    const scratch = try frame.getArena(.small, "Image.load");
    var caller_owns_scratch = true;
    errdefer if (caller_owns_scratch) frame.releaseArena(scratch);
    const resolved = try URL.resolve(scratch, frame.base(), src, .{ .encoding = frame.charset });
    const owned_url = try frame.arena.dupeZ(u8, resolved);

    if (self._loading) {
        if (self._load_url) |prev| {
            if (std.mem.eql(u8, prev, owned_url)) {
                frame.releaseArena(scratch);
                return;
            }
        }
    } else if (self._complete) {
        if (self._load_url) |prev| {
            if (std.mem.eql(u8, prev, owned_url)) {
                frame.releaseArena(scratch);
                return;
            }
        }
    }

    self._loading = true;
    self._complete = false;
    self._failed = false;
    self._natural_width = 0;
    self._natural_height = 0;
    self._load_url = owned_url;
    self._load_generation +%= 1;
    if (self._load_generation == 0) self._load_generation = 1;

    const arena = scratch;
    const load = try arena.create(ImageLoad);
    load.* = .{
        .image = self,
        .frame = frame,
        .arena = arena,
        .guard = LoadGuard.Guard.init(&frame.js.execution),
        .generation = self._load_generation,
    };

    // `data:` is a local resource fetch. The image loader captures and decodes
    // it directly; sending it through the HTTP client produces a transport
    // error and incorrectly fires `error` for valid inline images.
    if (std.mem.startsWith(u8, owned_url, "data:")) {
        const bytes = DataUrl.decodeBody(arena, owned_url) catch {
            caller_owns_scratch = false;
            ImageLoad.errorCallback(load, error.InvalidDataUrl);
            return;
        };
        try load.probe.appendSlice(arena, bytes[0..@min(bytes.len, ImageLoad.max_probe_bytes)]);
        load.status = 200;
        caller_owns_scratch = false;
        try ImageLoad.doneCallback(load);
        return;
    }

    const preload_key = try frame.imagePreloadKey(
        arena,
        owned_url,
        self.getCrossOrigin(),
    );
    const preload_use = try frame.useImagePreload(
        preload_key,
        load,
        ImageLoad.preloadResultCallback,
    );
    if (preload_use != .none) {
        // The preload registry owns completion delivery from here. It either
        // called the callback synchronously or retained it as an in-flight
        // waiter, so no second network transfer may be started.
        caller_owns_scratch = false;
        return;
    }

    const session = frame._session;
    const http_client = &session.browser.http_client;
    var headers = try http_client.newHeaders();
    try frame.headersForRequest(&headers, .{
        .request_url = owned_url,
        .resource_type = .image,
        // Plain images use no-CORS. An explicit crossorigin attribute switches
        // the image request to CORS and therefore carries Origin.
        .include_origin_header = self.getCrossOrigin() != null,
    });

    // From this point the ImageLoad callbacks own `scratch`.  Client.request
    // may report a synchronous curl start error after invoking errorCallback;
    // leaving the errdefer armed would then release Image.load a second time.
    // This handoff must happen immediately before entering the async client.
    caller_owns_scratch = false;
    try http_client.request(.{
        .ctx = load,
        .params = .{
            .url = owned_url,
            .method = .GET,
            .frame_id = frame._frame_id,
            .attribution_frame = frame,
            .loader_id = frame._loader_id,
            .headers = headers,
            .cookie_jar = &session.cookie_jar,
            .cookie_origin = frame.url,
            .top_level_cookie_url = frame.topLevelUrl(),
            .resource_type = .image,
            .notification = session.notification,
        },
        .header_callback = ImageLoad.headerCallback,
        .data_callback = ImageLoad.dataCallback,
        .done_callback = ImageLoad.doneCallback,
        .error_callback = ImageLoad.errorCallback,
        .shutdown_callback = ImageLoad.shutdownCallback,
    });
}

const ImageLoad = struct {
    image: *Image,
    frame: *Frame,
    arena: std.mem.Allocator,
    status: u16 = 0,
    guard: LoadGuard.Guard,
    generation: u64,
    probe: std.ArrayList(u8) = .empty,

    const max_probe_bytes = 512 * 1024;

    fn isCurrent(self: *const ImageLoad) bool {
        return self.image._load_generation == self.generation;
    }

    fn deliverable(self: *const ImageLoad) bool {
        const frame = self.frame;
        if (!self.isCurrent()) return false;
        return self.guard.isDeliverableForRealm(.{
            .realm_id = frame._frame_id,
            .epoch = frame._realm_epoch,
            .document_id = frame._loader_id,
        }, .{
            .realm_dead_or_draining = frame._realm_state == .dead or frame._realm_state == .draining,
            .going_away = frame.isGoingAway(),
        });
    }

    fn headerCallback(response: HttpClient.Response) !bool {
        const self: *ImageLoad = @ptrCast(@alignCast(response.ctx));
        self.status = response.status() orelse 0;
        return true;
    }

    fn dataCallback(response: HttpClient.Response, data: []const u8) !void {
        const self: *ImageLoad = @ptrCast(@alignCast(response.ctx));
        if (self.probe.items.len >= max_probe_bytes) return;
        const remaining = max_probe_bytes - self.probe.items.len;
        try self.probe.appendSlice(self.arena, data[0..@min(data.len, remaining)]);
    }

    fn shutdownCallback(ctx: *anyopaque) void {
        const self: *ImageLoad = @ptrCast(@alignCast(ctx));
        // Never leave the element stuck with complete=false — SPA image
        // pipelines treat that as "still loading" and never paint.
        if (self.image._load_generation == self.generation and self.image._loading) {
            self.image._loading = false;
            self.image._complete = true;
            self.image._failed = true;
            self.image._natural_width = 0;
            self.image._natural_height = 0;
        }
        self.finish();
    }

    fn doneCallback(ctx: *anyopaque) !void {
        const self: *ImageLoad = @ptrCast(@alignCast(ctx));
        defer self.finish();
        if (!self.isCurrent()) return;

        const dimensions = if (self.status >= 200 and self.status <= 299)
            self.image.decodedImageDimensions(self.probe.items)
        else
            null;
        try self.scheduleCompletion(if (dimensions) |dims|
            .{ .success = dims }
        else
            .failure);
    }

    fn preloadResultCallback(ctx: *anyopaque, result: Frame.ImagePreloadResult) !void {
        const self: *ImageLoad = @ptrCast(@alignCast(ctx));
        defer self.finish();
        if (!self.isCurrent()) return;

        const dimensions = if (result.ok)
            self.image.decodedImageDimensions(result.probe)
        else
            null;
        if (dimensions) |dims| {
            try self.scheduleCompletion(.{ .success = dims });
        } else if (!result.ok) {
            // A failed resource hint does not make the consumer fail. The
            // registry removes failed entries before notifying waiters, so the
            // image can perform its own normal fetch without recursing back
            // into the failed preload generation.
            try self.scheduleCompletion(.retry);
        } else {
            try self.scheduleCompletion(.failure);
        }
    }

    fn errorCallback(ctx: *anyopaque, _: anyerror) void {
        const self: *ImageLoad = @ptrCast(@alignCast(ctx));
        defer self.finish();
        if (!self.isCurrent()) return;
        self.scheduleCompletion(.failure) catch {};
    }

    fn scheduleCompletion(self: *ImageLoad, result: ImageCompletionCallback.Result) !void {
        const callback = try self.frame.arena.create(ImageCompletionCallback);
        callback.* = .{
            .frame = self.frame,
            .image = self.image,
            .task_owner = self.frame.js.execution.captureTaskOwner(),
            .generation = self.generation,
            .result = result,
        };
        try self.frame.js.scheduler.add(callback, ImageCompletionCallback.run, 0, .{
            .name = "Image.complete",
            .low_priority = false,
        });
    }

    fn finish(self: *ImageLoad) void {
        if (self.guard.isFinished()) return;
        self.guard.finished = true;
        self.frame.releaseArena(self.arena);
    }
};

const ImageCompletionCallback = struct {
    const Result = union(enum) {
        success: ImageDimensions,
        failure,
        retry,
    };

    frame: *Frame,
    image: *Image,
    task_owner: @import("../../../../runtime/RealmLifecycleKernel.zig").TaskOwner,
    generation: u64,
    result: Result,

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ImageCompletionCallback = @ptrCast(@alignCast(ctx));
        if (self.frame.js.execution.isTaskOwnerStale(self.task_owner)) return null;
        if (self.image._load_generation != self.generation) return null;

        if (self.result == .retry) {
            self.image._loading = false;
            self.image._complete = false;
            self.image._failed = false;
            try self.image.imageAddedCallback(self.frame);
            return null;
        }

        self.image._loading = false;
        self.image._complete = true;
        self.image._failed = self.result == .failure;
        const typ = switch (self.result) {
            .success => |dims| blk: {
                self.image._natural_width = dims.w;
                self.image._natural_height = dims.h;
                self.frame.domChanged();
                break :blk String.wrap("load");
            },
            .failure => blk: {
                self.image._natural_width = 0;
                self.image._natural_height = 0;
                break :blk String.wrap("error");
            },
            .retry => unreachable,
        };
        const event = try Event.initTrusted(typ, .{}, self.frame._page);
        try self.frame._event_manager.dispatch(self.image._proto.asEventTarget(), event);
        return null;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Image);

    pub const Meta = struct {
        pub const name = "HTMLImageElement";
        pub const constructor_alias = "Image";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Image.constructor, .{});
    pub const src = bridge.accessor(Image.getSrc, Image.setSrc, .{});
    pub const currentSrc = bridge.accessor(Image.getSrc, null, .{});
    pub const alt = bridge.accessor(Image.getAlt, Image.setAlt, .{});
    pub const name = bridge.accessor(Image.getName, Image.setName, .{});
    pub const width = bridge.accessor(Image.getWidth, Image.setWidth, .{});
    pub const height = bridge.accessor(Image.getHeight, Image.setHeight, .{});
    pub const crossOrigin = bridge.accessor(Image.getCrossOrigin, Image.setCrossOrigin, .{});
    pub const loading = bridge.accessor(Image.getLoading, Image.setLoading, .{});
    pub const naturalWidth = bridge.accessor(Image.getNaturalWidth, null, .{});
    pub const naturalHeight = bridge.accessor(Image.getNaturalHeight, null, .{});
    pub const complete = bridge.accessor(Image.getComplete, null, .{});
};

pub const Build = struct {
    pub fn created(node: *Node, frame: *Frame) !void {
        const self = node.as(Image);
        return self.imageAddedCallback(frame);
    }

    /// React/DOM often set src via setAttribute rather than the IDL setter.
    /// Without this, attributes update but no network load / complete ever runs.
    pub fn attributeChange(element: *Element, name: String, _: String, frame: *Frame) !void {
        if (!name.eql(comptime .wrap("src")) and !name.eql(comptime .wrap("loading"))) return;
        const self = element.as(Image);
        return self.imageAddedCallback(frame);
    }
};

const testing = @import("../../../../testing/testing.zig");
test "WebApi: HTML.Image" {
    try testing.htmlRunner("element/html/image.html", .{});
}

test "Image: encoded dimensions PNG GIF JPEG WebP" {
    const png = [_]u8{
        0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n',
        0,    0,   0,   13,  'I',  'H',  'D',  'R',
        0,    0,   5,   0,   0,    0,    2,    208,
    };
    try std.testing.expectEqual(ImageDimensions{ .w = 1280, .h = 720 }, encodedImageDimensions(&png).?);

    const gif = [_]u8{ 'G', 'I', 'F', '8', '9', 'a', 0x80, 0x02, 0xe0, 0x01 };
    try std.testing.expectEqual(ImageDimensions{ .w = 640, .h = 480 }, encodedImageDimensions(&gif).?);

    const jpeg = [_]u8{
        0xff, 0xd8,
        0xff, 0xe0,
        0x00, 0x04,
        0x00, 0x00,
        0xff, 0xc0,
        0x00, 0x09,
        0x08, 0x02,
        0xd0, 0x05,
        0x00, 0x03,
        0x01,
    };
    try std.testing.expectEqual(ImageDimensions{ .w = 1280, .h = 720 }, encodedImageDimensions(&jpeg).?);

    const webp_vp8x = [_]u8{
        'R',  'I',  'F',  'F',  22,   0,    0, 0, 'W', 'E', 'B', 'P',
        'V',  'P',  '8',  'X',  10,   0,    0, 0, 0,   0,   0,   0,
        0xff, 0x04, 0x00, 0xcf, 0x02, 0x00,
    };
    try std.testing.expectEqual(ImageDimensions{ .w = 1280, .h = 720 }, encodedImageDimensions(&webp_vp8x).?);
}

test "Image: encoded dimensions reject malformed input" {
    try std.testing.expect(encodedImageDimensions("") == null);
    try std.testing.expect(encodedImageDimensions("\x89PNG\r\n\x1a\n") == null);
    try std.testing.expect(encodedImageDimensions("not an image") == null);
}

test "Image: lazy loading token is parsed case-insensitively" {
    try std.testing.expect(hasLazyLoading("lazy"));
    try std.testing.expect(hasLazyLoading(" Lazy \t"));
    try std.testing.expect(!hasLazyLoading("eager"));
    try std.testing.expect(!hasLazyLoading(""));
}
