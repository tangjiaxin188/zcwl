//! Wayland-specific runtime loader.
//!
//! EGL and xkbcommon are Linux-generic and live in `src/linux/egl.zig` and
//! `src/linux/xkb.zig`. This file only owns `libwayland-egl`, which maps a
//! `wl_surface` to an EGL window.

const std = @import("std");
const egl = @import("../egl.zig");
const xkb = @import("../xkb.zig");

pub const Egl = egl.Egl;
pub const Xkb = xkb.Xkb;

const names = [_][]const u8{ "libwayland-egl.so.1", "libwayland-egl.so" };

pub const WlEglWindow = opaque {};

const Create = *const fn (surface: ?*anyopaque, width: c_int, height: c_int) callconv(.c) ?*WlEglWindow;
const Destroy = *const fn (window: ?*WlEglWindow) callconv(.c) void;
const Resize = *const fn (window: ?*WlEglWindow, width: c_int, height: c_int, dx: c_int, dy: c_int) callconv(.c) void;
const GetAttachedSize = *const fn (window: ?*WlEglWindow, width: [*c]c_int, height: [*c]c_int) callconv(.c) void;

pub const Error = error{
    WaylandEglUnavailable,
    MissingWaylandEglSymbol,
};

pub const WaylandEgl = struct {
    lib: std.DynLib,
    create: Create,
    destroy: Destroy,
    resize: Resize,
    getAttachedSize: GetAttachedSize,

    pub fn open() !WaylandEgl {
        var lib = openFirst("ZCWL_WAYLAND_EGL_LIB", &names) orelse return error.WaylandEglUnavailable;
        errdefer lib.close();

        var w: WaylandEgl = undefined;
        w.lib = lib;
        w.create = w.lib.lookup(@TypeOf(w.create), "wl_egl_window_create") orelse return error.MissingWaylandEglSymbol;
        w.destroy = w.lib.lookup(@TypeOf(w.destroy), "wl_egl_window_destroy") orelse return error.MissingWaylandEglSymbol;
        w.resize = w.lib.lookup(@TypeOf(w.resize), "wl_egl_window_resize") orelse return error.MissingWaylandEglSymbol;
        w.getAttachedSize = w.lib.lookup(@TypeOf(w.getAttachedSize), "wl_egl_window_get_attached_size") orelse return error.MissingWaylandEglSymbol;
        return w;
    }

    pub fn close(self: *WaylandEgl) void {
        self.lib.close();
    }
};

/// All optional Wayland loaders. Missing libraries stay `null`.
pub const Loader = struct {
    egl: ?Egl = null,
    wayland_egl: ?WaylandEgl = null,
    xkb: ?Xkb = null,

    pub fn init() Loader {
        var loader = Loader{};
        loader.egl = Egl.open() catch null;
        loader.wayland_egl = WaylandEgl.open() catch null;
        loader.xkb = Xkb.open() catch null;
        return loader;
    }

    pub fn deinit(self: *Loader) void {
        if (self.egl) |*value| value.close();
        if (self.wayland_egl) |*value| value.close();
        if (self.xkb) |*value| value.close();
        self.* = .{};
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
