const std = @import("std");
const runtime_io = @import("../../support/io.zig");
const c = std.c;
const Profile = @import("Profile.zig");
const ProfilePaths = @import("ProfilePaths.zig");
const ProfileManager = @import("ProfileManager.zig");
const HostEnvironment = @import("HostEnvironment.zig");
const Spoofing = @import("Spoofing.zig");
const TransportProfile = @import("TransportProfile.zig");
const MeasureTextIntelligent = @import("MeasureTextIntelligent.zig");
const CanvasIntelligent = @import("CanvasIntelligent.zig");
const WebGLParameters = @import("WebGLParameters.zig");
const MathsNative = @import("MathsNative.zig");
const FingerprintStore = @import("FingerprintStore.zig");
const BrowserPersonaModule = @import("BrowserPersona.zig");
const BrowserPersona = BrowserPersonaModule.BrowserPersona;

fn appendPrint(list: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime format: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(text);
    try list.appendSlice(allocator, text);
}

fn resolveAssetPath(allocator: std.mem.Allocator, root: []const u8, path: []const u8) ![]const u8 {
    if (path.len == 0) return error.EmptyPath;
    if (std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\\') != null) {
        return error.AssetOutsideFingerprint;
    }
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return error.AssetOutsideFingerprint;
    }
    return try std.fs.path.join(allocator, &.{ root, path });
}

fn readAssetFile(allocator: std.mem.Allocator, root: []const u8, path: []const u8, limit: usize) ![]u8 {
    const resolved = try resolveAssetPath(allocator, root, path);
    defer allocator.free(resolved);
    return std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), resolved, allocator, .limited(limit));
}
const ClientRectsIntelligent = @import("ClientRectsIntelligent.zig");
const SvgIntelligent = @import("SvgIntelligent.zig");

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, override: c_int) c_int;

pub const Mode = enum {
    koko,
    antidetect,

    pub fn parse(raw: []const u8) ?Mode {
        if (std.mem.eql(u8, raw, "koko")) return .koko;
        if (std.mem.eql(u8, raw, "antidetect")) return .antidetect;
        return null;
    }
};

pub const BrowserFamily = BrowserPersona.Family;
pub const Brand = BrowserPersona.Brand;

pub const PluginSpec = BrowserPersona.PluginSpec;

pub const SpeechVoiceSpec = struct {
    name: []const u8,
    lang: []const u8,
    voice_uri: []const u8,
    local_service: bool,
    default_voice: bool,
};

pub const LoadedProfile = struct {
    arena: std.heap.ArenaAllocator,
    mode: Mode,
    id: []const u8,
    persona: BrowserPersona,
    languages: []const []const u8,
    fonts: []const []const u8,
    webgl_extensions: []const []const u8,
    webgl_extensions2: []const []const u8 = &.{},
    plugins: []const PluginSpec,
    /// Chrome-captured data URL for the standard 240×60 canvas probe (antidetect only).
    canvas_probe_data_url: ?[]const u8 = null,
    canvas_probe_50_text: ?[]const u8 = null,
    canvas_probe_50_emoji: ?[]const u8 = null,
    canvas_probe_75_data: ?[]const u8 = null,
    canvas_probe_75_paint: ?[]const u8 = null,
    canvas_probe_75_paint_cpu: ?[]const u8 = null,
    canvas_probe_mods_pixel_image: ?[]const u8 = null,
    canvas_probe_2_pixels: ?[]const u8 = null,
    /// Chrome-captured OfflineAudioContext probe (5000 samples + FFT bins).
    audio_probe_samples: ?[]const f32 = null,
    audio_probe_freq: ?[]const f32 = null,
    audio_probe_time_domain: ?[]const f32 = null,
    speech_voices: []const SpeechVoiceSpec = &.{},
    measure_text_baseline: []const MeasureTextIntelligent.Entry = &.{},
    webgl_probe_read_width: i32 = 0,
    webgl_probe_read_height: i32 = 0,
    webgl_probe_pixels: ?[]const u8 = null,
    webgl_probe_pixels2: ?[]const u8 = null,
    webgl_probe_data_uri: ?[]const u8 = null,
    webgl_probe_data_uri2: ?[]const u8 = null,
    webgl_probe_parameters: WebGLParameters.Map = .empty,
    window_keys: []const []const u8 = &.{},
    navigator_keys: []const []const u8 = &.{},
    html_element_keys: []const []const u8 = &.{},
    css_computed_keys: []const []const u8 = &.{},
    css_computed_indexed_keys: []const []const u8 = &.{},
    css_computed_named_keys: []const []const u8 = &.{},
    /// Full merged key list for CSSStyleDeclaration `in`/named getter parity (creep alias expansion).
    css_computed_in_keys: []const []const u8 = &.{},
    maths_baseline: []const MathsNative.Entry = &.{},
    client_rects: []const ClientRectsIntelligent.Rect = &.{},
    client_rects_emoji_dims: []const ClientRectsIntelligent.EmojiDim = &.{},
    svg_baseline: SvgIntelligent.Baseline = .{},
    /// Site policy ids enabled for this profile (e.g. "google-search").
    policies: []const []const u8 = &.{},

    pub fn hasPolicy(self: *const LoadedProfile, policy_id: []const u8) bool {
        for (self.policies) |id| {
            if (std.mem.eql(u8, id, policy_id)) return true;
        }
        return false;
    }

    pub fn deinit(self: *LoadedProfile) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn identityPtr(self: *const LoadedProfile) *const Profile.IdentityProfile {
        return &self.persona.identity;
    }

    pub fn allowsMozillaUserAgent(self: *const LoadedProfile) bool {
        return self.mode == .antidetect;
    }

    pub fn isFirefox(self: *const LoadedProfile) bool {
        return self.persona.family == .firefox;
    }

    pub fn isSafari(self: *const LoadedProfile) bool {
        return self.persona.family == .safari;
    }

    /// Chrome/Chromium client-hints + X-Browser + ML-DSA knobs.
    pub fn isChromium(self: *const LoadedProfile) bool {
        return self.persona.family == .chrome;
    }

    pub fn canvas_probe_data_url_for(self: *const LoadedProfile, probe: CanvasIntelligent.ProbeId) ?[]const u8 {
        return switch (probe) {
            .canvas_240_koko => self.canvas_probe_data_url,
            .canvas_50_text => self.canvas_probe_50_text,
            .canvas_50_emoji => self.canvas_probe_50_emoji,
            .canvas_75_data => self.canvas_probe_75_data,
            .canvas_75_paint => self.canvas_probe_75_paint,
            .canvas_75_paint_cpu => self.canvas_probe_75_paint_cpu,
            .canvas_mods_pixel_image => self.canvas_probe_mods_pixel_image,
            else => null,
        };
    }

    pub fn canvas_image_data_for(self: *const LoadedProfile, probe: CanvasIntelligent.ProbeId) ?[]const u8 {
        return switch (probe) {
            .canvas_2_low_entropy => self.canvas_probe_2_pixels,
            else => null,
        };
    }
};

const JsonBrand = struct {
    brand: []const u8,
    version: []const u8,
};

const JsonNavigator = struct {
    userAgent: []const u8,
    platform: []const u8,
    languages: []const []const u8,
    hardwareConcurrency: u32,
    deviceMemory: f64,
    maxTouchPoints: u32,
    vendor: []const u8,
    pdfViewerEnabled: bool = true,
    appVersion: []const u8 = "1.0",
};

const JsonUserAgentData = struct {
    brands: []const JsonBrand,
    platform: []const u8,
    platformVersion: []const u8 = "",
    architecture: []const u8,
    bitness: []const u8,
    uaFullVersion: []const u8 = "1.0.0.0",
    fullVersionList: []const JsonBrand = &.{},
    mobile: bool = false,
    prefersColorScheme: []const u8 = "light",
};

const JsonScreen = struct {
    width: u32,
    height: u32,
    availWidth: u32,
    availHeight: u32,
    devicePixelRatio: f64,
    colorDepth: u8,
    pixelDepth: u8,
    touch: bool = false,
};

const JsonWindow = struct {
    innerWidth: u32,
    innerHeight: u32,
    outerWidth: u32,
    outerHeight: u32,
};

const JsonWebGL = struct {
    version: []const u8,
    vendor: []const u8,
    renderer: []const u8,
    shadingLanguageVersion: []const u8,
    unmaskedVendor: []const u8,
    unmaskedRenderer: []const u8,
    maxTextureSize: u32 = 16384,
    maxCubeMapTextureSize: u32 = 16384,
    maxRenderbufferSize: u32 = 16384,
    maxVertexAttribs: u32 = 16,
    maxVertexUniformVectors: u32 = 4096,
    maxVaryingVectors: u32 = 31,
    maxCombinedTextureImageUnits: u32 = 32,
    maxVertexTextureImageUnits: u32 = 16,
    maxTextureImageUnits: u32 = 16,
    maxFragmentUniformVectors: u32 = 1024,
    maxDrawBuffers: u32 = 8,
    maxColorAttachmentsWebGL2: u32 = 8,
    maxSamplesWebGL2: u32 = 4,
    max3dTextureSizeWebGL2: u32 = 2048,
    maxArrayTextureLayersWebGL2: u32 = 2048,
    maxTextureMaxAnisotropy: u32 = 16,
    maxViewportDims: [2]i32 = .{ 16384, 16384 },
    aliasedLineWidthRange: [2]f32 = .{ 1, 1 },
    aliasedPointSizeRange: [2]f32 = .{ 1, 1024 },
    extensions: []const []const u8,
    extensions2: []const []const u8 = &.{},
};

const JsonTransport = struct {
    impersonate: []const u8 = "",
};

const JsonPlugin = struct {
    name: []const u8,
    filename: []const u8,
    description: []const u8 = "",
    mimeType: []const u8,
    mimeSuffixes: []const u8 = "pdf",
};

const JsonCanvasProbe = struct {
    dataUrl: []const u8 = "",
    dataUrlFile: []const u8 = "",
    probesFile: []const u8 = "",
};

const JsonAudioProbe = struct {
    dataFile: []const u8 = "",
};

const JsonMeasureTextBaseline = struct {
    dataFile: []const u8 = "",
};

const JsonMeasureTextEntry = struct {
    family: []const u8,
    font: ?[]const u8 = null,
    text: []const u8,
    width: f64,
    actualBoundingBoxLeft: f64 = 0,
    actualBoundingBoxRight: f64 = 0,
    actualBoundingBoxAscent: f64 = 0,
    actualBoundingBoxDescent: f64 = 0,
    fontBoundingBoxAscent: f64 = 0,
    fontBoundingBoxDescent: f64 = 0,
};

const JsonWebGLProbe = struct {
    dataFile: []const u8 = "",
};

const JsonWindowKeys = struct {
    dataFile: []const u8 = "",
};

const JsonNavigatorKeys = struct {
    dataFile: []const u8 = "",
};

const JsonHtmlElementKeys = struct {
    dataFile: []const u8 = "",
};

const JsonCssComputedKeys = struct {
    dataFile: []const u8 = "",
    enumerableKeysFile: []const u8 = "",
};

const JsonCssEnumerableKeys = struct {
    indexed: []const []const u8 = &.{},
    named: []const []const u8 = &.{},
};

const JsonMathsBaseline = struct {
    dataFile: []const u8 = "",
};

const JsonClientRectsBaseline = struct {
    dataFile: []const u8 = "",
};

const JsonSvgBaseline = struct {
    dataFile: []const u8 = "",
};

const JsonClientRectEntry = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

const JsonEmojiDimEntry = struct {
    w: f64,
    h: f64,
};

const JsonMathsBaselineEntry = struct {
    method: []const u8,
    args: []std.json.Value,
    result: f64,
};

const JsonAudioBaseline = struct {
    samples: []const f64,
    freq: []const f64,
    timeDomain: []const f64 = &.{},
    tailSum: f64 = 0,
};

const JsonSpeechVoice = struct {
    name: []const u8,
    lang: []const u8,
    voiceURI: ?[]const u8 = null,
    localService: bool = true,
    default: bool = false,
};

const JsonProfile = struct {
    version: u32,
    id: []const u8,
    mode: []const u8,
    browserFamily: []const u8 = "",
    personaId: []const u8 = "",
    navigator: JsonNavigator,
    userAgentData: JsonUserAgentData,
    screen: JsonScreen,
    window: ?JsonWindow = null,
    webgl: JsonWebGL,
    fonts: []const []const u8 = &.{},
    fontsFile: []const u8 = "",
    timezone: []const u8,
    locale: []const u8,
    transport: JsonTransport = .{},
    plugins: []const JsonPlugin = &.{},
    canvasProbe: JsonCanvasProbe = .{},
    audioProbe: JsonAudioProbe = .{},
    speechVoicesFile: []const u8 = "",
    measureTextBaseline: JsonMeasureTextBaseline = .{},
    webglProbe: JsonWebGLProbe = .{},
    windowKeys: JsonWindowKeys = .{},
    navigatorKeys: JsonNavigatorKeys = .{},
    htmlElementKeys: JsonHtmlElementKeys = .{},
    cssComputedKeys: JsonCssComputedKeys = .{},
    mathsBaseline: JsonMathsBaseline = .{},
    clientRectsBaseline: JsonClientRectsBaseline = .{},
    svgBaseline: JsonSvgBaseline = .{},
    policies: []const []const u8 = &.{},
};

pub fn resolve(paths: *const ProfilePaths.ProfilePaths) !LoadedProfile {
    var fp_src = try FingerprintStore.resolve(
        std.heap.page_allocator,
        paths,
        paths.fingerprint_override,
    );
    defer fp_src.deinit(std.heap.page_allocator);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), fp_src.definition_path, std.heap.page_allocator, .limited(1024 * 1024));
    defer std.heap.page_allocator.free(bytes);

    var loaded = try parseJson(bytes, fp_src.root);
    if (fp_src.id.len > 0 and !std.mem.eql(u8, loaded.id, fp_src.id)) {
        loaded.deinit();
        return error.FingerprintIdMismatch;
    }
    try applyHostEnvironment(&loaded);
    applyProcessTimezone(&loaded);
    return loaded;
}

/// Apply a startup UA overlay to the persona itself so JavaScript, HTTP,
/// WebSocket and header plugins observe one value. A full override is accepted
/// only when it still describes the selected persona's Chrome build/platform;
/// changing browser identity requires importing a matching fingerprint.
pub fn applyUserAgentOverlay(
    profile: *LoadedProfile,
    explicit: ?[]const u8,
    suffix: ?[]const u8,
) !void {
    if (explicit != null and suffix != null) return error.ConflictingUserAgentOptions;
    if (explicit == null and suffix == null) return;

    const allocator = profile.arena.allocator();
    const candidate = if (explicit) |ua|
        try allocator.dupeZ(u8, ua)
    else
        try std.fmt.allocPrintSentinel(
            allocator,
            "{s} {s}",
            .{ profile.persona.network.user_agent, suffix.? },
            0,
        );

    if (explicit != null) {
        const current = Spoofing.extractChromeVersion(profile.persona.network.user_agent) orelse
            return error.PersonaUserAgentOverrideInconsistent;
        const replacement = Spoofing.extractChromeVersion(candidate) orelse
            return error.PersonaUserAgentOverrideInconsistent;
        if (current.major != replacement.major or
            !Spoofing.uaPlatformMatchesNavigator(candidate, profile.persona.identity.navigator_platform))
            return error.PersonaUserAgentOverrideInconsistent;
    }

    profile.persona.network.user_agent = candidate;
    profile.persona.identity.user_agent_fallback = candidate;
    try profile.persona.validate();
}

fn applyHostEnvironment(profile: *LoadedProfile) !void {
    if (profile.mode != .antidetect) return;
    var snap = HostEnvironment.detect(profile.arena.allocator()) catch return;
    // Antidetect JSON is authoritative for fingerprint surface; host probes are only
    // for optional GPU renderer alignment (same machine as the cloned browser).
    snap.screen = null;
    snap.window = null;
    snap.device_memory = null;
    snap.hardware_concurrency = null;
    snap.timezone = null;
    try HostEnvironment.applyIdentity(&profile.persona.identity, snap, profile.arena.allocator());
    try profile.persona.validate();
}

fn applyProcessTimezone(profile: *const LoadedProfile) void {
    const tz = profile.persona.identity.timezone;
    if (tz.len == 0 or tz.len >= 96) return;
    var buf: [96:0]u8 = undefined;
    @memcpy(buf[0..tz.len], tz);
    buf[tz.len] = 0;
    _ = setenv("TZ", &buf, 1);
}

fn fromEmbedded(name: ?[]const u8) !LoadedProfile {
    _ = name;
    const src = Profile.defaultIdentity();
    var profile: LoadedProfile = .{
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .mode = .koko,
        .id = "koko",
        .persona = undefined,
        .languages = src.languages,
        .fonts = src.fonts,
        .webgl_extensions = src.webgl.extensions,
        .plugins = &.{},
        .policies = &.{},
    };
    errdefer profile.deinit();

    const allocator = profile.arena.allocator();
    profile.id = try allocator.dupe(u8, "koko");
    const user_agent = try allocator.dupeZ(u8, src.user_agent_fallback);
    const brands = try allocator.alloc(Brand, 1);
    brands[0] = .{ .brand = "Koko", .version = "1" };
    const transport_target = TransportProfile.Target.chrome146;
    profile.persona = .{
        .family = BrowserFamily.inferFromUserAgent(user_agent),
        .version = BrowserPersona.Version.fromIdentity(
            BrowserFamily.inferFromUserAgent(user_agent),
            user_agent,
            src.ua_full_version,
        ),
        .identity = src.*,
        .network = .{
            .user_agent = user_agent,
            .brands = brands,
            .sec_ch_ua = try buildSecChUa(allocator, brands),
            .accept_language = try buildAcceptLanguage(allocator, src.languages),
            .prefers_color_scheme = "light",
            .transport_target = transport_target,
            .impersonate = try allocator.dupeZ(u8, transport_target.curlImpersonate()),
        },
        .features = BrowserPersona.FeatureMatrix.forIdentity(
            BrowserFamily.inferFromUserAgent(user_agent),
            user_agent,
        ),
        .surfaces = .{ .plugins = profile.plugins },
    };
    try profile.persona.validate();
    profile.plugins = &.{};
    return profile;
}

fn parseJson(bytes: []const u8, asset_root: []const u8) !LoadedProfile {
    var parsed = try std.json.parseFromSlice(JsonProfile, std.heap.page_allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const doc = parsed.value;
    const mode = Mode.parse(doc.mode) orelse return error.InvalidProfile;
    if (doc.version != 1) return error.UnsupportedProfileVersion;
    if (doc.navigator.languages.len == 0) return error.InvalidProfile;
    const browser_family = if (doc.browserFamily.len > 0)
        BrowserFamily.parse(doc.browserFamily) orelse return error.InvalidProfile
    else
        BrowserFamily.inferFromUserAgent(doc.navigator.userAgent);

    if (browser_family == .chrome and doc.userAgentData.brands.len == 0) return error.InvalidProfile;

    try validateAntidetect(mode, doc.navigator.userAgent, doc.userAgentData.brands, browser_family);
    if (mode == .antidetect and browser_family == .chrome) {
        try Spoofing.validateAntidetectConsistency(
            doc.navigator.userAgent,
            @as([]const Spoofing.Brand, @ptrCast(doc.userAgentData.brands)),
            doc.userAgentData.uaFullVersion,
        );
        if (!Spoofing.fullVersionListMatches(
            doc.userAgentData.uaFullVersion,
            @as([]const Spoofing.Brand, @ptrCast(doc.userAgentData.fullVersionList)),
        )) return error.InvalidProfile;
        if (!Spoofing.uaPlatformMatchesNavigator(doc.navigator.userAgent, doc.navigator.platform)) {
            return error.InvalidProfile;
        }
        if (!Spoofing.uaChPlatformMatchesNavigator(doc.navigator.platform, doc.userAgentData.platform)) {
            return error.InvalidProfile;
        }
        if (!Spoofing.uaChArchitectureMatchesPlatform(doc.navigator.platform, doc.userAgentData.architecture)) {
            return error.InvalidProfile;
        }
        if (!Spoofing.touchMatchesUserAgent(doc.navigator.userAgent, doc.navigator.maxTouchPoints)) {
            return error.InvalidProfile;
        }
        if (!Spoofing.pdfViewerMatchesPlugins(doc.navigator.pdfViewerEnabled, doc.plugins.len)) {
            return error.InvalidProfile;
        }
    }

    var profile: LoadedProfile = .{
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .mode = mode,
        .id = "",
        .persona = undefined,
        .languages = &.{},
        .fonts = &.{},
        .webgl_extensions = &.{},
        .plugins = &.{},
    };
    errdefer profile.deinit();

    const allocator = profile.arena.allocator();
    profile.id = try allocator.dupe(u8, doc.id);
    profile.policies = try dupeStringList(allocator, doc.policies);

    profile.languages = try dupeStringList(allocator, doc.navigator.languages);
    profile.fonts = try loadFonts(allocator, asset_root, doc.fonts, doc.fontsFile);
    profile.webgl_extensions = try dupeStringList(allocator, doc.webgl.extensions);
    profile.webgl_extensions2 = if (doc.webgl.extensions2.len > 0)
        try dupeStringList(allocator, doc.webgl.extensions2)
    else
        &.{};

    const user_agent = try allocator.dupeZ(u8, doc.navigator.userAgent);
    const brands = try allocator.alloc(Brand, doc.userAgentData.brands.len);
    for (doc.userAgentData.brands, 0..) |brand, i| {
        brands[i] = .{
            .brand = try allocator.dupe(u8, brand.brand),
            .version = try allocator.dupe(u8, brand.version),
        };
    }
    const sec_ch_ua = try buildSecChUa(allocator, brands);
    const accept_language = try buildAcceptLanguage(allocator, doc.navigator.languages);
    const prefers_color_scheme = try allocator.dupe(u8, doc.userAgentData.prefersColorScheme);

    const transport_target = TransportProfile.Target.resolve(
        if (doc.transport.impersonate.len > 0) doc.transport.impersonate else null,
        doc.navigator.userAgent,
    );

    const impersonate = try allocator.dupeZ(u8, transport_target.curlImpersonate());

    profile.plugins = if (doc.plugins.len > 0)
        try parsePlugins(allocator, doc.plugins)
    else
        &.{};

    const identity: Profile.IdentityProfile = .{
        .persona_id = try parsePersonaId(doc.personaId, doc.navigator.platform),
        .navigator_platform = try allocator.dupe(u8, doc.navigator.platform),
        .ua_data_platform = try allocator.dupe(u8, doc.userAgentData.platform),
        .ua_architecture = try allocator.dupe(u8, doc.userAgentData.architecture),
        .ua_bitness = try allocator.dupe(u8, doc.userAgentData.bitness),
        .locale = try allocator.dupe(u8, doc.locale),
        .languages = profile.languages,
        .timezone = try allocator.dupe(u8, doc.timezone),
        .hardware_concurrency = doc.navigator.hardwareConcurrency,
        .device_memory = doc.navigator.deviceMemory,
        .max_touch_points = doc.navigator.maxTouchPoints,
        .pdf_viewer_enabled = doc.navigator.pdfViewerEnabled,
        .global_privacy_control = false,
        .vendor = try allocator.dupe(u8, doc.navigator.vendor),
        .user_agent_fallback = user_agent,
        .app_version = try allocator.dupe(u8, doc.navigator.appVersion),
        .platform_version = try allocator.dupe(u8, doc.userAgentData.platformVersion),
        .ua_full_version = try allocator.dupe(u8, doc.userAgentData.uaFullVersion),
        .ua_mobile = doc.userAgentData.mobile,
        .screen = .{
            .width = doc.screen.width,
            .height = doc.screen.height,
            .avail_width = doc.screen.availWidth,
            .avail_height = doc.screen.availHeight,
            .device_pixel_ratio = doc.screen.devicePixelRatio,
            .color_depth = doc.screen.colorDepth,
            .pixel_depth = doc.screen.pixelDepth,
            .touch = doc.screen.touch,
        },
        .window = if (doc.window) |win| .{
            .inner_width = win.innerWidth,
            .inner_height = win.innerHeight,
            .outer_width = win.outerWidth,
            .outer_height = win.outerHeight,
        } else Profile.defaultWindowForScreen(.{
            .width = doc.screen.width,
            .height = doc.screen.height,
            .avail_width = doc.screen.availWidth,
            .avail_height = doc.screen.availHeight,
            .device_pixel_ratio = doc.screen.devicePixelRatio,
            .color_depth = doc.screen.colorDepth,
            .pixel_depth = doc.screen.pixelDepth,
            .touch = doc.screen.touch,
        }),
        .webgl = .{
            .version = try allocator.dupe(u8, doc.webgl.version),
            .vendor = try allocator.dupe(u8, doc.webgl.vendor),
            .renderer = try allocator.dupe(u8, doc.webgl.renderer),
            .shading_language_version = try allocator.dupe(u8, doc.webgl.shadingLanguageVersion),
            .unmasked_vendor = try allocator.dupe(u8, doc.webgl.unmaskedVendor),
            .unmasked_renderer = try allocator.dupe(u8, doc.webgl.unmaskedRenderer),
            .max_texture_size = doc.webgl.maxTextureSize,
            .max_cube_map_texture_size = doc.webgl.maxCubeMapTextureSize,
            .max_renderbuffer_size = doc.webgl.maxRenderbufferSize,
            .max_vertex_attribs = doc.webgl.maxVertexAttribs,
            .max_vertex_uniform_vectors = doc.webgl.maxVertexUniformVectors,
            .max_varying_vectors = doc.webgl.maxVaryingVectors,
            .max_combined_texture_image_units = doc.webgl.maxCombinedTextureImageUnits,
            .max_vertex_texture_image_units = doc.webgl.maxVertexTextureImageUnits,
            .max_texture_image_units = doc.webgl.maxTextureImageUnits,
            .max_fragment_uniform_vectors = doc.webgl.maxFragmentUniformVectors,
            .max_draw_buffers = doc.webgl.maxDrawBuffers,
            .max_color_attachments_webgl2 = doc.webgl.maxColorAttachmentsWebGL2,
            .max_samples_webgl2 = doc.webgl.maxSamplesWebGL2,
            .max_3d_texture_size_webgl2 = doc.webgl.max3dTextureSizeWebGL2,
            .max_array_texture_layers_webgl2 = doc.webgl.maxArrayTextureLayersWebGL2,
            .max_texture_max_anisotropy = doc.webgl.maxTextureMaxAnisotropy,
            .max_viewport_dims = doc.webgl.maxViewportDims,
            .aliased_line_width_range = doc.webgl.aliasedLineWidthRange,
            .aliased_point_size_range = doc.webgl.aliasedPointSizeRange,
            .extensions = profile.webgl_extensions,
            .extensions_webgl2 = profile.webgl_extensions2,
        },
        .fonts = profile.fonts,
    };

    profile.persona = .{
        .family = browser_family,
        .version = BrowserPersona.Version.fromIdentity(
            browser_family,
            user_agent,
            identity.ua_full_version,
        ),
        .identity = identity,
        .network = .{
            .user_agent = user_agent,
            .brands = brands,
            .sec_ch_ua = sec_ch_ua,
            .accept_language = accept_language,
            .prefers_color_scheme = prefers_color_scheme,
            .transport_target = transport_target,
            .impersonate = impersonate,
        },
        .features = BrowserPersona.FeatureMatrix.forIdentity(browser_family, user_agent),
        .surfaces = .{ .plugins = profile.plugins },
    };

    profile.canvas_probe_data_url = try loadCanvasProbe(allocator, asset_root, doc.canvasProbe);
    try loadCanvasProbes(allocator, asset_root, doc.canvasProbe, &profile);
    try loadAudioProbe(allocator, asset_root, doc.audioProbe, &profile);
    profile.speech_voices = try loadSpeechVoices(allocator, asset_root, doc.speechVoicesFile);
    profile.measure_text_baseline = try loadMeasureTextBaseline(allocator, asset_root, doc.measureTextBaseline);
    try loadWebGLProbe(allocator, asset_root, doc.webglProbe, &profile);
    profile.window_keys = try loadWindowKeys(allocator, asset_root, doc.windowKeys);
    profile.navigator_keys = try loadNavigatorKeys(allocator, asset_root, doc.navigatorKeys);
    profile.html_element_keys = try loadHtmlElementKeys(allocator, asset_root, doc.htmlElementKeys);
    try loadCssComputedKeys(allocator, asset_root, doc.cssComputedKeys, &profile);
    profile.maths_baseline = try loadMathsBaseline(allocator, asset_root, doc.mathsBaseline);
    try loadClientRectsBaseline(allocator, asset_root, doc.clientRectsBaseline, &profile);
    try loadSvgBaseline(allocator, asset_root, doc.svgBaseline, &profile);

    profile.persona.surfaces.has_canvas_probe = hasCanvasProbe(&profile);
    profile.persona.surfaces.has_audio_probe =
        profile.audio_probe_samples != null and profile.audio_probe_freq != null;
    profile.persona.surfaces.has_webgl_probe =
        profile.webgl_probe_pixels != null or profile.webgl_probe_pixels2 != null;
    try profile.persona.validate();
    try validateProbeConsistency(&profile);
    return profile;
}

fn validateProbeConsistency(profile: *const LoadedProfile) !void {
    const has_canvas_probe = hasCanvasProbe(profile);
    if (has_canvas_probe and profile.fonts.len == 0)
        return error.PersonaCanvasFontsMismatch;

    if (profile.webgl_probe_pixels != null and
        (profile.webgl_probe_read_width <= 0 or profile.webgl_probe_read_height <= 0))
        return error.PersonaWebGlProbeDimensionsInvalid;

    const has_audio_samples = profile.audio_probe_samples != null;
    const has_audio_frequency = profile.audio_probe_freq != null;
    if (has_audio_samples != has_audio_frequency)
        return error.PersonaAudioProbeIncomplete;
}

fn hasCanvasProbe(profile: *const LoadedProfile) bool {
    return profile.canvas_probe_data_url != null or
        profile.canvas_probe_50_text != null or
        profile.canvas_probe_50_emoji != null or
        profile.canvas_probe_75_data != null or
        profile.canvas_probe_75_paint != null or
        profile.canvas_probe_2_pixels != null;
}

fn loadMeasureTextBaseline(allocator: std.mem.Allocator, root: []const u8, spec: JsonMeasureTextBaseline) ![]const MeasureTextIntelligent.Entry {
    if (spec.dataFile.len == 0) return &.{};
    const bytes = try readAssetFile(allocator, root, spec.dataFile, 32 * 1024 * 1024);
    const parsed = try std.json.parseFromSlice([]const JsonMeasureTextEntry, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const src = parsed.value;
    const out = try allocator.alloc(MeasureTextIntelligent.Entry, src.len);
    for (src, 0..) |e, i| {
        const font = if (e.font) |f| try allocator.dupe(u8, f) else null;
        out[i] = .{
            .family = try allocator.dupe(u8, e.family),
            .font = font,
            .text = try allocator.dupe(u8, e.text),
            .width = e.width,
            .actual_bounding_box_left = e.actualBoundingBoxLeft,
            .actual_bounding_box_right = e.actualBoundingBoxRight,
            .actual_bounding_box_ascent = e.actualBoundingBoxAscent,
            .actual_bounding_box_descent = e.actualBoundingBoxDescent,
            .font_bounding_box_ascent = e.fontBoundingBoxAscent,
            .font_bounding_box_descent = e.fontBoundingBoxDescent,
        };
    }
    return out;
}

fn loadWebGLProbe(allocator: std.mem.Allocator, asset_root: []const u8, probe: JsonWebGLProbe, profile: *LoadedProfile) !void {
    if (probe.dataFile.len == 0) return;
    const bytes = readAssetFile(allocator, asset_root, probe.dataFile, 4 * 1024 * 1024) catch return;
    defer allocator.free(bytes);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };

    const pixels_val = root.get("pixels") orelse return;
    const pixels = try jsonU8Slice(allocator, pixels_val);
    if (pixels.len == 0) return;

    profile.webgl_probe_pixels = pixels;
    profile.webgl_probe_read_width = jsonI32(root.get("readWidth"), 0);
    profile.webgl_probe_read_height = jsonI32(root.get("readHeight"), 0);
    if (root.get("pixels2")) |pixels2_val| {
        const pixels2 = try jsonU8Slice(allocator, pixels2_val);
        if (pixels2.len > 0) profile.webgl_probe_pixels2 = pixels2;
    }
    if (root.get("dataURI")) |uri_val| {
        if (uri_val == .string and uri_val.string.len > 0) {
            profile.webgl_probe_data_uri = try allocator.dupe(u8, uri_val.string);
        }
    }
    if (root.get("dataURI2")) |uri_val| {
        if (uri_val == .string and uri_val.string.len > 0) {
            profile.webgl_probe_data_uri2 = try allocator.dupe(u8, uri_val.string);
        }
    }
    try WebGLParameters.loadFromJsonObject(allocator, root.get("parameters"), &profile.webgl_probe_parameters);
}

fn jsonI32(value: ?std.json.Value, default: i32) i32 {
    const v = value orelse return default;
    return switch (v) {
        .integer => |i| @intCast(i),
        .float => |f| @intFromFloat(f),
        else => default,
    };
}

fn jsonU8Slice(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    const arr = switch (value) {
        .array => |a| a,
        else => return &.{},
    };
    const out = try allocator.alloc(u8, arr.items.len);
    for (arr.items, 0..) |item, i| {
        out[i] = switch (item) {
            .integer => |n| @intCast(n),
            .float => |f| @intFromFloat(f),
            else => 0,
        };
    }
    return out;
}

fn loadWindowKeys(allocator: std.mem.Allocator, root: []const u8, spec: JsonWindowKeys) ![]const []const u8 {
    if (spec.dataFile.len == 0) return &.{};
    const bytes = try readAssetFile(allocator, root, spec.dataFile, 8 * 1024 * 1024);
    const parsed = try std.json.parseFromSlice([]const []const u8, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return dupeStringList(allocator, parsed.value);
}

fn loadNavigatorKeys(allocator: std.mem.Allocator, root: []const u8, spec: JsonNavigatorKeys) ![]const []const u8 {
    if (spec.dataFile.len == 0) return &.{};
    const bytes = try readAssetFile(allocator, root, spec.dataFile, 8 * 1024 * 1024);
    const parsed = try std.json.parseFromSlice([]const []const u8, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return dupeStringList(allocator, parsed.value);
}

fn loadCssComputedKeys(allocator: std.mem.Allocator, root: []const u8, spec: JsonCssComputedKeys, profile: *LoadedProfile) !void {
    if (spec.enumerableKeysFile.len > 0) {
        const bytes = try readAssetFile(allocator, root, spec.enumerableKeysFile, 8 * 1024 * 1024);
        const parsed = try std.json.parseFromSlice(JsonCssEnumerableKeys, allocator, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        profile.css_computed_indexed_keys = try dupeStringList(allocator, parsed.value.indexed);
        profile.css_computed_named_keys = try dupeStringList(allocator, parsed.value.named);
    }
    if (spec.dataFile.len > 0) {
        const bytes = try readAssetFile(allocator, root, spec.dataFile, 8 * 1024 * 1024);
        const parsed = try std.json.parseFromSlice([]const []const u8, allocator, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        profile.css_computed_keys = try dupeStringList(allocator, parsed.value);
        profile.css_computed_in_keys = profile.css_computed_keys;
        return;
    }
    if (profile.css_computed_indexed_keys.len > 0 or profile.css_computed_named_keys.len > 0) {
        profile.css_computed_in_keys = profile.css_computed_named_keys;
    }
}

fn loadHtmlElementKeys(allocator: std.mem.Allocator, root: []const u8, spec: JsonHtmlElementKeys) ![]const []const u8 {
    if (spec.dataFile.len == 0) return &.{};
    const bytes = try readAssetFile(allocator, root, spec.dataFile, 8 * 1024 * 1024);
    const parsed = try std.json.parseFromSlice([]const []const u8, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return dupeStringList(allocator, parsed.value);
}

fn loadClientRectsBaseline(allocator: std.mem.Allocator, asset_root: []const u8, spec: JsonClientRectsBaseline, profile: *LoadedProfile) !void {
    if (spec.dataFile.len == 0) return;
    const bytes = readAssetFile(allocator, asset_root, spec.dataFile, 8 * 1024 * 1024) catch return;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };

    if (root.get("elementClientRects")) |rects_val| {
        const arr = switch (rects_val) {
            .array => |a| a,
            else => return,
        };
        const out = try allocator.alloc(ClientRectsIntelligent.Rect, arr.items.len);
        for (arr.items, 0..) |item, i| {
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            out[i] = .{
                .x = jsonF64(obj.get("x"), 0),
                .y = jsonF64(obj.get("y"), 0),
                .width = jsonF64(obj.get("width"), 0),
                .height = jsonF64(obj.get("height"), 0),
            };
        }
        profile.client_rects = out;
    }

    if (root.get("emojiDims")) |dims_val| {
        const arr = switch (dims_val) {
            .array => |a| a,
            else => return,
        };
        const out = try allocator.alloc(ClientRectsIntelligent.EmojiDim, arr.items.len);
        for (arr.items, 0..) |item, i| {
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            out[i] = .{
                .w = jsonF64(obj.get("w"), 0),
                .h = jsonF64(obj.get("h"), 0),
            };
        }
        profile.client_rects_emoji_dims = out;
    }
}

fn loadSvgBaseline(allocator: std.mem.Allocator, asset_root: []const u8, spec: JsonSvgBaseline, profile: *LoadedProfile) !void {
    if (spec.dataFile.len == 0) return;
    const bytes = readAssetFile(allocator, asset_root, spec.dataFile, 8 * 1024 * 1024) catch return;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };

    if (root.get("bBox")) |bbox_val| {
        if (bbox_val == .object) {
            const obj = bbox_val.object;
            profile.svg_baseline.b_box = .{
                .x = jsonF64(obj.get("x"), 0),
                .y = jsonF64(obj.get("y"), 0),
                .width = jsonF64(obj.get("width"), 0),
                .height = jsonF64(obj.get("height"), 0),
            };
        }
    }
    profile.svg_baseline.computed_text_length = jsonF64(root.get("computedTextLength"), 0);
    profile.svg_baseline.sub_string_length = jsonF64(root.get("subStringLength"), 0);
    if (root.get("extentOfChar")) |ext_val| {
        if (ext_val == .object) {
            const obj = ext_val.object;
            profile.svg_baseline.extent_of_char = .{
                .x = jsonF64(obj.get("x"), 0),
                .y = jsonF64(obj.get("y"), 0),
                .width = jsonF64(obj.get("width"), 0),
                .height = jsonF64(obj.get("height"), 0),
            };
        }
    }
    if (root.get("perEmojiComputedTextLength")) |arr_val| {
        const arr = switch (arr_val) {
            .array => |a| a,
            else => return,
        };
        const out = try allocator.alloc(f64, arr.items.len);
        for (arr.items, 0..) |item, i| {
            out[i] = jsonF64(item, 0);
        }
        profile.svg_baseline.per_emoji_computed_text_length = out;
    }
    if (root.get("perEmojiNumberOfChars")) |arr_val| {
        const arr = switch (arr_val) {
            .array => |a| a,
            else => return,
        };
        const out = try allocator.alloc(i32, arr.items.len);
        for (arr.items, 0..) |item, i| {
            out[i] = @intFromFloat(jsonF64(item, 0));
        }
        profile.svg_baseline.per_emoji_number_of_chars = out;
    }
}

fn jsonF64(value: ?std.json.Value, default: f64) f64 {
    const v = value orelse return default;
    return switch (v) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => default,
    };
}

fn loadMathsBaseline(allocator: std.mem.Allocator, root: []const u8, spec: JsonMathsBaseline) ![]const MathsNative.Entry {
    if (spec.dataFile.len == 0) return &.{};
    const bytes = try readAssetFile(allocator, root, spec.dataFile, 8 * 1024 * 1024);
    const parsed = try std.json.parseFromSlice([]const JsonMathsBaselineEntry, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const src = parsed.value;
    const out = try allocator.alloc(MathsNative.Entry, src.len);
    for (src, 0..) |e, i| {
        out[i] = .{
            .method = try allocator.dupe(u8, e.method),
            .args = try loadMathsArgs(allocator, e.args),
            .result = e.result,
        };
    }
    return out;
}

fn loadMathsArgs(allocator: std.mem.Allocator, args: []std.json.Value) ![]const f64 {
    const out = try allocator.alloc(f64, args.len);
    for (args, 0..) |arg, i| {
        out[i] = try jsonValueToF64(arg);
    }
    return out;
}

fn jsonValueToF64(v: std.json.Value) !f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |n| @as(f64, @floatFromInt(n)),
        .number_string => |s| std.fmt.parseFloat(f64, s),
        else => error.InvalidArg,
    };
}

fn argsToJson(allocator: std.mem.Allocator, args: []std.json.Value) ![]const u8 {
    var json = std.ArrayList(u8).initCapacity(allocator, 64) catch return error.OutOfMemory;
    errdefer json.deinit(allocator);
    try json.append(allocator, '[');
    for (args, 0..) |arg, idx| {
        if (idx > 0) try json.append(allocator, ',');
        switch (arg) {
            .integer => |n| try appendPrint(&json, allocator, "{d}", .{n}),
            .float => |f| try appendPrint(&json, allocator, "{d}", .{f}),
            .bool => |b| try appendPrint(&json, allocator, "{}", .{b}),
            .null => try json.appendSlice(allocator, "null"),
            else => try json.append(allocator, '0'),
        }
    }
    try json.append(allocator, ']');
    return json.toOwnedSlice(allocator);
}

fn loadFonts(allocator: std.mem.Allocator, root: []const u8, embedded: []const []const u8, file_path: []const u8) ![]const []const u8 {
    if (embedded.len > 0) return dupeStringList(allocator, embedded);
    if (file_path.len == 0) return &.{};
    const bytes = try readAssetFile(allocator, root, file_path, 4 * 1024 * 1024);
    const parsed = try std.json.parseFromSlice([]const []const u8, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return dupeStringList(allocator, parsed.value);
}

fn loadSpeechVoices(allocator: std.mem.Allocator, root: []const u8, file_path: []const u8) ![]const SpeechVoiceSpec {
    if (file_path.len == 0) return &.{};
    const bytes = try readAssetFile(allocator, root, file_path, 4 * 1024 * 1024);
    const parsed = try std.json.parseFromSlice([]const JsonSpeechVoice, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const src = parsed.value;
    const out = try allocator.alloc(SpeechVoiceSpec, src.len);
    for (src, 0..) |v, i| {
        const voice_uri = if (v.voiceURI) |uri|
            try allocator.dupe(u8, uri)
        else
            try std.fmt.allocPrint(allocator, "com.apple.voice.compact.{s}.{s}", .{ v.lang, v.name });
        out[i] = .{
            .name = try allocator.dupe(u8, v.name),
            .lang = try allocator.dupe(u8, v.lang),
            .voice_uri = voice_uri,
            .local_service = v.localService,
            .default_voice = v.default,
        };
    }
    return out;
}

fn loadAudioProbe(allocator: std.mem.Allocator, root: []const u8, probe: JsonAudioProbe, profile: *LoadedProfile) !void {
    if (probe.dataFile.len == 0) return;
    const bytes = readAssetFile(allocator, root, probe.dataFile, 4 * 1024 * 1024) catch return;
    defer allocator.free(bytes);

    const parsed = std.json.parseFromSlice(JsonAudioBaseline, allocator, bytes, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const doc = parsed.value;
    if (doc.samples.len == 0 or doc.freq.len == 0) return;

    const samples = try allocator.alloc(f32, doc.samples.len);
    for (doc.samples, 0..) |v, i| samples[i] = @floatCast(v);
    const freq = try allocator.alloc(f32, doc.freq.len);
    for (doc.freq, 0..) |v, i| freq[i] = @floatCast(v);

    profile.audio_probe_samples = samples;
    profile.audio_probe_freq = freq;
    if (doc.timeDomain.len > 0) {
        const time_domain = try allocator.alloc(f32, doc.timeDomain.len);
        for (doc.timeDomain, 0..) |v, i| time_domain[i] = @floatCast(v);
        profile.audio_probe_time_domain = time_domain;
    }
}

fn loadCanvasProbe(allocator: std.mem.Allocator, root: []const u8, probe: JsonCanvasProbe) !?[]const u8 {
    if (probe.dataUrl.len > 0) {
        return try allocator.dupe(u8, probe.dataUrl);
    }
    if (probe.dataUrlFile.len == 0) return null;
    const bytes = readAssetFile(allocator, root, probe.dataUrlFile, 64 * 1024) catch return null;
    return bytes;
}

const JsonCanvasProbesFile = struct {
    canvas_240_koko: []const u8 = "",
    canvas_50_text: []const u8 = "",
    canvas_50_emoji: []const u8 = "",
    canvas_75_data: []const u8 = "",
    canvas_75_paint: []const u8 = "",
    canvas_75_paint_cpu: []const u8 = "",
    canvas_mods_pixel_image: []const u8 = "",
    canvas_2_low_entropy: []const f64 = &.{},
};

fn loadCanvasProbes(allocator: std.mem.Allocator, root: []const u8, probe: JsonCanvasProbe, profile: *LoadedProfile) !void {
    if (probe.probesFile.len == 0) return;
    const bytes = try readAssetFile(allocator, root, probe.probesFile, 2 * 1024 * 1024);
    const parsed = try std.json.parseFromSlice(JsonCanvasProbesFile, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const doc = parsed.value;

    if (profile.canvas_probe_data_url == null and doc.canvas_240_koko.len > 0) {
        profile.canvas_probe_data_url = try allocator.dupe(u8, doc.canvas_240_koko);
    }
    if (doc.canvas_50_text.len > 0) {
        profile.canvas_probe_50_text = try allocator.dupe(u8, doc.canvas_50_text);
    }
    if (doc.canvas_50_emoji.len > 0) {
        profile.canvas_probe_50_emoji = try allocator.dupe(u8, doc.canvas_50_emoji);
    }
    if (doc.canvas_75_data.len > 0) {
        profile.canvas_probe_75_data = try allocator.dupe(u8, doc.canvas_75_data);
    }
    if (doc.canvas_75_paint.len > 0) {
        profile.canvas_probe_75_paint = try allocator.dupe(u8, doc.canvas_75_paint);
    }
    if (doc.canvas_75_paint_cpu.len > 0) {
        profile.canvas_probe_75_paint_cpu = try allocator.dupe(u8, doc.canvas_75_paint_cpu);
    }
    if (doc.canvas_mods_pixel_image.len > 0) {
        profile.canvas_probe_mods_pixel_image = try allocator.dupe(u8, doc.canvas_mods_pixel_image);
    }
    if (doc.canvas_2_low_entropy.len > 0) {
        const pixels = try allocator.alloc(u8, doc.canvas_2_low_entropy.len);
        for (doc.canvas_2_low_entropy, 0..) |v, i| {
            const clamped = @min(@max(v, 0), 255);
            pixels[i] = @intFromFloat(clamped);
        }
        profile.canvas_probe_2_pixels = pixels;
    }
}

fn parsePlugins(allocator: std.mem.Allocator, src: []const JsonPlugin) ![]const PluginSpec {
    const out = try allocator.alloc(PluginSpec, src.len);
    for (src, 0..) |p, i| {
        out[i] = .{
            .name = try allocator.dupe(u8, p.name),
            .filename = try allocator.dupe(u8, p.filename),
            .description = try allocator.dupe(u8, p.description),
            .mime_type = try allocator.dupe(u8, p.mimeType),
            .mime_suffixes = try allocator.dupe(u8, p.mimeSuffixes),
        };
    }
    return out;
}

fn dupePluginSpecs(allocator: std.mem.Allocator, src: []const PluginSpec) ![]const PluginSpec {
    const out = try allocator.alloc(PluginSpec, src.len);
    for (src, 0..) |p, i| {
        out[i] = .{
            .name = try allocator.dupe(u8, p.name),
            .filename = try allocator.dupe(u8, p.filename),
            .description = try allocator.dupe(u8, p.description),
            .mime_type = try allocator.dupe(u8, p.mime_type),
            .mime_suffixes = try allocator.dupe(u8, p.mime_suffixes),
        };
    }
    return out;
}

fn dupeStringList(allocator: std.mem.Allocator, src: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, src.len);
    for (src, 0..) |item, i| {
        out[i] = try allocator.dupe(u8, item);
    }
    return out;
}

fn buildSecChUa(allocator: std.mem.Allocator, brands: []const Brand) ![:0]u8 {
    var list = try std.ArrayList(u8).initCapacity(allocator, 64);
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, "Sec-Ch-Ua:");
    for (brands, 0..) |brand, i| {
        const sep = if (i == 0) " " else ", ";
        try list.appendSlice(allocator, sep);
        try appendPrint(&list, allocator, "\"{s}\";v=\"{s}\"", .{ brand.brand, brand.version });
    }
    try list.append(allocator, 0);
    const slice = try list.toOwnedSlice(allocator);
    return slice[0 .. slice.len - 1 :0];
}

fn buildAcceptLanguage(allocator: std.mem.Allocator, languages: []const []const u8) ![:0]u8 {
    var list = try std.ArrayList(u8).initCapacity(allocator, 64);
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, "Accept-Language: ");
    for (languages, 0..) |lang, i| {
        if (i > 0) try list.append(allocator, ',');
        switch (i) {
            0 => try list.appendSlice(allocator, lang),
            1 => try appendPrint(&list, allocator, "{s};q=0.9", .{lang}),
            2 => try appendPrint(&list, allocator, "{s};q=0.8", .{lang}),
            else => try appendPrint(&list, allocator, "{s};q=0.7", .{lang}),
        }
    }
    try list.append(allocator, 0);
    const slice = try list.toOwnedSlice(allocator);
    return slice[0 .. slice.len - 1 :0];
}

fn parsePersonaId(raw: []const u8, platform: []const u8) !Profile.PersonaId {
    if (raw.len > 0) {
        if (std.mem.eql(u8, raw, "macos_sonoma_intel")) return .macos_sonoma_intel;
        if (std.mem.eql(u8, raw, "windows_11_intel")) return .windows_11_intel;
        if (std.mem.eql(u8, raw, "macos_catalina_intel")) return .macos_catalina_intel;
    }
    if (std.mem.eql(u8, platform, "Win32")) return .windows_11_intel;
    return .macos_catalina_intel;
}

fn validateAntidetect(
    mode: Mode,
    user_agent: []const u8,
    brands: []const JsonBrand,
    browser_family: BrowserFamily,
) !void {
    if (mode != .antidetect) return;
    if (std.ascii.indexOfIgnoreCase(user_agent, "mozilla/") == null) return error.InvalidProfile;
    switch (browser_family) {
        .chrome => {
            var has_chrome_brand = false;
            for (brands) |brand| {
                if (std.mem.eql(u8, brand.brand, "Chromium") or
                    std.mem.eql(u8, brand.brand, "Google Chrome"))
                {
                    has_chrome_brand = true;
                }
            }
            if (!has_chrome_brand) return error.InvalidProfile;
        },
        .firefox => {
            if (std.mem.indexOf(u8, user_agent, "Firefox/") == null) return error.InvalidProfile;
        },
        .safari => {
            if (std.mem.indexOf(u8, user_agent, "Safari/") == null) return error.InvalidProfile;
            if (std.mem.indexOf(u8, user_agent, "Chrome/") != null) return error.InvalidProfile;
        },
    }
}

const testing = @import("../../testing/testing.zig");

test "ProfileStore: assets cannot escape fingerprint folder" {
    const allocator = std.testing.allocator;
    try testing.expectError(
        error.AssetOutsideFingerprint,
        resolveAssetPath(allocator, "/tmp/fingerprint", "../outside.json"),
    );
    try testing.expectError(
        error.AssetOutsideFingerprint,
        resolveAssetPath(allocator, "/tmp/fingerprint", "/tmp/outside.json"),
    );
}

fn testPaths(allocator: std.mem.Allocator, profile_name: []const u8) !ProfilePaths.ProfilePaths {
    const base = try std.fmt.allocPrint(allocator, "/tmp/koko-profilestore-test-{s}", .{profile_name});
    defer allocator.free(base);
    std.Io.Dir.cwd().deleteTree(runtime_io.get(), base) catch {};
    var paths = try ProfilePaths.ProfilePaths.init(allocator, base, profile_name, null);
    try paths.ensureProfileReady();
    return paths;
}

test "ProfileStore: load koko profile" {
    var paths = try testPaths(std.testing.allocator, "koko");
    defer paths.deinit();
    var profile = try resolve(&paths);
    defer profile.deinit();
    try testing.expectEqual(Mode.koko, profile.mode);
    try testing.expect(profile.persona.network.brands.len >= 1);
}

test "ProfileStore: load chrome antidetect profile" {
    var paths = try testPaths(std.testing.allocator, "huynew");
    defer paths.deinit();
    var profile = try resolve(&paths);
    defer profile.deinit();
    try testing.expectEqual(Mode.antidetect, profile.mode);
    try testing.expect(std.mem.indexOf(u8, profile.persona.network.user_agent, "Chrome") != null);
}

test "ProfileStore: load captured Chrome profile with transport" {
    var paths = try testPaths(std.testing.allocator, "huynew");
    defer paths.deinit();
    var profile = try resolve(&paths);
    defer profile.deinit();
    try testing.expectEqual(Mode.antidetect, profile.mode);
    try testing.expectEqual(BrowserFamily.chrome, profile.persona.family);
    try testing.expectEqual(TransportProfile.Target.chrome150, profile.persona.network.transport_target);
    try testing.expect(std.mem.indexOf(u8, profile.persona.network.user_agent, "Chrome/150") != null);
    try testing.expectEqual(@as(usize, 5), profile.plugins.len);
    try testing.expectEqual(profile.plugins.len, profile.persona.surfaces.plugins.len);
    try testing.expect(profile.fonts.len > 0);
    try testing.expect(profile.speech_voices.len > 0);
    try testing.expectEqual(@as(u8, 24), profile.persona.identity.screen.color_depth);
}

test "ProfileStore: startup UA suffix updates the canonical persona" {
    var paths = try testPaths(std.testing.allocator, "huynew");
    defer paths.deinit();
    var profile = try resolve(&paths);
    defer profile.deinit();

    try applyUserAgentOverlay(&profile, null, "ProductMarker/1.0");
    try testing.expect(std.mem.endsWith(
        u8,
        profile.persona.network.user_agent,
        " ProductMarker/1.0",
    ));
    try testing.expectEqualStrings(
        profile.persona.network.user_agent,
        profile.persona.identity.user_agent_fallback,
    );
}

test "ProfileStore: startup UA cannot select another Chrome persona" {
    var paths = try testPaths(std.testing.allocator, "huynew");
    defer paths.deinit();
    var profile = try resolve(&paths);
    defer profile.deinit();

    try testing.expectError(
        error.PersonaUserAgentOverrideInconsistent,
        applyUserAgentOverlay(
            &profile,
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/149.0.0.0 Safari/537.36",
            null,
        ),
    );
}

test "ProfileStore: koko profile has no site policies" {
    var paths = try testPaths(std.testing.allocator, "koko");
    defer paths.deinit();
    var profile = try resolve(&paths);
    defer profile.deinit();
    try testing.expectEqual(@as(usize, 0), profile.policies.len);
}

test "ProfileStore: incomplete imported profile is rejected" {
    var paths = try testPaths(std.testing.allocator, "kameleo-00b2456ba29ec623");
    defer paths.deinit();
    try testing.expectError(error.MissingField, resolve(&paths));
}
