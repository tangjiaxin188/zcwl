const Window = @This();

const Backend = @import("Backend.zig");
const App = @import("App.zig");
const General = @import("General.zig");
const Context = @import("Context.zig");
const Config = @import("Config.zig");
const Vulkan = @import("Vulkan.zig");

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
    self.app._removeWindow(self);
    self.uninit();
}

/// Internal teardown used by `destroy()` and `App.uninit()`; it does not
/// deregister the window from the App.
pub fn uninit(self: *Window) void {
    if (self.context) |ctx| ctx.uninit();
    self.backendWindow.uninit();
    self.app._alloc.destroy(self);
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

/// Compare backend-assigned window ids.
pub fn eq(self: *Window, other: *Window) bool {
    return self.id == other.id;
}

/// Create a GL/GLES context for a `.opengl`/`.opengles` window.
/// One context per window; `share` must belong to the same backend/display.
/// Returns `error.UnsupportedApi` for Vulkan windows.
pub fn createContext(
    self: *Window,
    config: Config.ContextConfig,
    share: ?*Context,
) !*Context {
    if (self.client_api == .vulkan) {
        return error.UnsupportedApi;
    }
    if (config.api == .vulkan) {
        return error.UnsupportedApi;
    }
    if (self.context != null) {
        return error.WindowHadContext;
    }

    var share_backend: ?*Backend.Context = null;
    if (share) |s| {
        if (s.kind == .vulkan) {
            return error.IncompatibleShareContext;
        }
        share_backend = s.backendContext;
    }

    const native = self.getNative();
    const bctx = try self.backend.initContext(&native, config, share_backend);
    const cctx = Context.init(self.app._alloc, bctx) catch |err| {
        bctx.uninit();
        return err;
    };
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
pub fn setIcon(self: *Window, rgba: []const u8, width: u32, height: u32) !void {
    return self.backendWindow.setIcon(rgba, width, height);
}

pub fn setDecorated(self: *Window, decorated: bool) !void {
    return self.backendWindow.setDecorated(decorated);
}

/// Set always-on-top. May return `error.Unsupported`.
pub fn setAlwaysOnTop(self: *Window, always_on_top: bool) !void {
    return self.backendWindow.setAlwaysOnTop(always_on_top);
}

/// Whole-window opacity. Failures are sent to `General.error_reporter`.
pub fn setOpacity(self: *Window, opacity: f32) void {
    self.backendWindow.setOpacity(opacity) catch |err| General.reportError(err);
}

/// Show or hide the cursor.
pub fn setCursorVisible(self: *Window, visible: bool) void {
    self.backendWindow.setCursorVisible(visible);
}

/// Record an aspect-ratio constraint; platforms without support ignore it.
pub fn setAspectRatio(self: *Window, ratio: ?General.Ratio) void {
    self.backendWindow.setAspectRatio(ratio);
}

/// Request user attention. May return `error.Unsupported`.
pub fn requestAttention(self: *Window) !void {
    return self.backendWindow.requestAttention();
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

/// `null` clears the maximum-size limit.
pub fn setMaxSize(self: *Window, max_size: ?WindowSize) void {
    self.backendWindow.setMaxSize(max_size);
}

/// Set logical client size. The platform may ignore or adjust it.
pub fn setSize(self: *Window, new_size: WindowSize) void {
    self.backendWindow.setSize(new_size);
}

/// Logical client size. Use `getFramebufferSize()` for `glViewport`.
pub fn getSize(self: *Window) WindowSize {
    return self.backendWindow.getSize();
}

/// Set logical position. No-op on platforms without global positions.
pub fn setPos(self: *Window, new_pos: WindowPos) void {
    self.backendWindow.setPos(new_pos);
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
pub fn setResizable(self: *Window, resizable: bool) void {
    self.backendWindow.setResizable(resizable);
}

/// `null` clears the minimum-size limit.
pub fn setMinSize(self: *Window, min_size: ?WindowSize) void {
    self.backendWindow.setMinSize(min_size);
}

/// Toggle windowed/fullscreen mode.
pub fn setFullscreen(self: *Window, fullscreen: bool) !void {
    try self.backendWindow.setFullscreen(fullscreen);
}

/// Set the cursor shape.
pub fn setCursor(self: *Window, cursor: General.Cursor) !void {
    try self.backendWindow.setCursor(cursor);
}

/// Request focus; the platform/compositor may ignore it.
pub fn setFocus(self: *Window) void {
    self.backendWindow.setFocus();
}

/// Minimize the window.
pub fn minimize(self: *Window) void {
    self.backendWindow.minimize();
}

/// Maximize the window.
pub fn maximize(self: *Window) void {
    self.backendWindow.maximize();
}

/// Enable/disable IME. May return `error.Unsupported`.
pub fn setImeAllowed(self: *Window, allowed: bool) !void {
    try self.backendWindow.setImeAllowed(allowed);
}

/// Set the IME candidate area in logical coordinates.
pub fn setImeCursorArea(self: *Window, pos: WindowPos, size: WindowSize) void {
    self.backendWindow.setImeCursorArea(pos, size);
}
