const Window = @This();

const Backend = @import("Backend.zig");
const App = @import("App.zig");
const General = @import("General.zig");
const Context = @import("Context.zig");
const Config = @import("Config.zig");
const Vulkan = @import("Vulkan.zig");
const cursor_image = @import("cursor_image.zig");

const std = @import("std");

const WindowSize = General.Size;
const WindowPos = General.Position;

id: u32,
backendWindow: *Backend.Window,
app: *App,
backend: *Backend.Handle,
context: ?*Context,
/// Presentation API reserved by this window (from WindowConfig.client_api).
client_api: General.GraphicsApi,
/// A Vulkan surface is one-shot per window (the caller owns it, so the
/// library cannot know when it is destroyed).
vulkan_surface_created: bool,
/// Guards against double teardown from `uninit()` being public.
destroyed: bool = false,
/// Cached size limits, used for cross-validation. Backends keep their own copy.
min_size: ?WindowSize = null,
max_size: ?WindowSize = null,

pub fn init(app: *App, bwin: *Backend.Window, client_api: General.GraphicsApi) !*Window {
    const w = app._alloc.create(Window) catch |err| {
        bwin.uninit();
        return err;
    };
    w.* = Window{
        .id = bwin.getId(),
        .backendWindow = bwin,
        .app = app,
        .backend = app.backend,
        .context = null,
        .client_api = client_api,
        .vulkan_surface_created = false,
    };
    return w;
}

/// Destroy the window, its context and the backend window, and remove it from
/// the App. The pointer is invalid afterwards.
pub fn destroy(self: *Window) void {
    self.uninit();
}

/// Teardown used by `destroy()` and `App.uninit()`. It deregisters the window
/// itself so a direct call cannot leave a dangling entry in the App's table.
/// The small `Window` struct is owned by the `App` and freed in `App.uninit()`,
/// so repeated `destroy()`/`uninit()` calls are safe. Do not call any other
/// method on this window afterwards.
pub fn uninit(self: *Window) void {
    if (self.destroyed) return;
    self.destroyed = true;
    self.app._removeWindow(self);
    if (self.context) |ctx| ctx.uninit();
    self.context = null;
    self.backendWindow.uninit();
}

/// Native WSI handles (`ndt`/`nwh`) for third-party renderers. The library
/// does not interpret or own them.
pub fn getNative(self: *Window) General.NativeWindow {
    return self.backendWindow.getNative();
}

/// Create a `VkSurfaceKHR` for a `.vulkan` window. The caller owns the
/// surface; `instance` and the loader are only used for this call.
/// A second successful call returns `error.WindowHadVulkanSurface`.
pub fn createVulkanSurface(
    self: *Window,
    instance: Vulkan.Instance,
    get_instance_proc_addr: Vulkan.GetInstanceProcAddr,
    allocator: ?*const Vulkan.AllocationCallbacks,
) !Vulkan.SurfaceKHR {
    if (self.client_api != .vulkan) {
        return error.UnsupportedApi;
    }
    if (self.vulkan_surface_created) {
        return error.WindowHadVulkanSurface;
    }
    const surface = try self.backendWindow.createVulkanSurface(instance, get_instance_proc_addr, allocator);
    self.vulkan_surface_created = true;
    return surface;
}

/// Presentation API this window was created for.
pub fn getClientApi(self: *Window) General.GraphicsApi {
    return self.client_api;
}

/// Compare windows within the same `App`. Ids are backend-local, so windows
/// from different Apps are never equal.
pub fn eq(self: *Window, other: *Window) bool {
    return self == other or (self.app == other.app and self.id == other.id);
}

/// Create a GL/GLES context for a window reserved for the same API.
/// `config.api` must equal the window's `client_api`; Vulkan windows and
/// configs return `error.UnsupportedApi`. One context per window; `share` must
/// belong to the same backend/display.
pub fn createContext(
    self: *Window,
    config: Config.ContextConfig,
    share: ?*Context,
) !*Context {
    if (self.client_api == .vulkan or config.api == .vulkan) {
        return error.UnsupportedApi;
    }
    if (config.api != self.client_api) {
        return error.UnsupportedApi;
    }
    if (self.context != null) {
        return error.WindowHadContext;
    }

    var share_backend: ?*Backend.Context = null;
    if (share) |s| {
        if (s.kind == .vulkan or s.backend != self.backend) {
            return error.IncompatibleShareContext;
        }
        share_backend = s.backendContext;
    }

    const native = self.getNative();
    const bctx = try self.backend.initContext(&native, config, share_backend);
    const cctx = Context.init(self.app._alloc, bctx, self.app.reporter, self.backend) catch |err| {
        bctx.uninit();
        return err;
    };
    // Let a direct `Context.uninit()` clear this window's slot instead of
    // leaving a dangling pointer.
    cctx.owner = &self.context;
    self.context = cctx;
    return cctx;
}

/// Destroy the current context, if any.
pub fn destroyContext(self: *Window) void {
    if (self.context) |ctx| {
        ctx.uninit();
        self.context = null;
    }
}

/// Current context, or null if none was created.
pub fn getContext(self: *Window) ?*Context {
    return self.context;
}

/// Current window state.
pub fn getInfo(self: *Window) General.WindowInfo {
    return self.backendWindow.getInfo();
}

pub fn isFullscreen(self: *Window) bool {
    return self.getInfo().fullscreen;
}

pub fn isMaximized(self: *Window) bool {
    return self.getInfo().maximized;
}

pub fn isMinimized(self: *Window) bool {
    return self.getInfo().minimized;
}

pub fn isFocused(self: *Window) bool {
    return self.getInfo().focused;
}

pub fn isResizable(self: *Window) bool {
    return self.getInfo().resizable;
}

pub fn isDecorated(self: *Window) bool {
    return self.getInfo().decorated;
}

pub fn isAlwaysOnTop(self: *Window) bool {
    return self.getInfo().always_on_top;
}

pub fn getOpacity(self: *Window) f32 {
    return self.getInfo().opacity;
}

/// Set the window icon from RGBA8 pixel data. May return `error.Unsupported`.
/// Dimensions must be non-zero and `rgba.len` must equal `width * height * 4`.
pub fn setIcon(self: *Window, rgba: []const u8, width: u32, height: u32) !void {
    if (width == 0 or height == 0) return error.InvalidSize;
    const pixels = std.math.mul(u64, width, height) catch return error.InvalidArgument;
    const bytes = std.math.mul(u64, pixels, 4) catch return error.InvalidArgument;
    if (@as(u64, rgba.len) != bytes) return error.InvalidArgument;
    return self.backendWindow.setIcon(rgba, width, height);
}

pub fn setDecorated(self: *Window, decorated: bool) !void {
    return self.backendWindow.setDecorated(decorated);
}

/// Set always-on-top. May return `error.Unsupported`.
pub fn setAlwaysOnTop(self: *Window, always_on_top: bool) !void {
    return self.backendWindow.setAlwaysOnTop(always_on_top);
}

/// Whole-window opacity, clamped to `[0, 1]`. Non-finite values return
/// `error.InvalidOpacity`. May return `error.Unsupported`.
pub fn setOpacity(self: *Window, opacity: f32) !void {
    if (!std.math.isFinite(opacity)) return error.InvalidOpacity;
    try self.backendWindow.setOpacity(std.math.clamp(opacity, 0.0, 1.0));
}

/// Show or hide the window. Backends without a hide mechanism return
/// `error.Unsupported`.
pub fn setVisible(self: *Window, visible: bool) !void {
    try self.backendWindow.setVisible(visible);
}

/// Show or hide the cursor.
pub fn setCursorVisible(self: *Window, visible: bool) !void {
    try self.backendWindow.setCursorVisible(visible);
}

/// Record an aspect-ratio constraint; platforms without support ignore it.
/// A zero numerator or denominator returns `error.InvalidRatio`.
pub fn setAspectRatio(self: *Window, ratio: ?General.Ratio) !void {
    if (ratio) |r| {
        if (r.numerator == 0 or r.denominator == 0) return error.InvalidRatio;
    }
    try self.backendWindow.setAspectRatio(ratio);
}

/// Request user attention. May return `error.Unsupported`.
pub fn requestAttention(self: *Window) !void {
    return self.backendWindow.requestAttention();
}

/// Start dragging files out of this window. Paths must be absolute or use
/// `file://` URIs. Backends without drag support return `error.Unsupported`.
pub fn startDragFiles(self: *Window, paths: []const []const u8) !void {
    return self.backendWindow.startDragFiles(paths);
}

/// Assign a new window title.
pub fn setTitle(self: *Window, new_title: []const u8) !void {
    try self.backendWindow.setTitle(new_title);
}

/// Borrowed title; valid until the next `setTitle`.
pub fn getTitle(self: *Window) []const u8 {
    return self.backendWindow.getTitle();
}

/// Backend-assigned stable window id.
pub fn getId(self: *Window) u32 {
    return self.id;
}

/// `null` clears the maximum-size limit. Zero or `i32`-overflowing dimensions
/// and a limit below the current minimum return `error.InvalidSize` /
/// `error.InvalidSizeRange`.
pub fn setMaxSize(self: *Window, max_size: ?WindowSize) !void {
    if (max_size) |s| {
        try validateSize(s);
        if (self.min_size) |m| {
            if (m.w > s.w or m.h > s.h) return error.InvalidSizeRange;
        }
    }
    try self.backendWindow.setMaxSize(max_size);
    self.max_size = max_size;
}

/// Set logical client size. The platform may ignore or adjust it. Zero
/// dimensions and values above `i32` return `error.InvalidSize`; fullscreen is
/// a separate API.
pub fn setSize(self: *Window, new_size: WindowSize) !void {
    try validateSize(new_size);
    try self.backendWindow.setSize(new_size);
}

/// Logical client size. Use `getFramebufferSize()` for `glViewport`.
pub fn getSize(self: *Window) WindowSize {
    return self.backendWindow.getSize();
}

/// Set logical position. No-op on platforms without global positions.
pub fn setPos(self: *Window, new_pos: WindowPos) !void {
    try self.backendWindow.setPos(new_pos);
}

/// Logical position, or null when the platform has no global position.
pub fn getPos(self: *Window) ?WindowPos {
    return self.backendWindow.getPos();
}

/// Physical framebuffer size; this is what `glViewport` expects.
pub fn getFramebufferSize(self: *Window) WindowSize {
    return self.backendWindow.getFramebufferSize();
}

/// Logical-to-physical pixel ratio; re-query after resize/scale events.
pub fn getDpiScale(self: *Window) f32 {
    return self.backendWindow.getDpiScale();
}

/// Enable or disable interactive resizing.
pub fn setResizable(self: *Window, resizable: bool) !void {
    try self.backendWindow.setResizable(resizable);
}

/// `null` clears the minimum-size limit. Zero or `i32`-overflowing dimensions
/// and a limit above the current maximum return `error.InvalidSize` /
/// `error.InvalidSizeRange`.
pub fn setMinSize(self: *Window, min_size: ?WindowSize) !void {
    if (min_size) |s| {
        try validateSize(s);
        if (self.max_size) |m| {
            if (s.w > m.w or s.h > m.h) return error.InvalidSizeRange;
        }
    }
    try self.backendWindow.setMinSize(min_size);
    self.min_size = min_size;
}

/// Toggle windowed/fullscreen mode.
pub fn setFullscreen(self: *Window, fullscreen: bool) !void {
    try self.backendWindow.setFullscreen(fullscreen);
}

/// Set the cursor shape.
pub fn setCursor(self: *Window, cursor: General.Cursor) !void {
    try self.backendWindow.setCursor(cursor);
}

/// Configure a custom image for one cursor state. Images are stored per
/// `General.Cursor` state for the whole application (last writer wins), not per
/// window. See `Config.CursorImage` for the pixel contract.
pub fn setCursorImage(self: *Window, state: General.Cursor, image: Config.CursorImage) !void {
    _ = try cursor_image.layout(image);
    try self.backendWindow.setCursorImage(state, image);
}

/// Remove a custom image for one cursor state and restore the system shape.
/// Like `setCursorImage`, this affects the application-global cursor theme.
pub fn clearCursorImage(self: *Window, state: General.Cursor) !void {
    try self.backendWindow.clearCursorImage(state);
}

/// Request focus; the platform/compositor may ignore it.
pub fn setFocus(self: *Window) !void {
    try self.backendWindow.setFocus();
}

/// Minimize the window.
pub fn minimize(self: *Window) !void {
    try self.backendWindow.minimize();
}

/// Maximize the window.
pub fn maximize(self: *Window) !void {
    try self.backendWindow.maximize();
}

/// Enable/disable IME for this window. The setting applies whenever this
/// window has keyboard focus. May return `error.Unsupported`.
pub fn setImeAllowed(self: *Window, allowed: bool) !void {
    try self.backendWindow.setImeAllowed(allowed);
}

/// Set the IME candidate area in logical coordinates. Dimensions larger than
/// `i32` return `error.InvalidSize`; zero is allowed (empty candidate area).
pub fn setImeCursorArea(self: *Window, pos: WindowPos, size: WindowSize) !void {
    if (size.w > std.math.maxInt(i32) or size.h > std.math.maxInt(i32)) return error.InvalidSize;
    try self.backendWindow.setImeCursorArea(pos, size);
}

fn validateSize(size: WindowSize) !void {
    if (size.w == 0 or size.h == 0) return error.InvalidSize;
    // Wayland/EGL use signed 32-bit dimensions; reject values that would
    // otherwise panic in backend casts.
    if (size.w > std.math.maxInt(i32) or size.h > std.math.maxInt(i32)) return error.InvalidSize;
}
