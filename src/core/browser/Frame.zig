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

const JS = @import("../js/js.zig");
const Mime = @import("Mime.zig");
const Page = @import("Page.zig");
const Factory = @import("Factory.zig");
const Session = @import("Session.zig");
const EventManager = @import("EventManager.zig");
const ScriptManager = @import("ScriptManager.zig");
const StyleManager = @import("StyleManager.zig");

const Parser = @import("../parser/Parser.zig");
const h5e = @import("../parser/html5ever.zig");

const URL = @import("URL.zig");
const ContentSecurityPolicy = @import("ContentSecurityPolicy.zig");
const ReferrerPolicy = @import("ReferrerPolicy.zig");
const Blob = @import("../webapi/Blob.zig");
const Node = @import("../dom/Node.zig");
const DOMNodeIterator = @import("../dom/DOMNodeIterator.zig");
const Event = @import("../webapi/Event.zig");
const EventTarget = @import("../webapi/EventTarget.zig");
const CData = @import("../webapi/CData.zig");
const Element = @import("../dom/Element.zig");
const HtmlElement = @import("../webapi/element/Html.zig");
const Window = @import("../webapi/Window.zig");
const Location = @import("../webapi/Location.zig");
const Document = @import("../dom/Document.zig");
const ShadowRoot = @import("../webapi/ShadowRoot.zig");
const Performance = @import("../webapi/Performance.zig");
const Screen = @import("../webapi/Screen.zig");
const VisualViewport = @import("../webapi/VisualViewport.zig");
const PerformanceObserver = @import("../webapi/PerformanceObserver.zig");
const AbstractRange = @import("../webapi/AbstractRange.zig");
const MutationObserver = @import("../webapi/MutationObserver.zig");
const IntersectionObserver = @import("../webapi/IntersectionObserver.zig");
const Worker = @import("../webapi/Worker.zig");
const CustomElementDefinition = @import("../webapi/CustomElementDefinition.zig");
const PageTransitionEvent = @import("../webapi/event/PageTransitionEvent.zig");
const SubmitEvent = @import("../webapi/event/SubmitEvent.zig");
const NavigationKind = @import("../webapi/navigation/root.zig").NavigationKind;
const KeyboardEvent = @import("../webapi/event/KeyboardEvent.zig");
const MouseEvent = @import("../webapi/event/MouseEvent.zig");

const HttpClient = @import("HttpClient.zig");
const http = @import("../../runtime/network/http.zig");
const Config = @import("../../runtime/Config.zig");
const build_config = @import("build_config");
const FingerprintProfile = @import("../profile/types.zig");
const HttpProfile = @import("../../runtime/profile/HttpProfile.zig");
const ProfileStore = @import("../../runtime/profile/ProfileStore.zig");
const NavigatorState = @import("../webapi/NavigatorState.zig");

const timestamp = @import("../../support/datetime.zig").timestamp;
const milliTimestamp = @import("../../support/datetime.zig").milliTimestamp;
const nanoTimestamp = @import("../../support/datetime.zig").nanoTimestamp;

const WebApiURL = @import("../webapi/URL.zig");
const GlobalEventHandlersLookup = @import("../webapi/global_event_handlers.zig").Lookup;

const log = @import("../../support/log.zig");
const RealmLifecycleKernel = @import("../../runtime/RealmLifecycleKernel.zig");
const String = @import("../../support/string.zig").String;
const IFrame = Element.Html.IFrame;
const IFrameSandbox = @import("IFrameSandbox.zig");
const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;

fn assert(ok: bool, comptime msg: []const u8, args: anytype) void {
    if (ok) return;
    log.err(.app, msg, args);
    std.debug.assert(ok);
}

pub fn historyStore(self: *Frame) *@import("../webapi/History.zig") {
    if (self.parent == null) return &self._session.history;
    return &self.window._child_history;
}

/// Resource policy is browser-wide configuration, but resource admission is
/// owned by the frame that creates the DOM request. Keeping these helpers on
/// Frame avoids URL/site-specific filtering and lets image lifecycle code
/// coordinate defer-images with the document's load milestone.
pub fn resourcePolicy(self: *const Frame) Config.ResourcePolicy {
    return self._session.browser.app.config.resourcePolicy();
}

pub fn shouldLoadImages(self: *const Frame) bool {
    return self.resourcePolicy().allowsImages();
}

pub fn shouldDeferImages(self: *const Frame) bool {
    return self.resourcePolicy().defersImages();
}

pub fn shouldLoadExternalStylesheets(self: *const Frame) bool {
    return self.resourcePolicy().allowsExternalStylesheets();
}

pub fn navigationStore(self: *Frame) *@import("../webapi/navigation/Navigation.zig") {
    if (self.parent == null) return &self._session.navigation;
    return &self.window._child_navigation;
}

var default_url = WebApiURL{ ._raw = "about:blank" };
pub var default_location: Location = Location{ ._url = &default_url };

pub const BUF_SIZE = 1024;

const Frame = @This();

const QueuedElementLoad = struct {
    element: *Element.Html,
    task_owner: RealmLifecycleKernel.TaskOwner,
};

pub const InputHit = struct {
    element: *Element,
    frame: *Frame,
    client_x: f64,
    client_y: f64,
};

// This is the "id" of the frame. It can be re-used from frame-to-frame, e.g.
// when navigating.
_frame_id: u32,

// This is the "id" of this specific instance of the frame. It changes on every
// navigate.
_loader_id: u32,

/// Navigation generation for this frame's realm. Incremented at the start of
/// each `navigate()`; macrotasks capture it and drop if stale.
_realm_epoch: RealmLifecycleKernel.Epoch = 0,
_realm_state: RealmLifecycleKernel.State = .initializing,
_realm_has_window: bool = false,
_realm_has_js: bool = false,
/// True after `deinit` finishes teardown. Guards deferred iframe deinit +
/// recursive parent deinit from double-freeing ScriptManager hash maps
/// (`incorrect alignment` in clearImportedModules).
_deinit_done: bool = false,
/// Set to true when runaway microtask execution is detected (circuit breaker).
/// Once suppressed, the scheduler will reject further microtask checkpoints.
_scheduler_suppressed: bool = false,
/// Coalesce deferred frame_navigated notifications scheduled from HTTP callbacks.
_deferred_frame_navigated_scheduled: bool = false,
/// CDP Page.navigate ack is sent at header time; observer work runs after body.
_pending_frame_navigated_observers: bool = false,
/// Runtime.executionContextCreated already sent for this navigation (pending-
/// root commit publishes at frame_created; frameNavigated must not duplicate).
_inspector_context_published: bool = false,

_page: *Page,

_session: *Session,

_event_manager: EventManager,

_parse_mode: enum { document, fragment, document_write } = .document,

// See Attribute.List for what this is. TL;DR: proper DOM Attribute Nodes are
// fat yet rarely needed. We only create them on-demand, but still need proper
// identity (a given attribute should return the same *Attribute), so we do
// a look here. We don't store this in the Element or Attribute.List.Entry
// because that would require additional space per element / Attribute.List.Entry
// even though we'll create very few (if any) actual *Attributes.
_attribute_lookup: std.AutoHashMapUnmanaged(usize, *Element.Attribute) = .empty,

// Same as _atlribute_lookup, but instead of individual attributes, this is for
// the return of elements.attributes.
_attribute_named_node_map_lookup: std.AutoHashMapUnmanaged(usize, *Element.Attribute.NamedNodeMap) = .empty,

// Lazily-created style, classList, and dataset objects. Only stored for elements
// that actually access these features via JavaScript, saving 24 bytes per element.
_element_styles: Element.StyleLookup = .empty,
_element_datasets: Element.DatasetLookup = .empty,
_element_class_lists: Element.ClassListLookup = .empty,
_element_rel_lists: Element.RelListLookup = .empty,
_element_sandbox_lists: Element.SandboxListLookup = .empty,
_element_html_for_lists: Element.HtmlForListLookup = .empty,
_element_sizes_lists: Element.SizesListLookup = .empty,
_element_shadow_roots: Element.ShadowRootLookup = .empty,
_node_owner_documents: Node.OwnerDocumentLookup = .empty,
_element_assigned_slots: Element.AssignedSlotLookup = .empty,
_manual_slot_assignments: std.AutoHashMapUnmanaged(*Element.Html.Slot, []const *Node) = .{},
_element_scroll_positions: Element.ScrollPositionLookup = .empty,
_element_namespace_uris: Element.NamespaceUriLookup = .empty,
_attr_associated_elements: @import("../dom/AttrAssociatedElement.zig").Lookup = .empty,

/// Lazily-created inline event listeners (or listeners provided as attributes).
/// Avoids bloating all elements with extra function fields for rare usage.
///
/// Use this when a listener provided like this:
///
/// ```js
/// img.onload = () => { ... };
/// ```
///
/// Its also used as cache for such cases after lazy evaluation:
///
/// ```html
/// <img onload="(() => { ... })()" />
/// ```
///
/// ```js
/// img.setAttribute("onload", "(() => { ... })()");
/// ```
_event_target_attr_listeners: GlobalEventHandlersLookup = .empty,

// Blob URL registry for URL.createObjectURL/revokeObjectURL
_blob_urls: std.StringHashMapUnmanaged(*Blob) = .{},

/// `load` events that'll be fired before window's `load` event.
/// A call to `documentIsComplete` (which calls `_documentIsComplete`) resets it.
/// Double-buffered so that dispatching load events (which may trigger JS that
/// creates new elements) doesn't invalidate the list while iterating.
_to_load_1: std.ArrayList(QueuedElementLoad) = .empty,
_to_load_2: std.ArrayList(QueuedElementLoad) = .empty,
_to_load: *std.ArrayList(QueuedElementLoad) = undefined,

// iframe `load` events deferred to the next macrotask so sibling inline

_iframe_load_1: std.ArrayList(*IFrame) = .empty,
_iframe_load_2: std.ArrayList(*IFrame) = .empty,
_iframe_load: *std.ArrayList(*IFrame) = undefined,
_iframe_load_scheduled: bool = false,

// about:blank iframe loads queued during appendChild; flushed before returning to JS.
_sync_iframe_pending_1: std.ArrayList(*IFrame) = .empty,
_sync_iframe_pending_2: std.ArrayList(*IFrame) = .empty,
_sync_iframe_pending: *std.ArrayList(*IFrame) = undefined,
_sync_iframe_flush_scheduled: bool = false,
/// HTML parse + static scripts deferred off the document HTTP done_callback (CDP poll).
_document_parse_scheduled: bool = false,
/// Images marked `loading="lazy"` are collected while the document is parsed.
/// Koko has no compositor viewport, so they are activated on a later scheduler
/// turn after the document's load event instead of being fetched eagerly.
_deferred_lazy_images: std.ArrayList(*Element.Html.Image) = .empty,
_lazy_images_activation_scheduled: bool = false,
/// True while `DeferDocumentParseCallback` is on the stack (html5ever walking DOM).
/// Parser callbacks re-check realm after CDP poll; this flag is for diagnostics
/// and for call sites that must not assume parse is idle.
_document_parse_active: bool = false,
/// Throttle inbound CDP socket polls during long sync parse / script eval.
_cdp_poll_counter: u16 = 0,
/// Heap capacity for text nodes grown by the HTML parser (`appendParserAdjacentText`).
/// Avoids O(n²) arena blow-up when html5ever emits large style/script bodies as
/// many small AppendText chunks (bitbucket.org ~591KB CSS → multi-GB RSS).
_parser_text_cap: std.AutoHashMapUnmanaged(*CData, usize) = .empty,

_style_manager: StyleManager,
_script_manager: ScriptManager,

// List of active live ranges (for mutation updates per DOM spec)
_live_ranges: std.DoublyLinkedList = .{},
/// NodeIterator instances owned by this browsing context. DOM pre-removing
/// steps retarget their reference before a subtree is detached.
_node_iterators: std.DoublyLinkedList = .{},

// List of active MutationObservers
_mutation_observers: std.DoublyLinkedList = .{},
_mutation_delivery_scheduled: bool = false,
_suppress_dom_mutation_microtasks: bool = false,
_mutation_delivery_depth: u32 = 0,

// List of active IntersectionObservers
_intersection_observers: std.ArrayList(*IntersectionObserver) = .empty,
_intersection_check_scheduled: bool = false,
_intersection_delivery_scheduled: bool = false,

// Slots that need slotchange events to be fired
_slots_pending_slotchange: std.AutoHashMapUnmanaged(*Element.Html.Slot, void) = .{},
_slotchange_delivery_scheduled: bool = false,

// CSS class-driven animations: headless has no compositor timeline, so we
// synthesize animationend/transitionend after class changes (Fluent SPA route
// transitions commit the next location only in onAnimationEnd).
_css_anim_pending: std.AutoHashMapUnmanaged(*Element, void) = .{},
_css_anim_delivery_scheduled: bool = false,
_css_anim_delivery_task_owner: RealmLifecycleKernel.TaskOwner = .{ .realm_id = 0, .epoch = 0, .document_id = null },

/// `TaskOwner` captured when each single-flight microtask was scheduled (epoch / realm legality).
_mutation_delivery_task_owner: RealmLifecycleKernel.TaskOwner = .{ .realm_id = 0, .epoch = 0, .document_id = null },
_intersection_check_task_owner: RealmLifecycleKernel.TaskOwner = .{ .realm_id = 0, .epoch = 0, .document_id = null },
_intersection_delivery_task_owner: RealmLifecycleKernel.TaskOwner = .{ .realm_id = 0, .epoch = 0, .document_id = null },
_slotchange_delivery_task_owner: RealmLifecycleKernel.TaskOwner = .{ .realm_id = 0, .epoch = 0, .document_id = null },
/// Captured at each `navigate()`; document HTTP terminal callbacks drop if stale.
_nav_task_owner: RealmLifecycleKernel.TaskOwner = .{ .realm_id = 0, .epoch = 0, .document_id = null },
/// List of active PerformanceObservers.
/// Contrary to MutationObserver and IntersectionObserver, these are regular tasks.
_performance_observers: std.ArrayList(*PerformanceObserver) = .empty,
_performance_delivery_scheduled: bool = false,

_speech_voices_ready: bool = false,
_speech_voices_load_scheduled: bool = false,
_speech_remote_load_scheduled: bool = false,
_speech_remote_ready: bool = false,
_speech_voices: []?*@import("../webapi/speech/SpeechSynthesis.zig").SpeechSynthesisVoice = &.{},

_offline_audio_pending: [8]?*anyopaque = .{null} ** 8,
_offline_audio_pending_len: u8 = 0,
_offline_audio_flush_queued: bool = false,

_trusted_types_mapping: ?JS.Value.Global = null,

/// Active RTCPeerConnection instances owned by this frame.
_rtc_peer_connections: std.ArrayList(*@import("../webapi/rtc_bindings.zig").RTCPeerConnectionJs) = .empty,

// Lookup for customized built-in elements. Maps element pointer to definition.
_customized_builtin_definitions: std.AutoHashMapUnmanaged(*Element, *CustomElementDefinition) = .{},
_customized_builtin_connected_callback_invoked: std.AutoHashMapUnmanaged(*Element, void) = .{},
_customized_builtin_disconnected_callback_invoked: std.AutoHashMapUnmanaged(*Element, void) = .{},

// This is set when an element is being upgraded (constructor is called).
// The constructor can access this to get the element being upgraded.
_upgrading_element: ?*Node = null,

// List of custom elements that were created before their definition was registered
_undefined_custom_elements: std.ArrayList(*Element.Html.Custom) = .empty,

// for heap allocations and managing WebAPI objects
_factory: *Factory,

_load_state: LoadState = .waiting,
_static_scripts_done_scheduled: bool = false,
/// Inline parse finished inside frameDoneCallback; lifecycle starts at leaveTransferCallback.
_pending_post_parse_lifecycle: bool = false,

_parse_state: ParseState = .pre,

_notified_network_idle: IdleNotification = .init,
_notified_network_almost_idle: IdleNotification = .init,

// A navigation event that happens from a script gets scheduled to run on the
// next tick.
_queued_navigation: ?*QueuedNavigation = null,

// The URL of the current frame
url: [:0]const u8 = "about:blank",

origin: ?[]const u8 = null,

// The base url specifies the base URL used to resolve the relative urls.
// It is set by a <base> tag.
// If null the url must be used.
base_url: ?[:0]const u8 = null,
/// Creator base URL captured when an inline document is created.
fallback_base_url: ?[:0]const u8 = null,

// referer header cache.
referer_header: ?[:0]const u8 = null,

content_security_policy: ?ContentSecurityPolicy.Policy = null,
referrer_policy: ReferrerPolicy.Policy = .@"strict-origin-when-cross-origin",

// Document charset (canonical name from encoding_rs, static lifetime)
charset: []const u8 = "UTF-8",

// Arbitrary buffer. Need to temporarily lowercase a value? Use this. No lifetime
// guarantee - it's valid until someone else uses it.
buf: [BUF_SIZE]u8 = undefined,

// access to the JavaScript engine
js: *JS.Context,

// An arena for the lifetime of the frame.
arena: Allocator,

// An arena with a lifetime guaranteed to be for 1 invoking of a Zig function
// from JS. Best arena to use, when possible.
call_arena: Allocator,

parent: ?*Frame,
window: *Window,
document: *Document,
iframe: ?*IFrame = null,

child_frames_sorted: bool = true,
child_frames: std.ArrayList(*Frame) = .empty,

// Workers created by this frame. Cleaned up when frame is destroyed.
workers: std.ArrayList(*Worker) = .empty,

// Press-half state for split CDP mouse press/release sequences.
_input_press_hit: ?InputHit = null,
_last_pointer_x: f64 = 120,
_last_pointer_y: f64 = 120,
_automation_scrubbed: bool = false,

// Coordinates for independently scheduled CDP mouse press/release halves.
// Press must dispatch immediately so a real hold duration exists before release.
_cdp_mouse_pending_x: f64 = 0,
_cdp_mouse_pending_y: f64 = 0,
_cdp_mouse_release_x: f64 = 0,
_cdp_mouse_release_y: f64 = 0,
/// Element pending Koko/MCP click — activation runs on next scheduler tick.
_koko_pending_activation: ?*Element = null,

// Cached hosting `<iframe>` client size for child-frame hit-test layout.
_hosting_iframe_layout_size: ?struct { width: f64, height: f64 } = null,

// Per-element layout dimensions cache (key = @intFromPtr(element)).
// Entries carry their DOM generation so invalidation never requires clearing
// the HashMap from parser/HTTP threads.
_element_layout_cache: std.AutoHashMapUnmanaged(usize, struct {
    width: f64,
    height: f64,
    version: usize,
}) = .empty,
_layout_cache_dom_version: usize = 0,

// Layout hot-path caches (visibility + document position). Invalidated via version on domChanged.
_layout_visibility_cache: StyleManager.VisibilityCache = .empty,
_layout_visibility_cache_version: usize = 0,
_layout_doc_position_cache: std.AutoHashMapUnmanaged(usize, f64) = .empty,
// Image preload responses are keyed by URL + request credentials mode. The
// eventual HTMLImageElement either subscribes to an in-flight preload or
// consumes its completed probe, matching the browser preload cache contract.
_image_preloads: std.StringHashMapUnmanaged(ImagePreloadEntry) = .empty,
// True while resolveElementDimensions is on the stack — enables stylesheet fast path.
_layout_resolve_depth: u32 = 0,
_layout_observation_start_ns: i128 = 0,

// DOM version used to invalidate cached state of "live" collections
version: usize = 0,

// This is maybe not great. It's a counter on the number of events that we're
// waiting on before triggering the "load" event. Essentially, we need all
// synchronous scripts and all iframes to be loaded. Scripts are handled by the
// ScriptManager, so all scripts just count as 1 pending load.
_pending_loads: u32,

_parent_notified: bool = false,
_detach_pending: bool = false,
/// True while firing unload/pagehide for this frame (or ancestors). Navigations
/// started from unload handlers must be ignored (HTML navigating-across-documents).
_unload_running: bool = false,

_type: enum { root, frame }, // only used for logs right now
_req_id: u32 = 0,
_navigated_options: ?NavigatedOpts = null,

pub fn init(self: *Frame, frame_id: u32, page: *Page, parent: ?*Frame) !void {
    if (comptime IS_DEBUG) {
        log.debug(.frame, "frame.init", .{});
    }

    const session = page.session;
    const call_arena = try session.getArena(.medium, "call_arena");
    errdefer session.releaseArena(call_arena);

    const factory = &page.factory;
    const document = (try factory.document(Node.Document.HTMLDocument{
        ._proto = undefined,
    })).asDocument();

    const arena = page.frame_arena;

    self.* = .{
        .js = undefined,
        .arena = arena,
        .parent = parent,
        .document = document,
        .window = undefined,
        .call_arena = call_arena,
        ._frame_id = frame_id,
        ._page = page,
        ._session = session,
        ._loader_id = session.nextLoaderId(),
        ._factory = factory,
        ._pending_loads = 1, // always 1 for the ScriptManager
        ._type = if (parent == null) .root else .frame,
        ._style_manager = undefined,
        ._script_manager = undefined,
        ._event_manager = EventManager.init(arena, self),
    };
    self._to_load = &self._to_load_1;
    self._iframe_load = &self._iframe_load_1;
    self._sync_iframe_pending = &self._sync_iframe_pending_1;

    var screen: *Screen = undefined;
    var visual_viewport: *VisualViewport = undefined;
    if (parent) |p| {
        screen = p.window._screen;
        visual_viewport = p.window._visual_viewport;
    } else {
        screen = try factory.eventTarget(Screen{
            ._proto = undefined,
            ._orientation = null,
        });
        visual_viewport = try factory.eventTarget(VisualViewport{
            ._proto = undefined,
        });
    }

    const cookie_store = try factory.eventTarget(@import("../webapi/cookie_store.zig").CookieStore{
        ._proto = undefined,
    });

    self.window = try factory.eventTarget(Window{
        ._frame = self,
        ._proto = undefined,
        ._document = self.document,
        ._location = &default_location,
        ._performance = Performance.init(),
        ._screen = screen,
        ._visual_viewport = visual_viewport,
        ._cookie_store = cookie_store,
        ._cross_origin_wrapper = undefined,
    });
    self.window._cross_origin_wrapper = .{ .window = self.window };
    if (parent != null) {
        self.window._child_history.onNewFrame(self);
        try self.window._child_navigation.onNewFrame(self);
        // Every newly-created nested browsing context starts with an initial
        // about:blank session-history entry. Parser scripts in srcdoc or a
        // fast response may synchronously call history.replaceState() before
        // the first navigation reaches frameDoneCallback.
        self.window._child_navigation._current_navigation_kind = .{ .push = null };
        try self.window._child_navigation.commitNavigation(self);
    }
    self._realm_has_window = true;

    self._style_manager = try StyleManager.init(self);
    errdefer self._style_manager.deinit();

    const browser = session.browser;
    self._script_manager = ScriptManager.init(browser.allocator, &browser.http_client, self);
    errdefer self._script_manager.deinit();

    self.js = try browser.env.createContext(self, .{
        .identity = &page.identity,
        .identity_arena = page.identity_arena,
        .call_arena = self.call_arena,
    });
    errdefer browser.env.destroyContext(self.js);
    self._realm_has_js = true;

    document._frame = self;
    self._realm_state = .active;

    if (comptime builtin.is_test == false) {
        if (parent == null) {
            // HTML test runner manually calls these as necessary
            try self.js.scheduler.add(session.browser, struct {
                fn runIdleTasks(ctx: *anyopaque) !?u32 {
                    const b: *@import("Browser.zig") = @ptrCast(@alignCast(ctx));
                    b.runIdleTasks();
                    return 200;
                }
            }.runIdleTasks, 200, .{ .name = "frame.runIdleTasks", .low_priority = true });
        }
    }
}

pub fn realmEpoch(self: *const Frame) RealmLifecycleKernel.Epoch {
    return self._realm_epoch;
}

pub fn realmSchedulingActive(self: *const Frame) bool {
    return self._realm_state == .active;
}

pub fn realmState(self: *const Frame) RealmLifecycleKernel.State {
    return self._realm_state;
}

pub fn realmParseComplete(self: *const Frame) bool {
    return self._parse_state == .complete;
}

pub fn realmReadyForExternalObservers(self: *const Frame) bool {
    return self._realm_state == .active and self._realm_has_js and self._realm_has_window and self.document._frame == self;
}

/// Public entry for iframe re-navigation (processFrameNavigation) so unload
/// handlers run with `_unload_running` and cannot schedule a competing nav.
pub fn fireUnloadForNavigation(self: *Frame) void {
    fireUnloadLifecycleEvents(self);
}

fn fireUnloadLifecycleEvents(child_frame: *Frame) void {
    for (child_frame.child_frames.items) |nested| {
        fireUnloadLifecycleEvents(nested);
    }

    child_frame._unload_running = true;
    defer child_frame._unload_running = false;

    const doc = child_frame.document;
    const doc_target = doc.asEventTarget();
    const window_target = child_frame.window.asEventTarget();

    doc.markVisibilityHidden();

    if (Event.initTrusted(String.wrap("visibilitychange"), .{ .bubbles = true }, child_frame._page)) |visibility_event| {
        child_frame._event_manager.dispatchDirect(doc_target, visibility_event, null, .{
            .context = "iframe visibilitychange",
            .skip_post_dispatch_microtasks = true,
        }) catch |err| {
            log.warn(.frame, "iframe visibilitychange", .{ .err = err });
        };
    } else |err| {
        log.warn(.frame, "iframe visibilitychange init", .{ .err = err });
    }

    if (child_frame._event_manager.hasDirectListeners(window_target, "pagehide", null)) {
        if (PageTransitionEvent.initTrusted(comptime .wrap("pagehide"), .{ .persisted = false }, child_frame)) |pagehide_event| {
            child_frame._event_manager.dispatchDirect(window_target, pagehide_event.asEvent(), null, .{
                .context = "iframe pagehide",
                .skip_post_dispatch_microtasks = true,
            }) catch |err| {
                log.warn(.frame, "iframe pagehide", .{ .err = err });
            };
        } else |err| {
            log.warn(.frame, "iframe pagehide init", .{ .err = err });
        }
    }

    if (child_frame._event_manager.hasDirectListeners(window_target, "unload", null)) {
        if (Event.initTrusted(comptime .wrap("unload"), .{}, child_frame._page)) |unload_event| {
            child_frame._event_manager.dispatchDirect(window_target, unload_event, null, .{
                .context = "iframe unload",
                .skip_post_dispatch_microtasks = true,
            }) catch |err| {
                log.warn(.frame, "iframe unload", .{ .err = err });
            };
        } else |err| {
            log.warn(.frame, "iframe unload init", .{ .err = err });
        }
    }
}

const DeferIframeChildDeinitCallback = struct {
    child_frame: *Frame,

    fn cancelled(ctx: *anyopaque) void {
        const self: *DeferIframeChildDeinitCallback = @ptrCast(@alignCast(ctx));
        // Scheduler cancellation is a terminal path (normally parent/Page
        // teardown). A queued navigation cannot still own this detached frame:
        // the page navigation queues are being discarded with the page.
        if (self.child_frame._deinit_done) return;
        if (!self.child_frame._detach_pending) return;
        self.child_frame.deinit();
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DeferIframeChildDeinitCallback = @ptrCast(@alignCast(ctx));
        if (self.child_frame._deinit_done) return null;
        if (!self.child_frame._detach_pending) return null;
        // Detachment cancels navigation of this browsing context. Frame.deinit
        // releases the QueuedNavigation arena; the page queue treats this
        // pointer as stale and skips it.
        self.child_frame.deinit();
        return null;
    }
};

fn deferIframeChildDeinit(parent: *Frame, child_frame: *Frame) !void {
    const callback = try parent.arena.create(DeferIframeChildDeinitCallback);
    callback.* = .{ .child_frame = child_frame };

    try parent.js.scheduler.add(callback, DeferIframeChildDeinitCallback.run, 0, .{
        .name = "Frame.deferIframeDeinit",
        .low_priority = false,
        .finalizer = DeferIframeChildDeinitCallback.cancelled,
    });
}

fn detachChildFrameForIframe(self: *Frame, iframe: *IFrame) void {
    const child = iframe._window orelse return;
    const child_frame = child._frame;
    const child_frame_id = child_frame._frame_id;

    iframe._window = null;
    child_frame._detach_pending = true;
    child_frame._parent_notified = true;
    // Detach Document↔Frame immediately (before deferred deinit). JS may still
    // hold the old Document and call document.open()/write()/close(); those
    // must not use a departing browsing context (UAF / incorrect alignment).
    child_frame.document._frame = null;
    self.removePendingIframeLoad(iframe);
    for (self.child_frames.items, 0..) |frame, i| {
        if (frame == child_frame) {
            self.child_frames_sorted = false;
            _ = self.child_frames.swapRemove(i);
            break;
        }
    }

    self._session.notification.dispatch(.frame_child_frame_removed, &.{
        .parent_id = self._frame_id,
        .frame_id = child_frame_id,
        .timestamp = timestamp(.monotonic),
    });

    fireUnloadLifecycleEvents(child_frame);
    deferIframeChildDeinit(self, child_frame) catch |err| {
        log.warn(.frame, "defer iframe deinit", .{ .err = err });
        child_frame.deinit();
    };
}

/// Returns true if the scheduler has been suppressed due to runaway microtask execution
/// or intentional teardown containment.
pub fn schedulerSuppressed(self: *const Frame) bool {
    return self._scheduler_suppressed;
}

/// Why the realm scheduler was suppressed. Teardown is expected lifecycle;
/// runaway is a circuit breaker after microtask budget exhaustion.
pub const SuppressReason = enum {
    /// Departing realm during re-nav / commit — expected, must not ERROR-spam.
    teardown,
    /// Microtask checkpoint exceeded hard budget — real fault signal.
    runaway,
};

/// Suppress microtask checkpoints for this realm.
/// - `.teardown`: silent/debug; used by Session before destroying a departing page.
/// - `.runaway`: ERROR log via `realm.scheduler_suppressed` (circuit breaker).
pub fn suppressScheduler(self: *Frame, reason: SuppressReason) void {
    if (self._scheduler_suppressed) return;
    self._scheduler_suppressed = true;
    switch (reason) {
        .runaway => {
            RealmLifecycleKernel.traceSchedulerSuppressed(self._frame_id, self._realm_epoch, self._realm_state);
            RealmLifecycleKernel.trace(.scheduler_suppressed, self._frame_id, self._realm_epoch, null);
        },
        .teardown => {
            // Expected on every clean-slate / iframe re-nav. Do not use log.err —
            // hotmail/signup probes treated those lines as load failures.
            if (comptime IS_DEBUG) {
                log.debug(.frame, "realm.scheduler_suppressed.teardown", .{
                    .frame_id = self._frame_id,
                    .current_epoch = self._realm_epoch,
                    .realm_state = @tagName(self._realm_state),
                });
            }
            RealmLifecycleKernel.trace(.scheduler_suppressed, self._frame_id, self._realm_epoch, null);
        },
    }
}

pub fn clearSchedulerSuppression(self: *Frame) void {
    self._scheduler_suppressed = false;
}

/// Called at the start of every `navigate()` (including about:blank / blob).
/// Macrotasks scheduled with a captured epoch older than the current value are dropped.
pub fn bumpRealmNavigationEpoch(self: *Frame) void {
    self._realm_epoch +%= 1;
    self._realm_state = .initializing;
    self._sync_iframe_flush_scheduled = false;
    self._document_parse_scheduled = false;
    self._deferred_lazy_images.clearRetainingCapacity();
    self._lazy_images_activation_scheduled = false;
    self._document_parse_active = false;
    self._cdp_poll_counter = 0;
    self._input_press_hit = null;
    // Capacities are only valid for the parse that created them.
    self._parser_text_cap = .empty;
    // New navigation installs a new execution world; suppression belongs to
    // the discarded realm and must not poison the replacement realm.
    self._scheduler_suppressed = false;
    RealmLifecycleKernel.trace(.nav_epoch_bump, self._frame_id, self._realm_epoch, null);
}

pub fn markRealmReadyForPublication(self: *Frame) void {
    self._realm_state = .active;
    // New document is live — never carry teardown/runaway suppression into
    // the published realm (Fluent SPA hydrate needs microtask checkpoints).
    self._scheduler_suppressed = false;
}

fn enterRealmDraining(self: *Frame) void {
    if (self._realm_state == .active) {
        self._realm_state = .draining;
        RealmLifecycleKernel.trace(.realm_draining, self._frame_id, null, null);
    }
}

/// Single cancel-on-nav entry for document-owned async work.
///
/// Call when this frame is departing (root re-nav abort, or frame teardown).
/// Network abort is the caller's job (`abortTransfersAttributedTo`) so pending
/// root document transfers can keep `protect_from_abort` / scope options.
///
/// Contract after return:
/// - realm is `.draining` (no new JS entry with `.strict_active`)
/// - scheduler queue is empty (deferred parse / script slices / timer pumps)
/// - streaming `document.write` parser is cancelled
/// - script manager rejects late HTTP script callbacks
pub fn prepareForOutgoingAbort(self: *Frame) void {
    self.enterRealmDraining();
    // Break Document → Frame before further teardown so retained JS Document
    // objects cannot open/write into this departing context.
    self.document._frame = null;
    self._script_manager.base.shutdown = true;
    self.document.cancelStreamingParser();
    self._document_parse_active = false;
    self._parser_text_cap = .empty;
    self._pending_post_parse_lifecycle = false;
    self._static_scripts_done_scheduled = false;
    // Drop deferred HTML parse / script-slice / timer pumps still on this
    // frame's scheduler. Otherwise DeferDocumentParseCallback can run after
    // the page arena is freed (tinhte re-nav → Frame.appendNew UAF 0xaaaa…).
    self.cancelOwnedSchedulerWork();
    self.closeRtcPeerConnections();
    self.disconnectAllIntersectionObservers();
    self._intersection_delivery_scheduled = false;
    self._intersection_check_scheduled = false;
}

/// True while this realm may run document-owned scheduler tasks / parser work.
pub fn canRunOwnedScheduler(self: *const Frame) bool {
    if (self._detach_pending) return false;
    if (self._realm_state != .active) return false;
    if (self.isGoingAway()) return false;
    return true;
}

/// Drop all tasks on this frame's scheduler (and clear deferred-parse bookkeeping).
pub fn cancelOwnedSchedulerWork(self: *Frame) void {
    self.js.scheduler.reset();
    self._document_parse_scheduled = false;
    // scheduler.reset() drops DeferEvaluateCallback without running it.
    self._script_manager.base.deferred_evaluate_queued = false;
}

/// Run at most one owned scheduler task if the realm is still active.
/// On draining/dead, cancels leftover work instead of leaving dangling callbacks.
pub fn runOwnedSchedulerOne(self: *Frame) !bool {
    if (!self.canRunOwnedScheduler()) {
        if (self._realm_state == .draining or self._realm_state == .dead) {
            self.cancelOwnedSchedulerWork();
        }
        return false;
    }
    const started = nanoTimestamp(.monotonic);
    const ran = try self.js.scheduler.runOne();
    if (ran) self.observeBrowserStage("event-loop", elapsedMicros(started), "measured", "Renderer", "Main");
    return ran;
}

/// Drain ready owned scheduler tasks while the realm stays active.
pub fn runOwnedScheduler(self: *Frame) !void {
    if (!self.canRunOwnedScheduler()) {
        if (self._realm_state == .draining or self._realm_state == .dead) {
            self.cancelOwnedSchedulerWork();
        }
        return;
    }
    try self.js.scheduler.run();
}

fn disconnectAllIntersectionObservers(self: *Frame) void {
    while (self._intersection_observers.items.len > 0) {
        const observer = self._intersection_observers.items[self._intersection_observers.items.len - 1];
        observer.disconnect(self);
    }
}

fn enterRealmDead(self: *Frame) void {
    if (self._realm_state != .dead) {
        self._realm_state = .dead;
        RealmLifecycleKernel.trace(.realm_dead, self._frame_id, self.realmEpoch(), null);
    }
}

/// Enter terminal browser shutdown without destroying storage yet. Network
/// callbacks may still run during the following transport abort, so every
/// realm must be visibly dead before any callback can attempt JS re-entry.
pub fn prepareForBrowserShutdown(self: *Frame) void {
    if (self._deinit_done) return;
    for (self.child_frames.items) |child| {
        child.prepareForBrowserShutdown();
    }
    self.suppressScheduler(.teardown);
    self.prepareForOutgoingAbort();
    self.enterRealmDead();
}

pub fn deinit(self: *Frame) void {
    // Deferred iframe deinit + recursive parent deinit + processFrameNavigation
    // can all target the same Frame*. Second pass must no-op (hash map UAF).
    if (self._deinit_done) return;
    self._deinit_done = true;

    // Worker callbacks are scheduled on this frame's realm.  They must be
    // cancelled before the frame/context is torn down; otherwise a worker
    // message can race deinit and dereference the stale frame from the
    // scheduler callback.
    self.terminateAllWorkers();

    for (self.child_frames.items) |frame| {
        frame.deinit();
    }

    self.enterRealmDraining();
    // The frame scheduler also owns MessagePort/SharedWorker delivery tasks.
    // Dedicated workers are removed above, but shared-worker callbacks are not
    // frame-owned objects and can otherwise run after this realm is destroyed.
    self.cancelOwnedSchedulerWork();
    // Idempotent if prepareForOutgoingAbort / detach already cleared it.
    self.document._frame = null;
    self.closeRtcPeerConnections();
    self.document.cancelStreamingParser();

    if (comptime IS_DEBUG) {
        log.debug(.frame, "frame.deinit", .{ .url = self.url, .type = self._type });

        // Uncomment if you want slab statistics to print.
        // const stats = self._factory._slab.getStats(self.arena) catch unreachable;
        // var buffer: [256]u8 = undefined;
        // var stream = std.fs.File.stderr().writer(&buffer).interface;
        // stats.print(&stream) catch unreachable;
    }

    self._parse_state.deinit(self);

    const page = self._page;

    // postMessage callbacks that arrived before listener registration are no
    // longer scheduler-owned. Window is their terminal owner.
    self.window.cancelPendingPostMessages();

    if (self._queued_navigation) |qn| {
        page.releaseArena(qn.arena);
        self._queued_navigation = null;
    }

    // Drain async DOM queues before releasing observer references; the
    // observer list may contain the final owning ref during frame teardown.
    self.clearRealmAsyncDomQueuesForTeardown();

    {
        // Release all objects we're referencing
        {
            var it = self._blob_urls.valueIterator();
            while (it.next()) |blob| {
                blob.*.releaseRef(page);
            }
        }

        {
            var node: ?*std.DoublyLinkedList.Node = self._mutation_observers.first;
            while (node) |n| {
                node = n.next; // capture before we potentially delete observer
                const observer: *MutationObserver = @fieldParentPtr("node", n);
                observer.releaseRef(page);
            }
        }

        // Detach the registry before releasing its owner references. A V8
        // finalizer may run synchronously from releaseRef; leaving the list
        // populated until after that callback would retain a stale observer
        // pointer for the next shutdown/navigation pass.
        const intersection_observers = self._intersection_observers.items;
        self._intersection_observers.clearRetainingCapacity();
        for (intersection_observers) |observer| {
            observer._registered_frame = null;
            observer.releaseRef(page);
        }

        var document = self.window._document;
        document._selection.releaseRef(page);

        if (document._fonts) |f| {
            f.releaseRef(page);
        }
    }

    // V8 weak callbacks are not guaranteed to run when a realm is torn down.
    // Live Range objects are additionally linked from the frame for DOM
    // mutation tracking, so release every remaining owner before destroying
    // the context. This gives their arena and intrusive-list node one
    // deterministic terminal path and prevents teardown ArenaPool leaks.
    while (self._live_ranges.first) |link| {
        const ar: *AbstractRange = @fieldParentPtr("_range_link", link);
        ar._rc.forceDeinit(ar, page);
    }

    const browser = page.session.browser;
    self.enterRealmDead();
    // Abort in-flight HTTP transfers for this frame BEFORE destroying the V8
    // context. Each transfer's shutdown_callback (Fetch.httpShutdownCallback,
    // Worker.httpErrorCallback, etc.) reaches into Execution / Context to do
    // cleanup (e.g. `response.deinit(self._exec.context.page)`); if the V8
    // context has already been destroyed, those derefs are UAF and segfault.
    //
    // This matters most when commitPendingPage tears down the old active Page
    // while the previous navigation's JS-initiated transfers (fetch, XHR,
    // dynamic script loads) are still in flight: they share `_frame_id` with
    // the pending page (Session reuses it across allocatePage), so the .normal
    // scope passed below still hits them. With this ordering, kill() fires
    // the shutdown callbacks against a live context, then we destroy.
    //
    // Pending root navigation transfers carry `protect_from_abort = true` and
    // are excluded by the .normal scope, so they continue uninterrupted.
    self._script_manager.base.shutdown = true;
    browser.http_client.abortTransfersAttributedTo(self, .{});
    // Drain mid-perform transfers so Noop callbacks finish before Script
    // arenas are released by script_manager.deinit (nytimes.com SPA teardown).
    if (!browser.http_client.performing) {
        _ = browser.http_client.tick(0) catch {};
    }

    browser.env.destroyContext(self.js);

    // Must be after context is destroyed. A finalizer can reach into the *Worker
    // (e.g. Worker.ReceiveMessageCallback) so the worker must still be valid.
    for (self.workers.items) |worker| {
        worker.deinit();
    }

    self._script_manager.deinit();
    self._style_manager.deinit();

    page.releaseArena(self.call_arena);
}

pub fn trackWorker(self: *Frame, worker: *Worker) !void {
    try self.workers.append(self.arena, worker);
}

pub fn removeWorker(self: *Frame, worker: *Worker) void {
    for (self.workers.items, 0..) |w, i| {
        if (w == worker) {
            _ = self.workers.swapRemove(i);
            break;
        }
    }
}

/// Tear down dedicated workers before a new document navigation. WPT worker
/// batches navigate the same frame between *.worker.html tests; leaving workers
/// alive leaks HTTP transfers and parent-scheduler callbacks into the next test.
pub fn terminateAllWorkers(self: *Frame) void {
    for (self.child_frames.items) |child| {
        child.terminateAllWorkers();
    }
    while (self.workers.items.len > 0) {
        self.workers.items[0].destroy();
    }
}

pub fn identityProfile(self: *const Frame) *const FingerprintProfile.IdentityProfile {
    return self._session.browser.app.config.profile.identityPtr();
}

pub fn windowProfile(self: *const Frame) FingerprintProfile.WindowProfile {
    const profile_window = self.identityProfile().window;
    if (self._session.emulation) |em| return em.windowProfile(profile_window);
    return profile_window;
}

pub fn devicePixelRatio(self: *const Frame) f64 {
    const profile_dpr = self.identityProfile().screen.device_pixel_ratio;
    if (self._session.emulation) |em| return em.devicePixelRatio(profile_dpr);
    return profile_dpr;
}

pub fn loadedProfile(self: *const Frame) *const ProfileStore.LoadedProfile {
    return &self._session.browser.app.config.profile;
}

pub fn navigatorState(self: *const Frame) NavigatorState {
    return .{
        .profile = self.identityProfile(),
        .emulation = self._session.emulation,
    };
}

pub fn base(self: *const Frame) [:0]const u8 {
    if (self.base_url) |url| return url;
    return self.fallbackBase();
}

fn fallbackBase(self: *const Frame) [:0]const u8 {
    if (self.fallback_base_url) |url| return url;

    // A srcdoc document has `about:srcdoc` as its document URL, but the HTML
    // standard gives it the embedding document's fallback base URL. Relative
    // scripts, styles, links and module specifiers must therefore resolve
    // against the parent document until a <base href> inside the srcdoc
    // establishes an explicit base URL.
    if (std.mem.eql(u8, self.url, "about:srcdoc")) {
        if (self.parent) |parent| return parent.base();
    }

    return self.url;
}

/// Recompute the document base URL after the first `<base href>` changes.
/// The base element's own URL is resolved against the document's fallback
/// base, never against the previous cached base URL.
pub fn refreshDocumentBase(self: *Frame) !void {
    self.base_url = null;
    const element = try self.document.querySelector(comptime .wrap("base[href]"), self) orelse return;
    const href = element.getAttributeSafe(comptime .wrap("href")) orelse return;
    self.base_url = try URL.resolve(self.arena, self.fallbackBase(), href, .{});
}

fn subtreeContainsHtmlBase(root: *Node) bool {
    if (root.is(Element.Html.Base) != null) return true;

    var walker = @import("../dom/TreeWalker.zig").Full.Elements.init(root, .{});
    while (walker.next()) |element| {
        if (element.is(Element.Html.Base) != null) return true;
    }
    return false;
}

fn refreshDocumentBaseAfterMutation(self: *Frame) void {
    self.refreshDocumentBase() catch |err| {
        log.err(.frame, "refreshDocumentBase", .{ .err = err, .type = self._type, .url = self.url });
    };
}

pub fn getTitle(self: *Frame) !?[]const u8 {
    return try self.window._document.getTitle(self);
}

pub const HeadersForRequestOpts = struct {
    request_url: ?[:0]const u8 = null,
    resource_type: HttpClient.RequestParams.ResourceType = .fetch,
    /// Explicit Referer URL (without the "Referer: " prefix). Used by navigate()
    /// where self.url may already point at the destination.
    referer: ?[]const u8 = null,
    referrer_policy: ?ReferrerPolicy.Policy = null,
    referrer_source_url: ?[]const u8 = null,
    /// Document origin before this navigation (for Sec-Fetch-Site). navigate()
    /// updates self.origin before headers are built. Only meaningful when
    /// `is_document_navigation` is true.
    prior_origin: ?[]const u8 = null,
    is_document_navigation: bool = false,
    /// Browsing-context destination for document Fetch Metadata.
    navigation_destination: HttpProfile.RequestContext.NavigationDestination = .top_level,
    /// Site policy may omit Sec-Fetch-User (e.g. in-session search redirects).
    omit_sec_fetch_user: bool = false,
    /// Site policy may rely on curl-impersonate default_headers only (cold first hop).
    curl_defaults_only: bool = false,
    /// Fetch spec: omit Origin on GET/HEAD (§2.3).
    include_origin_header: bool = true,
    /// Fetch Metadata mode selected by the Fetch/Request algorithm.
    fetch_mode: ?[]const u8 = null,
    /// Whether this request has effective cookie/storage credentials.
    storage_access_active: bool = true,
    /// Per-request arena for header strings (fetch redirect refresh; avoids frame/call_arena races).
    header_arena: ?Allocator = null,
};

pub const ImagePreloadResult = struct {
    ok: bool,
    probe: []const u8,
};

pub const ImagePreloadCallback = *const fn (ctx: *anyopaque, result: ImagePreloadResult) anyerror!void;

const ImagePreloadWaiter = struct {
    ctx: *anyopaque,
    callback: ImagePreloadCallback,
};

const ImagePreloadEntry = struct {
    state: enum { loading, complete } = .loading,
    result: ImagePreloadResult = .{ .ok = false, .probe = &.{} },
    waiters: std.ArrayListUnmanaged(ImagePreloadWaiter) = .empty,
};

pub const ImagePreloadUse = enum {
    none,
    waiting,
    delivered,
};

/// Preload reuse keys include the request's CORS credentials mode. Two
/// requests for the same URL are reusable only when their fetch parameters
/// match, just as an HTTP cache entry alone is insufficient for preload reuse.
pub fn imagePreloadKey(
    self: *Frame,
    allocator: Allocator,
    url: []const u8,
    cross_origin: ?[]const u8,
) ![:0]const u8 {
    _ = self;
    const mode = if (cross_origin) |value|
        if (std.ascii.eqlIgnoreCase(value, "use-credentials")) "cors-include" else "cors-same-origin"
    else
        "no-cors-include";
    return std.fmt.allocPrintSentinel(allocator, "{s}\n{s}", .{ url, mode }, 0);
}

/// Returns true only for the owner that must start the network request.
pub fn beginImagePreload(self: *Frame, key: []const u8) !bool {
    if (self._image_preloads.contains(key)) return false;
    const owned_key = try self.arena.dupe(u8, key);
    try self._image_preloads.put(self.arena, owned_key, .{});
    return true;
}

/// Subscribe an image consumer to an in-flight preload or synchronously
/// deliver an already completed preload response.
pub fn useImagePreload(
    self: *Frame,
    key: []const u8,
    ctx: *anyopaque,
    callback: ImagePreloadCallback,
) !ImagePreloadUse {
    const entry = self._image_preloads.getPtr(key) orelse return .none;
    switch (entry.state) {
        .loading => {
            try entry.waiters.append(self.arena, .{ .ctx = ctx, .callback = callback });
            return .waiting;
        },
        .complete => {
            try callback(ctx, entry.result);
            return .delivered;
        },
    }
}

/// Complete exactly one preload generation and notify all matching consumers.
pub fn completeImagePreload(self: *Frame, key: []const u8, ok: bool, probe: []const u8) !void {
    const entry = self._image_preloads.getPtr(key) orelse return;
    if (entry.state == .complete) return;

    if (!ok) {
        const removed = self._image_preloads.fetchRemove(key) orelse return;
        for (removed.value.waiters.items) |waiter| {
            waiter.callback(waiter.ctx, .{ .ok = false, .probe = &.{} }) catch |err| {
                log.warn(.browser, "image preload consumer", .{ .err = err });
            };
        }
        return;
    }

    entry.result = .{
        .ok = true,
        .probe = if (probe.len == 0) &.{} else try self.arena.dupe(u8, probe),
    };
    entry.state = .complete;

    const waiters = entry.waiters.items;
    entry.waiters = .empty;
    for (waiters) |waiter| {
        waiter.callback(waiter.ctx, entry.result) catch |err| {
            log.warn(.browser, "image preload consumer", .{ .err = err });
        };
    }
}

fn navigateReasonForProfile(reason: NavigateReason) @import("../../runtime/profile/ProfileRuntime.zig").Reason {
    return switch (reason) {
        .anchor => .anchor,
        .address_bar => .address_bar,
        .form => .form,
        .script => .script,
        .history => .history,
        .navigation => .navigation,
        .initialFrameNavigation => .initial_frame_navigation,
    };
}

fn refererHeaderForRequest(self: *Frame, opts: HeadersForRequestOpts) ![:0]const u8 {
    const alloc = opts.header_arena orelse self.arena;
    if (opts.referrer_source_url) |source_url| {
        const policy = opts.referrer_policy orelse self.referrer_policy;
        const request_url = opts.request_url orelse "";
        const referer = ReferrerPolicy.computeReferer(alloc, policy, source_url, request_url) catch null;
        if (referer == null or referer.?.len == 0) return "";
        return try std.mem.concatWithSentinel(alloc, u8, &.{ "Referer: ", referer.? }, 0);
    }
    if (opts.referer) |explicit| {
        if (explicit.len == 0) return "";
        const sanitized = ReferrerPolicy.sanitizeReferrerUrl(alloc, explicit) catch explicit;
        return try std.mem.concatWithSentinel(alloc, u8, &.{ "Referer: ", sanitized }, 0);
    }
    if (self.referer_header == null) {
        if (std.mem.startsWith(u8, self.url, "http") and
            (opts.request_url == null or !std.mem.eql(u8, self.url, opts.request_url.?)))
        {
            self.referer_header = try std.mem.concatWithSentinel(self.arena, u8, &.{ "Referer: ", self.url }, 0);
        } else {
            self.referer_header = "";
        }
    }
    return self.referer_header.?;
}

// Add common subresource/navigation headers (Referer, Origin, Sec-Fetch-*, client hints).
pub fn headersForRequest(self: *Frame, headers: *HttpClient.Headers, opts: HeadersForRequestOpts) !void {
    const identity = self._session.browser.app.config.profile.identityPtr();
    const http_client = &self._session.browser.http_client;
    const request_url = opts.request_url orelse return;
    const hdr_alloc = opts.header_arena orelse self.arena;

    const static = HttpProfile.StaticHeaders{
        .user_agent_header = http_client.getUserAgentHeader(),
        .sec_ch_ua_header = http_client.getSecChUaHeader(),
        .accept_language_header = http_client.getAcceptLanguageHeader(),
    };

    const origin = if (opts.resource_type != .document and opts.include_origin_header)
        try self.requestOrigin()
    else
        null;

    const ctx = HttpProfile.RequestContext{
        .request_url = request_url,
        .resource_type = opts.resource_type,
        .frame_origin = self.origin,
        .prior_origin = opts.prior_origin,
        .is_document_navigation = opts.is_document_navigation,
        .navigation_destination = opts.navigation_destination,
        .origin = origin,
        .fetch_mode = opts.fetch_mode,
        .storage_access_active = opts.storage_access_active,
    };

    if (comptime build_config.curl_impersonate) {
        if (opts.curl_defaults_only) {
            // Cold first hop: curl-impersonate default_headers carry TLS-aligned
            // Sec-Fetch/Accept/UA. Guest Chrome also sends Downlink/RTT/Priority,
            // high-entropy Sec-CH-UA, and x-browser on google.com (www.google.com.har).
            const profile = self.loadedProfile();
            const header_plan = self._session.browser.app.config.profile_runtime.headerPlan(request_url);
            if (!profile.isFirefox()) {
                const chrome_opts = HttpProfile.ChromeHeadersOpts{
                    .full_client_hints = true,
                    .brands = profile.persona.network.brands,
                    .color_scheme = profile.persona.network.prefers_color_scheme,
                };
                try HttpProfile.appendCurlImpersonateColdHopSupplements(
                    headers,
                    hdr_alloc,
                    identity,
                    &static,
                    ctx,
                    chrome_opts,
                    profile.mode == .antidetect,
                );
            }
            try self._session.browser.app.config.profile_runtime.appendHeaderPlugins(
                header_plan,
                headers,
                hdr_alloc,
                http_client.getUserAgent(),
                self._session.fingerprint_seed,
            );
            return;
        }
        const profile = self.loadedProfile();
        const header_plan = self._session.browser.app.config.profile_runtime.headerPlan(request_url);
        if (profile.isFirefox()) {
            try HttpProfile.appendFirefoxHeaders(headers, hdr_alloc, &static, ctx);
        } else if (opts.resource_type == .document and opts.is_document_navigation) {
            const full_hints = opts.resource_type == .document or
                self.highEntropyClientHintsEnabledForUrl(request_url);
            // Always emit the full Chrome 150 document list (Accept-first + Sec-Fetch-*).
            // The old branch used thin `appendCurlImpersonateDocumentOverrides` for cold
            // hops, assuming libcurl default_headers would supply Accept/Sec-Fetch/UIR.
            // Wire capture (KOKO_WIRE_HEADERS) showed those defaults are *not* on the
            // hop-1 request — only Host/UA/AE/AL/Cookie/Sec-Ch-Ua/X-Browser — so cold
            // Google /search looked non-browser → knitsail / /sorry. In-session sei=
            // already used full headers (omit_sec_fetch_user path).
            const chrome_opts = HttpProfile.ChromeHeadersOpts{
                .full_client_hints = full_hints,
                .brands = profile.persona.network.brands,
                .color_scheme = profile.persona.network.prefers_color_scheme,
                .omit_sec_fetch_user = opts.omit_sec_fetch_user,
                // Referer is navigation provenance, independent of whether the
                // navigation has transient user activation. In particular,
                // child browsing-context navigations carry their embedder URL.
                // curl-impersonate's document headers carry Referer only for
                // same-origin/in-session navigations. Cross-site iframe
                // referrers are filtered by the document's referrer policy.
                .referer_url = if (opts.omit_sec_fetch_user) opts.referer else null,
            };
            try HttpProfile.appendChromeHeaders(headers, hdr_alloc, identity, &static, ctx, chrome_opts);
            try self._session.browser.app.config.profile_runtime.appendHeaderPlugins(
                header_plan,
                headers,
                hdr_alloc,
                http_client.getUserAgent(),
                self._session.fingerprint_seed,
            );
        } else {
            const full_hints = opts.resource_type == .document or
                self.highEntropyClientHintsEnabledForUrl(request_url);
            const chrome_opts = HttpProfile.ChromeHeadersOpts{
                .full_client_hints = full_hints,
                .brands = profile.persona.network.brands,
                .color_scheme = profile.persona.network.prefers_color_scheme,
                .omit_sec_fetch_user = opts.omit_sec_fetch_user,
                .referer_url = if (opts.omit_sec_fetch_user) opts.referer else null,
            };
            try HttpProfile.appendChromeHeaders(headers, hdr_alloc, identity, &static, ctx, chrome_opts);
            const referer_hdr = try refererHeaderForRequest(self, opts);
            if (referer_hdr.len > 0) {
                try headers.add(referer_hdr);
            }
            try self._session.browser.app.config.profile_runtime.appendHeaderPlugins(
                header_plan,
                headers,
                hdr_alloc,
                http_client.getUserAgent(),
                self._session.fingerprint_seed,
            );
        }
        return;
    }

    const referer = try refererHeaderForRequest(self, opts);
    try HttpProfile.appendFallbackHeaders(headers, hdr_alloc, identity, &static, ctx, referer);
}

fn highEntropyClientHintsEnabledForUrl(self: *const Frame, request_url: [:0]const u8) bool {
    if (!self._session.clientHintsEnabledForUrl(self.arena, request_url)) return false;

    // The UA-CH Permissions Policy default allowlist is `self`. Accept-CH from
    // a target origin does not delegate high-entropy hints to a cross-origin
    // document that later fetches that target.
    const request_origin = URL.getOrigin(self.arena, request_url) catch return false;
    if (!@import("../../runtime/profile/ClientHints.zig").defaultPolicyAllowsHighEntropy(
        request_origin,
        self.origin,
    )) return false;

    // Permissions Policy is inherited through every embedding boundary. Until
    // per-feature iframe/header delegation is represented, enforce the default
    // `self` allowlist across the complete ancestor chain.
    var child: *const Frame = self;
    while (child.parent) |parent| {
        if (!@import("../../runtime/profile/ClientHints.zig").defaultPolicyAllowsHighEntropy(
            child.origin,
            parent.origin,
        )) return false;
        child = parent;
    }
    return true;
}

// Origin for WebSocket upgrade and other callers that only need the origin token.
pub fn appendOriginHeader(self: *Frame, headers: *HttpClient.Headers) !void {
    const origin = try self.requestOrigin();
    const origin_hdr = try std.fmt.allocPrintSentinel(self.arena, "Origin: {s}", .{origin}, 0);
    try headers.add(origin_hdr);
}

pub fn requestOrigin(self: *Frame) ![]const u8 {
    if (self.origin) |o| return o;
    if (std.mem.startsWith(u8, self.url, "http")) {
        return (try URL.getOrigin(self.arena, self.url)) orelse "null";
    }
    return "null";
}

pub fn getArena(self: *Frame, size_or_bucket: anytype, debug: []const u8) !Allocator {
    return self._session.getArena(size_or_bucket, debug);
}

pub fn releaseArena(self: *Frame, allocator: Allocator) void {
    return self._session.releaseArena(allocator);
}

/// Nested DOM (appendChild) may run while `Env.checkpoint_active`.
/// **Nested path only** for timer policy: never `pumpDueTimersNow` while nested
/// (see EventLoop nested vs top-level table). Prefer `EventLoop.afterDomMutation`
/// when a single post-mutation drain is enough.
pub fn pumpSameTurnPromiseContinuations(self: *Frame) void {
    const env = &self._session.browser.env;
    const exec = &self.js.execution;
    // Returning from a DOM binding resumes the suspended JavaScript stack; it
    // is not a microtask checkpoint. Running Promise reactions here re-enters
    // framework commit phases between synchronous DOM operations (for example
    // appendChild), which violates HTML event-loop ordering and can turn a
    // stable ref update into an infinite render loop. The script/task runner
    // owns the checkpoint after V8 unwinds.
    if (exec.context.call_depth > 0) {
        env.checkpoint_pending = true;
        return;
    }
    var pass: u8 = 0;
    while (pass < 48) : (pass += 1) {
        // Unrestricted checkpoint: pure-JS Promise.resolve from onload.
        env.performMicrotaskCheckpointFp(self.js);
        if (@mod(pass, 4) == 3) {
            _ = self.runOwnedSchedulerOne() catch {};
            self.pumpDueTimersNow(10);
        }
    }
}

/// Mid classic `<script>` only — microtasks, **no** scheduler/timers
/// (`EventLoop.drainMicrotasksNested` shape). Deep passes re-enter MessagePort.
pub fn drainClassicScriptMicrotasks(self: *Frame) void {
    const env = &self._session.browser.env;
    const max_passes: u8 = if (self._script_manager.base.is_evaluating) 8 else 48;
    var pass: u8 = 0;
    while (pass < max_passes) : (pass += 1) {
        env.performMicrotaskCheckpointFp(self.js);
    }
}

/// After DOM insertion that may resolve pure-JS Promises. Delegates to
/// `EventLoop.afterDomMutation` (nested-safe vs top-level spin).
pub fn drainMicrotasksAfterDomInsertion(self: *Frame) void {
    // DOM serialization may insert an implementation-only <base> node. Those
    // mutations are not page script mutations and must not re-enter V8's
    // microtask checkpoint while the serializer is already on the JS stack.
    if (self._suppress_dom_mutation_microtasks) return;
    if (self.js.call_depth > 0) {
        self._session.browser.env.checkpoint_pending = true;
        return;
    }
    const js_mod = @import("../js/js.zig");
    // Local scope for any Zig→JS that reactions may need.
    var owned_scope: JS.Local.Scope = undefined;
    const has_local = self.js.local != null;
    if (!has_local) self.js.localScope(&owned_scope);
    defer if (!has_local) owned_scope.deinit();

    self.pumpSameTurnPromiseContinuations();
    js_mod.EventLoop.afterDomMutation(&self.js.execution);
}

/// Run overdue scheduler tasks up to `max_delay_ms` without a full macrotask pump.
pub fn pumpDueTimersNow(self: *Frame, max_delay_ms: u32) void {
    // Timer callbacks must run on V8's central stack. Nested host stacks are
    // not safe — EventLoop nested path forbids this (WS3).
    const js_mod = @import("../js/js.zig");
    if (js_mod.EventLoop.isHostNested(&self.js.execution)) {
        self.scheduleDeferredMacrotaskPump(0) catch |err| {
            log.warn(.frame, "defer timer pump nested", .{ .err = err });
        };
        return;
    }
    const env = &self._session.browser.env;
    var pass: u8 = 0;
    while (pass < 32) : (pass += 1) {
        const ms_to_next = self.js.scheduler.msToNext() orelse break;
        if (ms_to_next > max_delay_ms) break;
        if (!self.js.scheduler.hasReadyTasks()) break;
        _ = self.js.scheduler.runOne() catch break;
        // Nested yb() I() polls run while checkpoint_active; full runMicrotasks
        // defers and leaves Y.ip pending for vv()'s 2s race.
        var mt: u8 = 0;
        while (mt < 8) : (mt += 1) {
            env.performMicrotaskCheckpoint(self.js);
        }
    }
}

/// Schedule `runMacrotasks` on the next scheduler turn. Never call
/// `runMacrotasks` synchronously from V8 API callbacks (postMessage,
/// addEventListener, Worker setup) — it imbalances Context Enter/Exit.
pub fn scheduleDeferredMacrotaskPump(self: *Frame, delay_ms: u32) !void {
    const callback = try self.arena.create(DeferMacrotaskPumpCallback);
    callback.* = .{ .frame = self };

    try self.js.scheduler.add(callback, DeferMacrotaskPumpCallback.run, delay_ms, .{
        .name = "Frame.deferPump",
        .low_priority = false,
    });
}

const DeferMacrotaskPumpCallback = struct {
    frame: *Frame,

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DeferMacrotaskPumpCallback = @ptrCast(@alignCast(ctx));
        // This marker exists only to wake the outer Runner/Env turn. Calling
        // runMacrotasks here recursively drains schedulers while their current
        // callback still owns V8 locals and event objects. The outer event loop
        // observes the remaining ready contexts after this callback returns.
        _ = self.frame;
        return null;
    }
};

fn iframeSandboxFlags(self: *const Frame) IFrameSandbox.Flags {
    const iframe = self.iframe orelse return .{};
    return IFrameSandbox.parse(iframe);
}

fn applySandboxOrigin(self: *Frame, url_origin: ?[]const u8) !void {
    const flags = self.iframeSandboxFlags();
    if (IFrameSandbox.usesOpaqueOrigin(flags)) {
        self.origin = null;
    } else {
        self.origin = url_origin;
    }
    try self.js.setOrigin(self.origin);
}

/// Install the creator browsing context's origin identity on an inline child.
/// This preserves opaque-origin identity for about:blank/about:srcdoc. A
/// serialized `null` origin cannot represent that relationship.
fn inheritCreatorOrigin(self: *Frame, creator: *Frame) !void {
    if (IFrameSandbox.usesOpaqueOrigin(self.iframeSandboxFlags())) {
        return self.applySandboxOrigin(null);
    }
    self.origin = creator.origin;
    self.js.inheritOrigin(creator.js.origin);
}

pub fn isSameOrigin(self: *const Frame, url: [:0]const u8) bool {
    const current_origin = self.origin orelse return false;

    // fastpath
    if (!std.mem.startsWith(u8, url, current_origin)) {
        return false;
    }

    // Starting here, at least protocols are equals.
    // Compare hosts (domain:port) strictly
    return std.mem.eql(u8, URL.getHost(url), URL.getHost(current_origin));
}

/// Whether this browsing context is potentially trustworthy for APIs marked
/// [SecureContext]. Inline documents inherit their creator's serialized
/// origin, so checking the active origin also covers about:blank/srcdoc.
pub fn isSecureContext(self: *const Frame) bool {
    return potentiallyTrustworthyOrigin(self.origin orelse self.url);
}

fn potentiallyTrustworthyOrigin(raw: []const u8) bool {
    if (std.mem.startsWith(u8, raw, "https:") or std.mem.startsWith(u8, raw, "file:")) return true;
    if (!std.mem.startsWith(u8, raw, "http://")) return false;

    const authority = raw["http://".len..];
    const end = std.mem.indexOfAny(u8, authority, "/?#") orelse authority.len;
    const host_port = authority[0..end];
    const hostname = if (host_port.len > 0 and host_port[0] == '[') blk: {
        const close = std.mem.indexOfScalar(u8, host_port, ']') orelse return false;
        break :blk host_port[0 .. close + 1];
    } else blk: {
        const colon = std.mem.indexOfScalar(u8, host_port, ':') orelse host_port.len;
        break :blk host_port[0..colon];
    };
    return std.mem.eql(u8, hostname, "localhost") or
        std.mem.eql(u8, hostname, "127.0.0.1") or
        std.mem.eql(u8, hostname, "[::1]");
}

test "Frame: potentially trustworthy origins gate secure-context APIs" {
    try std.testing.expect(potentiallyTrustworthyOrigin("https://example.test"));
    try std.testing.expect(potentiallyTrustworthyOrigin("file:///tmp/page.html"));
    try std.testing.expect(potentiallyTrustworthyOrigin("http://localhost:8080"));
    try std.testing.expect(potentiallyTrustworthyOrigin("http://127.0.0.1/path"));
    try std.testing.expect(potentiallyTrustworthyOrigin("http://[::1]:9222"));
    try std.testing.expect(!potentiallyTrustworthyOrigin("about:blank"));
    try std.testing.expect(!potentiallyTrustworthyOrigin("http://example.test"));
    try std.testing.expect(!potentiallyTrustworthyOrigin("http://localhost.example.test"));
}

/// URL of the root frame in this frame tree (top-level browsing context).
pub fn topLevelUrl(self: *const Frame) [:0]const u8 {
    var frame: *const Frame = self;
    while (frame.parent) |parent| {
        frame = parent;
    }
    return frame.url;
}

/// Look up a blob URL in this frame's registry.
pub fn lookupBlobUrl(self: *Frame, url: []const u8) ?*Blob {
    return self._blob_urls.get(url);
}

/// Install a fresh Document for this browsing context. The previous document is
/// detached (`_frame = null`) so JS references to it lose cookie access per spec.
fn swapActiveDocument(self: *Frame) !void {
    const new_doc = (try self._factory.document(Document.HTMLDocument{
        ._proto = undefined,
    })).asDocument();
    const old_doc = self.document;
    old_doc._frame = null;
    self.document = new_doc;
    self.window._document = new_doc;
    new_doc._frame = self;
}

pub fn navigate(self: *Frame, request_url: [:0]const u8, opts: NavigateOpts) !void {
    assert(self._load_state == .waiting, "frame.renavigate", .{});

    // `javascript:` iframe sources are executable URLs, not HTTP resources.
    // Ad widgets commonly use them to run a parent-frame callback while
    // creating an otherwise blank iframe. They must not reach curl (which
    // reports CURLE_URL_MALFORMAT); leave the child at its initial blank
    // document until executable-URL navigation is implemented here.
    if (isJavascriptUrl(request_url)) {
        if (self.iframe != null) {
            return self.navigate("about:blank", opts);
        }
        return;
    }
    const session = self._session;
    try self.swapActiveDocument();
    session.cookie_jar.beginDocumentNavigation();
    self._load_state = .parsing;
    self._static_scripts_done_scheduled = false;
    self._pending_post_parse_lifecycle = false;
    self.terminateAllWorkers();
    self.bumpRealmNavigationEpoch();
    self._nav_task_owner = self.js.execution.captureTaskOwner();
    self.window._performance.recordNavigationStart();
    if (!self.loadedProfile().isFirefox()) {
        const nav_start = self.window._performance._timing.navigation_start;
        self.window._chrome.recordNavigationStart(nav_start);
    }
    @import("../../runtime/profile/AutomationScrub.zig").applyOnce(self);
    // Context bootstrap and constructor shims may use temporary engine
    // helpers. They must be gone before any document script can enumerate the
    // Window global.
    @import("../js/Env.zig").cleanupFrameInternalGlobals(self.js);

    const req_id = self._session.browser.http_client.nextReqId();
    const nav_id = log.bumpNavId() orelse 0;
    log.setContext(.{
        .nav_id = if (nav_id > 0) nav_id else null,
        .frame_id = self._frame_id,
        .url = request_url,
    });
    log.info(.frame, "navigate", .{
        .url = request_url,
        .method = opts.method,
        .reason = opts.reason,
        .body = opts.body != null,
        .req_id = req_id,
        .nav_id = nav_id,
        .type = self._type,
    });

    // Handle synthetic navigations: about:blank and blob: URLs
    const is_about_blank = std.mem.eql(u8, "about:blank", request_url);
    const is_blob = !is_about_blank and std.mem.startsWith(u8, request_url, "blob:");

    if (is_about_blank or is_blob) {
        self.url = if (is_about_blank) "about:blank" else try self.arena.dupeZ(u8, request_url);

        // even though this might be the same _data_ as `default_location`, we
        // have to do this to make sure window.location is at a unique _address_.
        // If we don't do this, multiple window._location will have the same
        // address and thus be mapped to the same v8::Object in the identity map.
        self.window._location = try Location.init(self.url, self);

        if (is_about_blank and !opts.opaque_about_error) {
            if (self.parent) |parent| {
                try self.inheritCreatorOrigin(parent);
            } else if (self.window._opener) |opener| {
                try self.inheritCreatorOrigin(opener._frame);
            } else {
                try self.applySandboxOrigin(null);
            }
        } else {
            const inline_origin = if (is_blob)
                try URL.getOrigin(self.arena, request_url[5.. :0])
            else
                null;
            try self.applySandboxOrigin(inline_origin);
        }

        // Assume we parsed the document.
        // It's important to force a reset during the following navigation.
        self._parse_state = .complete;

        // Inline navigations have no network commit; publish before injectBlank so
        // parent scripts polling contentWindow during appendChild see readyState.
        self.markRealmReadyForPublication();

        // Content injection
        if (is_blob) {
            // For navigation, walk up the parent chain to find blob URLs
            // (e.g., parent creates blob URL and sets iframe.src to it)
            const blob = blk: {
                var current: ?*Frame = self.parent;
                while (current) |frame| {
                    if (frame._blob_urls.get(request_url)) |b| break :blk b;
                    current = frame.parent;
                }
                log.warn(.js, "invalid blob", .{ .url = request_url });
                return error.BlobNotFound;
            };
            const parse_arena = try self.getArena(.medium, "Frame.parseBlob");
            defer self.releaseArena(parse_arena);
            var parser = Parser.init(parse_arena, self.document.asNode(), self);
            parser.parse(blob._slice);
        } else {
            self.document.injectBlank(self) catch |err| {
                log.err(.browser, "inject blank", .{ .err = err });
                return error.InjectBlankFailed;
            };
        }

        // Fingerprint yb() polls contentWindow when appendChild returns to its
        // Promise executor. Queue same-turn onload for flush at appendChild end.
        if (self.iframe) |iframe_elt| {
            if (self.parent) |parent| {
                parent.queueSyncIframeLoad(iframe_elt) catch |err| {
                    log.warn(.frame, "sync iframe load queue", .{ .err = err });
                };
            }
        }

        session.notification.dispatch(.frame_navigate, &.{
            .opts = opts,
            .req_id = req_id,
            .frame_id = self._frame_id,
            .loader_id = self._loader_id,
            .url = request_url,
            .timestamp = timestamp(.monotonic),
        });

        // Record telemetry for navigation
        session.browser.app.telemetry.record(.{
            .navigate = .{
                .tls = false, // about:blank and blob: are not TLS
                .proxy = session.browser.app.config.httpProxy() != null,
            },
        });

        session.notification.dispatch(.frame_navigated, &.{
            .req_id = req_id,
            .frame_id = self._frame_id,
            .loader_id = self._loader_id,
            .opts = .{
                .cdp_id = opts.cdp_id,
                .reason = opts.reason,
                .method = opts.method,
            },
            .url = request_url,
            .timestamp = timestamp(.monotonic),
        });

        // force next request id manually b/c we won't create a real req.
        _ = session.browser.http_client.incrReqId();

        const navigation = self.navigationStore();
        navigation._current_navigation_kind = opts.kind;
        try navigation.commitNavigation(self);

        self.documentIsComplete();
        return;
    }

    const http_client = &session.browser.http_client;

    const prior_url = self.url;
    const cookie_origin = cookieOriginForNavigation(self, prior_url);
    const is_top_level_navigation = self.parent == null;
    const nav_plan = try session.browser.app.config.profile_runtime.navigationPlan(self.arena, .{
        .prior_url = prior_url,
        .request_url = request_url,
        .reason = navigateReasonForProfile(opts.reason),
        .referer = opts.referer,
        .prior_origin = opts.prior_origin orelse self.origin,
        // Chỉ bật khi user truyền --google-chrome-transport. Antidetect profile
        // không tự spawn Chrome cho hop sg_ss (policy google-search.json).
        .external_transport_enabled = session.browser.app.config.googleChromeTransport(),
    });
    const prior_origin = nav_plan.prior_origin;
    const nav_referer = nav_plan.referer;

    self.url = nav_plan.effective_url;
    const url_origin = try URL.getOrigin(self.arena, self.url);
    try self.applySandboxOrigin(url_origin);

    self._req_id = req_id;
    self._navigated_options = .{
        .cdp_id = opts.cdp_id,
        .reason = opts.reason,
        .method = opts.method,
        .body = if (opts.body) |b| try self.arena.dupe(u8, b) else null,
        .header = if (opts.header) |h| try self.arena.dupeZ(u8, h) else null,
    };

    const use_chrome_transport = nav_plan.use_external_transport;

    var headers = try http_client.newHeaders();
    if (opts.header) |hdr| {
        try headers.add(hdr);
    }
    if (!use_chrome_transport) {
        try self.headersForRequest(&headers, .{
            .request_url = self.url,
            .resource_type = .document,
            .referer = nav_referer,
            .prior_origin = prior_origin,
            .is_document_navigation = true,
            .navigation_destination = if (self.parent == null) .top_level else .iframe,
            .omit_sec_fetch_user = nav_plan.omit_sec_fetch_user,
            .curl_defaults_only = nav_plan.curl_defaults_only,
        });
    }

    // A root navigation issued against a pending Page (i.e. one allocated by
    // Session.initiateRootNavigation) flags both the notification and the
    // HTTP request itself: CDP skips its node-registry reset until commit,
    // and the in-flight transfer survives the OLD page's frame.deinit which
    // calls http_client.abortFrame(frame_id) on the shared frame_id during
    // commitPendingPage.
    const is_pending_root = self._page._state == .pending;

    // We dispatch frame_navigate event before sending the request.
    // It ensures the event frame_navigated is not dispatched before this one.
    session.notification.dispatch(.frame_navigate, &.{
        .opts = opts,
        .url = self.url,
        .req_id = req_id,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .timestamp = timestamp(.monotonic),
        .is_pending_root = is_pending_root,
    });

    // Record telemetry for navigation
    session.browser.app.telemetry.record(.{ .navigate = .{
        .tls = std.ascii.startsWithIgnoreCase(self.url, "https://"),
        .proxy = session.browser.app.config.httpProxy() != null,
    } });

    self.navigationStore()._current_navigation_kind = opts.kind;

    if (use_chrome_transport) {
        return http_client.requestChromeTransport(.{
            .ctx = self,
            .params = .{
                .url = self.url,
                .frame_id = self._frame_id,
                .attribution_frame = self,
                .loader_id = self._loader_id,
                .method = opts.method,
                .headers = headers,
                .body = opts.body,
                .cookie_jar = &session.cookie_jar,
                .cookie_origin = cookie_origin,
                .top_level_cookie_url = self.topLevelUrl(),
                .is_top_level_navigation = is_top_level_navigation,
                .resource_type = .document,
                .referer = nav_referer,
                .omit_cookies = nav_plan.omit_cookies,
                .omit_sec_fetch_user = nav_plan.omit_sec_fetch_user,
                .curl_default_headers = nav_plan.curl_defaults_only,
                .prefer_http3 = nav_plan.prefer_http3,
                .force_fresh_connection = nav_plan.force_fresh_connection,
                .notification = self._session.notification,
                .browser_session = session,
                .protect_from_abort = is_pending_root,
                .skip_cache = opts.force,
            },
            .header_callback = frameHeaderDoneCallback,
            .data_callback = frameDataCallback,
            .done_callback = frameDoneCallback,
            .error_callback = frameErrorCallback,
        });
    }

    http_client.request(.{
        .ctx = self,
        .params = .{
            .url = self.url,
            .frame_id = self._frame_id,
            .attribution_frame = self,
            .loader_id = self._loader_id,
            .method = opts.method,
            .headers = headers,
            .body = opts.body,
            .cookie_jar = &session.cookie_jar,
            .cookie_origin = cookie_origin,
            .top_level_cookie_url = self.topLevelUrl(),
            .is_top_level_navigation = is_top_level_navigation,
            .resource_type = .document,
            .referer = nav_referer,
            .omit_cookies = nav_plan.omit_cookies,
            .omit_sec_fetch_user = nav_plan.omit_sec_fetch_user,
            .curl_default_headers = nav_plan.curl_defaults_only,
            .prefer_http3 = nav_plan.prefer_http3,
            .redirect_policy_refresh = refreshDocumentRedirectRequest,
            .notification = self._session.notification,
            .browser_session = session,
            .protect_from_abort = is_pending_root,
            .skip_cache = opts.force,
            .force_fresh_connection = opts.is_document_retry or nav_plan.force_fresh_connection,
        },
        .header_callback = frameHeaderDoneCallback,
        .data_callback = frameDataCallback,
        .done_callback = frameDoneCallback,
        .error_callback = frameErrorCallback,
    }) catch |err| {
        log.err(.frame, "navigate request", .{ .url = self.url, .err = err, .type = self._type });
        return err;
    };
}

// Navigation can happen in many places, such as executing a <script> tag or
// a JavaScript callback, a CDP command, etc...It's rarely safe to do immediately
// as the caller almost certainly doesn't expect the frame to go away during the
// call. So, we schedule the navigation for the next tick.
pub fn scheduleNavigation(self: *Frame, request_url: []const u8, opts: NavigateOpts, nt: Navigation) !void {
    if (self.canScheduleNavigation(std.meta.activeTag(nt)) == false) {
        return;
    }
    // HTML: navigations started during unload/pagehide must be ignored.
    if (self._unload_running or self.isUnloadRunningInChain()) {
        return;
    }
    // Executable URLs do not create a network navigation. In particular,
    // ignore iframe src updates instead of queuing an invalid curl transfer.
    if (isJavascriptUrl(request_url)) return;
    // about:srcdoc is only valid via the srcdoc="" attribute path — never
    // via location / window.open targeting (network-error → opaque page).
    if (isAboutSrcdocNavigationUrl(request_url) and
        !isSameDocumentAboutSrcdocUrl(self.url, request_url))
    {
        return self.scheduleOpaqueAboutSrcdocError(request_url);
    }
    const arena = try self._session.getArena(.small, "scheduleNavigation");
    errdefer self._session.releaseArena(arena);
    return self.scheduleNavigationWithArena(arena, request_url, opts, nt);
}

fn isUnloadRunningInChain(self: *const Frame) bool {
    var f: ?*const Frame = self;
    while (f) |cur| {
        if (cur._unload_running) return true;
        f = cur.parent;
    }
    return false;
}

fn isAboutSrcdocNavigationUrl(url: []const u8) bool {
    // about:srcdoc or about:srcdoc?...
    if (!std.mem.startsWith(u8, url, "about:srcdoc")) return false;
    if (url.len == "about:srcdoc".len) return true;
    return url["about:srcdoc".len] == '?' or url["about:srcdoc".len] == '#';
}

fn isJavascriptUrl(url: []const u8) bool {
    return url.len >= "javascript:".len and
        std.ascii.eqlIgnoreCase(url[0.."javascript:".len], "javascript:");
}

fn isSameDocumentAboutSrcdocUrl(current: []const u8, requested: []const u8) bool {
    if (!isAboutSrcdocNavigationUrl(current) or !isAboutSrcdocNavigationUrl(requested)) return false;
    const current_end = std.mem.indexOfScalar(u8, current, '#') orelse current.len;
    const requested_end = std.mem.indexOfScalar(u8, requested, '#') orelse requested.len;
    return std.mem.eql(u8, current[0..current_end], requested[0..requested_end]);
}

/// Navigate to a network-error style opaque document for blocked about:srcdoc.
fn scheduleOpaqueAboutSrcdocError(self: *Frame, request_url: []const u8) !void {
    _ = request_url;
    // Reuse about:blank opaque-ish path: swap document, mark opaque origin,
    // clear parent access (contentDocument null for cross-origin).
    if (self.iframe == null and self.parent != null) {
        // Should still be iframe path for WPT.
    }
    const arena = try self._session.getArena(.small, "scheduleAboutSrcdocError");
    errdefer self._session.releaseArena(arena);
    // Force a navigation that yields an opaque document — use a dedicated
    // about:blank re-nav with opaque origin flag via scheduleNavigationWithArena
    // would recurse; navigate inline after queue like about:blank re-nav.
    return self.scheduleNavigationWithArena(arena, "about:blank", .{
        .reason = .script,
        .kind = .{ .push = null },
        .force = true,
        .opaque_about_error = true,
    }, .{ .script = self });
}

/// Named child browsing context for Window named access (iframe name / window.name).
/// Only direct children — nested names are not visible on ancestors.
pub fn findNamedChildWindow(self: *Frame, name: []const u8) ?*@import("../webapi/Window.zig") {
    if (name.len == 0) return null;
    for (self.child_frames.items) |child| {
        if (child._detach_pending or child._deinit_done) continue;
        // Prefer live window.name, then iframe name attribute.
        if (child.window._name.len > 0 and std.mem.eql(u8, child.window._name, name)) {
            return child.window;
        }
        if (child.iframe) |iframe| {
            const attr = iframe.asElement().getAttributeSafe(comptime .wrap("name")) orelse "";
            if (attr.len > 0 and std.mem.eql(u8, attr, name)) {
                return child.window;
            }
        }
    }
    return null;
}

// Don't name the first parameter "self", because the target of this navigation
// might change inside the function. So the code should be explicit about the
// frame that it's acting on.
fn scheduleNavigationWithArena(originator: *Frame, arena: Allocator, request_url: []const u8, opts: NavigateOpts, nt: Navigation) !void {
    const resolved_url, const is_about_blank = blk: {
        if (URL.isCompleteHTTPUrl(request_url)) {
            break :blk .{ try arena.dupeZ(u8, request_url), false };
        }

        if (std.mem.eql(u8, request_url, "about:blank")) {
            // navigate will handle this special case
            break :blk .{ "about:blank", true };
        }

        // request_url isn't a "complete" URL, so it has to be resolved with the
        // originator's base. Unless, originator's base is "about:blank", in which
        // case we have to walk up the parents and find a real base.
        const frame_base = base_blk: {
            var maybe_not_blank_frame = originator;
            while (true) {
                const maybe_base = maybe_not_blank_frame.base();
                if (std.mem.eql(u8, maybe_base, "about:blank") == false) {
                    break :base_blk maybe_base;
                }
                // The orelse here is probably an invalid case, but there isn't
                // anything we can do about it. It should never happen?
                maybe_not_blank_frame = maybe_not_blank_frame.parent orelse break :base_blk "";
            }
        };

        const u = try URL.resolve(
            arena,
            frame_base,
            request_url,
            .{ .always_dupe = true, .encoding = originator.charset },
        );
        break :blk .{ u, false };
    };

    const target = switch (nt) {
        .form, .anchor => |p| p,
        .script => |p| p orelse originator,
        .iframe => |iframe| iframe._window.?._frame, // only an frame with existing content (i.e. a window) can be navigated
    };

    const session = target._session;
    // Short-circuit true fragment-only navigations (same path/query, different
    // fragment). Exact same-fragment assignments are filtered by Location's
    // hash setter before reaching this path. A full location assign/replace to
    // the current document URL is still a document navigation in browsers.
    const is_fragment_navigation = URL.eqlDocument(target.url, resolved_url);
    if (!opts.force and is_fragment_navigation and
        !std.mem.eql(u8, target.url, resolved_url))
    {
        target.url = try target.arena.dupeZ(u8, resolved_url);
        // Location has stable identity for the lifetime of a Window. Keep JS
        // references live while updating the URL owned by this context.
        target.window._location._url = try @import("../webapi/URL.zig").init(
            target.url,
            null,
            &target.js.execution,
        );
        target.document._url = target.url;
        try target.navigationStore().updateEntries(target.url, opts.kind, target, true);
        // don't defer this, the caller is responsible for freeing it on error
        session.releaseArena(arena);
        return;
    }

    log.info(.browser, "schedule navigation", .{
        .url = resolved_url,
        .reason = opts.reason,
        .type = target._type,
    });

    // Pre-abort in-flight work for the *target* frame before the queued nav
    // runs. Skip XHR + fetch: both may schedule this navigation from their own
    // callbacks (Google batchexecute XHR; Fingerprint agent fetch + about:blank
    // iframes). Killing them here left config GET as CDP Shutdown and hung
    // fetch() Promises. Document teardown still cancels via
    // abortTransfersAttributedTo without these skips.
    // Synthetic about:blank has no prior HTTP document body to cancel.
    if (!is_about_blank) {
        session.browser.http_client.abortFrame(target._frame_id, .{
            .skip_xhr = true,
            .skip_fetch = true,
        });
    }

    // Capture the originating frame's URL as the Referer for this
    // navigation. The originator's frame may be torn down before navigate()
    // runs (processRootQueuedNavigation rebuilds the Page in-place), so dup
    // into the QueuedNavigation arena which outlives that tear-down.
    var nav_opts = opts;
    if (nav_opts.referer == null and std.mem.startsWith(u8, originator.url, "http")) {
        nav_opts.referer = try arena.dupe(u8, originator.url);
    }
    if (nav_opts.prior_origin == null) {
        if (originator.origin) |o| {
            nav_opts.prior_origin = try arena.dupe(u8, o);
        } else if (nav_opts.referer) |ref| {
            const ref_z = try std.fmt.allocPrintSentinel(arena, "{s}", .{ref}, 0);
            nav_opts.prior_origin = try URL.getOrigin(arena, ref_z);
        }
    }

    const qn = try arena.create(QueuedNavigation);
    qn.* = .{
        .opts = nav_opts,
        .arena = arena,
        .url = resolved_url,
        .is_about_blank = is_about_blank,
        .navigation_type = std.meta.activeTag(nt),
    };

    if (target._queued_navigation) |existing| {
        session.releaseArena(existing.arena);
    }

    target._queued_navigation = qn;
    return session.scheduleNavigation(target);
}

// A script can have multiple competing navigation events, say it starts off
// by doing top.location = 'x' and then does a form submission.
// You might think that we just stop at the first one, but that doesn't seem
// to be what browsers do, and it isn't particularly well supported by v8 (i.e.
// halting execution mid-script).
// From what I can tell, there are 4 "levels" of priority, in order:
// 1 - form submission
// 2 - JavaScript apis (e.g. top.location)
// 3 - anchor clicks
// 4 - iframe.src =
// Within, each category, it's last-one-wins.
fn canScheduleNavigation(self: *Frame, new_target_type: NavigationType) bool {
    if (self.parent) |parent| {
        if (parent.isGoingAway()) {
            return false;
        }
    }

    const existing_target_type = (self._queued_navigation orelse return true).navigation_type;

    if (existing_target_type == new_target_type) {
        // same reason, than this latest one wins
        return true;
    }

    return switch (existing_target_type) {
        .iframe => true, // everything is higher priority than iframe.src = "x"
        .anchor => new_target_type != .iframe, // an anchor is only higher priority than an iframe
        .form => false, // nothing is higher priority than a form
        .script => new_target_type == .form, // a form is higher priority than a script
    };
}

pub fn documentIsLoaded(self: *Frame) void {
    if (self._load_state != .parsing) {
        // Ideally, documentIsLoaded would only be called once, but if a
        // script is dynamically added from an async script after
        // documentIsLoaded is already called, then ScriptManager will call
        // it again.
        return;
    }

    self._load_state = .load;
    self.document._ready_state = .interactive;
    self.window._performance.recordDomInteractive();
    self.observeBrowserStage("html-parser", 0, "boundary", "Renderer", "Main");
    self.observeBrowserStage("dom", 0, "boundary", "Renderer", "Main");
    self.observeLifecycle("domcontentloaded");

    // Emit Page.domContentEventFired *before* running page DOMContentLoaded
    // handlers. Ad/GTM listeners regularly V8_Fatal (stack overflow) and would
    // otherwise kill the process with CDP clients still waiting forever on
    // "Waiting for Page.domContentEventFired".
    self._session.notification.dispatch(.frame_dom_content_loaded, &.{
        .req_id = self._req_id,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .timestamp = timestamp(.monotonic),
    });

    self._documentIsLoaded() catch |err| {
        log.err(.frame, "document is loaded2", .{ .err = err, .type = self._type, .url = self.url });
    };
}

pub fn _documentIsLoaded(self: *Frame) !void {
    const HtmlElementVersionIntelligent = @import("../../runtime/profile/HtmlElementVersionIntelligent.zig");
    HtmlElementVersionIntelligent.installOnDocument(self, self.js);

    // Page DOMContentLoaded (after CDP). Failures here must not un-fire DCL.
    const event = try Event.initTrusted(.wrap("DOMContentLoaded"), .{ .bubbles = true }, self._page);
    self._event_manager.dispatch(
        self.document.asEventTarget(),
        event,
    ) catch |err| switch (err) {
        error.JsException => {},
        else => log.warn(.frame, "DOMContentLoaded dispatch", .{ .err = err, .url = self.url }),
    };
}

pub fn scriptsCompletedLoading(self: *Frame) void {
    self.pendingLoadCompleted();
}

fn iframeChildLoadedSynchronously(iframe: *const IFrame) bool {
    const child_window = iframe._window orelse return false;
    const child = child_window._frame;
    const url = child.url;
    return std.mem.eql(u8, url, "about:blank") or
        std.mem.eql(u8, url, "about:srcdoc") or
        std.mem.startsWith(u8, url, "blob:");
}

pub fn queueSyncIframeLoad(self: *Frame, iframe: *IFrame) !void {
    iframe._sync_load_queued = true;
    try self._sync_iframe_pending.append(self.arena, iframe);
}

pub fn flushPendingSyncIframeLoads(self: *Frame) void {
    if (self._sync_iframe_pending.items.len == 0) return;

    const to_process = self._sync_iframe_pending;
    self._sync_iframe_pending = if (to_process == &self._sync_iframe_pending_1)
        &self._sync_iframe_pending_2
    else
        &self._sync_iframe_pending_1;

    for (to_process.items) |iframe| {
        self.iframeCompletedLoading(iframe);
    }
    to_process.clearRetainingCapacity();

    if (self._sync_iframe_pending.items.len > 0) {
        self.flushPendingSyncIframeLoads();
    }

    // This function is called directly from Node insertion as well as from its
    // deferred scheduler task. It may queue iframe load work, but must not run
    // a checkpoint itself: during insertion the originating JavaScript call is
    // still active, and during the deferred path the outer task runner owns the
    // checkpoint. A private drain here can split a framework commit between ref
    // detach and attach callbacks.
}

/// Parser-inserted about:blank iframes queue sync `load` during HTML parse.
/// Flush on the next scheduler turn — not from `frameDoneCallback` / HTTP
/// callbacks, where cross-frame onload can imbalance V8 Enter/Exit.
pub fn scheduleDeferredSyncIframeFlush(self: *Frame) !void {
    if (self._sync_iframe_flush_scheduled) return;
    if (self._sync_iframe_pending.items.len == 0) return;
    self._sync_iframe_flush_scheduled = true;

    const callback = try self.arena.create(DeferSyncIframeFlushCallback);
    callback.* = .{ .frame = self };

    try self.js.scheduler.add(callback, DeferSyncIframeFlushCallback.run, 0, .{
        .name = "Frame.deferSyncIframeFlush",
        .low_priority = false,
    });
}

/// Defer HTML parse and parser-inserted scripts off the document HTTP
/// done_callback. frameDoneCallback runs inside HttpClient.processMessages;
/// synchronous parse + staticScriptsDone starves CDP polling (ebay.com hang).
pub fn hasDeferredDocumentParsePending(self: *const Frame) bool {
    return self._document_parse_scheduled;
}

/// Poll the CDP socket during long synchronous work (HTML parse, script eval).
///
/// While deferred document parse is on the stack, do **not** service CDP:
/// `Page.navigate` would drain this realm mid-html5ever and createElement
/// returning null corrupts the tree builder (getDataCallback UAF). Finish the
/// parse, then let the runner poll CDP; cancel-on-nav clears the old realm.
pub fn pollCdpDuringLongWork(self: *Frame) void {
    if (self._document_parse_active) return;
    self._cdp_poll_counter +%= 1;
    if (self._cdp_poll_counter & 0x0F != 0) return;
    self._session.browser.http_client.serviceInboundCdpIfReadable();
}

/// Start classic script drain + DCL after HTML parse. Must not run inside an
/// HTTP transfer callback (defer head fetches deadlock until curl unwinds).
pub fn runPostParseScriptLifecycle(self: *Frame) void {
    if (self._script_manager.base.static_scripts_done) return;
    const started = nanoTimestamp(.monotonic);
    defer self.observeBrowserStage("javascript", elapsedMicros(started), "measured", "Renderer", "Main");
    self._static_scripts_done_scheduled = false;
    // Activate style/link/img that were skipped mid-document-parse.
    self.activateDeferredParserResources();
    // Queues evaluate on delay-0 (shallow stack). Do not scheduler.run() here
    // for normal sites: pumpPostParseTasks would drain 70+ Next defer chunks
    // (stripe.com) on the frameDone/parse stack → MessagePort/V8_Fatal before DCL.
    self._script_manager.staticScriptsDone();
    self.pollCdpDuringLongWork();
    if (!navDeliverable(self)) return;
    self.scheduleDeferredSyncIframeFlush() catch |err| {
        log.warn(.frame, "defer sync iframe flush", .{ .err = err, .url = self.url });
    };
    // Parser-created lazy images are now outside the parser stack. Queue their
    // fallback activation before the document-complete bookkeeping so a page
    // that has no other pending resources still gets a scheduler turn.
    self.scheduleDeferredLazyImageActivation() catch |err| {
        log.warn(.frame, "defer lazy image activation", .{ .err = err, .url = self.url });
    };
}

/// Keep a lazy image out of the initial resource burst. The list is owned by
/// the frame arena, so no separate deallocation is needed during teardown.
pub fn deferLazyImage(self: *Frame, image: *Element.Html.Image) !void {
    for (self._deferred_lazy_images.items) |pending| {
        if (pending == image) return;
    }
    try self._deferred_lazy_images.append(self.arena, image);
    if (self._load_state == .complete) {
        try self.scheduleDeferredLazyImageActivation();
    }
}

/// Schedule lazy resource activation after `load` has been delivered. This is
/// a headless fallback for the compositor/viewport trigger that Koko does not
/// have; it preserves the important contract that lazy resources are deferred
/// and still eventually load.
pub fn scheduleDeferredLazyImageActivation(self: *Frame) !void {
    if (self._lazy_images_activation_scheduled) return;
    if (self._deferred_lazy_images.items.len == 0) return;
    self._lazy_images_activation_scheduled = true;

    const callback = try self.arena.create(DeferLazyImageActivationCallback);
    callback.* = .{ .frame = self };
    try self.js.scheduler.add(callback, DeferLazyImageActivationCallback.run, 0, .{
        .name = "Frame.activateLazyImages",
        // This is a lifecycle handoff, not background work: run it on the
        // next ordinary macrotask turn so the image can settle before the
        // caller's post-load scheduler drain ends.
        .low_priority = false,
    });
}

fn activateDeferredLazyImages(self: *Frame) void {
    if (!navDeliverable(self)) return;

    // Swap the queue before starting requests. Completion handlers and script
    // callbacks may create more lazy images; those belong to a subsequent
    // activation pass and cannot invalidate this iteration.
    const pending = self._deferred_lazy_images;
    self._deferred_lazy_images = .empty;
    for (pending.items) |image| {
        if (!navDeliverable(self)) return;
        image.activateDeferredLoad(self) catch |err| {
            log.warn(.frame, "lazy image activation", .{ .err = err, .url = self.url });
        };
    }
    if (self._deferred_lazy_images.items.len > 0) {
        self.scheduleDeferredLazyImageActivation() catch |err| {
            log.warn(.frame, "reschedule lazy image activation", .{ .err = err, .url = self.url });
        };
    }
}

const DeferLazyImageActivationCallback = struct {
    frame: *Frame,

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DeferLazyImageActivationCallback = @ptrCast(@alignCast(ctx));
        self.frame._lazy_images_activation_scheduled = false;
        if (!navDeliverable(self.frame)) return null;
        self.frame.activateDeferredLazyImages();
        return null;
    }
};

/// Walk document after HTML parse and fire nodeIsReady for style/link/img
/// that were intentionally skipped during html5ever (parser-stability).
fn activateDeferredParserResources(self: *Frame) void {
    if (!navDeliverable(self)) return;
    const root = self.document.asNode();
    var tw = @import("../dom/TreeWalker.zig").Full.Elements.init(root, .{});
    while (tw.next()) |el| {
        if (!navDeliverable(self)) return;
        // Scripts/iframes already ran at parser insertion points.
        if (el.is(Element.Html.Script) != null or el.is(IFrame) != null) continue;
        if (el.is(Element.Html.Style) == null and el.is(Element.Html.Link) == null and el.is(Element.Html.Image) == null) {
            continue;
        }
        self.nodeIsReady(false, el.asNode()) catch |err| {
            log.warn(.frame, "post-parse resource activate", .{ .err = err, .url = self.url });
        };
    }
}

pub fn scheduleDeferredStaticScriptsDone(self: *Frame) !void {
    if (self._script_manager.base.static_scripts_done) return;
    if (self._static_scripts_done_scheduled) return;
    self._static_scripts_done_scheduled = true;

    const callback = try self.arena.create(DeferStaticScriptsDoneCallback);
    callback.* = .{ .frame = self };
    // Fallback when leaveTransferCallback did not run lifecycle (scheduler path).
    const delay_ms: u32 = if (self._session.browser.http_client.inTransferCallback()) 1 else 0;
    try self.js.scheduler.add(callback, DeferStaticScriptsDoneCallback.run, delay_ms, .{
        .name = "Frame.deferStaticScriptsDone",
        .low_priority = false,
    });
}

const DeferStaticScriptsDoneCallback = struct {
    frame: *Frame,

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DeferStaticScriptsDoneCallback = @ptrCast(@alignCast(ctx));
        self.frame._static_scripts_done_scheduled = false;
        if (!navDeliverable(self.frame)) return null;
        self.frame.runPostParseScriptLifecycle();
        return null;
    }
};

pub fn scheduleDeferredDocumentParse(self: *Frame, raw_html: []const u8, as_xml: bool, html_arena: Allocator) !void {
    // Refuse while a parse is in flight — mid-parse reschedule + pump re-entered
    // html5ever and corrupted the tree (Google → Bing SIGABRT).
    if (self._document_parse_scheduled or self._document_parse_active) {
        return error.DocumentParseAlreadyPending;
    }
    self._document_parse_scheduled = true;
    errdefer self._document_parse_scheduled = false;

    const callback = try self.arena.create(DeferDocumentParseCallback);
    callback.* = .{
        .frame = self,
        .raw_html = raw_html,
        .as_xml = as_xml,
        .html_arena = html_arena,
    };

    try self.js.scheduler.add(callback, DeferDocumentParseCallback.run, 0, .{
        .name = "Frame.deferDocumentParse",
        .low_priority = false,
        .finalizer = DeferDocumentParseCallback.cancelled,
    });
}

const DeferDocumentParseCallback = struct {
    frame: *Frame,
    raw_html: []const u8,
    as_xml: bool,
    html_arena: Allocator,

    fn finish(self: *DeferDocumentParseCallback) void {
        self.frame.releaseArena(self.html_arena);
    }

    fn cancelled(ctx: *anyopaque) void {
        const self: *DeferDocumentParseCallback = @ptrCast(@alignCast(ctx));
        self.finish();
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DeferDocumentParseCallback = @ptrCast(@alignCast(ctx));
        const http_client = &self.frame._session.browser.http_client;
        // Runner may service ready scheduler tasks from processMessages while
        // curl_multi_perform is still active. Parsing there turns every parser-
        // blocking external script into an async script because libcurl cannot
        // start a nested transfer. Wait until the outer perform has returned so
        // normal scripts can synchronously block the parser, as HTML requires.
        if (http_client.performing or http_client.inTransferCallback()) {
            return 1;
        }
        // Re-entrancy guard: pollCdpDuringLongWork → pumpDeferredDocumentParse can
        // re-enter this callback mid-parse (Google re-nav → Bing double parse →
        // corrupt _parent / SIGABRT). Never parse the same document twice.
        if (self.frame._document_parse_active) {
            self.finish();
            return null;
        }
        self.frame._document_parse_scheduled = false;
        defer self.finish();
        // Do not block all inbound CDP (Runtime.evaluate) with navigationCritical.
        // Cancel-on-nav is cooperative: poll may start re-nav → prepareForOutgoingAbort
        // marks draining + resets scheduler; parser callbacks re-check realm.
        if (!navDeliverable(self.frame)) return null;

        self.frame._document_parse_active = true;
        defer self.frame._document_parse_active = false;

        const parse_arena = try self.frame.getArena(.medium, "Frame.parse");
        defer self.frame.releaseArena(parse_arena);

        var parser = Parser.init(parse_arena, self.frame.document.asNode(), self.frame);
        log.debug(.frame, "parse html start", .{
            .type = self.frame._type,
            .url = self.frame.url,
            .len = self.raw_html.len,
            .charset = self.frame.charset,
        });
        if (self.as_xml) {
            parser.parseXML(self.raw_html);
        } else if (std.mem.eql(u8, self.frame.charset, "UTF-8")) {
            parser.parse(self.raw_html);
        } else {
            parser.parseWithEncoding(self.raw_html, self.frame.charset);
        }
        self.frame.clearParserTextCaps();
        log.debug(.frame, "parse html done", .{ .type = self.frame._type, .url = self.frame.url, .len = self.raw_html.len });

        // A parser-executed script may queue navigation for this very frame.
        // `navDeliverable` intentionally becomes false as soon as that happens,
        // but the Session queue is the mechanism that actually starts the next
        // document. Hand the queue over before applying the departing-document
        // lifecycle guard, otherwise the frame remains `deferred_html` forever.
        const self_navigation_queued = self.frame._queued_navigation != null;
        if (!self_navigation_queued) {
            self.frame.reconcileParserIframeSrc();
        }
        self.frame.drainQueuedNavigationsAfterParse();
        if (self_navigation_queued) return null;

        // Re-nav may have marked draining mid-parse via a nested path; do not
        // run scripts / load events on a departing realm.
        if (!navDeliverable(self.frame)) return null;
        self.frame._parse_state = .{ .complete = {} };

        self.frame.pollCdpDuringLongWork();
        if (!navDeliverable(self.frame)) return null;
        self.frame.pollCdpDuringLongWork();
        if (!navDeliverable(self.frame)) return null;
        self.frame.runPostParseScriptLifecycle();
        self.frame._session.browser.http_client.serviceInboundCdpIfReadable();
        return null;
    }
};

const DeferSyncIframeFlushCallback = struct {
    frame: *Frame,

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DeferSyncIframeFlushCallback = @ptrCast(@alignCast(ctx));
        self.frame._sync_iframe_flush_scheduled = false;
        self.frame.flushPendingSyncIframeLoads();
        return null;
    }
};

pub fn iframeCompletedLoading(self: *Frame, iframe: *IFrame) void {
    if (iframe._window == null) return;
    if (iframeChildLoadedSynchronously(iframe)) {
        if (iframe._sync_onload_dispatched) return;
        // Fingerprint shared-iframe init (and similar) does:
        //   onload = resolve; appendChild(about:blank);
        //   poll: if (!resolved && readyState==='complete') resolve();
        //   else setTimeout(poll, 10);
        // contentWindow/readyState are published during about:blank navigate
        // (injectBlank + markRealmReady) *before* this queue flush.
        //
        // about:blank / sync inject: schedule deferred load + denser settle so
        // pure-JS await load continues (agent iframe + SPA patterns). No site URL
        // specials — denser settle is default for all.
        self.scheduleDeferredIframeLoad(iframe) catch |err| {
            log.warn(.js, "iframe defer load", .{ .err = err, .url = iframe._src });
            // Fallback: sync path only if we cannot schedule.
            self.dispatchIframeLoadNow(&.{iframe}, .same_turn) catch |e2| {
                log.warn(.js, "iframe onload sync", .{ .err = e2, .url = iframe._src });
                self.pendingLoadCompleted();
            };
        };
        // Promise reactions are driven after the queued load task returns.
        // Do not checkpoint while iframeCompletedLoading is reached from the
        // originating appendChild call.
        return;
    }
    self.queueIframeLoad(iframe) catch |err| {
        log.warn(.js, "iframe onload queue", .{ .err = err, .url = iframe._src });
        // Unblock parent load if we cannot queue the iframe load event.
        self.pendingLoadCompleted();
    };
}

fn removePendingIframeLoad(self: *Frame, iframe: *IFrame) void {
    for (&[_]*std.ArrayList(*IFrame){ &self._iframe_load_1, &self._iframe_load_2 }) |list| {
        var i: usize = 0;
        while (i < list.items.len) {
            if (list.items[i] == iframe) {
                _ = list.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
    for (&[_]*std.ArrayList(*IFrame){ &self._sync_iframe_pending_1, &self._sync_iframe_pending_2 }) |list| {
        var i: usize = 0;
        while (i < list.items.len) {
            if (list.items[i] == iframe) {
                _ = list.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
}

fn queueIframeLoad(self: *Frame, iframe: *IFrame) !void {
    if (iframe._window == null) return;
    try self._iframe_load.append(self.arena, iframe);
    if (self._iframe_load_scheduled) return;
    self._iframe_load_scheduled = true;
    try self.js.scheduler.add(self, struct {
        fn cleanup(ctx: *anyopaque) !?u32 {
            const f: *Frame = @ptrCast(@alignCast(ctx));
            try f.dispatchIframeLoad();
            return null;
        }
    }.cleanup, 0, .{ .name = "frame.dispatchIframeLoad" });
}

/// Delay-0 load dispatch for sync about:blank iframes. Lets agent-style
/// `readyState === 'complete'` polls resolve the load Promise on the same turn
/// after appendChild returns, before we fire the property onload handler.
fn scheduleDeferredIframeLoad(self: *Frame, iframe: *IFrame) !void {
    if (iframe._sync_onload_dispatched) return;
    const arena = try self.getArena(.tiny, "Frame.deferIframeLoad");
    errdefer self.releaseArena(arena);
    const callback = try arena.create(DeferIframeLoadCallback);
    callback.* = .{
        .frame = self,
        .iframe = iframe,
        .arena = arena,
        .task_owner = self.js.execution.captureTaskOwner(),
    };
    try self.js.scheduler.add(callback, DeferIframeLoadCallback.run, 0, .{
        .name = "Frame.deferIframeLoad",
        .low_priority = false,
        .finalizer = DeferIframeLoadCallback.cancelled,
    });
}

const DeferIframeLoadCallback = struct {
    frame: *Frame,
    iframe: *IFrame,
    arena: Allocator,
    task_owner: @import("../../runtime/RealmLifecycleKernel.zig").TaskOwner,

    fn cancelled(ctx: *anyopaque) void {
        const self: *DeferIframeLoadCallback = @ptrCast(@alignCast(ctx));
        self.frame.releaseArena(self.arena);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DeferIframeLoadCallback = @ptrCast(@alignCast(ctx));
        defer self.frame.releaseArena(self.arena);
        if (self.frame.js.execution.isTaskOwnerStale(self.task_owner)) return null;
        if (self.iframe._window == null) return null;
        if (self.iframe._sync_onload_dispatched) return null;
        self.frame.dispatchIframeLoadNow(&.{self.iframe}, .same_turn) catch |err| {
            log.warn(.js, "iframe onload deferred", .{ .err = err, .url = self.iframe._src });
            self.frame.pendingLoadCompleted();
            return null;
        };
        // After property onload (pure-JS resolve), perform the normal microtask
        // checkpoint; later timers remain owned by the shared event loop.
        self.frame.settleIframePromisesNow();
        return null;
    }
};

/// Host-agnostic settle for pure-JS Promise reactions after about:blank load.
///
/// Nested host stack: microtasks only + deferred macrotask pumps (WS3 — never
/// `pumpDueTimersNow` while nested; that path defers itself but callers should
/// not pretend timers already ran).
/// Top-level: short timer pump + `EventLoop.spin` so setTimeout(10) polls and
/// delay-0 chains progress without a private multi-delay cascade.
pub fn settleIframePromisesNow(self: *Frame) void {
    const js_mod = @import("../js/js.zig");
    const exec = &self.js.execution;
    const env = &self._session.browser.env;
    self.clearSchedulerSuppression();
    env.checkpoint_pending = true;

    var pass: u8 = 0;
    while (pass < 16) : (pass += 1) {
        env.drainAllRealmMicrotasks();
        env.performMicrotaskCheckpointFp(self.js);
    }

    if (js_mod.EventLoop.isHostNested(exec)) {
        // Nested appendChild / script: schedule outer pumps; wait-edge spin finishes.
        env.checkpoint_pending = true;
        self.scheduleDeferredMacrotaskPump(0) catch {};
        return;
    }

    // Top-level path: only work already due in this turn. Future timers retain
    // their own scheduler deadlines and wake through the shared event loop.
    self.pumpDueTimersNow(0);
    pass = 0;
    while (pass < 8) : (pass += 1) {
        env.drainAllRealmMicrotasks();
        env.performMicrotaskCheckpointFp(self.js);
    }
    js_mod.EventLoop.spin(exec, .{ .max_tasks = 32, .stop_when_idle = true });

    if (!env.checkpoint_active) {
        var outer: u8 = 0;
        while (outer < 4) : (outer += 1) {
            env.checkpoint_pending = false;
            env.runMicrotasks(.event_handler);
            if (!env.checkpoint_pending) break;
        }
    } else {
        env.checkpoint_pending = true;
    }
}

const IframeLoadDispatch = enum { same_turn, deferred };

fn dispatchIframeLoadNow(self: *Frame, iframes: []const *IFrame, comptime when: IframeLoadDispatch) !void {
    for (iframes) |iframe| {
        if (iframe._window == null) continue;
        var invoked_onload = false;

        const event = Event.initTrusted(comptime .wrap("load"), .{}, self._page) catch |err| {
            log.err(.frame, "iframe event init", .{ .err = err, .url = iframe._src });
            continue;
        };
        const target = iframe.asNode().asEventTarget();

        if (comptime when == .same_turn) {
            // Fingerprint yb() sets iframe.onload before appendChild. Invoke the
            // property handler directly (getOnLoad also materializes onload="").
            if (iframe.asNode().is(HtmlElement)) |html| {
                if (html.getOnLoad(self) catch null) |handler| {
                    var owned_scope: JS.Local.Scope = undefined;
                    const local: *const JS.Local = blk: {
                        if (self.js.local) |active| break :blk active;
                        self.js.localScope(&owned_scope);
                        break :blk &owned_scope.local;
                    };
                    defer if (self.js.local == null) owned_scope.deinit();

                    event._target = target;
                    event._current_target = target;
                    const handler_handle = JS.v8.v8__Global__Get(&handler.handle, local.isolate.handle) orelse continue;
                    const handler_local = JS.Function{
                        .local = local,
                        .handle = @ptrCast(handler_handle),
                    };
                    // Fingerprint yb() onload is () => { d=true; resolve(); } — zero-arg first.
                    const invoke_ok = blk: {
                        handler_local.callWithThis(void, target, .{}) catch {
                            handler_local.callWithThis(void, target, .{event}) catch |err| {
                                log.warn(.js, "iframe onload invoke", .{ .err = err, .url = iframe._src });
                                break :blk false;
                            };
                            break :blk true;
                        };
                        break :blk true;
                    };
                    if (invoke_ok) invoked_onload = true;
                }
                // Always dispatch too — yb() tolerates duplicate p() via d=true guard.
            }
        }

        self._event_manager.dispatch(target, event) catch |err| {
            log.warn(.js, "iframe onload", .{ .err = err, .url = iframe._src });
        };

        if (comptime when == .same_turn) {
            iframe._sync_load_queued = false;
            if (invoked_onload) iframe._sync_onload_dispatched = true;
            self.pumpSameTurnPromiseContinuations();
            // Wake pure-JS onload→Promise; nested-safe via EventLoop.
            const js_mod = @import("../js/js.zig");
            js_mod.EventLoop.afterDomMutation(&self.js.execution);
        }
    }

    if (comptime when == .deferred) {
        // Preserve ordering by waking the next outer event-loop turn. Never
        // recursively drain Env while the iframe-load scheduler callback and
        // its V8 event handles are still active.
        self.scheduleDeferredMacrotaskPump(0) catch {};
    }

    var completed: usize = 0;
    for (iframes) |iframe| {
        if (iframe._window != null) completed += 1;
    }
    for (0..completed) |_| {
        self.pendingLoadCompleted();
    }
}

fn dispatchIframeLoad(self: *Frame) !void {
    self._iframe_load_scheduled = false;

    const to_process = self._iframe_load;
    self._iframe_load = if (self._iframe_load == &self._iframe_load_1)
        &self._iframe_load_2
    else
        &self._iframe_load_1;

    try self.dispatchIframeLoadNow(to_process.items, .deferred);
    to_process.clearRetainingCapacity();
}

fn pendingLoadCompleted(self: *Frame) void {
    const pending_loads = self._pending_loads;
    if (pending_loads == 1) {
        self._pending_loads = 0;
        self.documentIsComplete();
    } else {
        self._pending_loads = pending_loads - 1;
    }
}

/// Run timer/macrotask work deferred while the HTML parser was active.
pub fn pumpPostParseTasks(self: *Frame) void {
    self.pumpPostParseTasksNow();
}

fn pumpPostParseTasksNow(self: *Frame) void {
    var ls: JS.Local.Scope = undefined;
    self.js.localScope(&ls);
    defer ls.deinit();

    ls.local.ctx.env.runMicrotasks(.after_evaluate);
    ls.local.runMacrotasks();
    _ = self.js.scheduler.run() catch |err| {
        log.warn(.frame, "post-parse scheduler", .{ .err = err });
    };
}

pub fn isDocumentParsing(self: *const Frame) bool {
    return self._load_state == .parsing;
}

pub fn documentIsComplete(self: *Frame) void {
    if (self._detach_pending) return;
    if (self.iframe) |iframe| {
        if (iframe._window == null) return;
    }
    if (self._load_state == .complete) {
        // Ideally, documentIsComplete would only be called once, but with
        // dynamic scripts, it can be hard to keep track of that. An async
        // script could be evaluated AFTER Loaded and Complete and load its
        // own non non-async script - which, upon completion, needs to check
        // whether Laoded/Complete have already been called, which is what
        // this guard is.
        return;
    }

    // documentIsComplete could be called directly, without first calling
    // documentIsLoaded, if there were _only_ async scripts.
    if (self._load_state == .parsing) {
        self.documentIsLoaded();
    }

    self._load_state = .complete;
    self.window._performance.recordDocumentComplete();
    if (!self.loadedProfile().isFirefox()) {
        const load_end = self.window._performance._timing.load_event_end;
        self.window._chrome.recordDocumentComplete(load_end);
    }
    // Turnstile parent posts bootstrap messages while the iframe is still
    // parsing; deliver them once the widget script has finished loading.
    self.window.flushPendingPostMessages();
    self._documentIsComplete() catch |err| switch (err) {
        error.JsException => {}, // already logged
        else => log.err(.frame, "document is complete", .{ .err = err, .type = self._type, .url = self.url }),
    };
}

fn _documentIsComplete(self: *Frame) !void {
    self.document._ready_state = .complete;

    // Run load events before window.load.
    try self.dispatchLoad();

    // Dispatch window.load event.
    const window_target = self.window.asEventTarget();
    if (self._event_manager.hasDirectListeners(window_target, "load", self.window._on_load)) {
        const event = try Event.initTrusted(comptime .wrap("load"), .{}, self._page);
        // This event is weird, it's dispatched directly on the window, but
        // with the document as the target.
        event._target = self.document.asEventTarget();
        try self._event_manager.dispatchDirect(window_target, event, self.window._on_load, .{ .inject_target = false, .context = "page load" });
    }

    self._session.notification.dispatch(.frame_loaded, &.{
        .req_id = self._req_id,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .timestamp = timestamp(.monotonic),
    });
    self.observeLifecycle("load");
    // Lazy resources must not block `load`, but they must not remain pending
    // forever in a headless runtime either. Start them on the next scheduler
    // turn after the load notification has reached page observers.
    self.scheduleDeferredLazyImageActivation() catch |err| {
        log.warn(.frame, "defer lazy image activation", .{ .err = err, .url = self.url });
    };
    self.observeBrowserStage("frame", 0, "boundary", "Renderer", "Main");

    if (self._event_manager.hasDirectListeners(window_target, "pageshow", self.window._on_pageshow)) {
        const pageshow_event = (try PageTransitionEvent.initTrusted(comptime .wrap("pageshow"), .{}, self)).asEvent();
        try self._event_manager.dispatchDirect(window_target, pageshow_event, self.window._on_pageshow, .{ .context = "page show" });
    }

    if (comptime IS_DEBUG) {
        log.debug(.frame, "load", .{ .url = self.url, .type = self._type });
    }

    self.notifyParentLoadComplete();
}

fn notifyParentLoadComplete(self: *Frame) void {
    const parent = self.parent orelse return;

    if (self.iframe) |iframe| {
        if (iframe._window == null) return;
        if (iframe._sync_onload_dispatched or iframe._sync_load_queued) {
            self._parent_notified = true;
            return;
        }
    }

    if (self._parent_notified == true) {
        if (comptime IS_DEBUG) {
            std.debug.assert(false);
        }
        // shouldn't happen, don't want to crash a release build over it
        return;
    }

    self._parent_notified = true;
    parent.iframeCompletedLoading(self.iframe.?);
}

/// Initiating document URL for SameSite cookie inclusion. Embedded iframe loads
/// from about:blank must use the parent's URL, not the navigation target.
fn cookieOriginForNavigation(frame: *Frame, prior_url: [:0]const u8) [:0]const u8 {
    if (std.mem.startsWith(u8, prior_url, "http")) return prior_url;
    if (frame.parent) |parent| {
        if (std.mem.startsWith(u8, parent.url, "http")) return parent.url;
    }
    return frame.url;
}

/// URL used for `document.cookie` get/set (about:blank inherits parent HTTP URL).
pub fn cookieURL(self: *const Frame) [:0]const u8 {
    return cookieOriginForNavigation(@constCast(self), self.url);
}

fn refreshDocumentRedirectRequest(
    ctx: *anyopaque,
    transfer: *HttpClient.Transfer,
    prior_url: [:0]const u8,
) !void {
    if (transfer.aborted) return;

    const arena = transfer.req.params.arena;
    const session = transfer.req.params.browser_session orelse blk: {
        const stale: *Frame = @ptrCast(@alignCast(ctx));
        break :blk stale._session;
    };
    const http_client = &session.browser.http_client;

    const frame = session.findFrameForHttpAttribution(transfer.req.params.frame_id);

    const prior_origin = if (frame) |f|
        f.origin
    else
        try URL.getOrigin(arena, if (std.mem.startsWith(u8, prior_url, "http")) prior_url else prior_url);

    const nav_plan = try session.browser.app.config.profile_runtime.navigationPlan(arena, .{
        .prior_url = prior_url,
        .request_url = transfer.req.params.url,
        .reason = .navigation,
        .referer = null,
        .prior_origin = prior_origin,
        .external_transport_enabled = false,
    });

    transfer.req.params.omit_sec_fetch_user = nav_plan.omit_sec_fetch_user;
    transfer.req.params.curl_default_headers = nav_plan.curl_defaults_only;
    transfer.req.params.omit_cookies = nav_plan.omit_cookies;
    transfer.req.params.prefer_http3 = nav_plan.prefer_http3;
    if (nav_plan.force_fresh_connection) transfer.req.params.force_fresh_connection = true;
    transfer.req.params.referer = nav_plan.referer;

    const live_frame = frame orelse {
        // Superseding root navigation discarded the pending frame while this
        // transfer is still inside handleRedirect. Cookie/referer policy above
        // is enough; skip header rebuild on a freed Frame.
        return;
    };

    transfer.req.params.headers.deinit();
    var headers = try http_client.newHeaders();
    try live_frame.headersForRequest(&headers, .{
        .request_url = transfer.req.params.url,
        .resource_type = .document,
        .referer = nav_plan.referer,
        .prior_origin = nav_plan.prior_origin,
        .is_document_navigation = true,
        .navigation_destination = if (live_frame.parent == null) .top_level else .iframe,
        .omit_sec_fetch_user = nav_plan.omit_sec_fetch_user,
        .curl_defaults_only = nav_plan.curl_defaults_only,
    });
    transfer.req.params.headers = headers;
}

fn frameHeaderDoneCallback(response: HttpClient.Response) !bool {
    var self: *Frame = @ptrCast(@alignCast(response.ctx));

    const is_pending_root = self._page._state == .pending;

    const response_url = response.url();
    if (std.mem.eql(u8, response_url, self.url) == false) {
        // would be different than self.url in the case of a redirect
        self.url = try self.arena.dupeZ(u8, response_url);
        const url_origin = try URL.getOrigin(self.arena, self.url);
        try self.applySandboxOrigin(url_origin);
    }

    // After any redirect, drop the original method/body/header so a later
    // Page.reload doesn't re-POST form data to the redirect target. Conservative
    // default — 307/308 technically preserve the method per RFC 7231, but
    // resubmitting form data is the more dangerous failure mode.
    if ((response.redirectCount() orelse 0) > 0) {
        if (self._navigated_options) |*no| {
            no.method = .GET;
            no.body = null;
            no.header = null;
        }
    }

    self.window._location = try Location.init(self.url, self);
    self.document._location = self.window._location;

    const status = response.status() orelse {
        log.warn(.frame, "navigate header missing status", .{ .url = self.url, .type = self._type });
        // Clients block on Page.navigate until ack or error — never leave cdp_id hanging.
        self.completePendingCdpNavigateFailureMsg("net::ERR_EMPTY_RESPONSE");
        return false;
    };
    // status==0 is a curl "no valid HTTP status" ghost (ebay hang class). Real
    // 4xx/5xx document responses still carry HTML error/challenge pages and
    // must proceed like Chrome — rejecting them stranded Page.navigate (SO 403).
    if (status == 0) {
        const protocol: ?[]const u8 = switch (response.inner) {
            .transfer => |t| if (t.response_header) |rh| rh.protocol() else null,
            else => null,
        };
        log.warn(.frame, "navigate header bad status", .{
            .url = self.url,
            .status = status,
            .type = self._type,
            .protocol = protocol,
        });
        self.completePendingCdpNavigateFailureMsg("net::ERR_EMPTY_RESPONSE");
        return false;
    }
    if (status < 200 or status > 299) {
        // Navigable error document (403 challenge, 404, 5xx HTML, …).
        log.info(.frame, "navigate non-2xx document", .{
            .url = self.url,
            .status = status,
            .type = self._type,
            .content_type = response.contentType(),
        });
    }
    if (comptime IS_DEBUG) {
        log.debug(.frame, "navigate header", .{
            .url = self.url,
            .status = status,
            .content_type = response.contentType(),
            .type = self._type,
        });
    }

    self.window._performance.recordResponseStart();
    const nav_xfer: f64 = blk: {
        if (response.contentLength()) |cl| {
            const n = @as(f64, @floatFromInt(cl));
            // Navigation Timing transferSize is wire bytes (headers + encoded body),
            // not decoded HTML length. CDP route.fulfill / Google sei ≈ 376.
            if (n > 0 and n <= 4096) break :blk n;
        }
        break :blk 376;
    };
    self.window._performance.ensureNavigationTimingEntry(self.url, nav_xfer, self) catch |err| {
        log.warn(.frame, "navigation timing entry", .{ .err = err, .url = self.url });
    };
    if (!self.loadedProfile().isFirefox()) {
        const rs = self.window._performance._timing.response_start;
        self.window._chrome.recordResponseCommit(rs);
    }

    var accept_iter = response.headerIterator();
    try self._session.processAcceptClientHints(response.url(), &accept_iter);

    self.content_security_policy = null;
    self.referrer_policy = .@"strict-origin-when-cross-origin";
    var hdr_it = response.headerIterator();
    while (hdr_it.next()) |hdr| {
        if (std.ascii.eqlIgnoreCase(hdr.name, "content-security-policy")) {
            self.content_security_policy = ContentSecurityPolicy.Policy.parse(self.arena, hdr.value) catch null;
        } else if (std.ascii.eqlIgnoreCase(hdr.name, "referrer-policy")) {
            self.referrer_policy = ReferrerPolicy.Policy.parse(hdr.value);
        }
    }

    if (self._navigated_options) |_| {
        // _navigated_options will be null in special short-circuit cases, like
        // "navigating" to about:blank, in which case this notification has
        // already been sent
        self.markRealmReadyForPublication();

        // Subframe: headers are the publication point — drain microtasks queued
        // while the realm was `.initializing` (Turnstile iframes). Defer: a
        // synchronous checkpoint from this HTTP callback imbalances V8 context
        // Enter/Exit when another realm is mid-dispatch.
        if (self.parent != null) {
            self.scheduleDeferredMacrotaskPump(0) catch |err| {
                log.warn(.frame, "defer subframe microtask drain", .{ .err = err });
            };
        }

        // Commit point for a pending root navigation. Publish only after the
        // pending frame has final URL/origin/location and is marked realm-ready;
        // CDP frame_created/contextCreated/new-document observers must never
        // see the initializing realm.
        if (is_pending_root) {
            const session = self._session;
            // Re-entrancy guard: if the currently active page has JS on the
            // V8 stack (the caller chain is JS -> fetch() -> HttpClient.request
            // -> perform -> processMessages -> headerCallback -> us),
            // committing now would destroy that V8 context and abortFrame
            // would kill the in-flight JS-initiated transfer. Defer commit
            // (and the protect_from_abort flip + frame_navigated dispatch)
            // until Session.drainDeferredCommit runs at a safe point.
            if (!session.canDestructivelyTeardown(self._frame_id)) {
                session._deferred_commit_pending = true;
                return true;
            }
            // Commit (tears down the old active page) MUST happen while
            // protect_from_abort is still true on this transfer, otherwise
            // the abortFrame inside old Frame.deinit (sharing frame_id with
            // pending) would kill us mid-flight. Flip the flag AFTER commit.
            try session.commitPendingPage();
            // The shield only owns the outgoing-page teardown boundary. Once
            // committed, a newer navigation must be able to abort this stream.
            session.browser.http_client.clearProtectForFrame(self._frame_id);
            if (self.queueFrameNavigatedObserversAfterBody()) {
                return true;
            }
            self.scheduleDeferredFrameNavigated() catch |err| {
                log.warn(.frame, "defer frame_navigated after pending commit", .{ .err = err });
            };
            return true;
        }

        // Non-pending-root path: the page is already active, no commit needed,
        // just notify observers.
        if (self.queueFrameNavigatedObserversAfterBody()) return true;
        self.scheduleDeferredFrameNavigated() catch |err| {
            log.warn(.frame, "defer frame_navigated", .{ .err = err });
        };
    }

    return true;
}

// Finishes a pending root navigation: commit the pending Page (promote it to
// active, tearing down the old active), clear protect_from_abort on the
// in-flight navigation transfer (so future abortFrame calls behave normally),
// and emit the frame_navigated notification. Called immediately from
// frameHeaderDoneCallback for the safe (non-reentrant) path, and from
// Session.drainDeferredCommit when the original commit was deferred due to
// re-entrant perform inside JS-initiated HTTP.
pub fn finalizePendingRootCommit(self: *Frame) !void {
    const session = self._session;
    try session.commitPendingPage();
    // In the deferred path we no longer hold `response`, so look the transfer
    // up by frame_id. Idempotent when called twice (immediate path already
    // cleared the flag before calling us).
    session.browser.http_client.clearProtectForFrame(self._frame_id);
    if (self._navigated_options != null) {
        if (!self.queueFrameNavigatedObserversAfterBody()) {
            self.scheduleDeferredFrameNavigated() catch |err| {
                log.warn(.frame, "defer frame_navigated after finalize commit", .{ .err = err });
            };
        }
    }
}

/// CDP Page.navigate: ack at header time, contextCreated after body completes.
fn queueFrameNavigatedObserversAfterBody(self: *Frame) bool {
    const had_cdp = if (self._navigated_options) |no| no.cdp_id != null else false;
    if (!had_cdp) return false;
    self.sendCdpNavigateAckIfPending();
    self._pending_frame_navigated_observers = true;
    return true;
}

fn flushPendingFrameNavigatedObservers(self: *Frame) void {
    if (!self._pending_frame_navigated_observers) return;
    self._pending_frame_navigated_observers = false;
    self.dispatchFrameNavigated();
    self._session.browser.http_client.serviceInboundCdpIfReadable();
}

/// Page.navigate clients block on the command result. Emit it from the header
/// callback; defer contextCreated / frameNavigated observer work.
fn sendCdpNavigateAckIfPending(self: *Frame) void {
    const cdp_id = if (self._navigated_options) |no| no.cdp_id else null;
    if (cdp_id) |id| {
        self._session.notification.dispatch(.frame_navigate_ack, &.{
            .cdp_id = id,
            .frame_id = self._frame_id,
            .loader_id = self._loader_id,
        });
        if (self._navigated_options) |*no| no.cdp_id = null;
        self._session.browser.http_client.serviceInboundCdpIfReadable();
    }
}

/// Emit frame_navigated on the next scheduler turn. Never call
/// `dispatchFrameNavigated` synchronously from HTTP header callbacks — CDP
/// `contextCreated` runs JS while curl may still be on the stack and races
/// scheduled postMessage / microtask work (V8 DisallowJavascriptExecutionScope).
pub fn scheduleDeferredFrameNavigated(self: *Frame) !void {
    if (self._deferred_frame_navigated_scheduled) return;
    if (self._navigated_options == null) return;
    self._deferred_frame_navigated_scheduled = true;

    const arena = try self.getArena(.tiny, "Frame.deferNavigated");
    errdefer self.releaseArena(arena);

    const callback = try arena.create(DeferFrameNavigatedCallback);
    callback.* = .{ .frame = self, .arena = arena };

    try self.js.scheduler.add(callback, DeferFrameNavigatedCallback.run, 0, .{
        .name = "Frame.deferNavigated",
        .low_priority = false,
        .finalizer = DeferFrameNavigatedCallback.cancelled,
    });
}

const DeferFrameNavigatedCallback = struct {
    frame: *Frame,
    arena: Allocator,

    fn cancelled(ctx: *anyopaque) void {
        const self: *DeferFrameNavigatedCallback = @ptrCast(@alignCast(ctx));
        self.frame._deferred_frame_navigated_scheduled = false;
        self.frame.releaseArena(self.arena);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DeferFrameNavigatedCallback = @ptrCast(@alignCast(ctx));
        defer {
            self.frame._deferred_frame_navigated_scheduled = false;
            self.frame.releaseArena(self.arena);
        }
        self.frame.dispatchFrameNavigated();
        return null;
    }
};

fn dispatchFrameNavigated(self: *Frame) void {
    const no = self._navigated_options orelse return;
    self._session.notification.dispatch(.frame_navigated, &.{
        .opts = no,
        .url = self.url,
        .req_id = self._req_id,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .timestamp = timestamp(.monotonic),
    });
}

fn frameDataCallback(response: HttpClient.Response, data: []const u8) !void {
    var self: *Frame = @ptrCast(@alignCast(response.ctx));

    if (self._parse_state == .pre) {
        // we lazily do this, because we might need the first chunk of data
        // to sniff the content type
        var mime: Mime = blk: {
            if (response.contentType()) |ct| {
                break :blk try Mime.parse(ct);
            }
            break :blk Mime.sniff(data);
        } orelse .unknown;

        // If the HTTP Content-Type header didn't specify a charset and this is HTML,
        // prescan the first 1024 bytes for a <meta charset> declaration.
        if (mime.content_type == .text_html and mime.is_default_charset) {
            if (Mime.prescanCharset(data)) |charset| {
                if (charset.len <= 40) {
                    @memcpy(mime.charset[0..charset.len], charset);
                    mime.charset[charset.len] = 0;
                    mime.charset_len = charset.len;
                }
            }
        }

        if (comptime IS_DEBUG) {
            log.debug(.frame, "navigate first chunk", .{
                .content_type = mime.content_type,
                .len = data.len,
                .type = self._type,
                .url = self.url,
            });
        }

        switch (mime.content_type) {
            .text_html, .text_xml => {
                // Normalize and store the charset using encoding_rs canonical names
                const charset_str = mime.charsetString();
                const info = h5e.encoding_for_label(charset_str.ptr, charset_str.len);
                if (info.isValid()) {
                    self.charset = info.name();
                }
                self._parse_state = .{ .html = .{
                    .buffer = .empty,
                    .arena = try self.getArena(.large, "Frame.navigate"),
                    .as_xml = mime.content_type == .text_xml,
                } };
            },
            .application_json, .text_javascript, .text_css, .text_plain => {
                var arr: std.ArrayList(u8) = .empty;
                try arr.appendSlice(self.arena, "<html><head><meta charset=\"utf-8\"></head><body><pre>");
                self._parse_state = .{ .text = arr };
            },
            .image_jpeg, .image_gif, .image_png, .image_webp => {
                self._parse_state = .{ .image = .empty };
            },
            else => self._parse_state = .{ .raw = .empty },
        }
    }

    switch (self._parse_state) {
        .html => |*html| try html.buffer.appendSlice(html.arena, data),
        .text => |*buf| {
            // we have to escape the data...
            var v = data;
            while (v.len > 0) {
                const index = std.mem.indexOfAnyPos(u8, v, 0, &.{ '<', '>' }) orelse {
                    return buf.appendSlice(self.arena, v);
                };
                try buf.appendSlice(self.arena, v[0..index]);
                switch (v[index]) {
                    '<' => try buf.appendSlice(self.arena, "&lt;"),
                    '>' => try buf.appendSlice(self.arena, "&gt;"),
                    else => unreachable,
                }
                v = v[index + 1 ..];
            }
        },
        .raw, .image => |*buf| try buf.appendSlice(self.arena, data),
        .pre => unreachable,
        .deferred_html => unreachable,
        .complete => unreachable,
        .err => unreachable,
        .raw_done => unreachable,
    }
}

fn navDeliverable(self: *const Frame) bool {
    if (self._detach_pending) return false;
    if (self._realm_state == .dead or self._realm_state == .draining) return false;
    if (self.isGoingAway()) return false;
    const current: RealmLifecycleKernel.TaskOwner = .{
        .realm_id = self._frame_id,
        .epoch = self._realm_epoch,
        .document_id = self._loader_id,
    };
    return !RealmLifecycleKernel.taskOwnerIsStale(self._nav_task_owner, current);
}

fn frameDoneCallback(ctx: *anyopaque) !void {
    var self: *Frame = @ptrCast(@alignCast(ctx));
    if (!navDeliverable(self)) return;

    // Body has fully arrived (or the transfer ended). Safe to drop the pending-
    // root abort shield that protected this document hop through commitPendingPage.
    self._session.browser.http_client.clearProtectForFrame(self._frame_id);

    log.debug(.frame, "navigate done", .{ .type = self._type, .url = self.url, .state = std.meta.activeTag(self._parse_state) });

    // Empty body stays `.pre` and is handled in the switch below (blank HTML +
    // documentIsComplete). Pending-root may retry once when HTML was expected.
    if (self._parse_state == .pre) {
        log.warn(.frame, "navigate empty document body", .{ .url = self.url, .type = self._type });
        if (self._page._state == .pending and retryPendingRootNavigation(self)) return;
    }

    // Session history belongs to a browsing context. Root Documents retain the
    // Session store across replacement realms; nested contexts use their
    // Window-owned store and must never publish entries into the root stack.
    log.debug(.frame, "commit navigation start", .{ .type = self._type, .url = self.url });
    try self.navigationStore().commitNavigation(self);
    log.debug(.frame, "commit navigation done", .{ .type = self._type, .url = self.url });

    defer if (comptime IS_DEBUG) {
        log.debug(.frame, "frame load complete", .{
            .url = self.url,
            .type = self._type,
            .state = std.meta.activeTag(self._parse_state),
        });
    };

    if (self._parse_state == .html) {
        const html = self._parse_state.takeHtmlForDeferred().?;
        const raw_html = html.buffer.items;
        const as_xml = html.as_xml;
        const html_arena = html.arena;
        self._session.browser.http_client.serviceInboundCdpIfReadable();
        self.flushPendingFrameNavigatedObservers();
        if (!navDeliverable(self)) {
            self._parse_state = .{ .html = html };
            return;
        }

        // HTML tree construction may synchronously encounter a classic external
        // parser-blocking script. Never enter the parser from curl's document
        // completion callback: libcurl cannot start the nested script transfer
        // there, and demoting that script to async violates parser ordering.
        // One deferred parse lifecycle for every document keeps the transfer
        // callback, parser, and script-fetch ownership boundaries explicit.
        log.debug(.frame, "parse html deferred", .{ .type = self._type, .url = self.url, .len = raw_html.len });
        self.scheduleDeferredDocumentParse(raw_html, as_xml, html_arena) catch |err| {
            log.warn(.frame, "defer document parse", .{ .err = err, .url = self.url });
            // Scheduling did not take ownership. Restore the response state so
            // teardown (or a later retry) remains its single terminal owner.
            self._parse_state = .{ .html = html };
            return;
        };
        // Do NOT pump here: frameDoneCallback runs inside HttpClient transfer
        // callbacks (curl multi / processMessages). Large document parse + CSSOM
        // registration (StyleSheetList) on that stack after Google knitsail re-nav
        // SIGSEGV'd in ArrayList growth (Google Search → Bing). Schedule only;
        // leaveTransferCallback / Runner.drainDeferredDocumentParse run parse once
        // transfer callbacks fully unwind.
        return;
    }

    const parse_arena = try self.getArena(.medium, "Frame.parse");
    defer self.releaseArena(parse_arena);

    var parser = Parser.init(parse_arena, self.document.asNode(), self);

    switch (self._parse_state) {
        .html => unreachable,
        .deferred_html => unreachable,
        .text => |*buf| {
            try buf.appendSlice(self.arena, "</pre></body></html>");
            parser.parse(buf.items);
            // Text responses (JSON, plain text, CSS and JavaScript) have no
            // document lifecycle to wait for. Once the synthetic preview
            // document is parsed, mark the transfer terminal so Runner does
            // not consume the full wait window for an already-complete body.
            self._parse_state = .{ .raw_done = buf.items };
            self.documentIsComplete();
        },
        .image => |buf| {
            self._parse_state = .{ .raw_done = buf.items };

            // Use empty an HTML containing the image.
            const html = try std.mem.concat(parse_arena, u8, &.{
                "<html><head><meta charset=\"utf-8\"></head><body><img src=\"",
                self.url,
                "\"></body></html>",
            });
            parser.parse(html);
            self.documentIsComplete();
        },
        .raw => |buf| {
            self._parse_state = .{ .raw_done = buf.items };

            // Use empty an empty HTML document.
            parser.parse("<html><head><meta charset=\"utf-8\"></head><body></body></html>");
            self.documentIsComplete();
        },
        .pre => {
            // Received a response without a body like: https://httpbin.io/status/200
            // We assume we have received an OK status (checked in Client.headerCallback)
            // so we load a blank document to navigate away from any prior frame.
            self._parse_state = .{ .complete = {} };

            // Use empty an empty HTML document.
            parser.parse("<html><head><meta charset=\"utf-8\"></head><body></body></html>");
            self.documentIsComplete();
        },
        .err => |err| {
            // A network error is not an HTTP response body. Browsers create an
            // internal error Document for it; feeding synthetic markup back
            // through the response parser can reuse a partially initialized
            // TreeSink and make html5ever ask for element data on the Document
            // handle. Construct the internal document directly instead.
            try self.buildNavigationErrorDocument(err);
            self._parse_state = .complete;
            self.documentIsComplete();
        },
        else => unreachable,
    }
}

fn buildNavigationErrorDocument(self: *Frame, err: anyerror) !void {
    self.clearDocumentChildren();

    const html = try self.createElementNS(.html, "html", null);
    const head = try self.createElementNS(.html, "head", null);
    const body = try self.createElementNS(.html, "body", null);
    const heading = try self.createElementNS(.html, "h1", null);
    const reason = try self.createElementNS(.html, "p", null);

    try self.appendInternalDocumentNode(self.document.asNode(), html);
    try self.appendInternalDocumentNode(html, head);
    try self.appendInternalDocumentNode(html, body);
    try self.appendInternalDocumentNode(body, heading);
    try self.appendInternalDocumentNode(heading, try self.createTextNode("Navigation failed"));
    try self.appendInternalDocumentNode(body, reason);
    try self.appendInternalDocumentNode(reason, try self.createTextNode("Reason: "));
    try self.appendInternalDocumentNode(reason, try self.createTextNode(@errorName(err)));

    try self.nodeComplete(head);
    try self.nodeComplete(heading);
    try self.nodeComplete(reason);
    try self.nodeComplete(body);
    try self.nodeComplete(html);
}

fn appendInternalDocumentNode(self: *Frame, parent: *Node, child: *Node) !void {
    try self._insertNodeRelative(true, parent, child, .append, .{
        .child_already_connected = false,
    });
}

fn completePendingCdpNavigateFailure(self: *Frame, err: anyerror) void {
    self.completePendingCdpNavigateFailureMsg(@errorName(err));
}

fn completePendingCdpNavigateFailureMsg(self: *Frame, message: []const u8) void {
    const cdp_id = if (self._navigated_options) |no| no.cdp_id else null;
    if (cdp_id) |id| {
        self._session.notification.dispatch(.frame_navigation_failed, &.{
            .cdp_id = id,
            .message = message,
        });
        if (self._navigated_options) |*no| no.cdp_id = null;
    }
}

fn retryPendingRootNavigation(self: *Frame) bool {
    if (self.parent != null) return false;
    const session = self._session;
    if (session._pending_root_nav_retries >= 2) return false;
    const no = self._navigated_options orelse return false;

    const frame_id = self._frame_id;
    const cdp_id = no.cdp_id;
    const reason = no.reason;
    const method = no.method;
    const kind: NavigationKind = session.navigation._current_navigation_kind orelse .{ .push = null };

    // Snapshot inputs before discardPendingPage frees the pending frame arena.
    const url_copy = session.arena.dupeZ(u8, self.url) catch |err| {
        log.warn(.frame, "navigate retry url dup", .{ .err = err, .url = self.url });
        return false;
    };
    const body_copy: ?[]const u8 = if (no.body) |b| session.arena.dupe(u8, b) catch |err| {
        log.warn(.frame, "navigate retry body dup", .{ .err = err });
        return false;
    } else null;
    const header_copy: ?[:0]const u8 = if (no.header) |h| blk: {
        const dup = session.arena.dupeZ(u8, h) catch |err| {
            log.warn(.frame, "navigate retry header dup", .{ .err = err });
            return false;
        };
        break :blk dup;
    } else null;

    session._pending_root_nav_retries += 1;
    const attempt = session._pending_root_nav_retries;
    session.discardPendingPage();

    const nav_opts = NavigateOpts{
        .cdp_id = cdp_id,
        .reason = reason,
        .method = method,
        .body = body_copy,
        .header = header_copy,
        .kind = kind,
        .is_document_retry = true,
    };
    session.initiateRootNavigation(frame_id, url_copy, nav_opts) catch |retry_err| {
        log.warn(.frame, "navigate retry", .{ .err = retry_err, .url = url_copy, .attempt = attempt });
        return false;
    };
    return true;
}

fn frameErrorCallback(ctx: *anyopaque, err: anyerror) void {
    var self: *Frame = @ptrCast(@alignCast(ctx));
    if (!navDeliverable(self)) return;
    if (err == error.Abort) {
        if (self._page._state == .pending) {
            if (!retryPendingRootNavigation(self)) {
                // Retries exhausted (or non-retryable): always resolve Page.navigate.
                self.completePendingCdpNavigateFailure(err);
                self._session.discardPendingPage();
            }
            return;
        }
        // Active-page abort that still holds a CDP id (header never acked).
        self.completePendingCdpNavigateFailure(err);
        return;
    }

    log.err(.frame, "navigate failed", .{ .err = err, .type = self._type, .url = self.url });

    // A pending root navigation that failed before commit: discard the
    // pending Page; the OLD active Page (and its V8 context) is untouched.
    // We do NOT run frameDoneCallback against the pending frame — the frame
    // is about to be freed. Must still complete CDP or clients hang 12–45s
    // (stackoverflow.com 403 → WriteError was this class).
    if (self._page._state == .pending) {
        self.completePendingCdpNavigateFailure(err);
        self._session.discardPendingPage();
        return;
    }

    // Active page: still free any stranded CDP navigate promise before error HTML.
    self.completePendingCdpNavigateFailure(err);

    // A failed child-frame navigation does not replace an already committed
    // Document with a synthetic error page. Besides matching browser behavior,
    // parsing a second document into the existing tree violates html5ever's
    // TreeSink contract (the document container has no element data).
    if (self.parent != null) {
        self._parse_state.deinit(self);
        self._parse_state = .{ .complete = {} };
        self.documentIsComplete();
        return;
    }

    self._parse_state.deinit(self);
    self._parse_state = .{ .err = err };

    // In case of error, we want to complete the frame with a custom HTML
    // containing the error.
    frameDoneCallback(ctx) catch |e| {
        log.err(.browser, "frameErrorCallback", .{ .err = e, .type = self._type, .url = self.url });
        return;
    };
}
pub fn isGoingAway(self: *const Frame) bool {
    if (self._queued_navigation != null) {
        return true;
    }
    const parent = self.parent orelse return false;
    return parent.isGoingAway();
}

pub fn scriptAddedCallback(self: *Frame, comptime from_parser: bool, script: *Element.Html.Script) !void {
    if (self.isGoingAway()) {
        // if we're planning on navigating to another frame, don't run this script
        return;
    }

    if (IFrameSandbox.blocksScripts(self.iframeSandboxFlags())) {
        return;
    }

    if (comptime from_parser) {
        // parser-inserted scripts have force-async set to false, but only if
        // they have src or non-empty content
        // html5ever populates the DOM attribute directly; `_src` is primarily
        // updated by the IDL setter. Inspect both representations so parser-
        // inserted external scripts do not retain the dynamic-script force-
        // async flag and lose parser-blocking/defer ordering.
        const has_src = script._src.len > 0 or blk: {
            const src = script.asElement().getAttributeSafe(comptime .wrap("src")) orelse break :blk false;
            break :blk src.len > 0;
        };
        if (has_src or script.asNode().firstChild() != null) {
            script._force_async = false;
        }
    }

    self._script_manager.addFromElement(from_parser, script, "parsing") catch |err| {
        log.err(.frame, "frame.scriptAddedCallback", .{
            .err = err,
            .url = self.url,
            .src = script.asElement().getAttributeSafe(comptime .wrap("src")),
            .type = self._type,
        });
    };
}

fn clearDocumentChildren(self: *Frame) void {
    const doc_node = self.document.asNode();
    while (doc_node.firstChild()) |child| {
        self.removeNode(doc_node, child, .{ .will_be_reconnected = false });
    }
    self.document._ready_state = .loading;
}

fn loadIframeSrcdoc(self: *Frame, iframe: *IFrame, srcdoc: []const u8) !void {
    const session = self._session;
    const is_first_load = iframe._window == null;

    const child: *Frame = blk: {
        if (iframe._window) |w| break :blk w._frame;

        iframe._executed = true;
        const new_frame = try self.arena.create(Frame);
        const frame_id = session.nextFrameId();

        try Frame.init(new_frame, frame_id, self._page, self);
        errdefer new_frame.deinit();

        self._pending_loads += 1;
        new_frame.iframe = iframe;
        iframe._window = new_frame.window;
        errdefer iframe._window = null;

        try self.child_frames.append(self.arena, new_frame);

        session.notification.dispatch(.frame_child_frame_created, &.{
            .parent_id = self._frame_id,
            .frame_id = new_frame._frame_id,
            .loader_id = new_frame._loader_id,
            .timestamp = timestamp(.monotonic),
        });

        break :blk new_frame;
    };

    if (!is_first_load) {
        iframe._executed = true;
        child._parent_notified = false;
        child._load_state = .parsing;
        clearDocumentChildren(child);
    }

    child.url = "about:srcdoc";
    child.window._location = try Location.init("about:srcdoc", child);
    child.base_url = null;
    child.fallback_base_url = try child.arena.dupeZ(u8, self.base());

    try child.inheritCreatorOrigin(self);

    child._parse_state = .complete;

    if (srcdoc.len == 0) {
        try child.document.injectBlank(child);
        child.markRealmReadyForPublication();
        child.documentIsComplete();
        return;
    }

    const parse_arena = try child.getArena(.medium, "Frame.srcdoc");
    defer child.releaseArena(parse_arena);

    var parser = Parser.init(parse_arena, child.document.asNode(), child);
    parser.parse(srcdoc);
    if (parser.err) |e| {
        log.warn(.frame, "iframe srcdoc parse", .{ .err = e.err });
        if (is_first_load) {
            self._pending_loads -= 1;
            iframe._window = null;
        }
        return error.IFrameLoadError;
    }

    child.markRealmReadyForPublication();
    child.documentIsComplete();

    if (!is_first_load) return;

    const frames_len = self.child_frames.items.len;
    if (frames_len == 1) return;

    if (self.child_frames_sorted == false) return;

    const iframe_a = self.child_frames.items[frames_len - 2].iframe.?;
    const iframe_b = self.child_frames.items[frames_len - 1].iframe.?;

    if (iframe_a.asNode().compareDocumentPosition(iframe_b.asNode()) & 0x04 == 0) {
        self.child_frames_sorted = false;
    }
}

pub fn iframeAddedCallback(self: *Frame, iframe: *IFrame) !void {
    if (self.isGoingAway()) {
        // if we're planning on navigating to another frame, don't load this iframe
        return;
    }
    if (iframe._executed) {
        // html5ever may run nodeComplete (pop) before addAttrsIfMissing sets
        // attributes on void elements like <iframe>. We eagerly navigate to
        // about:blank on the first pass; upgrade once the real src arrives.
        IFrame.Build.complete(iframe.asNode(), self) catch {};
        const src_attr = iframe.asElement().getAttributeSafe(comptime .wrap("src")) orelse "";
        return self._session.upgradeIframeFromAboutBlank(self, iframe, src_attr);
    }

    const srcdoc = iframe.asElement().getAttributeSafe(comptime .wrap("srcdoc")) orelse "";
    if (srcdoc.len > 0) {
        return self.loadIframeSrcdoc(iframe, srcdoc);
    }

    var src = iframe.asElement().getAttributeSafe(comptime .wrap("src")) orelse "";
    if (src.len == 0) {
        src = "about:blank";
    }

    if (iframe._window != null) {
        // This frame is being re-navigated. We need to do this through a
        // scheduleNavigation phase. We can't navigate immediately here, for
        // the same reason that a "root" frame can't immediately navigate:
        // we could be in the middle of a JS callback or something else that
        // doesn't exit the frame to just suddenly go away.
        return self.scheduleNavigation(src, .{
            .reason = .script,
            .kind = .{ .push = null },
        }, .{ .iframe = iframe });
    }

    iframe._executed = true;
    iframe._sync_onload_dispatched = false;
    iframe._sync_load_queued = false;
    const session = self._session;

    const new_frame = try self.arena.create(Frame);
    const frame_id = session.nextFrameId();

    try Frame.init(new_frame, frame_id, self._page, self);
    errdefer new_frame.deinit();

    self._pending_loads += 1;
    new_frame.iframe = iframe;
    iframe._window = new_frame.window;
    errdefer iframe._window = null;

    // Register the child before navigation notifications fire so CDP can
    // resolve frame-scoped events. The DOM-facing contentWindow getter still
    // gates publication on realmReadyForExternalObservers(), so the WindowProxy
    // slot can exist without exposing an initializing realm.
    try self.child_frames.append(self.arena, new_frame);

    // on first load, dispatch frame_created event
    self._session.notification.dispatch(.frame_child_frame_created, &.{
        .parent_id = self._frame_id,
        .frame_id = new_frame._frame_id,
        .loader_id = new_frame._loader_id,
        .timestamp = timestamp(.monotonic),
    });

    // The initial about:blank Document inherits a snapshot of its creator's
    // fallback base URL. Keep that snapshot on the child: resolving against
    // the literal document URL would turn a network-path reference such as
    // `//cdn.example/script.js` into the invalid `about://cdn.example/...`.
    // This mirrors the srcdoc path above and deliberately does not follow a
    // later <base> mutation in the embedding Document.
    if (std.mem.eql(u8, src, "about:blank")) {
        new_frame.fallback_base_url = try new_frame.arena.dupeZ(u8, self.base());
    }

    const url = blk: {
        if (std.mem.eql(u8, src, "about:blank")) {
            break :blk "about:blank"; // navigate will handle this special case
        }
        break :blk try URL.resolve(
            self.call_arena, // ok to use, frame.navigate dupes this
            self.base(),
            src,
            .{ .encoding = self.charset },
        );
    };

    new_frame.navigate(url, .{
        .reason = .initialFrameNavigation,
        // An iframe navigation is initiated by its embedder. Preserve both the
        // serialized referrer and origin used by Fetch Metadata.
        .referer = if (std.mem.startsWith(u8, self.url, "http")) self.url else null,
        .prior_origin = self.origin,
    }) catch |err| {
        log.warn(.frame, "iframe navigate failure", .{ .url = url, .err = err });
        self._pending_loads -= 1;
        iframe._window = null;
        return error.IFrameLoadError;
    };

    // window[N] is based on document order. For now we'll just append the frame
    // at the end of our list and set child_frames_sorted == false. window.getFrame
    // will check this flag to decide if it needs to sort the frames or not.
    // But, we can optimize this a bit. Since we expect frames to often be
    // added in document order, we can do a quick check to see whether the list
    // is sorted or not.
    const frames_len = self.child_frames.items.len;
    if (frames_len == 1) {
        // this is the only frame, it must be sorted.
        return;
    }

    if (self.child_frames_sorted == false) {
        // the list already wasn't sorted, it still isn't
        return;
    }

    // So we added a frame into a sorted list. If this frame is sorted relative
    // to the last frame, it's still sorted
    const iframe_a = self.child_frames.items[frames_len - 2].iframe.?;
    const iframe_b = self.child_frames.items[frames_len - 1].iframe.?;

    if (iframe_a.asNode().compareDocumentPosition(iframe_b.asNode()) & 0x04 == 0) {
        // if b followed a, then & 0x04 = 0x04
        // but since we got 0, it means b does not follow a, and thus our list
        // is no longer sorted.
        self.child_frames_sorted = false;
    }
}

const OpenPopupOpts = struct {
    url: []const u8,
    name: []const u8,
    opener: ?*Window,
};

// Create a new top-level browsing context as a sibling of the root frame.
// The popup shares the Page's arena, factory, and identity map, but has no
// parent and is not attached to the frame tree — it lives in page.popups.
pub fn openPopup(self: *Frame, opts: OpenPopupOpts) !*Frame {
    const page = self._page;
    const session = self._session;

    const resolved_url: [:0]const u8 = blk: {
        if (opts.url.len == 0) {
            break :blk "about:blank";
        }
        if (std.mem.eql(u8, opts.url, "about:blank")) {
            break :blk "about:blank";
        }
        // window.open() encodes-parses url relative to the entry settings object
        // (HTML), not the relevant global passed as `this`.
        const url_base_frame = self.js.getEntryFrame() orelse self;
        const frame_base = base_blk: {
            var frame = url_base_frame;
            while (true) {
                const maybe_base = frame.base();
                if (!std.mem.eql(u8, maybe_base, "about:blank")) {
                    break :base_blk maybe_base;
                }
                frame = frame.parent orelse break :base_blk "";
            }
        };
        break :blk try URL.resolve(self.call_arena, frame_base, opts.url, .{ .always_dupe = true, .encoding = url_base_frame.charset });
    };

    const popup = try page.frame_arena.create(Frame);
    errdefer page.frame_arena.destroy(popup);

    const frame_id = session.nextFrameId();
    try Frame.init(popup, frame_id, page, null);
    errdefer popup.deinit();

    popup.window._opener = opts.opener;
    if (opts.name.len > 0 and
        !std.ascii.eqlIgnoreCase(opts.name, "_blank") and
        !std.ascii.eqlIgnoreCase(opts.name, "_self") and
        !std.ascii.eqlIgnoreCase(opts.name, "_parent") and
        !std.ascii.eqlIgnoreCase(opts.name, "_top"))
    {
        popup.window._name = try page.frame_arena.dupe(u8, opts.name);
    }

    const popup_index = page.popups.items.len;
    try page.popups.append(page.frame_arena, popup);
    // not impossible that navigate adds popups, so remove by index
    errdefer _ = page.popups.swapRemove(popup_index);

    popup.navigate(resolved_url, .{ .reason = .script }) catch |err| {
        log.warn(.frame, "popup navigate failure", .{ .url = resolved_url, .err = err });
        return err;
    };

    return popup;
}

pub fn layoutResolveActive(self: *const Frame) bool {
    return self._layout_resolve_depth > 0;
}

pub fn beginLayoutResolve(self: *Frame) void {
    if (self._layout_resolve_depth == 0) self._layout_observation_start_ns = nanoTimestamp(.monotonic);
    self._layout_resolve_depth +%= 1;
}

pub fn endLayoutResolve(self: *Frame) void {
    if (self._layout_resolve_depth > 0) self._layout_resolve_depth -= 1;
    if (self._layout_resolve_depth == 0 and self._layout_observation_start_ns != 0) {
        self.observeBrowserStage("layout", elapsedMicros(self._layout_observation_start_ns), "measured", "Renderer", "Main");
        self._layout_observation_start_ns = 0;
    }
}

fn elapsedMicros(started: i128) u64 {
    const elapsed = nanoTimestamp(.monotonic) - started;
    if (elapsed <= 0) return 0;
    return @intCast(@divTrunc(elapsed, std.time.ns_per_us));
}

fn observeBrowserStage(self: *Frame, stage: []const u8, duration_us: u64, state: []const u8, process: []const u8, thread: []const u8) void {
    self._session.browser.observeBrowserStage(stage, duration_us, self._frame_id, self._loader_id, state, process, thread);
}

fn observeLifecycle(self: *Frame, stage: []const u8) void {
    self._session.browser.observeLifecycle(stage, self._frame_id, self._loader_id, self.url);
}

pub fn observeLifecycleForRunner(self: *Frame, stage: []const u8) void {
    self.observeLifecycle(stage);
}

/// Called after a top-level layout getter returns. Recovers from leaked depth
/// if a prior V8 native callback did not unwind Zig defers cleanly.
pub fn finishTopLevelLayoutResolve(self: *Frame) void {
    self._layout_resolve_depth = 0;
}

/// Drop cached offsetWidth/height after inline style mutation.
/// Font fingerprint probes reassign `style.fontFamily` on one span and re-read
/// `offsetWidth`. Version-only invalidation is not enough: `syncStyleAttribute`
/// → `setAttribute` → `domChanged` re-aligns `_layout_cache_dom_version` with
/// `version` while the HashMap still holds the pre-mutation sizes.
pub fn invalidateElementLayoutCache(self: *Frame) void {
    // Main-thread style path only (not worker). clearRetainingCapacity is OK here;
    // domChanged avoids it because workers raced HTTP/parser on SERP.
    self._element_layout_cache.clearRetainingCapacity();
    self._layout_cache_dom_version = self.version;
    self._style_manager.invalidateLayoutPropertyCache();
}

pub fn domChanged(self: *Frame) void {
    // Bulk layout reads (offsetWidth chains) must not invalidate mid-resolve.
    if (self.layoutResolveActive()) return;
    self.version += 1;
    // Version-only invalidation: eager HashMap clearRetainingCapacity from V8
    // worker threads raced HTTP/parser threads and segfaulted in metadata init
    // (Google SERP ~800KB hop). Lazy miss via version checks on read paths.
    self._layout_cache_dom_version = self.version;
    self._layout_visibility_cache_version = self.version;
    self._style_manager.invalidateLayoutPropertyCache();

    self.scheduleIntersectionChecks();
}

/// Queue a viewport checkpoint for IntersectionObserver.  DOM mutation and
/// scrolling are both observable geometry changes; keeping this in Frame
/// gives both paths the same stale-realm and coalescing semantics.
pub fn scheduleIntersectionChecks(self: *Frame) void {
    if (self._intersection_check_scheduled) return;

    self._intersection_check_scheduled = true;
    self._intersection_check_task_owner = self.js.execution.captureTaskOwner();
    self.js.queueIntersectionChecks() catch |err| {
        // The flag represents an actually queued checkpoint. If enqueueing
        // fails, leave the observer eligible for the next change.
        self._intersection_check_scheduled = false;
        log.err(.frame, "frame.schedIntersectChecks", .{ .err = err, .type = self._type, .url = self.url });
    };
}

const ElementIdMaps = struct { lookup: *std.StringHashMapUnmanaged(*Element), removed_ids: *std.StringHashMapUnmanaged(void) };

fn getElementIdMap(node: *Node) ?ElementIdMaps {
    // Walk up the tree checking for ShadowRoot and tracking the root
    var current = node;
    while (true) {
        if (current.is(ShadowRoot)) |shadow_root| {
            return .{
                .lookup = &shadow_root._elements_by_id,
                .removed_ids = &shadow_root._removed_ids,
            };
        }

        const parent = current._parent orelse {
            if (current._type == .document) {
                return .{
                    .lookup = &current._type.document._elements_by_id,
                    .removed_ids = &current._type.document._removed_ids,
                };
            }
            // Detached subtrees have no tree-scope ID map. Their IDs become
            // visible when the subtree is connected to a Document or
            // ShadowRoot and the insertion walk registers its descendants.
            return null;
        };

        current = parent;
    }
}

pub fn addElementId(self: *Frame, parent: *Node, element: *Element, id: []const u8) !void {
    var id_maps = getElementIdMap(parent) orelse return;
    const gop = try id_maps.lookup.getOrPut(self.arena, id);
    if (!gop.found_existing) {
        gop.value_ptr.* = element;
        return;
    }

    const existing = gop.value_ptr.*.asNode();
    switch (element.asNode().compareDocumentPosition(existing)) {
        0x04 => gop.value_ptr.* = element,
        else => {},
    }
}

pub fn removeElementId(self: *Frame, element: *Element, id: []const u8) void {
    const node = element.asNode();
    const id_maps = getElementIdMap(node) orelse return;
    self.removeElementIdWithMaps(id_maps, id);
}

pub fn removeElementIdWithMaps(self: *Frame, id_maps: ElementIdMaps, id: []const u8) void {
    if (id_maps.lookup.remove(id)) {
        const owned_id = self.dupeString(id) catch return;
        id_maps.removed_ids.put(self.arena, owned_id, {}) catch |err| {
            log.warn(.frame, "removeElementIdWithMaps", .{ .err = err });
        };
    }
}

pub fn getElementByIdFromNode(self: *Frame, node: *Node, id: []const u8) ?*Element {
    if (node.isConnected() or node.isInShadowTree()) {
        var current = node;
        while (true) {
            if (current.is(ShadowRoot)) |shadow_root| {
                return shadow_root.getElementById(id, self);
            }
            const parent = current._parent orelse {
                if (current._type == .document) {
                    return current._type.document.getElementById(id, self);
                }
                if (IS_DEBUG) {
                    std.debug.assert(false);
                }
                return null;
            };
            current = parent;
        }
    }
    var tw = @import("../dom/TreeWalker.zig").Full.Elements.init(node, .{});
    while (tw.next()) |el| {
        const element_id = el.getAttributeSafe(comptime .wrap("id")) orelse continue;
        if (std.mem.eql(u8, element_id, id)) {
            return el;
        }
    }
    return null;
}

pub fn registerPerformanceObserver(self: *Frame, observer: *PerformanceObserver) !void {
    return self._performance_observers.append(self.arena, observer);
}

pub fn unregisterPerformanceObserver(self: *Frame, observer: *PerformanceObserver) void {
    for (self._performance_observers.items, 0..) |perf_observer, i| {
        if (perf_observer == observer) {
            _ = self._performance_observers.swapRemove(i);
            return;
        }
    }
}

/// Updates performance observers with the new entry.
/// This doesn't emit callbacks but rather fills the queues of observers.
pub fn notifyPerformanceObservers(self: *Frame, entry: *Performance.Entry) !void {
    for (self._performance_observers.items) |observer| {
        if (observer.interested(entry)) {
            observer._entries.append(self.arena, entry) catch |err| {
                log.err(.frame, "notifyPerformanceObservers", .{ .err = err, .type = self._type, .url = self.url });
            };
        }
    }

    try self.schedulePerformanceObserverDelivery();
}

/// Schedules async delivery of performance observer records.
pub fn schedulePerformanceObserverDelivery(self: *Frame) !void {
    // Already scheduled.
    if (self._performance_delivery_scheduled) {
        return;
    }
    self._performance_delivery_scheduled = true;

    return self.js.scheduler.add(
        self,
        struct {
            fn run(_frame: *anyopaque) anyerror!?u32 {
                const frame: *Frame = @ptrCast(@alignCast(_frame));
                frame._performance_delivery_scheduled = false;

                // Dispatch performance observer events.
                for (frame._performance_observers.items) |observer| {
                    if (observer.hasRecords()) {
                        try observer.dispatch(frame);
                    }
                }

                return null;
            }
        }.run,
        0,
        .{ .low_priority = true },
    );
}

pub fn registerMutationObserver(self: *Frame, observer: *MutationObserver) !void {
    observer.acquireRef();
    observer.setObservingFrame(self);
    self._mutation_observers.append(&observer.node);
}

pub fn unregisterMutationObserver(self: *Frame, observer: *MutationObserver) void {
    observer.clearObservingFrame();
    observer.releaseRef(self._page);
    self._mutation_observers.remove(&observer.node);
}

pub fn registerIntersectionObserver(self: *Frame, observer: *IntersectionObserver) !void {
    observer.acquireRef();
    observer._registered_frame = self;
    try self._intersection_observers.append(self.arena, observer);
}

pub fn unregisterIntersectionObserver(self: *Frame, observer: *IntersectionObserver) void {
    // Clear the back-reference even if the registry entry was already
    // detached by frame teardown. This keeps observer.deinit from walking a
    // frame whose registry no longer owns it.
    if (observer._registered_frame == self) observer._registered_frame = null;
    for (self._intersection_observers.items, 0..) |obs, i| {
        if (obs == observer) {
            observer.releaseRef(self._page);
            _ = self._intersection_observers.swapRemove(i);
            return;
        }
    }
}

/// Remove a registry entry without releasing the observer. Used by the
/// observer's terminal deinit path when the final V8 reference is released
/// after the frame-side registration has already become stale.
pub fn detachIntersectionObserver(self: *Frame, observer: *IntersectionObserver) void {
    for (self._intersection_observers.items, 0..) |obs, i| {
        if (obs == observer) {
            _ = self._intersection_observers.swapRemove(i);
            return;
        }
    }
}

fn isIntersectionObserverRegistered(self: *const Frame, observer: *const IntersectionObserver) bool {
    for (self._intersection_observers.items) |registered| {
        if (registered == observer) return true;
    }
    return false;
}

pub fn checkIntersections(self: *Frame) !void {
    if (self._realm_state != .active) return;
    for (self._intersection_observers.items) |observer| {
        try observer.checkIntersections(self);
    }
}

pub fn hasPendingResourceLoadEvents(self: *const Frame) bool {
    return self._to_load_1.items.len != 0 or self._to_load_2.items.len != 0;
}

/// Returns true while a parser-collected `loading="lazy"` image still needs
/// its headless fallback activation task to run. The activation itself is
/// deliberately deferred until after `load`, but it is still work owned by
/// the current navigation and therefore must be visible to `wait_until=done`.
pub fn hasPendingLazyImageActivation(self: *const Frame) bool {
    return self._deferred_lazy_images.items.len != 0 or self._lazy_images_activation_scheduled;
}

pub fn queueLoad(self: *Frame, html: *Element.Html) !void {
    try self._to_load.append(self.arena, .{
        .element = html,
        .task_owner = self.js.execution.captureTaskOwner(),
    });
    if (self._to_load.items.len == 1) {
        try self.js.scheduler.add(self, struct {
            fn cleanup(ctx: *anyopaque) !?u32 {
                const f: *Frame = @ptrCast(@alignCast(ctx));
                try f.dispatchLoad();
                return null;
            }
        }.cleanup, 0, .{ .name = "frame.dispatchLoad" });
    }
}

fn dispatchLoad(self: *Frame) !void {
    const has_dom_load_listener = self._event_manager.has_dom_load_listener;

    // Swap buffers - new additions during dispatch go to the other buffer
    const to_process = self._to_load;
    self._to_load = if (self._to_load == &self._to_load_1)
        &self._to_load_2
    else
        &self._to_load_1;

    // Always dispatch resource `load` (not only when an onload property exists).
    // React/SPAs use addEventListener('load') and re-check complete after the
    // event; skipping the dispatch leaves images unpainted. EventManager is
    // cheap with zero listeners. has_dom_load_listener remains a useful signal
    // for page-level readiness heuristics elsewhere.
    _ = has_dom_load_listener;
    for (to_process.items) |queued| {
        // Resource completion can race a same-Frame document replacement.
        // Elements are document-arena owned, so validate the captured realm /
        // document generation before dereferencing the queued pointer.
        if (self.js.execution.isTaskOwnerStale(queued.task_owner)) {
            continue;
        }
        const event = try Event.initTrusted(comptime .wrap("load"), .{}, self._page);
        try self._event_manager.dispatch(queued.element.asEventTarget(), event);
    }

    to_process.clearRetainingCapacity();
}

pub fn scheduleMutationDelivery(self: *Frame) !void {
    if (self._mutation_delivery_scheduled) {
        return;
    }
    self._mutation_delivery_scheduled = true;
    self._mutation_delivery_task_owner = self.js.execution.captureTaskOwner();
    RealmLifecycleKernel.traceMo("mo.queue", self._frame_id, self._mutation_delivery_task_owner.epoch, self.realmEpoch(), self.realmState());
    try self.js.queueMutationDelivery();
}

pub fn scheduleIntersectionDelivery(self: *Frame) !void {
    if (self._intersection_delivery_scheduled) {
        return;
    }
    self._intersection_delivery_scheduled = true;
    errdefer self._intersection_delivery_scheduled = false;
    self._intersection_delivery_task_owner = self.js.execution.captureTaskOwner();
    try self.js.queueIntersectionDelivery();
}

pub fn scheduleSlotchangeDelivery(self: *Frame) !void {
    if (self._slotchange_delivery_scheduled) {
        return;
    }
    self._slotchange_delivery_scheduled = true;
    self._slotchange_delivery_task_owner = self.js.execution.captureTaskOwner();
    try self.js.queueSlotchangeDelivery();
}

pub fn performScheduledIntersectionChecks(self: *Frame) void {
    if (!self._intersection_check_scheduled) {
        return;
    }
    self._intersection_check_scheduled = false;
    self.checkIntersections() catch |err| {
        log.err(.frame, "frame.schedIntersectChecks", .{ .err = err, .type = self._type, .url = self.url });
    };
}

pub fn deliverIntersections(self: *Frame) void {
    if (!self._intersection_delivery_scheduled) {
        return;
    }
    // Departing realm: IO callbacks must not run — reentrant navigation would
    // disconnect observers while this loop is iterating (tinhte re-nav UAF).
    if (self._realm_state != .active) {
        self._intersection_delivery_scheduled = false;
        return;
    }
    self.js.execution.validateJsEntry(.strict_active, .intersection_delivery) catch {
        self._intersection_delivery_scheduled = false;
        return;
    };
    self._intersection_delivery_scheduled = false;

    // Snapshot: navigation from an IO callback can disconnect observers mid-loop.
    const session = self._session;
    const snapshot_arena = session.getArena(.tiny, "intersection-delivery-snapshot") catch return;
    defer session.releaseArena(snapshot_arena);
    const snapshot = snapshot_arena.dupe(
        *IntersectionObserver,
        self._intersection_observers.items,
    ) catch return;
    for (snapshot) |observer| {
        if (self._realm_state != .active or self._detach_pending or
            self.js.execution.isTaskOwnerStale(self._intersection_delivery_task_owner)) break;
        // A prior callback may disconnect another observer in the snapshot.
        // Do not dereference an observer after its registration ref is gone.
        if (!self.isIntersectionObserverRegistered(observer)) continue;
        observer.deliverEntries(self) catch |err| {
            log.err(.frame, "frame.deliverIntersections", .{ .err = err, .type = self._type, .url = self.url });
        };
    }
}

pub fn deliverMutations(self: *Frame) void {
    if (!self._mutation_delivery_scheduled) {
        return;
    }
    if (self.js.execution.isTaskOwnerStale(self._mutation_delivery_task_owner) or
        self._detach_pending or self._realm_state == .dead)
    {
        self._mutation_delivery_scheduled = false;
        return;
    }
    self.js.execution.validateJsEntry(.allow_draining, .mutation_delivery) catch {
        self._mutation_delivery_scheduled = false;
        return;
    };
    self._mutation_delivery_scheduled = false;

    RealmLifecycleKernel.traceMo("mo.deliver", self._frame_id, null, self.realmEpoch(), self.realmState());

    self._mutation_delivery_depth += 1;
    defer if (!self._mutation_delivery_scheduled) {
        // reset the depth once nothing is left to be scheduled
        self._mutation_delivery_depth = 0;
    };

    if (self._mutation_delivery_depth > 100) {
        log.err(.frame, "frame.MutationLimit", .{ .type = self._type, .url = self.url });
        self._mutation_delivery_depth = 0;
        return;
    }

    var it: ?*std.DoublyLinkedList.Node = self._mutation_observers.first;
    while (it) |node| {
        if (self._detach_pending or self._realm_state == .dead or
            self.js.execution.isTaskOwnerStale(self._mutation_delivery_task_owner)) break;
        // The callback can disconnect/destroy this observer or detach its
        // entire frame. Capture the continuation before entering JavaScript.
        const next = node.next;
        const observer: *MutationObserver = @fieldParentPtr("node", node);
        observer.deliverRecords(self) catch |err| {
            log.err(.frame, "frame.deliverMutations", .{ .err = err, .type = self._type, .url = self.url });
        };
        it = next;
    }
}

/// Drop pending mutation records and reset single-flight delivery flags during teardown.
pub fn clearRealmAsyncDomQueuesForTeardown(self: *Frame) void {
    self.discardAllMutationObserverPendingRecords();
    self._mutation_delivery_scheduled = false;
    self._intersection_check_scheduled = false;
    self._intersection_delivery_scheduled = false;
    self._slotchange_delivery_scheduled = false;
    self._slots_pending_slotchange.clearRetainingCapacity();
}

pub fn discardAllMutationObserverPendingRecords(self: *Frame) void {
    const page = self._page;
    var it: ?*std.DoublyLinkedList.Node = self._mutation_observers.first;
    while (it) |node| : (it = node.next) {
        const observer: *MutationObserver = @fieldParentPtr("node", node);
        observer.clearPendingRecords(page);
    }
}

pub fn deliverSlotchangeEvents(self: *Frame) void {
    if (!self._slotchange_delivery_scheduled) {
        return;
    }
    if (self._detach_pending or self._realm_state == .dead or
        self.js.execution.isTaskOwnerStale(self._slotchange_delivery_task_owner))
    {
        self._slotchange_delivery_scheduled = false;
        return;
    }
    self._slotchange_delivery_scheduled = false;

    // we need to collect the pending slots, and then clear it and THEN exeute
    // the slot change. We do this in case the slotchange event itself schedules
    // more slot changes (which should only be executed on the next microtask)
    const pending = self._slots_pending_slotchange.count();

    var i: usize = 0;
    const session = self._session;
    const snapshot_arena = session.getArena(.tiny, "slotchange-delivery-snapshot") catch |err| {
        log.err(.frame, "deliverSlotchange.arena", .{ .err = err, .type = self._type, .url = self.url });
        return;
    };
    defer session.releaseArena(snapshot_arena);

    var slots = snapshot_arena.alloc(*Element.Html.Slot, pending) catch |err| {
        log.err(.frame, "deliverSlotchange.append", .{ .err = err, .type = self._type, .url = self.url });
        return;
    };

    var it = self._slots_pending_slotchange.keyIterator();
    while (it.next()) |slot| {
        slots[i] = slot.*;
        i += 1;
    }
    self._slots_pending_slotchange.clearRetainingCapacity();

    for (slots) |slot| {
        if (self._detach_pending or self._realm_state == .dead or
            self.js.execution.isTaskOwnerStale(self._slotchange_delivery_task_owner)) break;
        const event = Event.initTrusted(comptime .wrap("slotchange"), .{ .bubbles = true }, self._page) catch |err| {
            log.err(.frame, "deliverSlotchange.init", .{ .err = err, .type = self._type, .url = self.url });
            continue;
        };
        const target = slot.asNode().asEventTarget();
        self._event_manager.dispatch(target, event) catch |err| {
            log.err(.frame, "deliverSlotchange.dispatch", .{ .err = err, .type = self._type, .url = self.url });
        };
    }
}

/// Run network-idle notification checks for this frame and, recursively, its
/// child frames. CDP clients (e.g. puppeteer networkidle0) expect lifecycle
pub fn checkIdleNotifications(self: *Frame, total_http_activity: usize) void {
    switch (self._parse_state) {
        .html, .deferred_html, .complete => {
            if (self._notified_network_almost_idle.check(total_http_activity <= 2)) {
                self.notifyNetworkAlmostIdle();
            }
            if (self._notified_network_idle.check(total_http_activity == 0)) {
                self.notifyNetworkIdle();
            }
        },
        else => {},
    }
    for (self.child_frames.items) |child| {
        child.checkIdleNotifications(total_http_activity);
    }
}

pub fn notifyNetworkIdle(self: *Frame) void {
    assert(self._notified_network_idle == .done, "Frame.notifyNetworkIdle", .{});
    self._session.notification.dispatch(.frame_network_idle, &.{
        .req_id = self._req_id,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .timestamp = timestamp(.monotonic),
    });
    self.observeLifecycle("networkidle");
}

pub fn notifyNetworkAlmostIdle(self: *Frame) void {
    assert(self._notified_network_almost_idle == .done, "Frame.notifyNetworkAlmostIdle", .{});
    self._session.notification.dispatch(.frame_network_almost_idle, &.{
        .req_id = self._req_id,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .timestamp = timestamp(.monotonic),
    });
}

// called from the parser
pub fn appendNew(self: *Frame, parent: *Node, child: Node.NodeOrText) !void {
    // Re-nav mid-parse (pollCdpDuringLongWork → Page.navigate) leaves the
    // outgoing realm draining; do not touch DOM on a departing frame.
    if (self._realm_state != .active) return;
    const node = switch (child) {
        .node => |n| n,
        .text => |txt| blk: {
            // If we're appending this adjacently to a text node, we should merge
            if (parent.lastChild()) |sibling| {
                if (sibling.is(CData.Text)) |tn| {
                    try self.appendParserAdjacentText(tn._proto, txt);
                    return;
                }
            }
            break :blk try self.createTextNode(txt);
        },
    };

    assert(node._parent == null, "Frame.appendNew", .{});
    try self._insertNodeRelative(true, parent, node, .append, .{
        // this opts has no meaning since we're passing `true` as the first
        // parameter, which indicates this comes from the parser, and has its
        // own special processing. Still, set it to be clear.
        .child_already_connected = false,
    });
}

/// Merge parser `AppendText` into an adjacent CharacterData with geometric growth.
///
/// `String.concat` re-allocates `existing+txt` on every call (arena never frees),
/// so large RAWTEXT bodies (style/script) emitted as many small tendrils become
/// O(n²) time and memory. Own a growable heap buffer while parsing instead.
fn appendParserAdjacentText(self: *Frame, cdata: *CData, txt: []const u8) !void {
    if (txt.len == 0) return;
    const existing = cdata._data.str();
    const need = existing.len + txt.len;

    if (need <= 12) {
        cdata._data = try String.concat(self.arena, &.{ existing, txt });
        _ = self._parser_text_cap.remove(cdata);
        return;
    }

    if (self._parser_text_cap.getPtr(cdata)) |cap| {
        if (need <= cap.*) {
            // Buffer is owned by this parse (never interned); extend in place.
            const dest: []u8 = @constCast(existing.ptr)[0..cap.*];
            @memcpy(dest[existing.len..][0..txt.len], txt);
            cdata._data = String.wrap(dest[0..need]);
            return;
        }
        var new_cap = cap.*;
        while (new_cap < need) {
            const doubled = new_cap *% 2;
            if (doubled <= new_cap) {
                new_cap = need;
                break;
            }
            new_cap = doubled;
        }
        const new_buf = try self.arena.alloc(u8, new_cap);
        @memcpy(new_buf[0..existing.len], existing);
        @memcpy(new_buf[existing.len..][0..txt.len], txt);
        cdata._data = String.wrap(new_buf[0..need]);
        cap.* = new_cap;
        return;
    }

    // First growth past SSO (or first merge of a createTextNode heap string).
    // Do not mutate `existing` — it may be interned or a one-shot dupe.
    var new_cap: usize = @max(need * 2, 64);
    if (new_cap < need) new_cap = need;
    const new_buf = try self.arena.alloc(u8, new_cap);
    @memcpy(new_buf[0..existing.len], existing);
    @memcpy(new_buf[existing.len..][0..txt.len], txt);
    cdata._data = String.wrap(new_buf[0..need]);
    try self._parser_text_cap.put(self.arena, cdata, new_cap);
}

fn clearParserTextCaps(self: *Frame) void {
    self._parser_text_cap = .empty;
}

// called from the parser when the node and all its children have been added
pub fn nodeComplete(self: *Frame, node: *Node) !void {
    Node.Build.call(node, "complete", .{ node, self }) catch |err| {
        log.err(.bug, "build.complete", .{ .tag = node.getNodeName(&self.buf), .err = err, .type = self._type, .url = self.url });
        return err;
    };
    return self.nodeIsReady(true, node);
}

// Sets the owner document for a node. Only stores entries for nodes whose owner
// is NOT frame.document to minimize memory overhead.
pub fn setNodeOwnerDocument(self: *Frame, node: *Node, owner: *Document) !void {
    if (owner == self.document) {
        // No need to store if it's the main document - remove if present
        _ = self._node_owner_documents.remove(node);
    } else {
        try self._node_owner_documents.put(self.arena, node, owner);
    }
}

// Recursively sets the owner document for a node and all its descendants
pub fn adoptNodeTree(self: *Frame, node: *Node, old_owner: *Document, new_owner: *Document) !void {
    try self.setNodeOwnerDocument(node, new_owner);

    // Per spec, adopted steps run on each element after its document is set.
    if (node.is(Element)) |el| {
        Element.Html.Custom.invokeAdoptedCallbackOnElement(el, old_owner, new_owner, self);
    }

    var it = node.childrenIterator();
    while (it.next()) |child| {
        try self.adoptNodeTree(child, old_owner, new_owner);
    }
}

pub fn createElementNS(self: *Frame, namespace: Element.Namespace, name: []const u8, attribute_iterator: anytype) !*Node {
    const from_parser = @TypeOf(attribute_iterator) == Parser.AttributeIterator;

    switch (namespace) {
        .html => {
            switch (name.len) {
                1 => switch (name[0]) {
                    'p' => return self.createHtmlElementT(
                        Element.Html.Paragraph,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    'a' => return self.createHtmlElementT(
                        Element.Html.Anchor,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    'b' => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("b"), ._tag = .b },
                    ),
                    'i' => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("i"), ._tag = .i },
                    ),
                    'q' => return self.createHtmlElementT(
                        Element.Html.Quote,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("q"), ._tag = .quote },
                    ),
                    's' => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("s"), ._tag = .s },
                    ),
                    else => {},
                },
                2 => switch (@as(u16, @bitCast(name[0..2].*))) {
                    asUint("br") => return self.createHtmlElementT(
                        Element.Html.BR,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("ol") => return self.createHtmlElementT(
                        Element.Html.OL,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("ul") => return self.createHtmlElementT(
                        Element.Html.UL,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("li") => return self.createHtmlElementT(
                        Element.Html.LI,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("h1") => return self.createHtmlElementT(
                        Element.Html.Heading,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("h1"), ._tag = .h1 },
                    ),
                    asUint("h2") => return self.createHtmlElementT(
                        Element.Html.Heading,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("h2"), ._tag = .h2 },
                    ),
                    asUint("h3") => return self.createHtmlElementT(
                        Element.Html.Heading,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("h3"), ._tag = .h3 },
                    ),
                    asUint("h4") => return self.createHtmlElementT(
                        Element.Html.Heading,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("h4"), ._tag = .h4 },
                    ),
                    asUint("h5") => return self.createHtmlElementT(
                        Element.Html.Heading,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("h5"), ._tag = .h5 },
                    ),
                    asUint("h6") => return self.createHtmlElementT(
                        Element.Html.Heading,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("h6"), ._tag = .h6 },
                    ),
                    asUint("hr") => return self.createHtmlElementT(
                        Element.Html.HR,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("em") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("em"), ._tag = .em },
                    ),
                    asUint("dd") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("dd"), ._tag = .dd },
                    ),
                    asUint("dl") => return self.createHtmlElementT(
                        Element.Html.DList,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("dt") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("dt"), ._tag = .dt },
                    ),
                    asUint("td") => return self.createHtmlElementT(
                        Element.Html.TableCell,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("td"), ._tag = .td },
                    ),
                    asUint("th") => return self.createHtmlElementT(
                        Element.Html.TableCell,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("th"), ._tag = .th },
                    ),
                    asUint("tr") => return self.createHtmlElementT(
                        Element.Html.TableRow,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    else => {},
                },
                3 => switch (@as(u24, @bitCast(name[0..3].*))) {
                    asUint("div") => return self.createHtmlElementT(
                        Element.Html.Div,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("img") => return self.createHtmlElementT(
                        Element.Html.Image,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("nav") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("nav"), ._tag = .nav },
                    ),
                    asUint("del") => return self.createHtmlElementT(
                        Element.Html.Mod,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("del"), ._tag = .del },
                    ),
                    asUint("ins") => return self.createHtmlElementT(
                        Element.Html.Mod,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("ins"), ._tag = .ins },
                    ),
                    asUint("col") => return self.createHtmlElementT(
                        Element.Html.TableCol,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("col"), ._tag = .col },
                    ),
                    asUint("dir") => return self.createHtmlElementT(
                        Element.Html.Directory,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("map") => return self.createHtmlElementT(
                        Element.Html.Map,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("pre") => return self.createHtmlElementT(
                        Element.Html.Pre,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("sub") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("sub"), ._tag = .sub },
                    ),
                    asUint("sup") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("sup"), ._tag = .sup },
                    ),
                    asUint("dfn") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("dfn"), ._tag = .dfn },
                    ),
                    else => {},
                },
                4 => switch (@as(u32, @bitCast(name[0..4].*))) {
                    asUint("span") => return self.createHtmlElementT(
                        Element.Html.Span,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("meta") => return self.createHtmlElementT(
                        Element.Html.Meta,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("link") => return self.createHtmlElementT(
                        Element.Html.Link,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("slot") => return self.createHtmlElementT(
                        Element.Html.Slot,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("html") => return self.createHtmlElementT(
                        Element.Html.Html,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("head") => return self.createHtmlElementT(
                        Element.Html.Head,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("body") => return self.createHtmlElementT(
                        Element.Html.Body,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("form") => return self.createHtmlElementT(
                        Element.Html.Form,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("main") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("main"), ._tag = .main },
                    ),
                    asUint("data") => return self.createHtmlElementT(
                        Element.Html.Data,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("base") => {
                        const n = try self.createHtmlElementT(
                            Element.Html.Base,
                            namespace,
                            attribute_iterator,
                            .{ ._proto = undefined },
                        );

                        // If frames's base url is not already set, fill it with
                        // the base tag.
                        if (self.base_url == null) {
                            if (n.as(Element).getAttributeSafe(comptime .wrap("href"))) |href| {
                                self.base_url = try URL.resolve(self.arena, self.url, href, .{});
                            }
                        }

                        return n;
                    },
                    asUint("menu") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("menu"), ._tag = .menu },
                    ),
                    asUint("area") => return self.createHtmlElementT(
                        Element.Html.Area,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("font") => return self.createHtmlElementT(
                        Element.Html.Font,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("code") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("code"), ._tag = .code },
                    ),
                    asUint("time") => return self.createHtmlElementT(
                        Element.Html.Time,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    else => {},
                },
                5 => switch (@as(u40, @bitCast(name[0..5].*))) {
                    asUint("input") => return self.createHtmlElementT(
                        Element.Html.Input,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("style") => return self.createHtmlElementT(
                        Element.Html.Style,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("title") => return self.createHtmlElementT(
                        Element.Html.Title,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("embed") => return self.createHtmlElementT(
                        Element.Html.Embed,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("audio") => return self.createHtmlMediaElementT(
                        Element.Html.Media.Audio,
                        namespace,
                        attribute_iterator,
                    ),
                    asUint("video") => return self.createHtmlMediaElementT(
                        Element.Html.Media.Video,
                        namespace,
                        attribute_iterator,
                    ),
                    asUint("aside") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("aside"), ._tag = .aside },
                    ),
                    asUint("label") => return self.createHtmlElementT(
                        Element.Html.Label,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("meter") => return self.createHtmlElementT(
                        Element.Html.Meter,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("param") => return self.createHtmlElementT(
                        Element.Html.Param,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("table") => return self.createHtmlElementT(
                        Element.Html.Table,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("thead") => return self.createHtmlElementT(
                        Element.Html.TableSection,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("thead"), ._tag = .thead },
                    ),
                    asUint("tbody") => return self.createHtmlElementT(
                        Element.Html.TableSection,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("tbody"), ._tag = .tbody },
                    ),
                    asUint("tfoot") => return self.createHtmlElementT(
                        Element.Html.TableSection,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("tfoot"), ._tag = .tfoot },
                    ),
                    asUint("track") => return self.createHtmlElementT(
                        Element.Html.Track,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._kind = comptime .wrap("subtitles"), ._ready_state = .none },
                    ),
                    else => {},
                },
                6 => switch (@as(u48, @bitCast(name[0..6].*))) {
                    asUint("script") => return self.createHtmlElementT(
                        Element.Html.Script,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("button") => return self.createHtmlElementT(
                        Element.Html.Button,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("canvas") => return self.createHtmlElementT(
                        Element.Html.Canvas,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("dialog") => return self.createHtmlElementT(
                        Element.Html.Dialog,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._is_modal = false },
                    ),
                    asUint("legend") => return self.createHtmlElementT(
                        Element.Html.Legend,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("object") => return self.createHtmlElementT(
                        Element.Html.Object,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("output") => return self.createHtmlElementT(
                        Element.Html.Output,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("source") => return self.createHtmlElementT(
                        Element.Html.Source,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("strong") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("strong"), ._tag = .strong },
                    ),
                    asUint("header") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("header"), ._tag = .header },
                    ),
                    asUint("footer") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("footer"), ._tag = .footer },
                    ),
                    asUint("select") => return self.createHtmlElementT(
                        Element.Html.Select,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("option") => return self.createHtmlElementT(
                        Element.Html.Option,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("iframe") => return self.createHtmlElementT(
                        IFrame,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("figure") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("figure"), ._tag = .figure },
                    ),
                    asUint("hgroup") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("hgroup"), ._tag = .hgroup },
                    ),
                    else => {},
                },
                7 => switch (@as(u56, @bitCast(name[0..7].*))) {
                    asUint("section") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("section"), ._tag = .section },
                    ),
                    asUint("article") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("article"), ._tag = .article },
                    ),
                    asUint("details") => return self.createHtmlElementT(
                        Element.Html.Details,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("summary") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("summary"), ._tag = .summary },
                    ),
                    asUint("caption") => return self.createHtmlElementT(
                        Element.Html.TableCaption,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("marquee") => return self.createHtmlElementT(
                        Element.Html.Marquee,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("address") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("address"), ._tag = .address },
                    ),
                    asUint("picture") => return self.createHtmlElementT(
                        Element.Html.Picture,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    else => {},
                },
                8 => switch (@as(u64, @bitCast(name[0..8].*))) {
                    asUint("textarea") => return self.createHtmlElementT(
                        Element.Html.TextArea,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("template") => return self.createHtmlElementT(
                        Element.Html.Template,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._content = undefined },
                    ),
                    asUint("colgroup") => return self.createHtmlElementT(
                        Element.Html.TableCol,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("colgroup"), ._tag = .colgroup },
                    ),
                    asUint("fieldset") => return self.createHtmlElementT(
                        Element.Html.FieldSet,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("frameset") => {
                        if (comptime from_parser) {
                            log.warn(.not_implemented, "framset", .{ .note = "<framset>...</frameset> in html is not handled properly" });
                        }
                        return self.createHtmlElementT(
                            Element.Html.FrameSet,
                            namespace,
                            attribute_iterator,
                            .{ ._proto = undefined },
                        );
                    },
                    asUint("optgroup") => return self.createHtmlElementT(
                        Element.Html.OptGroup,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("progress") => return self.createHtmlElementT(
                        Element.Html.Progress,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("datalist") => return self.createHtmlElementT(
                        Element.Html.DataList,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined },
                    ),
                    asUint("noscript") => return self.createHtmlElementT(
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("noscript"), ._tag = .noscript },
                    ),
                    else => {},
                },
                10 => switch (@as(u80, @bitCast(name[0..10].*))) {
                    asUint("blockquote") => return self.createHtmlElementT(
                        Element.Html.Quote,
                        namespace,
                        attribute_iterator,
                        .{ ._proto = undefined, ._tag_name = comptime .wrap("blockquote"), ._tag = .blockquote },
                    ),
                    else => {},
                },
                else => {},
            }
            const tag_name = try String.init(self.arena, name, .{});

            // Check if this is a custom element (must have hyphen for HTML namespace)
            const has_hyphen = std.mem.indexOfScalar(u8, name, '-') != null;
            if (has_hyphen and namespace == .html) {
                const definition = self.window._custom_elements._definitions.get(name);
                const node = try self.createHtmlElementT(Element.Html.Custom, namespace, attribute_iterator, .{
                    ._proto = undefined,
                    ._tag_name = tag_name,
                    ._definition = definition,
                });

                const def = definition orelse {
                    const element = node.as(Element);
                    const custom = element.is(Element.Html.Custom).?;
                    try self._undefined_custom_elements.append(self.arena, custom);
                    return node;
                };

                // Save and restore upgrading element to allow nested createElement calls
                const prev_upgrading = self._upgrading_element;
                self._upgrading_element = node;
                defer self._upgrading_element = prev_upgrading;

                var ls: JS.Local.Scope = undefined;
                self.js.localScope(&ls);
                defer ls.deinit();

                if (from_parser) {
                    // There are some things custom elements aren't allowed to do
                    // when we're parsing.
                    self.document._throw_on_dynamic_markup_insertion_counter += 1;
                }
                defer if (from_parser) {
                    self.document._throw_on_dynamic_markup_insertion_counter -= 1;
                };

                var caught: JS.TryCatch.Caught = undefined;
                _ = ls.toLocal(def.constructor).newInstance(&caught) catch |err| {
                    log.warn(.js, "custom element constructor", .{ .name = name, .err = err, .caught = caught, .type = self._type, .url = self.url });
                    return node;
                };

                // After constructor runs, invoke attributeChangedCallback for initial attributes
                const element = node.as(Element);
                if (element._attributes) |attributes| {
                    var it = attributes.iterator();
                    while (it.next()) |attr| {
                        Element.Html.Custom.invokeAttributeChangedCallbackOnElement(
                            element,
                            attr._name,
                            null, // old_value is null for initial attributes
                            attr._value,
                            null,
                            self,
                        );
                    }
                }

                return node;
            }

            return self.createHtmlElementT(Element.Html.Unknown, namespace, attribute_iterator, .{ ._proto = undefined, ._tag_name = tag_name });
        },
        .svg => {
            const tag_name = try String.init(self.arena, name, .{});
            if (std.ascii.eqlIgnoreCase(name, "svg")) {
                return self.createSvgElementT(Element.Svg, name, attribute_iterator, .{
                    ._proto = undefined,
                    ._type = .svg,
                    ._tag_name = tag_name,
                });
            }

            // Other SVG elements (rect, circle, text, g, etc.)
            const lower = std.ascii.lowerString(&self.buf, name);
            const tag = std.meta.stringToEnum(Element.Tag, lower) orelse .unknown;
            return self.createSvgElementT(Element.Svg.Generic, name, attribute_iterator, .{ ._proto = undefined, ._tag = tag });
        },
        else => {
            const tag_name = try String.init(self.arena, name, .{});
            return self.createHtmlElementT(Element.Html.Unknown, namespace, attribute_iterator, .{ ._proto = undefined, ._tag_name = tag_name });
        },
    }
}

fn createHtmlElementT(self: *Frame, comptime E: type, namespace: Element.Namespace, attribute_iterator: anytype, html_element: E) !*Node {
    const html_element_ptr = try self._factory.htmlElement(html_element);
    const element = html_element_ptr.asElement();
    element._namespace = namespace;
    try self.populateElementAttributes(element, attribute_iterator);

    // Check for customized built-in element via "is" attribute
    try Element.Html.Custom.checkAndAttachBuiltIn(element, self);

    const node = element.asNode();
    if (@hasDecl(E, "Build") and @hasDecl(E.Build, "created")) {
        @call(.auto, @field(E.Build, "created"), .{ node, self }) catch |err| {
            log.err(.frame, "build.created", .{ .tag = node.getNodeName(&self.buf), .err = err, .type = self._type, .url = self.url });
            return err;
        };
    }
    return node;
}

fn createHtmlMediaElementT(self: *Frame, comptime E: type, namespace: Element.Namespace, attribute_iterator: anytype) !*Node {
    const media_element = try self._factory.htmlMediaElement(E{ ._proto = undefined });
    const element = media_element.asElement();
    element._namespace = namespace;
    try self.populateElementAttributes(element, attribute_iterator);
    return element.asNode();
}

fn createSvgElementT(self: *Frame, comptime E: type, tag_name: []const u8, attribute_iterator: anytype, svg_element: E) !*Node {
    const svg_element_ptr = try self._factory.svgElement(tag_name, svg_element);
    var element = svg_element_ptr.asElement();
    element._namespace = .svg;
    try self.populateElementAttributes(element, attribute_iterator);
    return element.asNode();
}

fn populateElementAttributes(self: *Frame, element: *Element, list: anytype) !void {
    if (@TypeOf(list) == ?*Element.Attribute.List) {
        // from cloneNode

        var existing = list orelse return;

        var attributes = try self.arena.create(Element.Attribute.List);
        attributes.* = .{
            .normalize = existing.normalize,
        };

        var it = existing.iterator();
        while (it.next()) |attr| {
            try attributes.putNew(attr._name.str(), attr._value.str(), self);
        }
        element._attributes = attributes;
        return;
    }

    // from the parser
    if (@TypeOf(list) == @TypeOf(null) or list.count() == 0) {
        return;
    }
    var attributes = try element.createAttributeList(self);
    while (list.next()) |attr| {
        try attributes.putNew(attr.name.local.slice(), attr.value.slice(), self);
    }
}

// Called when `new MyElement()` is invoked directly in JS (not via the
// customElements.define/upgrade path). `new_target` is the constructor
// function that was used with `new`. We find the matching definition in the
// registry by function identity and allocate a detached Custom element with
// the registered tag name.
pub fn constructCustomElement(self: *Frame, new_target: JS.Function) !*Element {
    var it = self.window._custom_elements._definitions.iterator();
    const definition = while (it.next()) |entry| {
        if (entry.value_ptr.*.constructor.isEqual(new_target)) {
            break entry.value_ptr.*;
        }
    } else return error.IllegalConstructor;

    if (definition.isCustomizedBuiltIn()) {
        const extends_tag = definition.extends.?;
        const node = try self.createElementNS(.html, customizedBuiltInExtendsName(extends_tag), null);
        const element = node.as(Element);
        try element.setAttribute(comptime .wrap("is"), .wrap(definition.name), self);
        try Element.Html.Custom.attachBuiltInDefinition(element, definition, self, false);
        return element;
    }

    const tag_name = try String.init(self.arena, definition.name, .{});
    const node = try self.createHtmlElementT(Element.Html.Custom, .html, @as(?*Element.Attribute.List, null), .{
        ._proto = undefined,
        ._tag_name = tag_name,
        ._definition = definition,
    });
    return node.as(Element);
}

fn customizedBuiltInExtendsName(tag: Element.Tag) []const u8 {
    return switch (tag) {
        .anchor => "a",
        .directory => "dir",
        .quote => "q",
        else => @tagName(tag),
    };
}

pub fn createTextNode(self: *Frame, text: []const u8) !*Node {
    const cd = try self._factory.node(CData{
        ._proto = undefined,
        ._type = .{ .text = .{
            ._proto = undefined,
        } },
        ._data = try self.dupeSSO(text),
    });
    cd._type.text._proto = cd;
    return cd.asNode();
}

pub fn createComment(self: *Frame, text: []const u8) !*Node {
    const cd = try self._factory.node(CData{
        ._proto = undefined,
        ._type = .{ .comment = .{
            ._proto = undefined,
        } },
        ._data = try self.dupeSSO(text),
    });
    cd._type.comment._proto = cd;
    return cd.asNode();
}

pub fn createCDATASection(self: *Frame, data: []const u8) !*Node {
    // Validate that the data doesn't contain "]]>"
    if (std.mem.indexOf(u8, data, "]]>") != null) {
        return error.InvalidCharacterError;
    }

    // First allocate the Text node separately
    const text_node = try self._factory.create(CData.Text{
        ._proto = undefined,
    });

    // Then create the CData with cdata_section variant
    const cd = try self._factory.node(CData{
        ._proto = undefined,
        ._type = .{ .cdata_section = .{
            ._proto = text_node,
        } },
        ._data = try self.dupeSSO(data),
    });

    // Set up the back pointer from Text to CData
    text_node._proto = cd;

    return cd.asNode();
}

pub fn createProcessingInstruction(self: *Frame, target: []const u8, data: []const u8) !*Node {
    // Validate neither target nor data contain "?>"
    if (std.mem.indexOf(u8, target, "?>") != null) {
        return error.InvalidCharacterError;
    }
    if (std.mem.indexOf(u8, data, "?>") != null) {
        return error.InvalidCharacterError;
    }

    // Validate target follows XML Name production
    try validateXmlName(target);

    const owned_target = try self.dupeString(target);

    const pi = try self._factory.create(CData.ProcessingInstruction{
        ._proto = undefined,
        ._target = owned_target,
    });

    const cd = try self._factory.node(CData{
        ._proto = undefined,
        ._type = .{ .processing_instruction = pi },
        ._data = try self.dupeSSO(data),
    });

    // Set up the back pointer from ProcessingInstruction to CData
    pi._proto = cd;

    return cd.asNode();
}

/// Validate a string against the XML Name production.
/// https://www.w3.org/TR/xml/#NT-Name
fn validateXmlName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidCharacterError;

    var i: usize = 0;

    // First character must be a NameStartChar.
    const first_len = std.unicode.utf8ByteSequenceLength(name[0]) catch
        return error.InvalidCharacterError;
    if (first_len > name.len) return error.InvalidCharacterError;
    const first_cp = std.unicode.utf8Decode(name[0..][0..first_len]) catch
        return error.InvalidCharacterError;
    if (!isXmlNameStartChar(first_cp)) return error.InvalidCharacterError;
    i = first_len;

    // Subsequent characters must be NameChars.
    while (i < name.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(name[i]) catch
            return error.InvalidCharacterError;
        if (i + cp_len > name.len) return error.InvalidCharacterError;
        const cp = std.unicode.utf8Decode(name[i..][0..cp_len]) catch
            return error.InvalidCharacterError;
        if (!isXmlNameChar(cp)) return error.InvalidCharacterError;
        i += cp_len;
    }
}

fn isXmlNameStartChar(c: u21) bool {
    return c == ':' or
        (c >= 'A' and c <= 'Z') or
        c == '_' or
        (c >= 'a' and c <= 'z') or
        (c >= 0xC0 and c <= 0xD6) or
        (c >= 0xD8 and c <= 0xF6) or
        (c >= 0xF8 and c <= 0x2FF) or
        (c >= 0x370 and c <= 0x37D) or
        (c >= 0x37F and c <= 0x1FFF) or
        (c >= 0x200C and c <= 0x200D) or
        (c >= 0x2070 and c <= 0x218F) or
        (c >= 0x2C00 and c <= 0x2FEF) or
        (c >= 0x3001 and c <= 0xD7FF) or
        (c >= 0xF900 and c <= 0xFDCF) or
        (c >= 0xFDF0 and c <= 0xFFFD) or
        (c >= 0x10000 and c <= 0xEFFFF);
}

fn isXmlNameChar(c: u21) bool {
    return isXmlNameStartChar(c) or
        c == '-' or
        c == '.' or
        (c >= '0' and c <= '9') or
        c == 0xB7 or
        (c >= 0x300 and c <= 0x36F) or
        (c >= 0x203F and c <= 0x2040);
}

pub fn dupeString(self: *Frame, value: []const u8) ![]const u8 {
    if (String.intern(value)) |v| {
        return v;
    }
    return self.arena.dupe(u8, value);
}

pub fn registerRtcPeerConnection(self: *Frame, pc: *@import("../webapi/rtc_bindings.zig").RTCPeerConnectionJs) !void {
    try self._rtc_peer_connections.append(self.arena, pc);
}

pub fn unregisterRtcPeerConnection(self: *Frame, pc: *@import("../webapi/rtc_bindings.zig").RTCPeerConnectionJs) void {
    for (self._rtc_peer_connections.items, 0..) |item, i| {
        if (item == pc) {
            _ = self._rtc_peer_connections.swapRemove(i);
            return;
        }
    }
}

pub fn drainRtcEvents(self: *Frame) void {
    if (self._realm_state == .dead or self._realm_state == .draining) return;
    for (self._rtc_peer_connections.items) |pc| {
        pc.drainEvents();
    }
}

pub fn closeRtcPeerConnections(self: *Frame) void {
    const pcs = self._rtc_peer_connections.items;
    var i: usize = pcs.len;
    while (i > 0) {
        i -= 1;
        pcs[i].close();
    }
    self._rtc_peer_connections.clearRetainingCapacity();
}

// Direct (non-propagating) dispatch of an event. Mirrors WorkerGlobalScope.dispatch
// so worker-compatible APIs can uniformly call `global.dispatch(...)` across both
// Frame and Worker contexts.
pub fn dispatch(
    self: *Frame,
    target: *EventTarget,
    event: *Event,
    handler: anytype,
    comptime opts: EventManager.DispatchDirectOptions,
) !void {
    return self._event_manager.dispatchDirect(target, event, handler, opts);
}

pub fn hasDirectListeners(self: *Frame, target: *EventTarget, typ: []const u8, handler: anytype) bool {
    return self._event_manager.hasDirectListeners(target, typ, handler);
}

pub fn dupeSSO(self: *Frame, value: []const u8) !String {
    return String.init(self.arena, value, .{ .dupe = true });
}

const RemoveNodeOpts = struct {
    will_be_reconnected: bool,
};
pub fn removeNode(self: *Frame, parent: *Node, child: *Node, opts: RemoveNodeOpts) void {
    // Capture siblings before removing
    const previous_sibling = child.previousSibling();
    const next_sibling = child.nextSibling();

    // Capture child's index before removal for live range updates (DOM spec remove steps 4-7)
    const child_index_for_ranges: ?u32 = if (self._live_ranges.first != null)
        parent.getChildIndex(child)
    else
        null;

    const children = parent._children.?;

    var iterator_link = self._node_iterators.first;
    while (iterator_link) |link| : (iterator_link = link.next) {
        const iterator: *DOMNodeIterator = @fieldParentPtr("_frame_link", link);
        iterator.preRemovingSteps(child);
    }

    switch (children.*) {
        .one => |n| {
            assert(n == child, "Frame.removeNode.one", .{});
            parent._children = null;
            self._factory.destroy(children);
        },
        .list => |list| {
            list.remove(&child._child_link);

            // Should not be possible to get a child list with a single node.
            // While it doesn't cause any problems, it indicates an bug in the
            // code as these should always be represented as .{.one = node}
            const first = list.first.?;
            if (first.next == null) {
                children.* = .{ .one = Node.linkToNode(first) };
                self._factory.destroy(list);
            }
        },
    }
    // grab this before we null the parent
    const was_connected = child.isConnected();
    // Capture the ID map before disconnecting, so we can remove IDs from the correct document
    const id_maps = if (was_connected) getElementIdMap(child) else null;

    child._parent = null;
    child._child_link = .{};

    // The document base URL is derived from the first connected <base href>.
    // Recompute after detaching a connected subtree that contains a base,
    // including moves whose disconnect lifecycle is otherwise elided.
    if (was_connected and subtreeContainsHtmlBase(child)) {
        self.refreshDocumentBaseAfterMutation();
    }

    // Update live ranges for removal (DOM spec remove steps 4-7)
    if (child_index_for_ranges) |idx| {
        self.updateRangesForNodeRemoval(parent, child, idx);
    }

    // Handle slot assignment removal before mutation observers
    if (child.is(Element)) |el| {
        // Check if the parent was a shadow host
        if (parent.is(Element)) |parent_el| {
            if (self._element_shadow_roots.get(parent_el)) |shadow_root| {
                // Signal slot changes for any affected slots
                const slot_name = el.getAttributeSafe(comptime .wrap("slot")) orelse "";
                var tw = @import("../dom/TreeWalker.zig").Full.Elements.init(shadow_root.asNode(), .{});
                while (tw.next()) |slot_el| {
                    if (slot_el.is(Element.Html.Slot)) |slot| {
                        if (std.mem.eql(u8, slot.getName(), slot_name)) {
                            self.signalSlotChange(slot);
                            break;
                        }
                    }
                }
            }
        }
        // Remove from assigned slot lookup
        _ = self._element_assigned_slots.remove(el);
    }

    if (self.hasMutationObservers()) {
        const removed = [_]*Node{child};
        self.childListChange(parent, &.{}, &removed, previous_sibling, next_sibling);
    }

    if (opts.will_be_reconnected) {
        // We might be removing the node only to re-insert it. If the node will
        // remain connected, we can skip the expensive process of fully
        // disconnecting it.
        return;
    }

    if (was_connected == false) {
        // If the child wasn't connected, then there should be nothing left for
        // us to do
        return;
    }

    // The child was connected and now it no longer is. We need to "disconnect"
    // it and all of its descendants. For now "disconnect" just means updating
    // the ID map and invoking disconnectedCallback for custom elements
    var tw = @import("../dom/TreeWalker.zig").Full.Elements.init(child, .{});
    while (tw.next()) |el| {
        if (el.getAttributeSafe(comptime .wrap("id"))) |id| {
            if (id_maps) |maps| self.removeElementIdWithMaps(maps, id);
        }

        Element.Html.Custom.invokeDisconnectedCallbackOnElement(el, self);

        if (el.is(Element)) |element| {
            element.detachShadowRoot(self);
        }

        if (el.is(IFrame)) |iframe| {
            self.detachChildFrameForIframe(iframe);
        }

        // If a <style> element is being removed, remove its sheet from the list
        if (el.is(Element.Html.Style)) |style| {
            if (style._sheet) |sheet| {
                if (self.document._style_sheets) |sheets| {
                    sheets.remove(sheet);
                }
                style._sheet = null;
            }
            self._style_manager.sheetModified();
        }
    }
}

pub fn appendNode(self: *Frame, parent: *Node, child: *Node, opts: InsertNodeOpts) !void {
    return self._insertNodeRelative(false, parent, child, .append, opts);
}

pub fn appendAllChildren(self: *Frame, parent: *Node, target: *Node) !void {
    self.domChanged();
    const dest_connected = target.isConnected();

    // Use firstChild() instead of iterator to handle cases where callbacks
    // (like custom element connectedCallback) modify the parent during iteration.
    // The iterator captures "next" pointers that can become stale.
    while (parent.firstChild()) |child| {
        // Check if child was connected BEFORE removing it from parent
        const child_was_connected = child.isConnected();
        self.removeNode(parent, child, .{ .will_be_reconnected = dest_connected });
        try self.appendNode(target, child, .{ .child_already_connected = child_was_connected });
    }
}

pub fn insertAllChildrenBefore(self: *Frame, fragment: *Node, parent: *Node, ref_node: *Node) !void {
    self.domChanged();
    const dest_connected = parent.isConnected();

    // Use firstChild() instead of iterator to handle cases where callbacks
    // (like custom element connectedCallback) modify the fragment during iteration.
    // The iterator captures "next" pointers that can become stale.
    while (fragment.firstChild()) |child| {
        // Check if child was connected BEFORE removing it from fragment
        const child_was_connected = child.isConnected();
        self.removeNode(fragment, child, .{ .will_be_reconnected = dest_connected });
        // A callback fired by a previous iteration's insert (e.g. a custom
        // element's connectedCallback) may have detached ref_node from
        // parent. In that case, fall back to append so the remaining
        // children still land in `parent` in source order.
        if (ref_node._parent == parent) {
            try self.insertNodeRelative(
                parent,
                child,
                .{ .before = ref_node },
                .{ .child_already_connected = child_was_connected },
            );
        } else {
            try self.appendNode(
                parent,
                child,
                .{ .child_already_connected = child_was_connected },
            );
        }
    }
}

const InsertNodeRelative = union(enum) {
    append,
    after: *Node,
    before: *Node,
};
const InsertNodeOpts = struct {
    child_already_connected: bool = false,
    adopting_to_new_document: bool = false,
};
pub fn insertNodeRelative(self: *Frame, parent: *Node, child: *Node, relative: InsertNodeRelative, opts: InsertNodeOpts) !void {
    return self._insertNodeRelative(false, parent, child, relative, opts);
}
pub fn _insertNodeRelative(self: *Frame, comptime from_parser: bool, parent: *Node, child: *Node, relative: InsertNodeRelative, opts: InsertNodeOpts) !void {
    // caller should have made sure this was the case

    assert(child._parent == null, "Frame.insertNodeRelative parent", .{});

    const children = blk: {
        // expand parent._children so that it can take another child
        if (parent._children) |c| {
            switch (c.*) {
                .list => {},
                .one => |node| {
                    const list = try self._factory.create(std.DoublyLinkedList{});
                    list.append(&node._child_link);
                    c.* = .{ .list = list };
                },
            }
            break :blk c;
        } else {
            const Children = @import("../webapi/children.zig").Children;
            const c = try self._factory.create(Children{ .one = child });
            parent._children = c;
            break :blk c;
        }
    };

    switch (relative) {
        .append => switch (children.*) {
            .one => {}, // already set in the expansion above
            .list => |list| list.append(&child._child_link),
        },
        .after => |ref_node| {
            // caller should have made sure this was the case
            assert(ref_node._parent.? == parent, "Frame.insertNodeRelative after", .{ .url = self.url });
            // if ref_node is in parent, and expanded _children above to
            // accommodate another child, then `children` must be a list
            children.list.insertAfter(&ref_node._child_link, &child._child_link);
        },
        .before => |ref_node| {
            // caller should have made sure this was the case
            assert(ref_node._parent.? == parent, "Frame.insertNodeRelative before", .{ .url = self.url });
            // if ref_node is in parent, and expanded _children above to
            // accommodate another child, then `children` must be a list
            children.list.insertBefore(&ref_node._child_link, &child._child_link);
        },
    }
    child._parent = parent;

    // Dynamic insertion can change which <base href> is first in tree order.
    // Parser-created base elements are handled while constructing the initial
    // document; this path covers DOM and fragment insertions into a live tree.
    if (comptime !from_parser) {
        if (parent.isConnected() and subtreeContainsHtmlBase(child)) {
            self.refreshDocumentBaseAfterMutation();
        }
    }

    // Update live ranges for insertion (DOM spec insert step 6).
    // For .before/.after the child was inserted at a specific position;
    // ranges on parent with offsets past that position must be incremented.
    // For .append no range update is needed (spec: "if child is non-null").
    if (self._live_ranges.first != null) {
        switch (relative) {
            .append => {},
            .before, .after => {
                if (parent.getChildIndex(child)) |idx| {
                    self.updateRangesForNodeInsertion(parent, idx);
                }
            },
        }
    }

    // Tri-state behavior for mutations:
    // 1. from_parser=true, parse_mode=document -> no mutations (initial document parse)
    // 2. from_parser=true, parse_mode=fragment -> mutations (innerHTML additions)
    // 3. from_parser=false, parse_mode=document -> mutation (js manipulation)
    // split like this because from_parser can be comptime known.
    const should_notify = if (comptime from_parser)
        self._parse_mode == .fragment
    else
        true;

    // Never call isConnected() on the document-parse hot path: parent chains can
    // be transiently inconsistent during foster-parenting / reparent, and after
    // cross-document re-nav (Google knitsail → Bing) walking _parent UAF'd
    // (SIGABRT in isConnected). Document parse always inserts into the live tree.
    if (should_notify) {
        const parent_is_connected = parent.isConnected();
        if (comptime from_parser == false) {
            // When the parser adds the node, nodeIsReady is only called when the
            // nodeComplete() callback is executed.
            try self.nodeIsReady(false, child);

            // Check if text was added to a script that hasn't started yet.
            if (child._type == .cdata and parent_is_connected) {
                if (parent.is(Element.Html.Script)) |script| {
                    if (!script._executed) {
                        try self.nodeIsReady(false, parent);
                    }
                }
            }
        }

        // Notify mutation observers about childList change
        if (self.hasMutationObservers()) {
            const previous_sibling = child.previousSibling();
            const next_sibling = child.nextSibling();
            const added = [_]*Node{child};
            self.childListChange(parent, &added, &.{}, previous_sibling, next_sibling);
        }
    }

    if (comptime from_parser) {
        if (child.is(Element)) |el| {
            // Invoke connectedCallback for custom elements during parsing.
            // Main document parse: always treat as connected (no isConnected walk).
            // Fragment parse (innerHTML): must check connectivity.
            const connected = if (self._parse_mode == .document)
                true
            else
                (child.isConnected() or child.isInShadowTree());
            if (connected) {
                if (el.getAttributeSafe(comptime .wrap("id"))) |id| {
                    try self.addElementId(parent, el, id);
                }
                try Element.Html.Custom.invokeConnectedCallbackOnElement(true, el, self);
            }
        }
        return;
    }

    // Update slot assignments for the inserted child if parent is a shadow host
    // This needs to happen even if the element isn't connected to the document
    if (child.is(Element)) |el| {
        // Assignment changes signal both the previously assigned slot and the
        // newly assigned slot. Updating only the derived lookup suppresses the
        // required slotchange microtask for light-DOM insertion.
        self.updateSlotAssignments(el);
    }

    if (opts.child_already_connected and !opts.adopting_to_new_document) {
        // The child is already connected in the same document, we don't have to reconnect it.
        // On cross-document adoption the child has already fired
        // disconnectedCallback against the old tree and must re-fire
        // connectedCallback for the new tree, so we fall through.
        return;
    }

    const parent_is_connected = parent.isConnected();
    const parent_in_shadow = parent.is(ShadowRoot) != null or parent.isInShadowTree();

    if (!parent_in_shadow and !parent_is_connected) {
        return;
    }

    // If we're here, it means either:
    // 1. A disconnected child became connected (parent.isConnected() == true)
    // 2. Child is being added to a shadow tree (parent_in_shadow == true)
    // In both cases, we need to update ID maps and invoke callbacks

    // Only invoke connectedCallback if the root child is transitioning from
    // disconnected to connected. When that happens, all descendants should also
    // get connectedCallback invoked (they're becoming connected as a group).
    // Cross-document adoption also counts as a transition: the element fired
    // disconnectedCallback against the old tree during removeNode and must
    // now fire connectedCallback against the new tree.
    const should_invoke_connected = parent_is_connected and (!opts.child_already_connected or opts.adopting_to_new_document);

    // nodeIsReady / mutation observers / connectedCallback can reparent or
    // detach nodes in this subtree before or during the walk (nytimes.com
    // SPA inserts via setTimeout during script doneCallback). Never unwrap
    // _parent with `?` — skip detached nodes for id registration.
    var tw = @import("../dom/TreeWalker.zig").Full.Elements.init(child, .{});
    while (tw.next()) |el| {
        if (el.getAttributeSafe(comptime .wrap("id"))) |id| {
            const n = el.asNode();
            if (n._parent == null) continue;
            try self.addElementId(n, el, id);
        }

        if (should_invoke_connected) {
            // Element may have been detached by a prior connectedCallback in
            // this walk; only invoke when still connected / in a shadow tree.
            if (!el.asNode().isConnected() and !el.asNode().isInShadowTree()) continue;
            try Element.Html.Custom.invokeConnectedCallbackOnElement(false, el, self);
        }
    }

    // After the subtree is fully connected, fire deferred subresource/load
    // callbacks for descendants (iframes parsed via innerHTML, scripts/links
    // brought along by a moved subtree, etc). The root (`child`) was already
    // dispatched by the `nodeIsReady(false, child)` call above, so we walk
    // descendants only.
    if (should_invoke_connected) {
        try self.notifyDescendantsConnected(child);
    }
}

pub fn attributeChange(self: *Frame, element: *Element, name: String, value: String, old_value: ?String) void {
    _ = Element.Build.call(element, "attributeChange", .{ element, name, value, self }) catch |err| {
        log.err(.bug, "build.attributeChange", .{ .tag = element.getTag(), .name = name, .value = value, .err = err, .type = self._type, .url = self.url });
    };

    Element.Html.Custom.invokeAttributeChangedCallbackOnElement(element, name, old_value, value, null, self);

    if (name.eql(comptime .wrap("href")) and element.is(Element.Html.Base) != null and element.asNode().isConnected()) {
        self.refreshDocumentBaseAfterMutation();
    }

    var it: ?*std.DoublyLinkedList.Node = self._mutation_observers.first;
    while (it) |node| : (it = node.next) {
        const observer: *MutationObserver = @fieldParentPtr("node", node);
        observer.notifyAttributeChange(element, name, old_value, null, self) catch |err| {
            log.err(.frame, "attributeChange.notifyObserver", .{ .err = err, .type = self._type, .url = self.url });
        };
    }

    // Handle slot assignment changes
    if (name.eql(comptime .wrap("slot"))) {
        self.updateSlotAssignments(element);
    } else if (name.eql(comptime .wrap("name"))) {
        // Check if this is a slot element
        if (element.is(Element.Html.Slot)) |slot| {
            self.signalSlotChange(slot);
        }
    } else if (name.eql(comptime .wrap("class"))) {
        // Class swaps often start CSS animations (Fluent route fade-out). Without a
        // compositor we still must fire animationend so React onAnimationEnd runs.
        if (old_value == null or !old_value.?.eql(value)) {
            self.scheduleCssAnimationEnd(element) catch |err| {
                log.debug(.frame, "scheduleCssAnimationEnd", .{ .err = err, .type = self._type, .url = self.url });
            };
        }
    }
}

/// Queue a synthetic CSS animationend/transitionend for `element` after class change.
pub fn scheduleCssAnimationEnd(self: *Frame, element: *Element) !void {
    const owner = self.js.execution.captureTaskOwner();
    if (self._css_anim_delivery_scheduled and
        RealmLifecycleKernel.taskOwnerIsStale(self._css_anim_delivery_task_owner, owner))
    {
        // The pending keys belong to a replaced document arena.
        self._css_anim_pending.clearRetainingCapacity();
        self._css_anim_delivery_scheduled = false;
    }
    try self._css_anim_pending.put(self.arena, element, {});
    if (self._css_anim_delivery_scheduled) return;
    self._css_anim_delivery_scheduled = true;
    self._css_anim_delivery_task_owner = owner;
    // Without a compositor we still schedule the terminal DOM events, but the
    // deadline must come from the element's computed CSS rather than a
    // site-shaped constant. Zero-duration animations remain a future task.
    const delay_ms = self.cssAnimationTerminalDelayMs(element);
    try self.js.scheduler.add(self, struct {
        fn run(ctx: *anyopaque) !?u32 {
            const frame: *Frame = @ptrCast(@alignCast(ctx));
            frame.deliverCssAnimationEnds();
            return null;
        }
    }.run, delay_ms, .{ .name = "css.animationend" });
}

fn cssAnimationTerminalDelayMs(self: *Frame, element: *Element) u32 {
    const style = self.window.getComputedStyle(element, null, self) catch return 0;
    const animation = cssTimelineDurationMs(
        style.getPropertyValue("animation-duration", self),
        style.getPropertyValue("animation-delay", self),
    );
    const transition = cssTimelineDurationMs(
        style.getPropertyValue("transition-duration", self),
        style.getPropertyValue("transition-delay", self),
    );
    return @max(animation, transition);
}

fn cssTimelineDurationMs(duration_list: []const u8, delay_list: []const u8) u32 {
    var duration_ms: [32]i64 = undefined;
    var delay_ms: [32]i64 = undefined;
    const duration_count = parseCssTimeList(duration_list, &duration_ms);
    const delay_count = parseCssTimeList(delay_list, &delay_ms);
    if (duration_count == 0) return 0;

    var max_ms: i64 = 0;
    const item_count = @max(duration_count, delay_count);
    for (0..item_count) |i| {
        const duration = duration_ms[i % duration_count];
        const delay = if (delay_count == 0) 0 else delay_ms[i % delay_count];
        max_ms = @max(max_ms, duration +| delay);
    }
    return @intCast(@min(max_ms, std.math.maxInt(u32)));
}

fn parseCssTimeList(raw: []const u8, out: []i64) usize {
    var count: usize = 0;
    var values = std.mem.splitScalar(u8, raw, ',');
    while (values.next()) |value| {
        if (count == out.len) break;
        out[count] = cssTimeMs(value);
        count += 1;
    }
    return count;
}

fn cssTimeMs(raw: []const u8) i64 {
    const value = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (value.len == 0) return 0;
    const multiplier: f64 = if (std.mem.endsWith(u8, value, "ms"))
        1
    else if (std.mem.endsWith(u8, value, "s"))
        1000
    else
        return 0;
    const unit_len: usize = if (multiplier == 1) 2 else 1;
    const number = std.fmt.parseFloat(f64, value[0 .. value.len - unit_len]) catch return 0;
    if (!std.math.isFinite(number)) return 0;
    const millis = number * multiplier;
    const limit = @as(f64, @floatFromInt(std.math.maxInt(i32)));
    return @intFromFloat(std.math.clamp(millis, -limit, limit));
}

fn deliverCssAnimationEnds(self: *Frame) void {
    self._css_anim_delivery_scheduled = false;
    if (self._realm_state != .active or
        self.js.execution.isTaskOwnerStale(self._css_anim_delivery_task_owner))
    {
        self._css_anim_pending.clearRetainingCapacity();
        return;
    }

    const delivery_owner = self._css_anim_delivery_task_owner;
    const session = self._session;
    const delivery_arena = session.getArena(.tiny, "Frame.cssAnimationDelivery") catch {
        self._css_anim_pending.clearRetainingCapacity();
        return;
    };
    defer session.releaseArena(delivery_arena);

    // Event dispatch can execute arbitrary JS and reset Frame.call_arena.
    // Keep the queue snapshot in an independent arena for the whole delivery.
    var elements: std.ArrayList(*Element) = .empty;
    var it = self._css_anim_pending.keyIterator();
    while (it.next()) |key_ptr| {
        elements.append(delivery_arena, key_ptr.*) catch continue;
    }
    self._css_anim_pending.clearRetainingCapacity();

    for (elements.items) |element| {
        // An earlier handler may navigate and invalidate the remaining
        // document-owned Element pointers.
        if (self.js.execution.isTaskOwnerStale(delivery_owner)) break;
        // Fire both: Fluent uses CSS animation; some SPAs use transitions.
        for ([_][]const u8{ "animationend", "transitionend" }) |typ| {
            const event = Event.initTrusted(String.wrap(typ), .{ .bubbles = true }, self._page) catch |err| {
                log.debug(.frame, "css.animEvent.init", .{ .err = err, .type = self._type });
                continue;
            };
            self._event_manager.dispatch(element.asNode().asEventTarget(), event) catch |err| {
                log.debug(.frame, "css.animEvent.dispatch", .{ .err = err, .type = self._type });
            };
        }
    }
}

pub fn attributeRemove(self: *Frame, element: *Element, name: String, old_value: String) void {
    _ = Element.Build.call(element, "attributeRemove", .{ element, name, self }) catch |err| {
        log.err(.bug, "build.attributeRemove", .{ .tag = element.getTag(), .name = name, .err = err, .type = self._type, .url = self.url });
    };

    Element.Html.Custom.invokeAttributeChangedCallbackOnElement(element, name, old_value, null, null, self);

    if (name.eql(comptime .wrap("href")) and element.is(Element.Html.Base) != null and element.asNode().isConnected()) {
        self.refreshDocumentBaseAfterMutation();
    }

    var it: ?*std.DoublyLinkedList.Node = self._mutation_observers.first;
    while (it) |node| : (it = node.next) {
        const observer: *MutationObserver = @fieldParentPtr("node", node);
        observer.notifyAttributeChange(element, name, old_value, null, self) catch |err| {
            log.err(.frame, "attributeRemove.notifyObserver", .{ .err = err, .type = self._type, .url = self.url });
        };
    }

    // Handle slot assignment changes
    if (name.eql(comptime .wrap("slot"))) {
        self.updateSlotAssignments(element);
    } else if (name.eql(comptime .wrap("name"))) {
        // Check if this is a slot element
        if (element.is(Element.Html.Slot)) |slot| {
            self.signalSlotChange(slot);
        }
    }
}

pub fn signalSlotChange(self: *Frame, slot: *Element.Html.Slot) void {
    self._slots_pending_slotchange.put(self.arena, slot, {}) catch |err| {
        log.err(.frame, "signalSlotChange.put", .{ .err = err, .type = self._type, .url = self.url });
        return;
    };
    self.scheduleSlotchangeDelivery() catch |err| {
        log.err(.frame, "signalSlotChange.schedule", .{ .err = err, .type = self._type, .url = self.url });
    };
}

fn updateSlotAssignments(self: *Frame, element: *Element) void {
    // Find all slots in the shadow root that might be affected
    const parent = element.asNode()._parent orelse return;

    // Check if parent is a shadow host
    const parent_el = parent.is(Element) orelse return;
    _ = self._element_shadow_roots.get(parent_el) orelse return;

    // Signal change for the old slot (if any)
    if (self._element_assigned_slots.get(element)) |old_slot| {
        self.signalSlotChange(old_slot);
    }

    // Update the assignedSlot lookup to the new slot
    self.updateElementAssignedSlot(element);

    // Signal change for the new slot (if any)
    if (self._element_assigned_slots.get(element)) |new_slot| {
        self.signalSlotChange(new_slot);
    }
}

pub fn getManualSlotAssignment(self: *Frame, slot: *Element.Html.Slot) ?[]const *Node {
    return self._manual_slot_assignments.get(slot);
}

pub fn setManualSlotAssignment(self: *Frame, slot: *Element.Html.Slot, nodes: []const *Node) !void {
    const owned = try self.arena.dupe(*Node, nodes);
    try self._manual_slot_assignments.put(self.arena, slot, owned);

    for (nodes) |node| {
        if (node.is(Element)) |el| {
            if (self._element_assigned_slots.get(el)) |old_slot| {
                if (old_slot != slot) {
                    self.signalSlotChange(old_slot);
                }
            }
            try self._element_assigned_slots.put(self.arena, el, slot);
        }
    }
}

fn updateElementAssignedSlot(self: *Frame, element: *Element) void {
    // Remove old assignment
    _ = self._element_assigned_slots.remove(element);

    // Find the new assigned slot
    const parent = element.asNode()._parent orelse return;
    const parent_el = parent.is(Element) orelse return;
    const shadow_root = self._element_shadow_roots.get(parent_el) orelse return;

    const slot_name = element.getAttributeSafe(comptime .wrap("slot")) orelse "";

    // Recursively search through the shadow root for a matching slot
    if (findMatchingSlot(shadow_root.asNode(), slot_name)) |slot| {
        self._element_assigned_slots.put(self.arena, element, slot) catch |err| {
            log.err(.frame, "updateElementAssignedSlot.put", .{ .err = err, .type = self._type, .url = self.url });
        };
    }
}

fn findMatchingSlot(node: *Node, slot_name: []const u8) ?*Element.Html.Slot {
    // Check if this node is a matching slot
    if (node.is(Element)) |el| {
        if (el.is(Element.Html.Slot)) |slot| {
            if (std.mem.eql(u8, slot.getName(), slot_name)) {
                return slot;
            }
        }
    }

    // Search children
    var it = node.childrenIterator();
    while (it.next()) |child| {
        if (findMatchingSlot(child, slot_name)) |slot| {
            return slot;
        }
    }

    return null;
}

pub fn hasMutationObservers(self: *const Frame) bool {
    return self._mutation_observers.first != null;
}

pub fn getCustomizedBuiltInDefinition(self: *Frame, element: *Element) ?*CustomElementDefinition {
    return self._customized_builtin_definitions.get(element);
}

pub fn setCustomizedBuiltInDefinition(self: *Frame, element: *Element, definition: *CustomElementDefinition) !void {
    try self._customized_builtin_definitions.put(self.arena, element, definition);
}

pub fn characterDataChange(
    self: *Frame,
    target: *Node,
    old_value: String,
) void {
    var it: ?*std.DoublyLinkedList.Node = self._mutation_observers.first;
    while (it) |node| : (it = node.next) {
        const observer: *MutationObserver = @fieldParentPtr("node", node);
        observer.notifyCharacterDataChange(target, old_value, self) catch |err| {
            log.err(.frame, "cdataChange.notifyObserver", .{ .err = err, .type = self._type, .url = self.url });
        };
    }
}

pub fn childListChange(
    self: *Frame,
    target: *Node,
    added_nodes: []const *Node,
    removed_nodes: []const *Node,
    previous_sibling: ?*Node,
    next_sibling: ?*Node,
) void {
    // Filter out HTML wrapper element during fragment parsing (html5ever quirk)
    if (self._parse_mode == .fragment and added_nodes.len == 1) {
        if (added_nodes[0].is(Element.Html.Html) != null) {
            // This is the temporary HTML wrapper, added by html5ever
            // that will be unwrapped, see:
            // https://github.com/servo/html5ever/issues/583
            return;
        }
    }

    var it: ?*std.DoublyLinkedList.Node = self._mutation_observers.first;
    while (it) |node| : (it = node.next) {
        const observer: *MutationObserver = @fieldParentPtr("node", node);
        observer.notifyChildListChange(target, added_nodes, removed_nodes, previous_sibling, next_sibling, self) catch |err| {
            log.err(.frame, "childListChange.notifyObserver", .{ .err = err, .type = self._type, .url = self.url });
        };
    }
}

// --- Live range update methods (DOM spec §4.2.3, §4.2.4, §4.7, §4.8) ---

/// Update all live ranges after a replaceData mutation on a CharacterData node.
/// Per DOM spec: insertData = replaceData(offset, 0, data),
///               deleteData = replaceData(offset, count, "").
/// All parameters are in UTF-16 code unit offsets.
pub fn updateRangesForCharacterDataReplace(self: *Frame, target: *Node, offset: u32, count: u32, data_len: u32) void {
    var it: ?*std.DoublyLinkedList.Node = self._live_ranges.first;
    while (it) |link| : (it = link.next) {
        const ar: *AbstractRange = @fieldParentPtr("_range_link", link);
        ar.updateForCharacterDataReplace(target, offset, count, data_len);
    }
}

/// Update all live ranges after a splitText operation.
/// Steps 7b-7e of the DOM spec splitText algorithm.
/// Steps 7d-7e complement (not overlap) updateRangesForNodeInsertion:
/// the insert update handles offsets > child_index, while 7d/7e handle
/// offsets == node_index+1 (these are equal values but with > vs == checks).
pub fn updateRangesForSplitText(self: *Frame, target: *Node, new_node: *Node, offset: u32, parent: *Node, node_index: u32) void {
    var it: ?*std.DoublyLinkedList.Node = self._live_ranges.first;
    while (it) |link| : (it = link.next) {
        const ar: *AbstractRange = @fieldParentPtr("_range_link", link);
        ar.updateForSplitText(target, new_node, offset, parent, node_index);
    }
}

/// Update all live ranges after a node insertion.
/// Per DOM spec insert algorithm step 6: only applies when inserting before a
/// non-null reference node.
pub fn updateRangesForNodeInsertion(self: *Frame, parent: *Node, child_index: u32) void {
    var it: ?*std.DoublyLinkedList.Node = self._live_ranges.first;
    while (it) |link| : (it = link.next) {
        const ar: *AbstractRange = @fieldParentPtr("_range_link", link);
        ar.updateForNodeInsertion(parent, child_index);
    }
}

/// Update all live ranges after a node removal.
/// Per DOM spec remove algorithm steps 4-7.
pub fn updateRangesForNodeRemoval(self: *Frame, parent: *Node, child: *Node, child_index: u32) void {
    var it: ?*std.DoublyLinkedList.Node = self._live_ranges.first;
    while (it) |link| : (it = link.next) {
        const ar: *AbstractRange = @fieldParentPtr("_range_link", link);
        ar.updateForNodeRemoval(parent, child, child_index);
    }
}

// TODO: optimize and cleanup, this is called a lot (e.g., innerHTML = '')
pub fn parseHtmlAsChildren(self: *Frame, node: *Node, html: []const u8) !void {
    const previous_parse_mode = self._parse_mode;
    self._parse_mode = .fragment;
    defer self._parse_mode = previous_parse_mode;

    var parser = Parser.init(self.call_arena, node, self);
    try parser.parseFragment(html);

    // https://github.com/servo/html5ever/issues/583
    const children = node._children orelse return;
    const first = children.one;
    assert(first.is(Element.Html.Html) != null, "Frame.parseHtmlAsChildren root", .{ .type = first._type });
    node._children = first._children;

    if (self.hasMutationObservers()) {
        var it = node.childrenIterator();
        while (it.next()) |child| {
            child._parent = node;
            // Notify mutation observers for each unwrapped child
            const previous_sibling = child.previousSibling();
            const next_sibling = child.nextSibling();
            const added = [_]*Node{child};
            self.childListChange(node, &added, &.{}, previous_sibling, next_sibling);
        }
    } else {
        var it = node.childrenIterator();
        while (it.next()) |child| {
            child._parent = node;
        }
    }

    // If the parser-built children are now part of a connected subtree, fire
    // deferred subresource/lifecycle callbacks on the descendants. Without
    // this, iframes/scripts/links/styles introduced via innerHTML on a live
    // element never get their AddedCallback (e.g. iframes never receive a
    // contentWindow). The walker excludes `node` itself; callbacks are
    // idempotent so partial paths remain safe.
    if (node.isConnected()) {
        try self.notifyDescendantsConnected(node);
    }
}

/// html5ever may run nodeComplete on void elements like `<iframe>` before their
/// attributes are fully bound. Reconcile once the document parse is finished.
fn reconcileParserIframeSrc(self: *Frame) void {
    var tw = @import("../dom/TreeWalker.zig").Full.Elements.init(self.document.asNode(), .{});
    while (tw.next()) |el| {
        const iframe = el.is(IFrame) orelse continue;
        IFrame.Build.complete(el.asNode(), self) catch continue;
        const src = iframe.asElement().getAttributeSafe(comptime .wrap("src")) orelse iframe._src;
        self._session.upgradeIframeFromAboutBlank(self, iframe, src) catch |err| {
            log.warn(.frame, "reconcile iframe upgrade", .{ .err = err, .src = src });
        };
    }
}

fn drainQueuedNavigationsAfterParse(self: *Frame) void {
    const session = self._session;
    const page = session.currentPage() orelse return;

    var passes: u8 = 0;
    while (passes < 8) : (passes += 1) {
        if (page.queued_navigation.items.len == 0) break;
        session.processQueuedNavigation() catch |err| {
            log.warn(.frame, "queued nav after parse", .{ .err = err, .url = self.url });
            break;
        };
        var ticks: u8 = 0;
        while (ticks < 32) : (ticks += 1) {
            _ = session.browser.http_client.tick(0) catch break;
        }
    }
}

/// Fire deferred subresource/lifecycle callbacks for every descendant of
/// `subtree_root` (the root itself is excluded, as callers handle it via
/// `nodeIsReady`). This bridges the gap where iframes/scripts/links/styles/images
/// are introduced as descendants — either through `innerHTML` parsing or by
/// moving an already-built subtree into a connected parent — and would
/// otherwise never see their AddedCallback fire.
///
/// Each underlying callback is idempotent for replays (iframes guard on
/// `_executed`, scripts go through `ScriptManager`, etc.), so calling this
/// from multiple insertion paths is safe.
pub fn notifyDescendantsConnected(self: *Frame, subtree_root: *Node) !void {
    var tw = @import("../dom/TreeWalker.zig").FullExcludeSelf.Elements.init(subtree_root, .{});
    while (tw.next()) |el| {
        try self.nodeIsReady(false, el.asNode());
    }
}

fn nodeIsReady(self: *Frame, comptime from_parser: bool, node: *Node) !void {
    if ((comptime from_parser) and self._parse_mode == .fragment) {
        // we don't execute scripts added via innerHTML = '<script...';
        return;
    }
    // Main document html5ever parse: style/link/img deferred (knitsail re-nav
    // SIGBUS mid-parse on data:image / CSSOM). Scripts still call
    // scriptAddedCallback but ScriptManager queues inline bodies for
    // staticScriptsDone instead of eval on the parser stack.
    if ((comptime from_parser) and self._parse_mode == .document and self._document_parse_active) {
        if (node.is(Element.Html.Script) != null or node.is(IFrame) != null) {
            // fall through
        } else if (node.is(Element.Html.Style) != null) {
            self._style_manager.sheetModified();
            return;
        } else {
            return;
        }
    }
    if (node.is(Element.Html.Script)) |script| {
        if (comptime from_parser == false) {
            // React Helmet and other libs often set `src` via setAttribute rather
            // than the .src IDL property; only the latter updates Script._src.
            // Fall back to the live attribute so external scripts still execute.
            const has_src = script._src.len > 0 or blk: {
                const attr = script.asElement().getAttributeSafe(comptime .wrap("src")) orelse break :blk false;
                break :blk attr.len > 0;
            };
            if (!has_src and node.firstChild() == null) {
                // No src and no inline content — nothing to evaluate.
                return;
            }
        }

        self.scriptAddedCallback(from_parser, script) catch |err| {
            log.err(.frame, "frame.nodeIsReady", .{ .err = err, .element = "script", .type = self._type, .url = self.url });
            return err;
        };
    } else if (node.is(IFrame)) |iframe| {
        self.iframeAddedCallback(iframe) catch |err| {
            log.err(.frame, "frame.nodeIsReady", .{ .err = err, .element = "iframe", .type = self._type, .url = self.url });
            return err;
        };
    } else if (node.is(Element.Html.Link)) |link| {
        link.linkAddedCallback(self) catch |err| {
            log.err(.frame, "frame.nodeIsReady", .{ .err = err, .element = "link", .type = self._type });
            return error.LinkLoadError;
        };
    } else if (node.is(Element.Html.Style)) |style| {
        style.styleAddedCallback(self) catch |err| {
            log.err(.frame, "frame.nodeIsReady", .{ .err = err, .element = "style", .type = self._type });
            return error.StyleLoadError;
        };
    } else if (node.is(Element.Html.Image)) |image| {
        image.imageAddedCallback(self) catch |err| {
            log.err(.frame, "frame.nodeIsReady", .{ .err = err, .element = "img", .type = self._type, .url = self.url });
            return err;
        };
    }
}

const ParseState = union(enum) {
    const Html = struct {
        arena: Allocator,
        buffer: std.ArrayList(u8),
        as_xml: bool = false,
    };

    pre,
    complete,
    err: anyerror,
    html: Html,
    /// The scheduler callback is the sole owner of the response arena.
    deferred_html,
    text: std.ArrayList(u8),
    image: std.ArrayList(u8),
    raw: std.ArrayList(u8),
    raw_done: []const u8,

    fn takeHtmlForDeferred(self: *ParseState) ?Html {
        const html = switch (self.*) {
            .html => |value| value,
            else => return null,
        };
        self.* = .deferred_html;
        return html;
    }

    fn deinit(self: *ParseState, frame: *Frame) void {
        switch (self.*) {
            .html => |html| frame.releaseArena(html.arena),
            else => {},
        }
    }
};

const LoadState = enum {
    // waiting for the main HTML
    waiting,

    // the main HTML is being parsed (or downloaded)
    parsing,

    // the main HTML has been parsed and the JavaScript (including deferred
    // scripts) have been loaded. Corresponds to the DOMContentLoaded event
    load,

    // the frame has been loaded and all async scripts (if any) are done
    // Corresponds to the load event
    complete,
};

const IdleNotification = union(enum) {
    // hasn't started yet.
    init,

    // timestamp where the state was first triggered. If the state stays
    // true (e.g. 0 network activity for NetworkIdle, or <= 2 for NetworkAlmostIdle)
    // for 500ms, it'll send the notification and transition to .done. If
    // the state doesn't stay true, it'll revert to .init.
    triggered: u64,

    // notification sent - should never be reset
    done,

    // Returns `true` if we should send a notification. Only returns true if it
    // was previously triggered 500+ milliseconds ago.
    // active == true when the condition for the notification is true
    // active == false when the condition for the notification is false
    pub fn check(self: *IdleNotification, active: bool) bool {
        if (active) {
            switch (self.*) {
                .done => {
                    // Notification was already sent.
                },
                .init => {
                    // This is the first time the condition was triggered (or
                    // the first time after being un-triggered). Record the time
                    // so that if the condition holds for long enough, we can
                    // send a notification.
                    self.* = .{ .triggered = milliTimestamp(.monotonic) };
                },
                .triggered => |ms| {
                    // The condition was already triggered and was triggered
                    // again. When this condition holds for 500+ms, we'll send
                    // a notification.
                    if (milliTimestamp(.monotonic) - ms >= 500) {
                        // This is the only place in this function where we can
                        // return true. The only place where we can tell our caller
                        // "send the notification!".
                        self.* = .done;
                        return true;
                    }
                    // the state hasn't held for 500ms.
                },
            }
        } else {
            switch (self.*) {
                .done => {
                    // The condition became false, but we already sent the notification
                    // There's nothing we can do, it stays .done. We never re-send
                    // a notification or "undo" a sent notification (not that we can).
                },
                .init => {
                    // The condition remains false
                },
                .triggered => {
                    // The condition _had_ been true, and we were waiting (500ms)
                    // for it to hold, but it hasn't. So we go back to waiting.
                    self.* = .init;
                },
            }
        }

        // See above for the only case where we ever return true. All other
        // paths go here. This means "don't send the notification". Maybe
        // because it's already been sent, maybe because active is false, or
        // maybe because the condition hasn't held long enough.
        return false;
    }
};

pub const NavigateReason = enum {
    anchor,
    address_bar,
    form,
    script,
    history,
    navigation,
    initialFrameNavigation,
};

pub const NavigateOpts = struct {
    cdp_id: ?i64 = null,
    reason: NavigateReason = .address_bar,
    method: HttpClient.Method = .GET,
    body: ?[]const u8 = null,
    header: ?[:0]const u8 = null,
    /// Set when retryPendingRootNavigation re-issues a failed pending document hop.
    is_document_retry: bool = false,
    // Set by scheduleNavigationWithArena from the originating frame's URL so
    // anchor click / form submit / location.href navigations carry a Referer.
    // null on CDP Page.navigate (address-bar) and Page.reload — matches Chrome.
    referer: ?[]const u8 = null,
    // scheduleNavigationWithArena copies the originator's origin here for Sec-Fetch-Site.
    prior_origin: ?[]const u8 = null,
    force: bool = false,
    /// Blocked about:srcdoc navigations become an opaque-origin error document.
    opaque_about_error: bool = false,
    kind: NavigationKind = .{ .push = null },
};

pub const NavigatedOpts = struct {
    cdp_id: ?i64 = null,
    reason: NavigateReason = .address_bar,
    method: HttpClient.Method = .GET,
    // Retained on the frame's arena so Page.reload can replay the prior
    // navigation's HTTP method — matches Chrome's F5 behavior on POST pages.
    body: ?[]const u8 = null,
    header: ?[:0]const u8 = null,
};

const NavigationType = enum {
    form,
    script,
    anchor,
    iframe,
};

const Navigation = union(NavigationType) {
    form: *Frame,
    script: ?*Frame,
    anchor: *Frame,
    iframe: *IFrame,
};

pub const QueuedNavigation = struct {
    arena: Allocator,
    url: [:0]const u8,
    opts: NavigateOpts,
    is_about_blank: bool,
    navigation_type: NavigationType,
};

/// Resolves a target attribute value (e.g., "_self", "_parent", "_top", or frame name)
/// to the appropriateFrame to navigate.
/// Returns null if the target is "_blank" (which would open a new window/tab).
/// Note: Callers should handle empty target separately (for owner document resolution).
pub fn resolveTargetFrame(self: *Frame, target_name: []const u8) ?*Frame {
    if (std.ascii.eqlIgnoreCase(target_name, "_self")) {
        return self;
    }

    if (std.ascii.eqlIgnoreCase(target_name, "_blank")) {
        return null;
    }

    if (std.ascii.eqlIgnoreCase(target_name, "_parent")) {
        return self.parent orelse self;
    }

    if (std.ascii.eqlIgnoreCase(target_name, "_top")) {
        var frame = self;
        while (frame.parent) |f| {
            frame = f;
        }
        return frame;
    }

    // Named frame lookup: search current frame's descendants first, then from root
    // This follows the HTML spec's "implementation-defined" search order.
    if (findFrameByName(self, target_name)) |f| {
        return f;
    }

    // If not found in descendants, search from root (catches siblings and ancestors' descendants)
    var root = self;
    while (root.parent) |f| {
        root = f;
    }
    if (root != self) {
        if (findFrameByName(root, target_name)) |f| {
            return f;
        }
    }

    // If no frame found with that name, navigate in current frame
    // (this matches browser behavior - unknown targets act like _self)
    return self;
}

fn findFrameByName(frame: *Frame, name: []const u8) ?*Frame {
    for (frame.child_frames.items) |f| {
        if (f.iframe) |iframe| {
            const frame_name = iframe.asElement().getAttributeSafe(comptime .wrap("name")) orelse "";
            if (std.mem.eql(u8, frame_name, name)) {
                return f;
            }
        }
        // Recursively search child frames
        if (findFrameByName(f, name)) |found| {
            return found;
        }
    }
    return null;
}

/// Hit-test for synthetic input (CDP, fetch --click-selector). Unlike
/// `document.elementFromPoint`, this descends into child browsing contexts when
/// the topmost element is an iframe so clicks can reach nested content.
pub fn frameId(self: *const Frame) u32 {
    return self._frame_id;
}

pub fn hitTestForInput(self: *Frame, x: f64, y: f64) !?InputHit {
    const target = (try self.window._document.elementFromPoint(x, y, self)) orelse return null;
    return try resolveInputHit(target, x, y, self);
}

fn resolveInputHit(element: *Element, x: f64, y: f64, frame: *Frame) !?InputHit {
    if (element.asNode().is(IFrame)) |iframe| {
        const child_window = iframe._window orelse {
            if (comptime IS_DEBUG) {
                log.debug(.frame, "input hit iframe without child window", .{ .url = frame.url });
            }
            return .{ .element = element, .frame = frame, .client_x = x, .client_y = y };
        };
        const child_frame = child_window._frame;
        // Internal input routing uses the browsing context directly. Do not
        // gate on realmReadyForExternalObservers(), which only applies to the
        // contentWindow/contentDocument accessors exposed to page script.
        if (child_frame._load_state == .waiting or child_frame._load_state == .parsing) {
            if (comptime IS_DEBUG) {
                log.debug(.frame, "input hit child frame not ready", .{
                    .parent_url = frame.url,
                    .child_url = child_frame.url,
                    .load_state = child_frame._load_state,
                });
            }
            return .{ .element = element, .frame = frame, .client_x = x, .client_y = y };
        }

        const rect = element.getBoundingClientRectForVisible(frame);
        const child_x = x - rect.getLeft();
        const child_y = y - rect.getTop();

        const child_target = (try child_frame.window._document.elementFromPoint(child_x, child_y, child_frame)) orelse {
            return .{ .element = element, .frame = frame, .client_x = x, .client_y = y };
        };

        return try resolveInputHit(child_target, child_x, child_y, child_frame);
    }

    return .{ .element = element, .frame = frame, .client_x = x, .client_y = y };
}

pub fn triggerMouseClick(self: *Frame, x: f64, y: f64) !void {
    try @import("InputController.zig").dispatchPointerClick(self, x, y);
}

pub fn triggerMousePress(self: *Frame, x: f64, y: f64) !void {
    try @import("InputController.zig").dispatchPointerDownAtCdp(self, x, y);
}

pub fn triggerMouseRelease(self: *Frame, x: f64, y: f64) !void {
    try @import("InputController.zig").dispatchPointerUpAtCdp(self, x, y);
}

/// Queue mousePressed after its CDP reply. Unlike the old paired implementation,
/// this dispatches pointerdown/mousedown before mouseReleased arrives so
/// press-and-hold challenges observe the actual elapsed hold duration.
pub fn scheduleCdpMousePress(self: *Frame, x: f64, y: f64) !void {
    self._cdp_mouse_pending_x = x;
    self._cdp_mouse_pending_y = y;
    try self.js.scheduler.add(self, struct {
        fn run(ctx: *anyopaque) !?u32 {
            const frame: *Frame = @ptrCast(@alignCast(ctx));
            try @import("InputController.zig").dispatchPointerDownAtCdp(
                frame,
                frame._cdp_mouse_pending_x,
                frame._cdp_mouse_pending_y,
            );
            return null;
        }
    }.run, 0, .{ .name = "input.mousePressed" });
}

/// Queue element activation after Koko.clickNode CDP reply (avoids blocking transport).
pub fn scheduleActivationOnElement(self: *Frame, element: *Element) !void {
    self._koko_pending_activation = element;
    try self.js.scheduler.add(self, struct {
        fn run(ctx: *anyopaque) !?u32 {
            const frame: *Frame = @ptrCast(@alignCast(ctx));
            const el = frame._koko_pending_activation orelse return null;
            frame._koko_pending_activation = null;
            @import("InputController.zig").dispatchActivationOnElementFast(el, frame) catch |err| {
                log.err(.frame, "scheduled activation failed", .{ .err = err });
            };
            return null;
        }
    }.run, 0, .{ .name = "koko.clickNode" });
}

/// Queue mouseReleased independently; mousePressed has already established
/// `_input_press_hit` and dispatched its down events.
pub fn scheduleCdpMouseRelease(self: *Frame, x: f64, y: f64) !void {
    self._cdp_mouse_release_x = x;
    self._cdp_mouse_release_y = y;
    try self.js.scheduler.add(self, struct {
        fn run(ctx: *anyopaque) !?u32 {
            const frame: *Frame = @ptrCast(@alignCast(ctx));
            try @import("InputController.zig").dispatchPointerUpAtCdp(
                frame,
                frame._cdp_mouse_release_x,
                frame._cdp_mouse_release_y,
            );
            return null;
        }
    }.run, 0, .{ .name = "input.mouseReleased" });
}

// callback when the "click" event reaches the frame.
pub fn handleClick(self: *Frame, target: *Node) !void {
    // TODO: Also support <area> elements when implement
    // Clicks often land on text/span *inside* a <button type=submit>. Walk up
    // to the nearest activation target (Fluent Next wraps label text in spans).
    var element = target.is(Element) orelse return;
    var walk: ?*Node = target;
    while (walk) |n| {
        if (n.is(Element)) |el| {
            if (el.is(Element.Html)) |html| {
                switch (html._type) {
                    .button, .input, .anchor, .label => {
                        element = el;
                        break;
                    },
                    else => {},
                }
            }
        }
        walk = n._parent;
    }
    const html_element = element.is(Element.Html) orelse return;

    switch (html_element._type) {
        .anchor => |anchor| {
            const href = element.getAttributeSafe(comptime .wrap("href")) orelse return;
            if (href.len == 0) {
                return;
            }

            if (std.mem.startsWith(u8, href, "javascript:")) {
                return;
            }

            if (try element.hasAttribute(comptime .wrap("download"), self)) {
                log.warn(.browser, "a.download", .{ .type = self._type, .url = self.url });
                return;
            }

            const target_frame = blk: {
                const target_name = anchor.getTarget();
                if (target_name.len == 0) {
                    break :blk target.ownerFrame(self);
                }
                break :blk self.resolveTargetFrame(target_name) orelse {
                    log.warn(.not_implemented, "target", .{ .type = self._type, .url = self.url, .target = target_name });
                    return;
                };
            };

            try element.focus(self);
            try self.scheduleNavigation(href, .{
                .reason = .script,
                .kind = .{ .push = null },
            }, .{ .anchor = target_frame });
        },
        .input => |input| {
            try element.focus(self);
            // Per HTML §4.10.18.6.4 "Image Button state (type=image)", clicking an
            // image button submits its form. The form-data set already gets the
            // submitter's coordinate fields appended via FormData.collectForm
            // (see src/browser/webapi/net/FormData.zig).
            if (input._input_type == .submit or input._input_type == .image) {
                return self.submitForm(element, input.getForm(self), .{});
            }
        },
        .button => |button| {
            try element.focus(self);
            if (std.mem.eql(u8, button.getType(), "submit")) {
                return self.submitForm(element, button.getForm(self), .{});
            }
        },
        .select, .textarea => try element.focus(self),
        .label => |label| {
            // Per HTML §4.10.4 "The label element", a label's activation
            // behavior is to run the synthetic click activation steps on the
            // labeled control. Mirrors Chrome's HTMLLabelElement::DefaultEventHandler.
            const control = label.getControl(self) orelse return;
            const control_html = control.is(Element.Html) orelse return;
            try control_html.click(self);
        },
        .generic => |generic| {
            switch (generic._tag) {
                .summary => {
                    const parent_el = target.parentElement() orelse return;
                    const details = parent_el.is(Element.Html.Details) orelse return;
                    var maybe_prev = element.previousElementSibling();
                    while (maybe_prev) |prev| {
                        if (prev.getTag() == .summary) {
                            // we found a summary element before the clicked one
                            return;
                        }
                        maybe_prev = prev.previousElementSibling();
                    }
                    try details.setOpen(!details.getOpen(), self);
                },
                else => {},
            }
        },
        else => {},
    }
}

pub fn triggerKeyboard(self: *Frame, keyboard_event: *KeyboardEvent) !void {
    const event = keyboard_event.asEvent();
    const element = self.window._document._active_element orelse {
        event.deinit(self._page);
        return;
    };

    if (comptime IS_DEBUG) {
        log.debug(.frame, "frame keydown", .{
            .url = self.url,
            .node = element,
            .key = keyboard_event._key,
            .type = self._type,
        });
    }
    try self._event_manager.dispatch(element.asEventTarget(), event);
}

pub fn handleKeydown(self: *Frame, target: *Node, event: *Event) !void {
    const keyboard_event = event.is(KeyboardEvent) orelse return;
    const key = keyboard_event.getKey();

    if (key == .Dead) {
        return;
    }

    if (target.is(Element.Html.Input)) |input| {
        if (key == .Enter) {
            return self.submitForm(input.asElement(), input.getForm(self), .{});
        }

        // Don't handle text input for radio/checkbox
        const input_type = input._input_type;
        if (input_type == .radio or input_type == .checkbox) {
            return;
        }

        if (key == .Backspace) {
            try input.innerDeleteBackward(self);
            return;
        }
        if (key == .Delete) {
            try input.innerDeleteForward(self);
            return;
        }

        // Handle printable characters (including type=email)
        if (key.isPrintable()) {
            try input.innerInsert(key.asString(), self);
        }
        return;
    }

    if (target.is(Element.Html.TextArea)) |textarea| {
        if (key == .Backspace or key == .Delete) {
            // Minimal: clear selection or drop last char via insert replace path.
            // TextArea lacks dedicated delete helpers; drop last unit when empty selection.
            const val = textarea.getValue();
            if (val.len == 0) return;
            if (key == .Backspace) {
                const cut = if (val.len >= 1) val.len - 1 else 0;
                try textarea.setValue(val[0..cut], self);
            }
            return;
        }
        // zig fmt: off
        const append =
            if (key == .Enter) "\n"
            else if (key.isPrintable()) key.asString()
            else return
        ;
        // zig fmt: on
        return textarea.innerInsert(append, self);
    }
}

const SubmitFormOpts = struct {
    fire_event: bool = true,
};
pub fn submitForm(self: *Frame, submitter_: ?*Element, form_: ?*Element.Html.Form, submit_opts: SubmitFormOpts) !void {
    const form = form_ orelse return;

    if (submitter_) |submitter| {
        if (submitter.getAttributeSafe(comptime .wrap("disabled")) != null) {
            return;
        }
    }

    if (self.canScheduleNavigation(.form) == false) {
        return;
    }

    const form_element = form.asElement();

    const submit_button: ?*Element = blk: {
        const s = submitter_ orelse break :blk null;
        break :blk if (Element.Html.Form.isSubmitButton(s)) s else null;
    };

    const target_name_: ?[]const u8 = blk: {
        if (submit_button) |s| {
            if (s.getAttributeSafe(comptime .wrap("formtarget"))) |ft| {
                break :blk ft;
            }
        }
        break :blk form_element.getAttributeSafe(comptime .wrap("target"));
    };

    const target_frame = blk: {
        const target_name = target_name_ orelse {
            break :blk form_element.asNode().ownerFrame(self);
        };
        break :blk self.resolveTargetFrame(target_name) orelse {
            log.warn(.not_implemented, "target", .{ .type = self._type, .url = self.url, .target = target_name });
            return;
        };
    };

    if (submit_opts.fire_event) {
        // Per HTML spec "submit a form element" algorithm: SubmitEvent.submitter
        // must be null when the submitter is the form itself, which is what
        // Form.requestSubmit() passes when called with no submitter argument.
        // https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#concept-form-submit
        const submitter_html: ?*HtmlElement = blk: {
            const s = submitter_ orelse break :blk null;
            if (s == form_element) break :blk null;
            break :blk s.is(HtmlElement);
        };
        const submit_event = (try SubmitEvent.initTrusted(comptime .wrap("submit"), .{ .bubbles = true, .cancelable = true, .submitter = submitter_html }, self)).asEvent();

        // so submit_event is still valid when we check _prevent_default
        submit_event.acquireRef();
        defer _ = submit_event.releaseRef(self._page);

        try self._event_manager.dispatch(form_element.asEventTarget(), submit_event);
        // If the submit event was prevented, don't submit the form
        if (submit_event._prevent_default) {
            return;
        }
    }

    const FormData = @import("../webapi/net/FormData.zig");

    // The submitter can be an input box (if enter was entered on the box)
    // I don't think this is technically correct, but FormData handles it ok
    const form_data = try FormData.init(form, submitter_, &self.js.execution);

    const arena = try self._session.getArena(.medium, "submitForm");
    errdefer self._session.releaseArena(arena);

    // Per HTML spec form-submission algorithm, when the submitter is a submit
    // button, its formaction/formmethod/formenctype attributes override the
    // form's corresponding attributes (matching how formtarget is honored above).
    // https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#concept-form-submit
    const enctype_attr = blk: {
        if (submit_button) |s| {
            if (s.getAttributeSafe(comptime .wrap("formenctype"))) |fe| break :blk fe;
        }
        break :blk form_element.getAttributeSafe(comptime .wrap("enctype"));
    };
    const method = blk: {
        if (submit_button) |s| {
            if (s.getAttributeSafe(comptime .wrap("formmethod"))) |fm| break :blk fm;
        }
        break :blk form_element.getAttributeSafe(comptime .wrap("method")) orelse "";
    };
    const is_post = std.ascii.eqlIgnoreCase(method, "post");

    // Get charset from accept-charset attribute or fall back to document charset
    const charset: []const u8 = blk: {
        if (form_element.getAttributeSafe(.wrap("accept-charset"))) |ac| {
            // Normalize to canonical encoding name
            const info = h5e.encoding_for_label(ac.ptr, ac.len);
            if (info.isValid()) {
                break :blk info.name();
            }
        }
        break :blk self.charset;
    };

    var boundary_buf: [36]u8 = undefined;
    // GET ignores enctype per HTML spec; only resolve the union for POST.
    const encoding: FormData.EncType = blk: {
        if (is_post) {
            if (enctype_attr) |attr| {
                if (std.ascii.eqlIgnoreCase(attr, "multipart/form-data")) {
                    @import("../../support/id.zig").uuidv4(&boundary_buf);
                    break :blk .{ .formdata = &boundary_buf };
                }
                if (!std.ascii.eqlIgnoreCase(attr, "application/x-www-form-urlencoded")) {
                    log.warn(.not_implemented, "FormData.encoding", .{ .encoding = attr });
                }
            }
        }
        break :blk .urlencode;
    };

    var buf = std.Io.Writer.Allocating.init(arena);
    try form_data.write(.{ .encoding = encoding, .charset = charset, .allocator = arena }, &buf.writer);

    var action = blk: {
        if (submit_button) |s| {
            if (s.getAttributeSafe(comptime .wrap("formaction"))) |fa| break :blk fa;
        }
        break :blk form_element.getAttributeSafe(comptime .wrap("action")) orelse self.url;
    };

    var opts = NavigateOpts{
        .reason = .form,
        .kind = .{ .push = null },
    };
    if (is_post) {
        opts.method = .POST;
        opts.body = buf.written();
        opts.header = switch (encoding) {
            .urlencode => "Content-Type: application/x-www-form-urlencoded",
            .formdata => |b| try std.fmt.allocPrintSentinel(arena, "Content-Type: multipart/form-data; boundary={s}", .{b}, 0),
        };
    } else {
        action = try URL.concatQueryString(arena, action, buf.written());
    }

    return self.scheduleNavigationWithArena(arena, action, opts, .{ .form = target_frame });
}

// insertText is a shortcut to insert text into the active element.
pub fn insertText(self: *Frame, v: []const u8) !void {
    const html_element = self.document._active_element orelse return;

    if (html_element.is(Element.Html.Input)) |input| {
        const input_type = input._input_type;
        if (input_type == .radio or input_type == .checkbox) {
            return;
        }

        return input.innerInsert(v, self);
    }

    if (html_element.is(Element.Html.TextArea)) |textarea| {
        return textarea.innerInsert(v, self);
    }
}

fn asUint(comptime string: anytype) std.meta.Int(
    .unsigned,
    @bitSizeOf(@TypeOf(string.*)) - 8, // (- 8) to exclude sentinel 0
) {
    const byteLength = @sizeOf(@TypeOf(string.*)) - 1;
    const expectedType = *const [byteLength:0]u8;
    if (@TypeOf(string) != expectedType) {
        @compileError("expected : " ++ @typeName(expectedType) ++ ", got: " ++ @typeName(@TypeOf(string)));
    }

    return @bitCast(@as(*const [byteLength]u8, string).*);
}

const testing = @import("../../testing/testing.zig");
test "WebApi:Frame" {
    const filter: testing.LogFilter = .init(&.{.http});
    defer filter.deinit();
    try testing.htmlRunner("page", .{});
}

test "WebApi: Frames" {
    try testing.htmlRunner("frames", .{});
}

test "WebApi: Integration" {
    try testing.htmlRunner("integration", .{});
}

test "Frame: initial about blank inherits creator origin identity" {
    try testing.htmlRunner("regression/iframe_initial_about_blank.html", .{});
}

test "Frame: outerHTML excludes CSSOM export snapshot" {
    try testing.htmlRunner("regression/outer_html_excludes_css_snapshot.html", .{});
}

test "Frame: lazy images are not fetched eagerly without a viewport" {
    try testing.htmlRunner("regression/lazy_image_not_eager.html", .{});
}

test "Frame: WebGL reports unavailable without a headless compositor" {
    try testing.htmlRunner("regression/webgl_unavailable_headless.html", .{});
}

test "Frame: appendChild does not checkpoint microtasks inside DOM call" {
    try testing.htmlRunner("regression/append_child_microtask_order.html", .{});
}

test "Frame: iframe append does not checkpoint microtasks inside DOM call" {
    try testing.htmlRunner("regression/append_iframe_microtask_order.html", .{});
}

test "Frame: iframe contentWindow exists while child document is loading" {
    try testing.htmlRunner("regression/iframe_content_window_while_loading.html", .{});
}

test "Frame: iframe src reflects content attribute changes" {
    try testing.htmlRunner("regression/iframe_src_reflects_content_attribute.html", .{});
}

test "Frame: DOMRect serializes through toJSON" {
    try testing.htmlRunner("regression/dom_rect_to_json.html", .{});
}

test "Frame: performance timing objects serialize through toJSON" {
    try testing.htmlRunner("regression/performance_timing_to_json.html", .{});
}

test "Frame: iframe Window postMessage round-trips source origin and data" {
    try testing.htmlRunner("regression/iframe_window_post_message_roundtrip.html", .{});
}

test "Frame: iframe Window hierarchy preserves browsing-context identity" {
    try testing.htmlRunner("regression/iframe_window_hierarchy_identity.html", .{});
}

test "Frame: iframe Location uses its owning browsing context" {
    try testing.htmlRunner("regression/iframe_location_owner_browsing_context.html", .{});
}

test "Frame: iframe history and navigation are isolated from parent" {
    try testing.htmlRunner("regression/iframe_history_isolated_from_parent.html", .{});
}

test "Frame: srcdoc History URL rewriting follows about-srcdoc rules" {
    try testing.htmlRunner("regression/iframe_srcdoc_history_rewrite_rules.html", .{});
}

test "Frame: srcdoc fallback base URL is snapshotted from its creator" {
    try testing.htmlRunner("regression/iframe_srcdoc_base_snapshot.html", .{});
}

test "Frame: initial about blank fallback base URL is snapshotted from its creator" {
    try testing.htmlRunner("regression/iframe_about_blank_base_snapshot.html", .{});
}

test "Frame: static module wait exits when V8 execution is terminated" {
    const frame = try testing.test_session.createPage();
    defer testing.test_session.removePage();

    const manager = &frame._script_manager.base;
    const url = try manager.allocator.dupeZ(u8, "https://example.test/pending-module.js");
    const entry = try manager.imported_modules.getOrPut(manager.allocator, url);
    try testing.expect(!entry.found_existing);
    entry.key_ptr.* = url;
    entry.value_ptr.* = .{}; // Deliberately remains in `.loading`.

    const Terminator = struct {
        fn run(env: *JS.Env) void {
            @import("../../support/timer.zig").sleepNanoseconds(25 * std.time.ns_per_ms);
            env.terminate();
        }
    };
    const terminator = try std.Thread.spawn(.{}, Terminator.run, .{&testing.test_browser.env});
    defer terminator.join();
    defer testing.test_browser.env.cancelTerminate();

    try testing.expectError(error.ExecutionTerminated, manager.waitForImport(url));
}

test "Frame: static module dependency completion runs outside HTTP callback" {
    try testing.htmlRunner("regression/static_module_dependency_completion.html", .{});
}

test "Frame: host termination remains visible outside V8 and cancel restores execution" {
    const frame = try testing.test_session.createPage();
    defer testing.test_session.removePage();

    const env = &testing.test_browser.env;
    env.terminate();
    defer env.cancelTerminate();

    // V8's own IsExecutionTerminating may be false while no JavaScript stack
    // is active. Native module/network loops still need a durable host signal.
    try testing.expect(env.isExecutionTerminating());

    env.cancelTerminate();
    try testing.expect(!env.isExecutionTerminating());

    // Cancellation must not poison the isolate for the next operation.
    var scope: JS.Local.Scope = undefined;
    frame.js.localScope(&scope);
    defer scope.deinit();
    const result = try scope.local.exec("21 * 2", "termination recovery test");
    try testing.expectEqual(@as(i32, 42), try result.toI32());
}

test "Frame: iframe navigation drops callbacks owned by the previous realm" {
    try testing.htmlRunner("regression/navigation_drops_stale_realm_callbacks.html", .{});
}

test "Frame: removing iframe cancels child-owned asynchronous callbacks" {
    try testing.htmlRunner("regression/iframe_detach_cancels_async_callbacks.html", .{});
}

test "Frame: removing iframe aborts child fetch and XHR callback chains" {
    try testing.htmlRunner("regression/iframe_detach_aborts_fetch_xhr.html", .{});
}

test "Frame: fetch and XHR callbacks may schedule navigation without reentrant teardown" {
    try testing.htmlRunner("regression/network_callback_schedules_iframe_navigation.html", .{});
}

test "Frame: DOM wrappers do not alias objects from replaced or detached realms" {
    try testing.htmlRunner("regression/iframe_wrapper_identity_across_navigation.html", .{});
}

test "Frame: MutationObserver delivery stops when callback detaches its realm" {
    try testing.htmlRunner("regression/mutation_observer_detaches_iframe.html", .{});
}

test "Frame: custom-element callbacks may mutate their insertion safely" {
    try testing.htmlRunner("regression/custom_element_reentrant_insert_remove.html", .{});
}

test "Frame: worker and MessagePort tasks cannot enter a replaced iframe realm" {
    try testing.htmlRunner("regression/iframe_worker_port_stale_realm.html", .{});
}

test "Frame: slotchange delivery stops after callback detaches its realm" {
    try testing.htmlRunner("regression/slotchange_detaches_iframe.html", .{});
}

test "Frame: IntersectionObserver delivery stops after callback detaches its realm" {
    try testing.htmlRunner("regression/intersection_observer_detaches_iframe.html", .{});
}

test "Frame: parser document.write preserves synchronous insertion ordering" {
    try testing.htmlRunner("regression/document_write_parser_reentrancy.html", .{});
}

test "Frame: javascript iframe sources do not enter HTTP navigation" {
    try testing.htmlRunner("regression/iframe_javascript_src.html", .{});
}

test "Frame: stale iframe Document markup APIs cannot mutate a replacement realm" {
    try testing.htmlRunner("regression/stale_iframe_document_markup_noop.html", .{});
}

test "Frame: AbortSignal listener removal is safe during event dispatch" {
    try testing.htmlRunner("regression/event_listener_abort_during_dispatch.html", .{});
}

test "Frame: iframe detach during dispatch drains only the active event stack" {
    try testing.htmlRunner("regression/event_dispatch_detaches_iframe.html", .{});
}

test "Frame: iframe Window postMessage transfers a MessagePort" {
    try testing.htmlRunner("regression/iframe_window_message_port_transfer.html", .{});
}

test "Frame: removing cross-origin iframe releases child Context origin" {
    const frame = try testing.pageTest(
        "regression/iframe_cross_origin_remove_releases_context.html",
        .{},
    );
    defer testing.reset();
    defer frame._session.removePage();

    var runner = try frame._session.runner(.{});
    try runner.wait(.{ .ms = 2000 });
    try frame.runOwnedScheduler();

    try std.testing.expectEqual(@as(usize, 1), frame._page.origins.count());
    try std.testing.expectEqual(@as(usize, 1), frame.js.origin.rc);
}

test "Frame: MessagePort postMessage queues a task" {
    try testing.htmlRunner("regression/message_port_async_delivery.html", .{});
}

test "Frame: MessagePort tasks have a microtask checkpoint between deliveries" {
    try testing.htmlRunner("regression/message_port_intertask_microtask.html", .{});
}

test "Frame: timer scheduling does not checkpoint microtasks inside host call" {
    try testing.htmlRunner("regression/timer_scheduling_microtask_order.html", .{});
}

test "Frame: Window omits non-browser immediate timer APIs" {
    try testing.htmlRunner("regression/window_omits_set_immediate.html", .{});
}

test "Frame: user-agent media events release dispatch-owned arenas" {
    try testing.htmlRunner("regression/media_internal_event_ownership.html", .{});
}

test "Frame: image error event is queued after src setter returns" {
    try testing.htmlRunner("regression/image_error_event_async.html", .{});
}

test "Frame: stale image request generation cannot dispatch events" {
    try testing.htmlRunner("regression/image_stale_generation_event.html", .{});
}

test "Frame: link preload error event is queued after DOM insertion" {
    try testing.htmlRunner("regression/link_error_event_async.html", .{});
}

test "Frame: script load event is queued after DOM insertion" {
    try testing.htmlRunner("regression/script_load_event_async.html", .{});
}

test "Frame: ReadableStream closes only after queued chunks drain" {
    try testing.htmlRunner("regression/readable_stream_close_after_queue.html", .{});
}

test "Frame: fetch resolves on headers and streams body chunks" {
    try testing.htmlRunner("regression/fetch_resolves_on_headers_streaming.html", .{});
}

test "Frame: DOM wrappers preserve object identity across traversal" {
    try testing.htmlRunner("regression/dom_wrapper_identity.html", .{});
}

test "Frame: OfflineAudioContext currentTime schedules AudioParam" {
    try testing.htmlRunner("regression/offline_audio_current_time.html", .{});
}

test "Frame: basic DOM tree mutations preserve browser invariants" {
    try testing.htmlRunner("regression/dom_tree_mutation_invariants.html", .{});
}

test "Frame: DOM event propagation and listener mutation follow browser ordering" {
    try testing.htmlRunner("regression/event_propagation_invariants.html", .{});
}

test "Frame: common form controls expose live successful state" {
    try testing.htmlRunner("regression/form_control_state_invariants.html", .{});
}

test "Frame: Promise and MutationObserver callbacks share a deterministic checkpoint" {
    try testing.htmlRunner("regression/microtask_mutation_observer_order.html", .{});
}

test "Frame: live DOM collections track structural and attribute mutations" {
    try testing.htmlRunner("regression/live_collections_track_dom_mutations.html", .{});
}

test "Frame: document lifecycle events follow loading interactive complete order" {
    try testing.htmlRunner("regression/document_lifecycle_event_order.html", .{});
}

test "Frame: dynamic base URL changes invalidate relative URL resolution" {
    try testing.htmlRunner("regression/dynamic_base_url_invalidation.html", .{});
}

test "Page: isSameOrigin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var frame: Frame = undefined;

    frame.origin = null;
    try testing.expectEqual(false, frame.isSameOrigin("https://origin.com/"));

    frame.origin = try URL.getOrigin(allocator, "https://origin.com/foo/bar") orelse unreachable;
    try testing.expectEqual(true, frame.isSameOrigin("https://origin.com/foo/bar")); // exact same
    try testing.expectEqual(true, frame.isSameOrigin("https://origin.com/bar/bar")); // path differ
    try testing.expectEqual(true, frame.isSameOrigin("https://origin.com/")); // path differ
    try testing.expectEqual(true, frame.isSameOrigin("https://origin.com")); // no path
    try testing.expectEqual(true, frame.isSameOrigin("https://origin.com/foo?q=1"));
    try testing.expectEqual(true, frame.isSameOrigin("https://origin.com/foo#hash"));
    try testing.expectEqual(true, frame.isSameOrigin("https://origin.com/foo?q=1#hash"));
    // FIXME try testing.expectEqual(true, frame.isSameOrigin("https://foo:bar@origin.com"));
    // FIXME try testing.expectEqual(true, frame.isSameOrigin("https://origin.com:443/foo"));

    try testing.expectEqual(false, frame.isSameOrigin("http://origin.com/")); // another proto
    try testing.expectEqual(false, frame.isSameOrigin("https://origin.com:123/")); // another port
    try testing.expectEqual(false, frame.isSameOrigin("https://sub.origin.com/")); // another subdomain
    try testing.expectEqual(false, frame.isSameOrigin("https://target.com/")); // different domain
    try testing.expectEqual(false, frame.isSameOrigin("https://origin.com.target.com/")); // different domain
    try testing.expectEqual(false, frame.isSameOrigin("https://target.com/@origin.com"));

    frame.origin = try URL.getOrigin(allocator, "https://origin.com:8443/foo") orelse unreachable;
    try testing.expectEqual(true, frame.isSameOrigin("https://origin.com:8443/bar"));
    try testing.expectEqual(false, frame.isSameOrigin("https://origin.com/bar")); // missing port
    try testing.expectEqual(false, frame.isSameOrigin("https://origin.com:9999/bar")); // wrong port

    try testing.expectEqual(false, frame.isSameOrigin(""));
    try testing.expectEqual(false, frame.isSameOrigin("not-a-url"));
    try testing.expectEqual(false, frame.isSameOrigin("//origin.com/foo"));
}

test "ParseState: deferred HTML transfers arena ownership" {
    var buffer: std.ArrayList(u8) = .empty;
    try buffer.appendSlice(testing.allocator, "<html></html>");
    defer buffer.deinit(testing.allocator);

    var state: ParseState = .{ .html = .{
        .arena = testing.allocator,
        .buffer = buffer,
    } };
    const html = state.takeHtmlForDeferred() orelse return error.TestExpectedEqual;

    try testing.expect(state == .deferred_html);
    try testing.expectEqualStrings("<html></html>", html.buffer.items);
    try testing.expect(html.arena.ptr == testing.allocator.ptr);
}

test "CSS animation terminal delay follows computed time lists" {
    try testing.expectEqual(@as(u32, 250), cssTimelineDurationMs("0.2s", "50ms"));
    try testing.expectEqual(@as(u32, 900), cssTimelineDurationMs("100ms, 1s", "50ms, -100ms"));
    try testing.expectEqual(@as(u32, 1200), cssTimelineDurationMs("1s, 200ms", "200ms"));
    try testing.expectEqual(@as(u32, 2000), cssTimelineDurationMs("0s", "2s"));
}
