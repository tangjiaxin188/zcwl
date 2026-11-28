const General = @import("General.zig");

/// Application-level options shared by all windows.
pub const AppConfig = struct {
    /// Wayland app_id / X11 WM_CLASS / Win32 AppUserModelID / macOS bundle id.
    /// Empty means backend default.
    application_id: []const u8 = "",

    /// Sinks for errors and information that cannot be returned to the caller.
    /// Owned by this App; no process-global reporter state.
    reporter: General.Reporter = .{},
};

/// Caller-provided cursor image.
///
/// `pixels` is row-major, straight-alpha RGBA8 with exactly
/// `width * height * 4` bytes and no row padding. The library premultiplies
/// alpha for the Wayland shm buffer. Dimensions, stride and total size must
/// fit in `i32`; `hotspot_x`/`hotspot_y` must be inside the image. Invalid
/// input returns `error.InvalidSize` or `error.InvalidArgument`.
pub const CursorImage = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    hotspot_x: i32 = 0,
    hotspot_y: i32 = 0,
};

/// Window creation parameters.
pub const WindowConfig = struct {
    /// Graphics API reserved by the window. Using the other path returns
    /// `error.UnsupportedApi`; the default `.opengl` therefore rejects an
    /// `.opengles` context.
    client_api: General.GraphicsApi = .opengl,

    title: []const u8 = "",
    /// Logical client size. Both dimensions must be non-zero and fit in `i32`.
    size: General.Size = .{ .w = 640, .h = 480 },
    position: ?General.Position = null,
    resizable: bool = true,
    decorated: bool = true,
    always_on_top: bool = false,
    visible: bool = true,
};

/// Context creation parameters.
pub const ContextConfig = struct {
    /// `.opengl` or `.opengles`; Vulkan is not a Context.
    api: General.GraphicsApi = .opengl,
    /// 0/0 lets the backend choose.
    major: u8 = 0,
    minor: u8 = 0,
    profile: General.GlProfile = .core,
    debug: bool = false,
};
