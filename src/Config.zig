const General = @import("General.zig");

/// Application-level options shared by all windows.
pub const AppConfig = struct {
    /// Wayland app_id / X11 WM_CLASS / Win32 AppUserModelID / macOS bundle id.
    /// Empty means backend default.
    application_id: []const u8 = "",
};

/// Window creation parameters.
pub const WindowConfig = struct {
    /// Graphics API reserved by the window. Using the other path returns
    /// `error.UnsupportedApi`.
    client_api: General.GraphicsApi = .opengl,

    title: []const u8 = "",
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
