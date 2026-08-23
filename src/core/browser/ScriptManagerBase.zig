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
const assert = @import("../../support/assert.zig").assert;
const builtin = @import("builtin");

const HttpClient = @import("HttpClient.zig");
const LoadGuard = @import("LoadGuard.zig");
const ContentSecurityPolicy = @import("ContentSecurityPolicy.zig");
const http = @import("../../runtime/network/http.zig");

const js = @import("../js/js.zig");
const URL = @import("URL.zig");
const ImportMap = @import("ImportMap.zig");
const Session = @import("Session.zig");
const Frame = @import("Frame.zig");
const WorkerGlobalScope = @import("../webapi/WorkerGlobalScope.zig");

const Element = @import("../dom/Element.zig");

const log = @import("../../support/log.zig");
const datetime = @import("../../support/datetime.zig");
const runtime_io = @import("../../support/io.zig");
const String = @import("../../support/string.zig").String;
const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;
const JS_CALL_LOG_ENV = "KOKO_JS_CALL_LOG";

fn jsCallLogEnabled() bool {
    const value = runtime_io.getenv(JS_CALL_LOG_ENV) orelse return false;
    return value.len > 0 and !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false");
}

fn appendJsStringLiteral(list: *std.ArrayList(u8), arena: Allocator, value: []const u8) !void {
    try list.append(arena, '"');
    for (value) |c| {
        switch (c) {
            '\\' => try list.appendSlice(arena, "\\\\"),
            '"' => try list.appendSlice(arena, "\\\""),
            '\n' => try list.appendSlice(arena, "\\n"),
            '\r' => try list.appendSlice(arena, "\\r"),
            '\t' => try list.appendSlice(arena, "\\t"),
            else => try list.append(arena, c),
        }
    }
    try list.append(arena, '"');
}

fn instrumentClassicScript(arena: Allocator, src: []const u8, script_url: []const u8) ![]const u8 {
    const hook =
        \\(function(){
        \\  if (globalThis.__kokoJsCallLogHooked) return;
        \\  Object.defineProperty(globalThis, "__kokoJsCallLogHooked", { value: true, configurable: true });
        \\  const scriptUrl = 
    ;
    const hook_tail =
        \\;
        \\  const log = (kind, fn) => { try {
        \\    const raw = String((new Error()).stack || "").split("\n").slice(2, 9);
        \\    const frame = raw.find(line => line.includes(scriptUrl)) || raw[0] || "";
        \\    console.log("[koko-js-call] file=" + scriptUrl + " kind=" + kind + " fn=" + ((fn && (fn.name || fn.displayName)) || "<anonymous>") + " at=" + frame.trim());
        \\  } catch (_) {} };
        \\  const seen = new WeakMap();
        \\  const wrap = (kind, fn) => {
        \\    if (typeof fn !== "function") return fn;
        \\    const old = seen.get(fn); if (old) return old;
        \\    const wrapped = function(...args) { log(kind, fn); return Reflect.apply(fn, this, args); };
        \\    try { Object.defineProperty(wrapped, "name", { value: fn.name || "kokoWrapped", configurable: true }); } catch (_) {}
        \\    seen.set(fn, wrapped);
        \\    return wrapped;
        \\  };
        \\  for (const name of ["setTimeout", "setInterval"]) {
        \\    const original = globalThis[name];
        \\    if (typeof original === "function") globalThis[name] = function(fn, ...args) { return Reflect.apply(original, this, [wrap(name, fn), ...args]); };
        \\  }
        \\  if (typeof globalThis.queueMicrotask === "function") {
        \\    const original = globalThis.queueMicrotask;
        \\    globalThis.queueMicrotask = function(fn) { return Reflect.apply(original, this, [wrap("queueMicrotask", fn)]); };
        \\  }
        \\  const et = globalThis.EventTarget && globalThis.EventTarget.prototype;
        \\  if (et && typeof et.addEventListener === "function") {
        \\    const original = et.addEventListener;
        \\    et.addEventListener = function(type, fn, opts) { return Reflect.apply(original, this, [type, wrap("event:" + type, fn), opts]); };
        \\  }
        \\  const pp = globalThis.Promise && globalThis.Promise.prototype;
        \\  if (pp) for (const name of ["then", "catch", "finally"]) {
        \\    const original = pp[name];
        \\    if (typeof original === "function") pp[name] = function(...callbacks) { return Reflect.apply(original, this, callbacks.map(fn => wrap("promise." + name, fn))); };
        \\  }
        \\  for (const target of [globalThis.navigator, globalThis.document, globalThis.screen, globalThis.performance]) {
        \\    if (!target) continue;
        \\    let proto = Object.getPrototypeOf(target);
        \\    while (proto && proto !== Object.prototype) {
        \\      for (const key of Object.getOwnPropertyNames(proto)) { try {
        \\        if (key === "constructor") continue;
        \\        const desc = Object.getOwnPropertyDescriptor(proto, key);
        \\        if (!desc || desc.configurable === false || typeof desc.value !== "function") continue;
        \\        Object.defineProperty(proto, key, { ...desc, value: wrap("api:" + key, desc.value) });
        \\      } catch (_) {} }
        \\      proto = Object.getPrototypeOf(proto);
        \\    }
        \\  }
        \\})();
        \\
    ;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, hook);
    try appendJsStringLiteral(&out, arena, script_url);
    try out.appendSlice(arena, hook_tail);
    try out.append(arena, '\n');
    try out.appendSlice(arena, src);
    return out.items;
}

const ScriptManagerBase = @This();

// Either a *Frame (for page ScriptManagers) or *WorkerGlobalScope (for workers).
// Used from HTTP callbacks that only have a *Script in hand; the Script reaches
// the owner through its manager pointer.
pub const Owner = union(enum) {
    frame: *Frame,
    worker: *WorkerGlobalScope,

    pub fn url(self: Owner) [:0]const u8 {
        return switch (self) {
            .frame => |f| f.url,
            .worker => |w| w.url,
        };
    }

    pub fn topLevelCookieUrl(self: Owner) [:0]const u8 {
        return switch (self) {
            .frame => |f| f.topLevelUrl(),
            .worker => |w| w.url,
        };
    }

    pub fn frameId(self: Owner) u32 {
        return switch (self) {
            .frame => |f| f._frame_id,
            .worker => |w| w._worker._frame_id,
        };
    }

    pub fn attributionFrame(self: Owner) *anyopaque {
        return switch (self) {
            .frame => |f| f,
            .worker => |w| @ptrCast(w._worker._frame),
        };
    }

    pub fn loaderId(self: Owner) u32 {
        return switch (self) {
            .frame => |f| f._loader_id,
            .worker => |w| w._worker._loader_id,
        };
    }

    pub fn session(self: Owner) *Session {
        return switch (self) {
            .frame => |f| f._session,
            .worker => |w| w._session,
        };
    }

    pub fn jsContext(self: Owner) *js.Context {
        return switch (self) {
            .frame => |f| f.js,
            .worker => |w| w.js,
        };
    }

    pub fn captureTaskOwner(self: Owner) LoadGuard.TaskOwner {
        return self.jsContext().execution.captureTaskOwner();
    }

    pub fn addHeaders(self: Owner, headers: *HttpClient.Headers, opts: Frame.HeadersForRequestOpts) !void {
        switch (self) {
            .frame => |f| try f.headersForRequest(headers, opts),
            .worker => |w| try w.headersForRequest(headers, opts),
        }
    }

    pub fn omitCookies(self: Owner, request_url: [:0]const u8) bool {
        return switch (self) {
            .frame => false,
            .worker => |w| !w._worker.shouldSendCookies(request_url),
        };
    }

    pub fn parentFrame(self: Owner) *Frame {
        return switch (self) {
            .frame => |f| f,
            .worker => |w| w._worker._frame,
        };
    }

    pub fn cspAllowsStaticModuleImport(self: Owner, request_url: [:0]const u8) bool {
        const frame = self.parentFrame();
        const policy = frame.content_security_policy orelse return true;
        return policy.allowsWorkerStaticImport(frame.arena, frame.url, request_url);
    }

    pub fn cspAllowsDynamicModuleImport(self: Owner, request_url: [:0]const u8) bool {
        return switch (self) {
            .frame => true,
            .worker => |w| blk: {
                const policy = w._worker._script_csp orelse return true;
                const frame = w._worker._frame;
                break :blk policy.allowsDynamicImport(frame.arena, frame.url, request_url);
            },
        };
    }

    pub fn hasOpaqueOrigin(self: Owner) bool {
        return switch (self) {
            .frame => false,
            .worker => |w| w.origin == null,
        };
    }

    pub fn opaqueOriginAllowsModuleFetch(self: Owner, response: HttpClient.Response, request_url: []const u8) bool {
        if (!self.hasOpaqueOrigin()) return true;
        if (std.mem.startsWith(u8, request_url, "data:")) return true;
        var it = response.headerIterator();
        while (it.next()) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "access-control-allow-origin")) {
                return hdr.value.len > 0;
            }
        }
        return false;
    }
};

owner: Owner,

// used to prevent recursive evaluation
is_evaluating: bool,

// evaluate() arrived while is_evaluating (or while unsafe for V8/curl). Retry
// when the outer window ends or via scheduleDeferredEvaluate — never drop SPA.
evaluate_pending: bool = false,

// True while a DeferEvaluateCallback is scheduled (debounce; avoid 0-delay
// reschedule storms inside runOwnedScheduler when canEval is still false).
deferred_evaluate_queued: bool = false,

// Script load/error events cannot be dispatched recursively while evaluate()
// is on the V8 stack. Keep them as lifecycle work so window.load does not run
// before a dynamically inserted script's onload callback.
pending_element_callbacks: u32 = 0,

// Set when script-eval watchdog terminates a hung V8 module/script (infinite
// loop). evaluate() drops remaining incomplete defer heads so DCL can fire.
watchdog_terminated: bool = false,

// Only once this is true can deferred scripts be run
static_scripts_done: bool,
/// Wall ms when staticScriptsDone ran (diagnostics / optional metrics).
static_scripts_done_at_ms: u64 = 0,

// Async scripts and dynamic import() fetches. Frame .async classic scripts
// execute in insertion order once each predecessor has finished loading
// (boq-identity and similar loaders inject many async scripts in dependency
// order but smaller chunks can finish downloading first).
async_scripts: std.DoublyLinkedList,

// List of deferred scripts. These must be executed in order, but only once
// dom_loaded == true. Workers never populate this list.
defer_scripts: std.DoublyLinkedList,

// When an async script is ready, it's queued here.
ready_scripts: std.DoublyLinkedList,

shutdown: bool = false,

client: *HttpClient,
allocator: Allocator,

/// Detached HTTP callback contexts whose Script arenas were released while a
/// transfer may still hold the ctx pointer. Freed on reset/deinit after kill+tick.
orphaned_http_ctxs: std.ArrayListUnmanaged(*Script.HttpCtx) = .empty,

// See ScriptManager.zig for the type's documentation.
imported_modules: std.StringHashMapUnmanaged(ImportedModule),

// Mapping between module specifier and resolution.
// see https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/script/type/importmap
// For workers this stays empty (only Frame authors importmaps via
// ScriptManager.parseImportmap).
importmap: ImportMap,

// Called at the end of evaluate() after all Base-owned work has run. Frame
// wrapper uses this to drain defer_scripts and fire documentIsLoaded /
// scriptsCompletedLoading. Null for workers.
tail_hook: ?*const fn (*ScriptManagerBase) void,

pub fn init(allocator: Allocator, http_client: *HttpClient, owner: Owner) ScriptManagerBase {
    return .{
        .owner = owner,
        .async_scripts = .{},
        .defer_scripts = .{},
        .ready_scripts = .{},
        .importmap = .empty,
        .is_evaluating = false,
        .evaluate_pending = false,
        .deferred_evaluate_queued = false,
        .pending_element_callbacks = 0,
        .watchdog_terminated = false,
        .allocator = allocator,
        .imported_modules = .empty,
        .client = http_client,
        .static_scripts_done = false,
        .static_scripts_done_at_ms = 0,
        .tail_hook = null,
    };
}

pub fn deinit(self: *ScriptManagerBase) void {
    // necessary to free any arenas scripts may be referencing
    self.reset();
    self.reapOrphanedHttpCtxs();
    self.orphaned_http_ctxs.deinit(self.allocator);
    self.orphaned_http_ctxs = .empty;

    self.imported_modules.deinit(self.allocator);
    self.imported_modules = .empty;
    // we don't deinit self.importmap b/c we use the owner's arena for its
    // allocations.
}

/// `imported_modules` keys are always allocated with `allocator.dupeZ` (buffer
/// length = key.len + 1 for the NUL). Freeing them as plain `[]const u8` of
/// `key.len` triggers DebugAllocator "Invalid free" / off-by-one (seen on
/// nytimes.com when module preloads are reset mid-navigation).
fn freeImportedModuleKey(allocator: Allocator, key: []const u8) void {
    const z: [:0]const u8 = key.ptr[0..key.len :0];
    allocator.free(z);
}

fn clearImportedModules(self: *ScriptManagerBase) void {
    // Empty map (never used / already cleared): iterator must not touch
    // metadata — a double-deinit leaves a dangling metadata pointer and
    // panics with "incorrect alignment" in HashMap.header().
    if (self.imported_modules.metadata == null) return;
    var it = self.imported_modules.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.state) {
            .done => |script| script.deinit(),
            else => {},
        }
        freeImportedModuleKey(self.allocator, entry.key_ptr.*);
    }
    self.imported_modules.clearRetainingCapacity();
}

pub fn reset(self: *ScriptManagerBase) void {
    clearImportedModules(self);

    // The importmap's keys/values were allocated from the owner's arena, which
    // has been reset. Can't use clearAndRetainCapacity — that space is no
    // longer ours.
    self.importmap = .empty;

    clearList(&self.defer_scripts);
    clearList(&self.async_scripts);
    clearList(&self.ready_scripts);
    self.static_scripts_done = false;
    self.static_scripts_done_at_ms = 0;
    self.evaluate_pending = false;
    self.deferred_evaluate_queued = false;
    self.pending_element_callbacks = 0;
    self.watchdog_terminated = false;
    // Script.deinit nulls HttpCtx.script; free the ctx shells after lists clear.
    self.reapOrphanedHttpCtxs();
}

fn reapOrphanedHttpCtxs(self: *ScriptManagerBase) void {
    for (self.orphaned_http_ctxs.items) |ctx| {
        self.allocator.destroy(ctx);
    }
    self.orphaned_http_ctxs.clearRetainingCapacity();
}

/// Allocate a stable HTTP callback context that outlives the Script arena.
/// Transfer.req.ctx points here so late error/done after Script.deinit is safe.
pub fn attachHttpCtx(self: *ScriptManagerBase, script: *Script) !*Script.HttpCtx {
    const ctx = try self.allocator.create(Script.HttpCtx);
    ctx.* = .{ .script = script, .manager = self };
    script.http_ctx = ctx;
    return ctx;
}

pub fn retireHttpCtx(self: *ScriptManagerBase, ctx: *Script.HttpCtx) void {
    ctx.script = null;
    self.orphaned_http_ctxs.append(self.allocator, ctx) catch {
        // Best-effort: free immediately if we cannot track it.
        self.allocator.destroy(ctx);
    };
}

fn clearList(list: *std.DoublyLinkedList) void {
    while (list.popFirst()) |n| {
        const script: *Script = @fieldParentPtr("node", n);
        script.deinit();
    }
}

pub const ModuleReferrerKind = enum {
    none,
    worker_static,
    worker_dynamic,
};

fn moduleReferrerKind(self: *const ScriptManagerBase) ModuleReferrerKind {
    return switch (self.owner) {
        .worker => .worker_static,
        .frame => .none,
    };
}

pub fn getHeaders(
    self: *ScriptManagerBase,
    request_url: [:0]const u8,
    resource_type: HttpClient.RequestParams.ResourceType,
    referrer_kind: ModuleReferrerKind,
    cors_mode: bool,
) !http.Headers {
    var headers = try self.client.newHeaders();
    const referrer_opts: Frame.HeadersForRequestOpts = switch (referrer_kind) {
        .none => .{
            .request_url = request_url,
            .resource_type = resource_type,
            .include_origin_header = cors_mode,
            .fetch_mode = if (cors_mode) "cors" else "no-cors",
        },
        .worker_static => blk: {
            const frame = self.owner.parentFrame();
            break :blk .{
                .request_url = request_url,
                .resource_type = resource_type,
                .referrer_source_url = self.owner.url(),
                .referrer_policy = frame.referrer_policy,
                .include_origin_header = true,
                .fetch_mode = "cors",
            };
        },
        .worker_dynamic => blk: {
            break :blk switch (self.owner) {
                .worker => |w| .{
                    .request_url = request_url,
                    .resource_type = resource_type,
                    .referrer_source_url = self.owner.url(),
                    .referrer_policy = w._worker._referrer_policy,
                    .include_origin_header = true,
                    .fetch_mode = "cors",
                },
                .frame => .{
                    .request_url = request_url,
                    .resource_type = resource_type,
                    .include_origin_header = true,
                    .fetch_mode = "cors",
                },
            };
        },
    };
    try self.owner.addHeaders(&headers, referrer_opts);
    return headers;
}

fn acquireArena(self: *ScriptManagerBase, size_or_bucket: anytype, debug: []const u8) !Allocator {
    return self.owner.session().getArena(size_or_bucket, debug);
}

fn releaseArena(self: *ScriptManagerBase, arena: Allocator) void {
    self.owner.session().releaseArena(arena);
}

pub fn scriptList(self: *ScriptManagerBase, script: *const Script) *std.DoublyLinkedList {
    return switch (script.extra) {
        .import, .import_async => &self.async_scripts,
        .frame => |fe| switch (fe.mode) {
            .normal => unreachable, // not added to a list, executed immediately
            .@"defer" => &self.defer_scripts,
            .async, .ordered => &self.async_scripts,
        },
    };
}

// Resolve a module specifier to a valid URL.
fn completeDataUrlModuleScript(self: *ScriptManagerBase, script: *Script, owned_url: [:0]const u8) !void {
    const body = WorkerGlobalScope.decodeDataUrlJavaScript(script.arena, owned_url) catch {
        self.async_scripts.remove(&script.node);
        if (self.imported_modules.getPtr(owned_url)) |entry| {
            entry.state = .err;
        }
        script.deinit();
        return;
    };
    script.status = 200;
    script.complete = true;
    try script.source.remote.appendSlice(script.arena, body);
    self.async_scripts.remove(&script.node);
    const entry = self.imported_modules.getPtr(owned_url) orelse {
        script.deinit();
        return error.UnknownModule;
    };
    entry.state = .{ .done = script };
    entry.buffer = script.source.remote;
}

pub fn resolveSpecifier(self: *ScriptManagerBase, arena: Allocator, base: [:0]const u8, specifier: [:0]const u8) ![:0]const u8 {
    // If the specifier is mapped in the importmap, return the pre-resolved
    // value. For workers this map is empty.
    return (try self.importmap.resolve(arena, base, specifier)) orelse error.SpecifierResolutionFailed;
}

pub fn preloadImport(self: *ScriptManagerBase, url: [:0]const u8, referrer: []const u8) !void {
    switch (self.owner) {
        .worker => {
            if (!self.owner.cspAllowsStaticModuleImport(url)) {
                const gop = try self.imported_modules.getOrPut(self.allocator, url);
                if (!gop.found_existing) {
                    const owned_url = try self.allocator.dupeZ(u8, url);
                    gop.key_ptr.* = owned_url;
                    gop.value_ptr.* = .{ .state = .err };
                }
                return;
            }
        },
        .frame => {},
    }

    if (self.imported_modules.get(url)) |entry| {
        switch (entry.state) {
            .done, .loading => {
                log.debug(.js, "module cache hit", .{ .url = url, .state = @tagName(entry.state) });
                return;
            },
            .err => {
                if (self.imported_modules.fetchRemove(url)) |kv| {
                    freeImportedModuleKey(self.allocator, kv.key);
                }
            },
        }
    }

    const gop = try self.imported_modules.getOrPut(self.allocator, url);
    if (gop.found_existing) {
        return;
    }
    errdefer _ = self.imported_modules.remove(url);
    const owned_url = try self.allocator.dupeZ(u8, url);
    gop.key_ptr.* = owned_url;
    errdefer if (self.imported_modules.fetchRemove(owned_url)) |kv| {
        freeImportedModuleKey(self.allocator, kv.key);
    };

    const arena = try self.acquireArena(.large, "SM.preloadImport");
    errdefer self.releaseArena(arena);

    const script = try arena.create(Script);
    script.* = .{
        .arena = arena,
        .url = owned_url,
        .node = .{},
        .manager = self,
        .complete = false,
        .source = .{ .remote = .empty },
        .extra = .import,
        .guard = LoadGuard.Guard.init(&self.owner.jsContext().execution),
    };

    gop.value_ptr.* = ImportedModule{};
    log.debug(.js, "module fetch", .{ .url = url, .ptr = @intFromPtr(gop.value_ptr), .from = @tagName(gop.value_ptr.state), .to = "fetching" });

    if (comptime IS_DEBUG) {
        var ls: js.Local.Scope = undefined;
        self.owner.jsContext().localScope(&ls);
        defer ls.deinit();

        log.debug(.http, "script queue", .{
            .url = url,
            .ctx = "module",
            .referrer = referrer,
            .stack = ls.local.stackTrace() catch "???",
        });
    }

    // This seems wrong since we're not dealing with an async import (unlike
    // getAsyncModule below), but all we're trying to do here is pre-load the
    // script for execution at some point in the future (when waitForImport is
    // called).
    self.async_scripts.append(&script.node);

    if (std.mem.startsWith(u8, owned_url, "data:")) {
        try self.completeDataUrlModuleScript(script, owned_url);
        return;
    }

    const session = self.owner.session();
    const http_ctx = try self.attachHttpCtx(script);
    self.client.request(.{
        .ctx = http_ctx,
        .params = .{
            .url = owned_url,
            .method = .GET,
            .frame_id = self.owner.frameId(),
            .attribution_frame = self.owner.attributionFrame(),
            .loader_id = self.owner.loaderId(),
            .headers = try self.getHeaders(owned_url, .script, self.moduleReferrerKind(), true),
            .cookie_jar = &session.cookie_jar,
            .cookie_origin = self.owner.url(),
            .top_level_cookie_url = self.owner.topLevelCookieUrl(),
            .omit_cookies = self.owner.omitCookies(owned_url),
            .resource_type = .script,
            .notification = session.notification,
        },
        .start_callback = if (log.enabled(.http, .debug)) Script.HttpCtx.startCallback else null,
        .header_callback = Script.HttpCtx.headerCallback,
        .data_callback = Script.HttpCtx.dataCallback,
        .done_callback = Script.HttpCtx.doneCallback,
        .error_callback = Script.HttpCtx.errorCallback,
        .shutdown_callback = Script.HttpCtx.shutdownCallback,
    }) catch |err| {
        self.async_scripts.remove(&script.node);
        script.http_ctx = null;
        self.retireHttpCtx(http_ctx);
        return err;
    };
}

pub fn waitForImport(self: *ScriptManagerBase, url: [:0]const u8) !ModuleSource {
    const was_evaluating = self.is_evaluating;
    self.is_evaluating = true;
    defer self.endEvaluationWindow(was_evaluating);

    var client = self.client;

    // mutate imported_modules (grow/rehash), invalidating a cached Entry pointer
    // and stranding the wait on a stale `.loading` view. Re-lookup every pass
    // and wait for the request's real terminal callback. A wall-clock cutoff
    // here incorrectly turns a slow but successful module into a permanent
    // graph compilation failure; transport/navigation cancellation already
    // owns the error and shutdown terminal paths.
    while (true) {
        // This loop runs inside V8's synchronous static-module resolver.
        // TerminateExecution can interrupt JavaScript, but it cannot unwind a
        // native Zig callback by itself. Observe the isolate cancellation at
        // every transport quantum so script watchdogs and host deadlines can
        // return control to V8 instead of leaving the browser stuck here.
        if (self.owner.jsContext().env.isExecutionTerminating()) {
            return error.ExecutionTerminated;
        }

        const entry = self.imported_modules.getEntry(url) orelse {
            // Should not happen unless preload was skipped / map cleared mid-nav.
            return error.UnknownModule;
        };
        switch (entry.value_ptr.state) {
            .loading => {
                _ = try client.tick(25);
                // is_evaluating blocks blocksInboundCdp — briefly release so CDP
                // (and other transfer completions) can progress while we wait.
                const hold = self.is_evaluating;
                self.is_evaluating = false;
                client.serviceInboundCdpIfReadable();
                self.is_evaluating = hold;
                continue;
            },
            .done => |script| {
                // Re-fetch buffer after tick may have rehashed; use fresh getPtr.
                const ptr = self.imported_modules.getPtr(url) orelse return error.UnknownModule;
                const buf = switch (ptr.state) {
                    .done => ptr.buffer,
                    else => return error.Failed,
                };
                log.debug(.js, "module cache hit", .{
                    .url = url,
                    .state = @tagName(ptr.state),
                    .ptr = @intFromPtr(ptr),
                });
                return .{
                    .buffer = buf,
                    .shared = true,
                    .script = script,
                };
            },
            .err => return error.Failed,
        }
    }
}

pub fn getAsyncImport(self: *ScriptManagerBase, url: [:0]const u8, cb: ImportAsync.Callback, cb_data: *anyopaque, referrer: []const u8) !void {
    if (!self.owner.cspAllowsDynamicModuleImport(url)) {
        cb(cb_data, error.Failed);
        return;
    }

    if (std.mem.startsWith(u8, url, "data:")) {
        const arena = try self.acquireArena(.large, "SM.getAsyncImport.data");
        errdefer self.releaseArena(arena);
        const body = WorkerGlobalScope.decodeDataUrlJavaScript(arena, url) catch {
            cb(cb_data, error.Failed);
            return;
        };
        const script = try arena.create(Script);
        var buffer: std.ArrayList(u8) = .empty;
        try buffer.appendSlice(arena, body);
        script.* = .{
            .arena = arena,
            .url = url,
            .node = .{},
            .manager = self,
            .complete = true,
            .status = 200,
            .source = .{ .remote = buffer },
            .extra = .{ .import_async = .{
                .callback = cb,
                .data = cb_data,
            } },
            .guard = LoadGuard.Guard.init(&self.owner.jsContext().execution),
        };
        cb(cb_data, .{
            .shared = false,
            .script = script,
            .buffer = buffer,
        });
        return;
    }

    const arena = try self.acquireArena(.large, "SM.getAsyncImport");
    errdefer self.releaseArena(arena);

    const script = try arena.create(Script);
    script.* = .{
        .arena = arena,
        .url = url,
        .node = .{},
        .manager = self,
        .complete = false,
        .source = .{ .remote = .empty },
        .extra = .{ .import_async = .{
            .callback = cb,
            .data = cb_data,
        } },
        .guard = LoadGuard.Guard.init(&self.owner.jsContext().execution),
    };

    if (comptime IS_DEBUG) {
        var ls: js.Local.Scope = undefined;
        self.owner.jsContext().localScope(&ls);
        defer ls.deinit();

        log.debug(.http, "script queue", .{
            .url = url,
            .ctx = "dynamic module",
            .referrer = referrer,
            .stack = ls.local.stackTrace() catch "???",
        });
    }

    // It's possible, but unlikely, for client.request to immediately finish
    // a request, thus calling our callback. We generally don't want a call
    // from v8 (which is why we're here), to result in a new script evaluation.
    // So we block even the slightest change that `client.request` immediately
    // executes a callback — endEvaluationWindow retries evaluate_pending after.
    const was_evaluating = self.is_evaluating;
    self.is_evaluating = true;
    defer self.endEvaluationWindow(was_evaluating);

    const session = self.owner.session();
    self.async_scripts.append(&script.node);
    const http_ctx = try self.attachHttpCtx(script);
    self.client.request(.{
        .ctx = http_ctx,
        .params = .{
            .url = url,
            .method = .GET,
            .frame_id = self.owner.frameId(),
            .attribution_frame = self.owner.attributionFrame(),
            .loader_id = self.owner.loaderId(),
            .headers = try self.getHeaders(url, .script, .worker_dynamic, true),
            .resource_type = .script,
            .cookie_jar = &session.cookie_jar,
            .cookie_origin = self.owner.url(),
            .top_level_cookie_url = self.owner.topLevelCookieUrl(),
            .omit_cookies = self.owner.omitCookies(url),
            .notification = session.notification,
        },
        .start_callback = if (log.enabled(.http, .debug)) Script.HttpCtx.startCallback else null,
        .header_callback = Script.HttpCtx.headerCallback,
        .data_callback = Script.HttpCtx.dataCallback,
        .done_callback = Script.HttpCtx.doneCallback,
        .error_callback = Script.HttpCtx.errorCallback,
        .shutdown_callback = Script.HttpCtx.shutdownCallback,
    }) catch |err| {
        self.async_scripts.remove(&script.node);
        script.http_ctx = null;
        self.retireHttpCtx(http_ctx);
        return err;
    };
}

// Called from the Page / Frame to signal it's done parsing the HTML, so
// deferred scripts can start evaluating. Workers never call this.
//
// Mark done and schedule evaluate on a **fresh task** (delay 0). Callers are
// frameDoneCallback / DeferDocumentParse / leaveTransferCallback — already deep
// Zig+curl+parser stacks. Inline evaluate() there nests module graphs / SPA
// scripts until V8_Fatal (netlify/stripe/nytimes). HTML still runs scripts
// before DCL; we only move the first body to the next macrotask, same as a
// browser task boundary. Subsequent scripts hop one-per-task; incomplete
// heads resume from doneCallback → evaluate().
pub fn staticScriptsDone(self: *ScriptManagerBase) void {
    assert(self.static_scripts_done == false, "ScriptManagerBase.staticScriptsDone", .{});
    self.static_scripts_done = true;
    self.static_scripts_done_at_ms = datetime.milliTimestamp(.clock);
    self.queueDeferredEvaluateOnly(0);
}

/// Incomplete classic frame scripts (async/defer) that still block document lifecycle.
fn hasIncompleteLifecycleScripts(self: *const ScriptManagerBase) bool {
    var n = self.defer_scripts.first;
    while (n) |node| {
        const script: *const Script = @fieldParentPtr("node", node);
        if (!script.complete) return true;
        n = node.next;
    }
    // Classic async: only frame-async incomplete entries block ordered drain;
    // module imports do not block DCL.
    n = self.async_scripts.first;
    while (n) |node| {
        const script: *const Script = @fieldParentPtr("node", node);
        switch (script.extra) {
            .frame => |fe| {
                if (fe.mode == .ordered and !script.complete) return true;
            },
            else => {},
        }
        n = node.next;
    }
    return false;
}

fn hasPendingEvaluateWork(self: *const ScriptManagerBase) bool {
    if (self.ready_scripts.first != null) return true;
    var n = self.async_scripts.first;
    while (n) |node| {
        const script: *const Script = @fieldParentPtr("node", node);
        switch (script.extra) {
            .frame => |fe| {
                if (fe.mode == .ordered and script.complete) return true;
            },
            else => {},
        }
        n = node.next;
    }
    if (!self.static_scripts_done) return false;
    if (self.defer_scripts.first) |dn| {
        const script: *const Script = @fieldParentPtr("node", dn);
        if (script.complete) return true;
    }
    return false;
}

/// True while classic/module scripts still need evaluation (or evaluate is
/// deferred). Runner `.done` / network-idle must not resolve while SPA chunks
/// evaluate; Koko can have a gap if only evaluate_pending is set).
pub fn hasPendingJsWork(self: *const ScriptManagerBase) bool {
    return self.evaluate_pending or
        self.deferred_evaluate_queued or
        self.pending_element_callbacks != 0 or
        self.is_evaluating or
        self.hasPendingEvaluateWork() or
        self.hasIncompleteLifecycleScripts();
}

/// True when it is safe to run Script.eval (V8 central stack).
/// Must NOT gate DCL/tailHook — only individual script bodies.
/// Static module resolution may synchronously wait for a preloaded dependency.
/// Starting that resolution from an HTTP terminal callback deadlocks progress:
/// waitForImport can drive curl, but processMessages cannot re-enter to publish
/// the dependency's `.done` state until the outer callback returns. Defer the
/// script body to the central scheduler whenever curl mutation/completion
/// ownership is active.
fn canEvalScriptsFromHttpCallback(self: *const ScriptManagerBase) bool {
    if (self.client.mutationsBlocked()) return false;
    const env = &self.owner.parentFrame()._page.session.browser.env;
    if (env.anyContextOnV8Stack()) return false;
    return true;
}

/// Runner tick: ensure post-parse lifecycle started and resume evaluate when
/// work is pending (scheduler suppressed / missed hop). Incomplete defer heads
/// resume from HTTP doneCallback — no wall-clock script drops.
pub fn pumpDocumentLifecycle(self: *ScriptManagerBase, frame: *Frame) void {
    if (self.shutdown) return;

    // Parse finished but post-parse lifecycle never ran (missed leaveTransferCallback).
    if (!self.static_scripts_done and frame._parse_state == .complete and !frame._document_parse_active) {
        if (!self.client.inTransferCallback()) {
            frame._pending_post_parse_lifecycle = false;
            frame.runPostParseScriptLifecycle();
        }
    }

    if (!self.static_scripts_done or !frame.isDocumentParsing()) return;
    // Always try to make progress; also service CDP between hops (P0 navigate).
    self.client.serviceInboundCdpIfReadable();
    self.evaluatePendingWhenCentral();
}

/// Resume after nested/unsafe; never silent-drop.
pub fn evaluatePendingWhenCentral(self: *ScriptManagerBase) void {
    if (self.shutdown) return;
    // Owe DCL when parse+static done, defer heads not incomplete, and load
    // state still parsing (tailHook not applied yet).
    const owe_dcl =
        self.static_scripts_done and
        self.tail_hook != null and
        !self.hasIncompleteLifecycleScripts() and
        self.owner.parentFrame().isDocumentParsing();
    const need =
        self.evaluate_pending or
        self.hasPendingEvaluateWork() or
        owe_dcl;
    if (!need) return;
    if (self.is_evaluating) {
        self.evaluate_pending = true;
        return;
    }
    self.evaluate();
}

pub fn scheduleDeferredEvaluate(self: *ScriptManagerBase) void {
    if (self.shutdown) return;
    if (!self.static_scripts_done) return;
    if (!self.is_evaluating) {
        self.evaluate();
        return;
    }
    self.evaluate_pending = true;
    self.queueDeferredEvaluateOnly(0);
}

fn queueDeferredEvaluateOnly(self: *ScriptManagerBase, delay_ms: u32) void {
    if (self.shutdown) return;
    if (self.deferred_evaluate_queued) return;
    self.deferred_evaluate_queued = true;
    const frame = self.owner.parentFrame();
    const callback = frame.arena.create(DeferEvaluateCallback) catch {
        self.deferred_evaluate_queued = false;
        return;
    };
    callback.* = .{ .manager = self };
    frame.js.scheduler.add(callback, DeferEvaluateCallback.run, delay_ms, .{
        .name = "ScriptManager.deferEvaluate",
        .low_priority = false,
    }) catch {
        self.deferred_evaluate_queued = false;
    };
}

const DeferEvaluateCallback = struct {
    manager: *ScriptManagerBase,

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DeferEvaluateCallback = @ptrCast(@alignCast(ctx));
        self.manager.deferred_evaluate_queued = false;
        self.manager.evaluatePendingWhenCentral();
        return null;
    }
};

/// Close an `is_evaluating` window.
///
/// Always hop via delay-0 scheduler for evaluate_pending — never recurse
/// evaluate() here. Recursive re-entry + post-eval runMacrotasks stacked
/// Script.eval frames → V8_Fatal before DCL. Incomplete defer heads must not
/// set evaluate_pending (doneCallback re-enters instead).
pub fn endEvaluationWindow(self: *ScriptManagerBase, was_evaluating: bool) void {
    self.is_evaluating = was_evaluating;
    if (was_evaluating != false or !self.evaluate_pending) return;
    self.evaluate_pending = false;
    self.queueDeferredEvaluateOnly(0);
}

/// Drain completed classic frame `.async` scripts in document order.
/// Incomplete frame-async blocks subsequent frame-async (intentional).
/// Module imports sitting in the same list do not participate — scan past them.
pub fn drainOrderedAsyncScripts(self: *ScriptManagerBase) void {
    var guard: u32 = 0;
    while (guard < 256) : (guard += 1) {
        var n = self.async_scripts.first;
        var ran_one = false;
        while (n) |node| {
            var script: *Script = @fieldParentPtr("node", node);
            const next = node.next;
            switch (script.extra) {
                .frame => |fe| {
                    if (fe.mode != .ordered) {
                        n = next;
                        continue;
                    }
                    if (!script.complete) return; // ordered wait
                    if (!script.deliverable()) return;
                    if (!self.canEvalScriptsFromHttpCallback()) return;
                    self.async_scripts.remove(node);
                    defer script.deinit();
                    script.eval();
                    ran_one = true;
                    break; // restart from head after mutation
                },
                else => {
                    n = next;
                },
            }
        }
        if (!ran_one) return;
    }
}

/// Script evaluation + DOMContentLoaded (tailHook).
/// - Run **at most one** script body per evaluate() invoke, then hop via
///   delay-0 scheduler / Runner. That matches browsers treating each script
///   as a separate task and keeps Zig+V8 stack shallow (prevents V8_Fatal
///   Maximum call stack on module graphs / SPA injectors). Not a wall-clock wait.
/// - Incomplete defer head → return; HTTP doneCallback calls evaluate() again.
/// - Never set evaluate_pending while waiting on incomplete defer (SIGILL recursion).
/// - canEval false → delay-0 hop (V8 already on stack).
pub fn evaluate(self: *ScriptManagerBase) void {
    if (self.shutdown) return;
    if (!self.static_scripts_done) return;
    if (self.is_evaluating) {
        self.evaluate_pending = true;
        return;
    }

    self.is_evaluating = true;
    defer self.endEvaluationWindow(false);

    var ran_one = false;
    while (true) {
        self.evaluate_pending = false;

        // Drop ghost incomplete defer heads (aborted / non-deliverable).
        while (self.defer_scripts.first) |dn| {
            var s: *Script = @fieldParentPtr("node", dn);
            if (s.complete) break;
            if (s.guard.isFinished() or !s.deliverable()) {
                _ = self.defer_scripts.popFirst();
                s.deinit();
                continue;
            }
            break;
        }

        if (self.watchdog_terminated) {
            while (self.defer_scripts.first) |dn| {
                var s: *Script = @fieldParentPtr("node", dn);
                if (s.complete) break;
                _ = self.defer_scripts.popFirst();
                s.deinit();
            }
            self.watchdog_terminated = false;
        }

        if (!self.canEvalScriptsFromHttpCallback()) {
            if (self.hasPendingEvaluateWork() or self.hasIncompleteLifecycleScripts()) {
                self.queueDeferredEvaluateOnly(0);
            }
            return;
        }

        // HTML: deferred/module scripts block DOMContentLoaded; classic async does
        // not. Prefer one complete **defer** head first so GTM/async ready work
        // cannot starve DCL forever (previous ready-first ordering never reached
        // empty defer while trackers kept completing).
        if (self.defer_scripts.first) |n| {
            var script: *Script = @fieldParentPtr("node", n);
            if (!script.complete) {
                // In flight — doneCallback re-enters. Do not set evaluate_pending.
                // Still schedule hop so stall recovery / runner can poll.
                return;
            }
            _ = self.defer_scripts.popFirst();
            if (script.activeFrame() == null) {
                script.deinit();
                continue;
            }
            defer script.deinit();
            script.eval();
            self.client.serviceInboundCdpIfReadable();
            ran_one = true;
        } else if (self.ready_scripts.first) |n| {
            var script: *Script = @fieldParentPtr("node", n);
            _ = self.ready_scripts.popFirst();
            switch (script.extra) {
                .frame => {
                    defer script.deinit();
                    script.eval();
                    self.client.serviceInboundCdpIfReadable();
                    ran_one = true;
                },
                .import_async => |ia| {
                    if (script.status < 200 or script.status > 299) {
                        script.deinit();
                        ia.callback(ia.data, error.FailedToLoad);
                    } else {
                        ia.callback(ia.data, .{
                            .shared = false,
                            .script = script,
                            .buffer = script.source.remote,
                        });
                    }
                    self.client.serviceInboundCdpIfReadable();
                    ran_one = true;
                },
                .import => unreachable,
            }
        } else if (self.async_scripts.first) |_| {
            var n = self.async_scripts.first;
            while (n) |node| {
                var script: *Script = @fieldParentPtr("node", node);
                const next = node.next;
                switch (script.extra) {
                    .frame => |fe| {
                        if (fe.mode != .ordered) {
                            n = next;
                            continue;
                        }
                        if (!script.complete or !script.deliverable()) break;
                        self.async_scripts.remove(node);
                        defer script.deinit();
                        script.eval();
                        self.client.serviceInboundCdpIfReadable();
                        ran_one = true;
                        break;
                    },
                    else => {
                        n = next;
                    },
                }
            }
        }

        if (self.evaluate_pending and !ran_one) continue;

        // More complete defer? Hop (one-script-per-task). Delay 0 only.
        if (self.defer_scripts.first) |hn| {
            const head: *Script = @fieldParentPtr("node", hn);
            if (head.complete) {
                self.queueDeferredEvaluateOnly(0);
                return;
            }
            // Incomplete head — wait for HTTP doneCallback.
            return;
        }

        // Defer empty → DCL. Async/ready may remain; schedule optional drain.
        if (self.hasPendingEvaluateWork()) {
            self.queueDeferredEvaluateOnly(0);
        }
        break;
    }

    if (self.tail_hook) |hook| {
        hook(self);
    }
}

pub const Script = struct {
    complete: bool,
    status: u16 = 0,
    source: Source,
    url: []const u8,
    arena: Allocator,
    extra: Extra,
    node: std.DoublyLinkedList.Node,
    manager: *ScriptManagerBase,
    guard: LoadGuard.Guard,
    /// Stable HTTP callback shell (manager.allocator). Null after detach.
    http_ctx: ?*HttpCtx = null,

    // for debugging a rare production issue
    header_callback_called: bool = false,

    // for debugging a rare production issue
    debug_transfer_id: u32 = 0,
    debug_transfer_tries: u8 = 0,
    debug_transfer_aborted: bool = false,
    debug_transfer_bytes_received: usize = 0,
    debug_transfer_notified_fail: bool = false,
    debug_transfer_auth_challenge: bool = false,
    debug_transfer_easy_id: usize = 0,

    pub const Source = union(enum) {
        @"inline": []const u8,
        remote: std.ArrayList(u8),

        pub fn content(self: Source) []const u8 {
            return switch (self) {
                .remote => |buf| buf.items,
                .@"inline" => |c| c,
            };
        }
    };

    // The mode-specific extension. Only `.frame` carries frame-only state
    // (script_element, kind, *Frame); workers and dynamic JS imports use
    // `.import` / `.import_async` and never reach the .frame arm.
    pub const Extra = union(enum) {
        // Static module import — V8 resolution via imported_modules.
        import,
        // Dynamic JS import() — resolved via ready_scripts callback.
        import_async: ImportAsync,
        // <script> tag in a frame.
        frame: FrameExtra,

        pub const FrameExtra = struct {
            kind: Kind,
            mode: Mode,
            frame: *Frame,
            script_element: *Element.Html.Script,

            pub const Kind = enum {
                module,
                javascript,
                importmap,
            };

            pub const Mode = enum {
                // sync <script src="..."> — blocks parsing, evaluated
                // immediately at the end of addFromElement via syncRequest.
                normal,
                // <script defer> / <script type=module> — queued in
                // defer_scripts, drained in document order.
                @"defer",
                // <script async> — executes as soon as its fetch completes.
                async,
                // Dynamically inserted classic script with async=false:
                // fetch concurrently, execute strictly in insertion order.
                ordered,
            };
        };
    };

    fn execution(self: *const Script) *js.Execution {
        return switch (self.extra) {
            .frame => |fe| &fe.frame.js.execution,
            else => &self.manager.owner.jsContext().execution,
        };
    }

    fn deliverable(self: *const Script) bool {
        if (self.guard.isFinished()) return false;
        if (self.manager.shutdown) return false;
        return switch (self.extra) {
            // HTTP terminal callbacks can run after navigation abort while the
            // Script ctx is still alive. Do not read fe.frame — use manager.owner
            // (authoritative frame for this script manager) and bail on null.
            .frame => deliverableFrameScript(self),
            else => self.guard.isDeliverable(self.execution(), .{
                .manager_shutdown = false,
            }),
        };
    }

    fn deliverableFrameScript(self: *const Script) bool {
        const owner = self.manager.owner;
        const frame = owner.parentFrame();
        if (@intFromPtr(frame) == 0) return false;
        // Do NOT gate on navigationCritical here. Script HTTP can finish while
        // initiateRootNavigation/commitPendingPage holds the critical section
        // (tick/processMessages). Gating dropped doneCallback before complete=true
        // and left defer scripts incomplete forever (no DCL).
        return self.guard.isDeliverableForRealm(owner.captureTaskOwner(), .{
            .manager_shutdown = false,
            .realm_dead_or_draining = frame._realm_state == .dead or frame._realm_state == .draining,
            .going_away = frame.isGoingAway(),
        });
    }

    /// Authoritative frame for frame-attached scripts — never read fe.frame after
    /// navigation abort / commitPendingPage may have torn the extra pointer down.
    fn activeFrame(self: *const Script) ?*Frame {
        if (self.guard.isFinished()) return null;
        if (self.manager.shutdown) return null;
        return switch (self.extra) {
            .frame => blk: {
                const frame = self.manager.owner.parentFrame();
                if (@intFromPtr(frame) == 0) return null;
                if (frame.isGoingAway()) return null;
                if (frame._realm_state == .dead or frame._realm_state == .draining) return null;
                break :blk frame;
            },
            else => null,
        };
    }

    pub fn deinit(self: *Script) void {
        if (self.guard.isFinished()) return;
        self.guard.finished = true;
        // Detach HTTP ctx *before* freeing the Script arena so late transfer
        // callbacks see script == null instead of UAF (nytimes.com).
        if (self.http_ctx) |ctx| {
            self.http_ctx = null;
            self.manager.retireHttpCtx(ctx);
        }
        self.manager.releaseArena(self.arena);
    }

    fn frameIsGoingAway(self: *const Script) bool {
        return switch (self.extra) {
            .frame => |fe| fe.frame.isGoingAway(),
            else => false,
        };
    }

    /// HTTP callback context allocated with ScriptManager.allocator so it
    /// outlives Script arenas released on navigation/reset.
    pub const HttpCtx = struct {
        script: ?*Script,
        manager: *ScriptManagerBase,

        fn scriptOrNull(ctx: *anyopaque) ?*Script {
            const self: *HttpCtx = @ptrCast(@alignCast(ctx));
            const script = self.script orelse return null;
            if (script.guard.isFinished()) return null;
            return script;
        }

        pub fn shutdownCallback(ctx: *anyopaque) void {
            const self: *HttpCtx = @ptrCast(@alignCast(ctx));
            const script = self.script orelse return;
            // Null first so re-entrant paths cannot re-enter Script after free.
            self.script = null;
            if (script.http_ctx == self) script.http_ctx = null;
            if (!script.guard.isFinished()) {
                script.manager.scriptList(script).remove(&script.node);
                // deinit skips retire when http_ctx already nulled; we own free.
                script.guard.finished = true;
                script.manager.releaseArena(script.arena);
            }
            self.manager.retireHttpCtx(self);
        }

        pub fn startCallback(response: HttpClient.Response) !void {
            log.debug(.http, "script fetch start", .{ .req = response });
        }

        pub fn headerCallback(response: HttpClient.Response) !bool {
            const script = scriptOrNull(response.ctx) orelse return false;
            return script.headerCallback(response);
        }

        pub fn dataCallback(response: HttpClient.Response, data: []const u8) !void {
            const script = scriptOrNull(response.ctx) orelse return;
            try script.dataCallback(response, data);
        }

        pub fn doneCallback(ctx: *anyopaque) !void {
            const self: *HttpCtx = @ptrCast(@alignCast(ctx));
            const script = self.script orelse return;
            if (script.guard.isFinished()) return;
            try script.doneCallback();
        }

        pub fn errorCallback(ctx: *anyopaque, err: anyerror) void {
            const self: *HttpCtx = @ptrCast(@alignCast(ctx));
            const script = self.script orelse return;
            if (script.guard.isFinished()) return;
            script.errorCallback(err);
        }
    };

    pub fn shutdownCallback(ctx: *anyopaque) void {
        // Legacy direct Script ctx path (should not be used for new requests).
        const self: *Script = @ptrCast(@alignCast(ctx));
        if (self.guard.isFinished()) return;
        self.manager.scriptList(self).remove(&self.node);
        self.deinit();
    }

    pub fn startCallback(response: HttpClient.Response) !void {
        log.debug(.http, "script fetch start", .{ .req = response });
    }

    pub fn headerCallback(self: *Script, response: HttpClient.Response) !bool {
        self.status = response.status().?;
        if (response.status() != 200) {
            log.info(.http, "script header", .{
                .req = response,
                .status = response.status(),
                .content_type = response.contentType(),
            });
            return false;
        }

        if (self.extra == .import_async and
            !self.manager.owner.opaqueOriginAllowsModuleFetch(response, self.url))
        {
            log.debug(.http, "opaque origin dynamic import blocked", .{ .url = self.url });
            return false;
        }

        if (comptime IS_DEBUG) {
            log.debug(.http, "script header", .{
                .req = response,
                .status = response.status(),
                .content_type = response.contentType(),
            });
        }

        switch (response.inner) {
            .transfer => |transfer| {
                // temp debug, trying to figure out why the next assert sometimes
                // fails. Is the buffer just corrupt or is headerCallback really
                // being called twice?
                assert(self.header_callback_called == false, "ScriptManagerBase.Header recall", .{
                    .m = @tagName(std.meta.activeTag(self.extra)),
                    .a1 = self.debug_transfer_id,
                    .a2 = self.debug_transfer_tries,
                    .a3 = self.debug_transfer_aborted,
                    .a4 = self.debug_transfer_bytes_received,
                    .a5 = self.debug_transfer_notified_fail,
                    .a8 = self.debug_transfer_auth_challenge,
                    .a9 = self.debug_transfer_easy_id,
                    .b1 = transfer.id,
                    .b2 = transfer._tries,
                    .b3 = transfer.aborted,
                    .b4 = transfer.bytes_received,
                    .b5 = transfer._notified_fail,
                    .b8 = transfer._auth_challenge != null,
                    .b9 = if (transfer._conn) |c| @intFromPtr(c._easy) else 0,
                });
                self.header_callback_called = true;
                self.debug_transfer_id = transfer.id;
                self.debug_transfer_tries = transfer._tries;
                self.debug_transfer_aborted = transfer.aborted;
                self.debug_transfer_bytes_received = transfer.bytes_received;
                self.debug_transfer_notified_fail = transfer._notified_fail;
                self.debug_transfer_auth_challenge = transfer._auth_challenge != null;
                self.debug_transfer_easy_id = if (transfer._conn) |c| @intFromPtr(c._easy) else 0;
            },
            else => {},
        }

        assert(self.source.remote.capacity == 0, "ScriptManagerBase.Header buffer", .{ .capacity = self.source.remote.capacity });
        var buffer: std.ArrayList(u8) = .empty;
        if (response.contentLength()) |cl| {
            try buffer.ensureTotalCapacity(self.arena, cl);
        }
        self.source = .{ .remote = buffer };
        return true;
    }

    pub fn dataCallback(self: *Script, response: HttpClient.Response, data: []const u8) !void {
        self._dataCallback(response, data) catch |err| {
            log.err(.http, "SM.dataCallback", .{ .err = err, .transfer = response, .len = data.len });
            return err;
        };
    }

    fn _dataCallback(self: *Script, _: HttpClient.Response, data: []const u8) !void {
        try self.source.remote.appendSlice(self.arena, data);
    }

    pub fn doneCallback(self: *Script) !void {
        if (self.guard.isFinished() or self.manager.shutdown) return;

        // false (navigationCritical / draining) returned BEFORE complete=true, so
        // defer heads stayed incomplete forever → readyState stuck `loading`, no DCL.
        self.complete = true;
        if (comptime IS_DEBUG) {
            log.debug(.http, "script fetch complete", .{ .req = self.url });
        }

        const manager = self.manager;
        const can_deliver = self.deliverable();

        switch (self.extra) {
            .frame => |fe| switch (fe.mode) {
                .async => {
                    // Move to ready_scripts so completion is not blocked by an
                    // incomplete import head on async_scripts.
                    if (can_deliver) {
                        manager.async_scripts.remove(&self.node);
                        manager.ready_scripts.append(&self.node);
                    }
                },
                .ordered => {}, // stays queued; drained in insertion order
                .@"defer" => {}, // stays in defer_scripts; drained in order
                .normal => unreachable, // syncRequest path doesn't go through callbacks
            },
            .import_async => {
                if (can_deliver) {
                    manager.async_scripts.remove(&self.node);
                    manager.ready_scripts.append(&self.node);
                }
            },
            .import => {
                manager.async_scripts.remove(&self.node);
                const entry = manager.imported_modules.getPtr(self.url) orelse {
                    log.warn(.http, "module fetch done but entry missing", .{ .url = self.url });
                    self.deinit();
                    return;
                };
                log.debug(.js, "module fetch", .{ .url = self.url, .ptr = @intFromPtr(entry), .from = @tagName(entry.state), .to = "fetched" });
                entry.state = .{ .done = self };
                entry.buffer = self.source.remote;
            },
        }
        if (manager.shutdown) return;
        // While HTML parse / frameDoneCallback is still unwinding, queue
        // completions only — staticScriptsDone will drain ready/defer/async.
        if (!manager.static_scripts_done) return;

        // resume in the same processMessages chain (go.dev / netlify DCL).
        manager.evaluate();
    }

    pub fn errorCallback(self: *Script, err: anyerror) void {
        // Guard first: after kill/shutdown/reset the Script arena may already
        // be finished. deliverable() reads finished before any other fields.
        if (self.guard.isFinished()) return;
        if (self.manager.shutdown) {
            // Navigation/teardown already owns cleanup (clearList / kill
            // shutdown_callback). Do not remove from lists or evaluate.
            self.deinit();
            return;
        }
        const manager = self.manager;
        if (!self.deliverable()) {
            // Abort during navigation/teardown: drop incomplete defer/async heads so
            // DCL is not blocked forever (BBC guardian-class ghost heads).
            if (self.extra == .frame) {
                self.complete = true;
                manager.scriptList(self).remove(&self.node);
                self.deinit();
                if (!manager.shutdown) manager.scheduleDeferredEvaluate();
            }
            return;
        }
        if (self.status == 404) {
            log.info(.http, "script 404", .{
                .req = self.url,
                .extra = std.meta.activeTag(self.extra),
            });
        } else {
            log.warn(.http, "script fetch error", .{
                .err = err,
                .req = self.url,
                .extra = std.meta.activeTag(self.extra),
                .status = self.status,
            });
        }

        if (self.extra == .frame and self.extra.frame.mode == .normal) {
            // This is blocked in a loop at the end of addFromElement, setting
            // it to complete with a status of 0 will signal the error.
            self.status = 0;
            self.complete = true;
            return;
        }

        manager.scriptList(self).remove(&self.node);

        switch (self.extra) {
            .import_async => |ia| {
                if (self.deliverable()) ia.callback(ia.data, error.FailedToLoad);
            },
            .import => {
                if (manager.imported_modules.getPtr(self.url)) |entry| {
                    entry.state = .err;
                }
            },
            // Frame <script> fetch failures: remove from defer/async list (already
            // done above) and resume evaluate so DCL is not stuck forever waiting
            // on a head that will never complete. Use scheduleDeferredEvaluate
            // (not immediate evaluate) to avoid re-entering V8 from the HTTP tick
            // when unsafe — same safety goal as the old early-return, without

            .frame => {
                self.deinit();
                if (!manager.shutdown) manager.scheduleDeferredEvaluate();
                return;
            },
        }
        self.deinit();
        if (!manager.shutdown) manager.scheduleDeferredEvaluate();
    }

    fn pumpScriptScheduler(frame: *Frame, local: *const js.Local) void {
        // Fingerprint loader yb() may schedule 10ms iframe polls at the tail of
        // a long eval; drain overdue timers in a few passes so Y.ip settles.
        var pass: u8 = 0;
        while (pass < 12) : (pass += 1) {
            _ = frame.js.scheduler.run() catch |err| {
                log.err(.frame, "scheduler", .{ .err = err });
                break;
            };
            local.ctx.env.runMicrotasks(.after_evaluate);
            frame.pollCdpDuringLongWork();
            if (!frame.js.scheduler.hasReadyTasks()) break;
        }
    }

    /// Wall-clock watchdog: terminate isolate if a single script eval runs too long.
    /// eBay discoveryplatform modules have been observed to spin forever in V8,
    /// TerminateExecution usage.
    const ScriptEvalWatchdog = struct {
        thread: ?std.Thread = null,
        state: ?*State = null,

        const State = struct {
            env: *js.Env,
            deadline_ms: u64,
            cancel: std.atomic.Value(bool) = .init(false),
            fired: std.atomic.Value(bool) = .init(false),
        };

        fn start(env: *js.Env, timeout_ms: u64) !ScriptEvalWatchdog {
            const state = try std.heap.c_allocator.create(State);
            state.* = .{
                .env = env,
                .deadline_ms = timeout_ms,
            };
            const thread = std.Thread.spawn(.{}, run, .{state}) catch |err| {
                std.heap.c_allocator.destroy(state);
                return err;
            };
            return .{ .thread = thread, .state = state };
        }

        fn run(state: *State) void {
            const step_ns: u64 = 50 * std.time.ns_per_ms;
            var waited: u64 = 0;
            while (waited < state.deadline_ms * std.time.ns_per_ms) {
                if (state.cancel.load(.acquire)) return;
                std.Io.sleep(@import("../../support/io.zig").get(), .fromNanoseconds(step_ns), .awake) catch {};
                waited += step_ns;
            }
            if (state.cancel.load(.acquire)) return;
            state.fired.store(true, .release);
            log.warn(.js, "script eval watchdog terminate", .{ .ms = state.deadline_ms });
            state.env.terminate();
        }

        /// Returns true if the watchdog terminated execution.
        fn stop(self: *ScriptEvalWatchdog) bool {
            var fired = false;
            if (self.state) |state| {
                state.cancel.store(true, .release);
                fired = state.fired.load(.acquire);
            }
            if (self.thread) |t| {
                t.join();
            }
            if (self.state) |state| {
                fired = fired or state.fired.load(.acquire);
                state.env.cancelTerminate();
                std.heap.c_allocator.destroy(state);
            }
            self.thread = null;
            self.state = null;
            return fired;
        }
    };

    // Frame-only. Asserts extra == .frame; callers from the worker path never
    // reach here (workers only produce .import / .import_async).
    pub fn eval(self: *Script) void {
        const fe = self.extra.frame;
        const frame = self.activeFrame() orelse return;

        const previous_script = frame.document._current_script;
        frame.document._current_script = fe.script_element;
        defer frame.document._current_script = previous_script;

        // Clear the document.write insertion point for this script
        const previous_write_insertion_point = frame.document._write_insertion_point;
        frame.document._write_insertion_point = null;
        defer frame.document._write_insertion_point = previous_write_insertion_point;

        // inline scripts aren't cached. remote ones are.
        const cacheable = self.source == .remote;

        const url = self.url;
        const script_started = datetime.nanoTimestamp(.monotonic);
        defer {
            const elapsed = datetime.nanoTimestamp(.monotonic) - script_started;
            const duration_us: u64 = if (elapsed > 0) @intCast(@divTrunc(elapsed, std.time.ns_per_us)) else 0;
            frame._page.session.browser.observeBrowserScript(duration_us, frame._frame_id, frame._loader_id, url, @tagName(fe.kind));
        }

        log.info(.browser, "executing script", .{
            .src = url,
            .kind = fe.kind,
            .cacheable = cacheable,
        });

        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const local = &ls.local;

        // Handle importmap special case here: the content is a JSON containing
        // imports.
        if (fe.kind == .importmap) {
            frame._script_manager.parseImportmap(self) catch |err| {
                log.err(.browser, "parse importmap script", .{
                    .err = err,
                    .src = url,
                    .kind = fe.kind,
                    .cacheable = cacheable,
                });
                self.executeCallback(comptime .wrap("error"));
                return;
            };
            self.executeCallback(comptime .wrap("load"));
            return;
        }

        defer frame._event_manager.clearIgnoreList();

        // Remote modules (e.g. ebay.com discoveryplatform bundles) can infinite-
        // loop in V8 and freeze CDP. Arm a wall-clock watchdog that terminates
        // isolate execution; cancel after eval returns.
        const lifecycle_eval = self.manager.static_scripts_done;
        const remote_classic = fe.kind == .javascript and self.source != .@"inline";
        const inline_len: usize = switch (self.source) {
            .@"inline" => |c| c.len,
            .remote => 0,
        };
        // Watchdog only for runaway V8 (infinite loops). Short enough that
        // TerminateExecution fires before pure-JS recursion climbs into
        // V8_Fatal on a depleted C stack (stripe Next chunks). Not a DCL timer.
        const watchdog_ms: u64 = if (fe.kind == .module) 8_000 else if (lifecycle_eval and remote_classic) 3_000 else if (lifecycle_eval and fe.kind == .javascript) 2_500 else if (fe.mode == .async and cacheable) 4_000 else if (cacheable) 8_000 else if (!lifecycle_eval and inline_len > 96 * 1024) 5_000 else 0;
        var watchdog: ScriptEvalWatchdog = .{};
        if (watchdog_ms > 0) {
            if (ScriptEvalWatchdog.start(&frame._page.session.browser.env, watchdog_ms)) |w| {
                watchdog = w;
            } else |_| {}
        }
        defer {
            if (watchdog.stop()) {
                self.manager.watchdog_terminated = true;
                // Ensure isolate accepts subsequent lifecycle / CDP eval.
                frame._page.session.browser.env.cancelTerminate();
            }
        }

        const success = blk: {
            const content = self.source.content();
            if (jsCallLogEnabled()) {
                log.info(.js, "script call log source", .{ .src = url, .kind = fe.kind });
            }
            switch (fe.kind) {
                .javascript => {
                    const eval_content = blk2: {
                        if (jsCallLogEnabled()) {
                            break :blk2 instrumentClassicScript(frame.call_arena, content, url) catch break :blk false;
                        }
                        break :blk2 content;
                    };
                    _ = local.eval(eval_content, url) catch |err| {
                        log.warn(.js, "eval script", .{ .url = url, .err = err, .cacheable = cacheable });
                        break :blk false;
                    };
                    // Same-turn promise reactions only. Full 48-pass drain is for
                    // non-lifecycle paths; during evaluate() keep shallow.
                    frame.drainClassicScriptMicrotasks();
                },
                .module => {
                    // Module scripts: document.currentScript is always null.
                    const module_url = if (cacheable)
                        URL.resolve(frame.js.arena, frame.base(), url, .{ .always_dupe = true }) catch break :blk false
                    else
                        url;
                    frame.js.module(false, local, content, module_url, cacheable) catch |err| {
                        log.warn(.js, "eval module", .{ .url = url, .err = err, .cacheable = cacheable });
                        break :blk false;
                    };
                    frame.drainMicrotasksAfterDomInsertion();
                },
                .importmap => unreachable, // handled before the try/catch.
            }
            break :blk true;
        };

        if (comptime IS_DEBUG) {
            log.debug(.browser, "executed script", .{ .src = url, .success = success });
        }

        defer {
            // After a script body: microtasks only while the lifecycle evaluate()
            // window is open. Running the full scheduler here re-enters
            // DeferEvaluateCallback → nested evaluate → stacked Script.eval and
            // V8_Fatal. Runner macrotask loop drains timers after the hop.
            // Every classic script body is a microtask boundary, including parser
            // scripts before realmParseComplete. Native bindings only mark work
            // pending; they must never checkpoint while the JS stack is suspended.
            local.ctx.env.runMicrotasks(.after_evaluate);
            const should_pump = frame.realmParseComplete();
            if (should_pump) {
                // After classic/module body: microtasks always; EventLoop.spin when
                // not nested in lifecycle evaluate (nested re-entry → V8_Fatal).
                // No site URL specials (host event architecture 2026-07-19).
                const js_mod = @import("../js/js.zig");
                if (self.manager.is_evaluating) {
                    frame.scheduleDeferredMacrotaskPump(0) catch {};
                    local.ctx.env.runMicrotasks(.after_evaluate);
                } else {
                    frame.clearSchedulerSuppression();
                    // One shared spin path — avoid stacking settle + runMacrotasks + run.
                    js_mod.EventLoop.spin(&frame.js.execution, .{ .max_tasks = 64, .stop_when_idle = true });
                    // Single denser settle for pure-JS iframe await (no storm).
                    frame.settleIframePromisesNow();
                    local.ctx.env.runMicrotasks(.after_evaluate);
                }
            }
        }

        if (success) {
            self.executeCallback(comptime .wrap("load"));
            return;
        }

        self.executeCallback(comptime .wrap("error"));
    }

    const ElementCallbackType = enum { load, @"error" };

    const DeferredElementCallback = struct {
        manager: *ScriptManagerBase,
        frame: *Frame,
        element: *Element.Html.Script,
        typ: ElementCallbackType,
        guard: LoadGuard.Guard,

        fn run(ctx: *anyopaque) !?u32 {
            const self: *DeferredElementCallback = @ptrCast(@alignCast(ctx));
            const manager = self.manager;
            defer {
                if (manager.pending_element_callbacks > 0) {
                    manager.pending_element_callbacks -= 1;
                }

                if (!manager.shutdown and manager.pending_element_callbacks == 0) {
                    if (manager.hasPendingEvaluateWork() or manager.evaluate_pending) {
                        manager.evaluatePendingWhenCentral();
                    } else if (!manager.hasIncompleteLifecycleScripts()) {
                        if (manager.tail_hook) |hook| hook(manager);
                    }
                }
            }

            if (manager.shutdown or self.guard.isFinished()) return null;
            if (!self.guard.isDeliverableForRealm(self.frame.js.execution.captureTaskOwner(), .{
                .manager_shutdown = false,
                .realm_dead_or_draining = self.frame._realm_state == .dead or self.frame._realm_state == .draining,
                .going_away = self.frame.isGoingAway(),
            })) return null;

            const event_typ = switch (self.typ) {
                .load => String.wrap("load"),
                .@"error" => String.wrap("error"),
            };
            const Event = @import("../webapi/Event.zig");
            const event = try Event.initTrusted(event_typ, .{}, self.frame._page);
            self.frame._event_manager.dispatchOpts(
                self.element.asNode().asEventTarget(),
                event,
                .{ .apply_ignore = true },
            ) catch |err| {
                log.warn(.js, "deferred script callback", .{
                    .type = event_typ,
                    .err = err,
                });
            };
            return null;
        }
    };

    fn queueElementCallback(self: *const Script, typ: ElementCallbackType) !void {
        const fe = self.extra.frame;
        const frame = self.activeFrame() orelse return;
        const callback = try frame.arena.create(DeferredElementCallback);
        callback.* = .{
            .manager = self.manager,
            .frame = frame,
            .element = fe.script_element,
            .typ = typ,
            .guard = LoadGuard.Guard.init(&frame.js.execution),
        };
        self.manager.pending_element_callbacks += 1;
        frame.js.scheduler.add(callback, DeferredElementCallback.run, 0, .{
            .name = "ScriptManager.elementCallback",
            .low_priority = false,
        }) catch |err| {
            self.manager.pending_element_callbacks -= 1;
            return err;
        };
    }

    fn executeCallback(self: *const Script, typ: String) void {
        // Inline scripts do not have a resource-load lifecycle. Only external
        // scripts dispatch load/error on HTMLScriptElement.
        if (self.source == .@"inline") return;
        // Resource completion events are HTML tasks. Dispatching directly from
        // the fetch/evaluation pipeline re-enters page JavaScript before the
        // current host operation or framework commit has unwound. Keep every
        // external-script terminal event on the same owned scheduler path,
        // independent of whether the lifecycle evaluator happens to be active.
        const callback_typ: ElementCallbackType = if (typ.eql(comptime .wrap("load"))) .load else .@"error";
        self.queueElementCallback(callback_typ) catch |err| {
            log.warn(.js, "queue script callback", .{ .url = self.url, .type = typ, .err = err });
        };
    }
};

pub const ImportAsync = struct {
    data: *anyopaque,
    callback: ImportAsync.Callback,

    pub const Callback = *const fn (ptr: *anyopaque, result: anyerror!ModuleSource) void;
};

pub const ModuleSource = struct {
    shared: bool,
    script: *Script,
    buffer: std.ArrayList(u8),

    pub fn deinit(self: *ModuleSource) void {
        if (self.shared == false) {
            self.script.deinit();
        }
    }

    pub fn src(self: *const ModuleSource) []const u8 {
        return self.buffer.items;
    }
};

pub const ImportedModule = struct {
    state: State = .loading,
    buffer: std.ArrayList(u8) = .empty,

    pub const State = union(enum) {
        err,
        loading,
        done: *Script,
    };
};
