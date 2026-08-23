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
const runtime_io = @import("../../../support/io.zig");
const RC = @import("../../../support/rc.zig").RC;
const js = @import("../../js/js.zig");

const HttpClient = @import("../../browser/HttpClient.zig");
const http = @import("../../../runtime/network/http.zig");

const URL = @import("../../browser/URL.zig");
const Mime = @import("../../browser/Mime.zig");
const Page = @import("../../browser/Page.zig");

const Node = @import("../../dom/Node.zig");
const Event = @import("../Event.zig");
const Headers = @import("Headers.zig");
const EventTarget = @import("../EventTarget.zig");
const XMLHttpRequestEventTarget = @import("XMLHttpRequestEventTarget.zig");
const XMLHttpRequestUpload = @import("XMLHttpRequestUpload.zig");

const log = @import("../../../support/log.zig");
const Execution = js.Execution;
const RealmLifecycleKernel = @import("../../../runtime/RealmLifecycleKernel.zig");
const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

const XMLHttpRequest = @This();
_rc: RC(u8) = .{},
_exec: *const Execution,
_proto: *XMLHttpRequestEventTarget,
_upload: ?*XMLHttpRequestUpload = null,
_arena: Allocator,
_http_response: ?HttpClient.Response = null,
_active_request: bool = false,
_send_flag: bool = false,
_request_generation: u64 = 0,
_active_request_generation: u64 = 0,
/// Realm generation that initiated the active transfer. Network callbacks may
/// arrive after a navigation has reused the same Execution object.
_task_owner: ?RealmLifecycleKernel.TaskOwner = null,
_queued_completion_generation: ?u64 = null,

_url: [:0]const u8 = "",
_method: http.Method = .GET,
_request_headers: *Headers,
_request_body: ?[]const u8 = null,

_response: ?Response = null,
_response_data: std.ArrayList(u8) = .empty,
_response_status: u16 = 0,
_response_len: ?usize = 0,
_response_url: [:0]const u8 = "",
_response_mime: ?Mime = null,
_response_headers: std.ArrayList([]const u8) = .empty,
_response_type: ResponseType = .text,

_ready_state: ReadyState = .unsent,
_on_ready_state_change: ?js.Function.Temp = null,
_with_credentials: bool = false,
_timeout: u32 = 0,

const ReadyState = enum(u8) {
    unsent = 0,
    opened = 1,
    headers_received = 2,
    loading = 3,
    done = 4,
};

const Response = union(ResponseType) {
    text: []const u8,
    json: js.Value.Global,
    document: *Node.Document,
    arraybuffer: js.ArrayBuffer,
};

const ResponseType = enum {
    text,
    json,
    document,
    arraybuffer,
    // TODO: other types to support
};

pub fn init(exec: *const Execution) !*XMLHttpRequest {
    const arena = try exec.getArena(.large, "XMLHttpRequest");
    errdefer exec.releaseArena(arena);
    const self = try exec._factory.xhrEventTarget(arena, XMLHttpRequest{
        ._exec = exec,
        ._arena = arena,
        ._proto = undefined,
        ._request_headers = try Headers.init(null, exec),
    });
    return self;
}

// https://xhr.spec.whatwg.org/#the-upload-attribute
// Lazy + cached so listeners attached to xhr.upload stick across accesses.
pub fn getUpload(self: *XMLHttpRequest) !*XMLHttpRequestUpload {
    if (self._upload) |upload| return upload;
    const upload = try self._exec._factory.xhrEventTarget(
        self._arena,
        XMLHttpRequestUpload{ ._proto = undefined, ._xhr = self },
    );
    self._upload = upload;
    return upload;
}

pub fn deinit(self: *XMLHttpRequest, page: *Page) void {
    // Mark finished so httpErrorCallback / handleError skip JS event dispatch.
    // Page teardown force_deinit aborts the transfer after destroyContext; firing
    // readystatechange would call Context.localScope on a null V8 context
    // (reason: cast causes pointer to be null — nytimes.com SPA navigations).
    self._active_request = false;
    if (self._http_response) |resp| {
        self._http_response = null;
        resp.abort(error.Abort);
    }

    if (self._on_ready_state_change) |func| {
        func.release();
    }

    {
        const proto = self._proto;
        if (proto._on_abort) |func| {
            func.release();
        }
        if (proto._on_error) |func| {
            func.release();
        }
        if (proto._on_load) |func| {
            func.release();
        }
        if (proto._on_load_end) |func| {
            func.release();
        }
        if (proto._on_load_start) |func| {
            func.release();
        }
        if (proto._on_progress) |func| {
            func.release();
        }
        if (proto._on_timeout) |func| {
            func.release();
        }
    }

    page.releaseArena(self._arena);
}

fn releaseSelfRef(self: *XMLHttpRequest) void {
    if (self._active_request == false) {
        return;
    }
    self.releaseSelfRefForGeneration(self._active_request_generation);
}

fn releaseSelfRefForGeneration(self: *XMLHttpRequest, generation: u64) void {
    self.releaseRef(self._exec.context.page);
    if (self._active_request and self._active_request_generation == generation) {
        self._active_request = false;
        self._task_owner = null;
    }
}

pub fn releaseRef(self: *XMLHttpRequest, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *XMLHttpRequest) void {
    self._rc.acquire();
}

fn asEventTarget(self: *XMLHttpRequest) *EventTarget {
    return self._proto._proto;
}

pub fn getOnReadyStateChange(self: *const XMLHttpRequest) ?js.Function.Temp {
    return self._on_ready_state_change;
}

pub fn setOnReadyStateChange(self: *XMLHttpRequest, cb_: ?js.Function) !void {
    if (cb_) |cb| {
        self._on_ready_state_change = try cb.tempWithThis(self);
    } else {
        self._on_ready_state_change = null;
    }
}

pub fn getWithCredentials(self: *const XMLHttpRequest) bool {
    return self._with_credentials;
}

pub fn setWithCredentials(self: *XMLHttpRequest, value: bool) !void {
    if (self._ready_state != .unsent and self._ready_state != .opened) {
        return error.InvalidStateError;
    }
    self._with_credentials = value;
}

pub fn getTimeout(self: *const XMLHttpRequest) u32 {
    return self._timeout;
}

pub fn setTimeout(self: *XMLHttpRequest, value: u32) void {
    self._timeout = value;
}

// TODO: this takes an optional 3 more parameters
// TODO: url should be a union, as it can be multiple things
pub fn open(self: *XMLHttpRequest, method_: []const u8, url: [:0]const u8) !void {
    // Abort any in-progress request
    if (self._http_response) |transfer| {
        transfer.abort(error.Abort);
        self._http_response = null;
    }

    // Reset internal state
    self._response = null;
    self._response_data.clearRetainingCapacity();
    self._response_status = 0;
    self._response_len = 0;
    self._response_url = "";
    self._response_mime = null;
    self._response_headers.clearRetainingCapacity();
    self._request_body = null;
    self._send_flag = false;
    self._request_generation +%= 1;

    const exec = self._exec;
    self._method = try parseMethod(method_);
    self._url = try URL.resolve(self._arena, exec.base(), url, .{ .always_dupe = true, .encoding = exec.charset.* });
    try self.stateChanged(.opened, exec);
}

pub fn setRequestHeader(self: *XMLHttpRequest, name: []const u8, value: []const u8, exec: *const Execution) !void {
    if (self._ready_state != .opened) {
        return error.InvalidStateError;
    }
    return self._request_headers.append(name, value, exec);
}

pub fn send(self: *XMLHttpRequest, body_: ?[]const u8) !void {
    if (comptime IS_DEBUG) {
        log.debug(.http, "XMLHttpRequest.send", .{
            .url = self._url,
            .body_len = if (body_) |body| body.len else 0,
        });
    }
    if (self._ready_state != .opened or self._send_flag) {
        return error.InvalidStateError;
    }

    if (body_) |b| {
        if (self._method != .GET and self._method != .HEAD) {
            self._request_body = try self._arena.dupe(u8, b);
        }
    }

    const exec = self._exec;

    if (std.mem.startsWith(u8, self._url, "blob:")) {
        return self.handleBlobUrl(exec);
    }

    const session = exec.context.page.session;
    const http_client = &session.browser.http_client;
    var headers = try http_client.newHeaders();

    // Only add cookies for same-origin or when withCredentials is true
    const cookie_support = self._with_credentials or exec.isSameOrigin(self._url);

    // XHR `send()` extracts a string BodyInit as UTF-8 text. If the author did
    // not provide Content-Type, the body extraction algorithm supplies this
    // default before the request reaches the HTTP transport. Leaving it absent
    // lets libcurl invent application/x-www-form-urlencoded for POST, which is
    // not browser behaviour and changes the request's representation metadata.
    if (needsDefaultStringBodyContentType(
        self._method,
        self._request_body != null,
        try self._request_headers.get("content-type", exec) != null,
    )) {
        try self._request_headers.set("content-type", "text/plain;charset=UTF-8", exec);
    }

    try self._request_headers.populateHttpHeader(exec.call_arena, &headers, exec.buf);
    // XMLHttpRequest is revalidated by default. Chromium emits these
    // transport cache directives for author-created XHRs so an intermediary
    // cannot satisfy the request from a stale representation. Keep explicit
    // author headers authoritative.
    if (try self._request_headers.get("cache-control", exec) == null) {
        try headers.add("Cache-Control: no-cache");
    }
    if (try self._request_headers.get("pragma", exec) == null) {
        try headers.add("Pragma: no-cache");
    }
    const xhr_cross_origin = !exec.isSameOrigin(self._url);
    const xhr_unsafe_method = self._method != .GET and self._method != .HEAD;
    try exec.headersForRequest(&headers, .{
        .request_url = self._url,
        .resource_type = .xhr,
        .include_origin_header = xhr_cross_origin or xhr_unsafe_method,
    });

    self.acquireRef();
    self._active_request = true;
    self._active_request_generation = self._request_generation;
    self._task_owner = exec.captureTaskOwner();
    self._send_flag = true;

    http_client.request(.{
        .ctx = self,
        .params = .{
            .url = self._url,
            .method = self._method,
            .headers = headers,
            .frame_id = exec.frameId(),
            .loader_id = exec.loaderId(),
            .body = self._request_body,
            .cookie_jar = if (cookie_support) &session.cookie_jar else null,
            .cookie_origin = exec.url.*,
            .top_level_cookie_url = exec.topLevelCookieUrl(),
            .resource_type = .xhr,
            .timeout_ms = self._timeout,
            .notification = session.notification,
            .protect_from_abort = false,
            .attribution_frame = exec.attributionFrame(),
        },
        .start_callback = httpStartCallback,
        .header_callback = httpHeaderDoneCallback,
        .data_callback = httpDataCallback,
        .done_callback = httpDoneCallback,
        .error_callback = httpErrorCallback,
        .shutdown_callback = httpShutdownCallback,
    }) catch |err| {
        self.releaseSelfRef();
        self._send_flag = false;
        return err;
    };
}

fn handleBlobUrl(self: *XMLHttpRequest, exec: *const Execution) !void {
    const blob = exec.lookupBlobUrl(self._url) orelse {
        self.handleError(error.BlobNotFound);
        return;
    };

    self._response_status = 200;
    self._response_url = self._url;

    try self._response_data.appendSlice(self._arena, blob._slice);
    self._response_len = blob._slice.len;

    try self.stateChanged(.headers_received, exec);
    try self._proto.dispatch(.load_start, .{ .loaded = 0, .total = self._response_len orelse 0 }, exec);
    try self.stateChanged(.loading, exec);
    try self._proto.dispatch(.progress, .{
        .total = self._response_len orelse 0,
        .loaded = self._response_data.items.len,
    }, exec);
    try self.stateChanged(.done, exec);

    const loaded = self._response_data.items.len;
    try self._proto.dispatch(.load, .{
        .total = loaded,
        .loaded = loaded,
    }, exec);
    try self._proto.dispatch(.load_end, .{
        .total = loaded,
        .loaded = loaded,
    }, exec);
}

pub fn getReadyState(self: *const XMLHttpRequest) u32 {
    return @intFromEnum(self._ready_state);
}

pub fn getResponseHeader(self: *const XMLHttpRequest, name: []const u8) ?[]const u8 {
    for (self._response_headers.items) |entry| {
        if (entry.len <= name.len) {
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, entry[0..name.len]) == false) {
            continue;
        }
        if (entry[name.len] != ':') {
            continue;
        }
        return std.mem.trimStart(u8, entry[name.len + 1 ..], " ");
    }
    return null;
}

pub fn getAllResponseHeaders(self: *const XMLHttpRequest, exec: *const Execution) ![]const u8 {
    // Chrome exposes headers once readyState >= HEADERS_RECEIVED (2).
    if (@intFromEnum(self._ready_state) < @intFromEnum(ReadyState.headers_received)) {
        return "";
    }

    var buf = std.Io.Writer.Allocating.init(exec.call_arena);
    for (self._response_headers.items) |entry| {
        try buf.writer.writeAll(entry);
        try buf.writer.writeAll("\r\n");
    }
    return buf.written();
}

pub fn getResponseType(self: *const XMLHttpRequest) []const u8 {
    if (self._ready_state != .done) {
        return "";
    }
    return @tagName(self._response_type);
}

pub fn setResponseType(self: *XMLHttpRequest, value: []const u8) void {
    if (std.meta.stringToEnum(ResponseType, value)) |rt| {
        self._response_type = rt;
    }
}

pub fn getResponseText(self: *const XMLHttpRequest) []const u8 {
    return self._response_data.items;
}

pub fn getStatus(self: *const XMLHttpRequest) u16 {
    return self._response_status;
}

pub fn getStatusText(self: *const XMLHttpRequest) []const u8 {
    return std.http.Status.phrase(@enumFromInt(self._response_status)) orelse "";
}

pub fn getResponseURL(self: *XMLHttpRequest) []const u8 {
    return self._response_url;
}

pub fn getResponse(self: *XMLHttpRequest, exec: *const Execution) !?Response {
    if (self._ready_state != .done) {
        return null;
    }

    if (self._response) |res| {
        // was already loaded
        return res;
    }

    const data = self._response_data.items;
    const res: Response = switch (self._response_type) {
        .text => .{ .text = data },
        .json => blk: {
            const value = try exec.context.local.?.parseJSON(data);
            break :blk .{ .json = try value.persist() };
        },
        .document => blk: {
            // responseType=document is only meaningful in a Frame; workers
            // have no DOM. Drastically different impls -> switch on global.
            switch (exec.context.global) {
                .frame => |frame| {
                    const document = try exec._factory.node(Node.Document{ ._proto = undefined, ._type = .generic });
                    try frame.parseHtmlAsChildren(document.asNode(), data);
                    break :blk .{ .document = document };
                },
                .worker => return error.NotSupportedInWorker,
            }
        },
        .arraybuffer => .{ .arraybuffer = .{ .values = data } },
    };

    self._response = res;
    return res;
}

pub fn getResponseXML(self: *XMLHttpRequest, exec: *const Execution) !?*Node.Document {
    const res = (try self.getResponse(exec)) orelse return null;
    return switch (res) {
        .document => |doc| doc,
        else => null,
    };
}

fn httpStartCallback(response: HttpClient.Response) !void {
    const self: *XMLHttpRequest = @ptrCast(@alignCast(response.ctx));
    if (comptime IS_DEBUG) {
        log.debug(.http, "request start", .{
            .method = self._method,
            .url = self._url,
            .source = "xhr",
            .body_len = if (self._request_body) |body| body.len else 0,
        });
    }
    self._http_response = response;
}

fn needsDefaultStringBodyContentType(method: http.Method, has_body: bool, has_content_type: bool) bool {
    return has_body and !has_content_type and method != .GET and method != .HEAD;
}

fn httpHeaderCallback(response: HttpClient.Response, header: http.Header) !void {
    const self: *XMLHttpRequest = @ptrCast(@alignCast(response.ctx));
    const joined = try std.fmt.allocPrint(self._arena, "{s}: {s}", .{ header.name, header.value });
    try self._response_headers.append(self._arena, joined);
}

fn httpHeaderDoneCallback(response: HttpClient.Response) !bool {
    const self: *XMLHttpRequest = @ptrCast(@alignCast(response.ctx));

    if (comptime IS_DEBUG) {
        log.debug(.http, "request header", .{
            .source = "xhr",
            .url = self._url,
            .status = response.status(),
        });
    }

    if (response.contentType()) |ct| {
        self._response_mime = Mime.parse(ct) catch |e| {
            log.info(.http, "invalid content type", .{
                .content_Type = ct,
                .err = e,
                .url = self._url,
            });
            return false;
        };
    }

    var it = response.headerIterator();
    while (it.next()) |hdr| {
        const joined = try std.fmt.allocPrint(self._arena, "{s}: {s}", .{ hdr.name, hdr.value });
        try self._response_headers.append(self._arena, joined);
    }

    self._response_status = response.status().?;
    if (response.contentLength()) |cl| {
        self._response_len = cl;
        try self._response_data.ensureTotalCapacity(self._arena, cl);
    }
    self._response_url = try self._arena.dupeZ(u8, response.url());

    const exec = self._exec;
    if (!canDispatchXhrEvents(self, exec)) {
        if (self._ready_state != .headers_received) self._ready_state = .headers_received;
        self._ready_state = .loading;
        return true;
    }

    const ctx = exec.context;
    const nested_in_api = ctx.local != null;
    var owned_scope: js.Local.Scope = undefined;
    if (!nested_in_api) ctx.localScope(&owned_scope);
    defer if (!nested_in_api) owned_scope.deinit();

    try self.stateChanged(.headers_received, exec);
    try self._proto.dispatch(.load_start, .{ .loaded = 0, .total = self._response_len orelse 0 }, exec);
    try self.stateChanged(.loading, exec);

    return true;
}

fn httpDataCallback(response: HttpClient.Response, data: []const u8) !void {
    const self: *XMLHttpRequest = @ptrCast(@alignCast(response.ctx));
    try self._response_data.appendSlice(self._arena, data);

    const exec = self._exec;
    if (!canDispatchXhrEvents(self, exec)) return;

    try self._proto.dispatch(.progress, .{
        .total = self._response_len orelse 0,
        .loaded = self._response_data.items.len,
    }, exec);

    // Progressive responseText becomes observable at each LOADING update.
    if (self._ready_state == .loading) {
        try self.dispatchReadyStateChange(exec);
    }
}

fn httpDoneCallback(ctx: *anyopaque) !void {
    const self: *XMLHttpRequest = @ptrCast(@alignCast(ctx));

    log.info(.http, "request complete", .{
        .source = "xhr",
        .url = self._url,
        .status = self._response_status,
        .len = self._response_data.items.len,
    });

    if (self._response_status >= 400) {
        traceErrorExchange(self) catch |err| {
            log.warn(.http, "XHR error trace", .{
                .url = self._url,
                .status = self._response_status,
                .err = err,
            });
        };
    }

    // Not that the request is done, the http/client will free the transfer
    // object. It isn't safe to keep it around.
    self._http_response = null;

    const exec = self._exec;

    if (canDispatchXhrEvents(self, exec)) {
        defer self.releaseSelfRef();
        try self.dispatchSuccessfulCompletion();
        return;
    }

    // Curl may finish while another JS entry is active (notably a CDP
    // Runtime.evaluate poll). Dropping the events here leaves readyState=4 but
    // permanently loses onload/loadend; SPA bootstrap loaders then never append
    // their main bundle. Queue one HTML task and keep the request's self-ref
    // until that task either dispatches or is cancelled by realm teardown.
    try self.queueSuccessfulCompletion();
}

/// Opt-in raw capture for diagnosing rejected XHR exchanges. The XHR owns the
/// request body and accumulated response state until `httpDoneCallback`
/// returns, so this is the last lifecycle point where both sides can be
/// serialized without retaining transfer or realm memory. Wire-level request
/// headers are captured separately by `KOKO_WIRE_HEADERS`.
fn traceErrorExchange(self: *const XMLHttpRequest) !void {
    const trace_dir = runtime_io.getenv("KOKO_HTTP_ERROR_TRACE_DIR") orelse return;
    const io = runtime_io.get();
    try std.Io.Dir.cwd().createDirPath(io, trace_dir);

    const stem = try std.fmt.allocPrint(
        self._arena,
        "{x}-{d}-{d}",
        .{ @intFromPtr(self), self._request_generation, self._response_status },
    );

    const metadata_path = try std.fmt.allocPrint(
        self._arena,
        "{s}/{s}.metadata.txt",
        .{ trace_dir, stem },
    );
    const request_body_path = try std.fmt.allocPrint(
        self._arena,
        "{s}/{s}.request.body",
        .{ trace_dir, stem },
    );
    const response_body_path = try std.fmt.allocPrint(
        self._arena,
        "{s}/{s}.response.body",
        .{ trace_dir, stem },
    );

    const metadata = try std.Io.Dir.cwd().createFile(io, metadata_path, .{ .truncate = true });
    defer metadata.close(io);

    var buf: [4096]u8 = undefined;
    var writer = metadata.writer(io, &buf);
    try writer.interface.print(
        "method: {s}\nurl: {s}\nresponse-url: {s}\nstatus: {d}\nrequest-body-length: {d}\nresponse-body-length: {d}\nresponse-headers:\n",
        .{
            @tagName(self._method),
            self._url,
            self._response_url,
            self._response_status,
            if (self._request_body) |body| body.len else 0,
            self._response_data.items.len,
        },
    );
    for (self._response_headers.items) |header| {
        try writer.interface.print("{s}\n", .{header});
    }
    try writer.interface.flush();

    const request_body_file = try std.Io.Dir.cwd().createFile(io, request_body_path, .{ .truncate = true });
    defer request_body_file.close(io);
    if (self._request_body) |body| try request_body_file.writeStreamingAll(io, body);

    const response_body_file = try std.Io.Dir.cwd().createFile(io, response_body_path, .{ .truncate = true });
    defer response_body_file.close(io);
    try response_body_file.writeStreamingAll(io, self._response_data.items);

    log.info(.http, "XHR error trace saved", .{
        .url = self._url,
        .status = self._response_status,
        .metadata = metadata_path,
        .request_body = request_body_path,
        .response_body = response_body_path,
    });
}

fn dispatchSuccessfulCompletion(self: *XMLHttpRequest) !void {
    const exec = self._exec;
    try self.stateChanged(.done, exec);

    const loaded = self._response_data.items.len;
    try self._proto.dispatch(.load, .{
        .total = loaded,
        .loaded = loaded,
    }, exec);
    try self._proto.dispatch(.load_end, .{
        .total = loaded,
        .loaded = loaded,
    }, exec);

    exec.context.page.session.drainDeferredCommit();
}

fn queueSuccessfulCompletion(self: *XMLHttpRequest) !void {
    const generation = self._request_generation;
    if (self._queued_completion_generation == generation) return;
    self._queued_completion_generation = generation;

    const callback = self._arena.create(DeferredCompletionCallback) catch |err| {
        self._queued_completion_generation = null;
        self.releaseSelfRefForGeneration(generation);
        return err;
    };
    callback.* = .{ .xhr = self, .generation = generation };
    self._exec._scheduler.add(callback, DeferredCompletionCallback.run, 0, .{
        .name = "XMLHttpRequest.complete",
        .low_priority = false,
        .finalizer = DeferredCompletionCallback.cancelled,
    }) catch |err| {
        self._queued_completion_generation = null;
        self.releaseSelfRefForGeneration(generation);
        return err;
    };
}

const DeferredCompletionCallback = struct {
    xhr: *XMLHttpRequest,
    generation: u64,
    attempts: u8 = 0,

    fn clearQueued(self: *DeferredCompletionCallback) void {
        if (self.xhr._queued_completion_generation == self.generation) {
            self.xhr._queued_completion_generation = null;
        }
    }

    fn cancelled(ctx: *anyopaque) void {
        const self: *DeferredCompletionCallback = @ptrCast(@alignCast(ctx));
        self.clearQueued();
        self.xhr.releaseSelfRefForGeneration(self.generation);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DeferredCompletionCallback = @ptrCast(@alignCast(ctx));
        const xhr = self.xhr;

        if (xhr._request_generation != self.generation or !xhr._active_request) {
            self.clearQueued();
            xhr.releaseSelfRefForGeneration(self.generation);
            return null;
        }

        if (!canDispatchXhrEvents(xhr, xhr._exec)) {
            // A queued task normally has no V8 call depth, but a nested host
            // pump can still reach it. Retry while this is the active realm;
            // navigation/teardown makes the old completion ineligible.
            if (xhr._exec.canEnterJs(.strict_active) and self.attempts < 32) {
                self.attempts += 1;
                return 0;
            }
            self.clearQueued();
            xhr.releaseSelfRefForGeneration(self.generation);
            return null;
        }

        self.clearQueued();
        defer xhr.releaseSelfRefForGeneration(self.generation);
        try xhr.dispatchSuccessfulCompletion();
        return null;
    }
};

fn httpErrorCallback(ctx: *anyopaque, err: anyerror) void {
    const self: *XMLHttpRequest = @ptrCast(@alignCast(ctx));
    // http client will close it after an error, it isn't safe to keep around
    self.handleError(err);
    if (self._http_response != null) {
        self._http_response = null;
    }
    // Skip session commits when the request was already torn down (force_deinit
    // during Page.deinit) or the realm cannot enter JS.
    if (self._active_request and self._exec.canEnterJs(.allow_draining)) {
        self._exec.context.page.session.drainDeferredCommit();
    }
    self.releaseSelfRef();
}

fn httpShutdownCallback(ctx: *anyopaque) void {
    const self: *XMLHttpRequest = @ptrCast(@alignCast(ctx));
    self._http_response = null;
    self.releaseSelfRef();
}

pub fn abort(self: *XMLHttpRequest) void {
    self.handleError(error.Abort);
    if (self._http_response) |resp| {
        self._http_response = null;
        resp.abort(error.Abort);
    }
    self.releaseSelfRef();
}

fn handleError(self: *XMLHttpRequest, err: anyerror) void {
    self._handleError(err) catch |inner| {
        log.err(.http, "handle error error", .{
            .original = err,
            .err = inner,
        });
    };
}
fn _handleError(self: *XMLHttpRequest, err: anyerror) !void {
    const is_abort = err == error.Abort;
    const is_timeout = err == error.OperationTimedout;

    const new_state: ReadyState = if (is_abort) .unsent else .done;
    if (new_state != self._ready_state) {
        const exec = self._exec;
        // Teardown / navigated-away / nested HTTP: readyState only — no DOM events.
        if (!canDispatchXhrEvents(self, exec)) {
            self._ready_state = new_state;
        } else {
            try self.stateChanged(new_state, exec);
            if (is_abort) {
                try self._proto.dispatch(.abort, null, exec);
            } else if (is_timeout) {
                try self._proto.dispatch(.timeout, null, exec);
            }
            if (!is_timeout) {
                try self._proto.dispatch(.err, null, exec);
            }
            try self._proto.dispatch(.load_end, null, exec);
        }
    }

    const level: log.Level = if (err == error.Abort) .debug else .err;
    log.log(.http, level, "error", .{
        .url = self._url,
        .err = err,
        .source = "xhr.handleError",
    });
}

/// XHR progress events from curl callbacks must not enter JS while another call
/// is on the V8 stack (HTML parse / script eval) — crashes with IsOnCentralStack.
fn canDispatchXhrEvents(self: *const XMLHttpRequest, exec: *const Execution) bool {
    return self._active_request and
        (self._task_owner == null or !exec.isTaskOwnerStale(self._task_owner.?)) and
        exec.canEnterJs(.strict_active) and
        exec.context.call_depth == 0;
}

fn dispatchReadyStateChange(self: *XMLHttpRequest, exec: *const Execution) !void {
    if (!canDispatchXhrEvents(self, exec)) return;

    const target = self.asEventTarget();
    if (exec.hasDirectListeners(target, "readystatechange", self._on_ready_state_change)) {
        const event = try Event.initTrusted(.wrap("readystatechange"), .{}, exec.context.page);
        try exec.dispatch(target, event, self._on_ready_state_change, .{ .context = "XHR state change" });
    }
}

fn stateChanged(self: *XMLHttpRequest, state: ReadyState, exec: *const Execution) !void {
    if (state == self._ready_state) {
        return;
    }

    self._ready_state = state;
    try self.dispatchReadyStateChange(exec);
}

fn parseMethod(method: []const u8) !http.Method {
    if (std.ascii.eqlIgnoreCase(method, "get")) {
        return .GET;
    }
    if (std.ascii.eqlIgnoreCase(method, "post")) {
        return .POST;
    }
    if (std.ascii.eqlIgnoreCase(method, "delete")) {
        return .DELETE;
    }
    if (std.ascii.eqlIgnoreCase(method, "put")) {
        return .PUT;
    }
    if (std.ascii.eqlIgnoreCase(method, "propfind")) {
        return .PROPFIND;
    }
    return error.InvalidMethod;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(XMLHttpRequest);

    pub const Meta = struct {
        pub const name = "XMLHttpRequest";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(XMLHttpRequest.init, .{});
    pub const UNSENT = bridge.property(@intFromEnum(XMLHttpRequest.ReadyState.unsent), .{ .template = true });
    pub const OPENED = bridge.property(@intFromEnum(XMLHttpRequest.ReadyState.opened), .{ .template = true });
    pub const HEADERS_RECEIVED = bridge.property(@intFromEnum(XMLHttpRequest.ReadyState.headers_received), .{ .template = true });
    pub const LOADING = bridge.property(@intFromEnum(XMLHttpRequest.ReadyState.loading), .{ .template = true });
    pub const DONE = bridge.property(@intFromEnum(XMLHttpRequest.ReadyState.done), .{ .template = true });

    pub const upload = bridge.accessor(XMLHttpRequest.getUpload, null, .{});
    pub const onreadystatechange = bridge.accessor(XMLHttpRequest.getOnReadyStateChange, XMLHttpRequest.setOnReadyStateChange, .{});
    pub const timeout = bridge.accessor(XMLHttpRequest.getTimeout, XMLHttpRequest.setTimeout, .{});
    pub const withCredentials = bridge.accessor(XMLHttpRequest.getWithCredentials, XMLHttpRequest.setWithCredentials, .{ .dom_exception = true });
    pub const open = bridge.function(XMLHttpRequest.open, .{});
    pub const send = bridge.function(XMLHttpRequest.send, .{ .dom_exception = true });
    pub const responseType = bridge.accessor(XMLHttpRequest.getResponseType, XMLHttpRequest.setResponseType, .{});
    pub const status = bridge.accessor(XMLHttpRequest.getStatus, null, .{});
    pub const statusText = bridge.accessor(XMLHttpRequest.getStatusText, null, .{});
    pub const readyState = bridge.accessor(XMLHttpRequest.getReadyState, null, .{});
    pub const response = bridge.accessor(XMLHttpRequest.getResponse, null, .{});
    pub const responseText = bridge.accessor(XMLHttpRequest.getResponseText, null, .{});
    pub const responseXML = bridge.accessor(XMLHttpRequest.getResponseXML, null, .{});
    pub const responseURL = bridge.accessor(XMLHttpRequest.getResponseURL, null, .{});
    pub const setRequestHeader = bridge.function(XMLHttpRequest.setRequestHeader, .{ .dom_exception = true });
    pub const getResponseHeader = bridge.function(XMLHttpRequest.getResponseHeader, .{});
    pub const getAllResponseHeaders = bridge.function(XMLHttpRequest.getAllResponseHeaders, .{});
    pub const abort = bridge.function(XMLHttpRequest.abort, .{});
};

const testing = @import("../../../testing/testing.zig");

test "XHR string BodyInit supplies text content type only when required" {
    try testing.expect(needsDefaultStringBodyContentType(.POST, true, false));
    try testing.expect(needsDefaultStringBodyContentType(.PUT, true, false));
    try testing.expect(!needsDefaultStringBodyContentType(.POST, false, false));
    try testing.expect(!needsDefaultStringBodyContentType(.POST, true, true));
    try testing.expect(!needsDefaultStringBodyContentType(.GET, true, false));
    try testing.expect(!needsDefaultStringBodyContentType(.HEAD, true, false));
}

test "WebApi: XHR" {
    try testing.htmlRunner("net/xhr.html", .{});
}
