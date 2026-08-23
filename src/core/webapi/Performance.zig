const std = @import("std");
const js = @import("../js/js.zig");
const Frame = @import("../browser/Frame.zig");
const datetime = @import("../../support/datetime.zig");

const EventCounts = @import("EventCounts.zig");

const Allocator = std.mem.Allocator;

pub fn registerTypes() []const type {
    return &.{ Performance, Entry, NavigationTimingEntry, Mark, Measure, PerformanceTiming, PerformanceNavigation };
}

const Performance = @This();

/// Monotonic microsecond anchor for performance.now() (reset on each navigation).
_monotonic_origin_us: u64,
_entries: std.ArrayList(*Entry) = .empty,
_timing: PerformanceTiming = .{},
_navigation: PerformanceNavigation = .{},
_event_counts: EventCounts = .{},

/// High-resolution monotonic clock with Chrome-like quantization (~100μs + jitter).
fn highResTimestamp() u64 {
    const micros = datetime.microTimestamp(.monotonic);
    const base = @divTrunc(micros + 50, 100) * 100;
    const jitter = (micros ^ (micros >> 7) ^ (micros >> 13)) % 23;
    return base + jitter;
}

pub fn init() Performance {
    return .{
        ._monotonic_origin_us = highResTimestamp(),
        ._entries = .empty,
        ._timing = .{},
        ._navigation = .{},
    };
}

pub fn getTiming(self: *Performance) *PerformanceTiming {
    return &self._timing;
}

pub fn recordNavigationStart(self: *Performance) void {
    self._timing.recordNavigationStart();
    self._monotonic_origin_us = highResTimestamp();
    self.clearEntriesByType("navigation");
}

pub fn clearEntriesByType(self: *Performance, entry_type: []const u8) void {
    var i: usize = 0;
    while (i < self._entries.items.len) {
        const entry = self._entries.items[i];
        if (std.mem.eql(u8, entry.getEntryType(), entry_type)) {
            _ = self._entries.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

/// PerformanceNavigationTiming — minimal entry for getEntriesByType("navigation").
pub fn ensureNavigationTimingEntry(self: *Performance, url: []const u8, transfer_size: f64, frame: *Frame) !void {
    self.clearEntriesByType("navigation");
    _ = try NavigationTimingEntry.init(url, transfer_size, frame);
}

pub fn recordResponseStart(self: *Performance) void {
    self._timing.recordResponseStart();
}

pub fn recordDomInteractive(self: *Performance) void {
    self._timing.recordDomInteractive();
}

pub fn recordDocumentComplete(self: *Performance) void {
    self._timing.recordDocumentComplete();
}

pub fn now(self: *const Performance) f64 {
    const current = highResTimestamp();
    const origin = self._monotonic_origin_us;
    // Guard corrupted origins (UAF/slab reuse) — CreepJS logs use performance.now().
    if (origin == 0 or origin > current) {
        return 0.0;
    }
    const elapsed = current - origin;
    const ms = @as(f64, @floatFromInt(elapsed)) / 1000.0;
    return ms;
}

pub fn getTimeOrigin(self: *const Performance) f64 {
    // Blink: timeOrigin is the navigation start time in epoch milliseconds.
    if (self._timing.navigation_start > 0) {
        return self._timing.navigation_start;
    }
    return @as(f64, @floatFromInt(datetime.milliTimestamp(.clock)));
}

pub fn getNavigation(self: *Performance) *PerformanceNavigation {
    return &self._navigation;
}

pub fn getEventCounts(self: *Performance) *EventCounts {
    return &self._event_counts;
}

pub fn mark(
    self: *Performance,
    name: []const u8,
    _options: ?Mark.Options,
    frame: *Frame,
) !*Mark {
    const m = try Mark.init(name, _options, frame);
    try self._entries.append(frame.arena, m._proto);
    // Notify about the change.
    try frame.notifyPerformanceObservers(m._proto);
    return m;
}

const MeasureOptionsOrStartMark = union(enum) {
    measure_options: Measure.Options,
    start_mark: []const u8,
};

pub fn measure(
    self: *Performance,
    name: []const u8,
    maybe_options_or_start: ?MeasureOptionsOrStartMark,
    maybe_end_mark: ?[]const u8,
    frame: *Frame,
) !*Measure {
    if (maybe_options_or_start) |options_or_start| switch (options_or_start) {
        .measure_options => |options| {
            // Get start timestamp.
            const start_timestamp = blk: {
                if (options.start) |timestamp_or_mark| {
                    break :blk switch (timestamp_or_mark) {
                        .timestamp => |timestamp| timestamp,
                        .mark => |mark_name| try self.getMarkTime(mark_name),
                    };
                }

                break :blk 0.0;
            };

            // Get end timestamp.
            const end_timestamp = blk: {
                if (options.end) |timestamp_or_mark| {
                    break :blk switch (timestamp_or_mark) {
                        .timestamp => |timestamp| timestamp,
                        .mark => |mark_name| try self.getMarkTime(mark_name),
                    };
                }

                break :blk self.now();
            };

            const m = try Measure.init(
                name,
                options.detail,
                start_timestamp,
                end_timestamp,
                options.duration,
                frame,
            );
            try self._entries.append(frame.arena, m._proto);
            // Notify about the change.
            try frame.notifyPerformanceObservers(m._proto);
            return m;
        },
        .start_mark => |start_mark| {
            // Get start timestamp.
            const start_timestamp = try self.getMarkTime(start_mark);
            // Get end timestamp.
            const end_timestamp = blk: {
                if (maybe_end_mark) |mark_name| {
                    break :blk try self.getMarkTime(mark_name);
                }

                break :blk self.now();
            };

            const m = try Measure.init(
                name,
                null,
                start_timestamp,
                end_timestamp,
                null,
                frame,
            );
            try self._entries.append(frame.arena, m._proto);
            // Notify about the change.
            try frame.notifyPerformanceObservers(m._proto);
            return m;
        },
    };

    const m = try Measure.init(name, null, 0.0, self.now(), null, frame);
    try self._entries.append(frame.arena, m._proto);
    // Notify about the change.
    try frame.notifyPerformanceObservers(m._proto);
    return m;
}

pub fn clearMarks(self: *Performance, mark_name: ?[]const u8) void {
    var i: usize = 0;
    while (i < self._entries.items.len) {
        const entry = self._entries.items[i];
        if (entry._type == .mark and (mark_name == null or std.mem.eql(u8, entry._name, mark_name.?))) {
            _ = self._entries.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn clearMeasures(self: *Performance, measure_name: ?[]const u8) void {
    var i: usize = 0;
    while (i < self._entries.items.len) {
        const entry = self._entries.items[i];
        if (entry._type == .measure and (measure_name == null or std.mem.eql(u8, entry._name, measure_name.?))) {
            _ = self._entries.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn getEntries(self: *const Performance) []*Entry {
    return self._entries.items;
}

pub fn getEntriesByType(self: *const Performance, entry_type: []const u8, frame: *Frame) ![]const *Entry {
    return filterEntriesByType(frame.call_arena, self._entries.items, entry_type);
}

pub fn getEntriesByName(self: *const Performance, name: []const u8, entry_type: ?[]const u8, frame: *Frame) ![]const *Entry {
    return filterEntriesByName(frame.call_arena, self._entries.items, name, entry_type);
}

// Also used by PerformanceObserver
pub fn filterEntriesByType(arena: Allocator, list: []*Entry, entry_type: []const u8) ![]const *Entry {
    var result: std.ArrayList(*Entry) = .empty;
    for (list) |entry| {
        if (std.mem.eql(u8, entry.getEntryType(), entry_type)) {
            try result.append(arena, entry);
        }
    }
    return result.items;
}

// Also used by PerformanceObserver
pub fn filterEntriesByName(arena: Allocator, list: []*Entry, name: []const u8, entry_type: ?[]const u8) ![]const *Entry {
    var result: std.ArrayList(*Entry) = .empty;

    for (list) |entry| {
        if (!std.mem.eql(u8, entry._name, name)) {
            continue;
        }
        if (entry_type == null or std.mem.eql(u8, entry.getEntryType(), entry_type.?)) {
            try result.append(arena, entry);
        }
    }

    return result.items;
}

fn getMarkTime(self: *const Performance, mark_name: []const u8) !f64 {
    for (self._entries.items) |entry| {
        if (entry._type == .mark and std.mem.eql(u8, entry._name, mark_name)) {
            return entry._start_time;
        }
    }

    // PerformanceTiming attribute names are valid start/end marks per the
    // W3C User Timing Level 2 spec. All are relative to navigationStart (= 0).
    // https://www.w3.org/TR/user-timing/#dom-performance-measure
    //
    // `navigationStart` is an equivalent to 0.
    // Others are dependant to request arrival, end of request etc, but we
    // return a dummy 0 value for now.
    const navigation_timing_marks = std.StaticStringMap(void).initComptime(.{
        .{ "navigationStart", {} },
        .{ "unloadEventStart", {} },
        .{ "unloadEventEnd", {} },
        .{ "redirectStart", {} },
        .{ "redirectEnd", {} },
        .{ "fetchStart", {} },
        .{ "domainLookupStart", {} },
        .{ "domainLookupEnd", {} },
        .{ "connectStart", {} },
        .{ "connectEnd", {} },
        .{ "secureConnectionStart", {} },
        .{ "requestStart", {} },
        .{ "responseStart", {} },
        .{ "responseEnd", {} },
        .{ "domLoading", {} },
        .{ "domInteractive", {} },
        .{ "domContentLoadedEventStart", {} },
        .{ "domContentLoadedEventEnd", {} },
        .{ "domComplete", {} },
        .{ "loadEventStart", {} },
        .{ "loadEventEnd", {} },
    });
    if (navigation_timing_marks.has(mark_name)) {
        return 0;
    }

    return error.SyntaxError; // Mark not found
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Performance);

    pub const Meta = struct {
        pub const name = "Performance";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const now = bridge.function(Performance.now, .{});
    pub const mark = bridge.function(Performance.mark, .{});
    pub const measure = bridge.function(Performance.measure, .{ .dom_exception = true });
    pub const clearMarks = bridge.function(Performance.clearMarks, .{});
    pub const clearMeasures = bridge.function(Performance.clearMeasures, .{});
    pub const getEntries = bridge.function(Performance.getEntries, .{});
    pub const getEntriesByType = bridge.function(Performance.getEntriesByType, .{});
    pub const getEntriesByName = bridge.function(Performance.getEntriesByName, .{});
    pub const timeOrigin = bridge.accessor(Performance.getTimeOrigin, null, .{});
    pub const timing = bridge.accessor(Performance.getTiming, null, .{});
    pub const navigation = bridge.accessor(Performance.getNavigation, null, .{});
    pub const eventCounts = bridge.accessor(Performance.getEventCounts, null, .{});
};

pub const Entry = struct {
    _duration: f64 = 0.0,
    _type: Type,
    _name: []const u8,
    _start_time: f64 = 0.0,

    pub const Type = union(Enum) {
        element,
        event,
        first_input,
        @"largest-contentful-paint",
        @"layout-shift",
        @"long-animation-frame",
        longtask,
        measure: *Measure,
        navigation: *NavigationTimingEntry,
        paint,
        resource,
        taskattribution,
        @"visibility-state",
        mark: *Mark,

        pub const Enum = enum(u8) {
            element = 1, // Changing this affect PerformanceObserver's behavior.
            event = 2,
            first_input = 3,
            @"largest-contentful-paint" = 4,
            @"layout-shift" = 5,
            @"long-animation-frame" = 6,
            longtask = 7,
            measure = 8,
            navigation = 9,
            paint = 10,
            resource = 11,
            taskattribution = 12,
            @"visibility-state" = 13,
            mark = 14,
            // If we ever have types more than 16, we have to update entry
            // table of PerformanceObserver too.
        };
    };

    pub fn getDuration(self: *const Entry) f64 {
        return self._duration;
    }

    pub fn getEntryType(self: *const Entry) []const u8 {
        return switch (self._type) {
            .mark => "mark",
            .measure => "measure",
            .navigation => "navigation",
            else => |t| @tagName(t),
        };
    }

    pub fn getName(self: *const Entry) []const u8 {
        return self._name;
    }

    pub fn getStartTime(self: *const Entry) f64 {
        return self._start_time;
    }

    pub fn getNavigationType(self: *const Entry) ?[]const u8 {
        return switch (self._type) {
            .navigation => |n| n.getType(),
            else => null,
        };
    }

    pub fn getNavigationDeliveryType(self: *const Entry) ?[]const u8 {
        return switch (self._type) {
            .navigation => |n| n.getDeliveryType(),
            else => null,
        };
    }

    pub fn getNavigationTransferSize(self: *const Entry) ?f64 {
        return switch (self._type) {
            .navigation => |n| n.getTransferSize(),
            else => null,
        };
    }

    pub fn getNavigationNextHopProtocol(self: *const Entry) ?[]const u8 {
        return switch (self._type) {
            .navigation => |n| n.getNextHopProtocol(),
            else => null,
        };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Entry);

        pub const Meta = struct {
            pub const name = "PerformanceEntry";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const name = bridge.accessor(Entry.getName, null, .{});
        pub const duration = bridge.accessor(Entry.getDuration, null, .{});
        pub const entryType = bridge.accessor(Entry.getEntryType, null, .{});
        pub const startTime = bridge.accessor(Entry.getStartTime, null, .{});
        // PerformanceNavigationTiming fields (present when entryType === "navigation").
        pub const @"type" = bridge.accessor(Entry.getNavigationType, null, .{});
        pub const deliveryType = bridge.accessor(Entry.getNavigationDeliveryType, null, .{});
        pub const transferSize = bridge.accessor(Entry.getNavigationTransferSize, null, .{});
        pub const nextHopProtocol = bridge.accessor(Entry.getNavigationNextHopProtocol, null, .{});
        pub const toJSON = bridge.function(Entry.toJSON, .{});
    };

    /// PerformanceEntry serialization is inherited by timing subclasses.
    pub fn toJSON(self: *const Entry) struct {
        name: []const u8,
        entryType: []const u8,
        startTime: f64,
        duration: f64,
    } {
        return .{
            .name = self.getName(),
            .entryType = self.getEntryType(),
            .startTime = self.getStartTime(),
            .duration = self.getDuration(),
        };
    }
};

pub const NavigationTimingEntry = struct {
    _proto: *Entry,
    _transfer_size: f64 = 0,

    pub fn init(url: []const u8, transfer_size: f64, frame: *Frame) !*NavigationTimingEntry {
        const perf = &frame.window._performance;
        const n = try frame._factory.create(NavigationTimingEntry{
            ._proto = undefined,
            ._transfer_size = transfer_size,
        });
        const entry = try frame._factory.create(Entry{
            ._start_time = 0,
            ._duration = perf.now(),
            ._name = try frame.dupeString(url),
            ._type = .{ .navigation = n },
        });
        n._proto = entry;
        try perf._entries.append(frame.arena, entry);
        return n;
    }

    pub fn getType(self: *const NavigationTimingEntry) []const u8 {
        _ = self;
        return "navigate";
    }

    pub fn getDeliveryType(self: *const NavigationTimingEntry) []const u8 {
        _ = self;
        return "";
    }

    pub fn getTransferSize(self: *const NavigationTimingEntry) f64 {
        return self._transfer_size;
    }

    pub fn getNextHopProtocol(self: *const NavigationTimingEntry) []const u8 {
        _ = self;
        return "";
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(NavigationTimingEntry);

        pub const Meta = struct {
            pub const name = "PerformanceNavigationTiming";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const toJSON = bridge.function(NavigationTimingEntry.toJSON, .{});
    };

    /// Navigation entries extend PerformanceEntry but expose navigation timing
    /// fields from their own serialization algorithm. Values not yet observed
    /// by this lightweight timing model are the platform's zero defaults.
    pub fn toJSON(self: *const NavigationTimingEntry) struct {
        name: []const u8,
        entryType: []const u8,
        startTime: f64,
        duration: f64,
        domComplete: f64,
        domContentLoadedEventEnd: f64,
        domContentLoadedEventStart: f64,
        domInteractive: f64,
        loadEventEnd: f64,
        loadEventStart: f64,
        redirectCount: u32,
        responseStatus: u16,
        type: []const u8,
        unloadEventEnd: f64,
        unloadEventStart: f64,
    } {
        const entry = self._proto;
        return .{
            .name = entry.getName(),
            .entryType = entry.getEntryType(),
            .startTime = entry.getStartTime(),
            .duration = entry.getDuration(),
            .domComplete = 0,
            .domContentLoadedEventEnd = 0,
            .domContentLoadedEventStart = 0,
            .domInteractive = 0,
            .loadEventEnd = 0,
            .loadEventStart = 0,
            .redirectCount = 0,
            .responseStatus = 0,
            .type = self.getType(),
            .unloadEventEnd = 0,
            .unloadEventStart = 0,
        };
    }
};

pub const Mark = struct {
    _proto: *Entry,
    _detail: ?js.Value.Global,

    const Options = struct {
        detail: ?js.Value = null,
        startTime: ?f64 = null,
    };

    pub fn init(name: []const u8, _opts: ?Options, frame: *Frame) !*Mark {
        const opts = _opts orelse Options{};
        const start_time = opts.startTime orelse frame.window._performance.now();

        const detail = if (opts.detail) |d| try d.persist() else null;
        const m = try frame._factory.create(Mark{
            ._proto = undefined,
            ._detail = detail,
        });

        const entry = try frame._factory.create(Entry{
            ._start_time = start_time,
            ._name = try frame.dupeString(name),
            ._type = .{ .mark = m },
        });
        m._proto = entry;
        return m;
    }

    pub fn getDetail(self: *const Mark) ?js.Value.Global {
        return self._detail;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Mark);

        pub const Meta = struct {
            pub const name = "PerformanceMark";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const detail = bridge.accessor(Mark.getDetail, null, .{});
    };
};

pub const Measure = struct {
    _proto: *Entry,
    _detail: ?js.Value.Global,

    const Options = struct {
        detail: ?js.Value = null,
        start: ?TimestampOrMark,
        end: ?TimestampOrMark,
        duration: ?f64 = null,

        const TimestampOrMark = union(enum) {
            timestamp: f64,
            mark: []const u8,
        };
    };

    pub fn init(
        name: []const u8,
        maybe_detail: ?js.Value,
        start_timestamp: f64,
        end_timestamp: f64,
        maybe_duration: ?f64,
        frame: *Frame,
    ) !*Measure {
        const duration = maybe_duration orelse (end_timestamp - start_timestamp);
        if (duration < 0.0) {
            return error.TypeError;
        }

        const detail = if (maybe_detail) |d| try d.persist() else null;
        const m = try frame._factory.create(Measure{
            ._proto = undefined,
            ._detail = detail,
        });

        const entry = try frame._factory.create(Entry{
            ._start_time = start_timestamp,
            ._duration = duration,
            ._name = try frame.dupeString(name),
            ._type = .{ .measure = m },
        });
        m._proto = entry;
        return m;
    }

    pub fn getDetail(self: *const Measure) ?js.Value.Global {
        return self._detail;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Measure);

        pub const Meta = struct {
            pub const name = "PerformanceMeasure";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const detail = bridge.accessor(Measure.getDetail, null, .{});
    };
};

/// PerformanceTiming — Navigation Timing Level 1 (legacy, but widely used).
/// https://developer.mozilla.org/en-US/docs/Web/API/PerformanceTiming
pub const PerformanceTiming = struct {
    navigation_start: f64 = 0,
    unload_event_start: f64 = 0,
    unload_event_end: f64 = 0,
    redirect_start: f64 = 0,
    redirect_end: f64 = 0,
    fetch_start: f64 = 0,
    domain_lookup_start: f64 = 0,
    domain_lookup_end: f64 = 0,
    connect_start: f64 = 0,
    connect_end: f64 = 0,
    secure_connection_start: f64 = 0,
    request_start: f64 = 0,
    response_start: f64 = 0,
    response_end: f64 = 0,
    dom_loading: f64 = 0,
    dom_interactive: f64 = 0,
    dom_content_loaded_event_start: f64 = 0,
    dom_content_loaded_event_end: f64 = 0,
    dom_complete: f64 = 0,
    load_event_start: f64 = 0,
    load_event_end: f64 = 0,

    fn epochMs() f64 {
        return @as(f64, @floatFromInt(datetime.milliTimestamp(.clock)));
    }

    fn timingMs(value: f64) f64 {
        if (value <= 0) return 0;
        return @floatFromInt(@as(i64, @intFromFloat(value)));
    }

    pub fn recordNavigationStart(self: *PerformanceTiming) void {
        const t = epochMs();
        const base = @as(i64, @intFromFloat(t));
        self.navigation_start = @floatFromInt(base);
        self.unload_event_start = 0;
        self.unload_event_end = 0;
        self.redirect_start = 0;
        self.redirect_end = 0;
        self.fetch_start = @floatFromInt(base);
        self.domain_lookup_start = @floatFromInt(base);
        self.domain_lookup_end = @floatFromInt(base + 1);
        self.connect_start = @floatFromInt(base);
        self.connect_end = @floatFromInt(base + 2);
        self.secure_connection_start = @floatFromInt(base + 1);
        self.request_start = @floatFromInt(base + 3);
        self.response_start = 0;
        self.response_end = 0;
        self.dom_loading = 0;
        self.dom_interactive = 0;
        self.dom_content_loaded_event_start = 0;
        self.dom_content_loaded_event_end = 0;
        self.dom_complete = 0;
        self.load_event_start = 0;
        self.load_event_end = 0;
    }

    fn stampTiming(start: f64, span_ms: f64, numer: i64, denom: i64) f64 {
        const base = @as(i64, @intFromFloat(start));
        const span = @as(i64, @intFromFloat(@max(span_ms, 1)));
        return @floatFromInt(base + @divTrunc(span * numer, denom));
    }

    pub fn recordResponseStart(self: *PerformanceTiming) void {
        const t = epochMs();
        if (self.response_start == 0) self.response_start = t;
        if (self.response_end == 0) self.response_end = t;
        if (self.dom_loading == 0) self.dom_loading = t;
    }

    pub fn recordDomInteractive(self: *PerformanceTiming) void {
        const t = epochMs();
        const start = if (self.navigation_start > 0) self.navigation_start else t - 120;
        const span = @max(t - start, 25);
        if (self.dom_interactive == 0) {
            self.dom_interactive = stampTiming(start, span, 78, 100);
        }
        if (self.dom_content_loaded_event_start == 0) {
            self.dom_content_loaded_event_start = stampTiming(start, span, 82, 100);
            self.dom_content_loaded_event_end = stampTiming(start, span, 84, 100);
        }
    }

    pub fn recordDocumentComplete(self: *PerformanceTiming) void {
        const t = epochMs();
        const start = if (self.navigation_start > 0) self.navigation_start else t - 300;
        if (self.response_start > 0 and self.dom_content_loaded_event_end > 0) {
            const dce = @as(i64, @intFromFloat(self.dom_content_loaded_event_end));
            const load_end = @max(@as(i64, @intFromFloat(t)), dce);
            if (self.dom_complete == 0) self.dom_complete = @floatFromInt(load_end);
            if (self.load_event_start == 0) self.load_event_start = @floatFromInt(load_end);
            self.load_event_end = @floatFromInt(load_end);
            return;
        }
        const span = @max(t - start, 40);
        if (self.response_start == 0) self.response_start = stampTiming(start, span, 12, 100);
        if (self.response_end == 0) self.response_end = stampTiming(start, span, 22, 100);
        if (self.dom_loading == 0) self.dom_loading = stampTiming(start, span, 28, 100);
        if (self.dom_interactive == 0) self.dom_interactive = stampTiming(start, span, 52, 100);
        if (self.dom_content_loaded_event_start == 0) self.dom_content_loaded_event_start = stampTiming(start, span, 55, 100);
        if (self.dom_content_loaded_event_end == 0) self.dom_content_loaded_event_end = stampTiming(start, span, 57, 100);
        self.dom_complete = stampTiming(start, span, 86, 100);
        self.load_event_start = stampTiming(start, span, 88, 100);
        self.load_event_end = t;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PerformanceTiming);

        pub const Meta = struct {
            pub const name = "PerformanceTiming";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const navigationStart = bridge.accessor(PerformanceTiming.getNavigationStart, null, .{ .deletable = false });
        pub const unloadEventStart = bridge.accessor(PerformanceTiming.getUnloadEventStart, null, .{ .deletable = false });
        pub const unloadEventEnd = bridge.accessor(PerformanceTiming.getUnloadEventEnd, null, .{ .deletable = false });
        pub const redirectStart = bridge.accessor(PerformanceTiming.getRedirectStart, null, .{ .deletable = false });
        pub const redirectEnd = bridge.accessor(PerformanceTiming.getRedirectEnd, null, .{ .deletable = false });
        pub const fetchStart = bridge.accessor(PerformanceTiming.getFetchStart, null, .{ .deletable = false });
        pub const domainLookupStart = bridge.accessor(PerformanceTiming.getDomainLookupStart, null, .{ .deletable = false });
        pub const domainLookupEnd = bridge.accessor(PerformanceTiming.getDomainLookupEnd, null, .{ .deletable = false });
        pub const connectStart = bridge.accessor(PerformanceTiming.getConnectStart, null, .{ .deletable = false });
        pub const connectEnd = bridge.accessor(PerformanceTiming.getConnectEnd, null, .{ .deletable = false });
        pub const secureConnectionStart = bridge.accessor(PerformanceTiming.getSecureConnectionStart, null, .{ .deletable = false });
        pub const requestStart = bridge.accessor(PerformanceTiming.getRequestStart, null, .{ .deletable = false });
        pub const responseStart = bridge.accessor(PerformanceTiming.getResponseStart, null, .{ .deletable = false });
        pub const responseEnd = bridge.accessor(PerformanceTiming.getResponseEnd, null, .{ .deletable = false });
        pub const domLoading = bridge.accessor(PerformanceTiming.getDomLoading, null, .{ .deletable = false });
        pub const domInteractive = bridge.accessor(PerformanceTiming.getDomInteractive, null, .{ .deletable = false });
        pub const domContentLoadedEventStart = bridge.accessor(PerformanceTiming.getDomContentLoadedEventStart, null, .{ .deletable = false });
        pub const domContentLoadedEventEnd = bridge.accessor(PerformanceTiming.getDomContentLoadedEventEnd, null, .{ .deletable = false });
        pub const domComplete = bridge.accessor(PerformanceTiming.getDomComplete, null, .{ .deletable = false });
        pub const loadEventStart = bridge.accessor(PerformanceTiming.getLoadEventStart, null, .{ .deletable = false });
        pub const loadEventEnd = bridge.accessor(PerformanceTiming.getLoadEventEnd, null, .{ .deletable = false });
        pub const toJSON = bridge.function(PerformanceTiming.toJSON, .{});
    };

    pub fn getNavigationStart(self: *const PerformanceTiming) f64 {
        return timingMs(self.navigation_start);
    }
    pub fn getUnloadEventStart(self: *const PerformanceTiming) f64 {
        return self.unload_event_start;
    }
    pub fn getUnloadEventEnd(self: *const PerformanceTiming) f64 {
        return self.unload_event_end;
    }
    pub fn getRedirectStart(self: *const PerformanceTiming) f64 {
        return self.redirect_start;
    }
    pub fn getRedirectEnd(self: *const PerformanceTiming) f64 {
        return self.redirect_end;
    }
    pub fn getFetchStart(self: *const PerformanceTiming) f64 {
        return self.fetch_start;
    }
    pub fn getDomainLookupStart(self: *const PerformanceTiming) f64 {
        return self.domain_lookup_start;
    }
    pub fn getDomainLookupEnd(self: *const PerformanceTiming) f64 {
        return self.domain_lookup_end;
    }
    pub fn getConnectStart(self: *const PerformanceTiming) f64 {
        return self.connect_start;
    }
    pub fn getConnectEnd(self: *const PerformanceTiming) f64 {
        return self.connect_end;
    }
    pub fn getSecureConnectionStart(self: *const PerformanceTiming) f64 {
        return self.secure_connection_start;
    }
    pub fn getRequestStart(self: *const PerformanceTiming) f64 {
        return self.request_start;
    }
    pub fn getResponseStart(self: *const PerformanceTiming) f64 {
        return timingMs(self.response_start);
    }
    pub fn getResponseEnd(self: *const PerformanceTiming) f64 {
        return timingMs(self.response_end);
    }
    pub fn getDomLoading(self: *const PerformanceTiming) f64 {
        return timingMs(self.dom_loading);
    }
    pub fn getDomInteractive(self: *const PerformanceTiming) f64 {
        return timingMs(self.dom_interactive);
    }
    pub fn getDomContentLoadedEventStart(self: *const PerformanceTiming) f64 {
        return self.dom_content_loaded_event_start;
    }
    pub fn getDomContentLoadedEventEnd(self: *const PerformanceTiming) f64 {
        return self.dom_content_loaded_event_end;
    }
    pub fn getDomComplete(self: *const PerformanceTiming) f64 {
        return self.dom_complete;
    }
    pub fn getLoadEventStart(self: *const PerformanceTiming) f64 {
        return self.load_event_start;
    }
    pub fn getLoadEventEnd(self: *const PerformanceTiming) f64 {
        return self.load_event_end;
    }

    /// Navigation Timing Level 1 exposes a serializable snapshot of the
    /// legacy `performance.timing` object. Keep this derived from public
    /// getters so its values match direct property reads.
    pub fn toJSON(self: *const PerformanceTiming) struct {
        navigationStart: f64,
        unloadEventStart: f64,
        unloadEventEnd: f64,
        redirectStart: f64,
        redirectEnd: f64,
        fetchStart: f64,
        domainLookupStart: f64,
        domainLookupEnd: f64,
        connectStart: f64,
        connectEnd: f64,
        secureConnectionStart: f64,
        requestStart: f64,
        responseStart: f64,
        responseEnd: f64,
        domLoading: f64,
        domInteractive: f64,
        domContentLoadedEventStart: f64,
        domContentLoadedEventEnd: f64,
        domComplete: f64,
        loadEventStart: f64,
        loadEventEnd: f64,
    } {
        return .{
            .navigationStart = self.getNavigationStart(),
            .unloadEventStart = self.getUnloadEventStart(),
            .unloadEventEnd = self.getUnloadEventEnd(),
            .redirectStart = self.getRedirectStart(),
            .redirectEnd = self.getRedirectEnd(),
            .fetchStart = self.getFetchStart(),
            .domainLookupStart = self.getDomainLookupStart(),
            .domainLookupEnd = self.getDomainLookupEnd(),
            .connectStart = self.getConnectStart(),
            .connectEnd = self.getConnectEnd(),
            .secureConnectionStart = self.getSecureConnectionStart(),
            .requestStart = self.getRequestStart(),
            .responseStart = self.getResponseStart(),
            .responseEnd = self.getResponseEnd(),
            .domLoading = self.getDomLoading(),
            .domInteractive = self.getDomInteractive(),
            .domContentLoadedEventStart = self.getDomContentLoadedEventStart(),
            .domContentLoadedEventEnd = self.getDomContentLoadedEventEnd(),
            .domComplete = self.getDomComplete(),
            .loadEventStart = self.getLoadEventStart(),
            .loadEventEnd = self.getLoadEventEnd(),
        };
    }
};

// PerformanceNavigation implements the Navigation Timing Level 1 API.
// https://www.w3.org/TR/navigation-timing/#sec-navigation-navigation-timing-interface
// Stub implementation — returns 0 for type (TYPE_NAVIGATE) and 0 for redirectCount.
pub const PerformanceNavigation = struct {
    // Padding to avoid zero-size struct, which causes identity_map pointer collisions.
    _pad: bool = false,

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PerformanceNavigation);

        pub const Meta = struct {
            pub const name = "PerformanceNavigation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const @"type" = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const redirectCount = bridge.property(0.0, .{ .template = false, .readonly = true });
    };
};
