// Cookie Store API — window.cookieStore backed by Session.cookie_jar.
// https://developer.mozilla.org/en-US/docs/Web/API/CookieStore
//
// Architecture: single jar (document.cookie / HTTP / CDP / this API). No second store.

const std = @import("std");
const datetime = @import("../../support/datetime.zig");
const js = @import("../js/js.zig");
const Frame = @import("../browser/Frame.zig");
const Cookie = @import("storage/Cookie.zig");
const EventTarget = @import("EventTarget.zig");

const Allocator = std.mem.Allocator;

pub fn registerTypes() []const type {
    return &.{CookieStore};
}

/// Dictionary returned by cookieStore.get / getAll (CookieListItem).
pub const CookieListItem = struct {
    name: []const u8,
    value: []const u8,
    domain: ?[]const u8 = null,
    path: []const u8 = "/",
    expires: ?f64 = null,
    secure: bool = false,
    sameSite: []const u8 = "lax",
    partitioned: bool = false,
};

/// Options for cookieStore.set (CookieInit-like).
const CookieSetOpts = struct {
    name: []const u8 = "",
    value: []const u8 = "",
    domain: ?[]const u8 = null,
    path: ?[]const u8 = null,
    expires: ?f64 = null,
    /// Max-age seconds (takes precedence over expires when both present).
    maxAge: ?i64 = null,
    secure: ?bool = null,
    sameSite: ?[]const u8 = null,
    partitioned: ?bool = null,
};

/// Options for get / delete / getAll name query.
const CookieQueryOpts = struct {
    name: ?[]const u8 = null,
};

pub const CookieStore = struct {
    _proto: *EventTarget,

    pub fn asEventTarget(self: *CookieStore) *EventTarget {
        return self._proto;
    }

    /// cookieStore.get(name) or cookieStore.get({ name })
    pub fn get(self: *const CookieStore, name_or_opts: js.Value, frame: *Frame) !js.Promise {
        _ = self;
        const local = frame.js.local orelse return error.NotHandled;
        const name = try resolveNameArg(name_or_opts, local) orelse {
            return local.resolvePromise(null);
        };

        const cookie_url = frame.cookieURL();
        const jar = &frame._session.cookie_jar;
        jar.removeExpired(null);

        if (findMatchingCookie(jar, name, cookie_url, frame)) |c| {
            return local.resolvePromise(toListItem(c));
        }
        return local.resolvePromise(null);
    }

    /// cookieStore.set(name, value) or cookieStore.set({ name, value, ... })
    pub fn set(self: *const CookieStore, arg0: js.Value, arg1: ?js.Value, frame: *Frame) !js.Promise {
        _ = self;
        const local = frame.js.local orelse return error.NotHandled;
        const cookie_url = frame.cookieURL();
        const jar = &frame._session.cookie_jar;

        if (Cookie.isThirdPartyContext(frame.topLevelUrl(), cookie_url)) {
            return local.rejectPromise(.{ .dom_exception = .{ .err = error.SecurityError } });
        }

        var opts = CookieSetOpts{};
        if (arg0.isObject()) {
            opts = try local.jsValueToZig(CookieSetOpts, arg0);
        } else {
            opts.name = try local.jsValueToZig([]const u8, arg0);
            if (arg1) |v| {
                opts.value = try local.jsValueToZig([]const u8, v);
            }
        }
        if (opts.name.len == 0) {
            return local.rejectPromise(.{ .type_error = "CookieStore.set: name required" });
        }

        // Build a Set-Cookie-like string and reuse Cookie.parse for attribute rules.
        var list = std.Io.Writer.Allocating.init(local.call_arena);
        const w = &list.writer;
        try w.print("{s}={s}", .{ opts.name, opts.value });
        if (opts.domain) |d| try w.print("; Domain={s}", .{d});
        if (opts.path) |p| try w.print("; Path={s}", .{p});
        if (opts.maxAge) |ma| try w.print("; Max-Age={d}", .{ma});
        if (opts.expires) |ex| {
            // Cookie Store expires is DOMTimeStamp (ms); Cookie.parse expects RFC date or we set expires field after.
            _ = ex;
        }
        if (opts.secure == true) try w.writeAll("; Secure");
        if (opts.sameSite) |ss| try w.print("; SameSite={s}", .{ss});
        if (opts.partitioned == true) try w.writeAll("; Partitioned");

        var c = Cookie.parse(jar.allocator, cookie_url, list.written()) catch |err| {
            return local.rejectPromise(.{ .type_error = @errorName(err) });
        };
        // Cookie Store cannot set HttpOnly (JS surface).
        if (c.http_only) {
            c.deinit();
            return local.rejectPromise(.{ .type_error = "HttpOnly cookies cannot be set via cookieStore" });
        }
        // expires from CookieInit is Unix ms in the spec; convert to seconds if provided.
        if (opts.expires) |ex_ms| {
            c.expires = ex_ms / 1000.0;
        }

        jar.addWithTopLevel(c, @intCast(datetime.timestamp(.clock)), false, frame.topLevelUrl()) catch |err| {
            c.deinit();
            return local.rejectPromise(.{ .type_error = @errorName(err) });
        };
        return local.resolvePromise(js.Undefined{});
    }

    /// cookieStore.delete(name) or cookieStore.delete({ name, ... })
    pub fn delete(self: *const CookieStore, name_or_opts: js.Value, frame: *Frame) !js.Promise {
        _ = self;
        const local = frame.js.local orelse return error.NotHandled;
        const name = try resolveNameArg(name_or_opts, local) orelse {
            return local.resolvePromise(js.Undefined{});
        };

        const cookie_url = frame.cookieURL();
        if (Cookie.isThirdPartyContext(frame.topLevelUrl(), cookie_url)) {
            return local.resolvePromise(js.Undefined{});
        }

        const jar = &frame._session.cookie_jar;
        var path_opt: ?[]const u8 = null;
        var domain_opt: ?[]const u8 = null;
        if (name_or_opts.isObject()) {
            const q = try local.jsValueToZig(CookieSetOpts, name_or_opts);
            path_opt = q.path;
            domain_opt = q.domain;
        }

        removeMatching(jar, name, cookie_url, path_opt, domain_opt, frame);
        return local.resolvePromise(js.Undefined{});
    }

    /// cookieStore.getAll() or cookieStore.getAll(name) or cookieStore.getAll({ name })
    pub fn getAll(self: *const CookieStore, name_or_opts: ?js.Value, frame: *Frame) !js.Promise {
        _ = self;
        const local = frame.js.local orelse return error.NotHandled;
        const filter_name: ?[]const u8 = if (name_or_opts) |v|
            try resolveNameArg(v, local)
        else
            null;

        const cookie_url = frame.cookieURL();
        const jar = &frame._session.cookie_jar;
        jar.removeExpired(null);

        var items: std.ArrayList(CookieListItem) = .empty;
        defer items.deinit(local.call_arena);

        // Collect cookies that would appear in document.cookie for this URL
        // (is_http=false filters HttpOnly).
        for (jar.cookies.items) |*c| {
            if (c.http_only) continue;
            if (filter_name) |n| {
                if (!std.mem.eql(u8, c.name, n)) continue;
            }
            if (!cookieVisibleToDocument(c, cookie_url, frame)) continue;
            try items.append(local.call_arena, toListItem(c));
        }

        return local.resolvePromise(items.items);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CookieStore);
        pub const Meta = struct {
            pub const name = "CookieStore";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const Prototype = EventTarget;
        pub const get = bridge.function(CookieStore.get, .{});
        pub const set = bridge.function(CookieStore.set, .{});
        pub const delete = bridge.function(CookieStore.delete, .{});
        pub const getAll = bridge.function(CookieStore.getAll, .{});
    };
};

fn toListItem(c: *const Cookie) CookieListItem {
    const domain: ?[]const u8 = if (c.domain.len > 0 and c.domain[0] == '.')
        c.domain[1..]
    else if (c.domain.len > 0)
        c.domain
    else
        null;
    return .{
        .name = c.name,
        .value = c.value,
        .domain = domain,
        .path = c.path,
        .expires = c.expires,
        .secure = c.secure,
        .sameSite = switch (c.same_site) {
            .strict => "strict",
            .lax => "lax",
            .none => "none",
        },
        .partitioned = c.partitioned,
    };
}

fn resolveNameArg(value: js.Value, local: *const js.Local) !?[]const u8 {
    if (value.isObject()) {
        const q = try local.jsValueToZig(CookieQueryOpts, value);
        return q.name;
    }
    if (value.isNullOrUndefined()) return null;
    return try local.jsValueToZig([]const u8, value);
}

fn cookieVisibleToDocument(c: *const Cookie, cookie_url: [:0]const u8, frame: *Frame) bool {
    // Reuse forRequest matching by building a one-cookie filter via appliesTo path.
    // Third-party: document.cookie hides non-partitioned; same here.
    if (Cookie.isThirdPartyContext(frame.topLevelUrl(), cookie_url) and !c.partitioned) {
        return false;
    }
    // Match via forRequest semantics: collect names that appear.
    var buf = std.Io.Writer.Allocating.init(frame.call_arena);
    frame._session.cookie_jar.forRequest(cookie_url, &buf.writer, .{
        .is_http = false,
        .is_navigation = true,
        .origin_url = cookie_url,
        .top_level_url = frame.topLevelUrl(),
    }) catch return false;
    // forRequest joins all; check name= substring carefully
    return cookieNameInCookieHeader(buf.written(), c.name);
}

fn cookieNameInCookieHeader(header: []const u8, name: []const u8) bool {
    var it = std.mem.splitSequence(u8, header, "; ");
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return true;
    }
    // also check first pair without "; " prefix when only one cookie
    if (header.len > 0) {
        const eq = std.mem.indexOfScalar(u8, header, '=') orelse return false;
        const end = std.mem.indexOfScalar(u8, header, ';') orelse header.len;
        if (eq < end and std.mem.eql(u8, header[0..eq], name)) return true;
    }
    return false;
}

fn findMatchingCookie(jar: *Cookie.Jar, name: []const u8, cookie_url: [:0]const u8, frame: *Frame) ?*const Cookie {
    for (jar.cookies.items) |*c| {
        if (!std.mem.eql(u8, c.name, name)) continue;
        if (c.http_only) continue;
        if (!cookieVisibleToDocument(c, cookie_url, frame)) continue;
        return c;
    }
    return null;
}

fn removeMatching(
    jar: *Cookie.Jar,
    name: []const u8,
    cookie_url: [:0]const u8,
    path_opt: ?[]const u8,
    domain_opt: ?[]const u8,
    frame: *Frame,
) void {
    _ = frame;
    var i = jar.cookies.items.len;
    while (i > 0) {
        i -= 1;
        const c = &jar.cookies.items[i];
        if (!std.mem.eql(u8, c.name, name)) continue;
        if (c.http_only) continue; // JS cannot delete HttpOnly
        if (path_opt) |p| {
            if (!std.mem.eql(u8, c.path, p)) continue;
        }
        if (domain_opt) |d| {
            const c_dom = if (c.domain.len > 0 and c.domain[0] == '.') c.domain[1..] else c.domain;
            const d_dom = if (d.len > 0 and d[0] == '.') d[1..] else d;
            if (!std.mem.eql(u8, c_dom, d_dom)) continue;
        }
        // Default: only delete cookies that apply to this document URL.
        if (path_opt == null and domain_opt == null) {
            if (!Cookie.pathMatches(c.path, @import("../browser/URL.zig").getPathname(cookie_url))) continue;
            // Domain host match loosely: host-only or domain-cookie for host
            const host = @import("../browser/URL.zig").getHostname(cookie_url);
            if (c.domain.len > 0 and c.domain[0] == '.') {
                if (!std.mem.endsWith(u8, host, c.domain) and !std.mem.eql(u8, host, c.domain[1..])) continue;
            } else if (c.domain.len > 0) {
                if (!std.mem.eql(u8, host, c.domain)) continue;
            }
        }
        jar.cookies.swapRemove(i).deinit();
    }
}

const testing = @import("../../testing/testing.zig");
test "WebApi: CookieStore EventTarget" {
    try testing.htmlRunner("cookie_store_event_target.html", .{});
}
