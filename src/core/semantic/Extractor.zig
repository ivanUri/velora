const std = @import("std");

const Frame = @import("../browser/Frame.zig");
const DOMNode = @import("../dom/Node.zig");
const Selector = @import("../webapi/selector/Selector.zig");
const String = @import("../../support/string.zig").String;
const dump = @import("../browser/dump.zig");

pub const Limits = struct {
    max_nodes: usize = 10_000,
    max_bytes: usize = 4 * 1024 * 1024,
    max_depth: usize = 16,
};

pub const Error = error{
    InvalidSchema,
    InvalidSelector,
    MissingRequiredField,
    NodeLimitExceeded,
    OutputLimitExceeded,
    MaxDepthExceeded,
    StaleDocument,
    OutOfMemory,
    WriteFailed,
};

pub fn extract(
    allocator: std.mem.Allocator,
    frame: *Frame,
    schema: std.json.Value,
    limits: Limits,
) Error!std.json.Value {
    if (schema != .object) return error.InvalidSchema;
    const epoch = frame.realmEpoch();
    if (!frame.realmSchedulingActive()) return error.StaleDocument;
    var state = State{
        .allocator = allocator,
        .frame = frame,
        .limits = limits,
        .epoch = epoch,
        .nodes_seen = 0,
        .bytes_seen = 0,
    };
    return state.object(frame.document.asNode(), schema.object, 0);
}

const State = struct {
    allocator: std.mem.Allocator,
    frame: *Frame,
    limits: Limits,
    epoch: @TypeOf(@as(Frame, undefined).realmEpoch()),
    nodes_seen: usize,
    bytes_seen: usize,

    fn guard(self: *State, depth: usize) Error!void {
        if (depth > self.limits.max_depth) return error.MaxDepthExceeded;
        if (!self.frame.realmSchedulingActive() or self.frame.realmEpoch() != self.epoch) {
            return error.StaleDocument;
        }
    }

    fn accountNode(self: *State) Error!void {
        self.nodes_seen += 1;
        if (self.nodes_seen > self.limits.max_nodes) return error.NodeLimitExceeded;
    }

    fn accountBytes(self: *State, n: usize) Error!void {
        self.bytes_seen += n;
        if (self.bytes_seen > self.limits.max_bytes) return error.OutputLimitExceeded;
    }

    fn object(self: *State, root: *DOMNode, fields: std.json.ObjectMap, depth: usize) Error!std.json.Value {
        try self.guard(depth);
        var result: std.json.ObjectMap = .{};
        var it = fields.iterator();
        while (it.next()) |entry| {
            const value = try self.field(root, entry.value_ptr.*, depth + 1);
            try result.put(self.allocator, entry.key_ptr.*, value);
        }
        return .{ .object = result };
    }

    fn field(self: *State, root: *DOMNode, spec: std.json.Value, depth: usize) Error!std.json.Value {
        try self.guard(depth);
        if (spec != .object) return error.InvalidSchema;
        const selector = stringField(spec.object, "selector") orelse null;
        var nodes: std.ArrayList(*DOMNode) = .empty;
        defer nodes.deinit(self.allocator);

        if (selector) |css| {
            const parsed = Selector.parseLeaky(self.allocator, css) catch return error.InvalidSelector;
            var set: std.AutoArrayHashMapUnmanaged(*DOMNode, void) = .empty;
            defer set.deinit(self.allocator);
            for (parsed.selectors) |parsed_selector| {
                Selector.List.collect(self.allocator, root, parsed_selector, &set, self.frame) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                };
            }
            for (set.keys()) |node| {
                try self.accountNode();
                try nodes.append(self.allocator, node);
            }
        } else {
            try self.accountNode();
            try nodes.append(self.allocator, root);
        }

        const all = boolField(spec.object, "all") orelse false;
        if (all) {
            var values = std.json.Array.init(self.allocator);
            for (nodes.items) |node| {
                try values.append(try self.valueForNode(node, spec.object, depth));
            }
            if (values.items.len == 0) return self.missing(spec.object);
            return .{ .array = values };
        }

        if (nodes.items.len == 0) return self.missing(spec.object);
        return self.valueForNode(nodes.items[0], spec.object, depth);
    }

    fn valueForNode(self: *State, node: *DOMNode, spec: std.json.ObjectMap, depth: usize) Error!std.json.Value {
        try self.guard(depth);
        if (spec.get("fields")) |nested| {
            if (nested != .object) return error.InvalidSchema;
            return self.object(node, nested.object, depth + 1);
        }

        if (stringField(spec, "attribute")) |name| {
            const element = node.is(DOMNode.Element) orelse return .null;
            const value = element.getAttributeSafe(String.wrap(name)) orelse return .null;
            try self.accountBytes(value.len);
            return .{ .string = try self.allocator.dupe(u8, value) };
        }

        var aw = std.Io.Writer.Allocating.init(self.allocator);
        defer aw.deinit();
        if (boolField(spec, "html") orelse false) {
            if (node.is(DOMNode.Element)) |_| {
                dump.deep(node, .{}, &aw.writer, self.frame) catch return error.WriteFailed;
            } else {
                try node.getTextContent(&aw.writer);
            }
        } else {
            try node.getTextContent(&aw.writer);
        }
        const text = std.mem.trim(u8, aw.written(), &std.ascii.whitespace);
        try self.accountBytes(text.len);
        return .{ .string = try self.allocator.dupe(u8, text) };
    }

    fn missing(self: *State, spec: std.json.ObjectMap) Error!std.json.Value {
        _ = self;
        if (spec.get("default")) |default| return default;
        if (boolField(spec, "required") orelse false) return error.MissingRequiredField;
        return .null;
    }
};

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn boolField(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    return if (value == .bool) value.bool else null;
}

const testing = @import("../../testing/testing.zig");

fn parseSchema(raw: []const u8) !std.json.Value {
    return (try std.json.parseFromSliceLeaky(std.json.Value, testing.arena_allocator, raw, .{}));
}

test "Extractor: scalar, attribute, list and nested fields" {
    defer testing.reset();
    const frame = try testing.pageTest("mcp_extract.html", .{});
    defer frame._session.removePage();

    const schema = try parseSchema(
        \\{
        \\  "heading": { "selector": "h2", "text": true, "required": true },
        \\  "firstSku": { "selector": ".product", "attribute": "data-sku" },
        \\  "products": {
        \\    "selector": ".product",
        \\    "all": true,
        \\    "fields": {
        \\      "name": { "selector": "h2", "text": true },
        \\      "price": { "selector": ".price", "text": true },
        \\      "href": { "selector": "a", "attribute": "href" }
        \\    }
        \\  }
        \\}
    );

    const result = try extract(testing.arena_allocator, frame, schema, .{});
    try testing.expect(result == .object);
    try testing.expectString("Alpha", result.object.get("heading").?.string);
    try testing.expectString("a-1", result.object.get("firstSku").?.string);

    const products = result.object.get("products").?.array.items;
    try testing.expectEqual(@as(usize, 2), products.len);
    try testing.expectString("Alpha", products[0].object.get("name").?.string);
    try testing.expectString("$20", products[1].object.get("price").?.string);
    try testing.expectString("/beta", products[1].object.get("href").?.string);
}

test "Extractor: optional default and required missing field" {
    defer testing.reset();
    const frame = try testing.pageTest("mcp_extract.html", .{});
    defer frame._session.removePage();

    const with_default = try parseSchema(
        \\{"missing":{"selector":".does-not-exist","default":"fallback"}}
    );
    const result = try extract(testing.arena_allocator, frame, with_default, .{});
    try testing.expectString("fallback", result.object.get("missing").?.string);

    const required = try parseSchema(
        \\{"missing":{"selector":".does-not-exist","required":true}}
    );
    try testing.expectError(
        error.MissingRequiredField,
        extract(testing.arena_allocator, frame, required, .{}),
    );
}

test "Extractor: invalid selector and limits are deterministic" {
    defer testing.reset();
    const frame = try testing.pageTest("mcp_extract.html", .{});
    defer frame._session.removePage();

    const invalid = try parseSchema(
        \\{"value":{"selector":"[","text":true}}
    );
    try testing.expectError(
        error.InvalidSelector,
        extract(testing.arena_allocator, frame, invalid, .{}),
    );

    const list = try parseSchema(
        \\{"products":{"selector":".product","all":true,"text":true}}
    );
    try testing.expectError(
        error.NodeLimitExceeded,
        extract(testing.arena_allocator, frame, list, .{ .max_nodes = 1 }),
    );
    try testing.expectError(
        error.OutputLimitExceeded,
        extract(testing.arena_allocator, frame, list, .{ .max_bytes = 1 }),
    );
}
