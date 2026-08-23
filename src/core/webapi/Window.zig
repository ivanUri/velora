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
const builtin = @import("builtin");

const js = @import("../js/js.zig");
const Frame = @import("../browser/Frame.zig");
const EventManagerBase = @import("../browser/EventManagerBase.zig");
const Console = @import("Console.zig");
const History = @import("History.zig");
const Navigation = @import("navigation/Navigation.zig");
const Crypto = @import("Crypto.zig");
const CSS = @import("CSS.zig");
const Navigator = @import("Navigator.zig");
const Screen = @import("Screen.zig");
const VisualViewport = @import("VisualViewport.zig");
const Performance = @import("Performance.zig");
const Document = @import("../dom/Document.zig");
const Location = @import("Location.zig");
const Fetch = @import("net/Fetch.zig");
const Event = @import("Event.zig");
const EventTarget = @import("EventTarget.zig");
const ErrorEvent = @import("event/ErrorEvent.zig");
const MessageEvent = @import("event/MessageEvent.zig");
const MessagePort = @import("MessagePort.zig");
const MediaQueryList = @import("css/MediaQueryList.zig");
const storage = @import("storage/storage.zig");
const Element = @import("../dom/Element.zig");
const CSSStyleDeclaration = @import("css/CSSStyleDeclaration.zig");
const CSSStyleProperties = @import("css/CSSStyleProperties.zig");
const CustomElementRegistry = @import("CustomElementRegistry.zig");
const Selection = @import("Selection.zig");
const Timers = @import("Timers.zig");
const Notification = @import("../../runtime/Notification.zig");
const IDBFactory = @import("idb.zig").IDBFactory;
const CacheStorage = @import("cache_storage.zig").CacheStorage;
const SpeechSynthesis = @import("speech/SpeechSynthesis.zig").SpeechSynthesis;
const TrustedTypePolicyFactory = @import("trusted_types.zig").TrustedTypePolicyFactory;
const CookieStore = @import("cookie_store.zig").CookieStore;
const TaskScheduler = @import("scheduler_api.zig").Scheduler;
const Chrome = @import("Chrome.zig");
const ModelContext = @import("ModelContext.zig");
const global_event_handlers = @import("global_event_handlers.zig");

const log = @import("../../support/log.zig");
const IS_DEBUG = builtin.mode == .Debug;

const Allocator = std.mem.Allocator;

pub fn registerTypes() []const type {
    return &.{ Window, CrossOriginWindow };
}

const Window = @This();

_proto: *EventTarget,
_frame: *Frame,
_document: *Document,
_css: CSS = .init,
_crypto: Crypto = .init,
_console: Console = .init,
_navigator: Navigator = .init,
_model_context: ModelContext = .init,
_screen: *Screen,
_visual_viewport: *VisualViewport,
_performance: Performance,
_storage_bucket: storage.Bucket = .{},
_on_load: ?js.Function.Global = null,
_on_pageshow: ?js.Function.Global = null,
_on_popstate: ?js.Function.Global = null,
_on_hashchange: ?js.Function.Global = null,
_on_error: ?js.Function.Global = null,
_on_message: ?js.Function.Global = null,
_pending_post_messages: std.ArrayListUnmanaged(*PostMessageCallback) = .empty,
_on_rejection_handled: ?js.Function.Global = null,
_on_unhandled_rejection: ?js.Function.Global = null,
_current_event: ?*Event = null,
_location: *Location,
_chrome: Chrome = .init,
_external: Chrome.External = .{},
_timers: Timers = .{},
_custom_elements: CustomElementRegistry = .{},
_indexed_db: IDBFactory = .{},
_caches: CacheStorage = .{},
_speech_synthesis: SpeechSynthesis = .{},
_trusted_types: TrustedTypePolicyFactory = .{},
_cookie_store: *CookieStore,
_task_scheduler: TaskScheduler = .{},
// Nested browsing contexts own independent session history/navigation state.
// The root Window continues to use Session's stores so history survives
// replacement Documents in the top-level browsing context.
_child_history: History = .{},
_child_navigation: Navigation = .{ ._proto = undefined },
_scroll_pos: struct {
    x: u32,
    y: u32,
    state: enum {
        scroll,
        end,
        done,
    },
} = .{
    .x = 0,
    .y = 0,
    .state = .done,
},
// A cross origin wrapper for this window
_cross_origin_wrapper: CrossOriginWindow,

// The Window that called window.open to create this one. Null for the root
// window, for noopener popups, and cleared if the opener is torn down while
// we're still alive. Only valid if `!_opener.?._closed`.
_opener: ?*Window = null,

// True after our Frame has been deinit'd by window.close. Many things on the
// window become invalid once this is true.
_closed: bool = false,

// Popup name (owned by page.arena)
_name: []const u8 = "",

pub fn asEventTarget(self: *Window) *EventTarget {
    return self._proto;
}

pub fn getEvent(self: *const Window) ?*Event {
    return self._current_event;
}

pub fn getSelf(self: *Window) *Window {
    return self;
}

pub fn getWindow(self: *Window) *Window {
    return self;
}

pub fn getOpener(self: *Window, frame: *Frame) ?Access {
    const opener = self._opener orelse return null;
    // Closed *opener* window is not exposed; our own closed flag does not
    // clear opener until the discard task runs (WPT close-method).
    if (opener._closed) return null;
    return Access.init(frame.window, opener);
}

pub fn getClosed(self: *const Window) bool {
    return self._closed;
}

pub fn getName(self: *const Window) []const u8 {
    // Discarded browsing context (iframe removed / closed): name is "".
    const frame = self._frame;
    if (self._closed or frame._detach_pending or frame._deinit_done) return "";
    if (frame.document._frame != frame and frame.iframe != null) return "";
    if (self._name.len > 0) return self._name;
    // Reflect iframe name attribute until script sets window.name.
    if (frame.iframe) |iframe| {
        return iframe.asElement().getAttributeSafe(comptime .wrap("name")) orelse "";
    }
    return "";
}

pub fn setName(self: *Window, name: []const u8, frame: *Frame) !void {
    // After discard, sets are ignored (WPT name-attribute).
    if (self._closed or frame._detach_pending or frame._deinit_done) return;
    if (frame.document._frame != frame and frame.iframe != null) return;
    // Store in the Page's frame arena so the slice outlives any call_arena.
    self._name = try frame.arena.dupe(u8, name);
}

pub fn getTop(self: *Window, frame: *Frame) Access {
    var p = self._frame;
    while (p.parent) |parent| {
        p = parent;
    }
    return Access.init(frame.window, p.window);
}

pub fn getParent(self: *Window, frame: *Frame) Access {
    if (self._frame.parent) |p| {
        return Access.init(frame.window, p.window);
    }
    return .{ .window = self };
}

pub fn getDocument(self: *Window) *Document {
    return self._document;
}

pub fn getConsole(self: *Window) *Console {
    return &self._console;
}

pub fn getNavigator(self: *Window) *Navigator {
    return &self._navigator;
}

pub fn getScreen(self: *Window) *Screen {
    return self._screen;
}

pub fn getVisualViewport(self: *const Window) *VisualViewport {
    return self._visual_viewport;
}

pub fn getCrypto(self: *Window) *Crypto {
    return &self._crypto;
}

pub fn getCSS(self: *Window) *CSS {
    return &self._css;
}

pub fn getPerformance(self: *Window) *Performance {
    return &self._performance;
}

fn getOriginStorageBucket(self: *Window) *storage.Bucket {
    const frame = self._frame;
    const origin = frame.origin orelse "null";
    return frame._session.storage_shed.getOrPut(
        frame._session.arena,
        origin,
    ) catch {
        return &self._storage_bucket;
    };
}

pub fn getLocalStorage(self: *Window) *storage.Lookup {
    return &self.getOriginStorageBucket().local;
}

pub fn getSessionStorage(self: *Window) *storage.Lookup {
    return &self.getOriginStorageBucket().session;
}

pub fn getOrigin(self: *const Window) []const u8 {
    return self._frame.origin orelse "null";
}

pub fn getSelection(self: *const Window) *Selection {
    return &self._document._selection;
}

pub fn getLocation(self: *const Window) *Location {
    return self._location;
}

pub fn getChrome(self: *Window) ?*Chrome {
    if (self._frame.loadedProfile().isFirefox()) return null;
    return &self._chrome;
}

pub fn getExternal(self: *Window) *Chrome.External {
    return &self._external;
}

pub fn setLocation(self: *Window, url: [:0]const u8, frame: *Frame) !void {
    _ = frame;
    return self._frame.scheduleNavigation(url, .{ .reason = .script, .kind = .{ .push = null } }, .{ .script = self._frame });
}

pub fn getHistory(self: *Window, _: *Frame) *History {
    return self._frame.historyStore();
}

pub fn getNavigation(self: *Window, _: *Frame) *Navigation {
    return self._frame.navigationStore();
}

pub fn getCustomElements(self: *Window) *CustomElementRegistry {
    return &self._custom_elements;
}

pub fn getIndexedDB(self: *Window) *IDBFactory {
    return &self._indexed_db;
}

pub fn getCaches(self: *Window) *CacheStorage {
    return &self._caches;
}

pub fn getSpeechSynthesis(self: *Window) *SpeechSynthesis {
    return &self._speech_synthesis;
}

pub fn getTrustedTypes(self: *Window) *TrustedTypePolicyFactory {
    return &self._trusted_types;
}

pub fn getCookieStore(self: *Window) *CookieStore {
    return self._cookie_store;
}

pub fn getTaskScheduler(self: *Window) *TaskScheduler {
    return &self._task_scheduler;
}

pub fn getIsSecureContext(self: *const Window, frame: *Frame) bool {
    _ = self;
    return frame.isSecureContext();
}

pub fn getOnLoad(self: *const Window) ?js.Function.Global {
    return self._on_load;
}

pub fn setOnLoad(self: *Window, setter: ?FunctionSetter) void {
    self._on_load = getFunctionFromSetter(setter);
}

pub fn getOnPageShow(self: *const Window) ?js.Function.Global {
    return self._on_pageshow;
}

pub fn setOnPageShow(self: *Window, setter: ?FunctionSetter) void {
    self._on_pageshow = getFunctionFromSetter(setter);
}

pub fn getOnPopState(self: *const Window) ?js.Function.Global {
    return self._on_popstate;
}

pub fn setOnPopState(self: *Window, setter: ?FunctionSetter) void {
    self._on_popstate = getFunctionFromSetter(setter);
}

pub fn getOnHashChange(self: *const Window) ?js.Function.Global {
    return self._on_hashchange;
}

pub fn setOnHashChange(self: *Window, setter: ?FunctionSetter) void {
    self._on_hashchange = getFunctionFromSetter(setter);
}

pub fn getModelContext(self: *Window) *ModelContext {
    return &self._model_context;
}

pub fn getFrameElement(self: *const Window) ?*Element.Html.IFrame {
    return self._frame.iframe;
}

pub fn getOnError(self: *const Window) ?js.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *Window, setter: ?FunctionSetter) void {
    self._on_error = getFunctionFromSetter(setter);
}

pub fn getOnMessage(self: *const Window) ?js.Function.Global {
    return self._on_message;
}

pub fn setOnMessage(self: *Window, setter: ?FunctionSetter) void {
    self._on_message = getFunctionFromSetter(setter);
    self.flushPendingPostMessages();
}

fn getTouchHandler(self: *Window, handler: global_event_handlers.Handler, frame: *Frame) !?js.Function.Global {
    return frame._event_target_attr_listeners.get(.{ .target = self.asEventTarget(), .handler = handler });
}

fn setTouchHandler(self: *Window, handler: global_event_handlers.Handler, setter: ?FunctionSetter, frame: *Frame) !void {
    const callback = getFunctionFromSetter(setter);
    if (callback) |cb| {
        try frame._event_target_attr_listeners.put(frame.arena, .{
            .target = self.asEventTarget(),
            .handler = handler,
        }, cb);
    } else {
        _ = frame._event_target_attr_listeners.remove(.{
            .target = self.asEventTarget(),
            .handler = handler,
        });
    }
}

pub fn getOnTouchStart(self: *Window, frame: *Frame) !?js.Function.Global {
    return getTouchHandler(self, .ontouchstart, frame);
}

pub fn setOnTouchStart(self: *Window, setter: ?FunctionSetter, frame: *Frame) !void {
    return setTouchHandler(self, .ontouchstart, setter, frame);
}

pub fn getOnTouchEnd(self: *Window, frame: *Frame) !?js.Function.Global {
    return getTouchHandler(self, .ontouchend, frame);
}

pub fn setOnTouchEnd(self: *Window, setter: ?FunctionSetter, frame: *Frame) !void {
    return setTouchHandler(self, .ontouchend, setter, frame);
}

pub fn getOnTouchMove(self: *Window, frame: *Frame) !?js.Function.Global {
    return getTouchHandler(self, .ontouchmove, frame);
}

pub fn setOnTouchMove(self: *Window, setter: ?FunctionSetter, frame: *Frame) !void {
    return setTouchHandler(self, .ontouchmove, setter, frame);
}

pub fn getOnTouchCancel(self: *Window, frame: *Frame) !?js.Function.Global {
    return getTouchHandler(self, .ontouchcancel, frame);
}

pub fn setOnTouchCancel(self: *Window, setter: ?FunctionSetter, frame: *Frame) !void {
    return setTouchHandler(self, .ontouchcancel, setter, frame);
}

/// Deliver window.postMessage events that arrived before any message listener was registered.
pub fn flushPendingPostMessages(self: *Window) void {
    const frame = self._frame;
    const event_target = self.asEventTarget();

    while (self._pending_post_messages.items.len > 0) {
        if (!frame._event_manager.hasDirectListeners(event_target, "message", self._on_message)) {
            break;
        }

        const pending = self._pending_post_messages.orderedRemove(0);
        schedulePostMessageDelivery(frame, pending) catch |err| {
            log.warn(.browser, "pending postMessage schedule", .{ .err = err });
            pending.message.release();
            pending.deinit();
        };
    }
}

/// Cancel messages owned by this Window that never became scheduler tasks.
/// The scheduler finalizes queued tasks separately; once a callback moves into
/// `_pending_post_messages`, the Window is its sole owner and must release it
/// when the browsing context is discarded.
pub fn cancelPendingPostMessages(self: *Window) void {
    while (self._pending_post_messages.pop()) |pending| {
        pending.message.release();
        pending.deinit();
    }
    self._pending_post_messages = .empty;
}

fn queuePendingPostMessage(self: *Window, callback: *PostMessageCallback) !void {
    const frame = self._frame;
    const max_pending: usize = 64;
    while (self._pending_post_messages.items.len >= max_pending) {
        const dropped = self._pending_post_messages.orderedRemove(0);
        dropped.message.release();
        dropped.deinit();
    }
    try self._pending_post_messages.append(frame.arena, callback);
}

pub fn getOnRejectionHandled(self: *const Window) ?js.Function.Global {
    return self._on_rejection_handled;
}

pub fn setOnRejectionHandled(self: *Window, setter: ?FunctionSetter) void {
    self._on_rejection_handled = getFunctionFromSetter(setter);
}

pub fn getOnUnhandledRejection(self: *const Window) ?js.Function.Global {
    return self._on_unhandled_rejection;
}

pub fn setOnUnhandledRejection(self: *Window, setter: ?FunctionSetter) void {
    self._on_unhandled_rejection = getFunctionFromSetter(setter);
}

pub fn fetch(_: *const Window, input: Fetch.Input, options: ?Fetch.InitOpts, exec: *const js.Execution) !js.Promise {
    return Fetch.init(input, options, exec);
}

pub fn setTimeout(self: *Window, handler: Timers.LegacyHandler, delay_ms: ?u32, params: []js.Value.Temp, exec: *js.Execution) !u32 {
    const cb = try handler.resolve(exec);
    return self._timers.schedule(exec, cb, delay_ms orelse 0, .{
        .repeat = false,
        .params = params,
        .name = "window.setTimeout",
    });
}

pub fn setInterval(self: *Window, handler: Timers.LegacyHandler, delay_ms: ?u32, params: []js.Value.Temp, exec: *js.Execution) !u32 {
    const cb = try handler.resolve(exec);
    return self._timers.schedule(exec, cb, delay_ms orelse 0, .{
        .repeat = true,
        .params = params,
        .name = "window.setInterval",
    });
}

pub fn setImmediate(self: *Window, cb: js.Function.Temp, params: []js.Value.Temp, exec: *js.Execution) !u32 {
    return self._timers.schedule(exec, cb, 0, .{
        .repeat = false,
        .params = params,
        .name = "window.setImmediate",
    });
}

pub fn requestAnimationFrame(self: *Window, cb: js.Function.Temp, exec: *js.Execution) !u32 {
    return self._timers.schedule(exec, cb, 5, .{
        .repeat = false,
        .params = &.{},
        .mode = .animation_frame,
        .name = "window.requestAnimationFrame",
    });
}

pub fn queueMicrotask(_: *Window, cb: js.Function, frame: *Frame) void {
    frame.js.queueMicrotaskFunc(cb);
}

pub fn clearTimeout(self: *Window, id: u32) void {
    self._timers.clear(id);
}

pub fn clearInterval(self: *Window, id: u32) void {
    self._timers.clear(id);
}

pub fn clearImmediate(self: *Window, id: u32) void {
    self._timers.clear(id);
}

pub fn cancelAnimationFrame(self: *Window, id: u32) void {
    self._timers.clear(id);
}

const RequestIdleCallbackOpts = struct {
    timeout: ?u32 = null,
};
pub fn requestIdleCallback(self: *Window, cb: js.Function.Temp, opts_: ?RequestIdleCallbackOpts, exec: *js.Execution) !u32 {
    const opts = opts_ orelse RequestIdleCallbackOpts{};
    // An omitted timeout is not a 50ms timer. It is an idle task with no
    // author deadline; the idle-priority scheduler decides when there is
    // budget. Only an explicit `timeout` creates a timer deadline.
    return self._timers.schedule(exec, cb, 0, .{
        .mode = .idle,
        .idle_timeout_ms = opts.timeout,
        .repeat = false,
        .params = &.{},
        .low_priority = true,
        .name = "window.requestIdleCallback",
    });
}

pub fn cancelIdleCallback(self: *Window, id: u32) void {
    self._timers.clear(id);
}

pub fn reportError(self: *Window, err: js.Value, frame: *Frame) !void {
    try self.reportUncaughtException(
        err,
        err.toStringSlice() catch "Unknown error",
        frame.url,
        0,
        0,
        frame,
    );
}

/// Report an uncaught exception to `window.onerror` and `error` listeners.
pub fn reportUncaughtException(
    self: *Window,
    err: js.Value,
    message: []const u8,
    filename: []const u8,
    line: u32,
    col: u32,
    frame: *Frame,
) !void {
    const error_event = try ErrorEvent.initTrusted(comptime .wrap("error"), .{
        .@"error" = try err.temp(),
        .message = message,
        .filename = filename,
        .lineno = line,
        .colno = col,
        .bubbles = false,
        .cancelable = true,
    }, frame._page);

    // Invoke window.onerror callback if set (per WHATWG spec, this is called
    // with 5 arguments: message, source, lineno, colno, error)
    // If it returns true, the event is cancelled.
    var prevent_default = false;
    if (self._on_error) |on_error| {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const local_func = ls.toLocal(on_error);
        const result = EventManagerBase.invokeCallback(&ls.local, ls.local.ctx, local_func, js.Value, .{
            error_event._message,
            error_event._filename,
            error_event._line_number,
            error_event._column_number,
            err,
        }, "window.onerror");

        // Per spec: returning true from onerror cancels the event
        if (result) |r| {
            prevent_default = r.isTrue();
        }
    }

    const event = error_event.asEvent();
    event._prevent_default = prevent_default;
    // Pass null as handler: onerror was already called above with 5 args.
    // We still dispatch so that addEventListener('error', ...) listeners fire.
    try frame._event_manager.dispatchDirect(self.asEventTarget(), event, null, .{
        .context = "window.uncaughtException",
    });

    if (comptime builtin.is_test == false) {
        if (!event._prevent_default) {
            log.warn(.js, "window.uncaughtException", .{
                .message = error_event._message,
                .filename = error_event._filename,
                .line_number = error_event._line_number,
                .column_number = error_event._column_number,
            });
        }
    }
    frame._page.session.browser.observeJavaScriptError(
        "uncaught-exception",
        error_event._message,
        error_event._filename,
        error_event._line_number,
        error_event._column_number,
        frame._frame_id,
        frame._loader_id,
        null,
    );
}

pub fn matchMedia(_: *const Window, query: []const u8, frame: *Frame) !*MediaQueryList {
    return frame._factory.eventTarget(MediaQueryList{
        ._proto = undefined,
        ._media = try frame.dupeString(query),
    });
}

pub fn getComputedStyle(_: *const Window, element: *Element, pseudo_element: ?[]const u8, frame: *Frame) !*CSSStyleDeclaration {
    // Chrome always returns a CSSStyleDeclaration for ::before/::after (often
    // empty). Fluent UI on signup.live.com queries these heavily; warning on
    // every call flooded logs and did not change behavior. Fall back to the
    // element's computed style (same as prior) without spam.
    if (pseudo_element) |pe| {
        if (pe.len != 0) {
            // Known generated-content pseudos: silent host-style fallback.
            const pe_trim = std.mem.trim(u8, pe, &std.ascii.whitespace);
            const known =
                std.ascii.eqlIgnoreCase(pe_trim, "::before") or
                std.ascii.eqlIgnoreCase(pe_trim, ":before") or
                std.ascii.eqlIgnoreCase(pe_trim, "::after") or
                std.ascii.eqlIgnoreCase(pe_trim, ":after") or
                std.ascii.eqlIgnoreCase(pe_trim, "::marker") or
                std.ascii.eqlIgnoreCase(pe_trim, ":marker");
            if (!known) {
                log.debug(.not_implemented, "window.GetComputedStyle", .{ .pseudo_element = pe });
            }
        }
    }
    return CSSStyleDeclaration.init(element, true, frame);
}

// window.open(url?, target?, features?) — v1 scope:
//   * Always creates a new popup Frame on the Page (sibling to the root).
//   * Honors `noopener` / `noreferrer` tokens in `features` (opener=null,
//     return value=null). Geometry (width, height, ...) ignored.
//   * `target` values `_self` / `_parent` / `_top` navigate the current frame.
//     Any other value is treated as a popup name; reusing a live name
//     navigates the existing popup instead of spawning a new one.
//   * `url` empty or missing opens about:blank.
pub fn open(self: *Window, url_: ?[]const u8, target_: ?[]const u8, features_: ?[]const u8, frame: *Frame) !?Access {
    const raw_url = url_ orelse "";
    const target = target_ orelse "";
    const features = features_ orelse "";

    const no_opener = hasFeatureToken(features, "noopener") or hasFeatureToken(features, "noreferrer");

    // _self / _parent / _top navigate the current browsing context.
    if (std.ascii.eqlIgnoreCase(target, "_self") or
        std.ascii.eqlIgnoreCase(target, "_parent") or
        std.ascii.eqlIgnoreCase(target, "_top"))
    {
        const nav_target = frame.resolveTargetFrame(target) orelse frame;
        const nav_url = if (raw_url.len == 0) "about:blank" else raw_url;
        try frame.scheduleNavigation(nav_url, .{
            .reason = .script,
            .kind = .{ .push = null },
        }, .{ .script = nav_target });

        if (no_opener) {
            return null;
        }

        return Access.init(frame.window, nav_target.window);
    }

    const page = frame._page;

    // Name-based reuse: if a popup with this name already exists, reuse it.
    // `_blank` is reserved and never reuses.
    const is_named = target.len > 0 and !std.ascii.eqlIgnoreCase(target, "_blank");
    if (is_named) {
        if (page.findPopupByName(target)) |existing| {
            if (raw_url.len > 0) {
                try existing.scheduleNavigation(raw_url, .{
                    .reason = .script,
                    .kind = .{ .push = null },
                }, .{ .script = existing });
            }
            if (no_opener) {
                return null;
            }
            return Access.init(frame.window, existing.window);
        }
    }

    // Spawn a new popup Frame as a sibling of the root.
    const popup = try frame.openPopup(.{
        .url = raw_url,
        .name = target,
        .opener = if (no_opener) null else self,
    });

    if (no_opener) {
        return null;
    }
    return Access.init(frame.window, popup.window);
}

pub fn close(self: *Window) void {
    if (self._closed) {
        return;
    }

    // Per spec, close() is only honored on script-opened windows. That
    // maps exactly to membership in page.popups.
    const frame = self._frame;
    const page = frame._page;

    var popup_index: usize = 0;
    while (popup_index < page.popups.items.len) : (popup_index += 1) {
        if (page.popups.items[popup_index] == frame) {
            break;
        }
    } else return;

    // Spec: closed is true immediately; discard (and opener=null) is a task.
    self._closed = true;
    // Clear browsing context name immediately so name targeting skips us.
    self._name = "";

    // Remove from name-targeting list immediately, but keep the Frame alive
    // until a deferred task clears opener refs and tears down.
    _ = page.popups.swapRemove(popup_index);

    // Drop any pending queued navigation for this frame.
    if (frame._queued_navigation != null) {
        for (page.queued_navigation.items, 0..) |f, i| {
            if (f == frame) {
                _ = page.queued_navigation.swapRemove(i);
                break;
            }
        }
    }

    frame.js.scheduler.reset();

    // Fire pagehide/unload-ish path via deferred close: opener stays until
    // after pagehide so WPT close-method can observe opener===self on pagehide.
    page.queued_close.append(page.frame_arena, frame) catch |err| {
        log.err(.frame, "queue popup close", .{ .err = err });
        // Fallback: clear openers now so we don't leak.
        clearOpenerRefs(self, page);
        return;
    };

    // Schedule a macrotask to clear opener and deinit (spec "queue a task to discard").
    const ClearOpener = struct {
        window: *Window,
        frame: *Frame,
        fn run(ctx: *anyopaque) !?u32 {
            const self_cb: *@This() = @ptrCast(@alignCast(ctx));
            const w = self_cb.window;
            const page2 = self_cb.frame._page;
            // pagehide already observed closed===true; now drop opener.
            clearOpenerRefs(w, page2);
            // Actual deinit stays in Page.cleanupClosedPopups / deinit.
            return null;
        }
    };
    const cb = page.frame_arena.create(ClearOpener) catch {
        clearOpenerRefs(self, page);
        return;
    };
    cb.* = .{ .window = self, .frame = frame };
    // Prefer opener's scheduler if available so task runs in parent turn.
    const sched_frame = if (self._opener) |op| op._frame else &page.frame;
    sched_frame.js.scheduler.add(cb, ClearOpener.run, 0, .{
        .name = "Window.close.discard",
        .low_priority = false,
    }) catch {
        clearOpenerRefs(self, page);
    };
}

fn clearOpenerRefs(closed_window: *Window, page: *@import("../browser/Page.zig")) void {
    for (page.popups.items) |popup| {
        if (popup.window._opener == closed_window) {
            popup.window._opener = null;
        }
    }
    if (page.frame.window._opener == closed_window) {
        page.frame.window._opener = null;
    }
    // Also clear reverse: anyone still listing us.
    closed_window._opener = null;
}

pub fn postMessage(self: *Window, message: js.Value, target_origin: ?[]const u8, transfer: ?[]js.Value, _: *Frame) !void {
    // For now, we ignore targetOrigin checking and just dispatch the message
    // In a full implementation, we would validate the origin
    _ = target_origin;

    const target_frame = self._frame;
    // MessageEvent.source/origin describe the incumbent settings object, not
    // the WindowProxy method receiver. V8's entered/current context is the
    // receiver's relevant realm for a cross-realm platform object; its
    // incumbent context preserves the actual script caller.
    const source_frame = target_frame.js.getIncumbent();
    const source_window = source_frame.window;
    const arena = try target_frame.getArena(.medium, "Window.postMessage");
    errdefer target_frame.releaseArena(arena);

    const transferred_ports = if (transfer) |list|
        try MessagePort.processTransferList(list, &source_frame.js.execution, &target_frame.js.execution, arena)
    else
        &[_]*MessagePort{};

    // Clone from the sender realm into the target realm.
    const cloned_message = blk: {
        var target_owned: js.Local.Scope = undefined;
        target_frame.js.localScope(&target_owned);
        defer target_owned.deinit();

        const cloned = try message.structuredCloneTo(&target_owned.local, null);
        break :blk try cloned.temp();
    };
    errdefer cloned_message.release();

    // Serialize the caller's effective security origin. Do not derive this
    // from Location: about:blank/about:srcdoc retain those URLs while
    // inheriting their creator's origin, and sandboxed opaque origins serialize
    // as "null".
    const origin = source_frame.origin orelse "null";
    const callback = try arena.create(PostMessageCallback);
    callback.* = .{
        .arena = arena,
        .message = cloned_message,
        .ports = transferred_ports,
        .frame = target_frame,
        .source = source_window,
        .origin = try arena.dupe(u8, origin),
    };

    // HTML queues every Window.postMessage delivery on the target browsing
    // context's posted-message task source. Never enter another realm directly
    // from the sender's stack, including parent/child and transferable cases.
    // If the target has not installed a listener when the task runs, `run`
    // transfers ownership to the Window pending queue; listener registration
    // schedules it again rather than dispatching reentrantly.
    try schedulePostMessageDelivery(target_frame, callback);
}

fn schedulePostMessageDelivery(target_frame: *Frame, callback: *PostMessageCallback) !void {
    try target_frame.js.scheduler.add(callback, PostMessageCallback.run, 0, .{
        .name = "postMessage",
        .low_priority = false,
        .finalizer = PostMessageCallback.cancelled,
    });

    target_frame.scheduleDeferredMacrotaskPump(0) catch |err| {
        log.warn(.browser, "postMessage pump", .{ .err = err });
    };
}

pub fn btoa(_: *const Window, input: js.String.OneByte, frame: *Frame) ![]const u8 {
    return @import("encoding/base64.zig").encode(frame.call_arena, input.bytes);
}

pub fn atob(_: *const Window, input: js.String.OneByte, frame: *Frame) !js.String.OneByte {
    const bytes = try @import("encoding/base64.zig").decode(frame.call_arena, input.bytes);
    return .{ .bytes = bytes };
}

pub fn structuredClone(_: *const Window, value: js.Value) !js.Value {
    return value.structuredClone();
}

pub fn getFrame(self: *Window, idx: usize) !?*Window {
    const frame = self._frame;
    const frames = frame.child_frames.items;
    if (idx >= frames.len) {
        return null;
    }

    if (frame.child_frames_sorted == false) {
        std.mem.sort(*Frame, frames, {}, struct {
            fn lessThan(_: void, a: *Frame, b: *Frame) bool {
                const iframe_a = a.iframe orelse return false;
                const iframe_b = b.iframe orelse return true;

                const pos = iframe_a.asNode().compareDocumentPosition(iframe_b.asNode());
                // Return true if a precedes b (a should come before b in sorted order)
                return (pos & 0x04) != 0; // FOLLOWING bit: b follows a
            }
        }.lessThan);
        frame.child_frames_sorted = true;
    }
    return frames[idx].window;
}

pub fn getFramesLength(self: *const Window) u32 {
    return @intCast(self._frame.child_frames.items.len);
}

pub fn getScrollX(self: *const Window) u32 {
    return self._scroll_pos.x;
}

pub fn getScrollY(self: *const Window) u32 {
    return self._scroll_pos.y;
}

const ScrollToOpts = union(enum) {
    x: i32,
    opts: Opts,

    const Opts = struct {
        top: i32,
        left: i32,
        behavior: []const u8 = "",
    };
};
pub fn scrollTo(self: *Window, opts: ScrollToOpts, y: ?i32, frame: *Frame) !void {
    switch (opts) {
        .x => |x| {
            self._scroll_pos.x = @intCast(@max(x, 0));
            self._scroll_pos.y = @intCast(@max(0, y orelse 0));
        },
        .opts => |o| {
            self._scroll_pos.x = @intCast(@max(0, o.left));
            self._scroll_pos.y = @intCast(@max(0, o.top));
        },
    }

    self._scroll_pos.state = .scroll;

    // Scrolling changes every viewport-relative client rect.  Queue the same
    // coalesced IntersectionObserver checkpoint used by DOM mutations before
    // delivering the asynchronous scroll event.
    frame.scheduleIntersectionChecks();

    // We dispatch scroll event asynchronously after 10ms. So we can throttle
    // them.
    try frame.js.scheduler.add(
        frame,
        struct {
            fn dispatch(_frame: *anyopaque) anyerror!?u32 {
                const f: *Frame = @ptrCast(@alignCast(_frame));
                const pos = &f.window._scroll_pos;
                // If the state isn't scroll, we can ignore safely to throttle
                // the events.
                if (pos.state != .scroll) {
                    return null;
                }

                const event = try Event.initTrusted(comptime .wrap("scroll"), .{ .bubbles = true }, f._page);
                try f._event_manager.dispatch(f.document.asEventTarget(), event);
                pos.state = .end;

                return null;
            }
        }.dispatch,
        10,
        .{ .low_priority = true },
    );
    // We dispatch scrollend event asynchronously after 20ms.
    try frame.js.scheduler.add(
        frame,
        struct {
            fn dispatch(_frame: *anyopaque) anyerror!?u32 {
                const f: *Frame = @ptrCast(@alignCast(_frame));
                const pos = &f.window._scroll_pos;
                // Dispatch only if the state is .end.
                // If a scroll is pending, retry in 10ms.
                // If the state is .end, the event has been dispatched, so
                // ignore safely.
                switch (pos.state) {
                    .scroll => return 10,
                    .end => {},
                    .done => return null,
                }
                const event = try Event.initTrusted(comptime .wrap("scrollend"), .{ .bubbles = true }, f._page);
                try f._event_manager.dispatch(f.document.asEventTarget(), event);
                pos.state = .done;

                return null;
            }
        }.dispatch,
        20,
        .{ .low_priority = true },
    );
}

pub fn scrollBy(self: *Window, opts: ScrollToOpts, y: ?i32, frame: *Frame) !void {
    // The scroll is relative to the current position. So compute to new
    // absolute position.
    var absx: i32 = undefined;
    var absy: i32 = undefined;
    switch (opts) {
        .x => |x| {
            absx = @as(i32, @intCast(self._scroll_pos.x)) + x;
            absy = @as(i32, @intCast(self._scroll_pos.y)) + (y orelse 0);
        },
        .opts => |o| {
            absx = @as(i32, @intCast(self._scroll_pos.x)) + o.left;
            absy = @as(i32, @intCast(self._scroll_pos.y)) + o.top;
        },
    }
    return self.scrollTo(.{ .x = absx }, absy, frame);
}

// only exposed when the binary is built with the -Dwpt_extensions flag
pub fn getWebDriver(_: *const Window) @import("WebDriver.zig") {
    return .{};
}

pub fn notifyPromiseRejection(self: *Window, no_handler: bool, promise: js.Promise, reason: ?js.Value, frame: *Frame) !void {
    if (comptime IS_DEBUG) {
        log.debug(.js, "unhandled rejection", .{
            .target = "window",
            .value = reason,
            .stack = promise.local.stackTrace() catch |err| @errorName(err) orelse "???",
        });
    } else {
        log.warn(.js, "unhandled rejection", .{
            .target = "window",
            .value = reason,
        });
    }

    if (no_handler) {
        const message = if (reason) |value| value.toStringSlice() catch "Unhandled promise rejection" else "Unhandled promise rejection";
        const stack = promise.local.stackTrace() catch null;
        frame._page.session.browser.observeJavaScriptError("unhandled-rejection", message, frame.url, 0, 0, frame._frame_id, frame._loader_id, stack);
    }

    const event_name, const attribute_callback = blk: {
        if (no_handler) {
            break :blk .{ "unhandledrejection", self._on_unhandled_rejection };
        }
        break :blk .{ "rejectionhandled", self._on_rejection_handled };
    };

    const target = self.asEventTarget();
    if (frame._event_manager.hasDirectListeners(target, event_name, attribute_callback)) {
        const event = (try @import("event/PromiseRejectionEvent.zig").init(event_name, .{
            .reason = if (reason) |r| try r.temp() else null,
            .promise = try promise.temp(),
        }, frame._page)).asEvent();
        // Ignore any errors from dispatching the event to avoid crashing
        frame._event_manager.dispatchDirect(target, event, attribute_callback, .{ .context = "window.unhandledrejection" }) catch |err| {
            log.warn(.js, "failed to dispatch unhandledrejection event", .{ .err = err });
        };
    }
}

pub const Access = union(enum) {
    window: *Window,
    cross_origin: *CrossOriginWindow,

    pub fn init(callee: *Window, accessing: *Window) Access {
        if (callee == accessing) {
            // common enough that it's worth the check
            return .{ .window = accessing };
        }

        // Origin* pointer equality: same tuple origin (including shared
        // about:blank inheritance). Opaque origins are unique *Origin each
        // so they never match (about:srcdoc network-error, sandbox).
        if (callee._frame.js.origin == accessing._frame.js.origin) {
            return .{ .window = accessing };
        }

        return .{ .cross_origin = &accessing._cross_origin_wrapper };
    }
};

const PostMessageCallback = struct {
    frame: *Frame,
    source: *Window,
    arena: Allocator,
    origin: []const u8,
    message: js.Value.Temp,
    ports: []const *MessagePort,

    fn deinit(self: *PostMessageCallback) void {
        self.frame.releaseArena(self.arena);
    }

    fn cancelled(ctx: *anyopaque) void {
        const self: *PostMessageCallback = @ptrCast(@alignCast(ctx));
        self.message.release();
        self.deinit();
    }

    fn dispatch(self: *PostMessageCallback) !void {
        const frame = self.frame;
        const window = frame.window;
        const event_target = window.asEventTarget();

        var owned_scope: js.Local.Scope = undefined;
        const local: *const js.Local = if (frame.js.local) |active| active else blk: {
            frame.js.localScope(&owned_scope);
            break :blk &owned_scope.local;
        };
        defer if (frame.js.local == null) owned_scope.deinit();
        const source_value = try (try local.zigValueToJs(
            Window.Access.init(window, self.source),
            .{},
        )).temp();
        errdefer source_value.release();

        const event = (try MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = .{ .value = self.message },
            .origin = self.origin,
            .source = self.source,
            .source_context = window,
            .source_value = source_value,
            .ports = self.ports,
            .bubbles = false,
            .cancelable = false,
        }, frame._page)).asEvent();
        try frame._event_manager.dispatchDirect(event_target, event, window._on_message, .{ .context = "window.postMessage" });
        try frame.scheduleDeferredMacrotaskPump(0);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *PostMessageCallback = @ptrCast(@alignCast(ctx));

        const frame = self.frame;
        if (!frame.realmSchedulingActive()) {
            try frame.js.scheduler.add(self, PostMessageCallback.run, 0, .{
                .name = "window.postMessage.defer",
                .low_priority = false,
                .finalizer = PostMessageCallback.cancelled,
            });
            return null;
        }
        const window = frame.window;
        const event_target = window.asEventTarget();
        const has_listeners = frame._event_manager.hasDirectListeners(event_target, "message", window._on_message);
        if (!has_listeners) {
            window.queuePendingPostMessage(self) catch |err| {
                log.warn(.browser, "queue pending postMessage", .{ .err = err });
                self.message.release();
                self.deinit();
            };
            return null;
        }

        defer self.deinit();
        self.dispatch() catch |err| {
            log.warn(.browser, "postMessage dispatch", .{ .err = err });
            self.message.release();
        };

        return null;
    }
};

const FunctionSetter = union(enum) {
    func: js.Function.Global,
    anything: js.Value,
};

// window.onload = {}; doesn't fail, but it doesn't do anything.
// seems like setting to null is ok (though, at least on Firefix, it preserves
// the original value, which we could do, but why?)
fn getFunctionFromSetter(setter_: ?FunctionSetter) ?js.Function.Global {
    const setter = setter_ orelse return null;
    return switch (setter) {
        .func => |func| func, // Already a Global from bridge auto-conversion
        .anything => null,
    };
}

// Checks whether a window.open features string contains a token, matched
// case-insensitively on whole-token boundaries (comma or whitespace separated).
// The features syntax is legacy and loose; the only tokens we interpret are
// noopener and noreferrer.
fn hasFeatureToken(features: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, features, " \t\r\n,");
    while (it.next()) |raw| {
        // Trim a trailing =value if present — we only need the key.
        const key = if (std.mem.indexOfScalarPos(u8, raw, 0, '=')) |eq| raw[0..eq] else raw;
        if (std.ascii.eqlIgnoreCase(key, token)) return true;
    }
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Window);

    pub const Meta = struct {
        pub const name = "Window";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const document = bridge.accessor(Window.getDocument, null, .{ .cache = .{ .internal = 1 }, .deletable = false });
    pub const console = bridge.accessor(Window.getConsole, null, .{ .cache = .{ .internal = 2 } });

    pub const top = bridge.accessor(Window.getTop, null, .{});
    pub const self = bridge.accessor(Window.getWindow, null, .{});
    pub const window = bridge.accessor(Window.getWindow, null, .{});
    pub const parent = bridge.accessor(Window.getParent, null, .{});
    pub const navigator = bridge.accessor(Window.getNavigator, null, .{});
    pub const screen = bridge.accessor(Window.getScreen, null, .{});
    pub const visualViewport = bridge.accessor(Window.getVisualViewport, null, .{});
    pub const performance = bridge.accessor(Window.getPerformance, null, .{});
    pub const localStorage = bridge.accessor(Window.getLocalStorage, null, .{});
    pub const sessionStorage = bridge.accessor(Window.getSessionStorage, null, .{});
    pub const origin = bridge.accessor(Window.getOrigin, null, .{});
    pub const location = bridge.accessor(Window.getLocation, Window.setLocation, .{ .deletable = false });
    pub const chrome = bridge.accessor(Window.getChrome, null, .{ .null_as_undefined = true });
    pub const external = bridge.accessor(Window.getExternal, null, .{});
    pub const history = bridge.accessor(Window.getHistory, null, .{});
    pub const navigation = bridge.accessor(Window.getNavigation, null, .{});
    pub const crypto = bridge.accessor(Window.getCrypto, null, .{});
    pub const CSS = bridge.accessor(Window.getCSS, null, .{});
    pub const customElements = bridge.accessor(Window.getCustomElements, null, .{});
    pub const indexedDB = bridge.accessor(Window.getIndexedDB, null, .{});
    pub const caches = bridge.accessor(Window.getCaches, null, .{});
    pub const speechSynthesis = bridge.accessor(Window.getSpeechSynthesis, null, .{});
    pub const trustedTypes = bridge.accessor(Window.getTrustedTypes, null, .{});
    pub const cookieStore = bridge.accessor(Window.getCookieStore, null, .{});
    pub const scheduler = bridge.accessor(Window.getTaskScheduler, null, .{});
    pub const onload = bridge.accessor(Window.getOnLoad, Window.setOnLoad, .{});
    pub const onpageshow = bridge.accessor(Window.getOnPageShow, Window.setOnPageShow, .{});
    pub const onpopstate = bridge.accessor(Window.getOnPopState, Window.setOnPopState, .{});
    pub const onhashchange = bridge.accessor(Window.getOnHashChange, Window.setOnHashChange, .{});
    pub const modelContext = bridge.accessor(Window.getModelContext, null, .{});
    pub const frameElement = bridge.accessor(Window.getFrameElement, null, .{});
    pub const onerror = bridge.accessor(Window.getOnError, Window.setOnError, .{});
    pub const onmessage = bridge.accessor(Window.getOnMessage, Window.setOnMessage, .{});
    // Desktop Chrome omits Window ontouch* handlers (`'ontouchstart' in window` → false).
    // Touch profiles reinstall them via WindowKeysIntelligent (on* → null data props)
    // when listed in profile window_keys. Always exposing them breaks FPJS touchSupport
    // consistency with maxTouchPoints === 0.
    pub const onrejectionhandled = bridge.accessor(Window.getOnRejectionHandled, Window.setOnRejectionHandled, .{});
    pub const onunhandledrejection = bridge.accessor(Window.getOnUnhandledRejection, Window.setOnUnhandledRejection, .{});
    pub const event = bridge.accessor(Window.getEvent, null, .{ .null_as_undefined = true });
    pub const fetch = bridge.function(Window.fetch, .{});
    pub const queueMicrotask = bridge.function(Window.queueMicrotask, .{});
    pub const setTimeout = bridge.function(Window.setTimeout, .{});
    pub const clearTimeout = bridge.function(Window.clearTimeout, .{});
    pub const setInterval = bridge.function(Window.setInterval, .{});
    pub const clearInterval = bridge.function(Window.clearInterval, .{});
    // `setImmediate` / `clearImmediate` are not Window APIs in web browsers.
    // Exposing the Node/legacy-Edge names changes feature detection and makes
    // browser libraries select a non-browser scheduling implementation.
    pub const requestAnimationFrame = bridge.function(Window.requestAnimationFrame, .{});
    pub const cancelAnimationFrame = bridge.function(Window.cancelAnimationFrame, .{});
    pub const requestIdleCallback = bridge.function(Window.requestIdleCallback, .{});
    pub const cancelIdleCallback = bridge.function(Window.cancelIdleCallback, .{});
    pub const matchMedia = bridge.function(Window.matchMedia, .{});
    pub const postMessage = bridge.function(Window.postMessage, .{});
    pub const btoa = bridge.function(Window.btoa, .{ .dom_exception = true });
    pub const atob = bridge.function(Window.atob, .{ .dom_exception = true });
    pub const reportError = bridge.function(Window.reportError, .{});
    pub const structuredClone = bridge.function(Window.structuredClone, .{ .dom_exception = true });
    pub const getComputedStyle = bridge.function(Window.getComputedStyle, .{});
    pub const getSelection = bridge.function(Window.getSelection, .{});

    pub const frames = bridge.accessor(Window.getWindow, null, .{});
    pub const index = bridge.indexed(Window.getFrame, null, .{ .null_as_undefined = true });
    pub const length = bridge.accessor(Window.getFramesLength, null, .{});
    pub const scrollX = bridge.accessor(Window.getScrollX, null, .{});
    pub const scrollY = bridge.accessor(Window.getScrollY, null, .{});
    pub const pageXOffset = bridge.accessor(Window.getScrollX, null, .{});
    pub const pageYOffset = bridge.accessor(Window.getScrollY, null, .{});
    pub const scrollTo = bridge.function(Window.scrollTo, .{});
    pub const scroll = bridge.function(Window.scrollTo, .{});
    pub const scrollBy = bridge.function(Window.scrollBy, .{});

    pub const isSecureContext = bridge.accessor(Window.getIsSecureContext, null, .{});
    pub const crossOriginIsolated = bridge.attribute(false, .{});

    pub fn getInnerWidth(_: *const Window, frame: *Frame) u32 {
        return frame.windowProfile().inner_width;
    }

    pub fn getInnerHeight(_: *const Window, frame: *Frame) u32 {
        return frame.windowProfile().inner_height;
    }

    pub fn getOuterWidth(_: *const Window, frame: *Frame) u32 {
        return frame.windowProfile().outer_width;
    }

    pub fn getOuterHeight(_: *const Window, frame: *Frame) u32 {
        return frame.windowProfile().outer_height;
    }

    pub fn getDevicePixelRatio(_: *const Window, frame: *Frame) f64 {
        return frame.devicePixelRatio();
    }

    pub const innerWidth = bridge.accessor(getInnerWidth, null, .{});
    pub const innerHeight = bridge.accessor(getInnerHeight, null, .{});
    pub const outerWidth = bridge.accessor(getOuterWidth, null, .{});
    pub const outerHeight = bridge.accessor(getOuterHeight, null, .{});
    pub const devicePixelRatio = bridge.accessor(getDevicePixelRatio, null, .{});

    pub const opener = bridge.accessor(Window.getOpener, null, .{});
    pub const closed = bridge.accessor(Window.getClosed, null, .{});
    pub const name = bridge.accessor(Window.getName, Window.setName, .{});
    pub const open = bridge.function(Window.open, .{});
    pub const close = bridge.function(Window.close, .{});

    pub const alert = bridge.function(struct {
        fn alert(_: *const Window, message: ?[]const u8, frame: *Frame) void {
            var response: Notification.DialogResponse = .{};
            frame._session.notification.dispatch(.javascript_dialog_opening, &.{
                .url = frame.url,
                .message = message orelse "",
                .dialog_type = "alert",
                .response = &response,
            });
            // Return value is void; we still pop a pre-armed response so the
            // CDP client's pre-arm doesn't leak across to the next dialog.
        }
    }.alert, .{});
    pub const confirm = bridge.function(struct {
        fn confirm(_: *const Window, message: ?[]const u8, frame: *Frame) bool {
            var response: Notification.DialogResponse = .{};
            frame._session.notification.dispatch(.javascript_dialog_opening, &.{
                .url = frame.url,
                .message = message orelse "",
                .dialog_type = "confirm",
                .response = &response,
            });
            return response.accept;
        }
    }.confirm, .{});
    pub const prompt = bridge.function(struct {
        fn prompt(_: *const Window, message: ?[]const u8, default_text: ?[]const u8, frame: *Frame) ?[]const u8 {
            var response: Notification.DialogResponse = .{};
            frame._session.notification.dispatch(.javascript_dialog_opening, &.{
                .url = frame.url,
                .message = message orelse "",
                .dialog_type = "prompt",
                .response = &response,
            });
            if (!response.accept) return null;
            // Pre-armed promptText wins when present. Otherwise fall back to
            // the dialog's defaultText (second arg to window.prompt) — Chrome's
            // accept-without-typing behavior. If both are absent, return ""
            // per CDP spec
            // (https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-handleJavaScriptDialog).
            return response.prompt_text orelse default_text orelse "";
        }
    }.prompt, .{});

    // WPT testdriver only. Production/antidetect snapshots omit this — BotD
    // flags `'webdriver' in window` as WebDriver automation (distinctiveProps).
    pub const webdriver = bridge.accessor(Window.getWebDriver, null, .{ .wpt_only = true });
};

const CrossOriginWindow = struct {
    window: *Window,

    pub fn postMessage(self: *CrossOriginWindow, message: js.Value, target_origin: ?[]const u8, transfer: ?[]js.Value, frame: *Frame) !void {
        return self.window.postMessage(message, target_origin, transfer, frame);
    }

    pub fn getTop(self: *CrossOriginWindow, frame: *Frame) Access {
        return self.window.getTop(frame);
    }

    pub fn getParent(self: *CrossOriginWindow, frame: *Frame) Access {
        return self.window.getParent(frame);
    }

    pub fn getFramesLength(self: *const CrossOriginWindow) u32 {
        return self.window.getFramesLength();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CrossOriginWindow);

        pub const Meta = struct {
            pub const name = "CrossOriginWindow";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const postMessage = bridge.function(CrossOriginWindow.postMessage, .{});
        pub const top = bridge.accessor(CrossOriginWindow.getTop, null, .{});
        pub const parent = bridge.accessor(CrossOriginWindow.getParent, null, .{});
        pub const length = bridge.accessor(CrossOriginWindow.getFramesLength, null, .{});
    };
};

const testing = @import("../../testing/testing.zig");
test "WebApi: Window" {
    try testing.htmlRunner("window", .{});
}

test "WebApi: Window scroll" {
    try testing.htmlRunner("window_scroll.html", .{});
}

test "WebApi: Window.onerror" {
    try testing.htmlRunner("event/report_error.html", .{});
}

test "WebApi: fingerprint surface invariants" {
    try testing.htmlRunner("fingerprint_surface.html", .{});
}
