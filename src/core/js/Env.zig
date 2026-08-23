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
const builtin = @import("builtin");
const sync = @import("../../support/sync.zig");

const js = @import("js.zig");
const bridge = @import("bridge.zig");
const Context = @import("Context.zig");
const Isolate = @import("Isolate.zig");
const Platform = @import("Platform.zig");
const Inspector = @import("Inspector.zig");

const App = @import("../../runtime/App.zig");
const Frame = @import("../browser/Frame.zig");
const Window = @import("../webapi/Window.zig");
const DedicatedWorkerGlobalScope = @import("../webapi/DedicatedWorkerGlobalScope.zig");
const SharedWorkerGlobalScope = @import("../webapi/SharedWorkerGlobalScope.zig");
const WorkerGlobalScope = @import("../webapi/WorkerGlobalScope.zig");

const RealmLifecycleKernel = @import("../../runtime/RealmLifecycleKernel.zig");
const MathsNative = @import("../../runtime/profile/MathsNative.zig");
const NativeBuiltinHooks = @import("../../runtime/profile/NativeBuiltinHooks.zig");

const v8 = js.v8;
const log = @import("../../support/log.zig");
const JsApis = bridge.JsApis;
const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;

/// Sources from which runMicrotasks can be called.
/// Used for debugging microtask checkpoint reentry issues.
pub const TaskSource = enum {
    /// Called from Browser.runMacrotasks (main scheduler loop)
    macrotask_loop,
    /// Called from Local.runAfterEvaluate (post-script)
    after_evaluate,
    /// Called from PromiseResolver.resolve
    promise_resolve,
    /// Called from PromiseResolver.reject
    promise_reject,
    /// Called from EventManager after event handling
    event_handler,
    /// Called from Timers.setTimeout/setInterval callback
    timer_callback,
    /// Called from Browser.waitForBackgroundTasks
    background_tasks,
    /// Called from Context.zig module resolution
    module_resolution,
    /// Unknown source (default)
    unknown,
};

fn taskSourceOwnsOuterMacrotaskTurn(source: TaskSource) bool {
    return source == .macrotask_loop;
}

// CreepJS Promise.all fans out ~19 async probes across 5 frames; each queues
// offline-audio / worker / canvas microtasks and can trip the old budget before
// setTimeout(0) continuations (canvas2d, audio post) get a macrotask turn.
const MAX_CHECKPOINT_PASSES_PER_SCHEDULER_TICK = 512;
const MAX_SCHEDULER_PUMP_DEPTH = 4;
const MAX_MACROTASK_RUN_DEPTH = 1;

fn initClassIds() void {
    inline for (JsApis, 0..) |JsApi, i| {
        JsApi.Meta.class_id = i;
    }
}

var class_ids_initialized = false;
var class_ids_mutex: sync.Mutex = .{};

fn initClassIdsOnce() void {
    class_ids_mutex.lock();
    defer class_ids_mutex.unlock();
    if (class_ids_initialized) return;
    initClassIds();
    class_ids_initialized = true;
}

// The Env maps to a V8 isolate, which represents a isolated sandbox for
// executing JavaScript. The Env is where we'll define our V8 <-> Zig bindings,
// and it's where we'll start ExecutionWorlds, which actually execute JavaScript.
// The `S` parameter is arbitrary state. When we start an ExecutionWorld, an instance
// of S must be given. This instance is available to any Zig binding.
// The `types` parameter is a tuple of Zig structures we want to bind to V8.
const Env = @This();

app: *App,

allocator: Allocator,

platform: *const Platform,

// the global isolate
isolate: js.Isolate,

contexts: [64]*Context,
context_count: usize,

// just kept around because we need to free it on deinit
isolate_params: *v8.CreateParams,

context_id: usize,

// Maps origin -> shared Origin contains, for v8 values shared across
// same-origin Contexts. There's a mismatch here between our JS model and our
// Browser model. Origins only live as long as the root frame of a session exists.
// It would be wrong/dangerous to re-use an Origin across root frame navigations.

// Global handles that need to be freed on deinit
eternal_function_templates: []v8.Eternal,

// Dynamic slice to avoid circular dependency on JsApis.len at comptime
templates: []*const v8.FunctionTemplate,

// Inspector associated with the Isolate. Exists when CDP is being used.
inspector: ?*Inspector,

// We can store data in a v8::Object's Private data bag. The keys are v8::Private
// which an be created once per isolaet.
private_symbols: PrivateSymbols,

checkpoint_active: bool,
checkpoint_pending: bool,
// V8's IsExecutionTerminating is scoped to active isolate execution and is
// not a durable cancellation token for native callbacks. Mirror every host
// termination request so Zig loops can observe it while control is outside V8.
termination_requested: std.atomic.Value(bool) = .init(false),
scheduler_pump_depth: u8 = 0,
macrotask_run_depth: u8 = 0,

pub const InitOpts = struct {
    with_inspector: bool = false,
};

pub fn init(app: *App, opts: InitOpts) !Env {
    if (comptime IS_DEBUG) {
        comptime {
            // V8 requirement for any data using SetAlignedPointerInInternalField
            const a = @alignOf(@import("TaggedOpaque.zig"));
            std.debug.assert(a >= 2 and a % 2 == 0);
        }
    }

    // Initialize class IDs once before any V8 work
    initClassIdsOnce();

    const allocator = app.allocator;
    const snapshot = &app.snapshot;

    var params = try allocator.create(v8.CreateParams);
    errdefer allocator.destroy(params);
    v8.v8__Isolate__CreateParams__CONSTRUCT(params);
    params.snapshot_blob = @ptrCast(&snapshot.startup_data);

    params.array_buffer_allocator = v8.v8__ArrayBuffer__Allocator__NewDefaultAllocator().?;
    errdefer v8.v8__ArrayBuffer__Allocator__DELETE(params.array_buffer_allocator.?);

    params.external_references = &snapshot.external_references;

    // Tell V8 where the stack ends (grows down). Default JS stack is small and
    // Next/React deep recursion V8_Fatal's before RangeError. Leave ~1MB for
    // native frames; give JS ~16MB so uncaught stack overflow becomes exception.
    // stack_limit_ is *u32 — must be 4-byte aligned (ReleaseSafe alignment check).
    var stack_marker: u32 align(16) = 0;
    const sp = @intFromPtr(&stack_marker);
    const native_reserve: usize = 1024 * 1024;
    const js_stack: usize = 16 * 1024 * 1024;
    const limit_addr = (sp -% (js_stack + native_reserve)) & ~@as(usize, @alignOf(u32) - 1);
    params.constraints.stack_limit_ = @ptrFromInt(limit_addr);

    var isolate = js.Isolate.init(params);
    errdefer isolate.deinit();
    const isolate_handle = isolate.handle;

    v8.v8__Isolate__SetHostImportModuleDynamicallyCallback(isolate_handle, Context.dynamicModuleCallback);
    v8.v8__Isolate__SetPromiseRejectCallback(isolate_handle, promiseRejectCallback);
    v8.v8__Isolate__SetMicrotasksPolicy(isolate_handle, v8.kExplicit);
    v8.v8__Isolate__SetFatalErrorHandler(isolate_handle, fatalCallback);
    v8.v8__Isolate__SetOOMErrorHandler(isolate_handle, oomCallback);

    isolate.enter();
    errdefer isolate.exit();

    v8.v8__Isolate__SetCaptureStackTraceForUncaughtExceptions(isolate_handle, true, 10);
    _ = v8.v8__Isolate__AddMessageListener(isolate_handle, uncaughtExceptionCallback);
    v8.v8__Isolate__SetHostInitializeImportMetaObjectCallback(isolate_handle, Context.metaObjectCallback);

    // Allocate arrays dynamically to avoid comptime dependency on JsApis.len
    const eternal_function_templates = try allocator.alloc(v8.Eternal, JsApis.len);
    errdefer allocator.free(eternal_function_templates);

    const templates = try allocator.alloc(*const v8.FunctionTemplate, JsApis.len);
    errdefer allocator.free(templates);

    var private_symbols: PrivateSymbols = undefined;
    {
        var temp_scope: js.HandleScope = undefined;
        temp_scope.init(isolate);
        defer temp_scope.deinit();

        inline for (JsApis, 0..) |_, i| {
            const data = v8.v8__Isolate__GetDataFromSnapshotOnce(isolate_handle, snapshot.data_start + i);
            const function_handle: *const v8.FunctionTemplate = @ptrCast(data);
            // Make function template eternal
            v8.v8__Eternal__New(isolate_handle, @ptrCast(function_handle), &eternal_function_templates[i]);

            // Extract the local handle from the global for easy access
            const eternal_ptr = v8.v8__Eternal__Get(&eternal_function_templates[i], isolate_handle);
            templates[i] = @ptrCast(@alignCast(eternal_ptr.?));
        }

        private_symbols = PrivateSymbols.init(isolate_handle);
    }

    var inspector: ?*js.Inspector = null;
    if (opts.with_inspector) {
        inspector = try Inspector.init(allocator, isolate_handle);
    }

    return .{
        .app = app,
        .context_id = 0,
        .allocator = allocator,
        .contexts = undefined,
        .context_count = 0,
        .isolate = isolate,
        .platform = &app.platform,
        .templates = templates,
        .isolate_params = params,
        .inspector = inspector,
        .private_symbols = private_symbols,
        .checkpoint_active = false,
        .checkpoint_pending = false,
        .eternal_function_templates = eternal_function_templates,
    };
}

pub fn deinit(self: *Env) void {
    if (comptime IS_DEBUG) {
        std.debug.assert(self.context_count == 0);
    }

    const app = self.app;
    const allocator = app.allocator;

    if (self.inspector) |i| {
        i.deinit(allocator);
    }

    allocator.free(self.templates);
    allocator.free(self.eternal_function_templates);
    self.private_symbols.deinit();

    self.waitForBackgroundTasks();
    self.isolate.exit();
    self.isolate.deinit();
    v8.v8__ArrayBuffer__Allocator__DELETE(self.isolate_params.array_buffer_allocator.?);
    allocator.destroy(self.isolate_params);
}

pub const ContextParams = struct {
    identity: *js.Identity,
    identity_arena: Allocator,
    call_arena: Allocator,
    debug_name: []const u8 = "Context",
};

pub fn createContext(self: *Env, frame: *Frame, params: ContextParams) !*Context {
    return self._createContext(frame, params, .frame);
}

pub fn createWorkerContext(self: *Env, worker: *WorkerGlobalScope, params: ContextParams) !*Context {
    return self._createContext(worker, params, .dedicated_worker);
}

pub fn createSharedWorkerContext(self: *Env, worker: *WorkerGlobalScope, params: ContextParams) !*Context {
    return self._createContext(worker, params, .shared_worker);
}

const ContextKind = enum {
    frame,
    dedicated_worker,
    shared_worker,
};

fn _createContext(self: *Env, global: anytype, params: ContextParams, kind: ContextKind) !*Context {
    const is_frame = comptime @TypeOf(global) == *Frame;

    const context_arena = try self.app.arena_pool.acquire(.medium, params.debug_name);
    errdefer self.app.arena_pool.release(context_arena);

    const isolate = self.isolate;
    var hs: js.HandleScope = undefined;
    hs.init(isolate);
    defer hs.deinit();

    // Create a per-context microtask queue for isolation
    const microtask_queue = v8.v8__MicrotaskQueue__New(isolate.handle, v8.kExplicit).?;
    errdefer v8.v8__MicrotaskQueue__DELETE(microtask_queue);

    // Restore the context from the snapshot (0 = Page, 1 = DedicatedWorker, 2 = SharedWorker)
    const snapshot_index: u32 = switch (kind) {
        .frame => 0,
        .dedicated_worker => 1,
        .shared_worker => 2,
    };
    const v8_context = v8.v8__Context__FromSnapshot__Config(isolate.handle, snapshot_index, &.{
        .global_template = null,
        .global_object = null,
        .microtask_queue = microtask_queue,
    }).?;

    // Create the v8::Context and wrap it in a v8::Global
    var context_global: v8.Global = undefined;
    v8.v8__Global__New(isolate.handle, v8_context, &context_global);

    // Get the global object for the context
    const global_obj = v8.v8__Context__Global(v8_context).?;

    // Store our TAO inside the internal field of the global object. This
    // maps the v8::Object -> Zig instance.
    const tao = try params.identity_arena.create(@import("TaggedOpaque.zig"));
    tao.* = if (comptime is_frame) .{
        .value = @ptrCast(global.window),
        .prototype_chain = (&Window.JsApi.Meta.prototype_chain).ptr,
        .prototype_len = @intCast(Window.JsApi.Meta.prototype_chain.len),
        .subtype = .node,
    } else .{
        // Worker globals are WorkerGlobalScope heap objects; the outer
        // Dedicated/Shared types exist only for instanceof / constructor names.
        // TaggedOpaque must use WorkerGlobalScope's chain so prototype methods
        // like postMessage resolve to the correct Zig receiver.
        .value = @ptrCast(global),
        .prototype_chain = (&WorkerGlobalScope.JsApi.Meta.prototype_chain).ptr,
        .prototype_len = @intCast(WorkerGlobalScope.JsApi.Meta.prototype_chain.len),
        .subtype = null,
    };
    v8.v8__Object__SetAlignedPointerInInternalField(global_obj, 0, tao);

    const context_id = self.context_id;
    self.context_id = context_id + 1;

    const page = global._page;
    const origin = try page.getOrCreateOrigin(null);
    errdefer page.releaseOrigin(origin);

    const context = try context_arena.create(Context);
    context.* = .{
        .env = self,
        .global = if (comptime is_frame) .{ .frame = global } else .{ .worker = global },
        .origin = origin,
        .id = context_id,
        .page = page,
        .isolate = isolate,
        .arena = context_arena,
        .handle = context_global,
        .templates = self.templates,
        .call_arena = params.call_arena,
        .microtask_queue = microtask_queue,
        .script_manager = if (comptime is_frame) &global._script_manager.base else &global._script_manager,
        .scheduler = .init(context_arena),
        .identity = params.identity,
        .identity_arena = params.identity_arena,
        .execution = undefined,
    };

    context.execution = .{
        .url = &global.url,
        .buf = &global.buf,
        .charset = &global.charset,
        .context = context,
        .arena = global.arena,
        .call_arena = params.call_arena,
        ._factory = global._factory,
        ._scheduler = &context.scheduler,
    };

    // Register in the identity map. Multiple contexts can be created for the
    // same global (via CDP), so we only register the first one.
    const identity_ptr = if (comptime is_frame) @intFromPtr(global.window) else @intFromPtr(global);
    if (comptime is_frame) page.flushPendingIdentityRemovals();
    const gop = try params.identity.identity_map.getOrPut(params.identity_arena, identity_ptr);
    if (gop.found_existing == false) {
        var global_global: v8.Global = undefined;
        v8.v8__Global__New(isolate.handle, global_obj, &global_global);
        gop.value_ptr.* = global_global;
    }

    // Store a pointer to our context inside the v8 context so that, given
    // a v8 context, we can get our context out
    v8.v8__Context__SetAlignedPointerInEmbedderData(v8_context, 1, @ptrCast(context));

    const count = self.context_count;
    if (count >= self.contexts.len) {
        return error.TooManyContexts;
    }
    self.contexts[count] = context;
    self.context_count = count + 1;

    // Nested Frame.init from appendChild(iframe) mid-script already has V8 on
    // stack. Compiling many shims via eval there → V8_Fatal (nytimes/stripe).
    // Install only essential TrustedTypes shim when nested; full set on safe stacks.
    const nested_v8 = self.anyContextOnV8Stack();
    if (!nested_v8) {
        installTrustedTypesEvalShim(context);
        installConstructThrowShim(context);
        installDomTokenListArrayPrototypeShim(context);
        installUrlHistoricalShim(context);
    } else {
        installTrustedTypesEvalShim(context);
    }
    if (comptime is_frame) {
        if (!nested_v8) {
            installWorkerConstructDepth(context);
            installWorkerConstructorShim(context);
            installSharedWorkerConstructorShim(context);
            cleanupFrameInternalGlobals(context);
            installUrlSearchParamsConstructorShim(context);
            installWebSocketConstructorShim(context);
            installCreepJsCompatShim(context);
        }
        MathsNative.installOnContext(context, global);
    } else {
        // Nested-V8: eval-based WPT shims during Worker() mid-page-script
        // (Fingerprint agent) leave isolate such that classic Script::Run returns
        // null with empty TryCatch. Cold worker create still gets full shims.
        if (!nested_v8) {
            installWorkerIntlShim(context);
            installUrlSearchParamsConstructorShim(context);
            installWebSocketConstructorShim(context);
            installWorkerDomExceptionThrowShim(context);
            installWorkerRethrowShim(context);
            installWorkerImportScriptsMimeShim(context);
            installWorkerPostMessageShim(context);
        }
        MathsNative.installOnContext(context, global._worker._frame);
    }

    return context;
}

pub fn cleanupFrameInternalGlobals(context: *Context) void {
    var ls: js.Local.Scope = undefined;
    context.localScope(&ls);
    defer ls.deinit();
    const global_handle = v8.v8__Context__Global(ls.local.handle) orelse return;
    inline for (.{
        "__kokoConstructThrow",
        "__kokoRethrow",
        "__kokoDomExceptionThrow",
        "__kokoWorkerConstructing",
        "__kokoWorkerConstructEnter",
        "__kokoWorkerConstructExit",
    }) |name| deleteOwnGlobal(&ls.local, global_handle, name);
}

/// WPT historical: href setter, structuredClone, URL(string coercion) throws in harness.
fn installUrlHistoricalShim(context: *Context) void {
    var ls: js.Local.Scope = undefined;
    context.localScope(&ls);
    defer ls.deinit();

    const src = @embedFile("url_historical_shim.js");
    ls.local.eval(src, "url-historical-shim") catch |err| {
        log.warn(.js, "url historical shim", .{ .err = err });
    };
}

/// Shared recursive worker-creation guard used by worker constructor shims.
fn installWorkerConstructDepth(context: *Context) void {
    var ls: js.Local.Scope = undefined;
    context.localScope(&ls);
    defer ls.deinit();

    const src = @embedFile("worker_construct_depth.js");
    ls.local.eval(src, "worker-construct-depth") catch |err| {
        log.warn(.js, "worker construct depth", .{ .err = err });
    };
}

/// WPT: SharedWorker(url, { type }) validation before native constructor.
fn installSharedWorkerConstructorShim(context: *Context) void {
    var ls: js.Local.Scope = undefined;
    context.localScope(&ls);
    defer ls.deinit();

    const src = @embedFile("shared_worker_constructor_shim.js");
    ls.local.eval(src, "shared-worker-constructor-shim") catch |err| {
        log.warn(.js, "shared worker constructor shim", .{ .err = err });
    };
}

/// WPT: native Worker constructor throws do not reach try/catch on 2nd+ classic scripts.
fn installWorkerConstructorShim(context: *Context) void {
    var ls: js.Local.Scope = undefined;
    context.localScope(&ls);
    defer ls.deinit();

    const src = @embedFile("worker_constructor_shim.js");
    ls.local.eval(src, "worker-constructor-shim") catch |err| {
        log.warn(.js, "worker constructor shim", .{ .err = err });
    };
}

/// WPT: native WebSocket constructor throws do not reach try/catch on 2nd+ classic scripts.
fn installWebSocketConstructorShim(context: *Context) void {
    var ls: js.Local.Scope = undefined;
    context.localScope(&ls);
    defer ls.deinit();

    const src = @embedFile("websocket_constructor_shim.js");
    ls.local.eval(src, "websocket-constructor-shim") catch |err| {
        log.warn(.js, "websocket constructor shim", .{ .err = err });
    };
}

/// WPT: native constructor throws do not reach try/catch on 2nd+ classic scripts.
fn installUrlSearchParamsConstructorShim(context: *Context) void {
    var ls: js.Local.Scope = undefined;
    context.localScope(&ls);
    defer ls.deinit();

    const src = @embedFile("usp_constructor_shim.js");
    ls.local.eval(src, "usp-constructor-shim") catch |err| {
        log.warn(.js, "urlsearchparams constructor shim", .{ .err = err });
    };
}

/// WPT dom/lists/DOMTokenList-iteration.html expects DOMTokenList.prototype to
/// expose Array.prototype iteration methods by reference.
fn installDomTokenListArrayPrototypeShim(context: *Context) void {
    var ls: js.Local.Scope = undefined;
    context.localScope(&ls);
    defer ls.deinit();

    const src =
        \\(function(){var p=globalThis.DOMTokenList&&DOMTokenList.prototype;if(!p)return;var a=Array.prototype;["keys","values","entries","forEach"].forEach(function(m){Object.defineProperty(p,m,{value:a[m],writable:true,enumerable:false,configurable:true})});Object.defineProperty(p,Symbol.iterator,{value:a[Symbol.iterator],writable:true,enumerable:false,configurable:true})})();
    ;
    ls.local.eval(src, "domtokenlist-array-prototype-shim") catch |err| {
        log.warn(.js, "domtokenlist array prototype shim", .{ .err = err });
    };
}

/// Propagate constructor failures through pure JS throws (WPT assert_throws_js).
/// Helpers are non-enumerable so they do not pollute window key fingerprints.
fn installConstructThrowShim(context: *Context) void {
    var ls: js.Local.Scope = undefined;
    context.localScope(&ls);
    defer ls.deinit();

    const src =
        \\(function(){
        \\  function hide(name, fn) {
        \\    try {
        \\      Object.defineProperty(globalThis, name, {
        \\        value: fn, writable: true, enumerable: false, configurable: true
        \\      });
        \\    } catch (e) { globalThis[name] = fn; }
        \\  }
        \\  hide("__kokoConstructThrow", function(name) {
        \\    const C = globalThis[name];
        \\    if (typeof C === "function") throw new C("");
        \\    throw new Error(name || "");
        \\  });
        \\  hide("__kokoDomExceptionThrow", function(n,m){throw new DOMException(m||"",n||"Error")});
        \\  hide("__kokoRethrow", function(v){throw v});
        \\})();
    ;
    ls.local.eval(src, "construct-throw-shim") catch |err| {
        log.warn(.js, "construct throw shim", .{ .err = err });
        return;
    };

    const global_handle = v8.v8__Context__Global(ls.local.handle) orelse return;
    const global = js.Object{ .local = &ls.local, .handle = global_handle };
    if (global.getFunction("__kokoConstructThrow") catch null) |helper| {
        context.construct_throw_helper = helper.persist() catch null;
        deleteOwnGlobal(&ls.local, global.handle, "__kokoConstructThrow");
    }
    if (global.getFunction("__kokoRethrow") catch null) |helper| {
        context.rethrow_helper = helper.persist() catch null;
        deleteOwnGlobal(&ls.local, global.handle, "__kokoRethrow");
    }
    if (global.getFunction("__kokoDomExceptionThrow") catch null) |helper| {
        context.dom_exception_throw_helper = helper.persist() catch null;
        deleteOwnGlobal(&ls.local, global.handle, "__kokoDomExceptionThrow");
    }
}

fn deleteOwnGlobal(local: *const js.Local, global: *const v8.Object, name: []const u8) void {
    const key = local.isolate.initStringHandle(name);
    var out: v8.MaybeBool = undefined;
    v8.v8__Object__Delete(global, local.handle, key, &out);
}

/// Chrome unwraps TrustedScript before calling the intrinsic eval. Install a
/// **V8 FunctionTemplate** native wrapper (see NativeBuiltinHooks) so iframe
/// clean `Function.prototype.toString` still reports `[native code]`.
///
/// Also scrub `window._p` (never a Chrome global; high-signal automation mark).
fn installTrustedTypesEvalShim(context: *Context) void {
    NativeBuiltinHooks.installEval(context);

    var ls: js.Local.Scope = undefined;
    context.localScope(&ls);
    defer ls.deinit();
    ls.local.eval(
        \\try{delete globalThis._p}catch(e){}
    ,
        "scrub-p-global",
    ) catch {};
}

/// Native JS value rethrows from worker callbacks do not reach in-script try/catch.
fn installWorkerRethrowShim(context: *Context) void {
    var ls: js.Local.Scope = undefined;
    context.localScope(&ls);
    defer ls.deinit();

    const src =
        \\globalThis.__kokoRethrow=function(v){throw v};
    ;
    ls.local.eval(src, "worker-rethrow-shim") catch |err| {
        log.warn(.js, "worker rethrow shim", .{ .err = err });
    };
}

/// Native DOMException throws from worker callbacks do not reach in-script try/catch.
fn installWorkerDomExceptionThrowShim(context: *Context) void {
    var ls: js.Local.Scope = undefined;
    context.localScope(&ls);
    defer ls.deinit();

    const src =
        \\globalThis.__kokoDomExceptionThrow=function(n,m){throw new DOMException(m||"",n||"Error")};
    ;
    ls.local.eval(src, "worker-domexception-throw-shim") catch |err| {
        log.warn(.js, "worker domexception throw shim", .{ .err = err });
    };
}

/// WPT importScripts MIME checks: native DOMException throws do not reach try/catch.
fn installWorkerImportScriptsMimeShim(context: *Context) void {
    var ls: js.Local.Scope = undefined;
    context.localScope(&ls);
    defer ls.deinit();

    const src =
        \\(function(){var blobMime=new Map();var oc=URL.createObjectURL;URL.createObjectURL=function(b){var u=oc.call(URL,b);blobMime.set(u,b.type||"");return u};var or=URL.revokeObjectURL;URL.revokeObjectURL=function(u){blobMime.delete(u);return or.call(URL,u)};function isJsMime(m){m=(m||"").split(";")[0].trim().toLowerCase();return m==="text/javascript"||m==="application/javascript"||m==="text/ecmascript"}function mimeFromHttpQuery(u){var q=u.indexOf("?");if(q<0)return null;var s=u.slice(q+1),p="mime=",i=s.indexOf(p);if(i<0)return null;var v=s.slice(i+p.length),a=v.indexOf("&");return a<0?v:v.slice(0,a)}function mimeForUrl(u){if(u.startsWith("data:")){var r=u.slice(5),c=r.indexOf(",");return c<0?r:r.slice(0,c)||"text/plain"}if(u.startsWith("blob:"))return blobMime.get(u)||"";return mimeFromHttpQuery(u)}var n=Object.getPrototypeOf(globalThis).importScripts;globalThis.importScripts=function(){if(globalThis.__kokoWorkerIsModule)throw new TypeError("importScripts is not available in module workers");for(var i=0;i<arguments.length;i++){var u=arguments[i],m=mimeForUrl(u);if(m!==null&&!isJsMime(m))throw new DOMException("","NetworkError")}globalThis.__kokoImportScriptError=null;n.apply(globalThis,arguments);var e=globalThis.__kokoImportScriptError;if(e){globalThis.__kokoImportScriptError=null;throw e}}})();
    ;
    ls.local.eval(src, "worker-importscripts-mime-shim") catch |err| {
        log.warn(.js, "worker importScripts mime shim", .{ .err = err });
    };
}

/// WPT worker tests call bare `postMessage(x)` (unbound); bind to globalThis.
fn installWorkerPostMessageShim(context: *Context) void {
    var ls: js.Local.Scope = undefined;
    context.localScope(&ls);
    defer ls.deinit();

    const src =
        \\(function(){var n=null,p=Object.getPrototypeOf(globalThis);while(p){var d=Object.getOwnPropertyDescriptor(p,"postMessage");if(d&&d.value){n=d.value;break}p=Object.getPrototypeOf(p)}function normalizeTransfer(t){if(t==null||t===undefined)return null;var seq=(typeof t==="object"&&!Array.isArray(t)&&"transfer" in t)?t.transfer:t;if(seq==null||seq===undefined)return null;if(!Array.isArray(seq))throw new TypeError();for(var i=0;i<seq.length;i++){if(seq[i]===null)throw new TypeError()}return t}globalThis.postMessage=function(m,t){if(typeof FormData!=="undefined"&&m instanceof FormData)throw new DOMException("The object cannot be cloned.","DataCloneError");if(!n)throw new TypeError("postMessage is not a function");return n.call(globalThis,m,normalizeTransfer(t))}})();
    ;
    ls.local.eval(src, "worker-postmessage-shim") catch |err| {
        log.warn(.js, "worker postMessage shim", .{ .err = err });
    };
}

/// Worker `getLocale()` probes Intl constructors missing from the worker snapshot.
fn installWorkerIntlShim(context: *Context) void {
    var ls: js.Local.Scope = undefined;
    context.localScope(&ls);
    defer ls.deinit();

    const src = @embedFile("worker_intl_shim.js");
    ls.local.eval(src, "worker-intl-shim") catch |err| {
        log.warn(.js, "worker intl shim", .{ .err = err });
    };
}

/// CreepJS `getJSCoreFeatures` / blinkJS descriptor probes (Chrome 114+).
fn installCreepJsCompatShim(context: *Context) void {
    var ls: js.Local.Scope = undefined;
    context.localScope(&ls);
    defer ls.deinit();

    const src = @embedFile("creepjs_compat_shim.js");
    ls.local.eval(src, "creepjs-compat-shim") catch |err| {
        log.warn(.js, "creepjs compat shim", .{ .err = err });
    };

    const reorder = @embedFile("creepjs_features_reorder.js");
    ls.local.eval(reorder, "creepjs-features-reorder") catch |err| {
        log.warn(.js, "creepjs features reorder", .{ .err = err });
    };
}

/// Notify the V8 inspector that a context is gone without freeing the V8
/// context. Used during pending-root commit: the outgoing main context must
/// leave the inspector context group before the replacement is published, but
/// the V8 context stays alive until the old Page is destroyed.
pub fn notifyInspectorContextDestroyed(self: *Env, context: *Context) void {
    if (context._inspector_destroyed_notified) return;
    context._inspector_destroyed_notified = true;

    const inspector = self.inspector orelse return;
    const isolate = self.isolate;
    var hs: js.HandleScope = undefined;
    hs.init(isolate);
    defer hs.deinit();
    inspector.contextDestroyed(@ptrCast(v8.v8__Global__Get(&context.handle, isolate.handle)));
}

pub fn destroyContext(self: *Env, context: *Context) void {
    // Idempotent: document.open() / removeNode may tear down child iframe
    // contexts, then parent frame.deinit() calls destroyContext again. Double
    // deinit is UAF; panic("Tried to remove unknown context") took down the
    // whole process during WPT dynamic-markup suites.
    var found = false;
    for (self.contexts[0..self.context_count], 0..) |ctx, i| {
        if (ctx == context) {
            // Swap with last element and decrement count
            self.context_count -= 1;
            self.contexts[i] = self.contexts[self.context_count];
            found = true;
            break;
        }
    }
    if (!found) {
        if (comptime IS_DEBUG) {
            log.warn(.js, "destroyContext already removed", .{});
        }
        return;
    }

    self.notifyInspectorContextDestroyed(context);

    // Realm-owned registries must be detached while the Context identity is
    // still valid and before Context.deinit resets its V8 global.
    context.page.unregisterBroadcastChannelsForContext(context);

    context.deinit();
}

fn clearSchedulerSuppression(self: *Env) void {
    for (self.contexts[0..self.context_count]) |ctx| {
        switch (ctx.global) {
            .frame => |frame| frame.clearSchedulerSuppression(),
            .worker => {},
        }
    }
}

/// Single-context checkpoint for nested DOM APIs (e.g. iframe onload during
/// appendChild). Bypasses the global reentry guard so Promise reactions queued
/// by the handler can run before returning to script.
pub fn performMicrotaskCheckpoint(self: *Env, ctx: *Context) void {
    if (v8.v8__Isolate__IsExecutionTerminating(self.isolate.handle)) return;
    const exec = &ctx.execution;
    if (exec.realmState() == .dead) return;
    if (!exec.canEnterJs(.allow_draining)) {
        return;
    }
    v8.v8__MicrotaskQueue__PerformCheckpoint(ctx.microtask_queue, self.isolate.handle);
}

/// Unrestricted single-context checkpoint (even when canEnterJs is false).
/// Pure-JS `Promise.resolve` from iframe.onload does **not** go through
/// Zig PromiseResolver, so it never sets `checkpoint_pending`. When this runs
/// nested under an outer `runMicrotasks`, wake that outer loop so await
/// continuations (Fingerprint shared-iframe `ip`) are not stranded until the
/// 2s race.
pub fn performMicrotaskCheckpointFp(self: *Env, ctx: *Context) void {
    if (v8.v8__Isolate__IsExecutionTerminating(self.isolate.handle)) return;
    if (ctx.execution.realmState() == .dead) return;
    // V8 does not permit a microtask checkpoint to re-enter itself. DOM
    // serialization can synchronously trigger mutations while an outer
    // checkpoint is draining (for example, a MutationObserver callback that
    // updates the page). Preserve the work for the owning checkpoint instead
    // of invoking PerformCheckpoint recursively and tripping V8's debug
    // invariant (maybe_result.is_null()).
    if (self.checkpoint_active) {
        self.checkpoint_pending = true;
        return;
    }
    v8.v8__MicrotaskQueue__PerformCheckpoint(ctx.microtask_queue, self.isolate.handle);
    if (self.checkpoint_active) self.checkpoint_pending = true;
}

/// Drain every live realm's microtask queue once, then the isolate default
/// queue. iframe.onload pure-JS Promise reactions can land on either depending
/// on which queue V8 associates with the active Context.
pub fn drainAllRealmMicrotasks(self: *Env) void {
    if (v8.v8__Isolate__IsExecutionTerminating(self.isolate.handle)) return;
    if (self.checkpoint_active) {
        self.checkpoint_pending = true;
        return;
    }
    // Snapshot — destroyContext can run from a reaction.
    var snapshot: [64]*Context = undefined;
    const n = self.context_count;
    @memcpy(snapshot[0..n], self.contexts[0..n]);
    for (snapshot[0..n]) |ctx| {
        if (!self.isContextRegistered(ctx)) continue;
        if (ctx.execution.realmState() == .dead) continue;
        v8.v8__MicrotaskQueue__PerformCheckpoint(ctx.microtask_queue, self.isolate.handle);
    }
    // Isolate-level checkpoint (kExplicit policy still honors this).
    v8.v8__Isolate__PerformMicrotaskCheckpoint(self.isolate.handle);
    self.checkpoint_pending = true;
}

/// Same-turn drain after DOM / iframe mutations. **Prefer**
/// `EventLoop.afterDomMutation` at new call sites.
///
/// Thin wrapper: nested → microtasks only; top-level → spin/timers (see EventLoop).
/// Never invent a third drain path that calls `pumpDueTimersNow` while nested.
pub fn drainNestedHostMicrotasks(self: *Env, ctx: *Context) void {
    _ = self;
    const EventLoop = @import("EventLoop.zig");
    EventLoop.afterDomMutation(&ctx.execution);
}

pub fn runMicrotasks(self: *Env, source: TaskSource) void {
    if (self.checkpoint_active) {
        if (comptime IS_DEBUG) std.debug.assert(self.checkpoint_active);
        // Nested resolve/timer while an outer checkpoint owns the loop: only mark
        // pending. Nested PerformCheckpoint (even host-gated) × yb drain × timer
        // storms UAF/segfault on fingerprint playground (microtask.reentry spam).
        self.checkpoint_pending = true;
        if (builtin.mode == .Debug) {
            // Rate-limit: one log line per outer turn is enough; flooding stderr
            // during agent collection hid the real fault and slowed Debug builds.
            log.debug(.frame, "microtask.reentry", .{
                .source = @tagName(source),
            });
        }
        return;
    }

    const v8_isolate = self.isolate.handle;
    if (v8.v8__Isolate__IsExecutionTerminating(v8_isolate)) {
        return;
    }

    if (builtin.mode == .Debug) {
        log.debug(.frame, "microtask.checkpoint.begin", .{
            .source = @tagName(source),
        });
    }

    var checkpoint_passes: usize = 0;
    self.checkpoint_active = true;
    self.clearSchedulerSuppression();
    defer {
        self.checkpoint_active = false;
        self.clearSchedulerSuppression();
    }
    while (true) {
        self.checkpoint_pending = false;
        var i: usize = 0;
        while (i < self.context_count) : (i += 1) {
            const ctx = self.contexts[i];
            const exec = &ctx.execution;
            const frame_id = exec.frameId();
            const epoch = exec.realmEpoch();
            const st = exec.realmState();

            if (contextIsUnpublishedPendingRoot(ctx)) continue;

            if (switch (ctx.global) {
                .frame => |frame| frame._session.navigationCritical(),
                .worker => false,
            }) continue;

            if (st == .dead) {
                if (comptime IS_DEBUG) std.debug.assert(st == .dead);
                RealmLifecycleKernel.traceMicrotaskCheckpointDeadRealm(frame_id, epoch, st);
                continue;
            }

            if (exec.schedulerSuppressed()) {
                if (comptime IS_DEBUG) std.debug.assert(!exec.canEnterJs(.allow_draining));
                RealmLifecycleKernel.traceMicrotaskCheckpointSuppressed(frame_id, epoch, st);
                RealmLifecycleKernel.traceMicrotaskCheckpointAborted(frame_id, epoch, st);
                continue;
            }

            if (!exec.canEnterJs(.allow_draining)) {
                if (comptime IS_DEBUG) std.debug.assert(st != .active and st != .draining);
                RealmLifecycleKernel.traceMicrotaskCheckpointAborted(frame_id, epoch, st);
                continue;
            }

            if (checkpoint_passes >= MAX_CHECKPOINT_PASSES_PER_SCHEDULER_TICK) {
                RealmLifecycleKernel.traceMicrotaskBudgetExceeded(frame_id, epoch, st, checkpoint_passes);
                RealmLifecycleKernel.traceMicrotaskRunawayDetected(frame_id, epoch, st, checkpoint_passes);
                switch (ctx.global) {
                    .frame => |frame| frame.suppressScheduler(.runaway),
                    .worker => {
                        // TODO: worker realms intentionally lack scheduler_suppressed;
                        // add equivalent worker suppression before enabling worker checkpoints.
                        RealmLifecycleKernel.traceWorkerContainmentNotImplemented(frame_id, epoch, st);
                    },
                }
                RealmLifecycleKernel.traceMicrotaskCheckpointSuppressed(frame_id, epoch, st);
                RealmLifecycleKernel.traceMicrotaskCheckpointAborted(frame_id, epoch, st);
                if (comptime IS_DEBUG) {
                    switch (ctx.global) {
                        .frame => std.debug.assert(exec.schedulerSuppressed()),
                        .worker => {},
                    }
                }
                continue;
            }

            // Multi-context policy: one realm exhausting its semantic checkpoint
            // budget suppresses that realm only; unrelated contexts still get a turn.
            checkpoint_passes += 1;
            RealmLifecycleKernel.traceMicrotaskCheckpoint(true, frame_id, epoch, st);
            v8.v8__MicrotaskQueue__PerformCheckpoint(ctx.microtask_queue, v8_isolate);
            if (builtin.mode == .Debug) {
                log.debug(.frame, "microtask.checkpoint.done", .{
                    .frame_id = frame_id,
                    .checkpoint_passes = checkpoint_passes,
                    .pending_after = self.checkpoint_pending,
                });
            }
            RealmLifecycleKernel.traceMicrotaskCheckpoint(false, frame_id, epoch, st);
        }
        if (!self.checkpoint_pending) break;
    }

    // Release the checkpoint gate before pumping timers. setTimeout callbacks
    // call runMicrotasks(.timer_callback); if checkpoint_active is still true
    // those drains are deferred and queueEvent promises never resolve.
    self.checkpoint_active = false;
    self.clearSchedulerSuppression();

    // Promise/event/timer checkpoints may run while their scheduler callback
    // still owns V8 locals, events and listener handles. They may drain only
    // microtasks. Cross-context scheduler work belongs to the explicit outer
    // macrotask-loop checkpoint after that callback has unwound.
    if (taskSourceOwnsOuterMacrotaskTurn(source) and
        self.scheduler_pump_depth == 0 and
        self.anyContextHasReadyTimers())
    {
        self.pumpSchedulerTasks();
        if (self.checkpoint_pending) {
            self.runMicrotasks(.timer_callback);
        }
    }

    self.flushPendingIdentityRemovals();
}

test "only the outer macrotask checkpoint may pump schedulers" {
    try std.testing.expect(taskSourceOwnsOuterMacrotaskTurn(.macrotask_loop));
    try std.testing.expect(!taskSourceOwnsOuterMacrotaskTurn(.event_handler));
    try std.testing.expect(!taskSourceOwnsOuterMacrotaskTurn(.timer_callback));
    try std.testing.expect(!taskSourceOwnsOuterMacrotaskTurn(.promise_resolve));
    try std.testing.expect(!taskSourceOwnsOuterMacrotaskTurn(.after_evaluate));
}

fn flushPendingIdentityRemovals(self: *Env) void {
    var flushed_pages: [8]?*@import("../browser/Page.zig") = .{null} ** 8;
    var flushed_count: usize = 0;
    for (self.contexts[0..self.context_count]) |ctx| {
        const page = ctx.page;
        var seen = false;
        for (flushed_pages[0..flushed_count]) |p| {
            if (p == page) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        if (flushed_count < flushed_pages.len) {
            flushed_pages[flushed_count] = page;
            flushed_count += 1;
        }
        page.flushPendingIdentityRemovals();
    }
}

pub fn pumpSchedulerTasks(self: *Env) void {
    if (self.scheduler_pump_depth >= MAX_SCHEDULER_PUMP_DEPTH) return;
    if (self.anyContextOnV8Stack()) return;
    self.scheduler_pump_depth += 1;
    defer self.scheduler_pump_depth -= 1;
    // Circuit breaker only guards microtask checkpoints; timers must still run.
    self.clearSchedulerSuppression();
    self.runMacrotasks() catch |err| {
        if (comptime IS_DEBUG) {
            log.warn(.frame, "scheduler.pump", .{ .err = err });
        }
    };
}

/// True if `context` is still registered on this Env (not destroyContext'd).
fn isContextRegistered(self: *const Env, context: *Context) bool {
    for (self.contexts[0..self.context_count]) |c| {
        if (c == context) return true;
    }
    return false;
}

pub fn runMacrotasks(self: *Env) !void {
    if (v8.v8__Isolate__IsExecutionTerminating(self.isolate.handle)) {
        return;
    }
    if (self.macrotask_run_depth >= MAX_MACROTASK_RUN_DEPTH) return;
    self.macrotask_run_depth += 1;
    defer self.macrotask_run_depth -= 1;

    // Snapshot pointers: destroyContext swap-removes and deinit's a Context
    // mid-pump (React removes agent about:blank iframe ~100ms after append).
    // Iterating `contexts[0..count]` live would UAF Scheduler PriorityQueue.
    var snapshot: [64]*Context = undefined;
    const n = self.context_count;
    @memcpy(snapshot[0..n], self.contexts[0..n]);

    for (snapshot[0..n]) |ctx| {
        if (!self.isContextRegistered(ctx)) continue;
        const exec = &ctx.execution;
        if (exec.realmState() == .dead) {
            // Drop tasks that can never run legally on a dead realm (cancel-on-nav).
            switch (ctx.global) {
                .frame => |frame| frame.cancelOwnedSchedulerWork(),
                .worker => ctx.scheduler.reset(),
            }
            continue;
        }
        if (!exec.canEnterJs(.strict_active)) {
            // Draining: flush owned queue so deferred parse cannot fire after free.
            if (exec.realmState() == .draining) {
                switch (ctx.global) {
                    .frame => |frame| frame.cancelOwnedSchedulerWork(),
                    .worker => ctx.scheduler.reset(),
                }
            }
            continue;
        }
        const timers_blocked = contextBlocksTimerPump(ctx);

        if (comptime builtin.is_test == false) {
            // I hate this comptime check as much as you do. But we have tests
            // which rely on short execution before shutdown. In real world, it's
            // underterministic whether a timer will or won't run before the
            // frame shutsdown. But for tests, we need to run them to their end.
            if ((if (timers_blocked) ctx.scheduler.hasReadyNonTimerTasks() else ctx.scheduler.hasReadyTasks()) == false) {
                continue;
            }
        }

        if (!self.isContextRegistered(ctx)) continue;
        var hs: js.HandleScope = undefined;
        const entered = ctx.enter(&hs) orelse continue;
        defer entered.exit();
        // Re-check after enter — detach can race with enter.
        if (!self.isContextRegistered(ctx)) continue;
        switch (ctx.global) {
            .frame => |frame| if (timers_blocked)
                try frame.js.scheduler.runNonTimerTasks()
            else
                try frame.runOwnedScheduler(),
            .worker => try ctx.scheduler.run(),
        }
    }
}

/// Run at most one ready scheduler task across all contexts. CDP serve mode
/// interleaves this with inbound socket polling so Runtime.evaluate is not
/// starved by long macrotask batches (ebay.com).
pub fn runOneMacrotaskRound(self: *Env) !bool {
    if (v8.v8__Isolate__IsExecutionTerminating(self.isolate.handle)) {
        return false;
    }
    if (self.macrotask_run_depth >= MAX_MACROTASK_RUN_DEPTH) return false;
    self.macrotask_run_depth += 1;
    defer self.macrotask_run_depth -= 1;

    var snapshot: [64]*Context = undefined;
    const n = self.context_count;
    @memcpy(snapshot[0..n], self.contexts[0..n]);

    for (snapshot[0..n]) |ctx| {
        if (!self.isContextRegistered(ctx)) continue;
        const exec = &ctx.execution;
        if (exec.realmState() == .dead) {
            switch (ctx.global) {
                .frame => |frame| frame.cancelOwnedSchedulerWork(),
                .worker => ctx.scheduler.reset(),
            }
            continue;
        }
        if (!exec.canEnterJs(.strict_active)) {
            if (exec.realmState() == .draining) {
                switch (ctx.global) {
                    .frame => |frame| frame.cancelOwnedSchedulerWork(),
                    .worker => ctx.scheduler.reset(),
                }
            }
            continue;
        }
        const timers_blocked = contextBlocksTimerPump(ctx);
        if (!(if (timers_blocked) ctx.scheduler.hasReadyNonTimerTasks() else ctx.scheduler.hasReadyTasks())) continue;

        if (!self.isContextRegistered(ctx)) continue;
        var hs: js.HandleScope = undefined;
        const entered = ctx.enter(&hs) orelse continue;
        defer entered.exit();
        if (!self.isContextRegistered(ctx)) continue;
        const ran = switch (ctx.global) {
            .frame => |frame| if (timers_blocked)
                try frame.js.scheduler.runOneNonTimerTask()
            else
                try frame.runOwnedSchedulerOne(),
            .worker => try ctx.scheduler.runOne(),
        };
        if (ran) return true;
    }
    return false;
}

pub fn msToNextMacrotask(self: *Env) ?u64 {
    var next_task: u64 = std.math.maxInt(u64);
    for (self.contexts[0..self.context_count]) |ctx| {
        const candidate = ctx.scheduler.msToNext() orelse continue;
        next_task = @min(candidate, next_task);
    }
    return if (next_task == std.math.maxInt(u64)) null else next_task;
}

/// Pending root navigations install a second Page/context before commit; its
/// realm stays `.initializing` until headers land. Skip microtask checkpoints
/// on that unpublished page so the active document keeps draining.
fn contextIsUnpublishedPendingRoot(ctx: *Context) bool {
    return switch (ctx.global) {
        .frame => |frame| frame.parent == null and frame._page._state == .pending,
        .worker => false,
    };
}

/// Parser-inserted scripts defer timers only for the document being parsed.
/// A child iframe in .parsing must not stall the parent page (CreepJS queueEvent).
fn contextBlocksTimerPump(ctx: *Context) bool {
    return switch (ctx.global) {
        .frame => |frame| blk: {
            if (!frame.isDocumentParsing()) break :blk false;
            // Document already interactive/complete while still "parsing" for
            // lifecycle bookkeeping: allow short timers (agent/SPA polls).
            const rs = frame.document.getReadyState();
            if (std.mem.eql(u8, rs, "interactive") or std.mem.eql(u8, rs, "complete")) {
                break :blk false;
            }
            break :blk true;
        },
        .worker => false,
    };
}

/// True when any live context is mid-V8 callback (DOM API, script eval, etc.).
/// Scheduler/timer pumps from nested stacks crash with V8 `IsOnCentralStack`.
pub fn anyContextOnV8Stack(self: *const Env) bool {
    for (self.contexts[0..self.context_count]) |ctx| {
        // call_depth covers active JS callbacks. ctx.local also covers the
        // post-callback portion of a host dispatch: the callback has returned,
        // but its V8 context/HandleScope is still entered while the caller
        // performs the microtask checkpoint. Starting a macrotask from another
        // realm in that window re-enters V8 with objects from the wrong context.
        if (ctx.call_depth > 0 or ctx.local != null) return true;
    }
    return false;
}

fn anyContextHasReadyTimers(self: *const Env) bool {
    for (self.contexts[0..self.context_count]) |ctx| {
        if (contextBlocksTimerPump(ctx)) {
            if (ctx.scheduler.hasReadyNonTimerTasks()) return true;
            continue;
        }
        if (ctx.scheduler.hasReadyTasks()) return true;
    }
    return false;
}

/// Cheap host-loop hint used by the CDP runner before entering a macrotask
/// slice. Network completion is still polled first because it can enqueue a
/// task; this predicate only avoids entering V8 when every context is idle.
pub fn hasReadyMacrotasks(self: *const Env) bool {
    return self.anyContextHasReadyTimers();
}

/// True while inbound CDP must not run (nested V8, navigation commit).
/// Do not gate on is_evaluating alone — between script bodies in evaluate()
/// the main thread is idle and must service Runtime.evaluate / navigate ack.
pub fn blocksInboundCdp(self: *const Env) bool {
    if (self.anyContextOnV8Stack()) return true;
    for (self.contexts[0..self.context_count]) |ctx| {
        switch (ctx.global) {
            .frame => |frame| {
                if (frame._session.navigationCritical()) return true;
            },
            .worker => {},
        }
    }
    return false;
}

pub fn pumpMessageLoop(self: *const Env) void {
    var hs: v8.HandleScope = undefined;
    v8.v8__HandleScope__CONSTRUCT(&hs, self.isolate.handle);
    defer v8.v8__HandleScope__DESTRUCT(&hs);

    const isolate = self.isolate.handle;
    const platform = self.platform.handle;
    while (v8.v8__Platform__PumpMessageLoop(platform, isolate, false)) {}
}

pub fn hasBackgroundTasks(self: *const Env) bool {
    return v8.v8__Isolate__HasPendingBackgroundTasks(self.isolate.handle);
}

pub fn waitForBackgroundTasks(self: *Env) void {
    var hs: v8.HandleScope = undefined;
    v8.v8__HandleScope__CONSTRUCT(&hs, self.isolate.handle);
    defer v8.v8__HandleScope__DESTRUCT(&hs);

    const isolate = self.isolate.handle;
    const platform = self.platform.handle;
    while (v8.v8__Isolate__HasPendingBackgroundTasks(isolate)) {
        _ = v8.v8__Platform__PumpMessageLoop(platform, isolate, true);
        self.runMicrotasks(.background_tasks);
    }
}

pub fn runIdleTasks(self: *const Env) void {
    v8.v8__Platform__RunIdleTasks(self.platform.handle, self.isolate.handle, 1);
}

// V8 doesn't immediately free memory associated with
// a Context, it's managed by the garbage collector. We use the
// `lowMemoryNotification` call on the isolate to encourage v8 to free
// any contexts which have been freed.
// This GC is very aggressive. Use memoryPressureNotification for less
// aggressive GC passes.
pub fn lowMemoryNotification(self: *Env) void {
    var handle_scope: js.HandleScope = undefined;
    handle_scope.init(self.isolate);
    defer handle_scope.deinit();
    self.isolate.lowMemoryNotification();
}

// V8 doesn't immediately free memory associated with
// a Context, it's managed by the garbage collector. We use the
// `memoryPressureNotification` call on the isolate to encourage v8 to free
// any contexts which have been freed.
// The level indicates the aggressivity of the GC required:
// moderate speeds up incremental GC
// critical runs one full GC
// For a more aggressive GC, use lowMemoryNotification.
pub fn memoryPressureNotification(self: *Env, level: Isolate.MemoryPressureLevel) void {
    var handle_scope: js.HandleScope = undefined;
    handle_scope.init(self.isolate);
    defer handle_scope.deinit();
    self.isolate.memoryPressureNotification(level);
}

pub fn dumpMemoryStats(self: *Env) void {
    const stats = self.isolate.getHeapStatistics();
    std.debug.print(
        \\ Total Heap Size: {d}
        \\ Total Heap Size Executable: {d}
        \\ Total Physical Size: {d}
        \\ Total Available Size: {d}
        \\ Used Heap Size: {d}
        \\ Heap Size Limit: {d}
        \\ Malloced Memory: {d}
        \\ External Memory: {d}
        \\ Peak Malloced Memory: {d}
        \\ Number Of Native Contexts: {d}
        \\ Number Of Detached Contexts: {d}
        \\ Total Global Handles Size: {d}
        \\ Used Global Handles Size: {d}
        \\ Zap Garbage: {any}
        \\
    , .{ stats.total_heap_size, stats.total_heap_size_executable, stats.total_physical_size, stats.total_available_size, stats.used_heap_size, stats.heap_size_limit, stats.malloced_memory, stats.external_memory, stats.peak_malloced_memory, stats.number_of_native_contexts, stats.number_of_detached_contexts, stats.total_global_handles_size, stats.used_global_handles_size, stats.does_zap_garbage });
}

pub fn terminate(self: *Env) void {
    self.termination_requested.store(true, .release);
    v8.v8__Isolate__TerminateExecution(self.isolate.handle);
}

pub fn isExecutionTerminating(self: *const Env) bool {
    return self.termination_requested.load(.acquire) or
        v8.v8__Isolate__IsExecutionTerminating(self.isolate.handle);
}

/// Clears explicit CLI/server teardown termination only. Microtask containment
/// must not use temporary TerminateExecution/CancelTerminateExecution cycles.
pub fn cancelTerminate(self: *Env) void {
    v8.v8__Isolate__CancelTerminateExecution(self.isolate.handle);
    self.termination_requested.store(false, .release);
}

fn uncaughtExceptionCallback(message_handle: ?*const v8.Message, data_handle: ?*const v8.Value) callconv(.c) void {
    const message_ptr = message_handle orelse return;
    const exception_ptr = data_handle orelse return;
    const v8_isolate = v8.v8__Object__GetIsolate(@ptrCast(exception_ptr)).?;
    const isolate = js.Isolate{ .handle = v8_isolate };
    const ctx, const v8_context = Context.fromIsolate(isolate) orelse return;

    const local = js.Local{
        .ctx = ctx,
        .isolate = isolate,
        .handle = v8_context,
        .call_arena = ctx.call_arena,
    };

    const err_val = js.Value{ .local = &local, .handle = exception_ptr };

    const msg_text: []const u8 = err_val.toStringSlice() catch "Uncaught exception";

    const filename = blk: {
        const resource_handle = v8.v8__Message__GetScriptResourceName(message_ptr) orelse break :blk ctx.execution.base();
        const name_val = js.Value{ .local = &local, .handle = resource_handle };
        if (name_val.toStringSlice() catch null) |s| {
            if (s.len > 0) break :blk s;
        }
        break :blk ctx.execution.base();
    };

    const line_raw = v8.v8__Message__GetLineNumber(message_ptr, v8_context);
    const line: u32 = if (line_raw < 0) 0 else @intCast(line_raw);
    const col_raw = v8.v8__Message__GetStartColumn(message_ptr);
    const col: u32 = if (col_raw < 0) 0 else @intCast(col_raw);

    switch (ctx.global) {
        .frame => |frame| {
            frame.window.reportUncaughtException(err_val, msg_text, filename, line, col, frame) catch |err| {
                log.warn(.js, "uncaught exception handler", .{ .err = err, .target = "window" });
            };
        },
        .worker => |wsg| {
            wsg.reportUncaughtException(err_val, msg_text, filename, line, col) catch |err| {
                log.warn(.js, "uncaught exception handler", .{ .err = err, .target = "worker" });
            };
        },
    }
}

fn promiseRejectCallback(message_handle: v8.PromiseRejectMessage) callconv(.c) void {
    const promise_event = v8.v8__PromiseRejectMessage__GetEvent(&message_handle);
    if (promise_event != v8.kPromiseRejectWithNoHandler and promise_event != v8.kPromiseHandlerAddedAfterReject) {
        return;
    }

    const promise_handle = v8.v8__PromiseRejectMessage__GetPromise(&message_handle).?;
    const v8_isolate = v8.v8__Object__GetIsolate(@ptrCast(promise_handle)).?;
    const isolate = js.Isolate{ .handle = v8_isolate };
    const ctx, const v8_context = Context.fromIsolate(isolate) orelse return;

    const local = js.Local{
        .ctx = ctx,
        .isolate = isolate,
        .handle = v8_context,
        .call_arena = ctx.call_arena,
    };

    const promise = (js.PromiseRejection{ .local = &local, .handle = &message_handle }).promise();
    if (promise_event == v8.kPromiseRejectWithNoHandler) {
        queuePromiseRejection(ctx, promise, (js.PromiseRejection{
            .local = &local,
            .handle = &message_handle,
        }).reason()) catch |err| {
            log.warn(.browser, "queue unhandled rejection", .{ .err = err });
        };
    } else {
        markPromiseRejectionHandled(ctx, promise);
    }
}

fn findPendingPromiseRejection(ctx: *Context, promise: js.Promise) ?*Context.PendingPromiseRejection {
    for (ctx.pending_promise_rejections.items) |pending| {
        if (v8.v8__Global__IsEqual(&pending.promise.handle, @ptrCast(promise.handle))) return pending;
    }
    return null;
}

fn queuePromiseRejection(ctx: *Context, promise: js.Promise, reason: ?js.Value) !void {
    if (findPendingPromiseRejection(ctx, promise) != null) return;

    const pending = try ctx.arena.create(Context.PendingPromiseRejection);
    pending.* = .{
        .context = ctx,
        .promise = try promise.persist(),
        .reason = if (reason) |value| try value.persist() else null,
    };
    try ctx.pending_promise_rejections.append(ctx.arena, pending);
    try ctx.scheduler.add(pending, notifyPromiseRejectionTask, 0, .{
        .name = "promise rejection notification",
        .low_priority = false,
    });
    schedulePromiseRejectionPump(ctx);
}

fn markPromiseRejectionHandled(ctx: *Context, promise: js.Promise) void {
    const pending = findPendingPromiseRejection(ctx, promise) orelse return;
    switch (pending.state) {
        .pending => pending.state = .handled,
        .reported => {
            if (pending.notify_handled) return;
            pending.notify_handled = true;
            ctx.scheduler.add(pending, notifyPromiseRejectionTask, 0, .{
                .name = "promise rejection handled notification",
                .low_priority = false,
            }) catch return;
            schedulePromiseRejectionPump(ctx);
        },
        .handled => {},
    }
}

fn schedulePromiseRejectionPump(ctx: *Context) void {
    switch (ctx.global) {
        .frame => |frame| frame.scheduleDeferredMacrotaskPump(0) catch {},
        .worker => |worker| worker._worker._frame.scheduleDeferredMacrotaskPump(0) catch {},
    }
}

fn notifyPromiseRejectionTask(raw: *anyopaque) !?u32 {
    const pending: *Context.PendingPromiseRejection = @ptrCast(@alignCast(raw));
    const ctx = pending.context;
    if (ctx.execution.realmState() == .dead) return null;

    const no_handler = switch (pending.state) {
        .pending => blk: {
            pending.state = .reported;
            break :blk true;
        },
        .reported => blk: {
            if (!pending.notify_handled) return null;
            pending.notify_handled = false;
            pending.state = .handled;
            break :blk false;
        },
        .handled => return null,
    };

    // Scheduler tasks can run either from Env.runMacrotasks (context already
    // entered) or directly from a Frame/Runner wait edge. Use a full Local
    // scope so both paths have a V8 Context, HandleScope, and ctx.local.
    var local_scope: js.Local.Scope = undefined;
    ctx.localScope(&local_scope);
    defer local_scope.deinit();
    const local = &local_scope.local;
    const promise = pending.promise.local(local);
    const reason = if (pending.reason) |*value| value.local(local) else null;
    switch (ctx.global) {
        .frame => |frame| try frame.window.notifyPromiseRejection(no_handler, promise, reason, frame),
        .worker => |worker| try worker.notifyPromiseRejection(no_handler, promise, reason),
    }
    return null;
}

fn fatalCallback(c_location: [*c]const u8, c_message: [*c]const u8) callconv(.c) void {
    const location = std.mem.span(c_location);
    const message = std.mem.span(c_message);
    log.fatal(.app, "V8 fatal callback", .{ .location = location, .message = message });
    @import("../../support/crash_handler.zig").crash("Fatal V8 Error", .{ .location = location, .message = message }, @returnAddress());
}

fn oomCallback(c_location: [*c]const u8, details: ?*const v8.OOMDetails) callconv(.c) void {
    const location = std.mem.span(c_location);
    const detail = if (details) |d| std.mem.span(d.detail) else "";
    log.fatal(.app, "V8 OOM", .{ .location = location, .detail = detail });
    @import("../../support/crash_handler.zig").crash("V8 OOM", .{ .location = location, .detail = detail }, @returnAddress());
}

const PrivateSymbols = struct {
    const Private = @import("Private.zig");

    child_nodes: Private,
    children: Private,

    fn init(isolate: *v8.Isolate) PrivateSymbols {
        return .{
            .child_nodes = Private.init(isolate, "child_nodes"),
            .children = Private.init(isolate, "children"),
        };
    }

    fn deinit(self: *PrivateSymbols) void {
        self.child_nodes.deinit();
        self.children.deinit();
    }
};

const testing = @import("../../testing/testing.zig");
test "Env: Worker context " {
    const session = testing.test_session;
    const frame = try session.createPage();
    defer session.removePage();

    const worker = try @import("../webapi/Worker.zig").init(
        "http://localhost:9582/src/browser/tests/testing.js",
        null,
        &frame.js.execution,
    );

    var ls: js.Local.Scope = undefined;
    worker._worker_scope.js.localScope(&ls);
    defer ls.deinit();

    try testing.expectEqual(true, (try ls.local.exec("typeof Node === 'undefined'", null)).isTrue());
    try testing.expectEqual(true, (try ls.local.exec("typeof WorkerGlobalScope !== 'undefined'", null)).isTrue());
}

test "Env: Frame context" {
    const session = testing.test_session;
    const frame = try session.createPage();
    defer session.removePage();

    // Frame already has a context created, use it directly
    const ctx = frame.js;

    var ls: js.Local.Scope = undefined;
    ctx.localScope(&ls);
    defer ls.deinit();

    try testing.expectEqual(true, (try ls.local.exec("typeof Node !== 'undefined'", null)).isTrue());
    try testing.expectEqual(true, (try ls.local.exec("typeof WorkerGlobalScope === 'undefined'", null)).isTrue());
}
