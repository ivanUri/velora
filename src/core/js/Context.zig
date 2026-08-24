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

const js = @import("js.zig");
const Env = @import("Env.zig");
const Origin = @import("Origin.zig");
const Scheduler = @import("Scheduler.zig");
const Execution = @import("Execution.zig");

const Frame = @import("../browser/Frame.zig");
const URL = @import("../browser/URL.zig");
const Page = @import("../browser/Page.zig");
const Session = @import("../browser/Session.zig");
const ScriptManagerBase = @import("../browser/ScriptManagerBase.zig");
const WorkerGlobalScope = @import("../webapi/WorkerGlobalScope.zig");

const RealmLifecycleKernel = @import("../../runtime/RealmLifecycleKernel.zig");

const v8 = js.v8;
const log = @import("../../support/log.zig");
const Caller = js.Caller;
const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

// Loosely maps to a Browser Page or Worker.
const Context = @This();

pub const GlobalScope = union(enum) {
    frame: *Frame,
    worker: *WorkerGlobalScope,

    pub fn base(self: GlobalScope) [:0]const u8 {
        return switch (self) {
            .frame => |frame| frame.base(),
            .worker => |worker| worker.base(),
        };
    }

    pub fn getJs(self: GlobalScope) *Context {
        return switch (self) {
            .frame => |frame| frame.js,
            .worker => |worker| worker.js,
        };
    }

    pub fn setJs(self: GlobalScope, ctx: *Context) void {
        switch (self) {
            .frame => |frame| frame.js = ctx,
            .worker => |worker| worker.js = ctx,
        }
    }
};

id: usize,
env: *Env,
global: GlobalScope,

// The Page this Context belongs to. For main-world frame contexts, this is
// the Page of the frame. For worker contexts, this is the Page of the
// worker's parent frame — a worker's v8 globals and identity tracking live
// on the same Page as its owning frame (worker dies with its page). The
// Session is always reachable via `page.session`.
page: *Page,

isolate: js.Isolate,

// Per-context microtask queue for isolation between contexts
microtask_queue: *v8.MicrotaskQueue,

// The v8::Global<v8::Context>. When necessary, we can create a v8::Local<<v8::Context>>
// from this, and we can free it when the context is done.
handle: v8.Global,

cpu_profiler: ?*v8.CpuProfiler = null,

heap_profiler: ?*v8.HeapProfiler = null,

/// Inspector `contextDestroyed` already sent for this V8 context (e.g. pending-
/// root swap tears down CDP mappings before the V8 context is freed).
_inspector_destroyed_notified: bool = false,

// references Env.templates
templates: []*const v8.FunctionTemplate,

// Arena for the lifetime of the context
arena: Allocator,

// The call_arena for this context. For main world contexts this is
// frame.call_arena. For isolated world contexts this is a separate arena
// owned by the IsolatedWorld.
call_arena: Allocator,

// Because calls can be nested (i.e.a function calling a callback),
// we can only reset the call_arena when call_depth == 0. If we were
// to reset it within a callback, it would invalidate the data of
// the call which is calling the callback.
call_depth: usize = 0,

/// Set when a native callback throws; Caller.deinit must not run a microtask
/// checkpoint or the pending exception is lost before script try/catch runs.
pending_callback_exception: bool = false,

terminal_resources: std.ArrayList(TerminalResource) = .empty,

// When a Caller is active (V8->Zig callback), this points to its Local.
// When null, Zig->V8 calls must create a js.Local.Scope and initialize via
// context.localScope
local: ?*const js.Local = null,

// The Local.Scope currently entered by Zig. This is intentionally separate
// from `local`: callers use `local == null` to decide whether they own the
// scope lifetime, while dispatch only needs to know whether it can reuse an
// already-entered context and HandleScope.
active_scope: ?*const js.Local = null,

// Internal exception helpers are persistent handles, not globalThis
// properties. Exposing engine plumbing as __koko* own properties is both a
// web-compat violation and a high-signal automation fingerprint.
construct_throw_helper: ?js.Function.Global = null,
rethrow_helper: ?js.Function.Global = null,
dom_exception_throw_helper: ?js.Function.Global = null,

origin: *Origin,

// Identity tracking for this context. For main world contexts, this points to
// Session's Identity. For isolated world contexts (CDP inspector), this points
// to IsolatedWorld's Identity. This ensures same-origin frames share object
// identity while isolated worlds have separate identity tracking.
identity: *js.Identity,

// Allocator to use for identity map operations. For main world contexts this is
// page.frame_arena, for isolated worlds it's the isolated world's arena.
identity_arena: Allocator,

// Unlike other v8 types, like functions or objects, modules are not shared
// across origins.
global_modules: std.ArrayList(v8.Global) = .empty,

// Our module cache: normalized module specifier => module.
module_cache: std.StringHashMapUnmanaged(ModuleEntry) = .empty,

// Module => Path. The key is the module hashcode (module.getIdentityHash)
// and the value is the full path to the module. We need to capture this
// so that when we're asked to resolve a dependent module, and all we're
// given is the specifier, we can form the full path. The full path is
// necessary to lookup/store the dependent module in the module_cache.
module_identifier: std.AutoHashMapUnmanaged(u32, [:0]const u8) = .empty,

// Module-loading plumbing. Frame contexts point at the ScriptManager's
// embedded Base; worker contexts point at WorkerGlobalScope's Base directly.
script_manager: *ScriptManagerBase,

// Our macrotasks
scheduler: Scheduler,

/// Rejected promises awaiting HTML's "notify about rejected promises" step.
/// V8 reports `kPromiseRejectWithNoHandler` at rejection time, before the
/// current JavaScript job has had a chance to attach a handler. Browsers defer
/// the DOM event until a later task and cancel it when V8 subsequently reports
/// `kPromiseHandlerAddedAfterReject` in the same turn.
pending_promise_rejections: std.ArrayListUnmanaged(*PendingPromiseRejection) = .empty,

// Execution context for worker-compatible APIs. This provides a common
// interface that works in both Page and Worker contexts.
execution: Execution,

unknown_properties: (if (IS_DEBUG) std.StringHashMapUnmanaged(UnknownPropertyStat) else void) = if (IS_DEBUG) .{} else {},

const TerminalResource = struct {
    ptr: *anyopaque,
    invalidate: *const fn (*anyopaque) void,
};

pub fn trackTerminalResource(
    self: *Context,
    ptr: *anyopaque,
    invalidate: *const fn (*anyopaque) void,
) !void {
    try self.terminal_resources.append(self.arena, .{ .ptr = ptr, .invalidate = invalidate });
}

pub fn untrackTerminalResource(self: *Context, ptr: *anyopaque) void {
    for (self.terminal_resources.items, 0..) |resource, i| {
        if (resource.ptr == ptr) {
            _ = self.terminal_resources.swapRemove(i);
            return;
        }
    }
}

fn invalidateTerminalResources(self: *Context) void {
    while (self.terminal_resources.pop()) |resource| {
        resource.invalidate(resource.ptr);
    }
}

pub const PendingPromiseRejection = struct {
    context: *Context,
    promise: js.Promise.Global,
    reason: ?js.Value.Global,
    state: enum { pending, reported, handled } = .pending,
    notify_handled: bool = false,
};

const ModuleEntry = struct {
    // Can be null if we're asynchronously loading the module, in
    // which case resolver_promise cannot be null.
    module: ?js.Module.Global = null,
    state: State = .uninitialized,
    evaluate_count: u32 = 0,

    // The promise of the evaluating module. The resolved value is
    // meaningless to us, but the resolver promise needs to chain
    // to this, since we need to know when it's complete.
    module_promise: ?js.Promise.Global = null,

    // `waitForImport` consumes preloaded source. If resolution happens before
    // the top-level script reaches evaluation, keep the source for that pass.
    source: ?ScriptManagerBase.ModuleSource = null,

    // The promise for the resolver which is loading the module.
    // (AKA, the first time we try to load it). This resolver will
    // chain to the module_promise  and, when it's done evaluating
    // will resolve its namespace. Any other attempt to load the
    // module willchain to this.
    resolver_promise: ?js.Promise.Global = null,

    const State = enum {
        uninitialized,
        fetching,
        fetched,
        parsed,
        instantiated,
        evaluating,
        evaluated,
        errored,
    };
};

pub fn fromC(c_context: *const v8.Context) ?*Context {
    const ptr = v8.v8__Context__GetAlignedPointerFromEmbedderData(c_context, 1) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

/// Returns the Context and v8::Context for the given isolate.
/// If the current context is from a destroyed Context (e.g., navigated-away iframe),
/// falls back to the incumbent context (the calling context).
/// Returns null if neither context has a valid Context struct (both were destroyed).
pub fn fromIsolate(isolate: js.Isolate) ?struct { *Context, *const v8.Context } {
    const v8_context = v8.v8__Isolate__GetCurrentContext(isolate.handle) orelse return null;
    if (fromC(v8_context)) |ctx| {
        return .{ ctx, v8_context };
    }
    // The current context's Context struct has been freed (e.g., iframe navigated away).
    // Fall back to the incumbent context (the calling context).
    const v8_incumbent = v8.v8__Isolate__GetIncumbentContext(isolate.handle) orelse return null;
    const ctx = fromC(v8_incumbent) orelse return null;
    return .{ ctx, v8_incumbent };
}

pub fn deinit(self: *Context) void {
    if (comptime IS_DEBUG and @import("builtin").is_test == false) {
        var it = self.unknown_properties.iterator();
        while (it.next()) |kv| {
            log.debug(.unknown_prop, "unknown property", .{
                .property = kv.key_ptr.*,
                .occurrences = kv.value_ptr.count,
                .first_stack = kv.value_ptr.first_stack,
            });
        }
    }

    const env = self.env;
    // Break cross-realm native ownership edges before this Context and its
    // Execution storage can be reclaimed. The callback must not enter JS.
    self.invalidateTerminalResources();
    defer env.app.arena_pool.release(self.arena);

    // Scheduler tasks own frame/worker arenas and must be finalized even when
    // the V8 context can no longer be entered (for example after a stale
    // iframe realm is detached during shutdown).  Returning before this
    // cleanup leaves Window.postMessage callbacks tracked by ArenaPool and
    // turns a recoverable teardown race into a debug panic.
    self.scheduler.deinit();

    // These are Context-owned terminal resources, not operations on the JS
    // realm. A detached/stale iframe can no longer be entered, but it must
    // still release them exactly once.
    defer self.page.releaseOrigin(self.origin);
    defer v8.v8__Global__Reset(&self.handle);
    defer v8.v8__MicrotaskQueue__DELETE(self.microtask_queue);

    for (self.global_modules.items) |*global| {
        v8.v8__Global__Reset(global);
    }

    var hs: js.HandleScope = undefined;
    const entered = self.enter(&hs) orelse {
        env.isolate.notifyContextDisposed();
        return;
    };
    defer entered.exit();

    // Clear the embedder data so that if V8 keeps this context alive
    // (because objects created in it are still referenced), we don't
    // have a dangling pointer to our freed Context struct.
    v8.v8__Context__SetAlignedPointerInEmbedderData(entered.handle, 1, null);

    env.isolate.notifyContextDisposed();
    // There can be other tasks associated with this context that we need to
    // purge while the context is still alive.
    _ = env.pumpMessageLoop();
}

pub fn setOrigin(self: *Context, key: ?[]const u8) !void {
    if (comptime IS_DEBUG) {
        // A frame starts off with an opaque origin. The first setOrigin call must
        // release that opaque origin (not stored in Page.origins). Redirects may
        // call setOrigin again after a real origin is already installed.
        const is_opaque = self.page.origins.get(self.origin.key) == null;
        if (is_opaque) {
            assert(self.origin.rc == 1, "Ref opaque origin", .{ .rc = self.origin.rc });
        }
    }

    const origin = try self.page.getOrCreateOrigin(key);

    self.page.releaseOrigin(self.origin);
    self.origin = origin;

    self.installOriginSecurityToken(origin);
}

/// Inherit an existing origin identity, including an opaque origin.
///
/// `about:blank` and `about:srcdoc` child browsing contexts inherit the
/// creator's origin object. Reconstructing that identity from the serialized
/// origin is insufficient: opaque origins deliberately have no serialized
/// key and two independently-created opaque origins are cross-origin.
pub fn inheritOrigin(self: *Context, origin: *Origin) void {
    if (self.origin == origin) return;
    origin.rc += 1;
    self.page.releaseOrigin(self.origin);
    self.origin = origin;
    self.installOriginSecurityToken(origin);
}

fn installOriginSecurityToken(self: *Context, origin: *Origin) void {
    const isolate = self.env.isolate;
    {
        var ls: js.Local.Scope = undefined;
        self.localScope(&ls);
        defer ls.deinit();

        // Set the V8::Context SecurityToken, which is a big part of what allows
        // one context to access another.
        const token_local = v8.v8__Global__Get(&origin.security_token, isolate.handle);
        v8.v8__Context__SetSecurityToken(ls.local.handle, token_local);
    }
}

pub fn trackGlobal(self: *Context, global: v8.Global) !void {
    return self.page.globals.append(self.page.frame_arena, global);
}

pub fn trackTemp(self: *Context, global: v8.Global) !void {
    return self.page.temps.put(self.page.frame_arena, global.data_ptr, global);
}

pub const IdentityResult = struct {
    value_ptr: *v8.Global,
    found_existing: bool,
};

pub fn addIdentity(self: *Context, ptr: usize) !IdentityResult {
    self.page.flushPendingIdentityRemovals();
    const gop = try self.identity.identity_map.getOrPut(self.identity_arena, ptr);
    return .{
        .value_ptr = gop.value_ptr,
        .found_existing = gop.found_existing,
    };
}

/// Install `ctx.local` while the context is already entered (native microtasks).
/// Does not call `Context::Enter` — only adds a HandleScope for locals.
pub const InstalledLocal = struct {
    scope: js.Local.Scope,
    prev: ?*const js.Local,

    /// Initialize in caller-owned storage. HandleScope stores its own address
    /// inside V8, so returning an initialized InstalledLocal by value would
    /// leave V8 pointing at the temporary struct used during `install`.
    pub fn install(self: *InstalledLocal, ctx: *Context) void {
        self.* = .{ .scope = undefined, .prev = ctx.local };
        js.HandleScope.init(&self.scope.handle_scope, ctx.isolate);
        const handle_ptr = v8.v8__Global__Get(&ctx.handle, ctx.isolate.handle).?;
        self.scope.local = .{
            .ctx = ctx,
            .isolate = ctx.isolate,
            .handle = @ptrCast(handle_ptr),
            .call_arena = ctx.call_arena,
        };
        ctx.local = &self.scope.local;
    }

    pub fn deinit(self: *InstalledLocal, ctx: *Context) void {
        ctx.local = self.prev;
        self.scope.handle_scope.deinit();
    }
};

// Any operation on the context have to be made from a local.
// Returns false when the V8 context Global is empty (e.g. after destroyContext
// during Page/Frame teardown). Callers must not use `ls` when false.
// HandleScope must be entered before Global::Get (V8 requires it).
pub fn tryLocalScope(self: *Context, ls: *js.Local.Scope) bool {
    const isolate = self.isolate;
    js.HandleScope.init(&ls.handle_scope, isolate);
    const local_v8_context_opt = v8.v8__Global__Get(&self.handle, isolate.handle) orelse {
        ls.handle_scope.deinit();
        return false;
    };
    const local_v8_context: *const v8.Context = @ptrCast(local_v8_context_opt);
    v8.v8__Context__Enter(local_v8_context);

    // TODO: add and init ls.hs  for the handlescope
    ls.local = .{
        .ctx = self,
        .isolate = isolate,
        .handle = local_v8_context,
        .call_arena = self.call_arena,
    };

    // Publish the scope for the lifetime of the HandleScope. Event dispatch
    // can be entered from these Zig-owned callbacks (not only from a V8
    // Caller), so the Context needs a separate active-scope marker. This
    // prevents dispatchDirect from creating a nested Local.Scope and running
    // a nested microtask checkpoint while a Worker message callback is active.
    ls.ctx = self;
    ls.prev_active_scope = self.active_scope;
    self.active_scope = &ls.local;
    return true;
}

pub fn localScope(self: *Context, ls: *js.Local.Scope) void {
    if (!self.tryLocalScope(ls)) {
        log.err(.js, "localScope after context destroyed", .{});
        @panic("localScope called after V8 context destroyed");
    }
}

pub fn toLocal(self: *Context, global: anytype) js.Local.ToLocalReturnType(@TypeOf(global)) {
    const l = self.local orelse @panic("toLocal called without active Caller context");
    return l.toLocal(global);
}

pub fn getIncumbent(self: *Context) *Frame {
    const ctx = fromC(v8.v8__Isolate__GetIncumbentContext(self.env.isolate.handle).?).?;
    return switch (ctx.global) {
        .frame => |frame| frame,
        .worker => unreachable,
    };
}

/// The frame whose JavaScript realm is currently executing. This differs from
/// the relevant realm of a cross-origin platform object: code in a child frame
/// can invoke a method on its parent's WindowProxy while the current realm is
/// still the child. Callers that need the incumbent settings object must
/// preserve that distinction.
pub fn getCurrentFrame(self: *Context) ?*Frame {
    const v8_current = v8.v8__Isolate__GetCurrentContext(self.env.isolate.handle) orelse return null;
    const ctx = fromC(v8_current) orelse return null;
    return switch (ctx.global) {
        .frame => |frame| frame,
        .worker => null,
    };
}

/// HTML entry settings object — last context entered via the embedder, or the
/// microtask's entry realm while running promise reactions.
pub fn getEntryFrame(self: *Context) ?*Frame {
    const v8_entry = v8.v8__Isolate__GetEnteredOrMicrotaskContext(self.env.isolate.handle) orelse return null;
    const ctx = fromC(v8_entry) orelse return null;
    return switch (ctx.global) {
        .frame => |frame| frame,
        .worker => null,
    };
}

pub fn stringToPersistedFunction(
    self: *Context,
    function_body: []const u8,
    comptime parameter_names: []const []const u8,
    extensions: []const *const v8.Object,
) !js.Function.Global {
    var ls: js.Local.Scope = undefined;
    self.localScope(&ls);
    defer ls.deinit();

    const js_function = try ls.local.compileFunction(function_body, parameter_names, extensions);
    return js_function.persist();
}

pub fn module(self: *Context, comptime want_result: bool, local: *const js.Local, src: []const u8, url: []const u8, cacheable: bool) !(if (want_result) ModuleEntry else void) {
    const mod, const owned_url = blk: {
        const arena = self.arena;

        // gop will _always_ initiated if cacheable == true
        var gop: std.StringHashMapUnmanaged(ModuleEntry).GetOrPutResult = undefined;
        if (cacheable) {
            gop = try self.module_cache.getOrPut(arena, url);
            if (gop.found_existing) {
                log.debug(.js, "module cache hit", .{ .url = url, .state = @tagName(gop.value_ptr.state), .ptr = @intFromPtr(gop.value_ptr) });
                if (gop.value_ptr.module) |cache_mod| {
                    const mod = local.toLocal(cache_mod);
                    if (gop.value_ptr.module_promise != null or gop.value_ptr.state == .evaluating or gop.value_ptr.state == .evaluated) {
                        return if (comptime want_result) gop.value_ptr.* else {};
                    }

                    const status = mod.getStatus();
                    if (status == .kEvaluated or status == .kEvaluating) {
                        const module_resolver = local.createPromiseResolver();
                        module_resolver.resolve("resolve module", mod.getModuleNamespace());
                        _ = try module_resolver.persist();
                        gop.value_ptr.module_promise = try module_resolver.promise().persist();
                        gop.value_ptr.state = .evaluated;
                        return if (comptime want_result) gop.value_ptr.* else {};
                    }

                    if (status == .kUninstantiated) {
                        log.debug(.js, "module instantiate", .{ .url = url });
                        if (try mod.instantiate(resolveModuleCallback) == false) {
                            gop.value_ptr.state = .errored;
                            return error.ModuleInstantiationError;
                        }
                        gop.value_ptr.state = .instantiated;
                    }

                    return self.evaluateModule(want_result, mod, url, true);
                }
            } else {
                // first time seeing this
                const owned_key = try arena.dupeZ(u8, url);
                gop.key_ptr.* = owned_key;
                gop.value_ptr.* = .{};
            }
        }

        const owned_url = if (cacheable) blk_url: {
            const key = gop.key_ptr.*;
            break :blk_url key.ptr[0..key.len :0];
        } else try arena.dupeZ(u8, url);
        if (cacheable and !gop.found_existing) {
            gop.key_ptr.* = owned_url;
        }
        const source = if (cacheable) blk_src: {
            if (gop.value_ptr.source) |module_source| {
                break :blk_src module_source.src();
            }
            break :blk_src src;
        } else src;
        log.debug(.js, "module compile", .{ .url = owned_url, .ptr = if (cacheable) @intFromPtr(gop.value_ptr) else 0 });
        const m = try compileModule(local, source, owned_url);

        if (cacheable) {
            // compileModule is synchronous - nothing can modify the cache during compilation
            assert(gop.value_ptr.module == null, "Context.module has module", .{});
            gop.value_ptr.module = try m.persist();
            gop.value_ptr.state = .parsed;
        }

        break :blk .{ m, owned_url };
    };

    try self.postCompileModule(mod, owned_url, local);

    log.debug(.js, "module instantiate", .{ .url = owned_url });
    if (try mod.instantiate(resolveModuleCallback) == false) {
        if (cacheable) self.module_cache.getPtr(owned_url).?.state = .errored;
        return error.ModuleInstantiationError;
    }
    if (cacheable) self.module_cache.getPtr(owned_url).?.state = .instantiated;

    return self.evaluateModule(want_result, mod, owned_url, cacheable);
}

fn drainAfterModuleEvaluate(self: *Context) void {
    // Generic multi-pass microtask drain (no site specials). Avoid full
    // drainNestedHostMicrotasks here — re-enters during module eval.
    var pass: u8 = 0;
    while (pass < 32) : (pass += 1) {
        self.env.performMicrotaskCheckpoint(self);
        if (self.env.checkpoint_active) break;
        self.env.runMicrotasks(.after_evaluate);
        if (!self.env.checkpoint_pending) break;
    }
    switch (self.global) {
        .frame => |frame| {
            frame.drainMicrotasksAfterDomInsertion();
        },
        .worker => {},
    }
}

fn evaluateModule(self: *Context, comptime want_result: bool, mod: js.Module, url: []const u8, cacheable: bool) !(if (want_result) ModuleEntry else void) {
    if (cacheable) {
        const entry = self.module_cache.getPtr(url).?;
        if (entry.module_promise != null or entry.state == .evaluating or entry.state == .evaluated) {
            return if (comptime want_result) entry.* else {};
        }
        entry.state = .evaluating;
        entry.evaluate_count += 1;
        if (comptime IS_DEBUG) {
            std.debug.assert(entry.evaluate_count == 1);
        }
        if (entry.evaluate_count > 1) {
            log.warn(.js, "module duplicate evaluate", .{ .url = url, .count = entry.evaluate_count, .ptr = @intFromPtr(entry) });
        } else {
            log.debug(.js, "module evaluate", .{ .url = url, .ptr = @intFromPtr(entry) });
        }
    }

    const evaluated = mod.evaluate() catch {
        if (comptime IS_DEBUG) {
            std.debug.assert(mod.getStatus() == .kErrored);
        }

        // Some module-loading errors aren't handled by TryCatch. We need to
        // get the error from the module itself.
        const message = blk: {
            const e = mod.getException().toString() catch break :blk "???";
            break :blk e.toSlice() catch "???";
        };
        log.warn(.js, "evaluate module", .{
            .message = message,
            .specifier = url,
        });
        if (cacheable) self.module_cache.getPtr(url).?.state = .errored;
        return error.EvaluationError;
    };

    // https://v8.github.io/api/head/classv8_1_1Module.html#a1f1758265a4082595757c3251bb40e0f
    // Must be a promise that gets returned here.
    assert(evaluated.isPromise(), "Context.module non-promise", .{});

    // Fingerprint loader yb() starts during module eval; iframe Promise reactions
    // and await continuations must settle before callers race Y.ip.
    self.drainAfterModuleEvaluate();

    if (!cacheable) {
        switch (comptime want_result) {
            false => return,
            true => unreachable,
        }
    }

    // entry has to have been created atop this function
    const entry = self.module_cache.getPtr(url).?;

    // and the module must have been set after we compiled it
    assert(entry.module != null, "Context.module with module", .{});
    if (entry.module_promise != null) {
        // While loading this script, it's possible that it was dynamically
        // included (either the module dynamically loaded itself (unlikely) or
        // it included a script which dynamically imported it). If it was, then
        // the module_promise would already be setup, and we don't need to do
        // anything
    } else {
        // The *much* more likely case where the module we're trying to load
        // didn't [directly or indirectly] dynamically load itself.
        entry.module_promise = try evaluated.toPromise().persist();
    }
    entry.state = .evaluated;
    return if (comptime want_result) entry.* else {};
}

fn compileModule(local: *const js.Local, src: []const u8, name: []const u8) !js.Module {
    var origin_handle: v8.ScriptOrigin = undefined;
    v8.v8__ScriptOrigin__CONSTRUCT2(
        &origin_handle,
        local.isolate.initStringHandle(name),
        0, // resource_line_offset
        0, // resource_column_offset
        false, // resource_is_shared_cross_origin
        -1, // script_id
        null, // source_map_url
        false, // resource_is_opaque
        false, // is_wasm
        true, // is_module
        null, // host_defined_options
    );

    var source_handle: v8.ScriptCompilerSource = undefined;
    v8.v8__ScriptCompiler__Source__CONSTRUCT2(
        local.isolate.initStringHandle(src),
        &origin_handle,
        null, // cached data
        &source_handle,
    );

    defer v8.v8__ScriptCompiler__Source__DESTRUCT(&source_handle);

    const module_handle = v8.v8__ScriptCompiler__CompileModule(
        local.isolate.handle,
        &source_handle,
        v8.kNoCompileOptions,
        v8.kNoCacheNoReason,
    ) orelse {
        return error.JsException;
    };

    return .{
        .local = local,
        .handle = module_handle,
    };
}

// After we compile a module, whether it's a top-level one, or a nested one,
// we always want to track its identity (so that, if this module imports other
// modules, we can resolve the full URL), and preload any dependent modules.
fn postCompileModule(self: *Context, mod: js.Module, url: [:0]const u8, local: *const js.Local) !void {
    try self.module_identifier.putNoClobber(self.arena, mod.getIdentityHash(), url);
    log.debug(.js, "module parse", .{ .url = url, .module = mod.getIdentityHash() });

    // Non-async modules are blocking. We can download them in parallel, but
    // they need to be processed serially. So we want to get the list of
    // dependent modules this module has and start downloading them asap.
    const requests = mod.getModuleRequests();
    const request_len = requests.len();
    const script_manager = self.script_manager;
    for (0..request_len) |i| {
        const specifier = requests.get(i).specifier(local);
        const normalized_specifier = try script_manager.resolveSpecifier(
            self.call_arena,
            url,
            try specifier.toSliceZ(),
        );
        const nested_gop = try self.module_cache.getOrPut(self.arena, normalized_specifier);
        if (!nested_gop.found_existing) {
            const owned_specifier = try self.arena.dupeZ(u8, normalized_specifier);
            nested_gop.key_ptr.* = owned_specifier;
            nested_gop.value_ptr.* = .{};
            nested_gop.value_ptr.state = .fetching;
            try script_manager.preloadImport(owned_specifier, url);
            if (script_manager.imported_modules.get(owned_specifier)) |im| {
                if (im.state == .done) {
                    nested_gop.value_ptr.state = .fetched;
                }
            }
        } else if (nested_gop.value_ptr.module == null) {
            // Entry exists but module failed to compile previously.
            // The imported_modules entry may have been consumed, so
            // re-preload to ensure waitForImport can find it.
            // Key was stored via dupeZ so it has a sentinel in memory.
            const key = nested_gop.key_ptr.*;
            const key_z: [:0]const u8 = key.ptr[0..key.len :0];
            if (nested_gop.value_ptr.state == .uninitialized) nested_gop.value_ptr.state = .fetching;
            try script_manager.preloadImport(key_z, url);
            if (script_manager.imported_modules.get(key_z)) |im| {
                if (im.state == .done) {
                    nested_gop.value_ptr.state = .fetched;
                }
            }
        }
    }
}

fn newFunctionWithData(local: *const js.Local, comptime callback: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void, data: *anyopaque) js.Function {
    const external = local.isolate.createExternal(data);
    const handle = v8.v8__Function__New__DEFAULT2(local.handle, callback, @ptrCast(external)).?;
    return .{
        .local = local,
        .handle = handle,
    };
}

// == Callbacks ==
// Callback from V8, asking us to load a module. The "specifier" is
// the src of the module to load.
fn resolveModuleCallback(
    c_context: ?*const v8.Context,
    c_specifier: ?*const v8.String,
    import_attributes: ?*const v8.FixedArray,
    c_referrer: ?*const v8.Module,
) callconv(.c) ?*const v8.Module {
    _ = import_attributes;

    const self = fromC(c_context.?).?;
    const local = js.Local{
        .ctx = self,
        .handle = c_context.?,
        .isolate = self.isolate,
        .call_arena = self.call_arena,
    };

    const specifier = js.String.toSliceZ(.{ .local = &local, .handle = c_specifier.? }) catch |err| {
        log.err(.js, "resolve module", .{ .err = err });
        return null;
    };
    const referrer = js.Module{ .local = &local, .handle = c_referrer.? };

    return self._resolveModuleCallback(referrer, specifier, &local) catch |err| {
        log.err(.js, "resolve module", .{
            .err = err,
            .specifier = specifier,
        });
        return null;
    };
}

/// Base URL for dynamic `import()` when V8 omits referrer (eval/import in module workers).
fn dynamicImportReferrerBase(self: *Context, resource_name: ?[:0]const u8) [:0]const u8 {
    if (resource_name) |name| {
        if (name.len > 0 and URL.canParse(name, null)) return name;
    }

    const global_base = self.global.base();
    if (std.mem.startsWith(u8, global_base, "blob:") or std.mem.startsWith(u8, global_base, "data:")) {
        if (self.preferredModuleReferrerBase()) |http_base| return http_base;
    }
    return global_base;
}

/// HTTP module URL for blob:/data: entry workers (exclude leaf modules like export-on-load).
fn preferredModuleReferrerBase(self: *Context) ?[:0]const u8 {
    var it = self.module_identifier.valueIterator();
    var candidate: ?[:0]const u8 = null;
    while (it.next()) |url| {
        const u = url.*;
        if (!std.mem.startsWith(u8, u, "http://") and !std.mem.startsWith(u8, u, "https://")) continue;
        if (std.mem.endsWith(u8, u, "export-on-load-script.js")) continue;
        candidate = u;
    }
    return candidate;
}

pub fn dynamicModuleCallback(
    c_context: ?*const v8.Context,
    host_defined_options: ?*const v8.Data,
    resource_name: ?*const v8.Value,
    v8_specifier: ?*const v8.String,
    import_attrs: ?*const v8.FixedArray,
) callconv(.c) ?*v8.Promise {
    _ = host_defined_options;
    _ = import_attrs;

    const self = fromC(c_context.?).?;
    const local = js.Local{
        .ctx = self,
        .handle = c_context.?,
        .call_arena = self.call_arena,
        .isolate = self.isolate,
    };

    const resource_name_str = blk: {
        const resource_value = js.Value{ .handle = resource_name.?, .local = &local };
        if (resource_value.isNullOrUndefined()) break :blk null;

        const resource_str = js.String.toSliceZ(.{ .local = &local, .handle = resource_name.? }) catch |err| {
            log.err(.app, "OOM", .{ .err = err, .src = "dynamicModuleCallback1" });
            return @constCast(local.rejectPromise(.{ .generic_error = "Out of memory" }).handle);
        };
        if (resource_str.len == 0) break :blk null;
        break :blk resource_str;
    };

    const specifier = js.String.toSliceZ(.{ .local = &local, .handle = v8_specifier.? }) catch |err| {
        log.err(.app, "OOM", .{ .err = err, .src = "dynamicModuleCallback2" });
        return @constCast(local.rejectPromise(.{ .generic_error = "Out of memory" }).handle);
    };

    const import_base = self.dynamicImportReferrerBase(resource_name_str);

    const normalized_specifier = self.script_manager.resolveSpecifier(
        self.arena, // might need to survive until the module is loaded
        import_base,
        specifier,
    ) catch |err| {
        log.err(.app, "dynamic import resolve failed", .{
            .err = err,
            .resource = resource_name_str,
            .import_base = import_base,
            .specifier = specifier,
            .global_base = self.global.base(),
        });
        return @constCast(local.rejectPromise(.{ .generic_error = "Out of memory" }).handle);
    };

    const promise = self._dynamicModuleCallback(normalized_specifier, import_base, &local) catch |err| blk: {
        log.err(.js, "dynamic module callback", .{
            .err = err,
        });
        break :blk local.rejectPromise(.{ .generic_error = "Out of memory" });
    };
    return @constCast(promise.handle);
}

/// State threaded into the import.meta.resolve() native function.
/// Lifetime: context arena — valid for the duration of the context.
const ImportMetaResolveData = struct {
    context: *Context,
    base_url: [:0]const u8,
};

pub fn metaObjectCallback(c_context: ?*v8.Context, c_module: ?*v8.Module, c_meta: ?*v8.Value) callconv(.c) void {
    const self = fromC(c_context.?).?;
    var local = js.Local{
        .ctx = self,
        .handle = c_context.?,
        .isolate = self.isolate,
        .call_arena = self.call_arena,
    };

    const m = js.Module{ .local = &local, .handle = c_module.? };
    const meta = js.Object{ .local = &local, .handle = @ptrCast(c_meta.?) };

    const url = self.module_identifier.get(m.getIdentityHash()) orelse {
        log.err(.js, "import meta", .{ .err = error.UnknownModuleReferrer });
        return;
    };

    // Set import.meta.url
    const js_url = local.zigValueToJs(url, .{}) catch {
        log.err(.js, "import meta", .{ .err = error.FailedToConvertUrl });
        return;
    };
    const set_url = meta.defineOwnProperty("url", js_url, 0) orelse false;
    if (!set_url) {
        log.err(.js, "import meta", .{ .err = error.FailedToSet });
    }

    // Set import.meta.resolve(specifier) — synchronous, returns absolute URL string.
    // Per HTML spec §8.1.6.6: import.meta.resolve is a synchronous function.
    const resolve_data = self.arena.create(ImportMetaResolveData) catch {
        log.err(.js, "import meta resolve alloc", .{ .err = error.OutOfMemory });
        return;
    };
    resolve_data.* = .{
        .context = self,
        .base_url = url,
    };

    const resolve_fn = newFunctionWithData(&local, importMetaResolveCallback, resolve_data);
    const js_resolve = local.zigValueToJs(resolve_fn, .{}) catch {
        log.err(.js, "import meta", .{ .err = error.FailedToConvertResolve });
        return;
    };
    const set_resolve = meta.defineOwnProperty("resolve", js_resolve, 0) orelse false;
    if (!set_resolve) {
        log.err(.js, "import meta", .{ .err = error.FailedToSetResolve });
    }
}

/// Native callback for import.meta.resolve(specifier).
/// Synchronously resolves specifier relative to the module's base URL.
/// Returns the absolute URL string, or throws TypeError on invalid input.
fn importMetaResolveCallback(callback_handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
    var c: Caller = undefined;
    if (!c.initFromHandle(callback_handle)) return;
    defer c.deinit();

    const info = Caller.FunctionCallbackInfo{ .handle = callback_handle.? };
    const local = &c.local;
    const isolate = local.isolate;

    const data: *ImportMetaResolveData = @ptrCast(@alignCast(info.getData() orelse {
        _ = isolate.throwException(isolate.createTypeError("import.meta.resolve: missing data"));
        return;
    }));

    // Guard against stale context (e.g. navigated iframe)
    if (data.context.id != local.ctx.id) {
        _ = isolate.throwException(isolate.createTypeError("import.meta.resolve: stale context"));
        return;
    }

    const self = data.context;

    if (info.length() < 1) {
        _ = isolate.throwException(isolate.createTypeError("import.meta.resolve requires 1 argument"));
        return;
    }

    const arg0_val = info.getArg(0, local);

    if (arg0_val.isNullOrUndefined()) {
        _ = isolate.throwException(isolate.createTypeError("import.meta.resolve: specifier must be a string"));
        return;
    }

    const specifier = (js.String{ .local = local, .handle = @ptrCast(arg0_val.handle) }).toSliceZ() catch {
        _ = isolate.throwException(isolate.createTypeError("import.meta.resolve: failed to read specifier"));
        return;
    };

    const resolved = self.script_manager.resolveSpecifier(
        local.call_arena,
        data.base_url,
        specifier,
    ) catch {
        _ = isolate.throwException(isolate.createTypeError("import.meta.resolve: failed to resolve specifier"));
        return;
    };

    const js_result = local.zigValueToJs(resolved, .{}) catch {
        _ = isolate.throwException(isolate.createError("import.meta.resolve: out of memory"));
        return;
    };
    info.getReturnValue().set(js_result);
}

fn _resolveModuleCallback(self: *Context, referrer: js.Module, specifier: [:0]const u8, local: *const js.Local) !?*const v8.Module {
    const referrer_path = self.module_identifier.get(referrer.getIdentityHash()) orelse {
        // Shouldn't be possible.
        return error.UnknownModuleReferrer;
    };

    const normalized_specifier = try self.script_manager.resolveSpecifier(
        self.arena,
        referrer_path,
        specifier,
    );

    const entry = self.module_cache.getPtr(normalized_specifier).?;
    if (entry.module) |m| {
        log.debug(.js, "module cache hit", .{ .url = normalized_specifier, .state = @tagName(entry.state), .ptr = @intFromPtr(entry) });
        return local.toLocal(m).handle;
    }

    const source = self.script_manager.waitForImport(normalized_specifier) catch |err| switch (err) {
        error.UnknownModule => blk: {
            // Module is in cache but was consumed from imported_modules
            // (e.g., by a previous failed resolution). Re-preload and retry.
            try self.script_manager.preloadImport(normalized_specifier, referrer_path);
            break :blk try self.script_manager.waitForImport(normalized_specifier);
        },
        else => return err,
    };

    var try_catch: js.TryCatch = undefined;
    try_catch.init(local);
    defer try_catch.deinit();

    const mod = try compileModule(local, source.src(), normalized_specifier);
    entry.module = try mod.persist();
    entry.state = .parsed;
    entry.source = source;
    try self.postCompileModule(mod, normalized_specifier, local);
    // Note: We don't instantiate/evaluate here - V8 will handle instantiation
    // as part of the parent module's dependency chain. If there's a resolver
    // waiting, it will be handled when the module is eventually evaluated
    // (either as a top-level module or when accessed via dynamic import)
    return mod.handle;
}

// Will get passed to ScriptManager and then passed back to us when
// the src of the module is loaded
const DynamicModuleResolveState = struct {
    // The module that we're resolving (we'll actually resolve its
    // namespace)
    module: ?js.Module.Global,
    context_id: usize,
    context: *Context,
    specifier: [:0]const u8,
    resolver: js.PromiseResolver.Global,
};

fn _dynamicModuleCallback(self: *Context, specifier: [:0]const u8, referrer: []const u8, local: *const js.Local) !js.Promise {
    const gop = try self.module_cache.getOrPut(self.arena, specifier);
    const owned_specifier: [:0]const u8 = if (gop.found_existing) blk: {
        const key = gop.key_ptr.*;
        break :blk key.ptr[0..key.len :0];
    } else blk: {
        const key = try self.arena.dupeZ(u8, specifier);
        gop.key_ptr.* = key;
        gop.value_ptr.* = .{};
        break :blk key;
    };
    if (gop.found_existing) {
        if (gop.value_ptr.resolver_promise) |rp| {
            return local.toLocal(rp);
        }
    }

    const resolver = local.createPromiseResolver();
    const state = try self.arena.create(DynamicModuleResolveState);

    state.* = .{
        .module = null,
        .context = self,
        .specifier = owned_specifier,
        .context_id = self.id,
        .resolver = try resolver.persist(),
    };

    const promise = resolver.promise();

    if (!gop.found_existing or gop.value_ptr.module == null) {
        // Either this is a completely new module, or it's an entry that was
        // created (e.g., in postCompileModule) but not yet loaded
        // this module hasn't been seen before. This is the most
        // complicated path.

        // First, we'll setup a bare entry into our cache. This will
        // prevent anyone one else from trying to asynchronously load
        // it. Instead, they can just return our promise.
        gop.value_ptr.* = ModuleEntry{
            .module = null,
            .module_promise = null,
            .state = .fetching,
            .resolver_promise = try promise.persist(),
        };

        // Next, we need to actually load it.
        self.script_manager.getAsyncImport(owned_specifier, dynamicModuleSourceCallback, state, referrer) catch |err| {
            const error_msg = local.newString(@errorName(err));
            _ = resolver.reject("dynamic module get async", error_msg);
        };

        // For now, we're done. but this will be continued in
        // `dynamicModuleSourceCallback`, once the source for the module is loaded.
        return promise;
    }

    // we might update the map, so we might need to re-fetch this.
    var entry = gop.value_ptr;

    // So we have a module, but no async resolver. This can only
    // happen if the module was first synchronously loaded (Does that
    // ever even happen?!) You'd think we can just return the module
    // but no, we need to resolve the module namespace, and the
    // module could still be loading!
    // We need to do part of what the first case is going to do in
    // `dynamicModuleSourceCallback`, but we can skip some steps
    // since the module is already loaded,
    assert(gop.value_ptr.module != null, "Context._dynamicModuleCallback has module", .{});

    // If the module hasn't been evaluated yet (it was only instantiated
    // as a static import dependency), we need to evaluate it now.
    if (entry.module_promise == null) {
        const mod = local.toLocal(gop.value_ptr.module.?);
        const status = mod.getStatus();
        if (status == .kEvaluated or status == .kEvaluating) {
            // Module was already evaluated (shouldn't normally happen, but handle it).
            // Create a pre-resolved promise with the module namespace.
            const module_resolver = local.createPromiseResolver();
            module_resolver.resolve("resolve module", mod.getModuleNamespace());
            _ = try module_resolver.persist();
            entry.module_promise = try module_resolver.promise().persist();
            entry.state = .evaluated;
        } else {
            // the module was loaded, but not evaluated, we _have_ to evaluate it now
            if (status == .kUninstantiated) {
                if (try mod.instantiate(resolveModuleCallback) == false) {
                    entry.state = .errored;
                    _ = resolver.reject("module instantiation", local.newString("Module instantiation failed"));
                    return promise;
                }
                entry.state = .instantiated;
            }

            if (entry.state == .evaluating or entry.state == .evaluated or entry.module_promise != null) {
                self.resolveDynamicModule(state, entry.*, local);
                return promise;
            }
            entry.state = .evaluating;
            entry.evaluate_count += 1;
            if (entry.evaluate_count > 1) {
                log.warn(.js, "module duplicate evaluate", .{ .url = specifier, .count = entry.evaluate_count, .ptr = @intFromPtr(entry) });
            } else {
                log.debug(.js, "module evaluate", .{ .url = specifier, .ptr = @intFromPtr(entry) });
            }
            const evaluated = mod.evaluate() catch {
                if (comptime IS_DEBUG) {
                    std.debug.assert(mod.getStatus() == .kErrored);
                }
                _ = resolver.reject("module evaluation", local.newString("Module evaluation failed"));
                entry.state = .errored;
                return promise;
            };
            assert(evaluated.isPromise(), "Context._dynamicModuleCallback non-promise", .{});
            // mod.evaluate can invalidate or gop
            entry = self.module_cache.getPtr(specifier).?;
            entry.module_promise = try evaluated.toPromise().persist();
            entry.state = .evaluated;
        }
    }

    // like before, we want to set this up so that if anything else
    // tries to load this module, it can just return our promise
    // since we're going to be doing all the work.
    entry.resolver_promise = try promise.persist();

    // But we can skip directly to `resolveDynamicModule` which is
    // what the above callback will eventually do.
    self.resolveDynamicModule(state, entry.*, local);
    return promise;
}

fn dynamicModuleSourceCallback(ctx: *anyopaque, module_source_: anyerror!ScriptManagerBase.ModuleSource) void {
    const state: *DynamicModuleResolveState = @ptrCast(@alignCast(ctx));
    var self = state.context;

    var ls: js.Local.Scope = undefined;
    self.localScope(&ls);
    defer ls.deinit();

    const local = &ls.local;

    var ms = module_source_ catch |err| {
        log.debug(.js, "dynamic module fetch failed", .{ .err = err, .specifier = state.specifier });
        local.toLocal(state.resolver).rejectError("dynamic module source", .{ .type_error = "Failed to fetch dynamically imported module" });
        return;
    };

    const module_entry = blk: {
        defer ms.deinit();

        var try_catch: js.TryCatch = undefined;
        try_catch.init(local);
        defer try_catch.deinit();

        break :blk self.module(true, local, ms.src(), state.specifier, true) catch |err| {
            const caught = try_catch.caughtOrError(self.call_arena, err);
            log.err(.js, "module compilation failed", .{
                .caught = caught,
                .specifier = state.specifier,
            });
            _ = local.toLocal(state.resolver).reject("dynamic compilation failure", local.newString(caught.exception orelse ""));
            return;
        };
    };

    self.resolveDynamicModule(state, module_entry, local);
}

fn resolveDynamicModule(self: *Context, state: *DynamicModuleResolveState, module_entry: ModuleEntry, local: *const js.Local) void {
    if (local.ctx.execution.realmState() == .dead) return;
    defer {
        if (local.ctx.execution.realmState() != .dead and !local.ctx.execution.schedulerSuppressed()) {
            local.ctx.env.runMicrotasks(.module_resolution);
        }
    }

    // we can only be here if the module has been evaluated and if
    // we have a resolve loading this asynchronously.
    assert(module_entry.module_promise != null, "Context.resolveDynamicModule has module_promise", .{});
    assert(module_entry.resolver_promise != null, "Context.resolveDynamicModule has resolver_promise", .{});
    if (comptime IS_DEBUG) {
        std.debug.assert(self.module_cache.contains(state.specifier));
    }
    state.module = module_entry.module.?;

    // We've gotten the source for the module and are evaluating it.
    // You might think we're done, but the module evaluation is
    // itself asynchronous. We need to chain to the module's own
    // promise. When the module is evaluated, it resolves to the
    // last value of the module. But, for module loading, we need to
    // resolve to the module's namespace.

    const then_callback = newFunctionWithData(local, struct {
        pub fn callback(callback_handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
            var c: Caller = undefined;
            if (!c.initFromHandle(callback_handle)) {
                return;
            }
            defer c.deinit();

            const info = Caller.FunctionCallbackInfo{ .handle = callback_handle.? };
            const s: *DynamicModuleResolveState = @ptrCast(@alignCast(info.getData() orelse return));

            if (s.context_id != c.local.ctx.id) {
                // The microtask is tied to the isolate, not the context
                // it can be resolved while another context is active
                // (Which seems crazy to me). If that happens, then
                // another frame was loaded and we MUST ignore this
                // (most of the fields in state are not valid)
                return;
            }
            const l = c.local;
            defer l.ctx.env.runMicrotasks(.module_resolution);
            const namespace = l.toLocal(s.module.?).getModuleNamespace();
            _ = l.toLocal(s.resolver).resolve("resolve namespace", namespace);
        }
    }.callback, @ptrCast(state));

    const catch_callback = newFunctionWithData(local, struct {
        pub fn callback(callback_handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
            var c: Caller = undefined;
            if (!c.initFromHandle(callback_handle)) return;
            defer c.deinit();

            const info = Caller.FunctionCallbackInfo{ .handle = callback_handle.? };
            const s: *DynamicModuleResolveState = @ptrCast(@alignCast(info.getData() orelse return));

            const l = &c.local;
            if (s.context_id != l.ctx.id) {
                return;
            }

            defer l.ctx.env.runMicrotasks(.module_resolution);
            _ = l.toLocal(s.resolver).reject("catch callback", js.Value{
                .local = l,
                .handle = v8.v8__FunctionCallbackInfo__Data(callback_handle).?,
            });
        }
    }.callback, @ptrCast(state));

    _ = local.toLocal(module_entry.module_promise.?).thenAndCatch(then_callback, catch_callback) catch |err| {
        log.err(.js, "module evaluation is promise", .{
            .err = err,
            .specifier = state.specifier,
        });
        _ = local.toLocal(state.resolver).reject("module promise", local.newString("Failed to evaluate promise"));
    };
}

// Used to make temporarily enter and exit a context, updating and restoring
// frame.js:
//    var hs: js.HandleScope = undefined;
//    const entered = ctx.enter(&hs);
//    defer entered.exit();
pub fn enter(self: *Context, hs: *js.HandleScope) ?Entered {
    const isolate = self.isolate;
    js.HandleScope.init(hs, isolate);

    const handle_ptr = v8.v8__Global__Get(&self.handle, isolate.handle) orelse {
        // `hs` is owned by the caller and must not remain live after a failed
        // context lookup.  Returning without destroying it leaks the V8 scope
        // and leaves subsequent callbacks with an invalid scope stack.
        hs.deinit();
        return null;
    };

    const original = self.global.getJs();
    self.global.setJs(self);

    const handle: *const v8.Context = @ptrCast(handle_ptr);
    v8.v8__Context__Enter(handle);
    return .{ .original = original, .handle = handle, .handle_scope = hs, .global = self.global };
}

const Entered = struct {
    // the context we should restore on the frame/worker
    original: *Context,

    // the handle of the entered context
    handle: *const v8.Context,

    handle_scope: *js.HandleScope,

    global: GlobalScope,

    pub fn exit(self: Entered) void {
        self.global.setJs(self.original);
        v8.v8__Context__Exit(self.handle);
        self.handle_scope.deinit();
    }
};

pub fn queueMutationDelivery(self: *Context) !void {
    self.enqueueMicrotask(struct {
        fn run(ctx: *Context) void {
            switch (ctx.global) {
                .frame => |frame| {
                    const owner = frame._mutation_delivery_task_owner;
                    if (ctx.execution.isTaskOwnerStale(owner)) {
                        const cur = ctx.execution.captureTaskOwner();
                        RealmLifecycleKernel.traceMicrotaskDropStale(
                            frame._frame_id,
                            owner.epoch,
                            cur.epoch,
                            frame.realmState(),
                            .mutation_delivery,
                        );
                        RealmLifecycleKernel.traceMo("mo.drop_stale", frame._frame_id, owner.epoch, cur.epoch, frame.realmState());
                        frame._mutation_delivery_scheduled = false;
                        frame.discardAllMutationObserverPendingRecords();
                        return;
                    }
                    frame.deliverMutations();
                },
                .worker => unreachable,
            }
        }
    }.run);
}

pub fn queueIntersectionChecks(self: *Context) !void {
    self.enqueueMicrotask(struct {
        fn run(ctx: *Context) void {
            switch (ctx.global) {
                .frame => |frame| {
                    const owner = frame._intersection_check_task_owner;
                    if (ctx.execution.isTaskOwnerStale(owner)) {
                        const cur = ctx.execution.captureTaskOwner();
                        RealmLifecycleKernel.traceMicrotaskDropStale(
                            frame._frame_id,
                            owner.epoch,
                            cur.epoch,
                            frame.realmState(),
                            .intersection_check,
                        );
                        frame._intersection_check_scheduled = false;
                        return;
                    }
                    // A scheduled bit must never survive a microtask that did
                    // not perform its work.  Realm entry can be transiently
                    // unavailable while a framework is mounting a subtree;
                    // keeping the bit set would suppress every later
                    // domChanged() intersection checkpoint.
                    ctx.execution.validateJsEntry(.allow_draining, .intersection_check) catch {
                        frame._intersection_check_scheduled = false;
                        return;
                    };
                    frame.performScheduledIntersectionChecks();
                },
                .worker => unreachable,
            }
        }
    }.run);
}

pub fn queueIntersectionDelivery(self: *Context) !void {
    self.enqueueMicrotask(struct {
        fn run(ctx: *Context) void {
            switch (ctx.global) {
                .frame => |frame| {
                    const owner = frame._intersection_delivery_task_owner;
                    if (ctx.execution.isTaskOwnerStale(owner)) {
                        const cur = ctx.execution.captureTaskOwner();
                        RealmLifecycleKernel.traceMicrotaskDropStale(
                            frame._frame_id,
                            owner.epoch,
                            cur.epoch,
                            frame.realmState(),
                            .intersection_delivery,
                        );
                        frame._intersection_delivery_scheduled = false;
                        return;
                    }
                    ctx.execution.validateJsEntry(.allow_draining, .intersection_delivery) catch {
                        frame._intersection_delivery_scheduled = false;
                        return;
                    };
                    frame.deliverIntersections();
                },
                .worker => unreachable,
            }
        }
    }.run);
}

pub fn queueSlotchangeDelivery(self: *Context) !void {
    self.enqueueMicrotask(struct {
        fn run(ctx: *Context) void {
            switch (ctx.global) {
                .frame => |frame| {
                    const owner = frame._slotchange_delivery_task_owner;
                    if (ctx.execution.isTaskOwnerStale(owner)) {
                        const cur = ctx.execution.captureTaskOwner();
                        RealmLifecycleKernel.traceMicrotaskDropStale(
                            frame._frame_id,
                            owner.epoch,
                            cur.epoch,
                            frame.realmState(),
                            .slotchange_delivery,
                        );
                        frame._slotchange_delivery_scheduled = false;
                        return;
                    }
                    ctx.execution.validateJsEntry(.allow_draining, .slotchange_delivery) catch return;
                    frame.deliverSlotchangeEvents();
                },
                .worker => unreachable,
            }
        }
    }.run);
}

// Helper for executing a Microtask on this Context. In V8, microtasks aren't
// associated to a Context - they are just functions to execute in an Isolate.
// But for these Context microtasks, we want to (a) make sure the context isn't
// being shut down and (b) that it's entered.
pub fn queueMicrotaskCallback(self: *Context, callback: anytype) void {
    self.enqueueMicrotask(callback);
}

fn enqueueMicrotask(self: *Context, callback: anytype) void {
    self.execution.validateJsEntry(.allow_draining, .microtask_checkpoint) catch return;
    // Use context-specific microtask queue instead of isolate queue
    v8.v8__MicrotaskQueue__EnqueueMicrotask(self.microtask_queue, self.isolate.handle, struct {
        fn run(data: ?*anyopaque) callconv(.c) void {
            const ctx: *Context = @ptrCast(@alignCast(data.?));
            var hs: js.HandleScope = undefined;
            const entered = ctx.enter(&hs) orelse return;
            defer entered.exit();
            callback(ctx);
        }
    }.run, self);
}

/// Run `callback` on the context microtask queue after the current sync turn.
/// `entry` must live until the microtask runs (frame arena is typical).
pub const NativeMicrotask = struct {
    ctx: *Context,
    userdata: *anyopaque,
    callback: *const fn (*Context, *anyopaque) void,
};

pub fn queueMicrotaskNative(self: *Context, entry: *NativeMicrotask) void {
    self.execution.validateJsEntry(.allow_draining, .microtask_checkpoint) catch return;
    entry.ctx = self;
    v8.v8__MicrotaskQueue__EnqueueMicrotask(self.microtask_queue, self.isolate.handle, struct {
        fn run(data: ?*anyopaque) callconv(.c) void {
            const e: *NativeMicrotask = @ptrCast(@alignCast(data.?));
            var hs: js.HandleScope = undefined;
            const entered = e.ctx.enter(&hs) orelse return;
            defer entered.exit();
            e.callback(e.ctx, e.userdata);
        }
    }.run, entry);
}

// There's an assumption here: the js.Function will be alive when microtasks are
// run. If we're Env.runMicrotasks in all the places that we're supposed to, then
// this should be safe (I think). In whatever HandleScope a microtask is enqueued,
// PerformCheckpoint should be run. So the v8::Local<v8::Function> should remain
// valid. If we have problems with this, a simple solution is to provide a Zig
// wrapper for these callbacks which references a js.Function.Temp, on callback
// it executes the function and then releases the global.
pub fn queueMicrotaskFunc(self: *Context, cb: js.Function) void {
    self.execution.validateJsEntry(.allow_draining, .microtask_checkpoint) catch return;
    // Use context-specific microtask queue instead of isolate queue
    v8.v8__MicrotaskQueue__EnqueueMicrotaskFunc(self.microtask_queue, self.isolate.handle, cb.handle);
}

// == Profiler ==
pub fn startCpuProfiler(self: *Context) void {
    if (comptime !IS_DEBUG) {
        // Still testing this out, don't have it properly exposed, so add this
        // guard for the time being to prevent any accidental/weird prod issues.
        @compileError("CPU Profiling is only available in debug builds");
    }

    var ls: js.Local.Scope = undefined;
    self.localScope(&ls);
    defer ls.deinit();

    std.debug.assert(self.cpu_profiler == null);
    v8.v8__CpuProfiler__UseDetailedSourcePositionsForProfiling(self.isolate.handle);

    const cpu_profiler = v8.v8__CpuProfiler__Get(self.isolate.handle).?;
    const title = self.isolate.initStringHandle("v8_cpu_profile");
    v8.v8__CpuProfiler__StartProfiling(cpu_profiler, title);
    self.cpu_profiler = cpu_profiler;
}

pub fn stopCpuProfiler(self: *Context) ![]const u8 {
    var ls: js.Local.Scope = undefined;
    self.localScope(&ls);
    defer ls.deinit();

    const title = self.isolate.initStringHandle("v8_cpu_profile");
    const handle = v8.v8__CpuProfiler__StopProfiling(self.cpu_profiler.?, title) orelse return error.NoProfiles;
    const string_handle = v8.v8__CpuProfile__Serialize(handle, self.isolate.handle) orelse return error.NoProfile;
    return (js.String{ .local = &ls.local, .handle = string_handle }).toSlice();
}

pub fn startHeapProfiler(self: *Context) void {
    if (comptime !IS_DEBUG) {
        @compileError("Heap Profiling is only available in debug builds");
    }

    var ls: js.Local.Scope = undefined;
    self.localScope(&ls);
    defer ls.deinit();

    std.debug.assert(self.heap_profiler == null);
    const heap_profiler = v8.v8__HeapProfiler__Get(self.isolate.handle).?;

    // Sample every 32KB, stack depth 32
    v8.v8__HeapProfiler__StartSamplingHeapProfiler(heap_profiler, 32 * 1024, 32);
    v8.v8__HeapProfiler__StartTrackingHeapObjects(heap_profiler, true);

    self.heap_profiler = heap_profiler;
}

pub fn stopHeapProfiler(self: *Context) !struct { []const u8, []const u8 } {
    var ls: js.Local.Scope = undefined;
    self.localScope(&ls);
    defer ls.deinit();

    const allocating = blk: {
        const profile = v8.v8__HeapProfiler__GetAllocationProfile(self.heap_profiler.?);
        const string_handle = v8.v8__AllocationProfile__Serialize(profile, self.isolate.handle);
        v8.v8__HeapProfiler__StopSamplingHeapProfiler(self.heap_profiler.?);
        v8.v8__AllocationProfile__Delete(profile);
        break :blk try (js.String{ .local = &ls.local, .handle = string_handle.? }).toSlice();
    };

    const snapshot = blk: {
        const snapshot = v8.v8__HeapProfiler__TakeHeapSnapshot(self.heap_profiler.?, null) orelse return error.NoProfiles;
        const string_handle = v8.v8__HeapSnapshot__Serialize(snapshot, self.isolate.handle);
        v8.v8__HeapProfiler__StopTrackingHeapObjects(self.heap_profiler.?);
        v8.v8__HeapSnapshot__Delete(snapshot);
        break :blk try (js.String{ .local = &ls.local, .handle = string_handle.? }).toSlice();
    };

    return .{ allocating, snapshot };
}

const UnknownPropertyStat = struct {
    count: usize,
    first_stack: []const u8,
};
