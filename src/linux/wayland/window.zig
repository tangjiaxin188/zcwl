//! Wayland toplevel window: `wl_surface` + `xdg_surface` + `xdg_toplevel`.
//!
//! Wayland has no programmatic global position and no direct `set_size`
//! request; sizing is driven by configure events. `getSize` therefore reports
//! the last acknowledged configure, while `setSize` records a request and
//! resizes any attached EGL window.

const std = @import("std");
const BackendMod = @import("backend.zig");
const Config = @import("../../Config.zig");
const General = @import("../../General.zig");
const Vulkan = @import("../../Vulkan.zig");
const c = @import("protocols.zig").c;
const Decoration = @import("decorations.zig").Decoration;
const Display = @import("display.zig").Display;

const Backend = BackendMod.Backend;
pub const Window = @This();

alloc: std.mem.Allocator,
backend: *Backend,
display: *Display,
id: u32,

surface: *c.struct_wl_surface,
xdg_surface: *c.struct_xdg_surface,
toplevel: *c.struct_xdg_toplevel,

title: []u8,
app_id: []u8,
size: General.Size,
requested_size: General.Size,
min_size: ?General.Size = null,
max_size: ?General.Size = null,
scale: f32 = 1.0,

resizable: bool,
decorated: bool,
always_on_top: bool,
opacity: f32 = 1.0,
fullscreen: bool = false,
maximized: bool = false,
minimized: bool = false,
client_api: General.GraphicsApi,
focused: bool = false,
configured: bool = false,

pending_width: i32 = 0,
pending_height: i32 = 0,
pending_maximized: bool = false,
pending_fullscreen: bool = false,

cursor: General.Cursor = .arrow,
cursor_visible: bool = true,
ime_allowed: bool = false,
ime_pos: General.Position = .{ .x = 0, .y = 0 },
ime_size: General.Size = .{ .w = 0, .h = 0 },
aspect_ratio: ?General.Ratio = null,

outputs: std.ArrayList(*c.struct_wl_output) = .empty,
decoration: ?Decoration = null,
alpha_surface: ?*c.struct_wp_alpha_modifier_surface_v1 = null,

pub fn init(backend: *Backend, config: Config.WindowConfig, id: u32) !*Window {
    const display = backend.display;
    const compositor = display.compositor orelse return error.Unsupported;
    const wm_base = display.wm_base orelse return error.Unsupported;

    const surface = c.wl_compositor_create_surface(compositor) orelse return error.WaylandSurfaceFailed;
    errdefer c.wl_surface_destroy(surface);

    const xdg_surface = c.xdg_wm_base_get_xdg_surface(wm_base, surface) orelse return error.WaylandSurfaceFailed;
    errdefer c.xdg_surface_destroy(xdg_surface);

    const toplevel = c.xdg_surface_get_toplevel(xdg_surface) orelse return error.WaylandSurfaceFailed;
    errdefer c.xdg_toplevel_destroy(toplevel);

    const title = try dupeZ(backend.alloc, config.title);
    errdefer backend.alloc.free(title);
    const app_id = try dupeZ(backend.alloc, backend.app_id);
    errdefer backend.alloc.free(app_id);

    const self = try backend.alloc.create(Window);
    self.* = .{
        .alloc = backend.alloc,
        .backend = backend,
        .display = display,
        .id = id,
        .surface = surface,
        .xdg_surface = xdg_surface,
        .toplevel = toplevel,
        .title = title,
        .app_id = app_id,
        .size = config.size,
        .requested_size = config.size,
        .resizable = config.resizable,
        .decorated = config.decorated,
        .always_on_top = config.always_on_top,
        .client_api = config.client_api,
    };

    _ = c.wl_surface_add_listener(surface, &surface_listener, self);
    _ = c.xdg_surface_add_listener(xdg_surface, &xdg_surface_listener, self);
    _ = c.xdg_toplevel_add_listener(toplevel, &toplevel_listener, self);

    if (self.app_id.len > 0) c.xdg_toplevel_set_app_id(toplevel, self.app_id.ptr);
    if (self.title.len > 0) c.xdg_toplevel_set_title(toplevel, self.title.ptr);
    self.applySizeLimits();

    if (display.decoration_manager) |manager| {
        self.decoration = Decoration.init(manager, toplevel, config.decorated);
    }
    if (display.alpha_modifier) |manager| {
        self.alpha_surface = c.wp_alpha_modifier_v1_get_surface(manager, surface);
    }

    // The first commit lets the compositor send the initial configure.
    c.wl_surface_commit(surface);
    return self;
}
pub fn uninit(self: *Window) void {
    if (self.alpha_surface) |alpha| c.wp_alpha_modifier_surface_v1_destroy(alpha);
    if (self.decoration) |*decoration| decoration.deinit();
    self.outputs.deinit(self.alloc);
    c.xdg_toplevel_destroy(self.toplevel);
    c.xdg_surface_destroy(self.xdg_surface);
    c.wl_surface_destroy(self.surface);
    self.alloc.free(self.title);
    self.alloc.free(self.app_id);
    self.backend.removeWindow(self);
    self.alloc.destroy(self);
}

pub fn getId(self: *Window) u32 {
    return self.id;
}

pub fn getNative(self: *Window) General.NativeWindow {
    return .{
        .ndt = @ptrCast(self.display.display),
        .nwh = @ptrCast(self.surface),
    };
}

pub fn setTitle(self: *Window, title: []const u8) !void {
    const copy = try dupeZ(self.alloc, title);
    self.alloc.free(self.title);
    self.title = copy;
    c.xdg_toplevel_set_title(self.toplevel, copy.ptr);
    self.requestCommit();
}

pub fn getTitle(self: *Window) []const u8 {
    return self.title;
}

pub fn setMaxSize(self: *Window, max_size: ?General.Size) void {
    self.max_size = max_size;
    self.applySizeLimits();
}

pub fn setMinSize(self: *Window, min_size: ?General.Size) void {
    self.min_size = min_size;
    self.applySizeLimits();
}

pub fn setSize(self: *Window, size: General.Size) void {
    self.requested_size = size;
    if (!self.configured) self.size = size;
    self.backend.resizeContexts(self.id, size);
    c.wl_surface_commit(self.surface);
}

pub fn getSize(self: *Window) General.Size {
    return self.size;
}

pub fn getRequestedSize(self: *Window) General.Size {
    return self.requested_size;
}

pub fn setPos(self: *Window, pos: General.Position) void {
    _ = self;
    _ = pos;
}

pub fn getPos(self: *Window) ?General.Position {
    _ = self;
    return null;
}

pub fn getFramebufferSize(self: *Window) General.Size {
    return .{
        .w = @intFromFloat(@as(f32, @floatFromInt(self.size.w)) * self.scale),
        .h = @intFromFloat(@as(f32, @floatFromInt(self.size.h)) * self.scale),
    };
}

pub fn getDpiScale(self: *Window) f32 {
    return self.scale;
}

pub fn setResizable(self: *Window, resizable: bool) void {
    self.resizable = resizable;
    self.applySizeLimits();
}

pub fn setFullscreen(self: *Window, fullscreen: bool) !void {
    if (fullscreen) {
        c.xdg_toplevel_set_fullscreen(self.toplevel, null);
    } else {
        c.xdg_toplevel_unset_fullscreen(self.toplevel);
    }
    self.fullscreen = fullscreen;
    self.requestCommit();
}

pub fn minimize(self: *Window) void {
    c.xdg_toplevel_set_minimized(self.toplevel);
    self.minimized = true;
    self.requestCommit();
}

pub fn maximize(self: *Window) void {
    c.xdg_toplevel_set_maximized(self.toplevel);
    self.maximized = true;
    self.requestCommit();
}

pub fn setFocus(self: *Window) void {
    _ = self;
}

pub fn requestAttention(self: *Window) !void {
    _ = self;
    return error.Unsupported;
}

pub fn setCursor(self: *Window, shape: General.Cursor) !void {
    self.cursor = shape;
    self.cursor_visible = true;
    try self.backend.cursor.set(self.backend.input.pointerSerial(), shape);
}

pub fn setCursorVisible(self: *Window, visible: bool) void {
    self.cursor_visible = visible;
    self.backend.cursor.setVisible(self.backend.input.pointerSerial(), visible) catch |err| {
        General.reportError(err);
    };
}

pub fn setCursorImage(self: *Window, state: General.Cursor, image: Config.CursorImage) !void {
    try self.backend.cursor.setImage(self.backend.input.pointerSerial(), state, image);
}

pub fn clearCursorImage(self: *Window, state: General.Cursor) !void {
    try self.backend.cursor.clearImage(self.backend.input.pointerSerial(), state);
}

/// Start dragging files out of this window. `paths` must be absolute paths or
/// `file://` URIs. The pointer serial must be current; otherwise WouldBlock.
pub fn startDragFiles(self: *Window, paths: []const []const u8) !void {
    return self.backend.startDragFiles(self, paths);
}

pub fn setAspectRatio(self: *Window, ratio: ?General.Ratio) void {
    self.aspect_ratio = ratio;
}

pub fn setImeAllowed(self: *Window, allowed: bool) !void {
    if (self.backend.ime == null) return error.Unsupported;
    self.ime_allowed = allowed;
    self.backend.ime.?.setAllowed(allowed);
}

pub fn setImeCursorArea(self: *Window, pos: General.Position, size: General.Size) void {
    self.ime_pos = pos;
    self.ime_size = size;
    if (self.backend.ime) |*ime| ime.setCursorArea(self.id, pos, size);
}

pub fn getInfo(self: *Window) General.WindowInfo {
    return .{
        .size = self.size,
        .framebuffer_size = self.getFramebufferSize(),
        .position = null,
        .dpi_scale = self.scale,
        .client_api = self.client_api,
        .fullscreen = self.fullscreen,
        .maximized = self.maximized,
        .minimized = self.minimized,
        .focused = self.focused,
        .resizable = self.resizable,
        .decorated = self.decorated,
        .always_on_top = self.always_on_top,
        .opacity = self.opacity,
    };
}

pub fn setIcon(self: *Window, rgba: []const u8, width: u32, height: u32) !void {
    _ = self;
    _ = rgba;
    _ = width;
    _ = height;
    return error.Unsupported;
}

pub fn setDecorated(self: *Window, decorated: bool) !void {
    if (self.decoration) |*decoration| {
        decoration.setMode(decorated);
        self.decorated = decorated;
        c.wl_surface_commit(self.surface);
        return;
    }
    return error.Unsupported;
}

pub fn setAlwaysOnTop(self: *Window, always_on_top: bool) !void {
    _ = self;
    _ = always_on_top;
    return error.Unsupported;
}

pub fn setOpacity(self: *Window, opacity: f32) !void {
    const clamped = std.math.clamp(opacity, 0.0, 1.0);
    const alpha = self.alpha_surface orelse {
        if (clamped == 1.0) {
            self.opacity = 1.0;
            return;
        }
        return error.Unsupported;
    };
    const factor: u32 = @intFromFloat(clamped * 256.0);
    c.wp_alpha_modifier_surface_v1_set_multiplier(alpha, factor);
    self.opacity = clamped;
    c.wl_surface_commit(self.surface);
}

pub fn createVulkanSurface(
    self: *Window,
    instance: Vulkan.Instance,
    get_instance_proc_addr: Vulkan.GetInstanceProcAddr,
    allocator: ?*const Vulkan.AllocationCallbacks,
) !Vulkan.SurfaceKHR {
    const vulkan = @import("vulkan.zig");
    return vulkan.createSurface(self.display.display, self.surface, instance, get_instance_proc_addr, allocator);
}

pub fn isConfigured(self: *Window) bool {
    return self.configured;
}

pub fn hasOutput(self: *Window, output: *c.struct_wl_output) bool {
    for (self.outputs.items) |item| {
        if (item == output) return true;
    }
    return false;
}

pub fn applyCursor(self: *Window, serial: u32) void {
    if (self.cursor_visible) {
        self.backend.cursor.set(serial, self.cursor) catch |err| General.reportError(err);
    } else {
        self.backend.cursor.setVisible(serial, false) catch |err| General.reportError(err);
    }
}

fn applySizeLimits(self: *Window) void {
    const min = if (self.resizable) self.min_size else self.size;
    const max = if (self.resizable) self.max_size else self.size;
    c.xdg_toplevel_set_min_size(
        self.toplevel,
        if (min) |v| @intCast(v.w) else 0,
        if (min) |v| @intCast(v.h) else 0,
    );
    c.xdg_toplevel_set_max_size(
        self.toplevel,
        if (max) |v| @intCast(v.w) else 0,
        if (max) |v| @intCast(v.h) else 0,
    );
    self.requestCommit();
}

fn requestCommit(self: *Window) void {
    c.wl_surface_commit(self.surface);
}

fn applyPendingConfigure(self: *Window) void {
    var new_size = self.size;
    if (self.pending_width > 0 and self.pending_height > 0) {
        new_size = .{ .w = @intCast(self.pending_width), .h = @intCast(self.pending_height) };
    } else if (!self.configured) {
        new_size = self.requested_size;
    }
    if (new_size.w != self.size.w or new_size.h != self.size.h) {
        self.size = new_size;
        self.backend.resizeContexts(self.id, new_size);
        self.backend.pushEvent(.{ .window_resized = .{
            .window_id = self.id,
            .width = new_size.w,
            .height = new_size.h,
        } });
    }

    if (self.pending_maximized != self.maximized) {
        self.maximized = self.pending_maximized;
        if (self.maximized) {
            self.backend.pushEvent(.{ .window_maximized = .{ .window_id = self.id } });
        } else {
            self.backend.pushEvent(.{ .window_restored = .{ .window_id = self.id } });
        }
    }
    self.fullscreen = self.pending_fullscreen;
    self.configured = true;
}

const surface_listener = c.struct_wl_surface_listener{
    .enter = onSurfaceEnter,
    .leave = onSurfaceLeave,
    .preferred_buffer_scale = onSurfacePreferredScale,
    .preferred_buffer_transform = onSurfacePreferredTransform,
};

fn onSurfaceEnter(data: ?*anyopaque, surface: ?*c.struct_wl_surface, output: ?*c.struct_wl_output) callconv(.c) void {
    _ = surface;
    const self: *Window = @ptrCast(@alignCast(data orelse return));
    const out = output orelse return;
    for (self.outputs.items) |existing| {
        if (existing == out) return;
    }
    self.outputs.append(self.alloc, out) catch return;
    self.updateScale();
}

fn onSurfaceLeave(data: ?*anyopaque, surface: ?*c.struct_wl_surface, output: ?*c.struct_wl_output) callconv(.c) void {
    _ = surface;
    const self: *Window = @ptrCast(@alignCast(data orelse return));
    const out = output orelse return;
    var i: usize = 0;
    while (i < self.outputs.items.len) : (i += 1) {
        if (self.outputs.items[i] == out) {
            _ = self.outputs.orderedRemove(i);
            self.updateScale();
            return;
        }
    }
}

const xdg_surface_listener = c.struct_xdg_surface_listener{
    .configure = onXdgSurfaceConfigure,
};

fn onXdgSurfaceConfigure(
    data: ?*anyopaque,
    xdg_surface: ?*c.struct_xdg_surface,
    serial: u32,
) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(data orelse return));
    const surface = xdg_surface orelse return;
    c.xdg_surface_ack_configure(surface, serial);
    self.applyPendingConfigure();
    c.wl_surface_commit(self.surface);
}

const toplevel_listener = c.struct_xdg_toplevel_listener{
    .configure = onToplevelConfigure,
    .close = onToplevelClose,
    .configure_bounds = onToplevelConfigureBounds,
    .wm_capabilities = onToplevelWmCapabilities,
};

fn onToplevelConfigure(
    data: ?*anyopaque,
    toplevel: ?*c.struct_xdg_toplevel,
    width: i32,
    height: i32,
    states: [*c]c.struct_wl_array,
) callconv(.c) void {
    _ = toplevel;
    const self: *Window = @ptrCast(@alignCast(data orelse return));
    self.pending_width = width;
    self.pending_height = height;
    self.pending_maximized = false;
    self.pending_fullscreen = false;
    self.focused = false;

    if (states != null) {
        const arr = states[0];
        if (arr.data) |raw| {
            const items: [*]const u32 = @ptrCast(@alignCast(raw));
            const count = arr.size / @sizeOf(u32);
            for (items[0..count]) |value| {
                if (value == @as(u32, @intCast(c.XDG_TOPLEVEL_STATE_MAXIMIZED))) self.pending_maximized = true;
                if (value == @as(u32, @intCast(c.XDG_TOPLEVEL_STATE_FULLSCREEN))) self.pending_fullscreen = true;
                if (value == @as(u32, @intCast(c.XDG_TOPLEVEL_STATE_ACTIVATED))) self.focused = true;
            }
        }
    }
}

fn onToplevelClose(data: ?*anyopaque, toplevel: ?*c.struct_xdg_toplevel) callconv(.c) void {
    _ = toplevel;
    const self: *Window = @ptrCast(@alignCast(data orelse return));
    self.backend.pushEvent(.{ .window_should_close = .{ .window_id = self.id } });
}

pub fn updateScale(self: *Window) void {
    var new_scale: f32 = 1.0;
    for (self.outputs.items) |output| {
        const candidate = self.backend.scaleForOutput(output);
        if (candidate > new_scale) new_scale = candidate;
    }
    if (new_scale == self.scale) return;
    self.scale = new_scale;
    c.wl_surface_set_buffer_scale(self.surface, @intFromFloat(new_scale));
    c.wl_surface_commit(self.surface);
    self.backend.pushEvent(.{ .window_scale_changed = .{
        .window_id = self.id,
        .scale = new_scale,
    } });
}

fn dupeZ(alloc: std.mem.Allocator, value: []const u8) ![]u8 {
    const buf = try alloc.alloc(u8, value.len + 1);
    @memcpy(buf[0..value.len], value);
    buf[value.len] = 0;
    return buf;
}

fn onSurfacePreferredScale(data: ?*anyopaque, surface: ?*c.struct_wl_surface, factor: i32) callconv(.c) void {
    _ = data;
    _ = surface;
    _ = factor;
}

fn onSurfacePreferredTransform(data: ?*anyopaque, surface: ?*c.struct_wl_surface, transform: u32) callconv(.c) void {
    _ = data;
    _ = surface;
    _ = transform;
}

fn onToplevelConfigureBounds(data: ?*anyopaque, toplevel: ?*c.struct_xdg_toplevel, width: i32, height: i32) callconv(.c) void {
    _ = data;
    _ = toplevel;
    _ = width;
    _ = height;
}

fn onToplevelWmCapabilities(data: ?*anyopaque, toplevel: ?*c.struct_xdg_toplevel, capabilities: [*c]c.struct_wl_array) callconv(.c) void {
    _ = data;
    _ = toplevel;
    _ = capabilities;
}
