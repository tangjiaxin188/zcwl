//! Linux-generic EGL loader.
//!
//! This module is shared by the Wayland and future X11 backends. It uses only
//! opaque C handles and `dlopen`, so it has no dependency on generated Wayland
//! bindings and no hard link-time dependency on the GPU driver.

const std = @import("std");

pub const Display = ?*anyopaque;
pub const Config = ?*anyopaque;
pub const Context = ?*anyopaque;
pub const Surface = ?*anyopaque;
pub const NativeDisplayType = ?*anyopaque;
pub const NativeWindowType = ?*anyopaque;
pub const Int = i32;
pub const Boolean = u32;
pub const Enum = u32;
pub const ProcAddr = *const fn () callconv(.c) void;

pub const GetProcAddress = *const fn (procname: [*:0]const u8) callconv(.c) ?ProcAddr;
pub const GetPlatformDisplayEXT = ?*const fn (platform: Enum, native_display: NativeDisplayType, attrib_list: ?[*]const Int) callconv(.c) Display;

pub const SURFACE_TYPE: Int = 0x3033;
pub const WINDOW_BIT: Int = 0x0004;
pub const RENDERABLE_TYPE: Int = 0x3040;
pub const OPENGL_BIT: Int = 0x0008;
pub const OPENGL_ES2_BIT: Int = 0x0004;
pub const OPENGL_ES3_BIT: Int = 0x0040;
pub const RED_SIZE: Int = 0x3024;
pub const GREEN_SIZE: Int = 0x3023;
pub const BLUE_SIZE: Int = 0x3022;
pub const ALPHA_SIZE: Int = 0x3021;
pub const DEPTH_SIZE: Int = 0x3025;
pub const STENCIL_SIZE: Int = 0x3026;
pub const NONE: Int = 0x3038;
pub const OPENGL_API: Enum = 0x30A2;
pub const OPENGL_ES_API: Enum = 0x30A0;
pub const CONTEXT_MAJOR_VERSION: Int = 0x3098;
pub const CONTEXT_MINOR_VERSION: Int = 0x30FB;
pub const CONTEXT_OPENGL_PROFILE_MASK: Int = 0x30FD;
pub const CONTEXT_OPENGL_CORE_PROFILE_BIT: Int = 0x0001;
pub const CONTEXT_OPENGL_DEBUG: Int = 0x31B0;
pub const PLATFORM_WAYLAND_KHR: Enum = 0x31D8;

const names = [_][]const u8{ "libEGL.so.1", "libEGL.so" };

const GetDisplay = *const fn (display_id: NativeDisplayType) callconv(.c) Display;
const Initialize = *const fn (dpy: Display, major: [*c]Int, minor: [*c]Int) callconv(.c) Boolean;
const Terminate = *const fn (dpy: Display) callconv(.c) Boolean;
const ChooseConfig = *const fn (dpy: Display, attrib_list: [*c]const Int, configs: [*c]Config, config_size: Int, num_config: [*c]Int) callconv(.c) Boolean;
const BindAPI = *const fn (api: Enum) callconv(.c) Boolean;
const CreateContext = *const fn (dpy: Display, config: Config, share_context: Context, attrib_list: [*c]const Int) callconv(.c) Context;
const DestroyContext = *const fn (dpy: Display, ctx: Context) callconv(.c) Boolean;
const CreateWindowSurface = *const fn (dpy: Display, config: Config, win: NativeWindowType, attrib_list: [*c]const Int) callconv(.c) Surface;
const DestroySurface = *const fn (dpy: Display, surface: Surface) callconv(.c) Boolean;
const MakeCurrent = *const fn (dpy: Display, draw: Surface, read: Surface, ctx: Context) callconv(.c) Boolean;
const SwapBuffers = *const fn (dpy: Display, surface: Surface) callconv(.c) Boolean;
const SwapInterval = *const fn (dpy: Display, interval: Int) callconv(.c) Boolean;
const QueryString = *const fn (dpy: Display, name: Int) callconv(.c) [*c]const u8;
const GetError = *const fn () callconv(.c) Int;

pub const Error = error{
    EglUnavailable,
    MissingEglSymbol,
};

pub const Egl = struct {
    lib: std.DynLib,
    getProcAddress: GetProcAddress,
    getDisplay: GetDisplay,
    initialize: Initialize,
    terminate: Terminate,
    chooseConfig: ChooseConfig,
    bindAPI: BindAPI,
    createContext: CreateContext,
    destroyContext: DestroyContext,
    createWindowSurface: CreateWindowSurface,
    destroySurface: DestroySurface,
    makeCurrent: MakeCurrent,
    swapBuffers: SwapBuffers,
    swapInterval: SwapInterval,
    queryString: QueryString,
    getError: GetError,
    getPlatformDisplayEXT: GetPlatformDisplayEXT,

    pub fn open() !Egl {
        var lib = openFirst("ZCWL_EGL_LIB", &names) orelse return error.EglUnavailable;
        errdefer lib.close();

        var egl: Egl = undefined;
        egl.lib = lib;
        egl.getProcAddress = egl.lib.lookup(@TypeOf(egl.getProcAddress), "eglGetProcAddress") orelse return error.MissingEglSymbol;
        egl.getDisplay = egl.lib.lookup(@TypeOf(egl.getDisplay), "eglGetDisplay") orelse return error.MissingEglSymbol;
        egl.initialize = egl.lib.lookup(@TypeOf(egl.initialize), "eglInitialize") orelse return error.MissingEglSymbol;
        egl.terminate = egl.lib.lookup(@TypeOf(egl.terminate), "eglTerminate") orelse return error.MissingEglSymbol;
        egl.chooseConfig = egl.lib.lookup(@TypeOf(egl.chooseConfig), "eglChooseConfig") orelse return error.MissingEglSymbol;
        egl.bindAPI = egl.lib.lookup(@TypeOf(egl.bindAPI), "eglBindAPI") orelse return error.MissingEglSymbol;
        egl.createContext = egl.lib.lookup(@TypeOf(egl.createContext), "eglCreateContext") orelse return error.MissingEglSymbol;
        egl.destroyContext = egl.lib.lookup(@TypeOf(egl.destroyContext), "eglDestroyContext") orelse return error.MissingEglSymbol;
        egl.createWindowSurface = egl.lib.lookup(@TypeOf(egl.createWindowSurface), "eglCreateWindowSurface") orelse return error.MissingEglSymbol;
        egl.destroySurface = egl.lib.lookup(@TypeOf(egl.destroySurface), "eglDestroySurface") orelse return error.MissingEglSymbol;
        egl.makeCurrent = egl.lib.lookup(@TypeOf(egl.makeCurrent), "eglMakeCurrent") orelse return error.MissingEglSymbol;
        egl.swapBuffers = egl.lib.lookup(@TypeOf(egl.swapBuffers), "eglSwapBuffers") orelse return error.MissingEglSymbol;
        egl.swapInterval = egl.lib.lookup(@TypeOf(egl.swapInterval), "eglSwapInterval") orelse return error.MissingEglSymbol;
        egl.queryString = egl.lib.lookup(@TypeOf(egl.queryString), "eglQueryString") orelse return error.MissingEglSymbol;
        egl.getError = egl.lib.lookup(@TypeOf(egl.getError), "eglGetError") orelse return error.MissingEglSymbol;
        egl.getPlatformDisplayEXT = @ptrCast(egl.getProcAddress("eglGetPlatformDisplayEXT"));
        return egl;
    }

    pub fn close(self: *Egl) void {
        self.lib.close();
    }
};

fn openFirst(env_name: [:0]const u8, candidates: []const []const u8) ?std.DynLib {
    if (std.c.getenv(env_name)) |path| {
        if (std.DynLib.open(std.mem.span(path))) |lib| return lib else |_| {}
    }
    for (candidates) |name| {
        if (std.DynLib.open(name)) |lib| return lib else |_| {}
    }
    return null;
}
