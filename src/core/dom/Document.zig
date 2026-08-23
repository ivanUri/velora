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

const js = @import("../js/js.zig");
const Frame = @import("../browser/Frame.zig");
const URL = @import("../browser/URL.zig");

const Node = @import("Node.zig");
const Element = @import("Element.zig");
const Location = @import("../webapi/Location.zig");
const Parser = @import("../parser/Parser.zig");
const collections = @import("../webapi/collections.zig");
const Selector = @import("../webapi/selector/Selector.zig");
const DOMTreeWalker = @import("DOMTreeWalker.zig");
const DOMNodeIterator = @import("DOMNodeIterator.zig");
const DOMImplementation = @import("DOMImplementation.zig");
const StyleSheetList = @import("../webapi/css/StyleSheetList.zig");
const FontFaceSet = @import("../webapi/css/FontFaceSet.zig");
const Selection = @import("../webapi/Selection.zig");
const XPathResult = @import("../webapi/XPathResult.zig");
const XPathExpression = @import("../webapi/XPathExpression.zig");

pub const XMLDocument = @import("../webapi/XMLDocument.zig");
pub const HTMLDocument = @import("../webapi/HTMLDocument.zig");

const log = @import("../../support/log.zig");
const String = @import("../../support/string.zig").String;
const IS_DEBUG = @import("builtin").mode == .Debug;

const Document = @This();

_type: Type,
_proto: *Node,
_frame: ?*Frame = null,
_location: ?*Location = null,
_url: ?[:0]const u8 = null, // URL for documents created via DOMImplementation (about:blank)
_ready_state: ReadyState = .loading,
_current_script: ?*Element.Html.Script = null,
_elements_by_id: std.StringHashMapUnmanaged(*Element) = .empty,
// Track IDs that were removed from the map - they might have duplicates in the tree
_removed_ids: std.StringHashMapUnmanaged(void) = .empty,
_active_element: ?*Element = null,
_style_sheets: ?*StyleSheetList = null,
_implementation: ?*DOMImplementation = null,
_fonts: ?*FontFaceSet = null,
_write_insertion_point: ?*Node = null,
_script_created_parser: ?Parser.Streaming = null,
_adopted_style_sheets: ?js.Object.Global = null,
_selection: Selection = .{ ._rc = .init(1) },

// https://html.spec.whatwg.org/multipage/dynamic-markup-insertion.html#throw-on-dynamic-markup-insertion-counter
// Incremented during custom element reactions when parsing. When > 0,
// document.open/close/write/writeln must throw InvalidStateError.
_throw_on_dynamic_markup_insertion_counter: u32 = 0,

_visibility_hidden: bool = false,

_on_selectionchange: ?js.Function.Global = null,
_on_visibilitychange: ?js.Function.Global = null,

pub fn getHidden(self: *const Document) bool {
    return self._visibility_hidden;
}

pub fn getVisibilityState(self: *const Document) []const u8 {
    return if (self._visibility_hidden) "hidden" else "visible";
}

pub fn markVisibilityHidden(self: *Document) void {
    self._visibility_hidden = true;
}

pub fn getOnSelectionChange(self: *Document) ?js.Function.Global {
    return self._on_selectionchange;
}

pub fn setOnSelectionChange(self: *Document, listener: ?js.Function) !void {
    if (listener) |listen| {
        self._on_selectionchange = try listen.persistWithThis(self);
    } else {
        self._on_selectionchange = null;
    }
}

pub fn getOnVisibilityChange(self: *const Document) ?js.Function.Global {
    return self._on_visibilitychange;
}

pub fn setOnVisibilityChange(self: *Document, listener: ?js.Function) !void {
    const doc_frame = self._frame orelse {
        if (listener) |listen| {
            self._on_visibilitychange = try listen.persist();
        } else {
            self._on_visibilitychange = null;
        }
        return;
    };
    const target = self.asEventTarget();
    const em = &doc_frame._event_manager;

    if (self._on_visibilitychange) |prev| {
        var scope: js.Local.Scope = undefined;
        doc_frame.js.localScope(&scope);
        defer scope.deinit();
        if (js.v8.v8__Global__Get(&prev.handle, scope.local.isolate.handle)) |handle| {
            const prev_func = js.Function{
                .local = &scope.local,
                .handle = @ptrCast(handle),
            };
            em.remove(target, "visibilitychange", .{ .function = prev_func }, false);
        }
    }

    if (listener) |listen| {
        self._on_visibilitychange = try listen.persist();
        try em.register(target, "visibilitychange", .{ .function = listen }, .{});
    } else {
        self._on_visibilitychange = null;
    }
}

pub const Type = union(enum) {
    generic,
    html: *HTMLDocument,
    xml: *XMLDocument,
};

pub fn is(self: *Document, comptime T: type) ?*T {
    switch (self._type) {
        .html => |html| {
            if (T == HTMLDocument) {
                return html;
            }
        },
        .xml => |xml| {
            if (T == XMLDocument) {
                return xml;
            }
        },
        .generic => {},
    }
    return null;
}

pub fn as(self: *Document, comptime T: type) *T {
    return self.is(T).?;
}

pub fn asNode(self: *Document) *Node {
    return self._proto;
}

pub fn asEventTarget(self: *Document) *@import("../webapi/EventTarget.zig") {
    return self._proto.asEventTarget();
}

/// HTML: Document.currentScript — the classic script element currently evaluating,
/// or null. Must live on Document (not only HTMLDocument) so:
/// 1) it matches the IDL / Chrome shape used by CreepJS feature order, and
/// 2) creepjs_compat_shim does not install a permanent `return null` getter on
///    Document.prototype (that shim only defines missing keys; SPA/Next
///    getAssetPrefix does `document.currentScript instanceof HTMLScriptElement`).
pub fn getCurrentScript(self: *const Document) ?*Element.Html.Script {
    return self._current_script;
}

pub fn getURL(self: *const Document, frame: *const Frame) [:0]const u8 {
    // Prefer this document's own browsing-context URL. The injected `frame`
    // is the caller's realm (parent when reading iframe.contentDocument.URL).
    if (self._url) |u| return u;
    if (self._frame) |doc_frame| return doc_frame.url;
    return frame.url;
}

pub fn getContentType(self: *const Document) []const u8 {
    return switch (self._type) {
        .html => "text/html",
        .xml => "application/xml",
        .generic => "application/xml",
    };
}

pub fn getDomain(_: *const Document, frame: *const Frame) []const u8 {
    return URL.getHostname(frame.url);
}

const CreateElementOptions = struct {
    is: ?[]const u8 = null,
};

pub fn createElement(self: *Document, name: []const u8, options_: ?CreateElementOptions, frame: *Frame) !*Element {
    try validateElementName(name);
    const ns: Element.Namespace, const normalized_name = blk: {
        if (self._type == .html) {
            break :blk .{ .html, std.ascii.lowerString(&frame.buf, name) };
        }
        // Generic and XML documents create elements with null namespace
        break :blk .{ .null, name };
    };
    // HTML documents are case-insensitive - lowercase the tag name

    const node = try frame.createElementNS(ns, normalized_name, null);
    const element = node.as(Element);

    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }

    const options = options_ orelse return element;
    if (options.is) |is_value| {
        try element.setAttribute(comptime .wrap("is"), .wrap(is_value), frame);
        try Element.Html.Custom.checkAndAttachBuiltIn(element, frame);
    }

    return element;
}

pub fn createElementNS(self: *Document, namespace: ?[]const u8, name: []const u8, frame: *Frame) !*Element {
    try validateElementName(name);
    const ns = Element.Namespace.parse(namespace);
    // Per spec, createElementNS does NOT lowercase (unlike createElement).
    const node = try frame.createElementNS(ns, name, null);

    // Store original URI for unknown namespaces so lookupNamespaceURI can return it
    if (ns == .unknown) {
        if (namespace) |uri| {
            const duped = try frame.dupeString(uri);
            try frame._element_namespace_uris.put(frame.arena, node.as(Element), duped);
        }
    }

    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }
    return node.as(Element);
}

pub fn createAttribute(_: *const Document, name: String.Global, frame: *Frame) !?*Element.Attribute {
    try Element.Attribute.validateAttributeName(name.str);
    return frame._factory.node(Element.Attribute{
        ._proto = undefined,
        ._name = name.str,
        ._value = String.empty,
        ._element = null,
    });
}

pub fn createAttributeNS(_: *const Document, namespace: []const u8, name: String.Global, frame: *Frame) !?*Element.Attribute {
    if (std.mem.eql(u8, namespace, "http://www.w3.org/1999/xhtml") == false) {
        log.warn(.not_implemented, "document.createAttributeNS", .{ .namespace = namespace });
    }

    try Element.Attribute.validateAttributeName(name.str);
    return frame._factory.node(Element.Attribute{
        ._proto = undefined,
        ._name = name.str,
        ._value = String.empty,
        ._element = null,
    });
}

pub fn getElementById(self: *Document, id: []const u8, frame: *Frame) ?*Element {
    if (id.len == 0) {
        return null;
    }

    if (self._elements_by_id.get(id)) |element| {
        return element;
    }

    // Slow path: id map miss (innerHTML / importNode / adoption may skip indexing).
    _ = self._removed_ids.remove(id);
    var tw = @import("TreeWalker.zig").Full.Elements.init(self.asNode(), .{});
    while (tw.next()) |el| {
        const element_id = el.getAttributeSafe(comptime .wrap("id")) orelse continue;
        if (std.mem.eql(u8, element_id, id)) {
            const owned_id = frame.dupeString(id) catch return null;
            self._elements_by_id.put(frame.arena, owned_id, el) catch return null;
            return el;
        }
    }

    return null;
}

pub fn getElementsByTagName(self: *Document, tag_name: []const u8, frame: *Frame) !Node.GetElementsByTagNameResult {
    return self.asNode().getElementsByTagName(tag_name, frame);
}

pub fn getElementsByTagNameNS(self: *Document, namespace: ?[]const u8, local_name: []const u8, frame: *Frame) !collections.NodeLive(.tag_name_ns) {
    return self.asNode().getElementsByTagNameNS(namespace, local_name, frame);
}

pub fn getElementsByClassName(self: *Document, class_name: []const u8, frame: *Frame) !collections.NodeLive(.class_name) {
    return self.asNode().getElementsByClassName(class_name, frame);
}

pub fn getElementsByName(self: *Document, name: []const u8, frame: *Frame) !collections.NodeLive(.name) {
    const arena = frame.arena;
    const filter = try arena.dupe(u8, name);
    return collections.NodeLive(.name).init(self.asNode(), filter, frame);
}

pub fn getChildren(self: *Document, frame: *Frame) !collections.NodeLive(.child_elements) {
    return collections.NodeLive(.child_elements).init(self.asNode(), {}, frame);
}

pub fn getDocumentElement(self: *Document) ?*Element {
    var child = self.asNode().firstChild();
    while (child) |node| {
        if (node.is(Element)) |el| {
            return el;
        }
        child = node.nextSibling();
    }
    return null;
}

// ----------------------------------------------------------------------
// `title` IDL attribute (HTML spec, applies to ALL Document objects).
// ----------------------------------------------------------------------
//
// The "title element of a document" is defined as:
//   * if the document element is an SVG `svg` element, the first child
//     element of the document element (in tree order) that is an SVG
//     `title` element;
//   * otherwise, the first descendant of the document (in tree order)
//     that is an HTML `title` element.
//
// The setter mirrors the getter, falling through to "do nothing" when
// the document element is neither an SVG `svg` nor an HTML element.
// We deliberately put this on Document (not HTMLDocument) so that
// XMLDocument objects produced by `DOMImplementation.createDocument`
// expose the IDL attribute with the correct semantics.
fn isSvgRootSvg(root: *Element) bool {
    return root._namespace == .svg and std.mem.eql(u8, root.getLocalName(), "svg");
}

fn findTitleElement(self: *Document) ?*Element {
    const root = self.getDocumentElement() orelse return null;

    if (isSvgRootSvg(root)) {
        // SVG case: only direct children of <svg>.
        var child = root.asNode().firstChild();
        while (child) |node| : (child = node.nextSibling()) {
            const el = node.is(Element) orelse continue;
            if (el._namespace == .svg and std.mem.eql(u8, el.getLocalName(), "title")) {
                return el;
            }
        }
        return null;
    }

    // Non-SVG-rooted: first HTML title element anywhere in the document.
    var walker = @import("TreeWalker.zig").Full.init(self.asNode(), .{});
    while (walker.next()) |node| {
        const el = node.is(Element) orelse continue;
        if (el._namespace == .html and std.mem.eql(u8, el.getLocalName(), "title")) {
            return el;
        }
    }
    return null;
}

pub fn getTitle(self: *Document, frame: *Frame) ![]const u8 {
    const title_element = findTitleElement(self) orelse return "";

    var buf = std.Io.Writer.Allocating.init(frame.call_arena);
    try title_element.asNode().getTextContent(&buf.writer);
    const text = buf.written();
    if (text.len == 0) return "";

    // "Strip and collapse ASCII whitespace" per the spec.
    var started = false;
    var in_whitespace = false;
    var result: std.ArrayList(u8) = .empty;
    try result.ensureTotalCapacity(frame.call_arena, text.len);
    for (text) |c| {
        const is_ascii_ws = c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0C';
        if (is_ascii_ws) {
            if (started) in_whitespace = true;
            continue;
        }
        if (in_whitespace) {
            result.appendAssumeCapacity(' ');
            in_whitespace = false;
        }
        result.appendAssumeCapacity(c);
        started = true;
    }
    return result.items;
}

pub fn setTitle(self: *Document, value: []const u8, frame: *Frame) !void {
    const root = self.getDocumentElement() orelse return;

    if (isSvgRootSvg(root)) {
        // Find existing SVG title direct child, or create one and prepend.
        var child = root.asNode().firstChild();
        while (child) |node| : (child = node.nextSibling()) {
            const el = node.is(Element) orelse continue;
            if (el._namespace == .svg and std.mem.eql(u8, el.getLocalName(), "title")) {
                if (value.len == 0) return el.replaceChildren(&.{}, frame);
                return el.replaceChildren(&.{.{ .text = value }}, frame);
            }
        }
        const new_title_node = try frame.createElementNS(.svg, "title", null);
        if (value.len > 0) {
            try new_title_node.as(Element).replaceChildren(&.{.{ .text = value }}, frame);
        }
        const root_node = root.asNode();
        if (root_node.firstChild()) |first| {
            _ = try root_node.insertBefore(new_title_node, first, frame);
        } else {
            _ = try root_node.appendChild(new_title_node, frame);
        }
        return;
    }

    if (root._namespace != .html) {
        // Per spec step 3: do nothing.
        return;
    }

    // HTML-rooted document: reuse first HTML title in tree, or create one
    // inside <head> when the document has a head.
    var walker = @import("TreeWalker.zig").Full.init(self.asNode(), .{});
    while (walker.next()) |node| {
        const el = node.is(Element) orelse continue;
        if (el._namespace == .html and std.mem.eql(u8, el.getLocalName(), "title")) {
            if (value.len == 0) return el.replaceChildren(&.{}, frame);
            return el.replaceChildren(&.{.{ .text = value }}, frame);
        }
    }

    // No title present yet. We need a <head> to attach it to.
    const html_doc = self.is(HTMLDocument) orelse return;
    const head = html_doc.getHead() orelse return;
    const new_title_node = try frame.createElementNS(.html, "title", null);
    if (value.len > 0) {
        try new_title_node.as(Element).replaceChildren(&.{.{ .text = value }}, frame);
    }
    _ = try head.asNode().appendChild(new_title_node, frame);
}

pub fn getSelection(self: *Document) *Selection {
    return &self._selection;
}

pub fn querySelector(self: *Document, input: String, frame: *Frame) !?*Element {
    return Selector.querySelector(self.asNode(), input.str(), frame);
}

pub fn querySelectorAll(self: *Document, input: String, frame: *Frame) !*Selector.List {
    return Selector.querySelectorAll(self.asNode(), input.str(), frame);
}

pub fn getImplementation(self: *Document, frame: *Frame) !*DOMImplementation {
    if (self._implementation) |impl| return impl;
    const impl = try frame._factory.create(DOMImplementation{});
    self._implementation = impl;
    return impl;
}

pub fn createDocumentFragment(self: *Document, frame: *Frame) !*Node.DocumentFragment {
    const frag = try Node.DocumentFragment.init(frame);
    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(frag.asNode(), self);
    }
    return frag;
}

pub fn createComment(self: *Document, data: []const u8, frame: *Frame) !*Node {
    const node = try frame.createComment(data);
    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }
    return node;
}

pub fn createTextNode(self: *Document, data: []const u8, frame: *Frame) !*Node {
    const node = try frame.createTextNode(data);
    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }
    return node;
}

pub fn createCDATASection(self: *Document, data: []const u8, frame: *Frame) !*Node {
    const node = switch (self._type) {
        .html => return error.NotSupported, // cannot create a CDataSection in an HTMLDocument
        .xml => try frame.createCDATASection(data),
        .generic => try frame.createCDATASection(data),
    };
    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }
    return node;
}

pub fn createProcessingInstruction(self: *Document, target: []const u8, data: []const u8, frame: *Frame) !*Node {
    const node = try frame.createProcessingInstruction(target, data);
    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }
    return node;
}

const Range = @import("../webapi/Range.zig");
pub fn createRange(_: *const Document, frame: *Frame) !*Range {
    return Range.init(frame);
}

pub fn createEvent(_: *const Document, event_type: []const u8, frame: *Frame) !*@import("../webapi/Event.zig") {
    const Event = @import("../webapi/Event.zig");
    if (event_type.len > 100) {
        return error.NotSupported;
    }
    const normalized = std.ascii.lowerString(&frame.buf, event_type);

    if (std.mem.eql(u8, normalized, "event") or std.mem.eql(u8, normalized, "events") or std.mem.eql(u8, normalized, "htmlevents")) {
        return Event.init("", null, frame._page);
    }

    if (std.mem.eql(u8, normalized, "customevent") or std.mem.eql(u8, normalized, "customevents")) {
        const CustomEvent = @import("../webapi/event/CustomEvent.zig");
        return (try CustomEvent.init("", null, frame._page)).asEvent();
    }

    if (std.mem.eql(u8, normalized, "keyboardevent")) {
        const KeyboardEvent = @import("../webapi/event/KeyboardEvent.zig");
        return (try KeyboardEvent.init("", null, frame)).asEvent();
    }

    if (std.mem.eql(u8, normalized, "inputevent")) {
        const InputEvent = @import("../webapi/event/InputEvent.zig");
        return (try InputEvent.init("", null, frame)).asEvent();
    }

    if (std.mem.eql(u8, normalized, "mouseevent") or std.mem.eql(u8, normalized, "mouseevents")) {
        const MouseEvent = @import("../webapi/event/MouseEvent.zig");
        return (try MouseEvent.init("", null, frame)).asEvent();
    }

    if (std.mem.eql(u8, normalized, "messageevent")) {
        const MessageEvent = @import("../webapi/event/MessageEvent.zig");
        return (try MessageEvent.init("", null, frame._page)).asEvent();
    }

    if (std.mem.eql(u8, normalized, "uievent") or std.mem.eql(u8, normalized, "uievents")) {
        const UIEvent = @import("../webapi/event/UIEvent.zig");
        return (try UIEvent.init("", null, frame)).asEvent();
    }

    if (std.mem.eql(u8, normalized, "focusevent") or std.mem.eql(u8, normalized, "focusevents")) {
        const FocusEvent = @import("../webapi/event/FocusEvent.zig");
        return (try FocusEvent.init("", null, frame)).asEvent();
    }

    if (std.mem.eql(u8, normalized, "textevent") or std.mem.eql(u8, normalized, "textevents")) {
        const TextEvent = @import("../webapi/event/TextEvent.zig");
        return (try TextEvent.init("", null, frame)).asEvent();
    }

    if (std.mem.eql(u8, normalized, "compositionevent")) {
        const CompositionEvent = @import("../webapi/event/CompositionEvent.zig");
        return (try CompositionEvent.init("", null, frame)).asEvent();
    }

    // Chrome rejects legacy createEvent for TouchEvent with a DOMException (not NotSupportedError).
    // Google sign-in browserinfo probes this path for the touch-capability bit.
    if (std.mem.eql(u8, normalized, "touchevent") or std.mem.eql(u8, normalized, "touchevents")) {
        return error.InvalidEventType;
    }

    return error.NotSupported;
}

pub fn createTreeWalker(_: *const Document, root: *Node, what_to_show: ?js.Value, filter: ?DOMTreeWalker.FilterOpts, frame: *Frame) !*DOMTreeWalker {
    return DOMTreeWalker.init(root, try whatToShow(what_to_show), filter, frame);
}

pub fn createNodeIterator(_: *const Document, root: *Node, what_to_show: ?js.Value, filter: ?DOMNodeIterator.FilterOpts, frame: *Frame) !*DOMNodeIterator {
    return DOMNodeIterator.init(root, try whatToShow(what_to_show), filter, frame);
}

pub fn evaluate(
    self: *Document,
    expression: []const u8,
    context_node: ?*Node,
    resolver: ?js.Function,
    result_type: ?u16,
    result: ?*XPathResult,
    frame: *Frame,
) !*XPathResult {
    // Namespace resolver / result reuse are no-ops in HTML mode (Koko decision #2).
    _ = resolver;
    _ = result;
    return XPathResult.fromExpression(
        expression,
        context_node orelse self.asNode(),
        result_type orelse XPathResult.ANY_TYPE,
        frame,
    );
}

pub fn createExpression(
    _: *const Document,
    expression: []const u8,
    resolver: ?js.Function,
    frame: *Frame,
) !*XPathExpression {
    _ = resolver;
    return XPathExpression.init(expression, frame);
}

pub fn createNSResolver(_: *const Document, node: *Node) ?*Node {
    return node;
}

fn whatToShow(value_: ?js.Value) !u32 {
    const value = value_ orelse return 4294967295; // show all when undefined
    if (value.isUndefined()) {
        // undefined explicitly passed
        return 4294967295;
    }

    if (value.isNull()) {
        return 0;
    }

    return value.toZig(u32);
}

pub fn getReadyState(self: *const Document) []const u8 {
    return @tagName(self._ready_state);
}

/// Active browsing context for this document, if any. Detached documents (e.g.
/// after iframe navigation/remove) have `_frame == null`, or the frame is
/// draining/dead / no longer owns this document.
pub fn activeBrowsingContext(self: *const Document) ?*Frame {
    const frame = self._frame orelse return null;
    if (frame.document != self) return null;
    // Departing realms must not be used for document.open/write/close.
    if (frame._detach_pending) return null;
    if (frame._realm_state != .active) return null;
    if (frame.isGoingAway()) return null;
    return frame;
}

pub fn getCookie(self: *Document, _: *Frame) ![]const u8 {
    const html_doc = self.is(HTMLDocument) orelse return "";
    return HTMLDocument.getCookie(html_doc);
}

pub fn setCookie(self: *Document, cookie_str: []const u8, _: *Frame) ![]const u8 {
    const html_doc = self.is(HTMLDocument) orelse return "";
    return HTMLDocument.setCookie(html_doc, cookie_str);
}

pub fn getActiveElement(self: *Document) ?*Element {
    if (self._active_element) |el| {
        return el;
    }

    // Default to body if it exists
    if (self.is(HTMLDocument)) |html_doc| {
        if (html_doc.getBody()) |body| {
            return body;
        }
    }

    // Fallback to document element
    return self.getDocumentElement();
}

pub fn getStyleSheets(self: *Document, frame: *Frame) !*StyleSheetList {
    if (self._style_sheets) |sheets| {
        return sheets;
    }
    const sheets = try StyleSheetList.init(frame);
    self._style_sheets = sheets;
    return sheets;
}

pub fn getFonts(self: *Document, frame: *Frame) !*FontFaceSet {
    if (self._fonts) |fonts| {
        return fonts;
    }
    const fonts = try FontFaceSet.init(frame);
    fonts.acquireRef();
    self._fonts = fonts;
    return fonts;
}

pub fn adoptNode(self: *const Document, node: *Node, frame: *Frame) !*Node {
    if (node._type == .document) {
        return error.NotSupported;
    }

    const old_owner = node.ownerDocument(frame);
    if (node._parent) |parent| {
        frame.removeNode(parent, node, .{ .will_be_reconnected = false });
    }

    if (old_owner) |old| {
        if (old != self) {
            try frame.adoptNodeTree(node, old, @constCast(self));
        }
    } else {
        try frame.setNodeOwnerDocument(node, @constCast(self));
    }

    return node;
}

pub fn importNode(_: *const Document, node: *Node, deep_: ?bool, frame: *Frame) !*Node {
    if (node._type == .document) {
        return error.NotSupported;
    }

    return node.cloneNode(deep_, frame);
}

pub fn append(self: *Document, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    try validateDocumentNodes(self, nodes, false);

    frame.domChanged();
    const parent = self.asNode();
    const parent_is_connected = parent.isConnected();

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);

        // DocumentFragments are special - append all their children
        if (child.is(Node.DocumentFragment)) |_| {
            try frame.appendAllChildren(child, parent);
            continue;
        }

        var child_connected = false;
        if (child._parent) |previous_parent| {
            child_connected = child.isConnected();
            frame.removeNode(previous_parent, child, .{ .will_be_reconnected = parent_is_connected });
        }
        try frame.appendNode(parent, child, .{ .child_already_connected = child_connected });
    }
}

pub fn prepend(self: *Document, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    try validateDocumentNodes(self, nodes, false);

    frame.domChanged();
    const parent = self.asNode();
    const parent_is_connected = parent.isConnected();

    var i = nodes.len;
    while (i > 0) {
        i -= 1;
        const child = try nodes[i].toNode(frame);

        // DocumentFragments are special - need to insert all their children
        if (child.is(Node.DocumentFragment)) |frag| {
            const first_child = parent.firstChild();
            var frag_child = frag.asNode().lastChild();
            while (frag_child) |fc| {
                const prev = fc.previousSibling();
                frame.removeNode(frag.asNode(), fc, .{ .will_be_reconnected = parent_is_connected });
                if (first_child) |before| {
                    try frame.insertNodeRelative(parent, fc, .{ .before = before }, .{});
                } else {
                    try frame.appendNode(parent, fc, .{});
                }
                frag_child = prev;
            }
            continue;
        }

        var child_connected = false;
        if (child._parent) |previous_parent| {
            child_connected = child.isConnected();
            frame.removeNode(previous_parent, child, .{ .will_be_reconnected = parent_is_connected });
        }

        const first_child = parent.firstChild();
        if (first_child) |before| {
            try frame.insertNodeRelative(parent, child, .{ .before = before }, .{ .child_already_connected = child_connected });
        } else {
            try frame.appendNode(parent, child, .{ .child_already_connected = child_connected });
        }
    }
}

pub fn replaceChildren(self: *Document, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    try validateDocumentNodes(self, nodes, false);
    return self.asNode().replaceChildren(nodes, frame);
}

pub fn elementFromPoint(self: *Document, x: f64, y: f64, frame: *Frame) !?*Element {
    // Traverse document in depth-first order to find the topmost (last in document order)
    // element that contains the point (x, y). Descend into shadow roots (open or
    // closed) so hit-testing reaches embedded widget iframes (Cloudflare Turnstile).
    var topmost: ?*Element = null;

    const root = self.asNode();
    var stack: std.ArrayList(*Node) = .empty;
    try stack.append(frame.call_arena, root);

    while (stack.items.len > 0) {
        const node = stack.pop() orelse break;
        if (node.is(Element)) |element| {
            if (element.checkVisibilityCached(null, frame)) {
                const rect = element.getBoundingClientRectForVisible(frame);
                if (x >= rect.getLeft() and x <= rect.getRight() and y >= rect.getTop() and y <= rect.getBottom()) {
                    topmost = element;
                }
            }

            if (frame._element_shadow_roots.get(element)) |shadow_root| {
                var shadow_child = shadow_root.asNode().lastChild();
                while (shadow_child) |c| {
                    try stack.append(frame.call_arena, c);
                    shadow_child = c.previousSibling();
                }
            }
        }

        // Add children to stack in reverse order so we process them in document order
        var child = node.lastChild();
        while (child) |c| {
            try stack.append(frame.call_arena, c);
            child = c.previousSibling();
        }
    }

    return topmost;
}

pub fn elementsFromPoint(self: *Document, x: f64, y: f64, frame: *Frame) ![]const *Element {
    // Get topmost element
    var current: ?*Element = (try self.elementFromPoint(x, y, frame)) orelse return &.{};
    var result: std.ArrayList(*Element) = .empty;
    while (current) |el| {
        try result.append(frame.call_arena, el);
        current = el.parentElement();
    }
    return result.items;
}

pub fn getDocType(self: *Document) ?*Node {
    var tw = @import("TreeWalker.zig").Full.init(self.asNode(), .{});
    while (tw.next()) |node| {
        if (node._type == .document_type) {
            return node;
        }
    }
    return null;
}

// document.write is complicated and works differently based on the state of
// parsing. But, generally, it's supposed to be additive/streaming. Multiple
// document.writes are parsed a single unit. Well, that causes issues with
// html5ever if we're trying to parse 1 document which is really many. So we
// try to detect "new" documents. (This is particularly problematic because we
// don't have proper frame support, so document.write into a frame can get
// sent to the main document (instead of the frame document)...and it's completely
// reasonable for 2 frames to document.write("<html>...</html>") into their own
// frame.
fn looksLikeNewDocument(html: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, html, &std.ascii.whitespace);
    return std.ascii.startsWithIgnoreCase(trimmed, "<!DOCTYPE") or
        std.ascii.startsWithIgnoreCase(trimmed, "<html");
}

/// Document's own live browsing context only. Never fall back to the caller's
/// frame: `document.open()` on a stale iframe Document used to wipe the
/// *parent* page (UAF / incorrect-alignment process death).
fn frameForDocument(self: *Document, executing: *Frame) ?*Frame {
    _ = executing;
    return self.activeBrowsingContext();
}

pub fn write(self: *Document, text: []const []const u8, frame: *Frame) !void {
    const doc_frame = self.frameForDocument(frame) orelse return;
    return self.writeInternal(text, false, doc_frame);
}

// https://html.spec.whatwg.org/multipage/dynamic-markup-insertion.html#dom-document-writeln
// `writeln(...text)` runs the document write steps with `text` followed by a
// U+000A LINE FEED character.
pub fn writeln(self: *Document, text: []const []const u8, frame: *Frame) !void {
    const doc_frame = self.frameForDocument(frame) orelse return;
    return self.writeInternal(text, true, doc_frame);
}

fn writeInternal(self: *Document, text: []const []const u8, append_newline: bool, frame: *Frame) !void {
    if (self._type == .xml) {
        return error.InvalidStateError;
    }

    if (frame._realm_state != .active or frame.isGoingAway()) {
        return;
    }

    if (self._throw_on_dynamic_markup_insertion_counter > 0) {
        return error.InvalidStateError;
    }

    const html = blk: {
        var joined: std.ArrayList(u8) = .empty;
        for (text) |str| {
            try joined.appendSlice(frame.call_arena, str);
        }
        if (append_newline) {
            try joined.append(frame.call_arena, '\n');
        }
        break :blk joined.items;
    };

    if (self._current_script == null or frame._load_state != .parsing) {
        if (self._script_created_parser == null or looksLikeNewDocument(html)) {
            _ = try self.open(frame);
        }

        if (html.len > 0) {
            if (self._script_created_parser) |*parser| {
                parser.read(html) catch |err| {
                    log.warn(.dom, "document.write parser error", .{ .err = err });
                    // was already closed
                    self._script_created_parser = null;
                };
            }
        }
        return;
    }

    // Inline script during parsing
    const script = self._current_script.?;
    const parent = script.asNode().parentNode() orelse return;

    // Our implementation is hacky. We'll write to a DocumentFragment, then
    // append its children.
    const fragment = try Node.DocumentFragment.init(frame);
    const fragment_node = fragment.asNode();

    const previous_parse_mode = frame._parse_mode;
    frame._parse_mode = .document_write;
    defer frame._parse_mode = previous_parse_mode;

    const arena = try frame.getArena(.medium, "Document.write");
    defer frame.releaseArena(arena);

    var parser = Parser.init(arena, fragment_node, frame);
    parser.parseFragment(html) catch |err| {
        // Third-party ad scripts frequently feed malformed markup through
        // document.write. html5ever reports a parser panic for some of these
        // fragments; discard that write instead of taking down the browser.
        log.warn(.dom, "document.write fragment parser error", .{ .err = err });
        return;
    };

    // Extract children from wrapper HTML element (html5ever wraps fragments)
    // https://github.com/servo/html5ever/issues/583
    const children = fragment_node._children orelse return;
    const first = children.first();

    // Collect all children to insert (to avoid iterator invalidation)
    var children_to_insert: std.ArrayList(*Node) = .empty;

    var it = if (first.is(Element.Html.Html) == null) fragment_node.childrenIterator() else first.childrenIterator();
    while (it.next()) |child| {
        try children_to_insert.append(arena, child);
    }

    if (children_to_insert.items.len == 0) {
        return;
    }

    // Determine insertion point:
    // - If _write_insertion_point is set and still parented correctly, continue from there
    // - Otherwise, start after the script (first write, or previous insertion point was removed)
    // parseFragment above can synchronously execute a parser-blocking script
    // (e.g. <script src=...> with from_parser=true). That script's side
    // effects can detach `script` from `parent` — for instance, by writing
    // to parent.innerHTML — leaving us nowhere sensible to splice in.
    var insert_after: ?*Node = blk: {
        if (self._write_insertion_point) |wip| {
            if (wip._parent == parent) {
                break :blk wip;
            }
        }
        if (script.asNode()._parent == parent) {
            break :blk script.asNode();
        }
        return;
    };

    for (children_to_insert.items) |child| {
        // Clear parent pointer (child is currently parented to fragment/HTML wrapper)
        child._parent = null;
        try frame.insertNodeRelative(parent, child, .{ .after = insert_after.? }, .{});
        insert_after = child;
    }

    frame.domChanged();
    self._write_insertion_point = children_to_insert.getLast();
}

pub fn open(self: *Document, executing: *Frame) !*Document {
    // Only the document's own live browsing context. Falling back to `executing`
    // cleared the *caller* (parent) page when iframe docs had a stale `_frame`.
    const frame = self.frameForDocument(executing) orelse return self;
    if (self._type == .xml) {
        return error.InvalidStateError;
    }

    if (self._throw_on_dynamic_markup_insertion_counter > 0) {
        return error.InvalidStateError;
    }

    // Non-active / dead document: return without mutating.
    if (frame._realm_state == .dead or frame._realm_state == .draining or frame.isGoingAway()) {
        return self;
    }

    if (frame._load_state == .parsing) {
        return self;
    }

    if (self._script_created_parser != null) {
        return self;
    }

    // If we aren't parsing, then open clears the document.
    const doc_node = self.asNode();

    // Snapshot children first — removeNode mutates the list and invalidates
    // a live childrenIterator (iframe teardown mid-iteration).
    {
        var to_remove: std.ArrayList(*Node) = .empty;
        var it = doc_node.childrenIterator();
        while (it.next()) |child| {
            try to_remove.append(frame.call_arena, child);
        }
        for (to_remove.items) |child| {
            // Child detach can drain realms; re-check between removes.
            if (frame._realm_state != .active or frame.isGoingAway()) {
                return self;
            }
            frame.removeNode(doc_node, child, .{ .will_be_reconnected = false });
        }
    }

    if (frame._realm_state != .active or frame.isGoingAway()) {
        return self;
    }

    // reset the document
    self._elements_by_id.clearAndFree(frame.arena);
    self._active_element = null;
    self._style_sheets = null;
    self._implementation = null;
    self._ready_state = .loading;

    // HTML: if document is fully active, set URL to the entry settings object's
    // API base URL. Parent scripts call iframe.contentDocument.open() — the
    // method may run with the child's realm as `executing`, so use entry/incumbent
    // (caller) rather than the document's own about:blank URL.
    if (frame._realm_state == .active and !frame.isGoingAway() and frame.document == self) {
        const entry_url = blk: {
            if (executing.js.getEntryFrame()) |entry| break :blk entry.url;
            // Incumbent = calling script's window when cross-realm method call.
            break :blk executing.js.getIncumbent().url;
        };
        if (!std.mem.eql(u8, frame.url, entry_url)) {
            frame.url = try frame.arena.dupeZ(u8, entry_url);
            frame.window._location = try Location.init(frame.url, frame);
        }
        // Prefer frame.url over a stale document._url (DOMImplementation blank).
        self._url = null;
    }

    self._script_created_parser = Parser.Streaming.init(frame.arena, doc_node, frame);
    try self._script_created_parser.?.start();
    frame._parse_mode = .document;

    return self;
}

/// Tear down an in-flight document.open/write parser without running completion.
/// Used when the owning realm is draining so html5ever cannot call back into JS.
pub fn cancelStreamingParser(self: *Document) void {
    if (self._script_created_parser) |*parser| {
        if (parser.handle != null) {
            parser.deinit();
            parser.handle = null;
        }
        self._script_created_parser = null;
    }
}

pub fn close(self: *Document, executing: *Frame) !void {
    // Detached / stale document: no live browsing context — do not touch
    // the caller's frame (same UAF class as open/write parent wipe).
    const frame = self.frameForDocument(executing) orelse return;
    if (self._type == .xml) {
        return error.InvalidStateError;
    }

    if (self._throw_on_dynamic_markup_insertion_counter > 0) {
        return error.InvalidStateError;
    }

    if (self._script_created_parser == null) {
        return;
    }

    // done() calls html5ever_streaming_parser_finish which frees the parser
    // We must NOT call deinit() after done() as that would be a double-free
    self._script_created_parser.?.done();
    // Just null out the handle since done() already freed it
    self._script_created_parser.?.handle = null;
    self._script_created_parser = null;

    frame.documentIsComplete();
}

pub fn getFirstElementChild(self: *Document) ?*Element {
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        if (child.is(Element)) |el| {
            return el;
        }
    }
    return null;
}

pub fn getLastElementChild(self: *Document) ?*Element {
    var maybe_child = self.asNode().lastChild();
    while (maybe_child) |child| {
        if (child.is(Element)) |el| {
            return el;
        }
        maybe_child = child.previousSibling();
    }
    return null;
}

pub fn getChildElementCount(self: *Document) u32 {
    var i: u32 = 0;
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        if (child.is(Element) != null) {
            i += 1;
        }
    }
    return i;
}

pub fn getAdoptedStyleSheets(self: *Document, frame: *Frame) !js.Object.Global {
    if (self._adopted_style_sheets) |ass| {
        return ass;
    }
    const js_arr = frame.js.local.?.newArray(0);
    const js_obj = js_arr.toObject();
    self._adopted_style_sheets = try js_obj.persist();
    return self._adopted_style_sheets.?;
}

pub fn hasFocus(_: *Document) bool {
    log.debug(.not_implemented, "Document.hasFocus", .{});
    return true;
}

pub fn setAdoptedStyleSheets(self: *Document, sheets: js.Object) !void {
    self._adopted_style_sheets = try sheets.persist();
}

// Validates that nodes can be inserted into a Document, respecting Document constraints:
// - At most one Element child
// - At most one DocumentType child
// - No Document, Attribute, or Text nodes
// - Only Element, DocumentType, Comment, and ProcessingInstruction are allowed
// When replacing=true, existing children are not counted (for replaceChildren)
fn validateDocumentNodes(self: *Document, nodes: []const Node.NodeOrText, comptime replacing: bool) !void {
    const parent = self.asNode();

    // Check existing elements and doctypes (unless we're replacing all children)
    var has_element = false;
    var has_doctype = false;

    if (!replacing) {
        var it = parent.childrenIterator();
        while (it.next()) |child| {
            if (child._type == .element) {
                has_element = true;
            } else if (child._type == .document_type) {
                has_doctype = true;
            }
        }
    }

    // Validate new nodes
    for (nodes) |node_or_text| {
        switch (node_or_text) {
            .text => {
                // Text nodes are not allowed as direct children of Document
                return error.HierarchyError;
            },
            .node => |child| {
                // Check if it's a DocumentFragment - need to validate its children
                if (child.is(Node.DocumentFragment)) |frag| {
                    var frag_it = frag.asNode().childrenIterator();
                    while (frag_it.next()) |frag_child| {
                        // Document can only contain: Element, DocumentType, Comment, ProcessingInstruction
                        switch (frag_child._type) {
                            .element => {
                                if (has_element) {
                                    return error.HierarchyError;
                                }
                                has_element = true;
                            },
                            .document_type => {
                                if (has_doctype) {
                                    return error.HierarchyError;
                                }
                                if (has_element) {
                                    // Doctype cannot be inserted if document already has an element
                                    return error.HierarchyError;
                                }
                                has_doctype = true;
                            },
                            .cdata => |cd| switch (cd._type) {
                                .comment, .processing_instruction => {}, // Allowed
                                .text, .cdata_section => return error.HierarchyError, // Not allowed in Document
                            },
                            .document, .attribute, .document_fragment => return error.HierarchyError,
                        }
                    }
                } else {
                    // Validate node type for direct insertion
                    switch (child._type) {
                        .element => {
                            if (has_element) {
                                return error.HierarchyError;
                            }
                            has_element = true;
                        },
                        .document_type => {
                            if (has_doctype) {
                                return error.HierarchyError;
                            }
                            if (has_element) {
                                // Doctype cannot be inserted if document already has an element
                                return error.HierarchyError;
                            }
                            has_doctype = true;
                        },
                        .cdata => |cd| switch (cd._type) {
                            .comment, .processing_instruction => {}, // Allowed
                            .text, .cdata_section => return error.HierarchyError, // Not allowed in Document
                        },
                        .document, .attribute, .document_fragment => return error.HierarchyError,
                    }
                }

                // Check for cycles
                if (child.contains(parent)) {
                    return error.HierarchyError;
                }
            },
        }
    }
}

fn validateElementName(name: []const u8) !void {
    if (name.len == 0) {
        return error.InvalidCharacterError;
    }

    const first = name[0];
    // Element names cannot start with: digits, period, hyphen
    if ((first >= '0' and first <= '9') or first == '.' or first == '-') {
        return error.InvalidCharacterError;
    }

    for (name[1..]) |c| {
        const is_valid = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-' or c == '.' or c == ':' or
            c >= 128; // Allow non-ASCII UTF-8

        if (!is_valid) {
            return error.InvalidCharacterError;
        }
    }
}

// When a frame's URL is about:blank, or as soon as a frame is
// programmatically created, it has this default "blank" content
pub fn injectBlank(self: *Document, frame: *Frame) error{InjectBlankError}!void {
    self._injectBlank(frame) catch |err| {
        // we wrap _injectBlank like this so that injectBlank can only return an
        // InjectBlankError. injectBlank is used in when nodes are inserted
        // as since it inserts node itself, Zig can't infer the error set.
        log.err(.browser, "inject blank", .{ .err = err });
        return error.InjectBlankError;
    };
}

fn _injectBlank(self: *Document, frame: *Frame) !void {
    if (comptime IS_DEBUG) {
        // should only be called on an empty document
        std.debug.assert(self.asNode()._children == null);
    }

    const html = try frame.createElementNS(.html, "html", null);
    const head = try frame.createElementNS(.html, "head", null);
    const body = try frame.createElementNS(.html, "body", null);
    try frame.appendNode(html, head, .{});
    try frame.appendNode(html, body, .{});
    try frame.appendNode(self.asNode(), html, .{});
    self._ready_state = .complete;
}

const ReadyState = enum {
    loading,
    interactive,
    complete,
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Document);

    pub const Meta = struct {
        pub const name = "Document";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const enumerable = false;
    };

    pub const constructor = bridge.constructor(_constructor, .{});
    fn _constructor(frame: *Frame) !*Document {
        return frame._factory.node(Document{
            ._proto = undefined,
            ._type = .generic,
        });
    }

    pub const onselectionchange = bridge.accessor(Document.getOnSelectionChange, Document.setOnSelectionChange, .{});
    pub const onvisibilitychange = bridge.accessor(Document.getOnVisibilityChange, Document.setOnVisibilityChange, .{});
    pub const URL = bridge.accessor(Document.getURL, null, .{});
    pub const documentURI = bridge.accessor(Document.getURL, null, .{});
    pub const documentElement = bridge.accessor(Document.getDocumentElement, null, .{});
    pub const scrollingElement = bridge.accessor(Document.getDocumentElement, null, .{});
    pub const children = bridge.accessor(Document.getChildren, null, .{ .cache = .{ .private = "children" } });
    pub const readyState = bridge.accessor(Document.getReadyState, null, .{});
    pub const implementation = bridge.accessor(Document.getImplementation, null, .{});
    pub const activeElement = bridge.accessor(Document.getActiveElement, null, .{});
    pub const styleSheets = bridge.accessor(Document.getStyleSheets, null, .{});
    pub const fonts = bridge.accessor(Document.getFonts, null, .{});
    pub const contentType = bridge.accessor(Document.getContentType, null, .{});
    pub const domain = bridge.accessor(Document.getDomain, null, .{});
    // Spec: Document.currentScript (HTML). Keep on Document.prototype so the
    // creepjs_compat_shim never installs a null-returning placeholder.
    pub const currentScript = bridge.accessor(Document.getCurrentScript, null, .{});
    pub const createElement = bridge.function(Document.createElement, .{ .dom_exception = true });
    pub const createElementNS = bridge.function(Document.createElementNS, .{ .dom_exception = true });
    pub const createDocumentFragment = bridge.function(Document.createDocumentFragment, .{});
    pub const createComment = bridge.function(Document.createComment, .{});
    pub const createTextNode = bridge.function(Document.createTextNode, .{});
    pub const createAttribute = bridge.function(Document.createAttribute, .{ .dom_exception = true });
    pub const createAttributeNS = bridge.function(Document.createAttributeNS, .{ .dom_exception = true });
    pub const createCDATASection = bridge.function(Document.createCDATASection, .{ .dom_exception = true });
    pub const createProcessingInstruction = bridge.function(Document.createProcessingInstruction, .{ .dom_exception = true });
    pub const createRange = bridge.function(Document.createRange, .{});
    pub const createEvent = bridge.function(Document.createEvent, .{ .dom_exception = true });
    pub const createTreeWalker = bridge.function(Document.createTreeWalker, .{});
    pub const createNodeIterator = bridge.function(Document.createNodeIterator, .{});
    pub const evaluate = bridge.function(Document.evaluate, .{ .dom_exception = true });
    pub const createExpression = bridge.function(Document.createExpression, .{ .dom_exception = true });
    pub const createNSResolver = bridge.function(Document.createNSResolver, .{});
    pub const getElementById = bridge.function(_getElementById, .{});
    fn _getElementById(self: *Document, value_: ?js.Value, frame: *Frame) !?*Element {
        const value = value_ orelse return null;
        if (value.isNull()) {
            return self.getElementById("null", frame);
        }
        if (value.isUndefined()) {
            return self.getElementById("undefined", frame);
        }
        return self.getElementById(try value.toZig([]const u8), frame);
    }
    pub const querySelector = bridge.function(Document.querySelector, .{ .dom_exception = true });
    pub const querySelectorAll = bridge.function(Document.querySelectorAll, .{ .dom_exception = true });
    pub const getElementsByTagName = bridge.function(Document.getElementsByTagName, .{});
    pub const getElementsByTagNameNS = bridge.function(Document.getElementsByTagNameNS, .{});
    pub const getSelection = bridge.function(Document.getSelection, .{});
    pub const getElementsByClassName = bridge.function(Document.getElementsByClassName, .{});
    pub const getElementsByName = bridge.function(Document.getElementsByName, .{});
    pub const adoptNode = bridge.function(Document.adoptNode, .{ .dom_exception = true });
    pub const importNode = bridge.function(Document.importNode, .{ .dom_exception = true });
    pub const append = bridge.function(Document.append, .{ .dom_exception = true });
    pub const prepend = bridge.function(Document.prepend, .{ .dom_exception = true });
    pub const replaceChildren = bridge.function(Document.replaceChildren, .{ .dom_exception = true });
    pub const elementFromPoint = bridge.function(Document.elementFromPoint, .{});
    pub const elementsFromPoint = bridge.function(Document.elementsFromPoint, .{});
    pub const write = bridge.function(Document.write, .{ .dom_exception = true });
    pub const writeln = bridge.function(Document.writeln, .{ .dom_exception = true });
    pub const open = bridge.function(Document.open, .{ .dom_exception = true });
    pub const close = bridge.function(Document.close, .{ .dom_exception = true });
    pub const doctype = bridge.accessor(Document.getDocType, null, .{});
    pub const firstElementChild = bridge.accessor(Document.getFirstElementChild, null, .{});
    pub const lastElementChild = bridge.accessor(Document.getLastElementChild, null, .{});
    pub const childElementCount = bridge.accessor(Document.getChildElementCount, null, .{});
    pub const adoptedStyleSheets = bridge.accessor(Document.getAdoptedStyleSheets, Document.setAdoptedStyleSheets, .{});
    pub const hidden = bridge.accessor(Document.getHidden, null, .{});
    pub const visibilityState = bridge.accessor(Document.getVisibilityState, null, .{});
    /// HTML: documents not associated with a browsing context have defaultView null.
    /// createHTMLDocument / createDocument leave `_frame == null` until adopted.
    pub const defaultView = bridge.accessor(struct {
        fn defaultView(self: *const Document, frame: *Frame) ?*@import("../webapi/Window.zig") {
            // Only the live document of a browsing context exposes a Window.
            const doc_frame = self._frame orelse return null;
            // Stale documents after navigation: frame.document may no longer be self.
            if (doc_frame.document != self) return null;
            _ = frame;
            return doc_frame.window;
        }
    }.defaultView, null, .{ .null_as_undefined = false });
    pub const hasFocus = bridge.function(Document.hasFocus, .{});

    pub const prerendering = bridge.attribute(false, .{});
    pub const characterSet = bridge.accessor(getCharacterSet, null, .{});
    pub const charset = bridge.accessor(getCharacterSet, null, .{});
    pub const inputEncoding = bridge.accessor(getCharacterSet, null, .{});
    pub const compatMode = bridge.attribute("CSS1Compat", .{});

    fn getCharacterSet(self: *const Document) []const u8 {
        const doc_frame = self._frame orelse return "UTF-8";
        return doc_frame.charset;
    }
    pub const referrer = bridge.attribute("", .{});
    pub const title = bridge.accessor(Document.getTitle, Document.setTitle, .{});
    pub const cookie = bridge.accessor(Document.getCookie, Document.setCookie, .{});
};

const testing = @import("../../testing/testing.zig");
test "WebApi: Document" {
    try testing.htmlRunner("document", .{});
}
