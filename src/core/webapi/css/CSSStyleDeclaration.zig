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

const CssParser = @import("../../browser/css/Parser.zig");

const js = @import("../../js/js.zig");
const Frame = @import("../../browser/Frame.zig");
const Element = @import("../../dom/Element.zig");
const CSSRule = @import("CSSRule.zig");
const ComputedStyleProps = @import("computed_style_properties.zig");
const ClientRectsIntelligent = @import("../../../runtime/profile/ClientRectsIntelligent.zig");

const known_property_map: std.StaticStringMap(void) = blk: {
    var entries: [ComputedStyleProps.names.len]struct { []const u8, void } = undefined;
    for (ComputedStyleProps.names, 0..) |name, i| {
        entries[i] = .{ name, {} };
    }
    break :blk std.StaticStringMap(void).initComptime(entries[0..]);
};

const method_names = std.StaticStringMap(void).initComptime(.{
    .{ "getPropertyValue", {} },
    .{ "setProperty", {} },
    .{ "removeProperty", {} },
    .{ "getPropertyPriority", {} },
    .{ "item", {} },
    .{ "cssText", {} },
    .{ "length", {} },
    .{ "parentRule", {} },
});

const log = @import("../../../support/log.zig");
const String = @import("../../../support/string.zig").String;
const Allocator = std.mem.Allocator;
const CSSStyleDeclaration = @This();

_element: ?*Element = null,
_properties: std.DoublyLinkedList = .{},
_is_computed: bool = false,
_computed_indexed_keys: []const []const u8 = &.{},
_computed_named_keys: []const []const u8 = &.{},
_computed_in_keys: []const []const u8 = &.{},

pub fn init(element: ?*Element, is_computed: bool, frame: *Frame) !*CSSStyleDeclaration {
    const profile = frame.loadedProfile();
    const self = try frame._factory.create(CSSStyleDeclaration{
        ._element = element,
        ._is_computed = is_computed,
        ._computed_indexed_keys = if (is_computed) profile.css_computed_indexed_keys else &.{},
        ._computed_named_keys = if (is_computed) profile.css_computed_named_keys else &.{},
        ._computed_in_keys = if (is_computed) profile.css_computed_in_keys else &.{},
    });

    // Parse the element's existing style attribute into _properties so that
    // subsequent JS reads and writes see all CSS properties, not just newly
    // added ones.  Computed styles have no inline attribute to parse.
    if (!is_computed) {
        if (element) |el| {
            if (el.getAttributeSafe(comptime .wrap("style"))) |attr_value| {
                var it = CssParser.parseDeclarationsList(attr_value);
                while (it.next()) |declaration| {
                    try self.setPropertyImpl(declaration.name, declaration.value, declaration.important, frame);
                }
            }
        }
    }

    return self;
}

pub fn isComputed(self: *const CSSStyleDeclaration) bool {
    return self._is_computed;
}

pub fn length(self: *const CSSStyleDeclaration) u32 {
    if (self._is_computed) {
        if (self._computed_indexed_keys.len > 0) return @intCast(self._computed_indexed_keys.len);
        return @intCast(ComputedStyleProps.names.len);
    }
    return @intCast(self._properties.len());
}

pub fn item(self: *const CSSStyleDeclaration, index: u32) []const u8 {
    if (self._is_computed) {
        if (self._computed_indexed_keys.len > 0) {
            if (index >= self._computed_indexed_keys.len) return "";
            return self._computed_indexed_keys[index];
        }
        if (index >= ComputedStyleProps.names.len) return "";
        return ComputedStyleProps.names[index];
    }
    var i: u32 = 0;
    var node = self._properties.first;
    while (node) |n| {
        if (i == index) {
            const prop = Property.fromNodeLink(n);
            return prop._name.str();
        }
        i += 1;
        node = n.next;
    }
    return "";
}

fn styleFrameFor(self: *const CSSStyleDeclaration, caller: *Frame) *Frame {
    const element = self._element orelse return caller;
    return element.asNode().ownerFrame(caller);
}

pub fn getPropertyValue(self: *const CSSStyleDeclaration, property_name: []const u8, frame: *Frame) []const u8 {
    const normalized = normalizePropertyName(property_name, &frame.buf);
    const wrapped = String.wrap(normalized);
    const style_frame = styleFrameFor(self, frame);

    // Computed styles must reflect stylesheet rules, not just the element's
    // inline `style=` attribute. Limited to display/visibility — what aria
    // tree builders (Playwright ariaSnapshot) consult on every element.
    if (self._is_computed) {
        if (self._element) |element| {
            if (wrapped.eql(comptime .wrap("display"))) {
                if (style_frame._style_manager.hasDisplayNone(element)) return "none";
            } else if (wrapped.eql(comptime .wrap("visibility"))) {
                if (style_frame._style_manager.hasVisibilityHiddenInherited(element)) return "hidden";
            }
        }
    }

    const prop = self.findProperty(wrapped) orelse {
        if (self._is_computed) {
            return getComputedPropertyValue(self, wrapped, style_frame);
        }
        return "";
    };
    return resolveColorPropertyValue(wrapped, prop._value.str());
}

fn resolveColorPropertyValue(name: String, value: []const u8) []const u8 {
    if (!isColorProperty(name)) return value;
    if (resolveSystemColor(value)) |resolved| return resolved;
    return value;
}

fn isColorProperty(name: String) bool {
    const raw = name.str();
    return std.mem.eql(u8, raw, "color") or
        std.mem.eql(u8, raw, "background-color") or
        std.mem.eql(u8, raw, "border-color") or
        std.mem.eql(u8, raw, "outline-color");
}

fn getInlineStyleValue(element: *Element, property_name: []const u8) ?[]const u8 {
    const attr_value = element.getAttributeSafe(comptime .wrap("style")) orelse return null;
    var it = CssParser.parseDeclarationsList(attr_value);
    while (it.next()) |declaration| {
        if (std.ascii.eqlIgnoreCase(declaration.name, property_name)) {
            return declaration.value;
        }
    }
    return null;
}

fn getComputedPropertyValue(self: *const CSSStyleDeclaration, name: String, style_frame: *Frame) []const u8 {
    const raw = name.str();
    if (raw.len > 2 and raw[0] == '-' and raw[1] == '-') {
        if (self._element) |element| {
            if (style_frame._style_manager.getCustomProperty(element, raw)) |custom| {
                return custom;
            }
        }
        return "";
    }
    if (self._element) |element| {
        if (name.eql(comptime .wrap("display"))) {
            if (style_frame._style_manager.hasDisplayNone(element)) return "none";
        } else if (name.eql(comptime .wrap("visibility"))) {
            if (style_frame._style_manager.hasVisibilityHiddenInherited(element)) return "hidden";
        }
        if (getInlineStyleValue(element, raw)) |inline_value| {
            return resolveColorPropertyValue(name, inline_value);
        }
        if (name.eql(comptime .wrap("font-family"))) {
            if (getInlineSystemFontFamily(element)) |family| return family;
        }
        if (name.eql(comptime .wrap("block-size")) or name.eql(comptime .wrap("inline-size"))) {
            if (ClientRectsIntelligent.lookupEmojiLogicalSize(element, style_frame)) |dims| {
                const logical = if (name.eql(comptime .wrap("block-size"))) dims.block_size else dims.inline_size;
                // Chrome serializes logical emoji sizes at ~6 decimal places.
                const value = @round(logical * 1_000_000.0) / 1_000_000.0;
                const formatted = std.fmt.bufPrint(&style_frame.buf, "{d}px", .{value}) catch return "auto";
                return formatted;
            }
        }
    }
    return resolveColorPropertyValue(name, getDefaultPropertyValue(self, name));
}

fn getInlineSystemFontFamily(element: *Element) ?[]const u8 {
    const attr_value = element.getAttributeSafe(comptime .wrap("style")) orelse return null;
    var it = CssParser.parseDeclarationsList(attr_value);
    while (it.next()) |declaration| {
        if (!std.ascii.eqlIgnoreCase(declaration.name, "font")) continue;
        var value = std.mem.trim(u8, declaration.value, " ");
        if (std.mem.endsWith(u8, value, "!important")) {
            value = std.mem.trimEnd(u8, value[0 .. value.len - "!important".len], " ");
        }
        if (resolveSystemFontKeyword(value)) |family| return family;
    }
    return null;
}

fn resolveSystemFontKeyword(value: []const u8) ?[]const u8 {
    const keywords = [_][]const u8{
        "caption", "icon", "menu", "message-box", "small-caption", "status-bar",
    };
    for (keywords) |kw| {
        if (std.mem.eql(u8, value, kw)) return "Arial";
    }
    return null;
}

pub fn getPropertyPriority(self: *const CSSStyleDeclaration, property_name: []const u8, frame: *Frame) []const u8 {
    const normalized = normalizePropertyName(property_name, &frame.buf);
    const prop = self.findProperty(.wrap(normalized)) orelse return "";
    return if (prop._important) "important" else "";
}

pub fn setProperty(self: *CSSStyleDeclaration, property_name: []const u8, value: []const u8, priority_: ?[]const u8, frame: *Frame) !void {
    // Validate priority
    const priority = priority_ orelse "";
    const important = if (priority.len > 0) blk: {
        if (!std.ascii.eqlIgnoreCase(priority, "important")) {
            return;
        }
        break :blk true;
    } else false;

    try self.setPropertyImpl(property_name, value, important, frame);

    try self.syncStyleAttribute(frame);
    // After syncStyleAttribute (which may call domChanged and re-arm the layout
    // version), drop size entries so font-family / font-size mutations remeasure.
    frame.invalidateElementLayoutCache();
}

fn setPropertyImpl(self: *CSSStyleDeclaration, property_name: []const u8, value: []const u8, important: bool, frame: *Frame) !void {
    if (value.len == 0) {
        _ = try self.removePropertyImpl(property_name, frame);
        return;
    }

    const normalized = normalizePropertyName(property_name, &frame.buf);

    // Normalize the value for canonical serialization
    const normalized_value = try normalizePropertyValue(frame.call_arena, normalized, value);

    // Find existing property
    if (self.findProperty(.wrap(normalized))) |existing| {
        existing._value = try String.init(frame.arena, normalized_value, .{});
        existing._important = important;
        return;
    }

    // Create new property
    const prop = try frame._factory.create(Property{
        ._node = .{},
        ._name = try String.init(frame.arena, normalized, .{}),
        ._value = try String.init(frame.arena, normalized_value, .{}),
        ._important = important,
    });
    self._properties.append(&prop._node);
}

pub fn removeProperty(self: *CSSStyleDeclaration, property_name: []const u8, frame: *Frame) ![]const u8 {
    const result = try self.removePropertyImpl(property_name, frame);
    try self.syncStyleAttribute(frame);
    frame.invalidateElementLayoutCache();
    return result;
}

fn removePropertyImpl(self: *CSSStyleDeclaration, property_name: []const u8, frame: *Frame) ![]const u8 {
    const normalized = normalizePropertyName(property_name, &frame.buf);
    const prop = self.findProperty(.wrap(normalized)) orelse return "";

    // the value might not be on the heap (it could be inlined in the small string
    // optimization), so we need to dupe it.
    const old_value = try frame.call_arena.dupe(u8, prop._value.str());
    self._properties.remove(&prop._node);
    frame._factory.destroy(prop);
    return old_value;
}

// Serialize current properties back to the element's style attribute so that
// DOM serialization (outerHTML, getAttribute) reflects JS-modified styles.
fn syncStyleAttribute(self: *CSSStyleDeclaration, frame: *Frame) !void {
    const element = self._element orelse return;
    const css_text = try self.getCssText(frame);
    try element.setAttributeSafe(comptime .wrap("style"), .wrap(css_text), frame);
}

pub fn getParentRule(_: *const CSSStyleDeclaration, _: *Frame) ?*CSSRule {
    return null;
}

pub fn getIndexName(self: *const CSSStyleDeclaration, index: usize) ?[]const u8 {
    if (self._is_computed) {
        if (self._computed_indexed_keys.len > 0) {
            if (index >= self._computed_indexed_keys.len) return null;
            return self._computed_indexed_keys[index];
        }
        if (index >= ComputedStyleProps.names.len) return null;
        return ComputedStyleProps.names[index];
    }
    const name = self.item(@intCast(index));
    if (name.len == 0) return null;
    return name;
}

pub fn getIndexes(self: *const CSSStyleDeclaration, frame: *Frame) !js.Array {
    const len = self.length();
    var arr = frame.js.local.?.newArray(len);
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        var key_buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{d}", .{i});
        _ = try arr.set(i, key, .{});
    }
    return arr;
}

fn isComputedNamedKey(self: *const CSSStyleDeclaration, name: []const u8, dash_case: []const u8) bool {
    if (!self._is_computed) return true;
    const keys = if (self._computed_in_keys.len > 0) self._computed_in_keys else self._computed_named_keys;
    if (keys.len == 0) return true;
    for (keys) |key| {
        if (std.mem.eql(u8, key, name) or std.mem.eql(u8, key, dash_case)) return true;
    }
    return false;
}

pub fn getNamedKeys(self: *const CSSStyleDeclaration, frame: *Frame) !js.Array {
    if (self._is_computed) {
        const keys = if (self._computed_named_keys.len > 0)
            self._computed_named_keys
        else
            frame.loadedProfile().css_computed_named_keys;
        var arr = frame.js.local.?.newArray(@intCast(keys.len));
        for (keys, 0..) |key, i| {
            _ = try arr.set(@intCast(i), key, .{});
        }
        return arr;
    }
    const len = self.length();
    var arr = frame.js.local.?.newArray(len);
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const name = self.item(@intCast(i));
        _ = try arr.set(i, name, .{});
    }
    return arr;
}

pub fn setNamed(self: *CSSStyleDeclaration, name: []const u8, value: []const u8, frame: *Frame) !void {
    if (method_names.has(name)) return error.NotHandled;
    const dash_case = camelCaseToDashCase(name, &frame.buf);
    try self.setProperty(dash_case, value, null, frame);
}

pub fn getNamed(self: *const CSSStyleDeclaration, name: []const u8, frame: *Frame) ![]const u8 {
    if (method_names.has(name)) return error.NotHandled;
    const dash_case = camelCaseToDashCase(name, &frame.buf);
    if (!self.isComputedNamedKey(name, dash_case)) return error.NotHandled;
    const is_camelcase_access = std.mem.indexOfScalar(u8, name, '-') == null;
    if (is_camelcase_access and std.mem.startsWith(u8, dash_case, "-")) {
        const is_webkit = std.mem.startsWith(u8, dash_case, "-webkit-");
        const is_moz = std.mem.startsWith(u8, dash_case, "-moz-");
        const is_ms = std.mem.startsWith(u8, dash_case, "-ms-");
        const is_o = std.mem.startsWith(u8, dash_case, "-o-");
        if ((is_moz or is_ms or is_o) and !is_webkit) return error.NotHandled;
    }
    const value = self.getPropertyValue(dash_case, frame);
    if (value.len == 0) {
        if (self._is_computed and self._computed_in_keys.len > 0) return "";
        if (std.mem.startsWith(u8, dash_case, "-")) return error.NotHandled;
        if (!isKnownCSSProperty(dash_case)) return error.NotHandled;
        return "";
    }
    return value;
}

fn isKnownCSSProperty(dash_case: []const u8) bool {
    return known_property_map.has(dash_case);
}

fn camelCaseToDashCase(name: []const u8, buf: []u8) []const u8 {
    if (name.len == 0) return name;
    const lower_name = std.ascii.lowerString(buf, name);
    if (std.mem.eql(u8, lower_name, "cssfloat")) return "float";
    if (std.mem.indexOfScalar(u8, name, '-')) |_| return lower_name;
    if (!std.ascii.isLower(name[0])) return lower_name;
    const has_vendor_prefix = blk: {
        if (name.len > 6 and std.mem.startsWith(u8, name, "webkit") and std.ascii.isUpper(name[6])) break :blk true;
        if (name.len > 3 and std.mem.startsWith(u8, name, "moz") and std.ascii.isUpper(name[3])) break :blk true;
        if (name.len > 2 and std.mem.startsWith(u8, name, "ms") and std.ascii.isUpper(name[2])) break :blk true;
        if (name.len > 1 and std.mem.startsWith(u8, name, "o") and std.ascii.isUpper(name[1])) break :blk true;
        break :blk false;
    };
    var write_pos: usize = 0;
    if (has_vendor_prefix) {
        buf[write_pos] = '-';
        write_pos += 1;
    }
    for (name, 0..) |c, i| {
        if (write_pos >= buf.len) return lower_name;
        if (std.ascii.isUpper(c)) {
            const skip_dash = has_vendor_prefix and i < 10 and write_pos == 1;
            if (i > 0 and !skip_dash) {
                if (write_pos >= buf.len) break;
                buf[write_pos] = '-';
                write_pos += 1;
            }
            if (write_pos >= buf.len) break;
            buf[write_pos] = std.ascii.toLower(c);
            write_pos += 1;
        } else {
            buf[write_pos] = c;
            write_pos += 1;
        }
    }
    return buf[0..write_pos];
}

pub fn getFloat(self: *const CSSStyleDeclaration, frame: *Frame) []const u8 {
    return self.getPropertyValue("float", frame);
}

pub fn setFloat(self: *CSSStyleDeclaration, value_: ?[]const u8, frame: *Frame) !void {
    try self.setPropertyImpl("float", value_ orelse "", false, frame);
    try self.syncStyleAttribute(frame);
}

pub fn getCssText(self: *const CSSStyleDeclaration, frame: *Frame) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(frame.call_arena);
    try self.format(&buf.writer);
    return buf.written();
}

pub fn setCssText(self: *CSSStyleDeclaration, text: []const u8, frame: *Frame) !void {
    // Clear existing properties
    var node = self._properties.first;
    while (node) |n| {
        const next = n.next;
        const prop = Property.fromNodeLink(n);
        self._properties.remove(n);
        frame._factory.destroy(prop);
        node = next;
    }

    // Parse and set new properties
    var it = CssParser.parseDeclarationsList(text);
    while (it.next()) |declaration| {
        try self.setPropertyImpl(declaration.name, declaration.value, declaration.important, frame);
    }
    try self.syncStyleAttribute(frame);
    frame.invalidateElementLayoutCache();
}

pub fn format(self: *const CSSStyleDeclaration, writer: *std.Io.Writer) !void {
    const node = self._properties.first orelse return;
    try Property.fromNodeLink(node).format(writer);

    var next = node.next;
    while (next) |n| {
        try writer.writeByte(' ');
        try Property.fromNodeLink(n).format(writer);
        next = n.next;
    }
}

pub fn findProperty(self: *const CSSStyleDeclaration, name: String) ?*Property {
    var node = self._properties.first;
    while (node) |n| {
        const prop = Property.fromNodeLink(n);
        if (prop._name.eql(name)) {
            return prop;
        }
        node = n.next;
    }
    return null;
}

fn normalizePropertyName(name: []const u8, buf: []u8) []const u8 {
    if (name.len > buf.len) {
        log.info(.dom, "css.long.name", .{ .name = name });
        return name;
    }
    return std.ascii.lowerString(buf, name);
}

// Normalize CSS property values for canonical serialization
fn normalizePropertyValue(arena: Allocator, property_name: []const u8, value: []const u8) ![]const u8 {
    // Per CSSOM spec, unitless zero in length properties should serialize as "0px"
    if (std.mem.eql(u8, value, "0") and isLengthProperty(property_name)) {
        return "0px";
    }

    // "first baseline" serializes canonically as "baseline" (first is the default)
    if (std.ascii.startsWithIgnoreCase(value, "first baseline")) {
        if (value.len == 14) {
            // Exact match "first baseline"
            return "baseline";
        }
        if (value.len > 14 and value[14] == ' ') {
            // "first baseline X" -> "baseline X"
            return try std.mem.concat(arena, u8, &.{ "baseline", value[14..] });
        }
    }

    // For 2-value shorthand properties, collapse "X X" to "X"
    if (isTwoValueShorthand(property_name)) {
        if (collapseDuplicateValue(value)) |single| {
            return single;
        }
    }

    // Canonicalize anchor-size() function: anchor name (dashed ident) comes before size keyword
    if (std.mem.indexOf(u8, value, "anchor-size(")) |idx| {
        return canonicalizeAnchorSize(arena, value, idx);
    }

    // Canonicalize anchor() function: anchor name (dashed ident) comes before position keyword
    // Note: indexOf finds first occurrence, so we check it's not part of "anchor-size("
    if (std.mem.indexOf(u8, value, "anchor(")) |idx| {
        if (idx == 0 or value[idx - 1] != '-') {
            return canonicalizeAnchor(arena, value, idx);
        }
    }

    return value;
}

// Canonicalize anchor-size() so that the dashed ident (anchor name) comes before the size keyword.
// e.g. "anchor-size(width --foo)" -> "anchor-size(--foo width)"
fn canonicalizeAnchorSize(arena: Allocator, value: []const u8, start_index: usize) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(arena);

    // Copy everything before the first anchor-size(
    try buf.writer.writeAll(value[0..start_index]);

    var i: usize = start_index;

    while (i < value.len) {
        // Look for "anchor-size("
        if (std.mem.startsWith(u8, value[i..], "anchor-size(")) {
            try buf.writer.writeAll("anchor-size(");
            i += "anchor-size(".len;

            // Parse and canonicalize the arguments
            i = try canonicalizeAnchorFnArgs(value, i, &buf.writer, .anchor_size);
        } else {
            try buf.writer.writeByte(value[i]);
            i += 1;
        }
    }

    return buf.written();
}

const AnchorFnKind = enum { anchor, anchor_size };

// Parse anchor/anchor-size arguments and write them in canonical order
fn canonicalizeAnchorFnArgs(value: []const u8, start: usize, writer: *std.Io.Writer, kind: AnchorFnKind) !usize {
    var i = start;
    var depth: usize = 1;

    // Skip leading whitespace
    while (i < value.len and value[i] == ' ') : (i += 1) {}

    var token_count: usize = 0;
    var comma_pos: ?usize = null;

    var first_token_end: usize = 0;
    var first_token_start: ?usize = null;

    var second_token_end: usize = 0;
    var second_token_start: ?usize = null;

    const args_start = i;
    var in_token = false;

    // First pass: find the structure of arguments before comma/closing paren at depth 1
    while (i < value.len and depth > 0) {
        const c = value[i];

        if (c == '(') {
            depth += 1;
            in_token = true;
            i += 1;
        } else if (c == ')') {
            depth -= 1;
            if (depth == 0) {
                if (in_token) {
                    if (token_count == 0) {
                        first_token_end = i;
                    } else if (token_count == 1) {
                        second_token_end = i;
                    }
                }
                break;
            }
            i += 1;
        } else if (c == ',' and depth == 1) {
            if (in_token) {
                if (token_count == 0) {
                    first_token_end = i;
                } else if (token_count == 1) {
                    second_token_end = i;
                }
            }
            comma_pos = i;
            break;
        } else if (c == ' ') {
            if (in_token and depth == 1) {
                if (token_count == 0) {
                    first_token_end = i;
                    token_count = 1;
                } else if (token_count == 1 and second_token_start != null) {
                    second_token_end = i;
                    token_count = 2;
                }
                in_token = false;
            }
            i += 1;
        } else {
            if (!in_token and depth == 1) {
                if (token_count == 0) {
                    first_token_start = i;
                } else if (token_count == 1) {
                    second_token_start = i;
                }
                in_token = true;
            }
            i += 1;
        }
    }

    // Handle end of tokens
    if (in_token and token_count == 1 and second_token_start != null) {
        second_token_end = i;
        token_count = 2;
    } else if (in_token and token_count == 0) {
        first_token_end = i;
        token_count = 1;
    }

    // Check if we have exactly two tokens that need reordering
    if (token_count == 2) {
        const first_start = first_token_start orelse args_start;
        const second_start = second_token_start orelse first_token_end;

        const first_token = value[first_start..first_token_end];
        const second_token = value[second_start..second_token_end];

        // If second token is a dashed ident, it should come first
        // For anchor-size, also check that first token is a size keyword
        const should_swap = std.mem.startsWith(u8, second_token, "--") and
            (kind == .anchor or isAnchorSizeKeyword(first_token));

        if (should_swap) {
            try writer.writeAll(second_token);
            try writer.writeByte(' ');
            try writer.writeAll(first_token);
        } else {
            try writer.writeAll(first_token);
            try writer.writeByte(' ');
            try writer.writeAll(second_token);
        }
    } else if (first_token_start) |fts| {
        // Single token, just copy it
        try writer.writeAll(value[fts..first_token_end]);
    }

    // Handle comma and fallback value (may contain nested functions)
    if (comma_pos) |cp| {
        try writer.writeAll(", ");
        i = cp + 1;
        // Skip whitespace after comma
        while (i < value.len and value[i] == ' ') : (i += 1) {}

        // Copy the fallback, recursively handling nested anchor/anchor-size
        while (i < value.len and depth > 0) {
            if (std.mem.startsWith(u8, value[i..], "anchor-size(")) {
                try writer.writeAll("anchor-size(");
                i += "anchor-size(".len;
                depth += 1;
                i = try canonicalizeAnchorFnArgs(value, i, writer, .anchor_size);
                depth -= 1;
            } else if (std.mem.startsWith(u8, value[i..], "anchor(")) {
                try writer.writeAll("anchor(");
                i += "anchor(".len;
                depth += 1;
                i = try canonicalizeAnchorFnArgs(value, i, writer, .anchor);
                depth -= 1;
            } else if (value[i] == '(') {
                depth += 1;
                try writer.writeByte(value[i]);
                i += 1;
            } else if (value[i] == ')') {
                depth -= 1;
                if (depth == 0) break;
                try writer.writeByte(value[i]);
                i += 1;
            } else {
                try writer.writeByte(value[i]);
                i += 1;
            }
        }
    }

    // Write closing paren
    try writer.writeByte(')');

    return i + 1; // Skip past the closing paren
}

fn isAnchorSizeKeyword(token: []const u8) bool {
    const keywords = std.StaticStringMap(void).initComptime(.{
        .{ "width", {} },
        .{ "height", {} },
        .{ "block", {} },
        .{ "inline", {} },
        .{ "self-block", {} },
        .{ "self-inline", {} },
    });
    return keywords.has(token);
}

// Canonicalize anchor() so that the dashed ident (anchor name) comes before the position keyword.
// e.g. "anchor(left --foo)" -> "anchor(--foo left)"
fn canonicalizeAnchor(arena: Allocator, value: []const u8, start_index: usize) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(arena);

    // Copy everything before the first anchor(
    try buf.writer.writeAll(value[0..start_index]);

    var i: usize = start_index;

    while (i < value.len) {
        // Look for "anchor(" but not "anchor-size("
        if (std.mem.startsWith(u8, value[i..], "anchor(") and (i == 0 or value[i - 1] != '-')) {
            try buf.writer.writeAll("anchor(");
            i += "anchor(".len;

            // Parse and canonicalize the arguments
            i = try canonicalizeAnchorFnArgs(value, i, &buf.writer, .anchor);
        } else {
            try buf.writer.writeByte(value[i]);
            i += 1;
        }
    }

    return buf.written();
}

// Check if a value is "X X" (duplicate) and return just "X"
fn collapseDuplicateValue(value: []const u8) ?[]const u8 {
    const space_idx = std.mem.indexOfScalar(u8, value, ' ') orelse return null;
    if (space_idx == 0 or space_idx >= value.len - 1) return null;

    const first = value[0..space_idx];
    const rest = std.mem.trimStart(u8, value[space_idx + 1 ..], " ");

    // Check if there's only one more value (no additional spaces)
    if (std.mem.indexOfScalar(u8, rest, ' ') != null) return null;

    if (std.mem.eql(u8, first, rest)) {
        return first;
    }
    return null;
}

fn isTwoValueShorthand(name: []const u8) bool {
    const shorthands = std.StaticStringMap(void).initComptime(.{
        .{ "place-content", {} },
        .{ "place-items", {} },
        .{ "place-self", {} },
        .{ "margin-block", {} },
        .{ "margin-inline", {} },
        .{ "padding-block", {} },
        .{ "padding-inline", {} },
        .{ "inset-block", {} },
        .{ "inset-inline", {} },
        .{ "border-block-style", {} },
        .{ "border-inline-style", {} },
        .{ "border-block-width", {} },
        .{ "border-inline-width", {} },
        .{ "border-block-color", {} },
        .{ "border-inline-color", {} },
        .{ "overflow", {} },
        .{ "overscroll-behavior", {} },
        .{ "gap", {} },
        .{ "grid-gap", {} },
        // Scroll
        .{ "scroll-padding-block", {} },
        .{ "scroll-padding-inline", {} },
        .{ "scroll-snap-align", {} },
        // Background/Mask
        .{ "background-size", {} },
        .{ "border-image-repeat", {} },
        .{ "mask-repeat", {} },
        .{ "mask-size", {} },
    });
    return shorthands.has(name);
}

fn isLengthProperty(name: []const u8) bool {
    // Properties that accept <length> or <length-percentage> values
    const length_properties = std.StaticStringMap(void).initComptime(.{
        // Sizing
        .{ "width", {} },
        .{ "height", {} },
        .{ "min-width", {} },
        .{ "min-height", {} },
        .{ "max-width", {} },
        .{ "max-height", {} },
        // Margins
        .{ "margin", {} },
        .{ "margin-top", {} },
        .{ "margin-right", {} },
        .{ "margin-bottom", {} },
        .{ "margin-left", {} },
        .{ "margin-block", {} },
        .{ "margin-block-start", {} },
        .{ "margin-block-end", {} },
        .{ "margin-inline", {} },
        .{ "margin-inline-start", {} },
        .{ "margin-inline-end", {} },
        // Padding
        .{ "padding", {} },
        .{ "padding-top", {} },
        .{ "padding-right", {} },
        .{ "padding-bottom", {} },
        .{ "padding-left", {} },
        .{ "padding-block", {} },
        .{ "padding-block-start", {} },
        .{ "padding-block-end", {} },
        .{ "padding-inline", {} },
        .{ "padding-inline-start", {} },
        .{ "padding-inline-end", {} },
        // Positioning
        .{ "top", {} },
        .{ "right", {} },
        .{ "bottom", {} },
        .{ "left", {} },
        .{ "inset", {} },
        .{ "inset-block", {} },
        .{ "inset-block-start", {} },
        .{ "inset-block-end", {} },
        .{ "inset-inline", {} },
        .{ "inset-inline-start", {} },
        .{ "inset-inline-end", {} },
        // Border
        .{ "border-width", {} },
        .{ "border-top-width", {} },
        .{ "border-right-width", {} },
        .{ "border-bottom-width", {} },
        .{ "border-left-width", {} },
        .{ "border-block-width", {} },
        .{ "border-block-start-width", {} },
        .{ "border-block-end-width", {} },
        .{ "border-inline-width", {} },
        .{ "border-inline-start-width", {} },
        .{ "border-inline-end-width", {} },
        .{ "border-radius", {} },
        .{ "border-top-left-radius", {} },
        .{ "border-top-right-radius", {} },
        .{ "border-bottom-left-radius", {} },
        .{ "border-bottom-right-radius", {} },
        // Text
        .{ "font-size", {} },
        .{ "letter-spacing", {} },
        .{ "word-spacing", {} },
        .{ "text-indent", {} },
        // Flexbox/Grid
        .{ "gap", {} },
        .{ "row-gap", {} },
        .{ "column-gap", {} },
        .{ "flex-basis", {} },
        // Legacy grid aliases
        .{ "grid-column-gap", {} },
        .{ "grid-row-gap", {} },
        // Outline
        .{ "outline", {} },
        .{ "outline-width", {} },
        .{ "outline-offset", {} },
        // Multi-column
        .{ "column-rule-width", {} },
        .{ "column-width", {} },
        // Scroll
        .{ "scroll-margin", {} },
        .{ "scroll-margin-top", {} },
        .{ "scroll-margin-right", {} },
        .{ "scroll-margin-bottom", {} },
        .{ "scroll-margin-left", {} },
        .{ "scroll-padding", {} },
        .{ "scroll-padding-top", {} },
        .{ "scroll-padding-right", {} },
        .{ "scroll-padding-bottom", {} },
        .{ "scroll-padding-left", {} },
        // Shapes
        .{ "shape-margin", {} },
        // Motion path
        .{ "offset-distance", {} },
        // Transforms
        .{ "translate", {} },
        // Animations
        .{ "animation-range-end", {} },
        .{ "animation-range-start", {} },
        // Other
        .{ "border-spacing", {} },
        .{ "text-shadow", {} },
        .{ "box-shadow", {} },
        .{ "baseline-shift", {} },
        .{ "vertical-align", {} },
        .{ "text-decoration-inset", {} },
        .{ "block-step-size", {} },
        // Grid lanes
        .{ "flow-tolerance", {} },
        .{ "column-rule-edge-inset", {} },
        .{ "column-rule-interior-inset", {} },
        .{ "row-rule-edge-inset", {} },
        .{ "row-rule-interior-inset", {} },
        .{ "rule-edge-inset", {} },
        .{ "rule-interior-inset", {} },
    });

    return length_properties.has(name);
}

fn getDefaultPropertyValue(self: *const CSSStyleDeclaration, name: String) []const u8 {
    const element = self._element orelse return "";

    if (name.eql(comptime .wrap("font-family"))) {
        return getDefaultFontFamily(element);
    }
    if (name.eql(comptime .wrap("font-size"))) {
        return getDefaultFontSize(element);
    }
    if (name.eql(comptime .wrap("font-style"))) {
        return "normal";
    }
    if (name.eql(comptime .wrap("font-weight"))) {
        return getDefaultFontWeight(element);
    }
    if (name.eql(comptime .wrap("font-variant"))) {
        return "normal";
    }
    if (std.mem.eql(u8, name.str(), "line-height")) {
        return "normal";
    }
    if (std.mem.eql(u8, name.str(), "letter-spacing")) {
        return "normal";
    }
    if (std.mem.eql(u8, name.str(), "word-spacing")) {
        return "0px";
    }
    if (name.eql(comptime .wrap("text-align"))) {
        return "start";
    }
    if (name.eql(comptime .wrap("text-indent"))) {
        return "0px";
    }
    if (name.eql(comptime .wrap("white-space"))) {
        return "normal";
    }
    if (name.eql(comptime .wrap("block-size"))) {
        return getDefaultBlockSize(element);
    }
    if (name.eql(comptime .wrap("inline-size"))) {
        return getDefaultInlineSize(element);
    }

    switch (name.len) {
        5 => {
            if (name.eql(comptime .wrap("color"))) {
                return getDefaultColor(element);
            }
        },
        7 => {
            if (name.eql(comptime .wrap("opacity"))) {
                return "1";
            }
            if (name.eql(comptime .wrap("display"))) {
                return getDefaultDisplay(element);
            }
        },
        10 => {
            if (name.eql(comptime .wrap("visibility"))) {
                return "visible";
            }
        },
        16 => {
            if (name.eqlSlice("background-color")) {
                // transparent
                return "rgba(0, 0, 0, 0)";
            }
        },
        else => {},
    }
    return "";
}

fn getDefaultDisplay(element: *const Element) []const u8 {
    switch (element._type) {
        .html => |html| {
            return switch (html._type) {
                .anchor, .br, .span, .label, .time, .font, .mod, .quote => "inline",
                .body, .div, .dl, .p, .heading, .form, .button, .canvas, .details, .dialog, .embed, .head, .html, .hr, .iframe, .img, .input, .li, .link, .meta, .ol, .option, .script, .select, .slot, .style, .template, .textarea, .title, .ul, .media, .area, .base, .datalist, .directory, .fieldset, .frameset, .legend, .map, .marquee, .meter, .object, .optgroup, .output, .param, .picture, .pre, .progress, .source, .table, .table_caption, .table_cell, .table_col, .table_row, .table_section, .track => "block",
                .generic, .custom, .unknown, .data => blk: {
                    const tag = element.getTagNameLower();
                    if (isInlineTag(tag)) break :blk "inline";
                    break :blk "block";
                },
            };
        },
        .svg => return "inline",
    }
}

fn getDefaultFontFamily(element: *const Element) []const u8 {
    _ = element;
    return "Helvetica Neue";
}

fn getDefaultFontSize(element: *const Element) []const u8 {
    _ = element;
    return "16px";
}

fn getDefaultFontWeight(element: *const Element) []const u8 {
    switch (element._type) {
        .html => |html| {
            return switch (html._type) {
                .heading, .button => "700",
                else => "400",
            };
        },
        .svg => return "400",
    }
}

fn getDefaultBlockSize(element: *const Element) []const u8 {
    const display = getDefaultDisplay(element);
    if (std.mem.eql(u8, display, "inline")) {
        return "auto";
    }
    return "auto";
}

fn getDefaultInlineSize(element: *const Element) []const u8 {
    const display = getDefaultDisplay(element);
    if (std.mem.eql(u8, display, "inline")) {
        return "auto";
    }
    return "auto";
}

fn isInlineTag(tag_name: []const u8) bool {
    const inline_tags = [_][]const u8{
        "abbr",  "b",    "bdi",    "bdo",  "cite", "code", "dfn",
        "em",    "i",    "kbd",    "mark", "q",    "s",    "samp",
        "small", "span", "strong", "sub",  "sup",  "time", "u",
        "var",   "wbr",
    };

    for (inline_tags) |inline_tag| {
        if (std.mem.eql(u8, tag_name, inline_tag)) {
            return true;
        }
    }
    return false;
}

fn getDefaultColor(element: *const Element) []const u8 {
    switch (element._type) {
        .html => |html| {
            return switch (html._type) {
                .anchor => "rgb(0, 0, 238)", // blue
                else => "rgb(0, 0, 0)",
            };
        },
        .svg => return "rgb(0, 0, 0)",
    }
}

/// Resolve CSS system colors to realistic **macOS light / Chrome-on-Mac** values.
/// https://www.w3.org/TR/css-color-4/#css-system-colors
///
/// Do not use Phantom/old-headless pure `rgb(255, 0, 0)` for ActiveText —
/// CreepJS treats that exact triple as `hasKnownBgColor` (like-headless).
/// Apple systemRed-ish active text is the platform-accurate desktop default.
pub fn resolveSystemColor(color_name: []const u8) ?[]const u8 {
    // System colors (case-insensitive)
    const SystemColorEntry = struct { name: []const u8, value: []const u8 };
    const system_colors = [_]SystemColorEntry{
        // CSS Color Level 4 system colors (macOS light theme)
        .{ .name = "Canvas", .value = "rgb(255, 255, 255)" }, // Page background (white)
        .{ .name = "CanvasText", .value = "rgb(0, 0, 0)" }, // Text on canvas (black)
        .{ .name = "LinkText", .value = "rgb(0, 102, 204)" }, // Safari/Chrome-Mac style link blue
        .{ .name = "VisitedText", .value = "rgb(85, 26, 139)" }, // Visited links (purple)
        // ActiveText: platform active control/link text — not Phantom pure red.
        .{ .name = "ActiveText", .value = "rgb(255, 59, 48)" }, // macOS systemRed-ish
        .{ .name = "ButtonFace", .value = "rgb(239, 239, 239)" },
        .{ .name = "ButtonText", .value = "rgb(0, 0, 0)" },
        .{ .name = "ButtonBorder", .value = "rgb(0, 0, 0)" },
        .{ .name = "Field", .value = "rgb(255, 255, 255)" }, // Input field background
        .{ .name = "FieldText", .value = "rgb(0, 0, 0)" }, // Input field text
        .{ .name = "Highlight", .value = "rgba(128, 188, 254, 0.6)" },
        .{ .name = "HighlightText", .value = "rgb(0, 0, 0)" }, // Selection text
        .{ .name = "SelectedItem", .value = "rgb(0, 99, 220)" }, // Selected item (macOS blue)
        .{ .name = "SelectedItemText", .value = "rgb(255, 255, 255)" }, // Selected item text
        .{ .name = "Mark", .value = "rgb(255, 255, 0)" }, // <mark> element background
        .{ .name = "MarkText", .value = "rgb(0, 0, 0)" }, // <mark> element text
        .{ .name = "GrayText", .value = "rgb(128, 128, 128)" }, // Disabled text

        // Legacy system colors (deprecated but still used)
        .{ .name = "ActiveBorder", .value = "rgb(0, 0, 0)" },
        .{ .name = "ActiveCaption", .value = "rgb(255, 255, 255)" },
        .{ .name = "AppWorkspace", .value = "rgb(255, 255, 255)" },
        .{ .name = "Background", .value = "rgb(255, 255, 255)" },
        .{ .name = "ButtonHighlight", .value = "rgb(239, 239, 239)" },
        .{ .name = "ButtonShadow", .value = "rgb(239, 239, 239)" },
        .{ .name = "CaptionText", .value = "rgb(0, 0, 0)" },
        .{ .name = "InactiveBorder", .value = "rgb(0, 0, 0)" },
        .{ .name = "InactiveCaption", .value = "rgb(255, 255, 255)" },
        .{ .name = "InactiveCaptionText", .value = "rgb(128, 128, 128)" },
        .{ .name = "InfoBackground", .value = "rgb(255, 255, 255)" },
        .{ .name = "InfoText", .value = "rgb(0, 0, 0)" },
        .{ .name = "Menu", .value = "rgb(255, 255, 255)" },
        .{ .name = "MenuText", .value = "rgb(0, 0, 0)" },
        .{ .name = "Scrollbar", .value = "rgb(255, 255, 255)" },
        .{ .name = "ThreeDDarkShadow", .value = "rgb(0, 0, 0)" },
        .{ .name = "ThreeDFace", .value = "rgb(239, 239, 239)" },
        .{ .name = "ThreeDHighlight", .value = "rgb(0, 0, 0)" },
        .{ .name = "ThreeDLightShadow", .value = "rgb(0, 0, 0)" },
        .{ .name = "ThreeDShadow", .value = "rgb(0, 0, 0)" },
        .{ .name = "Window", .value = "rgb(255, 255, 255)" },
        .{ .name = "WindowFrame", .value = "rgb(0, 0, 0)" },
        .{ .name = "WindowText", .value = "rgb(0, 0, 0)" },
    };

    for (system_colors) |entry| {
        if (std.ascii.eqlIgnoreCase(color_name, entry.name)) {
            return entry.value;
        }
    }

    return null;
}

pub const Property = struct {
    _name: String,
    _value: String,
    _important: bool = false,
    _node: std.DoublyLinkedList.Node,

    fn fromNodeLink(n: *std.DoublyLinkedList.Node) *Property {
        return @alignCast(@fieldParentPtr("_node", n));
    }

    pub fn format(self: *const Property, writer: *std.Io.Writer) !void {
        try self._name.format(writer);
        try writer.writeAll(": ");
        try self._value.format(writer);

        if (self._important) {
            try writer.writeAll(" !important");
        }
        try writer.writeByte(';');
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(CSSStyleDeclaration);

    pub const Meta = struct {
        pub const name = "CSSStyleDeclaration";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const cssText = bridge.accessor(CSSStyleDeclaration.getCssText, CSSStyleDeclaration.setCssText, .{});
    pub const length = bridge.accessor(CSSStyleDeclaration.length, null, .{});
    pub const parentRule = bridge.accessor(CSSStyleDeclaration.getParentRule, null, .{ .null_as_undefined = true });
    pub const cssFloat = bridge.accessor(CSSStyleDeclaration.getFloat, CSSStyleDeclaration.setFloat, .{});
    pub const getPropertyPriority = bridge.function(CSSStyleDeclaration.getPropertyPriority, .{});
    pub const getPropertyValue = bridge.function(CSSStyleDeclaration.getPropertyValue, .{});

    fn _item(self: *const CSSStyleDeclaration, index: i32) []const u8 {
        if (index < 0) {
            return "";
        }
        return self.item(@intCast(index));
    }

    pub const item = bridge.function(_item, .{});
    pub const removeProperty = bridge.function(CSSStyleDeclaration.removeProperty, .{});
    pub const setProperty = bridge.function(CSSStyleDeclaration.setProperty, .{});
    pub const @"[int]" = bridge.indexed(CSSStyleDeclaration.getIndexName, CSSStyleDeclaration.getIndexes, .{ .enumerable = true });
    pub const @"[]" = bridge.namedIndexed(CSSStyleDeclaration.getNamed, CSSStyleDeclaration.setNamed, null, CSSStyleDeclaration.getNamedKeys, .{ .enumerable = true });
};

const testing = @import("../../../testing/testing.zig");
test "normalizePropertyValue: unitless zero to 0px" {
    const cases = .{
        .{ "width", "0", "0px" },
        .{ "height", "0", "0px" },
        .{ "scroll-margin-top", "0", "0px" },
        .{ "scroll-padding-bottom", "0", "0px" },
        .{ "column-width", "0", "0px" },
        .{ "column-rule-width", "0", "0px" },
        .{ "outline", "0", "0px" },
        .{ "shape-margin", "0", "0px" },
        .{ "offset-distance", "0", "0px" },
        .{ "translate", "0", "0px" },
        .{ "grid-column-gap", "0", "0px" },
        .{ "grid-row-gap", "0", "0px" },
        // Non-length properties should NOT normalize
        .{ "opacity", "0", "0" },
        .{ "z-index", "0", "0" },
    };
    inline for (cases) |case| {
        const result = try normalizePropertyValue(testing.allocator, case[0], case[1]);
        try testing.expectEqual(case[2], result);
    }
}

test "normalizePropertyValue: first baseline to baseline" {
    const result = try normalizePropertyValue(testing.allocator, "align-items", "first baseline");
    try testing.expectEqual("baseline", result);

    const result2 = try normalizePropertyValue(testing.allocator, "align-self", "last baseline");
    try testing.expectEqual("last baseline", result2);
}

test "normalizePropertyValue: collapse duplicate two-value shorthands" {
    const cases = .{
        .{ "overflow", "hidden hidden", "hidden" },
        .{ "gap", "10px 10px", "10px" },
        .{ "scroll-snap-align", "start start", "start" },
        .{ "scroll-padding-block", "5px 5px", "5px" },
        .{ "background-size", "auto auto", "auto" },
        .{ "overscroll-behavior", "auto auto", "auto" },
        // Different values should NOT collapse
        .{ "overflow", "hidden scroll", "hidden scroll" },
        .{ "gap", "10px 20px", "10px 20px" },
    };
    inline for (cases) |case| {
        const result = try normalizePropertyValue(testing.allocator, case[0], case[1]);
        try testing.expectEqual(case[2], result);
    }
}

test "normalizePropertyValue: anchor() canonical order" {
    defer testing.reset();
    const cases = .{
        // Dashed ident should come before keyword
        .{ "left", "anchor(left --foo)", "anchor(--foo left)" },
        .{ "left", "anchor(inside --foo)", "anchor(--foo inside)" },
        .{ "left", "anchor(50% --foo)", "anchor(--foo 50%)" },
        // Already canonical order - keep as-is
        .{ "left", "anchor(--foo left)", "anchor(--foo left)" },
        .{ "left", "anchor(left)", "anchor(left)" },
        // With fallback
        .{ "left", "anchor(left --foo, 1px)", "anchor(--foo left, 1px)" },
        // Nested anchor in fallback
        .{ "left", "anchor(left --foo, anchor(right --bar))", "anchor(--foo left, anchor(--bar right))" },
    };
    inline for (cases) |case| {
        const result = try normalizePropertyValue(testing.arena_allocator, case[0], case[1]);
        try testing.expectEqual(case[2], result);
    }
}
