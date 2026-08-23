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
const datetime = @import("../../support/datetime.zig");
const js = @import("../js/js.zig");

const Frame = @import("../browser/Frame.zig");
const Node = @import("../dom/Node.zig");
const Document = @import("../dom/Document.zig");
const Element = @import("../dom/Element.zig");
const DocumentType = @import("../dom/DocumentType.zig");
const TreeWalker = @import("../dom/TreeWalker.zig");
const IFrame = @import("element/html/IFrame.zig");
const collections = @import("collections.zig");
const String = @import("../../support/string.zig").String;

const HTMLDocument = @This();

_proto: *Document,
_document_type: ?*DocumentType = null,

pub fn asDocument(self: *HTMLDocument) *Document {
    return self._proto;
}

pub fn asNode(self: *HTMLDocument) *Node {
    return self._proto.asNode();
}

pub fn asEventTarget(self: *HTMLDocument) *@import("EventTarget.zig") {
    return self._proto.asEventTarget();
}

// HTML-specific accessors
//
// Per the HTML spec, the head/body IDL attributes return the first
// child of the document element whose **local name is "head"/"body"
// in the HTML namespace**, regardless of any prefix. That means
// `document.createElementNS(HTML_NS, "x:head")` is also a valid head
// element. The earlier implementation only matched the strongly-typed
// `Element.Html.Head`/`Body`, which excluded prefixed-but-still-HTML
// elements as well as foreign-namespace `<head>` lookalikes (the
// latter must NOT be returned).
fn isHtmlElementWithLocalName(el: *Element, local: []const u8) bool {
    if (el._namespace != .html) return false;
    return std.mem.eql(u8, el.getLocalName(), local);
}

pub fn getHead(self: *HTMLDocument) ?*Element {
    const doc_el = self._proto.getDocumentElement() orelse return null;
    var child = doc_el.asNode().firstChild();
    while (child) |node| {
        if (node.is(Element)) |el| {
            if (isHtmlElementWithLocalName(el, "head")) return el;
        }
        child = node.nextSibling();
    }
    return null;
}

pub fn getBody(self: *HTMLDocument) ?*Element {
    const document_element = self._proto.getDocumentElement() orelse return null;
    if (findBodyForDoc(document_element)) |body| return body;

    // Turnstile / challenge widgets often run inline scripts before the parser
    // inserts an explicit <body>. Chrome exposes a live body element once
    // <html> exists; synthesize one so `document.body.appendChild` does not throw.
    const frame = self._proto._frame orelse return null;
    const body_node = frame.createElementNS(.html, "body", null) catch return null;
    _ = document_element.asNode().appendChild(body_node, frame) catch return null;
    return body_node.is(Element);
}

pub fn setBody(self: *HTMLDocument, html: []const u8, frame: *Frame) !void {
    const document_element = self._proto.getDocumentElement() orelse return error.HierarchyError;

    // Build a fresh <body> holding the parsed HTML as its children. Fragment
    // parsing strips any <html>/<body>/<head> wrappers the author included.
    const new_body_node = try frame.createElementNS(.html, "body", null);
    if (html.len > 0) {
        try frame.parseHtmlAsChildren(new_body_node, html);
    }

    const document_node = document_element.asNode();
    if (findBodyForDoc(document_element)) |current| {
        _ = try document_node.replaceChild(new_body_node, current.asNode(), frame);
    } else {
        _ = try document_node.appendChild(new_body_node, frame);
    }
}

fn findBodyForDoc(document_element: *Element) ?*Element {
    var child = document_element.asNode().firstChild();
    while (child) |node| {
        if (node.is(Element)) |el| {
            if (isHtmlElementWithLocalName(el, "body") or
                isHtmlElementWithLocalName(el, "frameset"))
            {
                return el;
            }
        }
        child = node.nextSibling();
    }
    return null;
}

// `getTitle` / `setTitle` live on Document.zig now so that XMLDocument
// (and SVG-rooted documents created via DOMImplementation.createDocument)
// expose `title` correctly per spec. Keep this comment as a breadcrumb.

// Per the HTML spec, document.{images,scripts,forms,embeds,plugins}
// return HTMLCollections whose filter matches **only HTML elements**
// of the given local name (not foreign-namespace lookalikes). The
// `.tag` mode in NodeLive intentionally also matches non-HTML
// elements (because that's what `getElementsByTagName` requires for
// HTML documents), so we cannot reuse it here. Using `.tag_name_ns`
// with a fixed HTML namespace gives us the correct scoping.
const TagNameNsFilter = @import("collections/node_live.zig").TagNameNsFilter;
fn htmlNamespaceFilter(local: []const u8) TagNameNsFilter {
    return .{
        .namespace = .html,
        .local_name = String.wrap(local),
    };
}

pub fn getImages(self: *HTMLDocument, frame: *Frame) !collections.NodeLive(.tag_name_ns) {
    return collections.NodeLive(.tag_name_ns).init(self.asNode(), htmlNamespaceFilter("img"), frame);
}

pub fn getScripts(self: *HTMLDocument, frame: *Frame) !collections.NodeLive(.tag_name_ns) {
    return collections.NodeLive(.tag_name_ns).init(self.asNode(), htmlNamespaceFilter("script"), frame);
}

pub fn getLinks(self: *HTMLDocument, frame: *Frame) !collections.NodeLive(.links) {
    return collections.NodeLive(.links).init(self.asNode(), {}, frame);
}

pub fn getAnchors(self: *HTMLDocument, frame: *Frame) !collections.NodeLive(.anchors) {
    return collections.NodeLive(.anchors).init(self.asNode(), {}, frame);
}

pub fn getForms(self: *HTMLDocument, frame: *Frame) !collections.NodeLive(.tag_name_ns) {
    return collections.NodeLive(.tag_name_ns).init(self.asNode(), htmlNamespaceFilter("form"), frame);
}

pub fn getEmbeds(self: *HTMLDocument, frame: *Frame) !collections.NodeLive(.tag_name_ns) {
    return collections.NodeLive(.tag_name_ns).init(self.asNode(), htmlNamespaceFilter("embed"), frame);
}

// ---------------------------------------------------------------------------
// Named property getter (HTML spec §3.1.5: "named getter on Document").
// ---------------------------------------------------------------------------
//
// Returns the first element in tree order whose name OR id contributes
// to the supported property names of the document, per the spec rules:
//
//   * exposed by `name` content attribute when the element is an
//     embed/form/iframe/img/object in the HTML namespace and its name
//     attribute is non-empty;
//   * exposed by `id` content attribute when the element is an
//     object in the HTML namespace with non-empty id, or an img with
//     both a non-empty id AND a non-empty name attribute.
//
// Special case: when the matching element is an iframe with a live
// browsing context, return its contentWindow rather than the element
// itself, as required by the spec.
//
// We currently return only the first matching element; producing an
// HTMLCollection when multiple elements share the same name is a
// subsequent refinement (a small minority of WPT cases).
fn isExposedByName(el: *Element) bool {
    if (el._namespace != .html) return false;
    return switch (el.getTag()) {
        .embed, .form, .iframe, .img, .object => true,
        else => false,
    };
}

fn isExposedById(el: *Element) bool {
    if (el._namespace != .html) return false;
    return switch (el.getTag()) {
        .object => true,
        .img => blk: {
            // imgs only contribute their id when they ALSO have a
            // non-empty name attribute.
            const name_attr = el.getAttributeSafe(comptime .wrap("name")) orelse break :blk false;
            break :blk name_attr.len > 0;
        },
        else => false,
    };
}

fn getNamedItem(self: *HTMLDocument, name: []const u8, frame: *Frame) !js.Value {
    // We must signal "no such property" by returning error.NotHandled
    // rather than null/undefined. Returning null with the
    // `null_as_undefined` opt would cause V8 to treat the named lookup
    // as intercepted-with-undefined, which makes `name in document`
    // wrongly evaluate to true and breaks several WPT cases.
    if (name.len == 0) return error.NotHandled;
    const local = frame.js.local orelse return error.NotHandled;

    var walker = TreeWalker.Full.Elements.init(self.asNode(), .{});
    while (walker.next()) |el| {
        const matches_name = isExposedByName(el) and blk: {
            const attr = el.getAttributeSafe(comptime .wrap("name")) orelse break :blk false;
            break :blk attr.len > 0 and std.mem.eql(u8, attr, name);
        };
        const matches_id = isExposedById(el) and blk: {
            const attr = el.getAttributeSafe(comptime .wrap("id")) orelse break :blk false;
            break :blk attr.len > 0 and std.mem.eql(u8, attr, name);
        };
        if (!matches_name and !matches_id) continue;

        // iframe: return its contentWindow when one is available.
        if (el._namespace == .html and el.getTag() == .iframe) {
            if (el.is(IFrame)) |iframe| {
                if (iframe.getContentWindow(frame)) |cw| {
                    return try local.zigValueToJs(cw, .{});
                }
            }
        }
        return try local.zigValueToJs(el, .{});
    }
    return error.NotHandled;
}

pub fn getApplets(_: *const HTMLDocument) collections.HTMLCollection {
    return .{ ._data = .empty };
}

pub fn getLocation(self: *const HTMLDocument) ?*@import("Location.zig") {
    const frame = self._proto._frame orelse return null;
    return frame.window._location;
}

pub fn setLocation(self: *HTMLDocument, url: [:0]const u8, frame: *Frame) !void {
    return frame.scheduleNavigation(url, .{ .reason = .script, .kind = .{ .push = null } }, .{ .script = self._proto._frame });
}

pub fn getDir(self: *HTMLDocument) []const u8 {
    const el = self._proto.getDocumentElement() orelse return "";
    const html = el.is(Element.Html) orelse return "";
    return html.getDir();
}

pub fn setDir(self: *HTMLDocument, value: []const u8, frame: *Frame) !void {
    const el = self._proto.getDocumentElement() orelse return;
    const html = el.is(Element.Html) orelse return;
    try html.setDir(value, frame);
}

pub fn getLang(self: *HTMLDocument) []const u8 {
    const el = self._proto.getDocumentElement() orelse return "";
    const html = el.is(Element.Html) orelse return "";
    return html.getLang();
}

pub fn setLang(self: *HTMLDocument, value: []const u8, frame: *Frame) !void {
    const el = self._proto.getDocumentElement() orelse return;
    const html = el.is(Element.Html) orelse return;
    try html.setLang(value, frame);
}

pub fn getAll(self: *HTMLDocument, frame: *Frame) !*collections.HTMLAllCollection {
    return frame._factory.create(collections.HTMLAllCollection.init(self.asNode(), frame));
}

pub fn getCookie(self: *HTMLDocument) ![]const u8 {
    const doc = self.asDocument();
    const doc_frame = doc.activeBrowsingContext() orelse return "";
    const cookie_url = doc_frame.cookieURL();
    var buf = std.Io.Writer.Allocating.init(doc_frame.call_arena);
    try doc_frame._session.cookie_jar.forRequest(cookie_url, &buf.writer, .{
        .is_http = false,
        .is_navigation = true,
        .origin_url = cookie_url,
        .top_level_url = doc_frame.topLevelUrl(),
    });
    return buf.written();
}

pub fn setCookie(self: *HTMLDocument, cookie_str: []const u8) ![]const u8 {
    const doc = self.asDocument();
    const doc_frame = doc.activeBrowsingContext() orelse return "";
    const cookie_url = doc_frame.cookieURL();
    const Cookie = @import("storage/Cookie.zig");
    if (Cookie.isThirdPartyContext(doc_frame.topLevelUrl(), cookie_url)) {
        return "";
    }
    // we use the cookie jar's allocator to parse the cookie because it
    // outlives the frame's arena.
    const c = Cookie.parse(doc_frame._session.cookie_jar.allocator, cookie_url, cookie_str) catch {
        // Invalid cookies should be silently ignored, not throw errors
        return "";
    };
    errdefer c.deinit();
    if (c.http_only) {
        c.deinit();
        return ""; // HttpOnly cookies cannot be set from JS
    }
    try doc_frame._session.cookie_jar.addWithTopLevel(c, @intCast(datetime.timestamp(.clock)), false, doc_frame.topLevelUrl());
    return cookie_str;
}

pub fn getDocType(self: *HTMLDocument, frame: *Frame) !*DocumentType {
    if (self._document_type) |dt| {
        return dt;
    }

    var tw = @import("../dom/TreeWalker.zig").Full.init(self.asNode(), .{});
    while (tw.next()) |node| {
        if (node._type == .document_type) {
            self._document_type = node.as(DocumentType);
            return self._document_type.?;
        }
    }

    self._document_type = try frame._factory.node(DocumentType{
        ._proto = undefined,
        ._name = "html",
        ._public_id = "",
        ._system_id = "",
    });
    return self._document_type.?;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(HTMLDocument);

    pub const Meta = struct {
        pub const name = "HTMLDocument";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(_constructor, .{});
    fn _constructor(frame: *Frame) !*HTMLDocument {
        return frame._factory.document(HTMLDocument{
            ._proto = undefined,
        });
    }

    pub const dir = bridge.accessor(HTMLDocument.getDir, HTMLDocument.setDir, .{});
    pub const head = bridge.accessor(HTMLDocument.getHead, null, .{});
    pub const body = bridge.accessor(HTMLDocument.getBody, HTMLDocument.setBody, .{ .dom_exception = true });
    pub const lang = bridge.accessor(HTMLDocument.getLang, HTMLDocument.setLang, .{});
    // `title` is defined on Document so SVG/XML documents see it too.
    pub const images = bridge.accessor(HTMLDocument.getImages, null, .{});
    pub const scripts = bridge.accessor(HTMLDocument.getScripts, null, .{});
    pub const links = bridge.accessor(HTMLDocument.getLinks, null, .{});
    pub const anchors = bridge.accessor(HTMLDocument.getAnchors, null, .{});
    pub const forms = bridge.accessor(HTMLDocument.getForms, null, .{});
    pub const embeds = bridge.accessor(HTMLDocument.getEmbeds, null, .{});
    pub const applets = bridge.accessor(HTMLDocument.getApplets, null, .{});
    pub const plugins = bridge.accessor(HTMLDocument.getEmbeds, null, .{});
    // currentScript is on Document (HTML IDL) — see Document.JsApi.currentScript.
    pub const location = bridge.accessor(HTMLDocument.getLocation, HTMLDocument.setLocation, .{});
    pub const all = bridge.accessor(HTMLDocument.getAll, null, .{});
    // `cookie` is defined on Document (HTML spec).
    pub const doctype = bridge.accessor(HTMLDocument.getDocType, null, .{});

    // `document[name]` named property getter (HTML spec).
    pub const @"[str]" = bridge.namedIndexed(getNamedItem, null, null, null, .{ .null_as_undefined = true });
};
