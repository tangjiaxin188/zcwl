const std = @import("std");

pub const Size = struct { w: u32, h: u32 };
pub const Position = struct { x: i32, y: i32 };
pub const Vector2 = struct { x: f32, y: f32 };

/// Standard cursor shapes; `.arrow` is the default.
/// Semantic cursor states/shapes. `Window.setCursor` selects the current
/// state; `Window.setCursorImage` can attach a caller-drawn image to one state.
pub const Cursor = enum(u8) {
    arrow,
    ibeam,
    crosshair,
    pointing_hand,
    resize_ew,
    resize_ns,
    resize_nwse,
    resize_nesw,
    resize_all,
    not_allowed,
    wait,
    progress,
    help,
    move,
    copy,
    no_drop,
    grab,
    grabbing,
};

/// Graphics API used by a window/context.
pub const GraphicsApi = enum(u8) {
    opengl,
    opengles,
    vulkan,
};

pub const ProcAddr = *const fn () callconv(.c) void;

/// Native display/window handles for third-party renderers. The library does
/// not interpret or own them.
pub const NativeWindow = struct {
    ndt: ?*anyopaque = null,
    nwh: ?*anyopaque = null,
};

pub const BackendKind = enum { wayland, x11, both, null, windows, macos };
pub const Platform = enum { wayland, x11, win32, cocoa, null };
pub const ContextCreator = enum { egl, wgl, cgl, none };
pub const GlProfile = enum { core, compatibility, es };

pub const Ratio = struct { numerator: u32, denominator: u32 };

/// One clipboard MIME item used when setting multiple representations.
pub const ClipboardItem = struct {
    mime: []const u8,
    data: []const u8,
};

pub const ContextInfo = struct {
    kind: GraphicsApi,
    major: u8 = 0,
    minor: u8 = 0,
    profile: GlProfile = .core,
    vendor: []const u8 = "",
    renderer: []const u8 = "",
    version: []const u8 = "",
    shading_language: []const u8 = "",
    creator: ContextCreator = .none,
};

pub const WindowInfo = struct {
    size: Size,
    framebuffer_size: Size,
    position: ?Position,
    dpi_scale: f32,
    client_api: GraphicsApi,
    fullscreen: bool = false,
    maximized: bool = false,
    minimized: bool = false,
    focused: bool = false,
    resizable: bool = true,
    decorated: bool = true,
    always_on_top: bool = false,
    opacity: f32 = 1.0,
};

pub const MonitorInfo = struct {
    id: u32,
    name: []const u8,
    position: Position,
    size: Size,
    work_area: Size,
    dpi_scale: f32,
    refresh_hz: f32,
};

pub const BackendInfo = struct {
    requested: BackendKind = .null,
    effective: BackendKind = .null,
    platform: Platform = .null,
    context_creator: ContextCreator = .none,
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
};

/// Optional sink for errors that cannot be returned. Default: silent/no I/O.
pub const ErrorReporter = *const fn (err: anyerror) void;

pub var error_reporter: ?ErrorReporter = null;

/// Cheap no-op unless the application installed a reporter.
pub inline fn reportError(err: anyerror) void {
    if (error_reporter) |report| report(err);
}

/// Static system information for the opt-in info reporter below.
pub const SystemInfo = struct {
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
    backend: []const u8,
};

/// Optional sink for informational messages. Default: silent/no I/O.
pub const InfoReporter = *const fn (info: SystemInfo) void;
pub var info_reporter: ?InfoReporter = null;

pub inline fn reportInfo(info: SystemInfo) void {
    if (info_reporter) |report| report(info);
}
