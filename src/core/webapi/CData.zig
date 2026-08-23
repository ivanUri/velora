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

const Node = @import("../dom/Node.zig");
pub const Text = @import("cdata/Text.zig");
pub const Comment = @import("cdata/Comment.zig");
pub const CDATASection = @import("cdata/CDATASection.zig");
pub const ProcessingInstruction = @import("cdata/ProcessingInstruction.zig");

const String = @import("../../support/string.zig").String;

const CData = @This();

_type: Type,
_proto: *Node,
_data: String = .empty,

const Utf16Seq = struct {
    byte_len: usize,
    units: [2]u16,
    unit_count: u8,

    fn codeUnit(self: Utf16Seq, index: usize) u16 {
        return self.units[index];
    }
};

fn readUtf16Seq(data: []const u8, i: usize) Utf16Seq {
    if (i >= data.len) return .{ .byte_len = 0, .units = .{ 0, 0 }, .unit_count = 0 };

    const byte = data[i];
    const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
        return .{ .byte_len = 1, .units = .{ data[i], 0 }, .unit_count = 1 };
    };
    if (i + seq_len > data.len) {
        return .{ .byte_len = 1, .units = .{ data[i], 0 }, .unit_count = 1 };
    }

    if (seq_len == 4) {
        const cp = std.unicode.utf8Decode(data[i .. i + 4]) catch {
            return .{ .byte_len = 1, .units = .{ data[i], 0 }, .unit_count = 1 };
        };
        const v = cp - 0x10000;
        return .{
            .byte_len = 4,
            .units = .{
                @intCast(0xD800 + (v >> 10)),
                @intCast(0xDC00 + (v & 0x3FF)),
            },
            .unit_count = 2,
        };
    }

    // WTF-8 stores lone UTF-16 surrogates as 3-byte sequences. std.unicode.utf8Decode
    // rejects U+D800..U+DFFF, so decode BMP manually (incl. surrogates).
    if (seq_len == 3) {
        const b0 = data[i];
        const b1 = data[i + 1];
        const b2 = data[i + 2];
        const cp: u21 = ((@as(u21, b0) & 0x0F) << 12) |
            ((@as(u21, b1) & 0x3F) << 6) |
            (@as(u21, b2) & 0x3F);
        return .{ .byte_len = 3, .units = .{ @intCast(cp), 0 }, .unit_count = 1 };
    }

    const cp = std.unicode.utf8Decode(data[i .. i + seq_len]) catch {
        return .{ .byte_len = 1, .units = .{ data[i], 0 }, .unit_count = 1 };
    };
    return .{ .byte_len = seq_len, .units = .{ @intCast(cp), 0 }, .unit_count = 1 };
}

fn encodeBmpCodepoint(cp: u21, buf: *[4]u8) usize {
    if (cp < 0x80) {
        buf[0] = @intCast(cp);
        return 1;
    }
    buf[0] = @intCast(0xE0 | ((cp >> 12) & 0x0F));
    buf[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
    buf[2] = @intCast(0x80 | (cp & 0x3F));
    return 3;
}

fn appendUtf16CodeUnit(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, cu: u16) !void {
    var buf: [4]u8 = undefined;
    const len = encodeBmpCodepoint(cu, &buf);
    try out.appendSlice(allocator, buf[0..len]);
}

fn appendUtf16CodeUnitPair(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, high: u16, low: u16) !void {
    if (high >= 0xD800 and high <= 0xDBFF and low >= 0xDC00 and low <= 0xDFFF) {
        const cp: u21 = 0x10000 + (@as(u21, high - 0xD800) << 10) + (low - 0xDC00);
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch {
            try appendUtf16CodeUnit(out, allocator, high);
            try appendUtf16CodeUnit(out, allocator, low);
            return;
        };
        try out.appendSlice(allocator, buf[0..len]);
        return;
    }
    try appendUtf16CodeUnit(out, allocator, high);
    try appendUtf16CodeUnit(out, allocator, low);
}

/// Encode UTF-16 code units as WTF-8 bytes (preserves lone surrogates).
pub fn utf16ToWtf8(allocator: std.mem.Allocator, code_units: []const u16) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < code_units.len) {
        const high = code_units[i];
        if (high >= 0xD800 and high <= 0xDBFF and i + 1 < code_units.len) {
            const low = code_units[i + 1];
            if (low >= 0xDC00 and low <= 0xDFFF) {
                try appendUtf16CodeUnitPair(&out, allocator, high, low);
                i += 2;
                continue;
            }
        }
        try appendUtf16CodeUnit(&out, allocator, high);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// Expand stored WTF-8/UTF-8 data to a UTF-16 code unit buffer.
pub fn wtf8ToUtf16(allocator: std.mem.Allocator, data: []const u8) ![]u16 {
    const len = utf16Len(data);
    var out = try allocator.alloc(u16, len);
    errdefer allocator.free(out);

    var cu_index: usize = 0;
    var i: usize = 0;
    while (i < data.len) {
        const seq = readUtf16Seq(data, i);
        if (seq.byte_len == 0) break;
        for (0..seq.unit_count) |sub| {
            out[cu_index] = seq.codeUnit(sub);
            cu_index += 1;
        }
        i += seq.byte_len;
    }
    return out;
}

/// Count UTF-16 code units in stored WTF-8/UTF-8 data.
pub fn utf16Len(data: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < data.len) {
        const seq = readUtf16Seq(data, i);
        if (seq.byte_len == 0) break;
        count += seq.unit_count;
        i += seq.byte_len;
    }
    return count;
}

/// Extract `count` UTF-16 code units starting at `offset`, re-encoding as WTF-8/UTF-8.
pub fn extractUtf16Range(allocator: std.mem.Allocator, data: []const u8, offset: usize, count: usize) ![]const u8 {
    const total = utf16Len(data);
    if (offset > total) return error.IndexSizeError;
    const effective_count = @min(count, total - offset);
    if (effective_count == 0) return try allocator.dupe(u8, "");

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var cu_pos: usize = 0;
    var i: usize = 0;
    var extracted: usize = 0;

    while (i < data.len and extracted < effective_count) {
        const seq = readUtf16Seq(data, i);
        if (seq.byte_len == 0) break;

        var sub: usize = 0;
        while (sub < seq.unit_count and extracted < effective_count) : (sub += 1) {
            if (cu_pos < offset) {
                cu_pos += 1;
                continue;
            }

            if (seq.unit_count == 2 and sub == 0 and extracted + 1 < effective_count and
                cu_pos + 1 < offset + effective_count)
            {
                try appendUtf16CodeUnitPair(&out, allocator, seq.units[0], seq.units[1]);
                extracted += 2;
                cu_pos += 2;
                sub += 1;
                continue;
            }

            try appendUtf16CodeUnit(&out, allocator, seq.codeUnit(sub));
            extracted += 1;
            cu_pos += 1;
        }
        i += seq.byte_len;
    }

    return try out.toOwnedSlice(allocator);
}

fn spliceUtf16(allocator: std.mem.Allocator, data: []const u8, offset: usize, delete_count: usize, insert: []const u8) ![]const u8 {
    const total = utf16Len(data);
    if (offset > total) return error.IndexSizeError;
    const effective_delete = @min(delete_count, total - offset);

    const prefix = try extractUtf16Range(allocator, data, 0, offset);
    defer allocator.free(prefix);
    const suffix = try extractUtf16Range(allocator, data, offset + effective_delete, total - offset - effective_delete);
    defer allocator.free(suffix);

    const result = try String.concat(allocator, &.{ prefix, insert, suffix });
    defer result.deinit(allocator);
    // concat may return SSO on the stack; dupe before returning the slice.
    return try allocator.dupe(u8, result.str());
}

/// Convert a UTF-16 code unit offset to a UTF-8 byte offset.
/// Returns IndexSizeError if utf16_offset > utf16 length of data.
/// Offsets that fall between surrogate halves map to the byte index of the pair.
pub fn utf16OffsetToUtf8(data: []const u8, utf16_offset: usize) error{IndexSizeError}!usize {
    var cu_pos: usize = 0;
    var i: usize = 0;
    while (i < data.len) {
        if (cu_pos == utf16_offset) return i;
        const seq = readUtf16Seq(data, i);
        if (seq.byte_len == 0) break;
        if (cu_pos + seq.unit_count > utf16_offset) return i;
        cu_pos += seq.unit_count;
        i += seq.byte_len;
    }
    if (cu_pos == utf16_offset) return i;
    return error.IndexSizeError;
}

pub const Type = union(enum) {
    text: Text,
    comment: Comment,
    // This should be under Text, but that would require storing a _type union
    // in text, which would add 8 bytes to every text node.
    cdata_section: CDATASection,
    processing_instruction: *ProcessingInstruction,
};

pub fn asNode(self: *CData) *Node {
    return self._proto;
}

pub fn is(self: *CData, comptime T: type) ?*T {
    inline for (@typeInfo(Type).@"union".fields) |f| {
        if (@field(Type, f.name) == self._type) {
            if (f.type == T) {
                return &@field(self._type, f.name);
            }
            if (f.type == *T) {
                return @field(self._type, f.name);
            }
        }
    }
    return null;
}

pub fn getData(self: *const CData) String {
    return self._data;
}

fn getDomData(self: *const CData, frame: *Frame) ![]const u16 {
    return wtf8ToUtf16(frame.call_arena, self._data.str());
}

pub const RenderOpts = struct {
    trim_left: bool = true,
    trim_right: bool = true,
};
// Replace successives whitespaces with one whitespace.
// Trims left and right according to the options.
// Returns true if the string ends with a trimmed whitespace.
pub fn render(self: *const CData, writer: *std.Io.Writer, opts: RenderOpts) !bool {
    var start: usize = 0;
    var prev_w: ?bool = null;
    var is_w: bool = undefined;
    const s = self._data.str();

    for (s, 0..) |c, i| {
        is_w = std.ascii.isWhitespace(c);

        // Detect the first char type.
        if (prev_w == null) {
            prev_w = is_w;
        }
        // The current char is the same kind of char, the chunk continues.
        if (prev_w.? == is_w) {
            continue;
        }

        // Starting here, the chunk changed.
        if (is_w) {
            // We have a chunk of non-whitespaces, we write it as it.
            try writer.writeAll(s[start..i]);
        } else {
            // We have a chunk of whitespaces, replace with one space,
            // depending the position.
            if (start > 0 or !opts.trim_left) {
                try writer.writeByte(' ');
            }
        }
        // Start the new chunk.
        prev_w = is_w;
        start = i;
    }
    // Write the reminder chunk.
    if (is_w) {
        // Last chunk is whitespaces.
        // If the string contains only whitespaces, don't write it.
        if (start > 0 and opts.trim_right == false) {
            try writer.writeByte(' ');
        } else {
            return true;
        }
    } else {
        // last chunk is non whitespaces.
        try writer.writeAll(s[start..]);
    }

    return false;
}

pub fn setData(self: *CData, value: ?[]const u8, frame: *Frame) !void {
    const old_value = self._data;

    if (value) |v| {
        self._data = try frame.dupeSSO(v);
    } else {
        self._data = .empty;
    }

    frame.characterDataChange(self.asNode(), old_value);
}

/// JS bridge wrapper for `data` setter.
/// Per spec, setting .data runs replaceData(0, this.length, value),
/// which includes live range updates.
/// Handles [LegacyNullToEmptyString]: null → "" per spec.
pub fn _setData(self: *CData, value: js.Value, frame: *Frame) !void {
    const new_data: js.Wtf8String = if (value.isNull())
        .{ .value = "" }
    else
        try value.toZig(js.Wtf8String);
    const length = self.getLength();
    try self.replaceData(0, length, new_data, frame);
}

pub fn format(self: *const CData, writer: *std.Io.Writer) !void {
    return switch (self._type) {
        .text => writer.print("<text>{f}</text>", .{self._data}),
        .comment => writer.print("<!-- {f} -->", .{self._data}),
        .cdata_section => writer.print("<![CDATA[{f}]]>", .{self._data}),
        .processing_instruction => |pi| writer.print("<?{s} {f}?>", .{ pi._target, self._data }),
    };
}

pub fn getLength(self: *const CData) usize {
    return utf16Len(self._data.str());
}

pub fn isEqualNode(self: *const CData, other: *const CData) bool {
    if (std.meta.activeTag(self._type) != std.meta.activeTag(other._type)) {
        return false;
    }

    if (self._type == .processing_instruction) {
        @branchHint(.unlikely);
        if (std.mem.eql(u8, self._type.processing_instruction._target, other._type.processing_instruction._target) == false) {
            return false;
        }
        // if the _targets are equal, we still want to compare the data
    }

    return self._data.eql(other._data);
}

pub fn appendData(self: *CData, data: js.Wtf8String, frame: *Frame) !void {
    // Per DOM spec, appendData(data) is replaceData(length, 0, data).
    const length = self.getLength();
    try self.replaceData(length, 0, data, frame);
}

pub fn deleteData(self: *CData, offset: usize, count: usize, frame: *Frame) !void {
    try self.replaceData(offset, count, .{ .value = "" }, frame);
}

pub fn insertData(self: *CData, offset: usize, data: js.Wtf8String, frame: *Frame) !void {
    try self.replaceData(offset, 0, data, frame);
}

pub fn replaceData(self: *CData, offset: usize, count: usize, data: js.Wtf8String, frame: *Frame) !void {
    const existing = self._data.str();
    const length = self.getLength();
    if (offset > length) return error.IndexSizeError;
    const effective_count: u32 = @intCast(@min(count, length - offset));

    frame.updateRangesForCharacterDataReplace(self.asNode(), @intCast(offset), effective_count, @intCast(utf16Len(data.value)));

    const old_value = self._data;
    const new_bytes = try spliceUtf16(frame.arena, existing, offset, count, data.value);
    self._data = try frame.dupeSSO(new_bytes);
    frame.characterDataChange(self.asNode(), old_value);
}

/// Extract UTF-16 code units directly from stored WTF-8/UTF-8 data.
pub fn extractUtf16CodeUnits(allocator: std.mem.Allocator, data: []const u8, offset: usize, count: usize) ![]const u16 {
    const total = utf16Len(data);
    if (offset > total) return error.IndexSizeError;
    const effective_count = @min(count, total - offset);
    if (effective_count == 0) return &[_]u16{};

    const out = try allocator.alloc(u16, effective_count);
    errdefer allocator.free(out);

    var cu_pos: usize = 0;
    var out_idx: usize = 0;
    var i: usize = 0;
    while (i < data.len and out_idx < effective_count) {
        const seq = readUtf16Seq(data, i);
        if (seq.byte_len == 0) break;
        for (0..seq.unit_count) |sub| {
            if (cu_pos >= offset and out_idx < effective_count) {
                out[out_idx] = seq.codeUnit(sub);
                out_idx += 1;
            }
            cu_pos += 1;
        }
        i += seq.byte_len;
    }
    return out;
}

pub fn substringData(self: *const CData, offset: usize, count: usize, frame: *Frame) ![]const u16 {
    return extractUtf16CodeUnits(frame.call_arena, self._data.str(), offset, count);
}

pub fn remove(self: *CData, frame: *Frame) !void {
    const node = self.asNode();
    const parent = node.parentNode() orelse return;
    _ = try parent.removeChild(node, frame);
}

pub fn before(self: *CData, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    const node = self.asNode();
    const parent = node.parentNode() orelse return;

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);
        _ = try parent.insertBefore(child, node, frame);
    }
}

pub fn after(self: *CData, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    const node = self.asNode();
    const parent = node.parentNode() orelse return;
    const viable_next = Node.NodeOrText.viableNextSibling(node, nodes);

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);
        _ = try parent.insertBefore(child, viable_next, frame);
    }
}

pub fn replaceWith(self: *CData, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    const ref_node = self.asNode();
    const parent = ref_node.parentNode() orelse return;

    var rm_ref_node = true;
    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);
        if (child == ref_node) {
            rm_ref_node = false;
            continue;
        }
        _ = try parent.insertBefore(child, ref_node, frame);
    }

    if (rm_ref_node) {
        _ = try parent.removeChild(ref_node, frame);
    }
}

pub fn nextElementSibling(self: *CData) ?*Node.Element {
    var maybe_sibling = self.asNode().nextSibling();
    while (maybe_sibling) |sibling| {
        if (sibling.is(Node.Element)) |el| return el;
        maybe_sibling = sibling.nextSibling();
    }
    return null;
}

pub fn previousElementSibling(self: *CData) ?*Node.Element {
    var maybe_sibling = self.asNode().previousSibling();
    while (maybe_sibling) |sibling| {
        if (sibling.is(Node.Element)) |el| return el;
        maybe_sibling = sibling.previousSibling();
    }
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CData);

    pub const Meta = struct {
        pub const name = "CharacterData";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const enumerable = false;
    };

    pub const data = bridge.accessor(CData.getDomData, CData._setData, .{});
    pub const length = bridge.accessor(CData.getLength, null, .{});

    pub const appendData = bridge.function(CData.appendData, .{});
    pub const deleteData = bridge.function(CData.deleteData, .{ .dom_exception = true });
    pub const insertData = bridge.function(CData.insertData, .{ .dom_exception = true });
    pub const replaceData = bridge.function(CData.replaceData, .{ .dom_exception = true });
    pub const substringData = bridge.function(CData.substringData, .{ .dom_exception = true });

    pub const remove = bridge.function(CData.remove, .{});
    pub const before = bridge.function(CData.before, .{});
    pub const after = bridge.function(CData.after, .{});
    pub const replaceWith = bridge.function(CData.replaceWith, .{});

    pub const nextElementSibling = bridge.accessor(CData.nextElementSibling, null, .{});
    pub const previousElementSibling = bridge.accessor(CData.previousElementSibling, null, .{});
};

const testing = @import("../../testing/testing.zig");
test "WebApi: CData" {
    try testing.htmlRunner("cdata", .{});
}

test "WebApi: CData.render" {
    const allocator = std.testing.allocator;

    const TestCase = struct {
        value: []const u8,
        expected: []const u8,
        result: bool = false,
        opts: RenderOpts = .{},
    };

    const test_cases = [_]TestCase{
        .{ .value = "   ", .expected = "", .result = true },
        .{ .value = "   ", .expected = "", .opts = .{ .trim_left = false, .trim_right = false }, .result = true },
        .{ .value = "foo bar", .expected = "foo bar" },
        .{ .value = "foo  bar", .expected = "foo bar" },
        .{ .value = "  foo bar", .expected = "foo bar" },
        .{ .value = "foo bar  ", .expected = "foo bar", .result = true },
        .{ .value = "  foo  bar  ", .expected = "foo bar", .result = true },
        .{ .value = "foo\n\tbar", .expected = "foo bar" },
        .{ .value = "\tfoo bar   baz   \t\n yeah\r\n", .expected = "foo bar baz yeah", .result = true },
        .{ .value = "  foo bar", .expected = " foo bar", .opts = .{ .trim_left = false } },
        .{ .value = "foo bar  ", .expected = "foo bar ", .opts = .{ .trim_right = false } },
        .{ .value = "  foo bar  ", .expected = " foo bar ", .opts = .{ .trim_left = false, .trim_right = false } },
    };

    var buffer = std.Io.Writer.Allocating.init(allocator);
    defer buffer.deinit();
    for (test_cases) |test_case| {
        buffer.clearRetainingCapacity();

        const cdata = CData{
            ._type = .{ .text = undefined },
            ._proto = undefined,
            ._data = .wrap(test_case.value),
        };

        const result = try cdata.render(&buffer.writer, test_case.opts);

        try std.testing.expectEqualStrings(test_case.expected, buffer.written());
        try std.testing.expect(result == test_case.result);
    }
}

test "utf16Len" {
    // ASCII: 1 byte = 1 code unit each
    try std.testing.expectEqual(@as(usize, 0), utf16Len(""));
    try std.testing.expectEqual(@as(usize, 5), utf16Len("hello"));
    // CJK: 3 bytes UTF-8 = 1 UTF-16 code unit each
    try std.testing.expectEqual(@as(usize, 2), utf16Len("資料")); // 6 bytes, 2 code units
    // Emoji U+1F320: 4 bytes UTF-8 = 2 UTF-16 code units (surrogate pair)
    try std.testing.expectEqual(@as(usize, 2), utf16Len("🌠")); // 4 bytes, 2 code units
    // Mixed: 🌠(2) + " test "(6) + 🌠(2) + " TEST"(5) = 15
    try std.testing.expectEqual(@as(usize, 15), utf16Len("🌠 test 🌠 TEST"));
    // 2-byte UTF-8 (e.g. é U+00E9): 1 UTF-16 code unit
    try std.testing.expectEqual(@as(usize, 4), utf16Len("café")); // c(1) + a(1) + f(1) + é(1)
}

test "utf16OffsetToUtf8" {
    try std.testing.expectEqual(@as(usize, 0), try utf16OffsetToUtf8("hello", 0));
    try std.testing.expectEqual(@as(usize, 3), try utf16OffsetToUtf8("hello", 3));
    try std.testing.expectEqual(@as(usize, 5), try utf16OffsetToUtf8("hello", 5));
    try std.testing.expectError(error.IndexSizeError, utf16OffsetToUtf8("hello", 6));

    try std.testing.expectEqual(@as(usize, 0), try utf16OffsetToUtf8("🌠AB", 0));
    // offset 1 lands inside the surrogate pair — maps to the pair's byte index
    try std.testing.expectEqual(@as(usize, 0), try utf16OffsetToUtf8("🌠AB", 1));
    try std.testing.expectEqual(@as(usize, 4), try utf16OffsetToUtf8("🌠AB", 2));
}

test "extractUtf16Range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("ell", try extractUtf16Range(allocator, "hello", 1, 3));
    try std.testing.expectEqualStrings("hello", try extractUtf16Range(allocator, "hello", 0, 100));
    try std.testing.expectEqualStrings("", try extractUtf16Range(allocator, "hello", 5, 1));

    // Full supplementary character stays compact when both halves are extracted
    try std.testing.expectEqualStrings("🌠", try extractUtf16Range(allocator, "🌠AB", 0, 2));
    try std.testing.expectEqualStrings("A", try extractUtf16Range(allocator, "🌠AB", 2, 1));

    // Splitting surrogate pairs produces lone surrogates (WTF-8)
    {
        const result = try extractUtf16Range(allocator, "🌠 test 🌠 TEST", 1, 8);
        defer allocator.free(result);
        try std.testing.expectEqual(@as(usize, 12), result.len);
        try std.testing.expectEqual(@as(u16, 0xDF20), readUtf16Seq(result, 0).units[0]);
        try std.testing.expectEqualStrings(" test ", result[3..9]);
        try std.testing.expectEqual(@as(u16, 0xD83C), readUtf16Seq(result, 9).units[0]);
    }

    try std.testing.expectEqualStrings("st 🌠 TE", try extractUtf16Range(allocator, "🌠 test 🌠 TEST", 5, 8));
    try std.testing.expectError(error.IndexSizeError, extractUtf16Range(allocator, "hello", 6, 0));
}

test "spliceUtf16 deleteData surrogate sequence" {
    const allocator = std.testing.allocator;
    const original = "🌠 test 🌠 TEST";
    const after1 = try spliceUtf16(allocator, original, 1, 4, "");
    defer allocator.free(after1);
    try std.testing.expectEqual(@as(usize, 11), utf16Len(after1));

    const after2 = try spliceUtf16(allocator, after1, 1, 4, "");
    defer allocator.free(after2);
    try std.testing.expectEqual(@as(usize, 7), utf16Len(after2));

    const cu = try wtf8ToUtf16(allocator, after2);
    defer allocator.free(cu);
    try std.testing.expectEqual(@as(u16, 0xD83C), cu[0]);
    try std.testing.expectEqual(@as(u16, 0xDF20), cu[1]);
}

test "utf16ToWtf8 roundtrip" {
    const allocator = std.testing.allocator;
    const cu = [_]u16{ 0xD83C, 0xDF20, 0x20, 0x74, 0x65, 0x73, 0x74 };
    const wtf = try utf16ToWtf8(allocator, &cu);
    defer allocator.free(wtf);
    const back = try wtf8ToUtf16(allocator, wtf);
    defer allocator.free(back);
    try std.testing.expectEqualSlices(u16, &cu, back);
}
