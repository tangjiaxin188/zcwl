//! EGL context creation on Wayland.
//!
//! EGL is loaded at runtime (see `loader.zig`). The default config requests an
//! 8-bit alpha channel so windows can be composited with per-pixel alpha.

const std = @import("std");
const BackendMod = @import("backend.zig");
const Config = @import("../../Config.zig");
const General = @import("../../General.zig");
const c = @import("protocols.zig").c;
const egl = @import("../egl.zig");
const loader = @import("loader.zig");

const Backend = BackendMod.Backend;
pub const Context = @This();

pub const NativeContext = struct {
    display: egl.Display,
    config: egl.Config,
    context: egl.Context,
    surface: egl.Surface,
};

alloc: std.mem.Allocator,
backend: *Backend,
kind: General.GraphicsApi,
window_id: u32,

display: egl.Display,
config: egl.Config,
context: egl.Context,
surface: egl.Surface,
egl_window: ?*loader.WlEglWindow = null,

native: NativeContext,
info: General.ContextInfo,
owned_strings: [4]?[]u8 = .{ null, null, null, null },

pub fn init(
    backend: *Backend,
    native_window: *const General.NativeWindow,
    config: Config.ContextConfig,
    share: ?*Context,
) !*Context {
    if (config.api != .opengl and config.api != .opengles) return error.Unsupported;
    const api = if (backend.loader.egl) |*value| value else return error.Unsupported;
    const wayland_egl = if (backend.loader.wayland_egl) |*value| value else return error.Unsupported;

    const wl_display: *c.struct_wl_display = @ptrCast(@alignCast(native_window.ndt orelse return error.InvalidNativeWindow));
    const wl_surface: *c.struct_wl_surface = @ptrCast(@alignCast(native_window.nwh orelse return error.InvalidNativeWindow));

    var egl_display: egl.Display = null;
    if (api.getPlatformDisplayEXT) |get_platform| {
        egl_display = get_platform(@intCast(egl.PLATFORM_WAYLAND_KHR), @ptrCast(wl_display), null);
    }
    if (egl_display == null) {
        egl_display = api.getDisplay(@ptrCast(wl_display));
    }
    if (egl_display == null) return error.EglDisplayFailed;

    var major: egl.Int = 0;
    var minor: egl.Int = 0;
    if (api.initialize(egl_display, &major, &minor) == 0) return error.EglInitializeFailed;

    const renderable: egl.Int = if (config.api == .opengl)
        @intCast(egl.OPENGL_BIT)
    else if (config.major >= 3)
        @intCast(egl.OPENGL_ES3_BIT)
    else
        @intCast(egl.OPENGL_ES2_BIT);

    var config_attribs = [_]egl.Int{
        @intCast(egl.SURFACE_TYPE),    @intCast(egl.WINDOW_BIT),
        @intCast(egl.RENDERABLE_TYPE), renderable,
        @intCast(egl.RED_SIZE),        8,
        @intCast(egl.GREEN_SIZE),      8,
        @intCast(egl.BLUE_SIZE),       8,
        @intCast(egl.ALPHA_SIZE),      8,
        @intCast(egl.DEPTH_SIZE),      24,
        @intCast(egl.STENCIL_SIZE),    8,
        @intCast(egl.NONE),
    };
    var configs: [64]egl.Config = undefined;
    var config_count: egl.Int = 0;
    if (api.chooseConfig(egl_display, &config_attribs, &configs, configs.len, &config_count) == 0 or config_count == 0)
        return error.EglConfigFailed;
    const egl_config = configs[0];

    const egl_api_kind: egl.Enum = if (config.api == .opengl)
        @intCast(egl.OPENGL_API)
    else
        @intCast(egl.OPENGL_ES_API);
    if (api.bindAPI(egl_api_kind) == 0) return error.EglBindApiFailed;

    var context_attribs: [16]egl.Int = undefined;
    var n: usize = 0;
    const want_major: egl.Int = if (config.major == 0) 3 else @intCast(config.major);
    const want_minor: egl.Int = if (config.minor == 0 and config.major == 0)
        (if (config.api == .opengl) 3 else 0)
    else
        @intCast(config.minor);
    context_attribs[n] = @intCast(egl.CONTEXT_MAJOR_VERSION);
    n += 1;
    context_attribs[n] = want_major;
    n += 1;
    context_attribs[n] = @intCast(egl.CONTEXT_MINOR_VERSION);
    n += 1;
    context_attribs[n] = want_minor;
    n += 1;
    if (config.api == .opengl and config.profile == .core) {
        context_attribs[n] = @intCast(egl.CONTEXT_OPENGL_PROFILE_MASK);
        n += 1;
        context_attribs[n] = @intCast(egl.CONTEXT_OPENGL_CORE_PROFILE_BIT);
        n += 1;
    }
    if (config.debug) {
        context_attribs[n] = @intCast(egl.CONTEXT_OPENGL_DEBUG);
        n += 1;
        context_attribs[n] = 1;
        n += 1;
    }
    context_attribs[n] = @intCast(egl.NONE);

    const share_context: egl.Context = if (share) |s| s.context else null;
    const egl_context = api.createContext(egl_display, egl_config, share_context, &context_attribs);
    if (egl_context == null) return error.EglContextFailed;
    errdefer _ = api.destroyContext(egl_display, egl_context);

    const window_id = backend.windowIdForSurface(wl_surface) orelse return error.InvalidNativeWindow;
    const window_size = backend.windowSizeById(window_id);
    const egl_window = wayland_egl.create(wl_surface, @intCast(window_size.w), @intCast(window_size.h)) orelse
        return error.EglWindowFailed;
    errdefer wayland_egl.destroy(egl_window);

    const egl_surface = api.createWindowSurface(egl_display, egl_config, egl_window, null);
    if (egl_surface == null) return error.EglSurfaceFailed;
    errdefer _ = api.destroySurface(egl_display, egl_surface);

    if (api.makeCurrent(egl_display, egl_surface, egl_surface, egl_context) == 0)
        return error.EglMakeCurrentFailed;
    errdefer _ = api.makeCurrent(egl_display, null, null, null);

    const self = try backend.alloc.create(Context);
    self.* = .{
        .alloc = backend.alloc,
        .backend = backend,
        .kind = config.api,
        .window_id = window_id,
        .display = egl_display,
        .config = egl_config,
        .context = egl_context,
        .surface = egl_surface,
        .egl_window = egl_window,
        .native = .{
            .display = egl_display,
            .config = egl_config,
            .context = egl_context,
            .surface = egl_surface,
        },
        .info = .{
            .kind = config.api,
            .major = @intCast(want_major),
            .minor = @intCast(want_minor),
            .profile = config.profile,
            .creator = .egl,
        },
    };
    self.queryGlInfo(api);
    return self;
}
pub fn uninit(self: *Context) void {
    if (self.backend.loader.egl) |*api| {
        _ = api.destroySurface(self.display, self.surface);
        _ = api.destroyContext(self.display, self.context);
    }
    if (self.egl_window) |window| {
        if (self.backend.loader.wayland_egl) |*wayland_egl| wayland_egl.destroy(window);
    }
    for (&self.owned_strings) |*slot| {
        if (slot.*) |value| self.alloc.free(value);
        slot.* = null;
    }
    self.backend.removeContext(self);
    self.alloc.destroy(self);
}

pub fn getKind(self: *Context) General.GraphicsApi {
    return self.kind;
}

pub fn getInfo(self: *Context) General.ContextInfo {
    return self.info;
}

pub fn getNative(self: *Context) *const NativeContext {
    return &self.native;
}

pub fn makeCurrent(self: *Context) !void {
    const api = if (self.backend.loader.egl) |*value| value else return error.Unsupported;
    if (api.makeCurrent(self.display, self.surface, self.surface, self.context) == 0)
        return error.EglMakeCurrentFailed;
}

pub fn clearCurrent(self: *Context) !void {
    const api = if (self.backend.loader.egl) |*value| value else return error.Unsupported;
    if (api.makeCurrent(self.display, null, null, null) == 0)
        return error.EglMakeCurrentFailed;
}

pub fn getProcAddress(self: *Context, name: [*:0]const u8) ?General.ProcAddr {
    const api = if (self.backend.loader.egl) |*value| value else return null;
    return api.getProcAddress(name);
}

pub fn swapBuffers(self: *Context) !void {
    if (!self.backend.windowIsConfigured(self.window_id)) return error.WouldBlock;
    const api = if (self.backend.loader.egl) |*value| value else return error.Unsupported;
    if (api.swapBuffers(self.display, self.surface) == 0) return error.EglSwapFailed;
}

pub fn setSwapInterval(self: *Context, interval: i32) !void {
    const api = if (self.backend.loader.egl) |*value| value else return error.Unsupported;
    if (api.swapInterval(self.display, @intCast(interval)) == 0) return error.Unsupported;
}

pub fn resize(self: *Context, size: General.Size) void {
    if (self.egl_window) |window| {
        if (self.backend.loader.wayland_egl) |*wayland_egl| {
            wayland_egl.resize(window, @intCast(size.w), @intCast(size.h), 0, 0);
        }
    }
}

fn queryGlInfo(self: *Context, api: *loader.Egl) void {
    const proc = api.getProcAddress("glGetString") orelse return;
    const get_string: *const fn (c_uint) callconv(.c) ?[*:0]const u8 = @ptrCast(proc);

    self.owned_strings[0] = dupeZToSlice(self.alloc, get_string(0x1F00)); // GL_VENDOR
    self.owned_strings[1] = dupeZToSlice(self.alloc, get_string(0x1F01)); // GL_RENDERER
    self.owned_strings[2] = dupeZToSlice(self.alloc, get_string(0x1F02)); // GL_VERSION
    self.owned_strings[3] = dupeZToSlice(self.alloc, get_string(0x8B8C)); // GL_SHADING_LANGUAGE_VERSION

    self.info.vendor = self.owned_strings[0] orelse "";
    self.info.renderer = self.owned_strings[1] orelse "";
    self.info.version = self.owned_strings[2] orelse "";
    self.info.shading_language = self.owned_strings[3] orelse "";
}

fn dupeZToSlice(alloc: std.mem.Allocator, value: ?[*:0]const u8) ?[]u8 {
    const ptr = value orelse return null;
    return alloc.dupe(u8, std.mem.span(ptr)) catch |err| {
        General.reportError(err);
        return null;
    };
}
