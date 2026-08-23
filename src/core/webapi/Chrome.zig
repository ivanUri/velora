// Blink-like window.chrome stub.
// Intentionally omits chrome.runtime: a naive JS function stub for sendMessage/connect
// has `.prototype` and is constructable, which CreepJS flags as hasBadChromeRuntime.
// Missing runtime is safer than a lying runtime (see stealth hasBadChromeRuntime).

const std = @import("std");
const datetime = @import("../../support/datetime.zig");
const js = @import("../js/js.zig");
const Frame = @import("../browser/Frame.zig");

const Chrome = @This();

_app: ChromeApp = .{},
_request_time: f64 = 0,
_start_load_time: f64 = 0,
_commit_time: f64 = 0,
_finish_doc_time: f64 = 0,
_finish_load_time: f64 = 0,
_first_paint_time: f64 = 0,
_start_e_ms: u64 = 0,
_onload_ms: u64 = 0,

pub const init: Chrome = .{};

pub const LoadTimes = struct {
    requestTime: f64 = 0,
    startLoadTime: f64 = 0,
    commitLoadTime: f64 = 0,
    finishDocumentLoadTime: f64 = 0,
    finishLoadTime: f64 = 0,
    firstPaintTime: f64 = 0,
    firstPaintAfterLoadTime: f64 = 0,
    navigationType: []const u8 = "Other",
    wasFetchedViaSpdy: bool = false,
    wasNpnNegotiated: bool = true,
    npnNegotiatedProtocol: []const u8 = "h2",
    wasAlternateProtocolAvailable: bool = false,
    connectionInfo: []const u8 = "unknown",
};

pub const Csi = struct {
    startE: u64 = 0,
    onloadT: u64 = 0,
    pageT: f64 = 0,
    tran: u32 = 15,
};

pub fn recordResponseCommit(self: *Chrome, commit_ms: f64) void {
    const commit_sec = commit_ms / 1000.0;
    const start_sec = if (self._request_time > 0) self._request_time else commit_sec - 0.15;
    self._commit_time = commit_sec;
    if (self._first_paint_time == 0) {
        self._first_paint_time = commit_sec + 0.02;
    }
    _ = start_sec;
}

pub fn recordNavigationStart(self: *Chrome, nav_start_ms: f64) void {
    const start_sec = nav_start_ms / 1000.0;
    self._request_time = start_sec;
    self._start_load_time = start_sec;
    self._commit_time = 0;
    self._finish_doc_time = 0;
    self._finish_load_time = 0;
    self._first_paint_time = 0;
    self._start_e_ms = @intFromFloat(nav_start_ms);
    self._onload_ms = 0;
}

pub fn recordDocumentComplete(self: *Chrome, load_end_ms: f64) void {
    const start_sec = if (self._request_time > 0) self._request_time else (load_end_ms / 1000.0) - 0.5;
    const end_sec = load_end_ms / 1000.0;
    const span = @max(end_sec - start_sec, 0.08);
    self._commit_time = start_sec + span * 0.35;
    self._first_paint_time = start_sec + span * 0.55;
    self._finish_doc_time = start_sec + span * 0.85;
    self._finish_load_time = end_sec;
    self._onload_ms = @intFromFloat(load_end_ms);
}

pub fn loadTimes(self: *const Chrome) LoadTimes {
    const now = @as(f64, @floatFromInt(datetime.timestamp(.clock)));
    const request = if (self._request_time > 0) self._request_time else now - 0.4;
    const finish = if (self._finish_load_time > 0) self._finish_load_time else now;
    const commit = if (self._commit_time > 0) self._commit_time else request + 0.12;
    const finish_doc = if (self._finish_doc_time > 0) self._finish_doc_time else finish - 0.03;
    const first_paint = if (self._first_paint_time > 0) self._first_paint_time else commit + 0.04;
    return .{
        .requestTime = request,
        .startLoadTime = if (self._start_load_time > 0) self._start_load_time else request,
        .commitLoadTime = commit,
        .finishDocumentLoadTime = finish_doc,
        .finishLoadTime = finish,
        .firstPaintTime = first_paint,
        .firstPaintAfterLoadTime = 0,
        .navigationType = "Other",
        .wasFetchedViaSpdy = true,
        .wasNpnNegotiated = true,
        .npnNegotiatedProtocol = "h3",
        .connectionInfo = "h3",
    };
}

/// Chromium `GetCSI`: pageT = (base::Time::Now() - navigationStart).InMillisecondsF().
/// See chrome/renderer/loadtimes_extension_bindings.cc.
pub fn csiPageT(
    navigation_start_ms: f64,
    start_e_ms: u64,
    epoch_now_ms: u64,
) f64 {
    const nav_start: f64 = if (navigation_start_ms > 0)
        navigation_start_ms
    else if (start_e_ms > 0)
        @as(f64, @floatFromInt(start_e_ms))
    else
        @as(f64, @floatFromInt(epoch_now_ms)) - 400.0;
    const epoch_now: f64 = @as(f64, @floatFromInt(epoch_now_ms));
    return @max(epoch_now - nav_start, 0.0);
}

pub fn csi(self: *const Chrome, frame: *Frame) Csi {
    const perf = &frame.window._performance;
    const timing = perf._timing;
    const now_ms = datetime.milliTimestamp(.clock);

    const start_e: u64 = if (timing.navigation_start > 0)
        @intFromFloat(timing.navigation_start)
    else if (self._start_e_ms > 0)
        self._start_e_ms
    else
        now_ms -| 400;

    const onload_t: u64 = if (timing.dom_content_loaded_event_end > 0)
        @intFromFloat(timing.dom_content_loaded_event_end)
    else if (timing.load_event_end > 0)
        @intFromFloat(timing.load_event_end)
    else if (self._onload_ms > 0)
        self._onload_ms
    else
        now_ms;

    const page_t = csiPageT(timing.navigation_start, self._start_e_ms, now_ms);

    return .{
        .startE = start_e,
        .onloadT = onload_t,
        .pageT = page_t,
        .tran = 15,
    };
}

pub fn getApp(self: *Chrome) *ChromeApp {
    return &self._app;
}

/// Chromium `window.external` — empty host object. BotD/Fingerprint read
/// `external.toString()` (Sequentum check) and treat missing external as rare.
pub const External = struct {
    _pad: bool = false,

    pub fn toString(_: *const External) []const u8 {
        return "[object External]";
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(External);
        pub const Meta = struct {
            pub const name = "External";
            pub const own_properties = true;
            pub const empty_with_no_proto = true;
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const toString = bridge.function(External.toString, .{});
    };
};

pub fn registerTypes() []const type {
    return &.{ Chrome, ChromeApp, ChromeAppInstallState, ChromeAppRunningState, External };
}

/// chrome.app — minimal namespace object (no runtime).
pub const ChromeApp = struct {
    _pad: bool = false,
    _install_state: ChromeAppInstallState = .{},
    _running_state: ChromeAppRunningState = .{},

    pub fn isInstalled(_: *const ChromeApp) bool {
        return false;
    }

    pub fn getDetails(_: *const ChromeApp) ?bool {
        return null;
    }

    pub fn getIsInstalled(self: *const ChromeApp) bool {
        return self.isInstalled();
    }

    pub fn installState(_: *const ChromeApp) []const u8 {
        return "not_installed";
    }

    pub fn runningState(_: *const ChromeApp) []const u8 {
        return "cannot_run";
    }

    pub fn getInstallState(self: *ChromeApp) *ChromeAppInstallState {
        return &self._install_state;
    }

    pub fn getRunningState(self: *ChromeApp) *ChromeAppRunningState {
        return &self._running_state;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ChromeApp);

        pub const Meta = struct {
            pub const name = "ChromeApp";
            pub const own_properties = true;
            pub const empty_with_no_proto = true;
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // Chrome exposes isInstalled as a data property (boolean), not a method.
        // Function form is a common anti-detect / automation tell.
        pub const isInstalled = bridge.accessor(ChromeApp.isInstalled, null, .{});
        pub const getDetails = bridge.function(ChromeApp.getDetails, .{});
        pub const getIsInstalled = bridge.function(ChromeApp.getIsInstalled, .{});
        pub const installState = bridge.function(ChromeApp.installState, .{});
        pub const runningState = bridge.function(ChromeApp.runningState, .{});
        pub const InstallState = bridge.accessor(ChromeApp.getInstallState, null, .{ .deletable = false });
        pub const RunningState = bridge.accessor(ChromeApp.getRunningState, null, .{ .deletable = false });
    };
};

pub const ChromeAppInstallState = struct {
    pub const init: ChromeAppInstallState = .{};

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ChromeAppInstallState);

        pub const Meta = struct {
            pub const name = "ChromeAppInstallState";
            pub const own_properties = true;
            pub const empty_with_no_proto = true;
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const DISABLED = bridge.property("disabled", .{ .template = false, .readonly = true });
        pub const INSTALLED = bridge.property("installed", .{ .template = false, .readonly = true });
        pub const NOT_INSTALLED = bridge.property("not_installed", .{ .template = false, .readonly = true });
    };
};

pub const ChromeAppRunningState = struct {
    pub const init: ChromeAppRunningState = .{};

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ChromeAppRunningState);

        pub const Meta = struct {
            pub const name = "ChromeAppRunningState";
            pub const own_properties = true;
            pub const empty_with_no_proto = true;
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const CANNOT_RUN = bridge.property("cannot_run", .{ .template = false, .readonly = true });
        pub const READY_TO_RUN = bridge.property("ready_to_run", .{ .template = false, .readonly = true });
        pub const RUNNING = bridge.property("running", .{ .template = false, .readonly = true });
    };
};

const testing = @import("../../testing/testing.zig");

test "Chrome.csiPageT: epoch delta matches Chromium GetCSI" {
    const page_t = csiPageT(1_000_000.0, 0, 1_000_192);
    try testing.expectApproxEqAbs(@as(f64, 192.0), page_t, 0.001);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Chrome);

    pub const Meta = struct {
        pub const name = "Chrome";
        // Real Chrome exposes loadTimes/csi/app as own enumerable properties.
        pub const own_properties = true;
        pub const empty_with_no_proto = true;
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const app = bridge.accessor(Chrome.getApp, null, .{ .deletable = false });
    pub const loadTimes = bridge.function(Chrome.loadTimes, .{});
    pub const csi = bridge.function(Chrome.csi, .{});
};
