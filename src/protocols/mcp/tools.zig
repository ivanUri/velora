const std = @import("std");

const log = @import("../../support/log.zig");
const js = @import("../../core/js/js.zig");

const DOMNode = @import("../../core/dom/Node.zig");
const protocol = @import("protocol.zig");
const Server = @import("Server.zig");
const CDPNode = @import("../cdp/Node.zig");
const ToolRegistry = @import("../automation/ToolRegistry.zig");

const goto_schema = protocol.minify(
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "url": { "type": "string", "description": "The URL to navigate to, must be a valid URL." },
    \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 10000." },
    \\    "waitUntil": { "type": "string", "enum": ["load", "domcontentloaded", "networkidle", "domstable", "done"], "description": "Optional wait strategy. Defaults to 'done'." }
    \\  },
    \\  "required": ["url"]
    \\}
);

const url_params_schema = protocol.minify(
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "url": { "type": "string", "description": "Optional URL to navigate to before processing." },
    \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 10000." },
    \\    "waitUntil": { "type": "string", "enum": ["load", "domcontentloaded", "networkidle", "domstable", "done"], "description": "Optional wait strategy. Defaults to 'done'." }
    \\  }
    \\}
);

const evaluate_schema = protocol.minify(
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "script": { "type": "string" },
    \\    "url": { "type": "string", "description": "Optional URL to navigate to before evaluating." },
    \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 10000." },
    \\    "waitUntil": { "type": "string", "enum": ["load", "domcontentloaded", "networkidle", "domstable", "done"], "description": "Optional wait strategy. Defaults to 'done'." }
    \\  },
    \\  "required": ["script"]
    \\}
);

pub const tool_list = [_]protocol.Tool{
    .{
        .action = .goto,
        .name = "goto",
        .description = "Navigate to a specified URL and load the page in memory so it can be reused later for info extraction.",
        .inputSchema = goto_schema,
    },
    .{
        .action = .goto,
        .name = "navigate",
        .description = "Alias for goto. Navigate to a specified URL and load the page in memory.",
        .inputSchema = goto_schema,
    },
    .{
        .action = .markdown,
        .name = "markdown",
        .description = "Get the page content in markdown format. If a url is provided, it navigates to that url first.",
        .inputSchema = url_params_schema,
    },
    .{
        .action = .links,
        .name = "links",
        .description = "Extract all links in the opened frame. If a url is provided, it navigates to that url first.",
        .inputSchema = url_params_schema,
    },
    .{
        .action = .extract,
        .name = "extract",
        .description = "Extract structured data from the current page with a selector schema. Supports scalar fields, lists, nested fields, text, HTML, attributes, required fields, and defaults.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "schema": { "type": "object", "description": "Object whose keys are output fields and values are extraction specifications." },
            \\    "maxNodes": { "type": "integer", "minimum": 1, "description": "Maximum number of matched nodes. Defaults to 10000." },
            \\    "maxBytes": { "type": "integer", "minimum": 1, "description": "Maximum extracted text/HTML bytes. Defaults to 4194304." },
            \\    "maxDepth": { "type": "integer", "minimum": 1, "description": "Maximum nested schema depth. Defaults to 16." }
            \\  },
            \\  "required": ["schema"]
            \\}
        ),
    },
    .{
        .action = .evaluate,
        .name = "evaluate",
        .description = "Evaluate JavaScript in the current page context. If a url is provided, it navigates to that url first.",
        .inputSchema = evaluate_schema,
    },
    .{
        .action = .evaluate,
        .name = "eval",
        .description = "Alias for evaluate. Evaluate JavaScript in the current page context.",
        .inputSchema = evaluate_schema,
    },
    .{
        .action = .semantic_tree,
        .name = "semantic_tree",
        .description = "Get the page content as a simplified semantic DOM tree for AI reasoning. If a url is provided, it navigates to that url first.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "url": { "type": "string", "description": "Optional URL to navigate to before fetching the semantic tree." },
            \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 10000." },
            \\    "waitUntil": { "type": "string", "enum": ["load", "domcontentloaded", "networkidle", "domstable", "done"], "description": "Optional wait strategy. Defaults to 'done'." },
            \\    "backendNodeId": { "type": "integer", "description": "Optional backend node ID to get the tree for a specific element instead of the document root." },
            \\    "maxDepth": { "type": "integer", "description": "Optional maximum depth of the tree to return. Useful for exploring high-level structure first." }
            \\  }
            \\}
        ),
    },
    .{
        .action = .node_details,
        .name = "nodeDetails",
        .description = "Get detailed information about a specific node by its backend node ID. Returns tag, role, name, interactivity, disabled state, value, input type, placeholder, href, checked state, and select options.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "backendNodeId": { "type": "integer", "description": "The backend node ID of the element to inspect." }
            \\  },
            \\  "required": ["backendNodeId"]
            \\}
        ),
    },
    .{
        .action = .interactive_elements,
        .name = "interactiveElements",
        .description = "Extract interactive elements from the opened frame. If a url is provided, it navigates to that url first.",
        .inputSchema = url_params_schema,
    },
    .{
        .action = .structured_data,
        .name = "structuredData",
        .description = "Extract structured data (like JSON-LD, OpenGraph, etc) from the opened frame. If a url is provided, it navigates to that url first.",
        .inputSchema = url_params_schema,
    },
    .{
        .action = .detect_forms,
        .name = "detectForms",
        .description = "Detect all forms on the page and return their structure including fields, types, and required status. If a url is provided, it navigates to that url first.",
        .inputSchema = url_params_schema,
    },
    .{
        .action = .click,
        .name = "click",
        .description = "Click on an interactive element. Returns the current page URL and title after the click.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "backendNodeId": { "type": "integer", "description": "The backend node ID of the element to click." }
            \\  },
            \\  "required": ["backendNodeId"]
            \\}
        ),
    },
    .{
        .action = .fill,
        .name = "fill",
        .description = "Fill text into an input element. Returns the filled value and current page URL and title.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "backendNodeId": { "type": "integer", "description": "The backend node ID of the input element to fill." },
            \\    "text": { "type": "string", "description": "The text to fill into the input element." }
            \\  },
            \\  "required": ["backendNodeId", "text"]
            \\}
        ),
    },
    .{
        .action = .scroll,
        .name = "scroll",
        .description = "Scroll the page or a specific element. Returns the scroll position and current page URL and title.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "backendNodeId": { "type": "integer", "description": "Optional: The backend node ID of the element to scroll. If omitted, scrolls the window." },
            \\    "x": { "type": "integer", "description": "Optional: The horizontal scroll offset." },
            \\    "y": { "type": "integer", "description": "Optional: The vertical scroll offset." }
            \\  }
            \\}
        ),
    },
    .{
        .action = .wait_for_selector,
        .name = "waitForSelector",
        .description = "Wait for an element matching a CSS selector to appear in the frame. Returns the backend node ID of the matched element.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "selector": { "type": "string", "description": "The CSS selector to wait for." },
            \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 5000." }
            \\  },
            \\  "required": ["selector"]
            \\}
        ),
    },
    .{
        .action = .hover,
        .name = "hover",
        .description = "Hover over an element, triggering mouseover and mouseenter events. Useful for menus, tooltips, and hover states.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "backendNodeId": { "type": "integer", "description": "The backend node ID of the element to hover over." }
            \\  },
            \\  "required": ["backendNodeId"]
            \\}
        ),
    },
    .{
        .action = .press,
        .name = "press",
        .description = "Press a keyboard key, dispatching keydown and keyup events. Use key names like 'Enter', 'Tab', 'Escape', 'ArrowDown', 'Backspace', or single characters like 'a', '1'.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "key": { "type": "string", "description": "The key to press (e.g. 'Enter', 'Tab', 'a')." },
            \\    "backendNodeId": { "type": "integer", "description": "Optional backend node ID of the element to target. Defaults to the document." }
            \\  },
            \\  "required": ["key"]
            \\}
        ),
    },
    .{
        .action = .select_option,
        .name = "selectOption",
        .description = "Select an option in a <select> dropdown element by its value. Dispatches input and change events.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "backendNodeId": { "type": "integer", "description": "The backend node ID of the <select> element." },
            \\    "value": { "type": "string", "description": "The value of the option to select." }
            \\  },
            \\  "required": ["backendNodeId", "value"]
            \\}
        ),
    },
    .{
        .action = .set_checked,
        .name = "setChecked",
        .description = "Check or uncheck a checkbox or radio button. Dispatches input, change, and click events.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "backendNodeId": { "type": "integer", "description": "The backend node ID of the checkbox or radio input element." },
            \\    "checked": { "type": "boolean", "description": "Whether to check (true) or uncheck (false) the element." }
            \\  },
            \\  "required": ["backendNodeId", "checked"]
            \\}
        ),
    },
    .{
        .action = .find_element,
        .name = "findElement",
        .description = "Find interactive elements by role and/or accessible name. Returns matching elements with their backend node IDs. Useful for locating specific elements without parsing the full semantic tree.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "role": { "type": "string", "description": "Optional ARIA role to match (e.g. 'button', 'link', 'textbox', 'checkbox')." },
            \\    "name": { "type": "string", "description": "Optional accessible name substring to match (case-insensitive)." }
            \\  }
            \\}
        ),
    },
    .{
        .action = .recording_start,
        .name = "recordingStart",
        .description = "Start a new deterministic action recording. Any previous in-memory recording is cleared.",
        .inputSchema = protocol.minify(
            \\{"type":"object","properties":{}}
        ),
    },
    .{
        .action = .recording_stop,
        .name = "recordingStop",
        .description = "Stop action recording and return the versioned workflow JSON.",
        .inputSchema = protocol.minify(
            \\{"type":"object","properties":{}}
        ),
    },
    .{
        .action = .workflow_export,
        .name = "workflowExport",
        .description = "Export the current action journal as versioned JSON or JavaScript.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type":"object",
            \\  "properties":{"format":{"type":"string","enum":["json","javascript"]}}
            \\}
        ),
    },
    .{
        .action = .workflow_replay,
        .name = "workflowReplay",
        .description = "Replay a versioned deterministic workflow without an LLM.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type":"object",
            \\  "properties":{"workflow":{"type":"object"}},
            \\  "required":["workflow"]
            \\}
        ),
    },
};

comptime {
    const definitions = blk: {
        var result: [tool_list.len]ToolRegistry.Definition = undefined;
        for (tool_list, 0..) |tool, i| {
            result[i] = .{
                .action = tool.action,
                .name = tool.name,
                .description = tool.description,
                .input_schema = tool.inputSchema,
            };
        }
        break :blk result;
    };
    ToolRegistry.validate(&definitions);
}

pub fn handleList(server: *Server, arena: std.mem.Allocator, req: protocol.Request) !void {
    _ = arena;
    const id = req.id orelse return;
    try server.sendResult(id, .{ .tools = &tool_list });
}

const GotoParams = struct {
    url: [:0]const u8,
    timeout: ?u32 = null,
    waitUntil: ?@import("../../runtime/Config.zig").WaitUntil = null,
};

const UrlParams = struct {
    url: ?[:0]const u8 = null,
    timeout: ?u32 = null,
    waitUntil: ?@import("../../runtime/Config.zig").WaitUntil = null,
};

const EvaluateParams = struct {
    script: [:0]const u8,
    url: ?[:0]const u8 = null,
    timeout: ?u32 = null,
    waitUntil: ?@import("../../runtime/Config.zig").WaitUntil = null,
};

const ToolStreamingText = struct {
    frame: *@import("../../core/browser/Frame.zig"),
    action: enum { markdown, links, semantic_tree },
    registry: ?*CDPNode.Registry = null,
    arena: ?std.mem.Allocator = null,
    backendNodeId: ?u32 = null,
    maxDepth: ?u32 = null,

    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        try jw.beginWriteRaw();
        try jw.writer.writeByte('"');
        var escaped: protocol.JsonEscapingWriter = .init(jw.writer);
        const w = &escaped.writer;

        switch (self.action) {
            .markdown => @import("../../core/browser/markdown.zig").dump(self.frame.document.asNode(), .{}, w, self.frame) catch |err| {
                log.err(.mcp, "markdown dump failed", .{ .err = err });
                return error.WriteFailed;
            },
            .links => {
                const links = @import("../../core/browser/links.zig").collectLinks(self.frame.call_arena, self.frame.document.asNode(), self.frame) catch |err| {
                    log.err(.mcp, "query links failed", .{ .err = err });
                    return error.WriteFailed;
                };
                var first = true;
                for (links) |href| {
                    if (!first) try w.writeByte('\n');
                    try w.writeAll(href);
                    first = false;
                }
            },
            .semantic_tree => {
                var root_node = self.frame.document.asNode();
                if (self.backendNodeId) |node_id| {
                    if (self.registry) |registry| {
                        if (registry.lookup_by_id.get(node_id)) |n| {
                            root_node = n.dom;
                        } else {
                            log.warn(.mcp, "semantic_tree id missing", .{ .id = node_id });
                        }
                    }
                }

                const st = @import("../../core/semantic/SemanticTree.zig"){
                    .dom_node = root_node,
                    .registry = self.registry.?,
                    .frame = self.frame,
                    .arena = self.arena.?,
                    .prune = true,
                    .max_depth = self.maxDepth orelse std.math.maxInt(u32) - 1,
                };

                st.textStringify(w) catch |err| {
                    log.err(.mcp, "semantic tree dump failed", .{ .err = err });
                    return error.WriteFailed;
                };
            },
        }

        try jw.writer.writeByte('"');
        jw.endWriteRaw();
    }
};

fn findTool(name: []const u8) ?*const protocol.Tool {
    for (&tool_list) |*tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

pub fn handleCall(server: *Server, arena: std.mem.Allocator, req: protocol.Request) !void {
    if (req.params == null or req.id == null) {
        return server.sendError(req.id orelse .{ .integer = -1 }, .InvalidParams, "Missing params");
    }

    const CallParams = struct {
        name: []const u8,
        arguments: ?std.json.Value = null,
    };

    const call_params = std.json.parseFromValueLeaky(CallParams, arena, req.params.?, .{ .ignore_unknown_fields = true }) catch {
        return server.sendError(req.id.?, .InvalidParams, "Invalid params");
    };

    const tool = findTool(call_params.name) orelse {
        return server.sendError(req.id.?, .MethodNotFound, "Tool not found");
    };

    switch (tool.action) {
        .goto => try handleGoto(server, arena, req.id.?, call_params.arguments),
        .markdown => try handleMarkdown(server, arena, req.id.?, call_params.arguments),
        .links => try handleLinks(server, arena, req.id.?, call_params.arguments),
        .extract => try handleExtract(server, arena, req.id.?, call_params.arguments),
        .node_details => try handleNodeDetails(server, arena, req.id.?, call_params.arguments),
        .interactive_elements => try handleInteractiveElements(server, arena, req.id.?, call_params.arguments),
        .structured_data => try handleStructuredData(server, arena, req.id.?, call_params.arguments),
        .detect_forms => try handleDetectForms(server, arena, req.id.?, call_params.arguments),
        .evaluate => try handleEvaluate(server, arena, req.id.?, call_params.arguments),
        .semantic_tree => try handleSemanticTree(server, arena, req.id.?, call_params.arguments),
        .click => try handleClick(server, arena, req.id.?, call_params.arguments),
        .fill => try handleFill(server, arena, req.id.?, call_params.arguments),
        .scroll => try handleScroll(server, arena, req.id.?, call_params.arguments),
        .wait_for_selector => try handleWaitForSelector(server, arena, req.id.?, call_params.arguments),
        .hover => try handleHover(server, arena, req.id.?, call_params.arguments),
        .press => try handlePress(server, arena, req.id.?, call_params.arguments),
        .select_option => try handleSelectOption(server, arena, req.id.?, call_params.arguments),
        .set_checked => try handleSetChecked(server, arena, req.id.?, call_params.arguments),
        .find_element => try handleFindElement(server, arena, req.id.?, call_params.arguments),
        .recording_start => try handleRecordingStart(server, req.id.?),
        .recording_stop => try handleRecordingStop(server, arena, req.id.?),
        .workflow_export => try handleWorkflowExport(server, arena, req.id.?, call_params.arguments),
        .workflow_replay => try handleWorkflowReplay(server, arena, req.id.?, call_params.arguments),
    }
}

fn handleGoto(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const args = try parseArgs(GotoParams, arena, arguments, server, id, "goto");
    try performGoto(server, args.url, id, args.timeout, args.waitUntil);

    const content = [_]protocol.TextContent([]const u8){.{ .text = "Navigated successfully." }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
    _ = try server.action_journal.append(.goto, "goto", arguments, true);
}

fn handleMarkdown(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const args = try parseArgsOrDefault(UrlParams, arena, arguments, server, id);
    const frame = try ensurePage(server, id, args.url, args.timeout, args.waitUntil);

    const content = [_]protocol.TextContent(ToolStreamingText){.{
        .text = .{ .frame = frame, .action = .markdown },
    }};
    server.sendResult(id, protocol.CallToolResult(ToolStreamingText){ .content = &content }) catch {
        return server.sendError(id, .InternalError, "Failed to serialize markdown content");
    };
}

fn handleLinks(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const args = try parseArgsOrDefault(UrlParams, arena, arguments, server, id);
    const frame = try ensurePage(server, id, args.url, args.timeout, args.waitUntil);

    const content = [_]protocol.TextContent(ToolStreamingText){.{
        .text = .{ .frame = frame, .action = .links },
    }};
    server.sendResult(id, protocol.CallToolResult(ToolStreamingText){ .content = &content }) catch {
        return server.sendError(id, .InternalError, "Failed to serialize links content");
    };
}

fn handleExtract(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const ExtractParams = struct {
        schema: std.json.Value,
        maxNodes: ?usize = null,
        maxBytes: ?usize = null,
        maxDepth: ?usize = null,
    };
    const args = try parseArgs(ExtractParams, arena, arguments, server, id, "extract");
    const frame = try ensurePage(server, id, null, null, null);

    const result = @import("../../core/semantic/Extractor.zig").extract(arena, frame, args.schema, .{
        .max_nodes = args.maxNodes orelse 10_000,
        .max_bytes = args.maxBytes orelse 4 * 1024 * 1024,
        .max_depth = args.maxDepth orelse 16,
    }) catch |err| {
        return switch (err) {
            error.InvalidSchema, error.InvalidSelector => server.sendError(id, .InvalidParams, "Invalid extraction schema or selector"),
            error.MissingRequiredField => server.sendError(id, .NotFound, "A required extraction field was not found"),
            error.NodeLimitExceeded, error.OutputLimitExceeded, error.MaxDepthExceeded => server.sendError(id, .InvalidParams, "Extraction limit exceeded"),
            error.StaleDocument => server.sendError(id, .InternalError, "Document changed during extraction"),
            else => server.sendError(id, .InternalError, "Structured extraction failed"),
        };
    };

    const json = try std.json.Stringify.valueAlloc(arena, result, .{});
    const content = [_]protocol.TextContent([]const u8){.{ .text = json }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
    _ = try server.action_journal.append(.extract, "extract", arguments, true);
}

fn handleSemanticTree(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const TreeParams = struct {
        url: ?[:0]const u8 = null,
        backendNodeId: ?u32 = null,
        maxDepth: ?u32 = null,
        timeout: ?u32 = null,
        waitUntil: ?@import("../../runtime/Config.zig").WaitUntil = null,
    };
    const args = try parseArgsOrDefault(TreeParams, arena, arguments, server, id);
    const frame = try ensurePage(server, id, args.url, args.timeout, args.waitUntil);

    const content = [_]protocol.TextContent(ToolStreamingText){.{
        .text = .{
            .frame = frame,
            .action = .semantic_tree,
            .registry = &server.node_registry,
            .arena = arena,
            .backendNodeId = args.backendNodeId,
            .maxDepth = args.maxDepth,
        },
    }};
    server.sendResult(id, protocol.CallToolResult(ToolStreamingText){ .content = &content }) catch {
        return server.sendError(id, .InternalError, "Failed to serialize semantic tree content");
    };
}

fn handleNodeDetails(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const Params = struct {
        backendNodeId: CDPNode.Id,
    };
    const args = try parseArgs(Params, arena, arguments, server, id, "nodeDetails");
    const resolved = try resolveNodeAndPage(server, id, args.backendNodeId);

    const details = @import("../../core/semantic/SemanticTree.zig").getNodeDetails(arena, resolved.node, &server.node_registry, resolved.frame) catch {
        return server.sendError(id, .InternalError, "Failed to get node details");
    };

    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(&details, .{}, &aw.writer);

    const content = [_]protocol.TextContent([]const u8){.{ .text = aw.written() }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleInteractiveElements(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const args = try parseArgsOrDefault(UrlParams, arena, arguments, server, id);
    const frame = try ensurePage(server, id, args.url, args.timeout, args.waitUntil);

    const elements = @import("../../core/browser/interactive.zig").collectInteractiveElements(frame.document.asNode(), arena, frame) catch |err| {
        log.err(.mcp, "elements collection failed", .{ .err = err });
        return server.sendError(id, .InternalError, "Failed to collect interactive elements");
    };

    @import("../../core/browser/interactive.zig").registerNodes(elements, &server.node_registry) catch |err| {
        log.err(.mcp, "node registration failed", .{ .err = err });
        return server.sendError(id, .InternalError, "Failed to register element nodes");
    };

    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(elements, .{}, &aw.writer);

    const content = [_]protocol.TextContent([]const u8){.{ .text = aw.written() }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleStructuredData(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const args = try parseArgsOrDefault(UrlParams, arena, arguments, server, id);
    const frame = try ensurePage(server, id, args.url, args.timeout, args.waitUntil);

    const data = @import("../../core/browser/structured_data.zig").collectStructuredData(frame.document.asNode(), arena, frame) catch |err| {
        log.err(.mcp, "struct data collection failed", .{ .err = err });
        return server.sendError(id, .InternalError, "Failed to collect structured data");
    };
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(data, .{}, &aw.writer);

    const content = [_]protocol.TextContent([]const u8){.{ .text = aw.written() }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleDetectForms(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const args = try parseArgsOrDefault(UrlParams, arena, arguments, server, id);
    const frame = try ensurePage(server, id, args.url, args.timeout, args.waitUntil);

    const forms_data = @import("../../core/browser/forms.zig").collectForms(arena, frame.document.asNode(), frame) catch |err| {
        log.err(.mcp, "form collection failed", .{ .err = err });
        return server.sendError(id, .InternalError, "Failed to collect forms");
    };

    @import("../../core/browser/forms.zig").registerNodes(forms_data, &server.node_registry) catch |err| {
        log.err(.mcp, "form node registration failed", .{ .err = err });
        return server.sendError(id, .InternalError, "Failed to register form nodes");
    };

    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(forms_data, .{}, &aw.writer);

    const content = [_]protocol.TextContent([]const u8){.{ .text = aw.written() }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleEvaluate(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const args = try parseArgs(EvaluateParams, arena, arguments, server, id, "evaluate");
    const frame = try ensurePage(server, id, args.url, args.timeout, args.waitUntil);

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const js_result = ls.local.compileAndRun(args.script, null) catch |err| {
        const caught = try_catch.caughtOrError(arena, err);
        var aw: std.Io.Writer.Allocating = .init(arena);
        try caught.format(&aw.writer);

        const content = [_]protocol.TextContent([]const u8){.{ .text = aw.written() }};
        return server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content, .isError = true });
    };

    const str_result = js_result.toStringSliceWithAlloc(arena) catch "undefined";

    const content = [_]protocol.TextContent([]const u8){.{ .text = str_result }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleClick(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const ClickParams = struct {
        backendNodeId: CDPNode.Id,
    };
    const args = try parseArgs(ClickParams, arena, arguments, server, id, "click");
    const resolved = try resolveNodeAndPage(server, id, args.backendNodeId);

    @import("../../core/browser/actions.zig").click(resolved.node, resolved.frame) catch |err| {
        if (err == error.InvalidNodeType) {
            return server.sendError(id, .InvalidParams, "Node is not an HTML element");
        }
        return server.sendError(id, .InternalError, "Failed to click element");
    };

    const page_title = resolved.frame.getTitle() catch null;
    const result_text = try std.fmt.allocPrint(arena, "Clicked element (backendNodeId: {d}). Page url: {s}, title: {s}", .{
        args.backendNodeId,
        resolved.frame.url,
        page_title orelse "(none)",
    });
    const content = [_]protocol.TextContent([]const u8){.{ .text = result_text }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleFill(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const FillParams = struct {
        backendNodeId: CDPNode.Id,
        text: []const u8,
    };
    const args = try parseArgs(FillParams, arena, arguments, server, id, "fill");
    const resolved = try resolveNodeAndPage(server, id, args.backendNodeId);

    @import("../../core/browser/actions.zig").fill(resolved.node, args.text, resolved.frame) catch |err| {
        if (err == error.InvalidNodeType) {
            return server.sendError(id, .InvalidParams, "Node is not an input, textarea or select");
        }
        return server.sendError(id, .InternalError, "Failed to fill element");
    };

    const page_title = resolved.frame.getTitle() catch null;
    const result_text = try std.fmt.allocPrint(arena, "Filled element (backendNodeId: {d}) with \"{s}\". Page url: {s}, title: {s}", .{
        args.backendNodeId,
        args.text,
        resolved.frame.url,
        page_title orelse "(none)",
    });
    const content = [_]protocol.TextContent([]const u8){.{ .text = result_text }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleScroll(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const ScrollParams = struct {
        backendNodeId: ?CDPNode.Id = null,
        x: ?i32 = null,
        y: ?i32 = null,
    };
    const args = try parseArgs(ScrollParams, arena, arguments, server, id, "scroll");

    const frame = server.session.currentFrame() orelse {
        return server.sendError(id, .FrameNotLoaded, "Frame not loaded");
    };

    var target_node: ?*DOMNode = null;
    if (args.backendNodeId) |node_id| {
        const node = server.node_registry.lookup_by_id.get(node_id) orelse {
            return server.sendError(id, .InvalidParams, "Node not found");
        };
        target_node = node.dom;
    }

    @import("../../core/browser/actions.zig").scroll(target_node, args.x, args.y, frame) catch |err| {
        if (err == error.InvalidNodeType) {
            return server.sendError(id, .InvalidParams, "Node is not an element");
        }
        return server.sendError(id, .InternalError, "Failed to scroll");
    };

    const page_title = frame.getTitle() catch null;
    const result_text = try std.fmt.allocPrint(arena, "Scrolled to x: {d}, y: {d}. Page url: {s}, title: {s}", .{
        args.x orelse 0,
        args.y orelse 0,
        frame.url,
        page_title orelse "(none)",
    });
    const content = [_]protocol.TextContent([]const u8){.{ .text = result_text }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleWaitForSelector(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const WaitParams = struct {
        selector: [:0]const u8,
        timeout: ?u32 = null,
    };
    const args = try parseArgs(WaitParams, arena, arguments, server, id, "waitForSelector");

    _ = server.session.currentFrame() orelse {
        return server.sendError(id, .FrameNotLoaded, "Frame not loaded");
    };

    const timeout_ms = args.timeout orelse 5000;

    const node = @import("../../core/browser/actions.zig").waitForSelector(args.selector, timeout_ms, server.session) catch |err| {
        if (err == error.InvalidSelector) {
            return server.sendError(id, .InvalidParams, "Invalid selector");
        } else if (err == error.Timeout) {
            return server.sendError(id, .InternalError, "Timeout waiting for selector");
        }
        return server.sendError(id, .InternalError, "Failed waiting for selector");
    };

    const registered = try server.node_registry.register(node);
    const msg = std.fmt.allocPrint(arena, "Element found. backendNodeId: {d}", .{registered.id}) catch "Element found.";

    const content = [_]protocol.TextContent([]const u8){.{ .text = msg }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
    _ = try server.action_journal.append(.wait_for_selector, "waitForSelector", arguments, true);
}

fn handleRecordingStart(server: *Server, id: std.json.Value) !void {
    server.action_journal.start();
    const content = [_]protocol.TextContent([]const u8){.{ .text = "Recording started." }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleRecordingStop(server: *Server, arena: std.mem.Allocator, id: std.json.Value) !void {
    server.action_journal.stop();
    const json = try server.action_journal.jsonAlloc(arena);
    const content = [_]protocol.TextContent([]const u8){.{ .text = json }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleWorkflowExport(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const Params = struct {
        format: enum { json, javascript } = .json,
    };
    const args = try parseArgsOrDefault(Params, arena, arguments, server, id);
    const output = switch (args.format) {
        .json => try server.action_journal.jsonAlloc(arena),
        .javascript => try server.action_journal.javascriptAlloc(arena),
    };
    const content = [_]protocol.TextContent([]const u8){.{ .text = output }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleWorkflowReplay(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const Params = struct { workflow: std.json.Value };
    const args = try parseArgs(Params, arena, arguments, server, id, "workflowReplay");
    const raw = try std.json.Stringify.valueAlloc(arena, args.workflow, .{});

    const Executor = struct {
        server: *Server,
        arena: std.mem.Allocator,
        id: std.json.Value,

        pub fn execute(self: *@This(), action: ToolRegistry.Action, value: std.json.Value) !void {
            switch (action) {
                .goto => {
                    const step_args = std.json.parseFromValueLeaky(GotoParams, self.arena, value, .{
                        .ignore_unknown_fields = true,
                    }) catch return error.InvalidWorkflow;
                    try performGoto(self.server, step_args.url, self.id, step_args.timeout, step_args.waitUntil);
                },
                .extract => {
                    const ExtractStepParams = struct {
                        schema: std.json.Value,
                        maxNodes: ?usize = null,
                        maxBytes: ?usize = null,
                        maxDepth: ?usize = null,
                    };
                    const step_args = std.json.parseFromValueLeaky(ExtractStepParams, self.arena, value, .{
                        .ignore_unknown_fields = true,
                    }) catch return error.InvalidWorkflow;
                    const frame = self.server.session.currentFrame() orelse return error.FrameNotLoaded;
                    _ = try @import("../../core/semantic/Extractor.zig").extract(self.arena, frame, step_args.schema, .{
                        .max_nodes = step_args.maxNodes orelse 10_000,
                        .max_bytes = step_args.maxBytes orelse 4 * 1024 * 1024,
                        .max_depth = step_args.maxDepth orelse 16,
                    });
                },
                .wait_for_selector => {
                    const WaitStepParams = struct {
                        selector: [:0]const u8,
                        timeout: ?u32 = null,
                    };
                    const step_args = std.json.parseFromValueLeaky(WaitStepParams, self.arena, value, .{
                        .ignore_unknown_fields = true,
                    }) catch return error.InvalidWorkflow;
                    _ = self.server.session.currentFrame() orelse return error.FrameNotLoaded;
                    _ = try @import("../../core/browser/actions.zig").waitForSelector(
                        step_args.selector,
                        step_args.timeout orelse 5000,
                        self.server.session,
                    );
                },
                else => return error.NonReplayableTool,
            }
        }
    };

    var executor: Executor = .{ .server = server, .arena = arena, .id = id };
    @import("../automation/WorkflowRunner.zig").replay(arena, raw, &executor) catch |err| {
        return switch (err) {
            error.UnsupportedVersion => server.sendError(id, .InvalidParams, "Unsupported workflow version"),
            error.InvalidWorkflow, error.UnknownTool, error.NonReplayableTool => server.sendError(id, .InvalidParams, "Invalid or non-replayable workflow"),
            else => server.sendError(id, .InternalError, "Workflow replay failed"),
        };
    };

    const content = [_]protocol.TextContent([]const u8){.{ .text = "Workflow replayed successfully." }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleHover(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const Params = struct {
        backendNodeId: CDPNode.Id,
    };
    const args = try parseArgs(Params, arena, arguments, server, id, "hover");
    const resolved = try resolveNodeAndPage(server, id, args.backendNodeId);

    @import("../../core/browser/actions.zig").hover(resolved.node, resolved.frame) catch |err| {
        if (err == error.InvalidNodeType) {
            return server.sendError(id, .InvalidParams, "Node is not an HTML element");
        }
        return server.sendError(id, .InternalError, "Failed to hover element");
    };

    const page_title = resolved.frame.getTitle() catch null;
    const result_text = try std.fmt.allocPrint(arena, "Hovered element (backendNodeId: {d}). Page url: {s}, title: {s}", .{
        args.backendNodeId,
        resolved.frame.url,
        page_title orelse "(none)",
    });
    const content = [_]protocol.TextContent([]const u8){.{ .text = result_text }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handlePress(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const Params = struct {
        key: []const u8,
        backendNodeId: ?CDPNode.Id = null,
    };
    const args = try parseArgs(Params, arena, arguments, server, id, "press");

    const frame = server.session.currentFrame() orelse {
        return server.sendError(id, .FrameNotLoaded, "Frame not loaded");
    };

    var target_node: ?*DOMNode = null;
    if (args.backendNodeId) |node_id| {
        const node = server.node_registry.lookup_by_id.get(node_id) orelse {
            return server.sendError(id, .InvalidParams, "Node not found");
        };
        target_node = node.dom;
    }

    @import("../../core/browser/actions.zig").press(target_node, args.key, frame) catch |err| {
        if (err == error.InvalidNodeType) {
            return server.sendError(id, .InvalidParams, "Node is not an HTML element");
        }
        return server.sendError(id, .InternalError, "Failed to press key");
    };

    const page_title = frame.getTitle() catch null;
    const result_text = try std.fmt.allocPrint(arena, "Pressed key '{s}'. Page url: {s}, title: {s}", .{
        args.key,
        frame.url,
        page_title orelse "(none)",
    });
    const content = [_]protocol.TextContent([]const u8){.{ .text = result_text }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleSelectOption(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const Params = struct {
        backendNodeId: CDPNode.Id,
        value: []const u8,
    };
    const args = try parseArgs(Params, arena, arguments, server, id, "selectOption");
    const resolved = try resolveNodeAndPage(server, id, args.backendNodeId);

    @import("../../core/browser/actions.zig").selectOption(resolved.node, args.value, resolved.frame) catch |err| {
        if (err == error.InvalidNodeType) {
            return server.sendError(id, .InvalidParams, "Node is not a <select> element");
        }
        return server.sendError(id, .InternalError, "Failed to select option");
    };

    const page_title = resolved.frame.getTitle() catch null;
    const result_text = try std.fmt.allocPrint(arena, "Selected option '{s}' (backendNodeId: {d}). Page url: {s}, title: {s}", .{
        args.value,
        args.backendNodeId,
        resolved.frame.url,
        page_title orelse "(none)",
    });
    const content = [_]protocol.TextContent([]const u8){.{ .text = result_text }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleSetChecked(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const Params = struct {
        backendNodeId: CDPNode.Id,
        checked: bool,
    };
    const args = try parseArgs(Params, arena, arguments, server, id, "setChecked");
    const resolved = try resolveNodeAndPage(server, id, args.backendNodeId);

    @import("../../core/browser/actions.zig").setChecked(resolved.node, args.checked, resolved.frame) catch |err| {
        if (err == error.InvalidNodeType) {
            return server.sendError(id, .InvalidParams, "Node is not a checkbox or radio input");
        }
        return server.sendError(id, .InternalError, "Failed to set checked state");
    };

    const state_str = if (args.checked) "checked" else "unchecked";
    const page_title = resolved.frame.getTitle() catch null;
    const result_text = try std.fmt.allocPrint(arena, "Set element (backendNodeId: {d}) to {s}. Page url: {s}, title: {s}", .{
        args.backendNodeId,
        state_str,
        resolved.frame.url,
        page_title orelse "(none)",
    });
    const content = [_]protocol.TextContent([]const u8){.{ .text = result_text }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleFindElement(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const Params = struct {
        role: ?[]const u8 = null,
        name: ?[]const u8 = null,
    };
    const args = try parseArgsOrDefault(Params, arena, arguments, server, id);

    if (args.role == null and args.name == null) {
        return server.sendError(id, .InvalidParams, "At least one of 'role' or 'name' must be provided");
    }

    const frame = server.session.currentFrame() orelse {
        return server.sendError(id, .FrameNotLoaded, "Frame not loaded");
    };

    const elements = @import("../../core/browser/interactive.zig").collectInteractiveElements(frame.document.asNode(), arena, frame) catch |err| {
        log.err(.mcp, "elements collection failed", .{ .err = err });
        return server.sendError(id, .InternalError, "Failed to collect interactive elements");
    };

    var matches: std.ArrayList(@import("../../core/browser/interactive.zig").InteractiveElement) = .empty;
    for (elements) |el| {
        if (args.role) |role| {
            const el_role = el.role orelse continue;
            if (!std.ascii.eqlIgnoreCase(el_role, role)) continue;
        }
        if (args.name) |name| {
            const el_name = el.name orelse continue;
            if (!containsIgnoreCase(el_name, name)) continue;
        }
        try matches.append(arena, el);
    }

    const matched = try matches.toOwnedSlice(arena);
    @import("../../core/browser/interactive.zig").registerNodes(matched, &server.node_registry) catch |err| {
        log.err(.mcp, "node registration failed", .{ .err = err });
        return server.sendError(id, .InternalError, "Failed to register element nodes");
    };

    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(matched, .{}, &aw.writer);

    const content = [_]protocol.TextContent([]const u8){.{ .text = aw.written() }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    if (needle.len == 0) return true;
    const end = haystack.len - needle.len + 1;
    for (0..end) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

const NodeAndPage = struct { node: *DOMNode, frame: *@import("../../core/browser/Frame.zig") };

fn resolveNodeAndPage(server: *Server, id: std.json.Value, node_id: CDPNode.Id) !NodeAndPage {
    const frame = server.session.currentFrame() orelse {
        try server.sendError(id, .FrameNotLoaded, "Frame not loaded");
        return error.FrameNotLoaded;
    };
    const node = server.node_registry.lookup_by_id.get(node_id) orelse {
        try server.sendError(id, .InvalidParams, "Node not found");
        return error.InvalidParams;
    };
    return .{ .node = node.dom, .frame = frame };
}

fn ensurePage(server: *Server, id: std.json.Value, url: ?[:0]const u8, timeout: ?u32, waitUntil: ?@import("../../runtime/Config.zig").WaitUntil) !*@import("../../core/browser/Frame.zig") {
    if (url) |u| {
        try performGoto(server, u, id, timeout, waitUntil);
    }
    return server.session.currentFrame() orelse {
        try server.sendError(id, .FrameNotLoaded, "Frame not loaded");
        return error.FrameNotLoaded;
    };
}

/// Parses JSON arguments into a given struct type `T`.
/// If the arguments are missing, it returns a default-initialized `T` (e.g., `.{}`).
/// If the arguments are present but invalid, it sends an MCP error response and returns `error.InvalidParams`.
/// Use this for tools where all arguments are optional.
fn parseArgsOrDefault(comptime T: type, arena: std.mem.Allocator, arguments: ?std.json.Value, server: *Server, id: std.json.Value) !T {
    const args_raw = arguments orelse return .{};
    return std.json.parseFromValueLeaky(T, arena, args_raw, .{ .ignore_unknown_fields = true }) catch {
        try server.sendError(id, .InvalidParams, "Invalid arguments");
        return error.InvalidParams;
    };
}

/// Parses JSON arguments into a given struct type `T`.
/// If the arguments are missing or invalid, it automatically sends an MCP error response to the client
/// and returns an `error.InvalidParams`.
/// Use this for tools that require strict validation or mandatory arguments.
fn parseArgs(comptime T: type, arena: std.mem.Allocator, arguments: ?std.json.Value, server: *Server, id: std.json.Value, tool_name: []const u8) !T {
    const args_raw = arguments orelse {
        try server.sendError(id, .InvalidParams, "Missing arguments");
        return error.InvalidParams;
    };
    return std.json.parseFromValueLeaky(T, arena, args_raw, .{ .ignore_unknown_fields = true }) catch {
        const msg = std.fmt.allocPrint(arena, "Invalid arguments for {s}", .{tool_name}) catch "Invalid arguments";
        try server.sendError(id, .InvalidParams, msg);
        return error.InvalidParams;
    };
}

fn performGoto(server: *Server, url: [:0]const u8, id: std.json.Value, timeout: ?u32, waitUntil: ?@import("../../runtime/Config.zig").WaitUntil) !void {
    const session = server.session;
    if (session.hasPage()) {
        session.removePage();
    }
    const frame = session.createPage() catch {
        try server.sendError(id, .InternalError, "Failed to create page");
        return error.NavigationFailed;
    };
    frame.navigate(url, .{
        .reason = .address_bar,
        .kind = .{ .push = null },
    }) catch {
        try server.sendError(id, .InternalError, "Internal error during navigation");
        return error.NavigationFailed;
    };

    var runner = session.runner(.{}) catch {
        try server.sendError(id, .InternalError, "Failed to start page runner");
        return error.NavigationFailed;
    };
    runner.wait(.{
        .ms = timeout orelse 10000,
        .until = waitUntil orelse .done,
    }) catch {
        try server.sendError(id, .InternalError, "Error waiting for page load");
        return error.NavigationFailed;
    };
}

const router = @import("router.zig");
const testing = @import("../../testing/testing.zig");

test "MCP - evaluate error reporting" {
    defer testing.reset();
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    // Call evaluate with a script that throws an error
    const msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": {
        \\      "script": "throw new Error('test error')"
        \\    }
        \\  }
        \\}
    ;

    try router.handleMessage(server, testing.arena_allocator, msg);

    try testing.expectJson(.{ .id = 1, .result = .{
        .isError = true,
        .content = &.{.{ .type = "text" }},
    } }, out.written());
}

test "MCP - native structured extract" {
    defer testing.reset();
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage(
        "http://localhost:9582/src/browser/tests/mcp_extract.html",
        &out.writer,
    );
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"extract","arguments":{"schema":{"products":{"selector":".product","all":true,"fields":{"name":{"selector":"h2","text":true},"sku":{"attribute":"data-sku"}}}}}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);

    try testing.expect(std.mem.indexOf(u8, out.written(), "\\\"name\\\":\\\"Alpha\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\\\"sku\\\":\\\"b-2\\\"") != null);
}

test "MCP - action recording exports only successful replayable operations" {
    defer testing.reset();
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage(
        "http://localhost:9582/src/browser/tests/mcp_extract.html",
        &out.writer,
    );
    defer server.deinit();
    out.clearRetainingCapacity();

    try router.handleMessage(server, testing.arena_allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"recordingStart","arguments":{}}}
    );
    out.clearRetainingCapacity();

    try router.handleMessage(server, testing.arena_allocator,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"extract","arguments":{"schema":{"title":{"selector":"h1","text":true}}}}}
    );
    out.clearRetainingCapacity();

    // This fails deterministically and therefore must not enter the journal.
    try router.handleMessage(server, testing.arena_allocator,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"extract","arguments":{"schema":{"missing":{"selector":".absent","text":true,"required":true}}}}}
    );
    out.clearRetainingCapacity();

    try router.handleMessage(server, testing.arena_allocator,
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"recordingStop","arguments":{}}}
    );

    try testing.expect(std.mem.indexOf(u8, out.written(), "\\\"version\\\":1") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\\\"tool\\\":\\\"extract\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), ".absent") == null);
}

test "MCP - deterministic workflow replay runs without a model" {
    defer testing.reset();
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try Server.init(testing.allocator, testing.test_app, &out.writer);
    defer server.deinit();

    try router.handleMessage(server, testing.arena_allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"workflowReplay","arguments":{"workflow":{"version":1,"steps":[{"tool":"goto","arguments":{"url":"http://localhost:9582/src/browser/tests/mcp_extract.html"}},{"tool":"waitForSelector","arguments":{"selector":".product","timeout":1000}},{"tool":"extract","arguments":{"schema":{"title":{"selector":"h1","text":true}}}}]}}}}
    );

    try testing.expect(std.mem.indexOf(u8, out.written(), "Workflow replayed successfully.") != null);
    try testing.expect(server.session.currentFrame() != null);
}

test "MCP - Actions: click, fill, scroll, hover, press, selectOption, setChecked" {
    defer testing.reset();
    const aa = testing.arena_allocator;

    var out: std.Io.Writer.Allocating = .init(aa);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();

    const frame = server.session.currentFrame().?;

    {
        // Test Click
        const btn = frame.document.getElementById("btn", frame).?.asNode();
        const btn_id = (try server.node_registry.register(btn)).id;
        var btn_id_buf: [12]u8 = undefined;
        const btn_id_str = std.fmt.bufPrint(&btn_id_buf, "{d}", .{btn_id}) catch unreachable;
        const click_msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"click\",\"arguments\":{\"backendNodeId\":", btn_id_str, "}}}" });
        try router.handleMessage(server, aa, click_msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Clicked element") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Page url: http://localhost:9582/src/browser/tests/mcp_actions.html") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test Fill Input
        const inp = frame.document.getElementById("inp", frame).?.asNode();
        const inp_id = (try server.node_registry.register(inp)).id;
        var inp_id_buf: [12]u8 = undefined;
        const inp_id_str = std.fmt.bufPrint(&inp_id_buf, "{d}", .{inp_id}) catch unreachable;
        const fill_msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"fill\",\"arguments\":{\"backendNodeId\":", inp_id_str, ",\"text\":\"hello\"}}}" });
        try router.handleMessage(server, aa, fill_msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Filled element") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "with \\\"hello\\\"") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test Fill Select
        const sel = frame.document.getElementById("sel", frame).?.asNode();
        const sel_id = (try server.node_registry.register(sel)).id;
        var sel_id_buf: [12]u8 = undefined;
        const sel_id_str = std.fmt.bufPrint(&sel_id_buf, "{d}", .{sel_id}) catch unreachable;
        const fill_sel_msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"fill\",\"arguments\":{\"backendNodeId\":", sel_id_str, ",\"text\":\"opt2\"}}}" });
        try router.handleMessage(server, aa, fill_sel_msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Filled element") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "with \\\"opt2\\\"") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test Scroll
        const scrollbox = frame.document.getElementById("scrollbox", frame).?.asNode();
        const scrollbox_id = (try server.node_registry.register(scrollbox)).id;
        var scroll_id_buf: [12]u8 = undefined;
        const scroll_id_str = std.fmt.bufPrint(&scroll_id_buf, "{d}", .{scrollbox_id}) catch unreachable;
        const scroll_msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"scroll\",\"arguments\":{\"backendNodeId\":", scroll_id_str, ",\"y\":50}}}" });
        try router.handleMessage(server, aa, scroll_msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Scrolled to x: 0, y: 50") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test Hover
        const el = frame.document.getElementById("hoverTarget", frame).?.asNode();
        const el_id = (try server.node_registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"hover\",\"arguments\":{\"backendNodeId\":", id_str, "}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Hovered element") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test Press
        const el = frame.document.getElementById("keyTarget", frame).?.asNode();
        const el_id = (try server.node_registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"press\",\"arguments\":{\"key\":\"Enter\",\"backendNodeId\":", id_str, "}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Pressed key") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test SelectOption
        const el = frame.document.getElementById("sel2", frame).?.asNode();
        const el_id = (try server.node_registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"selectOption\",\"arguments\":{\"backendNodeId\":", id_str, ",\"value\":\"b\"}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Selected option") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test SetChecked (checkbox)
        const el = frame.document.getElementById("chk", frame).?.asNode();
        const el_id = (try server.node_registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"setChecked\",\"arguments\":{\"backendNodeId\":", id_str, ",\"checked\":true}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "checked") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test SetChecked (radio)
        const el = frame.document.getElementById("rad", frame).?.asNode();
        const el_id = (try server.node_registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"setChecked\",\"arguments\":{\"backendNodeId\":", id_str, ",\"checked\":true}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "checked") != null);
        out.clearRetainingCapacity();
    }

    // Evaluate JS assertions for all actions
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const result = try ls.local.exec(
        \\ window.clicked === true && window.inputVal === 'hello' &&
        \\ window.selChanged === 'opt2' &&
        \\ window.scrolled === true &&
        \\ window.hovered === true &&
        \\ window.keyPressed === 'Enter' && window.keyReleased === 'Enter' &&
        \\ window.sel2Changed === 'b' &&
        \\ window.chkClicked === true && window.chkChanged === true &&
        \\ window.radClicked === true && window.radChanged === true
    , null);

    try testing.expect(result.isTrue());
}

test "MCP - findElement" {
    defer testing.reset();
    const aa = testing.arena_allocator;

    var out: std.Io.Writer.Allocating = .init(aa);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();

    {
        // Find by role
        const msg =
            \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"findElement","arguments":{"role":"button"}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Click Me") != null);
        out.clearRetainingCapacity();
    }

    {
        // Find by name (case-insensitive substring)
        const msg =
            \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"findElement","arguments":{"name":"click"}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Click Me") != null);
        out.clearRetainingCapacity();
    }

    {
        // Find with no matches
        const msg =
            \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"findElement","arguments":{"role":"slider"}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "[]") != null);
        out.clearRetainingCapacity();
    }

    {
        // Error: no params provided
        const msg =
            \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"findElement","arguments":{}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "error") != null);
        out.clearRetainingCapacity();
    }
}

test "MCP - waitForSelector: existing element" {
    defer testing.reset();
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage(
        "http://localhost:9582/src/browser/tests/mcp_wait_for_selector.html",
        &out.writer,
    );
    defer server.deinit();

    // waitForSelector on an element that already exists returns immediately
    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"waitForSelector","arguments":{"selector":"#existing","timeout":2000}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);

    try testing.expectJson(.{ .id = 1, .result = .{ .content = &.{.{ .type = "text" }} } }, out.written());
}

test "MCP - waitForSelector: delayed element" {
    defer testing.reset();
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage(
        "http://localhost:9582/src/browser/tests/mcp_wait_for_selector.html",
        &out.writer,
    );
    defer server.deinit();

    // waitForSelector on an element added after 200ms via setTimeout
    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"waitForSelector","arguments":{"selector":"#delayed","timeout":5000}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);

    try testing.expectJson(.{ .id = 1, .result = .{ .content = &.{.{ .type = "text" }} } }, out.written());
}

test "MCP - waitForSelector: timeout" {
    defer testing.reset();
    var out: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage(
        "http://localhost:9582/src/browser/tests/mcp_wait_for_selector.html",
        &out.writer,
    );
    defer server.deinit();

    // waitForSelector with a short timeout on a non-existent element should error
    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"waitForSelector","arguments":{"selector":"#nonexistent","timeout":100}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expectJson(.{
        .id = 1,
        .@"error" = struct {}{},
    }, out.written());
}

fn testLoadPage(url: [:0]const u8, writer: *std.Io.Writer) !*Server {
    var server = try Server.init(testing.allocator, testing.test_app, writer);
    errdefer server.deinit();

    const frame = try server.session.createPage();
    try frame.navigate(url, .{});

    var runner = try server.session.runner(.{});
    try runner.wait(.{ .ms = 2000 });
    return server;
}
