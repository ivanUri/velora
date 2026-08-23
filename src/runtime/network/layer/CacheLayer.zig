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
const datetime = @import("../../../support/datetime.zig");
const runtime_io = @import("../../../support/io.zig");
const log = @import("../../../support/log.zig");

const http = @import("../http.zig");
const Client = @import("../../../core/browser/HttpClient.zig").Client;
const Transfer = @import("../../../core/browser/HttpClient.zig").Transfer;
const Request = @import("../../../core/browser/HttpClient.zig").Request;
const Response = @import("../../../core/browser/HttpClient.zig").Response;
const Layer = @import("../../../core/browser/HttpClient.zig").Layer;

const Cache = @import("../cache/Cache.zig");
const CacheControl = Cache.CacheControl;
const CachedMetadata = @import("../cache/Cache.zig").CachedMetadata;
const CachedResponse = @import("../cache/Cache.zig").CachedResponse;
const CachedData = @import("../cache/Cache.zig").CachedData;
const CacheRequest = @import("../cache/Cache.zig").CacheRequest;
const Forward = @import("Forward.zig");

const CacheLayer = @This();

next: Layer = undefined,

pub fn layer(self: *CacheLayer) Layer {
    return .{
        .ptr = self,
        .vtable = &.{
            .request = request,
        },
    };
}

fn request(ptr: *anyopaque, client: *Client, req: Request) anyerror!void {
    const self: *CacheLayer = @ptrCast(@alignCast(ptr));
    const network = client.network;

    if (req.params.method != .GET) {
        return self.next.request(client, req);
    }

    if (network.cache_disabled or req.params.skip_cache) {
        return self.next.request(client, req);
    }

    const cache = &(network.cache orelse {
        return self.next.request(client, req);
    });

    const arena = req.params.arena;

    var iter = req.params.headers.iterator();
    const req_header_list = try iter.collect(arena);

    const cache_req: CacheRequest = .{
        .url = req.params.url,
        .timestamp = @intCast(datetime.timestamp(.clock)),
        .request_headers = req_header_list.items,
    };

    if (cache.get(arena, cache_req)) |cached| {
        try serveFromCache(req, &cached);
        client.deinitRequest(req);
        return;
    }

    if (cache.getStale(arena, cache_req)) |stale| {
        defer closeCachedData(&stale.data);
        if (stale.metadata.hasValidators()) {
            return try conditionalRequest(self, client, req, cache_req, &stale);
        }
        cache.evict(req.params.url);
    }

    return unconditionalRequest(self, client, req, cache_req);
}

fn requestHasClientValidators(cache_req: CacheRequest) bool {
    for (cache_req.request_headers) |hdr| {
        if (std.ascii.eqlIgnoreCase(hdr.name, "if-none-match") or
            std.ascii.eqlIgnoreCase(hdr.name, "if-modified-since"))
        {
            return true;
        }
    }
    return false;
}

fn closeCachedData(data: *const CachedData) void {
    switch (data.*) {
        .buffer => {},
        .file => |f| f.file.close(runtime_io.get()),
    }
}

fn unconditionalRequest(self: *CacheLayer, client: *Client, req: Request, cache_req: CacheRequest) !void {
    const arena = req.params.arena;

    const cache_ctx = try arena.create(CacheContext);
    cache_ctx.* = .{
        .arena = arena,
        .client = client,
        .forward = Forward.fromRequest(req),
        .req_url = req.params.url,
        // RequestParams is copied by value through the network layers while
        // Headers owns a curl_slist. Redirect policy may replace and free that
        // list, so cache metadata must retain the arena-owned header snapshot.
        .req_headers = cache_req.request_headers,
    };

    const wrapped = cache_ctx.forward.wrapRequest(
        req,
        cache_ctx,
        .{
            .start = CacheContext.startCallback,
            .header = CacheContext.headerCallback,
            .done = CacheContext.doneCallback,
            .shutdown = CacheContext.shutdownCallback,
            .err = CacheContext.errorCallback,
        },
    );

    return self.next.request(client, wrapped);
}

fn conditionalRequest(
    self: *CacheLayer,
    client: *Client,
    req: Request,
    cache_req: CacheRequest,
    stale: *const CachedResponse,
) !void {
    var mutable_req = req;
    const arena = mutable_req.params.arena;

    const stale_meta = try arena.create(CachedMetadata);
    stale_meta.* = stale.metadata;

    const stale_body = try duplicateCachedData(arena, stale.data);

    const cache_ctx = try arena.create(CacheContext);
    cache_ctx.* = .{
        .arena = arena,
        .client = client,
        .forward = Forward.fromRequest(mutable_req),
        .req_url = mutable_req.params.url,
        .req_headers = cache_req.request_headers,
        .stale_cached = stale_meta,
        .stale_body = stale_body,
        .cache_req = cache_req,
        .expose_304_status = requestHasClientValidators(cache_req),
    };

    if (stale.metadata.etag) |etag| {
        mutable_req.params.revalidate_etag = etag;
    }
    if (stale.metadata.last_modified) |lm| {
        mutable_req.params.revalidate_last_modified = lm;
    }

    const wrapped = cache_ctx.forward.wrapRequest(
        mutable_req,
        cache_ctx,
        .{
            .start = CacheContext.startCallback,
            .header = CacheContext.headerCallback,
            .done = CacheContext.doneCallback,
            .shutdown = CacheContext.shutdownCallback,
            .err = CacheContext.errorCallback,
        },
    );

    return self.next.request(client, wrapped);
}

fn duplicateCachedData(arena: std.mem.Allocator, data: CachedData) !CachedData {
    return switch (data) {
        .buffer => |buf| .{ .buffer = try arena.dupe(u8, buf) },
        .file => |f| blk: {
            const file = f.file;
            var read_buf: [1024]u8 = undefined;
            var file_reader = file.reader(runtime_io.get(), &read_buf);
            try file_reader.seekTo(f.offset);
            const body = try file_reader.interface.readAlloc(arena, f.len);
            break :blk .{ .buffer = body };
        },
    };
}

fn serveFromCache(req: Request, cached: *const CachedResponse) !void {
    const response = Response.fromCached(req.ctx, cached);
    defer switch (cached.data) {
        .buffer => {},
        .file => |f| f.file.close(runtime_io.get()),
    };

    if (req.start_callback) |cb| {
        try cb(response);
    }

    const proceed = try req.header_callback(response);
    if (!proceed) {
        return error.Abort;
    }

    switch (cached.data) {
        .buffer => |data| {
            if (data.len > 0) {
                try req.data_callback(response, data);
            }
        },
        .file => |f| {
            const file = f.file;
            var buf: [1024]u8 = undefined;
            var file_reader = file.reader(runtime_io.get(), &buf);
            try file_reader.seekTo(f.offset);
            const reader = &file_reader.interface;
            var read_buf: [1024]u8 = undefined;
            var remaining = f.len;
            while (remaining > 0) {
                const read_len = @min(read_buf.len, remaining);
                const n = try reader.readSliceShort(read_buf[0..read_len]);
                if (n == 0) break;
                remaining -= n;
                try req.data_callback(response, read_buf[0..n]);
            }
        },
    }

    try req.done_callback(req.ctx);
}

const CacheContext = struct {
    arena: std.mem.Allocator,
    client: *Client,
    transfer: ?*Transfer = null,
    forward: Forward,
    req_url: [:0]const u8,
    req_headers: []const http.Header,
    pending_metadata: ?*CachedMetadata = null,
    stale_cached: ?*CachedMetadata = null,
    stale_body: ?CachedData = null,
    cache_req: ?CacheRequest = null,
    served_stale: bool = false,
    /// When the client sent If-None-Match / If-Modified-Since, surface 304 to Fetch.
    expose_304_status: bool = false,

    fn startCallback(response: Response) anyerror!void {
        const self: *CacheContext = @ptrCast(@alignCast(response.ctx));
        self.transfer = response.inner.transfer;
        return self.forward.forwardStart(response);
    }

    fn headerCallback(response: Response) anyerror!bool {
        const self: *CacheContext = @ptrCast(@alignCast(response.ctx));
        const allocator = self.arena;

        const transfer = response.inner.transfer;
        var rh = &transfer.response_header.?;

        const status = rh.status;

        if (status == 304) {
            if (self.stale_cached) |stale_meta| {
                const cache = &(self.client.network.cache orelse {
                    return self.forward.forwardHeader(response);
                });

                stale_meta.stored_at = @intCast(datetime.timestamp(.clock));
                if (transfer._conn) |conn| {
                    if (conn.getResponseHeader("age", 0)) |h| {
                        stale_meta.age_at_store = std.fmt.parseInt(u64, h.value, 10) catch 0;
                    } else {
                        stale_meta.age_at_store = 0;
                    }
                    if (conn.getResponseHeader("etag", 0)) |h| {
                        stale_meta.etag = try allocator.dupe(u8, h.value);
                    }
                    if (conn.getResponseHeader("last-modified", 0)) |h| {
                        stale_meta.last_modified = try allocator.dupe(u8, h.value);
                    }
                    if (conn.getResponseHeader("cache-control", 0)) |h| {
                        if (CacheControl.parse(h.value)) |cc| {
                            stale_meta.cache_control = cc;
                        }
                    }
                }

                {
                    const x_status = blk: {
                        if (transfer._conn) |conn| {
                            if (conn.getResponseHeader("x-http-status", 0)) |h| break :blk h.value;
                        }
                        break :blk "304";
                    };
                    var headers: std.ArrayList(http.Header) = .empty;
                    for (stale_meta.headers) |hdr| {
                        if (std.ascii.eqlIgnoreCase(hdr.name, "X-HTTP-STATUS")) continue;
                        try headers.append(allocator, .{
                            .name = try allocator.dupe(u8, hdr.name),
                            .value = try allocator.dupe(u8, hdr.value),
                        });
                    }
                    try headers.append(allocator, .{
                        .name = try allocator.dupe(u8, "X-HTTP-STATUS"),
                        .value = try allocator.dupe(u8, x_status),
                    });
                    stale_meta.headers = try headers.toOwnedSlice(allocator);
                }

                const body = self.stale_body orelse return self.forward.forwardHeader(response);
                switch (body) {
                    .buffer => |data| {
                        cache.put(stale_meta.*, data) catch |err| {
                            log.warn(.http, "cache put failed", .{ .err = err });
                        };
                    },
                    .file => {},
                }

                if (self.expose_304_status) {
                    stale_meta.status = 304;
                }

                const cached = CachedResponse{
                    .metadata = stale_meta.*,
                    .data = body,
                };

                const cached_response = Response.fromCached(self.forward.ctx, &cached);
                if (self.forward.start) |cb| {
                    try cb(cached_response);
                }
                const proceed = try self.forward.header(cached_response);
                if (!proceed) return false;

                switch (body) {
                    .buffer => |data| {
                        if (data.len > 0) {
                            try self.forward.data(cached_response, data);
                        }
                    },
                    .file => {},
                }

                self.served_stale = true;
                try self.forward.forwardDone();
                return false;
            }
        }

        // Alternate transports may not attach a curl Connection. Skip
        // connection-backed cache metadata and forward their headers.
        const conn = transfer._conn orelse {
            return self.forward.forwardHeader(response);
        };

        const vary = if (conn.getResponseHeader("vary", 0)) |h| h.value else null;

        const maybe_cm = try Cache.tryCache(
            allocator,
            @intCast(datetime.timestamp(.clock)),
            transfer.url,
            rh.status,
            rh.contentType(),
            if (conn.getResponseHeader("cache-control", 0)) |h| h.value else null,
            vary,
            if (conn.getResponseHeader("age", 0)) |h| h.value else null,
            if (conn.getResponseHeader("etag", 0)) |h| h.value else null,
            if (conn.getResponseHeader("last-modified", 0)) |h| h.value else null,
            conn.getResponseHeader("set-cookie", 0) != null,
            conn.getResponseHeader("authorization", 0) != null,
        );

        if (maybe_cm) |cm| {
            var iter = transfer.responseHeaderIterator();
            var header_list = try iter.collect(allocator);
            const end_of_response = header_list.items.len;

            if (vary) |vary_str| {
                for (self.req_headers) |hdr| {
                    var vary_iter = std.mem.splitScalar(u8, vary_str, ',');
                    while (vary_iter.next()) |part| {
                        const name = std.mem.trim(u8, part, &std.ascii.whitespace);
                        if (std.ascii.eqlIgnoreCase(hdr.name, name)) {
                            try header_list.append(allocator, .{
                                .name = try allocator.dupe(u8, hdr.name),
                                .value = try allocator.dupe(u8, hdr.value),
                            });
                        }
                    }
                }
            }

            const metadata = try allocator.create(CachedMetadata);
            metadata.* = cm;
            metadata.headers = header_list.items[0..end_of_response];
            metadata.vary_headers = header_list.items[end_of_response..];
            self.pending_metadata = metadata;
        }

        return self.forward.forwardHeader(response);
    }

    fn doneCallback(ctx: *anyopaque) anyerror!void {
        const self: *CacheContext = @ptrCast(@alignCast(ctx));
        // Stale-while-revalidate already delivered the cached body via
        // forwardDone() on the 304 branch. Do not complete the consumer again.
        if (self.served_stale) {
            return;
        }

        const transfer = self.transfer orelse @panic("Start Callback didn't set CacheLayer.transfer");

        if (self.pending_metadata) |metadata| {
            const cache = &(self.client.network.cache orelse {
                return self.forward.forwardDone();
            });

            log.debug(.browser, "http cache", .{ .key = self.req_url, .metadata = metadata });
            cache.put(metadata.*, transfer._stream_buffer.items) catch |err| {
                log.warn(.http, "cache put failed", .{ .err = err });
            };
            log.debug(.browser, "http.cache.put", .{ .url = self.req_url });
        }

        return self.forward.forwardDone();
    }

    fn shutdownCallback(ctx: *anyopaque) void {
        const self: *CacheContext = @ptrCast(@alignCast(ctx));
        // Same as error: after stale was served, the consumer is finished.
        // Forwarding Abort/Shutdown here double-completes and UAF's Script/Image
        // arenas (SIGSEGV @ 0x8fc on rust-lang.org / x.com / twitter.com).
        if (self.served_stale) return;
        self.forward.forwardShutdown();
    }

    fn errorCallback(ctx: *anyopaque, e: anyerror) void {
        const self: *CacheContext = @ptrCast(@alignCast(ctx));
        if (self.served_stale) {
            // Revalidation aborted after stale body was already delivered —
            // swallow (e.g. nav abort, connection drop). Consumer already got done.
            log.debug(.http, "cache revalidate err after stale serve", .{
                .url = self.req_url,
                .err = e,
            });
            return;
        }
        self.forward.forwardErr(e);
    }
};
