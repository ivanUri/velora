//! Optional local observability sink for completed HTTP transfers.
//! The network layer owns the measurements; consumers only receive immutable
//! JSONL snapshots after CURLMSG_DONE and before the pooled handle is reset.

const std = @import("std");
const sync = @import("../../support/sync.zig");
const builtin = @import("builtin");
const http = @import("http.zig");
const datetime = @import("../../support/datetime.zig");
const runtime_io = @import("../../support/io.zig");

const Self = @This();

// Site export needs the complete text document, not only a small telemetry
// preview. Keep a bounded limit so a pathological response cannot turn the
// telemetry stream into an unbounded memory sink.
const MAX_CAPTURE_BYTES: usize = 4 * 1024 * 1024;

pub const ResponseMetadata = struct {
    method: []const u8,
    resource_type: []const u8,
    request_id: u32,
    frame_id: u32,
    loader_id: u32,
    redirect_count: u32,
    content_type: ?[]const u8,
};

const JourneyStage = struct {
    id: []const u8,
    measurement: []const u8 = "not-applicable-replay",
};

const replay_stages = [_]JourneyStage{
    .{ .id = "queue" },
    .{ .id = "cache" },
    .{ .id = "dns" },
    .{ .id = "routing" },
    .{ .id = "proxy" },
    .{ .id = "tcp" },
    .{ .id = "tls" },
    .{ .id = "request" },
    .{ .id = "redirect" },
    .{ .id = "server" },
    .{ .id = "response" },
    .{ .id = "received", .measurement = "boundary" },
};

// A browser process may own multiple Network instances. They can share the
// same observability file, so serialization must live at module/process scope
// rather than on an individual sink.
var process_mutex: sync.Mutex = .{};
var process_sequence: u64 = 0;
var previous_cpu_sample: ?ProcessSample = null;
var latest_cpu_sample: ?CpuSample = null;

allocator: std.mem.Allocator,
file: std.Io.File,
session_id: []u8,
capture_bodies: bool,
checkpoint_enabled: bool,
replay_enabled: bool,

pub fn init(allocator: std.mem.Allocator, path: ?[]const u8, capture_bodies: bool, checkpoint_enabled: bool, replay_enabled: bool) !?Self {
    const output_path = path orelse return null;

    const io = runtime_io.get();
    const file = std.Io.Dir.cwd().openFile(io, output_path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => try std.Io.Dir.cwd().createFile(io, output_path, .{ .truncate = false }),
        else => return err,
    };
    errdefer file.close(io);
    if (std.c.lseek(file.handle, 0, std.c.SEEK.END) < 0) return error.Unexpected;
    const session_id = try std.fmt.allocPrint(allocator, "koko-{d}-{d}", .{ std.c.getpid(), datetime.nanoTimestamp(.monotonic) });
    errdefer allocator.free(session_id);
    return .{
        .allocator = allocator,
        .file = file,
        .session_id = session_id,
        .capture_bodies = capture_bodies,
        .checkpoint_enabled = checkpoint_enabled,
        .replay_enabled = replay_enabled,
    };
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.session_id);
    self.file.close(runtime_io.get());
}

fn append(self: *Self, bytes: []const u8) !void {
    const io = runtime_io.get();
    if (std.c.lseek(self.file.handle, 0, std.c.SEEK.END) < 0) return error.Unexpected;
    try self.file.writeStreamingAll(io, bytes);
}

pub fn emit(
    self: *Self,
    conn: *const http.Connection,
    timing: http.Connection.TransferTiming,
    metadata: ResponseMetadata,
    failed: bool,
    request_headers: http.Headers,
    response_headers: *http.HeaderIterator,
    request_body: ?[]const u8,
    response_body: []const u8,
) !void {
    process_mutex.lock();
    defer process_mutex.unlock();

    const url = if (conn.getEffectiveUrl() catch null) |url_ptr|
        std.mem.span(url_ptr)
    else
        "";
    const response_code = conn.getResponseCode() catch 0;
    const now = datetime.milliTimestamp(.clock);
    const content_encoding = headerValue(conn, "content-encoding");
    const cache_control = headerValue(conn, "cache-control");
    const server = headerValue(conn, "server");
    const age = headerValue(conn, "age");
    const via = headerValue(conn, "via");
    const etag = headerValue(conn, "etag");
    const content_length = headerValue(conn, "content-length");
    const compressed_size = if (content_length) |value| std.fmt.parseInt(u64, std.mem.trim(u8, value, " \t\r\n"), 10) catch null else null;

    var request_header_output: std.Io.Writer.Allocating = .init(self.allocator);
    defer request_header_output.deinit();
    var request_header_iterator = request_headers.iterator();
    try writeSafeHeaders(&request_header_output.writer, &request_header_iterator);

    var response_header_output: std.Io.Writer.Allocating = .init(self.allocator);
    defer response_header_output.deinit();
    try writeSafeHeaders(&response_header_output.writer, response_headers);

    const response_capture = if (self.capture_bodies) captureBody(response_body, content_encoding, metadata.content_type) else "";
    const request_capture = if (self.capture_bodies) captureBody(request_body orelse "", null, null) else "";

    const Stage = struct { id: []const u8, duration_us: u64, measurement: []const u8 = "measured" };
    const connection_reused = timing.num_connects == 0 and timing.connection_id >= 0;
    // libcurl does not expose a reliable memory/disk/service-worker cache
    // source. Only a 304 response is directly observable; do not imply that
    // every other transfer bypassed all browser caches.
    const cache_decision = if (response_code == 304) "revalidated" else "not-observed";
    const stages = [_]Stage{
        .{ .id = "queue", .duration_us = timing.queue_us },
        .{ .id = "cache", .duration_us = 0, .measurement = "not-timed" },
        .{ .id = "dns", .duration_us = timing.dns_us },
        .{ .id = "routing", .duration_us = 0, .measurement = "unavailable" },
        .{ .id = "proxy", .duration_us = 0, .measurement = if (timing.used_proxy) "not-timed" else "unavailable" },
        .{ .id = "tcp", .duration_us = timing.tcp_us },
        .{ .id = "tls", .duration_us = timing.tls_us },
        .{ .id = "request", .duration_us = timing.request_us },
        .{ .id = "redirect", .duration_us = 0, .measurement = if (metadata.redirect_count > 0) "not-timed" else "unavailable" },
        .{ .id = "server", .duration_us = timing.server_us },
        .{ .id = "response", .duration_us = timing.transfer_us },
        .{ .id = "received", .duration_us = 0, .measurement = "boundary" },
    };

    // A failed transfer still emits the complete schema, but only the stage
    // where the network invariant broke is marked as the failure point. Later
    // stages are explicitly skipped so consumers cannot render a false
    // successful journey.
    const failed_stage: ?[]const u8 = if (!failed) null else if (timing.dns_us == 0 and timing.primary_ip == null) "dns" else if (timing.tcp_us == 0 and timing.primary_ip != null) "tcp" else if (timing.tls_us == 0 and timing.num_connects > 0) "tls" else if (timing.server_us == 0 and response_code == 0) "server" else "response";
    var failed_index: ?usize = null;
    if (failed_stage) |stage_id| for (stages, 0..) |stage, index| {
        if (std.mem.eql(u8, stage.id, stage_id)) failed_index = index;
    };

    var output: std.Io.Writer.Allocating = .init(self.allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writer.writeByte('[');
    for (stages, 0..) |stage, index| {
        process_sequence += 1;
        if (index > 0) try writer.writeByte(',');
        const event_id = try std.fmt.allocPrint(self.allocator, "{s}:journey-{d}", .{ self.session_id, process_sequence });
        defer self.allocator.free(event_id);
        const stage_status = if (failed_index) |failure_index| blk: {
            if (index == failure_index and std.mem.eql(u8, stage.id, failed_stage.?)) break :blk "error";
            if (index > failure_index) break :blk "skipped";
            break :blk "ok";
        } else "ok";
        try std.json.Stringify.value(.{
            .id = event_id,
            .sessionId = self.session_id,
            .sequence = process_sequence,
            .timestamp = now,
            .duration = @as(f64, @floatFromInt(stage.duration_us)) / 1000.0,
            .kind = "network",
            .name = stage.id,
            .status = stage_status,
            .payload = .{
                .executionId = self.session_id,
                .executionStatus = "recording",
                .executionCapabilities = self.executionCapabilities(),
                .journeyStage = stage.id,
                .failureStage = failed_stage,
                .url = url,
                .resourceType = metadata.resource_type,
                .requestId = metadata.request_id,
                .frameId = metadata.frame_id,
                .loaderId = metadata.loader_id,
                .responseStatus = response_code,
                .responseBodyBytes = timing.response_body_bytes,
                .compressedSizeBytes = compressed_size,
                .uncompressedSizeBytes = timing.response_body_bytes,
                .responseMemoryBytes = timing.response_body_bytes,
                .responseMemoryState = "estimated_from_transfer_size",
                .contentEncoding = content_encoding,
                .primaryIp = timing.primary_ip,
                .connectionId = timing.connection_id,
                .numConnects = timing.num_connects,
                .connectionReused = connection_reused,
                .usedProxy = timing.used_proxy,
                .cacheDecision = cache_decision,
                .httpVersion = conn.httpProtocolLabel(),
                .method = metadata.method,
                .redirectCount = metadata.redirect_count,
                .contentType = metadata.content_type,
                .requestHeaders = if (request_header_output.written().len > 0) request_header_output.written() else null,
                .responseHeaders = if (response_header_output.written().len > 0) response_header_output.written() else null,
                .requestBody = if (request_capture.len > 0) request_capture else null,
                .responseBody = if (response_capture.len > 0 and isTextContent(metadata.content_type, content_encoding)) response_capture else null,
                .bodyCaptureState = if (!self.capture_bodies) "disabled" else if (isTextContent(metadata.content_type, content_encoding)) "captured" else "unsupported-content-type",
                .bodyTruncated = self.capture_bodies and isTextContent(metadata.content_type, content_encoding) and response_body.len > response_capture.len,
                .cacheControl = cache_control,
                .server = server,
                .age = age,
                .via = via,
                .etag = etag,
                .measurement = durationMeasurement(stage.id, stage.duration_us, stage.measurement, connection_reused),
                .terminalStatus = if (failed) "error" else "ok",
            },
        }, .{ .emit_null_optional_fields = false }, writer);
    }
    try writer.writeAll("]\n");
    // Other Network-owned sinks may have advanced the shared file since this
    // handle was opened. Re-resolve EOF while holding the process lock.
    try self.append(output.written());
}

/// Record a response fulfilled locally by the deterministic replay policy.
/// Replay has no DNS/TCP/TLS timings, so those stages are present for the
/// stable telemetry schema but explicitly marked as not applicable.
pub fn emitReplay(
    self: *Self,
    metadata: ResponseMetadata,
    url: []const u8,
    status: u16,
    request_headers: http.Headers,
    response_headers: []const http.Header,
    request_body: ?[]const u8,
    response_body: ?[]const u8,
) !void {
    process_mutex.lock();
    defer process_mutex.unlock();

    var request_header_output: std.Io.Writer.Allocating = .init(self.allocator);
    defer request_header_output.deinit();
    var request_header_iterator = request_headers.iterator();
    try writeSafeHeaders(&request_header_output.writer, &request_header_iterator);

    var response_header_output: std.Io.Writer.Allocating = .init(self.allocator);
    defer response_header_output.deinit();
    var response_header_iterator = http.HeaderIterator{ .list = .{ .list = response_headers } };
    try writeSafeHeaders(&response_header_output.writer, &response_header_iterator);

    const content_type = headerFromList(response_headers, "content-type");
    const response_value = response_body orelse "";
    const response_capture = if (self.capture_bodies) captureBody(response_value, null, content_type) else "";
    const request_capture = if (self.capture_bodies) captureBody(request_body orelse "", null, null) else "";
    const now = datetime.milliTimestamp(.clock);

    var output: std.Io.Writer.Allocating = .init(self.allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writer.writeByte('[');
    for (replay_stages, 0..) |stage, index| {
        process_sequence += 1;
        if (index > 0) try writer.writeByte(',');
        const event_id = try std.fmt.allocPrint(self.allocator, "{s}:replay-{d}", .{ self.session_id, process_sequence });
        defer self.allocator.free(event_id);
        try std.json.Stringify.value(.{
            .id = event_id,
            .sessionId = self.session_id,
            .sequence = process_sequence,
            .timestamp = now,
            .duration = @as(f64, 0),
            .kind = "network",
            .name = stage.id,
            .status = "ok",
            .payload = .{
                .executionId = self.session_id,
                .executionStatus = "replaying",
                .executionCapabilities = self.executionCapabilities(),
                .journeyStage = stage.id,
                .url = url,
                .resourceType = metadata.resource_type,
                .requestId = metadata.request_id,
                .frameId = metadata.frame_id,
                .loaderId = metadata.loader_id,
                .responseStatus = status,
                .responseBodyBytes = response_value.len,
                .uncompressedSizeBytes = response_value.len,
                .responseMemoryBytes = response_value.len,
                .responseMemoryState = "fulfilled_from_replay",
                .connectionReused = false,
                .usedProxy = false,
                .cacheDecision = "execution-replay",
                .httpVersion = "replay",
                .method = metadata.method,
                .redirectCount = metadata.redirect_count,
                .contentType = content_type,
                .requestHeaders = if (request_header_output.written().len > 0) request_header_output.written() else null,
                .responseHeaders = if (response_header_output.written().len > 0) response_header_output.written() else null,
                .requestBody = if (request_capture.len > 0) request_capture else null,
                .responseBody = if (response_capture.len > 0 and isTextContent(content_type, null)) response_capture else null,
                .bodyCaptureState = if (!self.capture_bodies) "disabled" else if (isTextContent(content_type, null)) "captured" else "unsupported-content-type",
                .bodyTruncated = self.capture_bodies and isTextContent(content_type, null) and response_value.len > response_capture.len,
                .measurement = stage.measurement,
                .terminalStatus = "ok",
                .responseSource = "execution-replay",
            },
        }, .{ .emit_null_optional_fields = false }, writer);
    }
    try writer.writeAll("]\n");
    try self.append(output.written());
}

fn headerFromList(headers: []const http.Header, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn writeSafeHeaders(writer: *std.Io.Writer, iterator: *http.HeaderIterator) !void {
    while (iterator.next()) |header| {
        if (isSensitiveHeader(header.name)) continue;
        try writer.print("{s}: {s}\n", .{ header.name, header.value });
    }
}

fn isSensitiveHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "authorization") or
        std.ascii.eqlIgnoreCase(name, "proxy-authorization") or
        std.ascii.eqlIgnoreCase(name, "cookie") or
        std.ascii.eqlIgnoreCase(name, "set-cookie") or
        std.ascii.eqlIgnoreCase(name, "x-api-key") or
        std.ascii.eqlIgnoreCase(name, "x-auth-token") or
        std.ascii.eqlIgnoreCase(name, "x-csrf-token") or
        std.ascii.eqlIgnoreCase(name, "x-xsrf-token");
}

fn captureBody(body: []const u8, _: ?[]const u8, _: ?[]const u8) []const u8 {
    return body[0..@min(body.len, MAX_CAPTURE_BYTES)];
}

fn isTextContent(content_type: ?[]const u8, content_encoding: ?[]const u8) bool {
    _ = content_encoding;
    const value = content_type orelse return false;
    return std.ascii.startsWithIgnoreCase(value, "text/") or
        std.ascii.indexOfIgnoreCase(value, "json") != null or
        std.ascii.indexOfIgnoreCase(value, "javascript") != null or
        std.ascii.indexOfIgnoreCase(value, "xml") != null or
        std.ascii.indexOfIgnoreCase(value, "css") != null or
        std.ascii.indexOfIgnoreCase(value, "svg") != null;
}

pub fn emitBrowserStage(
    self: *Self,
    stage: []const u8,
    duration_us: u64,
    frame_id: u32,
    loader_id: u32,
    measurement_state: []const u8,
    process: []const u8,
    thread: []const u8,
) !void {
    process_mutex.lock();
    defer process_mutex.unlock();
    process_sequence += 1;
    var output: std.Io.Writer.Allocating = .init(self.allocator);
    defer output.deinit();
    const event_id = try std.fmt.allocPrint(self.allocator, "{s}:browser-{d}", .{ self.session_id, process_sequence });
    defer self.allocator.free(event_id);
    const sample = readProcessSample();
    try std.json.Stringify.value(.{.{
        .id = event_id,
        .sessionId = self.session_id,
        .sequence = process_sequence,
        .timestamp = datetime.milliTimestamp(.clock),
        .duration = @as(f64, @floatFromInt(duration_us)) / 1000.0,
        .kind = "render",
        .name = stage,
        .status = "ok",
        .payload = .{
            .browserStage = stage,
            .systemStage = systemStageForBrowserStage(stage),
            .frameId = frame_id,
            .loaderId = loader_id,
            .measurementState = measurement_state,
            .process = process,
            .thread = thread,
            .processName = process,
            .threadName = thread,
            .processId = std.c.getpid(),
            .threadId = std.Thread.getCurrentId(),
            .logicalCpuCount = sample.logical_cpu_count,
            .physicalMemoryBytes = sample.physical_memory_bytes,
            .residentMemoryBytes = sample.resident_memory_bytes,
            .cpuPercent = sample.cpu_percent,
            .cpuCoresUsed = sample.cpu_cores_used,
            .cpuSampleWindowMs = sample.cpu_sample_window_ms,
            .cpuSampleState = sample.cpu_sample_state,
            .contextSwitches = sample.context_switches,
            .diskReadBytes = sample.disk_read_bytes,
            .diskWriteBytes = sample.disk_write_bytes,
            .systemSampleState = sample.state,
        },
    }}, .{}, &output.writer);
    try output.writer.writeByte('\n');
    try self.append(output.written());
}

/// Emit a browser lifecycle milestone without claiming that the execution has
/// finished.  Lifecycle events are intentionally separate from render timing:
/// consumers can show progress while the page continues running background
/// work (polling, WebSocket callbacks, lazy resources, etc.).
pub fn emitLifecycle(
    self: *Self,
    stage: []const u8,
    frame_id: u32,
    loader_id: u32,
    url: []const u8,
) !void {
    process_mutex.lock();
    defer process_mutex.unlock();
    process_sequence += 1;
    var output: std.Io.Writer.Allocating = .init(self.allocator);
    defer output.deinit();
    const event_id = try std.fmt.allocPrint(self.allocator, "{s}:lifecycle-{d}", .{ self.session_id, process_sequence });
    defer self.allocator.free(event_id);
    try std.json.Stringify.value(.{.{
        .id = event_id,
        .sessionId = self.session_id,
        .sequence = process_sequence,
        .timestamp = datetime.milliTimestamp(.clock),
        .duration = @as(f64, 0),
        .kind = "navigation",
        .name = stage,
        .status = "ok",
        .payload = .{
            .lifecycleStage = stage,
            .executionStatus = "recording",
            .frameId = frame_id,
            .loaderId = loader_id,
            .url = url,
            .source = "koko-core",
        },
    }}, .{}, &output.writer);
    try output.writer.writeByte('\n');
    try self.append(output.written());
}

pub fn emitBrowserScript(self: *Self, duration_us: u64, frame_id: u32, loader_id: u32, url: []const u8, script_kind: []const u8) !void {
    process_mutex.lock();
    defer process_mutex.unlock();
    process_sequence += 1;
    var output: std.Io.Writer.Allocating = .init(self.allocator);
    defer output.deinit();
    const event_id = try std.fmt.allocPrint(self.allocator, "{s}:browser-{d}", .{ self.session_id, process_sequence });
    defer self.allocator.free(event_id);
    const sample = readProcessSample();
    try std.json.Stringify.value(.{.{
        .id = event_id,
        .sessionId = self.session_id,
        .sequence = process_sequence,
        .timestamp = datetime.milliTimestamp(.clock),
        .duration = @as(f64, @floatFromInt(duration_us)) / 1000.0,
        .kind = "render",
        .name = "javascript",
        .status = "ok",
        .payload = .{ .browserStage = "javascript", .systemStage = "thread-scheduler", .scriptUrl = url, .scriptKind = script_kind, .functionName = "<script>", .callId = event_id, .callKind = "script", .callDepth = @as(u8, 0), .frameId = frame_id, .loaderId = loader_id, .measurementState = "measured", .process = "Renderer", .thread = "Main", .processName = "Renderer", .threadName = "Main", .processId = std.c.getpid(), .threadId = std.Thread.getCurrentId(), .logicalCpuCount = sample.logical_cpu_count, .physicalMemoryBytes = sample.physical_memory_bytes, .residentMemoryBytes = sample.resident_memory_bytes, .cpuPercent = sample.cpu_percent, .cpuCoresUsed = sample.cpu_cores_used, .cpuSampleWindowMs = sample.cpu_sample_window_ms, .cpuSampleState = sample.cpu_sample_state, .contextSwitches = sample.context_switches, .diskReadBytes = sample.disk_read_bytes, .diskWriteBytes = sample.disk_write_bytes, .systemSampleState = sample.state },
    }}, .{}, &output.writer);
    try output.writer.writeByte('\n');
    try self.append(output.written());
}

pub fn emitJavaScriptError(
    self: *Self,
    error_kind: []const u8,
    message: []const u8,
    script_url: []const u8,
    line: u32,
    column: u32,
    frame_id: u32,
    loader_id: u32,
    stack: ?[]const u8,
) !void {
    process_mutex.lock();
    defer process_mutex.unlock();
    process_sequence += 1;
    var output: std.Io.Writer.Allocating = .init(self.allocator);
    defer output.deinit();
    const event_id = try std.fmt.allocPrint(self.allocator, "{s}:javascript-error-{d}", .{ self.session_id, process_sequence });
    defer self.allocator.free(event_id);
    try std.json.Stringify.value(.{
        .id = event_id,
        .sessionId = self.session_id,
        .sequence = process_sequence,
        .timestamp = datetime.milliTimestamp(.clock),
        .duration = @as(f64, 0),
        .kind = "javascript",
        .name = error_kind,
        .status = "error",
        .payload = .{
            .errorType = error_kind,
            .message = message,
            .scriptUrl = script_url,
            .line = line,
            .column = column,
            .frameId = frame_id,
            .loaderId = loader_id,
            .source = "page",
            .handled = false,
            .stack = stack,
        },
    }, .{ .emit_null_optional_fields = false }, &output.writer);
    try output.writer.writeByte('\n');
    try self.append(output.written());
}

pub fn emitApplicationStorageEntry(
    self: *Self,
    storage_type: []const u8,
    origin: []const u8,
    key: []const u8,
    value: ?[]const u8,
    value_bytes: usize,
    details: anytype,
) !void {
    process_mutex.lock();
    defer process_mutex.unlock();
    process_sequence += 1;
    var output: std.Io.Writer.Allocating = .init(self.allocator);
    defer output.deinit();
    const event_id = try std.fmt.allocPrint(self.allocator, "{s}:application-storage-{d}", .{ self.session_id, process_sequence });
    defer self.allocator.free(event_id);
    try std.json.Stringify.value(.{
        .id = event_id,
        .sessionId = self.session_id,
        .sequence = process_sequence,
        .timestamp = datetime.milliTimestamp(.clock),
        .duration = @as(f64, 0),
        .kind = "log",
        .name = "storage-entry",
        .status = "ok",
        .payload = .{
            .storageType = storage_type,
            .origin = origin,
            .key = key,
            .value = value,
            .valueBytes = value_bytes,
            .valueState = if (value != null) "captured" else "unavailable",
            .source = "browser-runtime",
            .details = details,
        },
    }, .{ .emit_null_optional_fields = false }, &output.writer);
    try output.writer.writeByte('\n');
    try self.append(output.written());
}

/// Records that the Core has atomically written a reconstructible state
/// manifest. The checkpoint directory is deliberately not sent to telemetry:
/// it contains credential-bearing browser state and is a local operator detail.
pub fn emitExecutionCheckpoint(
    self: *Self,
    url: []const u8,
    cookie_count: usize,
    local_storage_entries: usize,
    session_storage_entries: usize,
) !void {
    process_mutex.lock();
    defer process_mutex.unlock();
    process_sequence += 1;
    var output: std.Io.Writer.Allocating = .init(self.allocator);
    defer output.deinit();
    const event_id = try std.fmt.allocPrint(self.allocator, "{s}:execution-checkpoint-{d}", .{ self.session_id, process_sequence });
    defer self.allocator.free(event_id);
    try std.json.Stringify.value(.{
        .id = event_id,
        .sessionId = self.session_id,
        .sequence = process_sequence,
        .timestamp = datetime.milliTimestamp(.clock),
        .duration = @as(f64, 0),
        .kind = "log",
        .name = "execution-checkpoint",
        .status = "ok",
        .payload = .{
            .executionId = self.session_id,
            .executionStatus = "completed",
            .executionCapabilities = self.executionCapabilities(),
            .executionCheckpoint = .{
                .kind = "reconstructible",
                .url = url,
                .stateCoverage = &.{"browser-state"},
                // A checkpoint is restorable even before a replay policy is
                // selected. Observatory derives that policy from the recorded
                // inputs after the inspection has completed.
                .replayable = self.checkpoint_enabled,
                .cookieCount = cookie_count,
                .localStorageEntries = local_storage_entries,
                .sessionStorageEntries = session_storage_entries,
            },
        },
    }, .{}, &output.writer);
    try output.writer.writeByte('\n');
    try self.append(output.written());
}

fn executionCapabilities(self: *const Self) []const []const u8 {
    if (self.checkpoint_enabled and self.replay_enabled) return &.{ "recording", "bookmark", "checkpoint-reconstruct", "network-replay" };
    if (self.checkpoint_enabled) return &.{ "recording", "bookmark", "checkpoint-reconstruct" };
    if (self.replay_enabled) return &.{ "recording", "bookmark", "network-replay" };
    return &.{ "recording", "bookmark" };
}

fn headerValue(conn: *const http.Connection, comptime name: [:0]const u8) ?[]const u8 {
    const header = conn.getResponseHeader(name, 0) orelse return null;
    return header.value;
}

fn durationMeasurement(stage: []const u8, duration_us: u64, measurement: []const u8, connection_reused: bool) []const u8 {
    if (duration_us == 0 and std.mem.eql(u8, measurement, "measured")) {
        if (connection_reused and (std.mem.eql(u8, stage, "dns") or std.mem.eql(u8, stage, "tcp") or std.mem.eql(u8, stage, "tls"))) return "reused";
        return "unavailable";
    }
    return measurement;
}

const ProcessSample = struct {
    logical_cpu_count: u32 = 0,
    physical_memory_bytes: ?u64 = null,
    resident_memory_bytes: ?u64 = null,
    cpu_percent: ?f64 = null,
    cpu_cores_used: ?f64 = null,
    cpu_sample_window_ms: ?f64 = null,
    cpu_sample_state: []const u8 = "warming-up",
    context_switches: ?u64 = null,
    disk_read_bytes: ?u64 = null,
    disk_write_bytes: ?u64 = null,
    cpu_time_us: ?u64 = null,
    wall_time_us: i128 = 0,
    state: []const u8 = "sampled",
};

const CpuSample = struct {
    percent: f64,
    cores_used: f64,
    window_ms: f64,
};

const cpu_sample_min_window_us: i128 = 250_000;

fn readProcessSample() ProcessSample {
    var sample = ProcessSample{
        .logical_cpu_count = @intCast(std.Thread.getCpuCount() catch 0),
        .physical_memory_bytes = physicalMemoryBytes(),
        .wall_time_us = @intCast(datetime.microTimestamp(.clock)),
    };

    if (readRusage()) |usage| {
        sample.resident_memory_bytes = usage.resident_memory_bytes;
        sample.context_switches = usage.context_switches;
        sample.disk_read_bytes = usage.disk_read_bytes;
        sample.disk_write_bytes = usage.disk_write_bytes;
        sample.cpu_time_us = usage.cpu_time_us;
    } else {
        sample.state = "rusage-unavailable";
    }

    if (sample.cpu_time_us) |cpu_time| {
        if (previous_cpu_sample) |previous| {
            if (previous.cpu_time_us) |previous_cpu_time| {
                const wall_delta = sample.wall_time_us - previous.wall_time_us;
                if (wall_delta >= cpu_sample_min_window_us and cpu_time >= previous_cpu_time) {
                    const cpu_delta = cpu_time - previous_cpu_time;
                    const cpu_ratio = @as(f64, @floatFromInt(cpu_delta)) / @as(f64, @floatFromInt(wall_delta));
                    const cores = @max(sample.logical_cpu_count, 1);
                    const cores_used = @max(0.0, cpu_ratio);
                    const window_ms = @as(f64, @floatFromInt(wall_delta)) / 1000.0;
                    const percent = @min(100.0, cores_used / @as(f64, @floatFromInt(cores)) * 100.0);
                    sample.cpu_percent = percent;
                    sample.cpu_cores_used = cores_used;
                    sample.cpu_sample_window_ms = window_ms;
                    sample.cpu_sample_state = "sampled";
                    latest_cpu_sample = .{ .percent = percent, .cores_used = cores_used, .window_ms = window_ms };
                    previous_cpu_sample = sample;
                    return sample;
                }
            }
        }
    }
    if (latest_cpu_sample) |latest| {
        sample.cpu_percent = latest.percent;
        sample.cpu_cores_used = latest.cores_used;
        sample.cpu_sample_window_ms = latest.window_ms;
        sample.cpu_sample_state = "cached";
    }
    if (previous_cpu_sample == null and sample.cpu_time_us != null) previous_cpu_sample = sample;
    return sample;
}

const RusageSnapshot = struct {
    resident_memory_bytes: u64,
    context_switches: u64,
    disk_read_bytes: u64,
    disk_write_bytes: u64,
    cpu_time_us: u64,
};

fn readRusage() ?RusageSnapshot {
    const usage = std.posix.getrusage(0);
    const user_us = timevalMicros(usage.utime);
    const system_us = timevalMicros(usage.stime);
    return .{
        .resident_memory_bytes = residentBytesFromRusage(usage.maxrss),
        .context_switches = nonNegativeInt(usage.nvcsw) + nonNegativeInt(usage.nivcsw),
        .disk_read_bytes = nonNegativeInt(usage.inblock) * 512,
        .disk_write_bytes = nonNegativeInt(usage.oublock) * 512,
        .cpu_time_us = user_us + system_us,
    };
}

fn timevalMicros(value: std.c.timeval) u64 {
    return nonNegativeInt(value.sec) * 1_000_000 + nonNegativeInt(value.usec);
}

fn nonNegativeInt(value: anytype) u64 {
    return if (value <= 0) 0 else @intCast(value);
}

fn residentBytesFromRusage(value: anytype) u64 {
    const rss = nonNegativeInt(value);
    return switch (builtin.os.tag) {
        .macos, .ios, .watchos, .tvos => rss,
        else => rss * 1024,
    };
}

fn physicalMemoryBytes() ?u64 {
    return switch (builtin.os.tag) {
        .macos => sysctlU64("hw.memsize"),
        else => null,
    };
}

fn sysctlU64(name: [*:0]const u8) ?u64 {
    var value: u64 = 0;
    var size: usize = @sizeOf(u64);
    if (std.c.sysctlbyname(name, &value, &size, null, 0) != 0) return null;
    if (value == 0) return null;
    return value;
}

/// Maps a browser-owned stage to the first OS/hardware subsystem that owns its
/// execution. This is an ownership boundary, not a synthetic measurement.
fn systemStageForBrowserStage(stage: []const u8) []const u8 {
    if (std.mem.eql(u8, stage, "javascript") or std.mem.eql(u8, stage, "dom") or std.mem.eql(u8, stage, "event-loop")) return "thread-scheduler";
    if (std.mem.eql(u8, stage, "paint") or std.mem.eql(u8, stage, "layout") or std.mem.eql(u8, stage, "style")) return "graphics-pipeline";
    if (std.mem.eql(u8, stage, "raster") or std.mem.eql(u8, stage, "composite")) return "gpu";
    if (std.mem.eql(u8, stage, "frame") or std.mem.eql(u8, stage, "present")) return "display";
    return "browser-processes";
}

test "InternetJourneySink stage durations are non-overlapping" {
    const timing = http.Connection.TransferTiming{
        .queue_us = 3_000,
        .dns_us = 4_000,
        .tcp_us = 18_000,
        .tls_us = 41_000,
        .request_us = 2_000,
        .server_us = 95_000,
        .transfer_us = 12_000,
        .total_us = 172_000,
        .response_body_bytes = 25_395,
        .primary_ip = "93.184.216.34",
        .connection_id = 7,
        .num_connects = 1,
        .used_proxy = false,
    };
    try std.testing.expectEqual(@as(u64, 175_000), timing.queue_us + timing.dns_us + timing.tcp_us + timing.tls_us + timing.request_us + timing.server_us + timing.transfer_us);
}

test "InternetJourneySink labels zero durations without inventing a measurement" {
    try std.testing.expectEqualStrings("unavailable", durationMeasurement("server", 0, "measured", false));
    try std.testing.expectEqualStrings("reused", durationMeasurement("tcp", 0, "measured", true));
    try std.testing.expectEqualStrings("boundary", durationMeasurement("received", 0, "boundary", false));
    try std.testing.expectEqualStrings("measured", durationMeasurement("tcp", 1, "measured", true));
}

test "InternetJourneySink replay stages never claim live network measurements" {
    try std.testing.expectEqual(@as(usize, 12), replay_stages.len);
    for (replay_stages[0 .. replay_stages.len - 1]) |stage| {
        try std.testing.expectEqualStrings("not-applicable-replay", stage.measurement);
    }
    try std.testing.expectEqualStrings("received", replay_stages[replay_stages.len - 1].id);
    try std.testing.expectEqualStrings("boundary", replay_stages[replay_stages.len - 1].measurement);
}

test "InternetJourneySink serializes headers with real line breaks" {
    const headers = [_]http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "cache-control", .value = "no-store" },
    };
    var iterator = http.HeaderIterator{ .list = .{ .list = &headers } };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeSafeHeaders(&output.writer, &iterator);
    try std.testing.expectEqualStrings("content-type: application/json\ncache-control: no-store\n", output.written());
}

test "InternetJourneySink maps browser stages to system ownership without site rules" {
    try std.testing.expectEqualStrings("thread-scheduler", systemStageForBrowserStage("javascript"));
    try std.testing.expectEqualStrings("graphics-pipeline", systemStageForBrowserStage("paint"));
    try std.testing.expectEqualStrings("gpu", systemStageForBrowserStage("composite"));
    try std.testing.expectEqualStrings("display", systemStageForBrowserStage("frame"));
    try std.testing.expectEqualStrings("browser-processes", systemStageForBrowserStage("parse"));
}

test "InternetJourneySink process sampler exposes real process counters" {
    const sample = readProcessSample();
    try std.testing.expect(sample.logical_cpu_count > 0);
    try std.testing.expect(sample.wall_time_us > 0);
    try std.testing.expect(sample.resident_memory_bytes == null or sample.resident_memory_bytes.? > 0);
    try std.testing.expect(sample.context_switches == null or sample.context_switches.? >= 0);
}
