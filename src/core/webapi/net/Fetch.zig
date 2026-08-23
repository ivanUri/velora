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
const HttpClient = @import("../../browser/HttpClient.zig");

const js = @import("../../js/js.zig");
const Page = @import("../../browser/Page.zig");
const URL = @import("../../browser/URL.zig");

const Blob = @import("../Blob.zig");
const Request = @import("Request.zig");
const Response = @import("Response.zig");
const FetchRedirectState = @import("FetchRedirectState.zig");
const Integrity = @import("Integrity.zig");
const AbortSignal = @import("../AbortSignal.zig");
const ReadableStream = @import("../streams/ReadableStream.zig");
const DOMException = @import("../../dom/DOMException.zig");
const ReferrerPolicy = @import("../../browser/ReferrerPolicy.zig");
const http = @import("../../../runtime/network/http.zig");

const log = @import("../../../support/log.zig");
const Execution = js.Execution;
const Frame = @import("../../browser/Frame.zig");
const RealmLifecycleKernel = @import("../../../runtime/RealmLifecycleKernel.zig");
const IS_DEBUG = @import("builtin").mode == .Debug;

const Fetch = @This();

_exec: *const Execution,
_task_owner: RealmLifecycleKernel.TaskOwner,
_url: [:0]const u8,
_buf: std.ArrayList(u8),
_response: *Response,
_resolver: js.PromiseResolver.Global,
_owns_response: bool,
_signal: ?*AbortSignal,
_mode: Request.Mode,
_integrity: []const u8,
_method: []const u8,
_fetch_resolved: bool = false,
_stream: ?*ReadableStream = null,
_pending_chunk_tasks: usize = 0,
_keepalive: bool = false,

pub const Input = Request.Input;
pub const InitOpts = Request.InitOpts;

pub fn init(input: Input, options: ?InitOpts, exec: *const Execution) !js.Promise {
    const resolver = exec.context.local.?.createPromiseResolver();

    const request = Request.init(input, options, exec) catch |err| switch (err) {
        error.TypeError => {
            resolver.rejectError("fetch init", .{ .type_error = "" });
            return resolver.promise();
        },
        else => return err,
    };

    if (request._body_stream != null) {
        resolver.rejectError("streaming upload", .{ .type_error = "" });
        return resolver.promise();
    }

    if (request._signal) |signal| {
        if (signal._aborted) {
            resolver.reject("fetch aborted", DOMException.init("The operation was aborted.", "AbortError"));
            return resolver.promise();
        }
    }

    if (std.mem.startsWith(u8, request._url, "blob:")) {
        return handleBlobUrl(request, resolver, exec);
    }

    if (request._mode == .@"same-origin" and !exec.isSameOrigin(request._url)) {
        resolver.rejectError("fetch same-origin", .{ .type_error = "Failed to fetch" });
        return resolver.promise();
    }

    const response = try Response.init(null, .{ .status = 0 }, exec);
    response._network_response = true;
    errdefer response.deinit(exec.context.page);

    const arena = response._arena;
    const req_headers = try request.getHeaders(exec);
    const method_name = request._method;
    const http_method = request.httpMethod();
    const custom_method: ?[:0]const u8 = if (std.meta.stringToEnum(http.Method, method_name) == null)
        try exec.call_arena.dupeZ(u8, method_name)
    else
        null;

    const redirect_state = try arena.create(FetchRedirectState.State);
    redirect_state.* = .{
        .exec = exec,
        .arena = arena,
        .request_headers = req_headers,
        .referrer = try arena.dupe(u8, request._referrer),
        .referrer_policy = try arena.dupe(u8, request._referrer_policy),
        .referrer_source_url = try arena.dupeZ(u8, exec.url.*),
        .body_content_type = request._body_content_type,
        .fetch_mode = @tagName(request._mode),
        .credentials_mode = @tagName(request._credentials),
        .cache_revalidate = request._cache == .@"no-cache" or
            request._cache == .reload or request._cache == .@"no-store",
    };

    const fetch = try arena.create(Fetch);
    fetch.* = .{
        ._exec = exec,
        ._task_owner = exec.captureTaskOwner(),
        ._buf = .empty,
        ._url = try arena.dupeZ(u8, request._url),
        ._resolver = try resolver.persist(),
        ._response = response,
        ._owns_response = true,
        ._signal = request._signal,
        ._mode = request._mode,
        ._integrity = request._integrity,
        ._method = try arena.dupe(u8, method_name),
        ._keepalive = request._keepalive,
    };
    try response.trackPendingFetch(exec.context.page);

    const session = exec.context.page.session;
    const http_client = &session.browser.http_client;
    var headers = try FetchRedirectState.buildWireHeaders(redirect_state, request._url, request._body, method_name);
    // Ownership transfers either to the main HttpClient request or to
    // PreflightCtx. Until that call succeeds, this stack frame owns the curl
    // header list and must release it on every construction/start failure.
    errdefer headers.deinit();

    if (comptime IS_DEBUG) {
        log.debug(.http, "fetch", .{ .url = request._url });
    }

    const cookie_jar = switch (request._credentials) {
        .omit => null,
        .include => &session.cookie_jar,
        .@"same-origin" => if (exec.isSameOrigin(request._url)) &session.cookie_jar else null,
    };

    RealmLifecycleKernel.tracePromiseSchedule(exec.frameId(), exec.realmEpoch(), .fetch_completion);

    const raw_post_body = request._body != null and request._body_content_type == null;
    // Fetch constructs its browser-controlled headers before entering the
    // transport. curl-impersonate contributes TLS behaviour only here; its
    // generic navigation header preset must not be merged into Fetch requests.
    const curl_default_headers = false;
    const credentials = request._credentials;
    const cross_origin = !exec.isSameOrigin(request._url);
    const needs_preflight = request._mode == .cors and cross_origin and
        needsCorsPreflight(method_name, req_headers, exec);

    // Cross-origin CORS: always send Origin (including GET/HEAD).
    if (cross_origin and request._mode == .cors) {
        try appendCorsOriginHeader(exec, arena, &headers);
    }

    if (needs_preflight) {
        try startCorsPreflight(.{
            .fetch = fetch,
            .http_client = http_client,
            .session = session,
            .redirect_state = redirect_state,
            .method_name = method_name,
            .http_method = http_method,
            .custom_method = custom_method,
            .main_headers = headers,
            .cookie_jar = cookie_jar,
            .raw_post_body = raw_post_body,
            .curl_default_headers = curl_default_headers,
            .body = request._body,
            .credentials = credentials,
            .req_headers = req_headers,
        });
        return resolver.promise();
    }

    try http_client.request(.{
        .ctx = fetch,
        .params = .{
            .url = request._url,
            .method = http_method,
            .custom_method = custom_method,
            .frame_id = exec.frameId(),
            .loader_id = exec.loaderId(),
            .body = request._body,
            .headers = headers,
            .resource_type = .fetch,
            .cookie_jar = cookie_jar,
            .cookie_origin = exec.url.*,
            .top_level_cookie_url = exec.topLevelCookieUrl(),
            .notification = session.notification,
            .curl_default_headers = curl_default_headers,
            .raw_post_body = raw_post_body,
            .redirect_refresh_ctx = redirect_state,
            .redirect_header_rebuild = FetchRedirectState.rebuildHeaders,
            .keepalive = request._keepalive,
            .attribution_frame = exec.attributionFrame(),
        },
        .start_callback = httpStartCallback,
        .header_callback = httpHeaderDoneCallback,
        .data_callback = httpDataCallback,
        .done_callback = httpDoneCallback,
        .error_callback = httpErrorCallback,
        .shutdown_callback = httpShutdownCallback,
    });
    return resolver.promise();
}

// --- CORS preflight (Fetch §4.3) ---------------------------------------------

fn appendCorsOriginHeader(exec: *const Execution, arena: std.mem.Allocator, headers: *HttpClient.Headers) !void {
    const origin = (try URL.getOrigin(arena, exec.url.*)) orelse "null";
    const origin_hdr = try std.fmt.allocPrintSentinel(arena, "Origin: {s}", .{origin}, 0);
    try headers.add(origin_hdr);
}

fn isCorsSafelistedMethod(method: []const u8) bool {
    return std.ascii.eqlIgnoreCase(method, "GET") or
        std.ascii.eqlIgnoreCase(method, "HEAD") or
        std.ascii.eqlIgnoreCase(method, "POST");
}

fn isCorsSafelistedRequestHeader(name: []const u8, value: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, "accept") or
        std.ascii.eqlIgnoreCase(name, "accept-language") or
        std.ascii.eqlIgnoreCase(name, "content-language"))
    {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(name, "content-type")) {
        // application/x-www-form-urlencoded, multipart/form-data, text/plain
        // (ignore parameters)
        const semi = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
        const mime = std.mem.trim(u8, value[0..semi], &std.ascii.whitespace);
        return std.ascii.eqlIgnoreCase(mime, "application/x-www-form-urlencoded") or
            std.ascii.eqlIgnoreCase(mime, "multipart/form-data") or
            std.ascii.eqlIgnoreCase(mime, "text/plain");
    }
    return false;
}

fn needsCorsPreflight(method: []const u8, headers: *Headers, exec: *const Execution) bool {
    if (!isCorsSafelistedMethod(method)) return true;
    // Walk Headers entries (combined not required — any non-simple name triggers).
    for (headers._list._entries.items) |entry| {
        const name = entry.name.str();
        const value = entry.value.str();
        if (!isCorsSafelistedRequestHeader(name, value)) return true;
    }
    _ = exec;
    return false;
}

const PreflightStart = struct {
    fetch: *Fetch,
    http_client: *HttpClient,
    session: *Session,
    redirect_state: *FetchRedirectState.State,
    method_name: []const u8,
    http_method: http.Method,
    custom_method: ?[:0]const u8,
    main_headers: HttpClient.Headers,
    cookie_jar: ?*CookieJar,
    raw_post_body: bool,
    curl_default_headers: bool,
    body: ?[]const u8,
    credentials: Request.Credentials,
    req_headers: *Headers,
};

const CookieJar = @import("../storage/Cookie.zig").Jar;
const Session = @import("../../browser/Session.zig");
const Headers = @import("Headers.zig");

const PreflightCtx = struct {
    fetch: *Fetch,
    http_client: *HttpClient,
    session: *Session,
    redirect_state: *FetchRedirectState.State,
    method_name: []const u8,
    http_method: http.Method,
    custom_method: ?[:0]const u8,
    main_headers: HttpClient.Headers,
    main_headers_owned: bool = true,
    cookie_jar: ?*CookieJar,
    raw_post_body: bool,
    curl_default_headers: bool,
    body: ?[]const u8,
    credentials_include: bool,
    /// Comma-separated non-safelisted header names sent in ACRH (lowercase).
    request_headers_list: []const u8,
    acao: ?[]const u8 = null,
    acam: ?[]const u8 = null,
    acah: ?[]const u8 = null,
    acac: bool = false,
    status: u16 = 0,
};

fn startCorsPreflight(opts: PreflightStart) !void {
    const fetch = opts.fetch;
    const exec = fetch._exec;
    const arena = fetch._response._arena;

    // Build Access-Control-Request-Headers from non-safelisted names.
    var acrh_buf: std.ArrayList(u8) = .empty;
    for (opts.req_headers._list._entries.items) |entry| {
        const name = entry.name.str();
        const value = entry.value.str();
        if (isCorsSafelistedRequestHeader(name, value)) continue;
        if (acrh_buf.items.len > 0) try acrh_buf.appendSlice(arena, ",");
        try acrh_buf.appendSlice(arena, name);
    }
    const acrh = try arena.dupe(u8, acrh_buf.items);

    const pctx = try arena.create(PreflightCtx);
    pctx.* = .{
        .fetch = fetch,
        .http_client = opts.http_client,
        .session = opts.session,
        .redirect_state = opts.redirect_state,
        .method_name = try arena.dupe(u8, opts.method_name),
        .http_method = opts.http_method,
        .custom_method = opts.custom_method,
        .main_headers = opts.main_headers,
        .cookie_jar = opts.cookie_jar,
        .raw_post_body = opts.raw_post_body,
        .curl_default_headers = opts.curl_default_headers,
        .body = opts.body,
        .credentials_include = opts.credentials == .include,
        .request_headers_list = acrh,
    };

    var pf_headers = try opts.http_client.newHeaders();
    // HttpClient owns this list only after request() succeeds.
    errdefer pf_headers.deinit();
    try exec.headersForRequest(&pf_headers, .{
        .request_url = fetch._url,
        .resource_type = .fetch,
        // Preflight always carries Origin, appended explicitly below.
        .include_origin_header = false,
        .header_arena = arena,
        .fetch_mode = "cors",
        .storage_access_active = false,
    });
    try appendCorsOriginHeader(exec, arena, &pf_headers);
    // ACR-Method
    const acrm = try std.fmt.allocPrintSentinel(arena, "Access-Control-Request-Method: {s}", .{opts.method_name}, 0);
    try pf_headers.add(acrm);
    if (acrh.len > 0) {
        const acrh_hdr = try std.fmt.allocPrintSentinel(arena, "Access-Control-Request-Headers: {s}", .{acrh}, 0);
        try pf_headers.add(acrh_hdr);
    }

    if (comptime IS_DEBUG) {
        log.debug(.http, "cors preflight", .{ .url = fetch._url, .method = opts.method_name });
    }

    try opts.http_client.request(.{
        .ctx = pctx,
        .params = .{
            .url = fetch._url,
            .method = .OPTIONS,
            .frame_id = exec.frameId(),
            .loader_id = exec.loaderId(),
            .body = null,
            .headers = pf_headers,
            .resource_type = .fetch,
            .cookie_jar = null, // preflight is non-credentialed by default unless... still omit cookies
            .cookie_origin = exec.url.*,
            .top_level_cookie_url = exec.topLevelCookieUrl(),
            .notification = opts.session.notification,
            .curl_default_headers = false,
            .raw_post_body = false,
            .keepalive = false,
            .attribution_frame = exec.attributionFrame(),
            // Do not follow redirects for preflight
            // (HttpClient default may follow — check)
        },
        .header_callback = preflightHeaderCallback,
        .data_callback = preflightDataCallback,
        .done_callback = preflightDoneCallback,
        .error_callback = preflightErrorCallback,
        .shutdown_callback = preflightShutdownCallback,
    });
}

fn preflightHeaderCallback(response: HttpClient.Response) !bool {
    const pctx: *PreflightCtx = @ptrCast(@alignCast(response.ctx));
    pctx.status = response.status() orelse 0;
    var it = response.headerIterator();
    while (it.next()) |hdr| {
        if (std.ascii.eqlIgnoreCase(hdr.name, "access-control-allow-origin")) {
            pctx.acao = try pctx.fetch._response._arena.dupe(u8, hdr.value);
        } else if (std.ascii.eqlIgnoreCase(hdr.name, "access-control-allow-methods")) {
            pctx.acam = try pctx.fetch._response._arena.dupe(u8, hdr.value);
        } else if (std.ascii.eqlIgnoreCase(hdr.name, "access-control-allow-headers")) {
            pctx.acah = try pctx.fetch._response._arena.dupe(u8, hdr.value);
        } else if (std.ascii.eqlIgnoreCase(hdr.name, "access-control-allow-credentials")) {
            pctx.acac = std.ascii.eqlIgnoreCase(std.mem.trim(u8, hdr.value, &std.ascii.whitespace), "true");
        }
    }
    return true;
}

fn preflightDataCallback(_: HttpClient.Response, _: []const u8) !void {}

fn corsTokenListContains(list: []const u8, needle: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (t.len == 1 and t[0] == '*') return true;
        if (std.ascii.eqlIgnoreCase(t, needle)) return true;
    }
    return false;
}

fn preflightAllows(pctx: *PreflightCtx) bool {
    if (pctx.status < 200 or pctx.status >= 300) return false;
    const acao = pctx.acao orelse return false;
    if (pctx.credentials_include) {
        if (std.mem.eql(u8, acao, "*")) return false;
        if (!pctx.acac) return false;
    }
    // Origin match: * or exact (we don't re-parse request Origin string here;
    // server echoed ACAO is enough when not * for credentialed, and * for simple).
    const acam = pctx.acam orelse return false;
    if (!corsTokenListContains(acam, pctx.method_name)) return false;
    if (pctx.request_headers_list.len > 0) {
        const acah = pctx.acah orelse return false;
        var hit = std.mem.splitScalar(u8, pctx.request_headers_list, ',');
        while (hit.next()) |name| {
            if (name.len == 0) continue;
            if (!corsTokenListContains(acah, name)) return false;
        }
    }
    return true;
}

fn preflightDoneCallback(ctx: *anyopaque) !void {
    const pctx: *PreflightCtx = @ptrCast(@alignCast(ctx));
    const fetch = pctx.fetch;
    if (fetchJsUnavailable(fetch)) {
        releasePreflightMainHeaders(pctx);
        releaseFetchResponse(fetch);
        return;
    }

    if (!preflightAllows(pctx)) {
        releasePreflightMainHeaders(pctx);
        try rejectFetchNetworkError(fetch);
        return;
    }

    const exec = fetch._exec;
    const session = pctx.session;
    pctx.http_client.request(.{
        .ctx = fetch,
        .params = .{
            .url = fetch._url,
            .method = pctx.http_method,
            .custom_method = pctx.custom_method,
            .frame_id = exec.frameId(),
            .loader_id = exec.loaderId(),
            .body = pctx.body,
            .headers = pctx.main_headers,
            .resource_type = .fetch,
            .cookie_jar = pctx.cookie_jar,
            .cookie_origin = exec.url.*,
            .top_level_cookie_url = exec.topLevelCookieUrl(),
            .notification = session.notification,
            .curl_default_headers = pctx.curl_default_headers,
            .raw_post_body = pctx.raw_post_body,
            .redirect_refresh_ctx = pctx.redirect_state,
            .redirect_header_rebuild = FetchRedirectState.rebuildHeaders,
            .keepalive = fetch._keepalive,
            .attribution_frame = exec.attributionFrame(),
        },
        .start_callback = httpStartCallback,
        .header_callback = httpHeaderDoneCallback,
        .data_callback = httpDataCallback,
        .done_callback = httpDoneCallback,
        .error_callback = httpErrorCallback,
        .shutdown_callback = httpShutdownCallback,
    }) catch |err| {
        releasePreflightMainHeaders(pctx);
        return err;
    };
    pctx.main_headers_owned = false;
}

fn preflightErrorCallback(ctx: *anyopaque, err: anyerror) void {
    const pctx: *PreflightCtx = @ptrCast(@alignCast(ctx));
    const fetch = pctx.fetch;
    releasePreflightMainHeaders(pctx);
    if (fetchJsUnavailable(fetch)) {
        releaseFetchResponse(fetch);
        return;
    }
    log.debug(.http, "cors preflight error", .{ .err = err, .url = fetch._url });
    rejectFetchNetworkError(fetch) catch {};
}

fn preflightShutdownCallback(ctx: *anyopaque) void {
    const pctx: *PreflightCtx = @ptrCast(@alignCast(ctx));
    const fetch = pctx.fetch;
    releasePreflightMainHeaders(pctx);
    if (fetchJsUnavailable(fetch)) {
        releaseFetchResponse(fetch);
        return;
    }
    rejectFetchNetworkError(fetch) catch {};
}

fn releasePreflightMainHeaders(pctx: *PreflightCtx) void {
    if (!pctx.main_headers_owned) return;
    pctx.main_headers_owned = false;
    pctx.main_headers.deinit();
}

fn handleBlobUrl(request: *Request, resolver: js.PromiseResolver, exec: *const Execution) !js.Promise {
    if (!std.mem.eql(u8, request._method, "GET")) {
        resolver.rejectError("fetch blob method", .{ .type_error = "" });
        return resolver.promise();
    }

    const url = request._url;
    const blob: *Blob = exec.lookupBlobUrl(url) orelse {
        resolver.rejectError("fetch blob error", .{ .type_error = "BlobNotFound" });
        return resolver.promise();
    };

    const response = try Response.init(null, .{ .status = 200 }, exec);
    response._body = .{ .bytes = try response._arena.dupe(u8, blob._slice) };
    response._url = try response._arena.dupeZ(u8, url);
    response._type = .basic;

    const content_type = try Blob.validateMimeType(response._arena, blob._mime, true);
    try response._headers.appendResponse("Content-Type", content_type, exec);

    const content_length = try std.fmt.allocPrint(response._arena, "{d}", .{blob._slice.len});
    try response._headers.appendResponse("Content-Length", content_length, exec);

    const js_val = try exec.context.local.?.zigValueToJs(response, .{});
    resolver.resolve("fetch blob done", js_val);
    return resolver.promise();
}

fn httpStartCallback(response: HttpClient.Response) !void {
    const self: *Fetch = @ptrCast(@alignCast(response.ctx));
    if (comptime IS_DEBUG) {
        log.debug(.http, "request start", .{ .url = self._url, .source = "fetch" });
    }
    self._response._http_response = response;
}

/// Safe AbortSignal probe. After navigation the signal object may already be
/// freed with the old document; only dereference when the fetch's task owner
/// epoch is still current (nytimes.com UAF at signal._aborted).
/// Callers must only invoke this while the Fetch / Execution are still live
/// (transfer aborted or callbacks noop'd before page destroy).
///
/// Temporary `canEnterJs == false` is **not** an abort. Treating it as one made
/// `httpHeaderDoneCallback` return false → curl Abort/Shutdown, which killed
/// Fingerprint config GET (`…/e?region=us`) mid-flight while Chrome completed
/// the same request in ~0.5s (see demo.fingerprint.com playground).
fn fetchSignalAborted(self: *Fetch) bool {
    // Permanent teardown only — do not use fetchJsUnavailable here.
    if (self._exec.isTaskOwnerStale(self._task_owner) or self._exec.realmState() == .dead) {
        self._signal = null;
        return true;
    }
    if (self._signal) |signal| {
        return signal._aborted;
    }
    return false;
}

fn httpHeaderDoneCallback(response: HttpClient.Response) !bool {
    const self: *Fetch = @ptrCast(@alignCast(response.ctx));

    // Never return false solely because V8 is temporarily unenterable — that
    // aborts the HTTP transfer (HttpClient treats false as error.Abort) and
    // leaves fetch() pending forever. Fingerprint config GET (`…/e?region=us`)
    // hit this during realm init while identify still completed later.
    // Buffer status/headers/body always; settle the Promise when JS is ready.

    if (fetchSignalAborted(self)) {
        return false;
    }
    // True navigation teardown only.
    if (self._exec.isTaskOwnerStale(self._task_owner) or self._exec.realmState() == .dead) {
        self._signal = null;
        return false;
    }

    const arena = self._response._arena;
    if (response.contentLength()) |cl| {
        try self._buf.ensureTotalCapacity(arena, cl);
    }

    const res = self._response;

    if (comptime IS_DEBUG) {
        log.debug(.http, "request header", .{
            .source = "fetch",
            .url = self._url,
            .status = response.status(),
        });
    }

    const status = response.status().?;
    // Redirect hops are handled internally; only materialize the final response.
    // 304 Not Modified is terminal (Fetch conditional GET), not a redirect hop.
    if (status >= 300 and status < 400 and status != 304) return true;

    res._status = status;
    res._status_text = std.http.Status.phrase(@enumFromInt(status)) orelse "";
    res._url = try URL.withoutFragment(arena, response.url());
    res._is_redirected = response.redirectCount().? > 0;

    const exec = self._exec;
    const is_same_origin = isSameOriginResolved(exec, res._url);

    if (self._mode == .@"no-cors" and !is_same_origin) {
        applyOpaqueFilter(res);
        return true;
    }

    // Determine response type per Fetch spec §4.3:
    //   - same-origin → .basic
    //   - cross-origin + ACAO header present → .cors
    //   - cross-origin + no ACAO header → .opaque
    if (is_same_origin) {
        res._type = .basic;
    } else {
        var has_acao = false;
        var hdr_it = response.headerIterator();
        while (hdr_it.next()) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "access-control-allow-origin")) {
                has_acao = true;
                break;
            }
        }
        res._type = if (has_acao) .cors else .@"opaque";
    }

    var it = response.headerIterator();
    while (it.next()) |hdr| {
        try res._headers.appendResponse(hdr.name, hdr.value, exec);
    }

    if (self._integrity.len > 0 and responseHasNullBody(status, self._method)) {
        if (!fetchJsUnavailable(self)) {
            try rejectFetchNetworkError(self);
        }
        return true;
    }

    // Fetch resolves when the final response headers are available. Non-null
    // bodies remain live streams; waiting for transfer completion deadlocks
    // incremental protocols whose response intentionally remains open.
    if (!responseHasNullBody(status, self._method)) {
        const stream = try ReadableStream.init(null, null, exec);
        self._stream = stream;
        res._body = .{ .stream = stream };
    }
    // Resolving a Promise queues its reactions as microtasks; it does not run
    // consumer JavaScript on this transport callback stack.
    if (!fetchJsUnavailable(self)) {
        try resolveFetchOnHeaders(self);
    } else {
        try scheduleDeferredFetchHeaders(self);
    }

    return true;
}

fn responseHasNullBody(status: u16, method: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(method, "HEAD")) return true;
    return status == 204 or status == 205 or status == 304;
}

/// Keepalive (and any in-flight) fetches may outlive the initiating realm after
/// navigation / destroyContext. Complete the HTTP transfer but do not touch V8.
fn fetchJsUnavailable(self: *Fetch) bool {
    const exec = self._exec;
    if (exec.realmState() == .dead) return true;
    if (exec.isTaskOwnerStale(self._task_owner)) return true;
    if (!exec.canEnterJs(.allow_draining)) return true;
    return false;
}

/// Install a local scope for promise resolve/reject; no-op if context is gone.
fn fetchLocalScope(self: *Fetch, ls: *js.Local.Scope) bool {
    if (fetchJsUnavailable(self)) return false;
    return self._exec.context.tryLocalScope(ls);
}

fn releaseFetchResponse(self: *Fetch) void {
    if (!self._owns_response) return;
    const response = self._response;
    const page = self._exec.context.page;
    // The Response arena, not the document arena, owns Fetch. Until the
    // response is exposed to JS, Fetch retains that arena across navigation;
    // stale-realm terminal paths must therefore release it too.
    // Fetch itself is allocated in response._arena. Transfer ownership before
    // destroying that arena; even writing the flag after deinit is a UAF.
    self._owns_response = false;
    response.deinit(page);
}

fn rejectFetchIntegrity(self: *Fetch) !void {
    const exec = self._exec;
    var blocked = exec.isTaskOwnerStale(self._task_owner);
    if (!blocked) {
        exec.validateJsEntry(.allow_draining, .fetch_completion) catch {
            blocked = true;
        };
    }
    var ls: js.Local.Scope = undefined;
    if (!self._exec.context.tryLocalScope(&ls)) {
        if (self._owns_response) {
            self._owns_response = false;
            self._response.deinit(self._exec.context.page);
        }
        return;
    }
    defer ls.deinit();

    if (blocked) {
        ls.toLocal(self._resolver).rejectError("fetch stale", .{ .type_error = "realm navigated" });
    } else {
        ls.toLocal(self._resolver).rejectError("fetch integrity", .{ .type_error = "Failed to fetch" });
    }
    if (self._owns_response) {
        self._owns_response = false;
        self._response.deinit(exec.context.page);
    }
}

fn resolveFetchAfterBody(self: *Fetch) !void {
    const exec = self._exec;
    var blocked = exec.isTaskOwnerStale(self._task_owner);
    if (!blocked) {
        exec.validateJsEntry(.allow_draining, .fetch_completion) catch {
            blocked = true;
        };
    }
    if (blocked) {
        const cur = exec.captureTaskOwner();
        RealmLifecycleKernel.tracePromiseDropStale(exec.frameId(), self._task_owner.epoch, cur.epoch, .fetch_completion);
        var ls: js.Local.Scope = undefined;
        if (!self._exec.context.tryLocalScope(&ls)) {
            if (self._owns_response) {
                self._owns_response = false;
                self._response.deinit(self._exec.context.page);
            }
            return;
        }
        defer ls.deinit();
        ls.toLocal(self._resolver).rejectError("fetch stale", .{ .type_error = "realm navigated" });
        if (self._owns_response) {
            self._owns_response = false;
            self._response.deinit(exec.context.page);
        }
        return;
    }

    if (self._mode == .@"same-origin" and !isSameOriginResolved(exec, self._response._url)) {
        var ls: js.Local.Scope = undefined;
        if (!self._exec.context.tryLocalScope(&ls)) {
            if (self._owns_response) {
                self._owns_response = false;
                self._response.deinit(self._exec.context.page);
            }
            return;
        }
        defer ls.deinit();
        defer if (self._owns_response) {
            self._owns_response = false;
            self._response.deinit(exec.context.page);
        };
        return ls.toLocal(self._resolver).rejectError("fetch same-origin redirect", .{ .type_error = "Failed to fetch" });
    }

    var ls: js.Local.Scope = undefined;
    if (!self._exec.context.tryLocalScope(&ls)) {
        if (self._owns_response) {
            self._owns_response = false;
            self._response.deinit(self._exec.context.page);
        }
        return;
    }
    defer ls.deinit();

    const js_val = try ls.local.zigValueToJs(self._response, .{});
    self._fetch_resolved = true;
    self._response.transferPendingFetchToJs(exec.context.page);
    self._owns_response = false;
    ls.toLocal(self._resolver).resolve("fetch done", js_val);
}

fn rejectFetchNetworkError(self: *Fetch) !void {
    const exec = self._exec;
    var blocked = exec.isTaskOwnerStale(self._task_owner);
    if (!blocked) {
        exec.validateJsEntry(.allow_draining, .fetch_completion) catch {
            blocked = true;
        };
    }
    var ls: js.Local.Scope = undefined;
    if (!self._exec.context.tryLocalScope(&ls)) {
        if (self._owns_response) {
            self._owns_response = false;
            self._response.deinit(self._exec.context.page);
        }
        return;
    }
    defer ls.deinit();

    if (blocked) {
        ls.toLocal(self._resolver).rejectError("fetch stale", .{ .type_error = "realm navigated" });
    } else {
        ls.toLocal(self._resolver).rejectError("fetch error", .{ .type_error = "fetch error" });
    }
    if (self._owns_response) {
        self._owns_response = false;
        self._response.deinit(exec.context.page);
    }
}

fn isSameOriginResolved(exec: *const Execution, url: []const u8) bool {
    const resolved = URL.resolve(exec.call_arena, exec.base(), url, .{
        .always_dupe = false,
        .encoding = exec.charset.*,
    }) catch return false;
    return exec.isSameOrigin(resolved);
}

fn resolveFetchOnHeaders(self: *Fetch) !void {
    const exec = self._exec;
    // Fetch exposes a non-null body stream for every response whose status and
    // request method permit a body. Keep this invariant at the Promise
    // resolution boundary even if a transport/header callback was interrupted
    // after receiving headers but before installing the stream.
    if (!responseHasNullBody(self._response._status, self._method) and
        self._response._body == .empty)
    {
        const stream = try ReadableStream.init(null, null, exec);
        self._response._body = .{ .stream = stream };
        self._stream = stream;
    }
    var blocked = exec.isTaskOwnerStale(self._task_owner);
    if (!blocked) {
        exec.validateJsEntry(.allow_draining, .fetch_completion) catch {
            blocked = true;
        };
    }
    if (blocked) {
        const cur = exec.captureTaskOwner();
        RealmLifecycleKernel.tracePromiseDropStale(exec.frameId(), self._task_owner.epoch, cur.epoch, .fetch_completion);
        var ls: js.Local.Scope = undefined;
        if (!self._exec.context.tryLocalScope(&ls)) {
            if (self._owns_response) {
                self._owns_response = false;
                self._response.deinit(self._exec.context.page);
            }
            return;
        }
        defer ls.deinit();
        ls.toLocal(self._resolver).rejectError("fetch stale", .{ .type_error = "realm navigated" });
        if (self._owns_response) {
            self._owns_response = false;
            self._response.deinit(exec.context.page);
        }
        return;
    }

    if (self._mode == .@"same-origin" and !isSameOriginResolved(exec, self._response._url)) {
        var ls: js.Local.Scope = undefined;
        if (!self._exec.context.tryLocalScope(&ls)) {
            if (self._owns_response) {
                self._owns_response = false;
                self._response.deinit(self._exec.context.page);
            }
            return;
        }
        defer ls.deinit();
        defer if (self._owns_response) {
            self._owns_response = false;
            self._response.deinit(exec.context.page);
        };
        return ls.toLocal(self._resolver).rejectError("fetch same-origin redirect", .{ .type_error = "Failed to fetch" });
    }

    var ls: js.Local.Scope = undefined;
    if (!self._exec.context.tryLocalScope(&ls)) {
        if (self._owns_response) {
            self._owns_response = false;
            self._response.deinit(self._exec.context.page);
        }
        return;
    }
    defer ls.deinit();

    const js_val = try ls.local.zigValueToJs(self._response, .{});
    self._fetch_resolved = true;
    self._response.transferPendingFetchToJs(exec.context.page);
    self._owns_response = false;
    ls.toLocal(self._resolver).resolve("fetch headers", js_val);
}

fn applyOpaqueFilter(res: *Response) void {
    res._type = .@"opaque";
    res._status = 0;
    res._status_text = "";
    res._url = "";
    res._headers._list = .{};
}

fn httpDataCallback(response: HttpClient.Response, data: []const u8) !void {
    const self: *Fetch = @ptrCast(@alignCast(response.ctx));

    // Check if aborted (epoch-gated; signal may be freed after navigation)
    if (fetchSignalAborted(self)) {
        return error.Abort;
    }

    try self._buf.appendSlice(self._response._arena, data);

    if (self._stream) |stream| {
        const copy = try self._response._arena.dupe(u8, data);
        try scheduleDeferredFetchChunk(self, stream, copy);
    }
}

fn httpDoneCallback(ctx: *anyopaque) !void {
    const self: *Fetch = @ptrCast(@alignCast(ctx));
    var response = self._response;
    response._http_response = null;

    log.info(.http, "request complete", .{
        .source = "fetch",
        .url = self._url,
        .status = response._status,
        .len = self._buf.items.len,
    });

    // Architecture D3: never settle the JS Promise on the curl transfer stack.
    // Always enqueue a scheduler task; settleFetchDone runs on the task path.
    try scheduleDeferredFetchDone(self);
}

/// Complete a finished fetch transfer into V8. **Task path only** (not curl
/// done_callback). If still on transfer stack, re-queue.
fn settleFetchDone(self: *Fetch) !void {
    const exec = self._exec;

    // D3: if somehow called mid-transfer, bounce to scheduler.
    if (js.JsEntryGate.inTransferCallback(exec)) {
        try scheduleDeferredFetchDone(self);
        return;
    }

    // Scheduler ordering is not a transport-order guarantee. The terminal
    // close may run before chunk-delivery tasks queued earlier, so explicitly
    // wait until every acquired chunk task has released its ownership.
    if (self._pending_chunk_tasks != 0) {
        try scheduleDeferredFetchDone(self);
        return;
    }

    var response = self._response;

    if (self._exec.isTaskOwnerStale(self._task_owner) or self._exec.realmState() == .dead) {
        // Realm gone — best-effort reject so the Promise does not hang.
        var ls: js.Local.Scope = undefined;
        if (self._exec.context.tryLocalScope(&ls)) {
            defer ls.deinit();
            if (!self._fetch_resolved) {
                ls.toLocal(self._resolver).rejectError("fetch stale", .{ .type_error = "realm navigated" });
                self._fetch_resolved = true;
            }
        }
        releaseFetchResponse(self);
        return;
    }

    if (fetchJsUnavailable(self)) {
        // Temporary gate (realm initializing / cannot enter JS yet). Retry soon.
        scheduleDeferredFetchDone(self) catch |err| {
            log.warn(.http, "fetch defer settle", .{ .err = err, .url = self._url });
        };
        return;
    }

    if (self._integrity.len > 0) {
        const is_opaque = response._type == .@"opaque";
        const ok = !is_opaque and Integrity.verify(self._integrity, self._buf.items, exec.call_arena);
        if (!ok) {
            if (self._stream) |stream| {
                if (stream._state == .readable) {
                    try stream._controller.doError("Failed to fetch");
                }
            }
            if (!self._fetch_resolved) {
                try rejectFetchIntegrity(self);
            }
            return;
        }
    }

    if (self._fetch_resolved) {
        if (self._stream) |stream| {
            if (stream._state == .readable) {
                stream._controller.close() catch {};
            }
            self._stream = null;
        }
        return;
    }

    response._body = .{ .bytes = self._buf.items };
    var blocked = exec.isTaskOwnerStale(self._task_owner);
    if (!blocked) {
        exec.validateJsEntry(.allow_draining, .fetch_completion) catch {
            blocked = true;
        };
    }
    if (blocked) {
        // Not permanently dead — re-check on a later turn.
        if (!self._exec.isTaskOwnerStale(self._task_owner) and self._exec.realmState() != .dead) {
            scheduleDeferredFetchDone(self) catch {};
            return;
        }
        const cur = exec.captureTaskOwner();
        RealmLifecycleKernel.tracePromiseDropStale(exec.frameId(), self._task_owner.epoch, cur.epoch, .fetch_completion);
        var ls: js.Local.Scope = undefined;
        if (!self._exec.context.tryLocalScope(&ls)) {
            if (self._owns_response) {
                self._owns_response = false;
                self._response.deinit(self._exec.context.page);
            }
            return;
        }
        defer ls.deinit();
        ls.toLocal(self._resolver).rejectError("fetch stale", .{ .type_error = "realm navigated" });
        if (self._owns_response) {
            self._owns_response = false;
            response.deinit(exec.context.page);
        }
        return;
    }

    var ls: js.Local.Scope = undefined;
    if (!self._exec.context.tryLocalScope(&ls)) {
        scheduleDeferredFetchDone(self) catch {
            if (self._owns_response) {
                self._owns_response = false;
                self._response.deinit(self._exec.context.page);
            }
        };
        return;
    }
    defer ls.deinit();

    // Capture resolver before response.deinit: Fetch lives in response._arena.
    if (self._mode == .@"same-origin" and !isSameOriginResolved(exec, response._url)) {
        const resolver = self._resolver;
        defer if (self._owns_response) {
            self._owns_response = false;
            response.deinit(exec.context.page);
        };
        return ls.toLocal(resolver).rejectError("fetch same-origin redirect", .{ .type_error = "Failed to fetch" });
    }

    if (self._integrity.len > 0) {
        const is_opaque = response._type == .@"opaque";
        const ok = !is_opaque and Integrity.verify(self._integrity, self._buf.items, exec.call_arena);
        if (!ok) {
            const resolver = self._resolver;
            defer if (self._owns_response) {
                self._owns_response = false;
                response.deinit(exec.context.page);
            };
            return ls.toLocal(resolver).rejectError("fetch integrity", .{ .type_error = "Failed to fetch" });
        }
    }

    // Task path: resolve Promise then EventLoop.afterTask (not curl stack).
    const js_val = try ls.local.zigValueToJs(self._response, .{});
    self._response.transferPendingFetchToJs(exec.context.page);
    self._owns_response = false;
    self._fetch_resolved = true;

    // Opt-in diagnostics for successful fetch bodies. Wire-header capture
    // cannot explain application-level state transitions whose decision is in
    // a small JSON response. Keep this disabled by default and bounded so it
    // cannot turn arbitrary downloads into unbounded logs.
    if (runtime_io.getenv("KOKO_FETCH_BODY_LOG") != null) {
        const body = self._buf.items[0..@min(self._buf.items.len, 4096)];
        log.info(.http, "fetch response body", .{
            .url = self._url,
            .len = self._buf.items.len,
            .body = body,
            .truncated = body.len != self._buf.items.len,
        });
    }

    const env = exec.context.env;
    if (env.checkpoint_active) {
        ls.toLocal(self._resolver).resolve("fetch done", js_val);
        env.checkpoint_pending = true;
    } else {
        ls.toLocal(self._resolver).resolve("fetch done", js_val);
    }

    // One delay-0 continue: follow-on timers / reactions via wait-edge spin.
    // (Was 0/1/5/16/50 cascade — architecture D3 collapses to task + EventLoop.)
    scheduleDeferredFetchContinue(self) catch |err| {
        log.warn(.http, "fetch defer continue", .{ .err = err, .url = self._url });
    };
    js.EventLoop.afterTask(exec);
}

/// After fetch Promise resolves on the task path, one more hop to run timer
/// queues / reactions (setInterval job queues, etc.). Wait edges also spin.
fn scheduleDeferredFetchContinue(self: *Fetch) !void {
    const exec = self._exec;
    const callback = try exec.arena.create(DeferredFetchContinueCallback);
    callback.* = .{ .fetch = self };
    try exec._scheduler.add(callback, DeferredFetchContinueCallback.run, 0, .{
        .name = "Fetch.deferredContinue",
        .low_priority = false,
    });
    switch (exec.context.global) {
        .frame => |frame| frame.scheduleDeferredMacrotaskPump(0) catch {},
        .worker => |wgs| wgs._worker._frame.scheduleDeferredMacrotaskPump(0) catch {},
    }
}

const DeferredFetchContinueCallback = struct {
    fetch: *Fetch,

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DeferredFetchContinueCallback = @ptrCast(@alignCast(ctx));
        const fetch = self.fetch;
        if (fetch._exec.isTaskOwnerStale(fetch._task_owner) or fetch._exec.realmState() == .dead) {
            return null;
        }
        const env = fetch._exec.context.env;
        // Task-path continue (not curl stack): shared EventLoop spin + microtasks.
        // Avoid private pump storms; JsEntryGate task rule — we're already a task.
        if (js.JsEntryGate.mustQueueAsTask(fetch._exec)) {
            // Unexpected nested entry: only nested-safe microtasks, re-arm delay-0.
            js.EventLoop.drainMicrotasksNested(fetch._exec);
            return 1;
        }
        env.drainAllRealmMicrotasks();
        env.performMicrotaskCheckpointFp(fetch._exec.context);
        if (!env.checkpoint_active) {
            env.runMicrotasks(.promise_resolve);
        }
        js.EventLoop.spin(fetch._exec, .{ .max_tasks = 48, .stop_when_idle = true });
        switch (fetch._exec.context.global) {
            .frame => |frame| {
                // Short timer budget for setInterval(1) job queues without full private loop.
                if (!js.JsEntryGate.mustQueueAsTask(fetch._exec)) {
                    frame.pumpDueTimersNow(50);
                    js.EventLoop.spin(fetch._exec, .{ .max_tasks = 16, .stop_when_idle = true });
                }
            },
            .worker => {},
        }
        return null;
    }
};

fn scheduleDeferredFetchHeaders(self: *Fetch) !void {
    const exec = self._exec;
    const callback = try exec.arena.create(DeferredFetchHeadersCallback);
    callback.* = .{
        .fetch = self,
        .task_owner = exec.captureTaskOwner(),
    };
    try exec._scheduler.add(callback, DeferredFetchHeadersCallback.run, 0, .{
        .name = "Fetch.headers",
        .low_priority = false,
    });
    switch (exec.context.global) {
        .frame => |frame| frame.scheduleDeferredMacrotaskPump(0) catch {},
        .worker => |wgs| wgs._worker._frame.scheduleDeferredMacrotaskPump(0) catch {},
    }
}

const DeferredFetchHeadersCallback = struct {
    fetch: *Fetch,
    task_owner: RealmLifecycleKernel.TaskOwner,

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DeferredFetchHeadersCallback = @ptrCast(@alignCast(ctx));
        const fetch = self.fetch;
        if (fetch._fetch_resolved) return null;
        if (fetch._exec.isTaskOwnerStale(self.task_owner) or fetch._exec.realmState() == .dead) {
            releaseFetchResponse(fetch);
            return null;
        }
        if (fetchJsUnavailable(fetch)) return 1;
        try resolveFetchOnHeaders(fetch);
        return null;
    }
};

fn scheduleDeferredFetchChunk(self: *Fetch, stream: *ReadableStream, data: []const u8) !void {
    const exec = self._exec;
    const callback = try exec.arena.create(DeferredFetchChunkCallback);
    callback.* = .{
        .fetch = self,
        .stream = stream,
        .data = data,
        .task_owner = exec.captureTaskOwner(),
    };
    self._pending_chunk_tasks += 1;
    errdefer self._pending_chunk_tasks -= 1;
    try exec._scheduler.add(callback, DeferredFetchChunkCallback.run, 0, .{
        .name = "Fetch.chunk",
        .low_priority = false,
    });
    switch (exec.context.global) {
        .frame => |frame| frame.scheduleDeferredMacrotaskPump(0) catch {},
        .worker => |wgs| wgs._worker._frame.scheduleDeferredMacrotaskPump(0) catch {},
    }
}

const DeferredFetchChunkCallback = struct {
    fetch: *Fetch,
    stream: *ReadableStream,
    data: []const u8,
    task_owner: RealmLifecycleKernel.TaskOwner,

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DeferredFetchChunkCallback = @ptrCast(@alignCast(ctx));
        const fetch = self.fetch;
        if (fetch._exec.isTaskOwnerStale(self.task_owner) or fetch._exec.realmState() == .dead) {
            fetch._pending_chunk_tasks -= 1;
            return null;
        }
        if (fetchJsUnavailable(fetch)) return 1;
        defer fetch._pending_chunk_tasks -= 1;
        if (self.stream._state == .readable and !self.stream._close_requested) {
            try self.stream._controller.enqueue(.{ .uint8array = .{ .values = self.data } });
        }
        return null;
    }
};

fn scheduleDeferredFetchDone(self: *Fetch) !void {
    const exec = self._exec;
    const callback = try exec.arena.create(DeferredFetchDoneCallback);
    callback.* = .{
        .fetch = self,
        .task_owner = exec.captureTaskOwner(),
    };
    try exec._scheduler.add(callback, DeferredFetchDoneCallback.run, 0, .{
        .name = "Fetch.deferredDone",
        .low_priority = false,
    });
    // Ensure the delay-0 task is not stuck behind a quiet event loop.
    switch (exec.context.global) {
        .frame => |frame| frame.scheduleDeferredMacrotaskPump(0) catch {},
        .worker => |wgs| wgs._worker._frame.scheduleDeferredMacrotaskPump(0) catch {},
    }
}

const DeferredFetchDoneCallback = struct {
    fetch: *Fetch,
    task_owner: RealmLifecycleKernel.TaskOwner,
    attempts: u8 = 0,

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DeferredFetchDoneCallback = @ptrCast(@alignCast(ctx));
        const fetch = self.fetch;
        if (comptime IS_DEBUG) {
            log.info(.http, "fetch deferred completion task", .{
                .url = fetch._url,
                .attempt = self.attempts,
                .realm = @tagName(fetch._exec.realmState()),
            });
        }
        if (fetch._exec.isTaskOwnerStale(self.task_owner)) {
            // Give up without hang: release; resolve path already abandoned.
            releaseFetchResponse(fetch);
            return null;
        }
        if (fetchJsUnavailable(fetch)) {
            self.attempts +%= 1;
            if (self.attempts > 64) {
                // ~many event-loop turns; reject rather than hang forever.
                var ls: js.Local.Scope = undefined;
                if (fetch._exec.context.tryLocalScope(&ls)) {
                    defer ls.deinit();
                    if (!fetch._fetch_resolved) {
                        ls.toLocal(fetch._resolver).rejectError("fetch settle timeout", .{ .type_error = "Failed to fetch" });
                        fetch._fetch_resolved = true;
                    }
                }
                releaseFetchResponse(fetch);
                return null;
            }
            // Retry next turn. Scheduler forbids repeat delay 0 in Debug.
            return 1;
        }
        try settleFetchDone(fetch);
        return null;
    }
};

fn httpErrorCallback(ctx: *anyopaque, err: anyerror) void {
    const self: *Fetch = @ptrCast(@alignCast(ctx));

    log.info(.http, "request error", .{
        .source = "fetch",
        .url = self._url,
        .status = self._response._status,
        .err = err,
    });

    var response = self._response;
    response._http_response = null;

    if (self._fetch_resolved) {
        // Body stream error path: only touch V8 if the initiating realm is
        // still enterable. After destroyContext (SPA nav / page teardown),
        // doError → localScope panics (nytimes.com mid-load aborts).
        if (!fetchJsUnavailable(self)) {
            if (self._stream) |stream| {
                stream._controller.doError("fetch error") catch {};
            }
        }
        return;
    }

    if (fetchJsUnavailable(self)) {
        // Same hang as done: do not abandon the Promise. Defer reject/settle.
        if (self._exec.isTaskOwnerStale(self._task_owner) or self._exec.realmState() == .dead) {
            releaseFetchResponse(self);
            return;
        }
        scheduleDeferredFetchDone(self) catch {
            releaseFetchResponse(self);
        };
        return;
    }

    // the response is only passed on v8 on success, if we're here, it's safe to
    // clear this. (defer since `self is in the response's arena). Never deinit
    // when the realm is already dead — Page owns/released the arena.
    defer {
        if (self._owns_response and self._exec.realmState() != .dead) {
            self._owns_response = false;
            response.deinit(self._exec.context.page);
        } else {
            self._owns_response = false;
        }
    }

    const exec = self._exec;
    var blocked = exec.isTaskOwnerStale(self._task_owner);
    if (!blocked) {
        exec.validateJsEntry(.allow_draining, .fetch_completion) catch {
            blocked = true;
        };
    }

    var ls: js.Local.Scope = undefined;
    if (!fetchLocalScope(self, &ls)) {
        return;
    }
    defer ls.deinit();

    if (blocked) {
        const cur = exec.captureTaskOwner();
        RealmLifecycleKernel.tracePromiseDropStale(exec.frameId(), self._task_owner.epoch, cur.epoch, .fetch_completion);
        ls.toLocal(self._resolver).rejectError("fetch stale", .{ .type_error = "realm navigated" });
        return;
    }

    // fetch() must reject with a TypeError on network errors per spec
    ls.toLocal(self._resolver).rejectError("fetch error", .{ .type_error = "fetch error" });
}

fn httpShutdownCallback(ctx: *anyopaque) void {
    const self: *Fetch = @ptrCast(@alignCast(ctx));
    if (comptime IS_DEBUG) {
        // should always be true when we still own the response
        std.debug.assert(self._owns_response or self._fetch_resolved);
    }

    // Transfer shutdown is terminal for Response ownership. Reject immediately
    // when JS is enterable; otherwise detach a resolver-only task from Fetch so
    // the Response arena can still be released exactly once.
    if (!self._fetch_resolved) {
        if (!self._exec.isTaskOwnerStale(self._task_owner) and
            self._exec.realmState() != .dead)
        {
            rejectFetchShutdownDetached(self);
        }
        self._fetch_resolved = true;
    }

    if (self._owns_response) {
        var response = self._response;
        response._http_response = null;
        self._owns_response = false;
        response.deinit(self._exec.context.page);
        // Do not access `self` after this point: the Fetch struct was
        // allocated from response._arena which has been released.
    }
}

fn rejectFetchShutdownDetached(self: *Fetch) void {
    var ls: js.Local.Scope = undefined;
    if (!self._exec.context.tryLocalScope(&ls)) {
        scheduleDetachedFetchReject(self) catch {};
        return;
    }
    defer ls.deinit();
    ls.toLocal(self._resolver).rejectError("fetch shutdown", .{ .type_error = "Failed to fetch" });
}

fn scheduleDetachedFetchReject(self: *Fetch) !void {
    const exec = self._exec;
    const callback = try exec.arena.create(DetachedFetchRejectCallback);
    callback.* = .{
        .exec = exec,
        .resolver = self._resolver,
        .task_owner = exec.captureTaskOwner(),
    };
    try exec._scheduler.add(callback, DetachedFetchRejectCallback.run, 0, .{
        .name = "Fetch.detachedReject",
        .low_priority = false,
    });
    switch (exec.context.global) {
        .frame => |frame| frame.scheduleDeferredMacrotaskPump(0) catch {},
        .worker => |wgs| wgs._worker._frame.scheduleDeferredMacrotaskPump(0) catch {},
    }
}

const DetachedFetchRejectCallback = struct {
    exec: *const Execution,
    resolver: js.PromiseResolver.Global,
    task_owner: RealmLifecycleKernel.TaskOwner,
    attempts: u8 = 0,

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DetachedFetchRejectCallback = @ptrCast(@alignCast(ctx));
        if (self.exec.isTaskOwnerStale(self.task_owner) or self.exec.realmState() == .dead) return null;
        if (!self.exec.canEnterJs(.allow_draining)) {
            self.attempts +%= 1;
            if (self.attempts > 64) return null;
            return 1;
        }
        var ls: js.Local.Scope = undefined;
        if (!self.exec.context.tryLocalScope(&ls)) {
            self.attempts +%= 1;
            if (self.attempts > 64) return null;
            return 1;
        }
        defer ls.deinit();
        ls.toLocal(self.resolver).rejectError("fetch shutdown", .{ .type_error = "Failed to fetch" });
        return null;
    }
};

const testing = @import("../../../testing/testing.zig");
test "WebApi: fetch" {
    try testing.htmlRunner("net/fetch.html", .{});
}
