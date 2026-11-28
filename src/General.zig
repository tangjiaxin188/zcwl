const std = @import("std");

pub const Size = struct { w: u32, h: u32 };
pub const Position = struct { x: i32, y: i32 };
pub const Vector2 = struct { x: f32, y: f32 };

/// Scale a logical size to physical pixels without panicking on extreme or
/// non-finite values. Results saturate at `maxInt(u32)`.
pub fn scaledSize(size: Size, scale: f32) Size {
    return .{
        .w = scaledDimension(size.w, scale),
        .h = scaledDimension(size.h, scale),
    };
}

fn scaledDimension(value: u32, scale: f32) u32 {
    const effective: f32 = if (std.math.isFinite(scale) and scale > 0.0) scale else 1.0;
    const scaled: f64 = @as(f64, @floatFromInt(value)) * @as(f64, effective);
    if (scaled <= 0.0) return 0;
    if (scaled >= @as(f64, @floatFromInt(std.math.maxInt(u32)))) return std.math.maxInt(u32);
    return @intFromFloat(scaled);
}

test "scaledSize scales and saturates" {
    const normal = scaledSize(.{ .w = 100, .h = 50 }, 2.0);
    try std.testing.expectEqual(@as(u32, 200), normal.w);
    try std.testing.expectEqual(@as(u32, 100), normal.h);

    const invalid = scaledSize(.{ .w = 100, .h = 50 }, std.math.nan(f32));
    try std.testing.expectEqual(@as(u32, 100), invalid.w);

    const huge = scaledSize(.{ .w = std.math.maxInt(u32), .h = 1 }, 2.0);
    try std.testing.expectEqual(std.math.maxInt(u32), huge.w);
}

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

/// Static system information passed to the info reporter.
pub const SystemInfo = struct {
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
    backend: []const u8,
};

pub const ErrorReporter = *const fn (err: anyerror) void;
pub const InfoReporter = *const fn (info: SystemInfo) void;

/// Per-application sinks for diagnostics that cannot be returned to the
/// caller. Stored by value in `App` and in the selected backend; there is no
/// process-global reporter state. Both sinks default to silent/no I/O.
pub const Reporter = struct {
    error_fn: ?ErrorReporter = null,
    info_fn: ?InfoReporter = null,

    /// Cheap no-op unless the application installed an error reporter.
    pub inline fn reportError(self: Reporter, err: anyerror) void {
        if (self.error_fn) |report| report(err);
    }

    /// Cheap no-op unless the application installed an info reporter.
    pub inline fn reportInfo(self: Reporter, info: SystemInfo) void {
        if (self.info_fn) |report| report(info);
    }
};
