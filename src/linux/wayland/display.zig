//! `wl_display`, registry and global object ownership.
//!
//! This module binds only the globals the backend needs. Optional protocols
//! are allowed to be missing; their fields stay null and the corresponding
//! window methods return `error.Unsupported` or fall back to a no-op.

const std = @import("std");
const General = @import("../../General.zig");
const c = @import("protocols.zig").c;

pub const Display = @This();

alloc: std.mem.Allocator,
display: *c.struct_wl_display,
registry: ?*c.struct_wl_registry = null,

compositor: ?*c.struct_wl_compositor = null,
seat: ?*c.struct_wl_seat = null,
wm_base: ?*c.struct_xdg_wm_base = null,
data_device_manager: ?*c.struct_wl_data_device_manager = null,

decoration_manager: ?*c.struct_zxdg_decoration_manager_v1 = null,
cursor_shape_manager: ?*c.struct_wp_cursor_shape_manager_v1 = null,
alpha_modifier: ?*c.struct_wp_alpha_modifier_v1 = null,
text_input_manager: ?*c.struct_zwp_text_input_manager_v3 = null,
tablet_manager: ?*c.struct_zwp_tablet_manager_v2 = null,

outputs: std.ArrayList(Global) = .empty,

pub const Global = struct {
    name: u32,
    version: u32,
};

pub const InitError = error{
    WaylandConnectFailed,
    WaylandRoundtripFailed,
    WaylandMissingCompositor,
    WaylandMissingXdgWmBase,
    OutOfMemory,
};

pub fn init(alloc: std.mem.Allocator) InitError!*Display {
    const dpy = c.wl_display_connect(null) orelse return error.WaylandConnectFailed;

    const self = alloc.create(Display) catch {
        c.wl_display_disconnect(dpy);
        return error.OutOfMemory;
    };
    self.* = .{ .alloc = alloc, .display = dpy };
    errdefer self.uninit();

    self.registry = c.wl_display_get_registry(dpy) orelse return error.WaylandConnectFailed;
    _ = c.wl_registry_add_listener(self.registry, &registry_listener, self);

    if (c.wl_display_roundtrip(dpy) < 0) return error.WaylandRoundtripFailed;
    if (self.compositor == null) return error.WaylandMissingCompositor;
    if (self.wm_base == null) return error.WaylandMissingXdgWmBase;
    return self;
}

pub fn uninit(self: *Display) void {
    self.outputs.deinit(self.alloc);

    if (self.text_input_manager) |v| c.zwp_text_input_manager_v3_destroy(v);
    if (self.tablet_manager) |v| c.zwp_tablet_manager_v2_destroy(v);
    if (self.alpha_modifier) |v| c.wp_alpha_modifier_v1_destroy(v);
    if (self.cursor_shape_manager) |v| c.wp_cursor_shape_manager_v1_destroy(v);
    if (self.decoration_manager) |v| c.zxdg_decoration_manager_v1_destroy(v);
    if (self.data_device_manager) |v| c.wl_data_device_manager_destroy(v);
    if (self.wm_base) |v| c.xdg_wm_base_destroy(v);
    if (self.seat) |v| c.wl_seat_release(v);
    if (self.compositor) |v| c.wl_compositor_destroy(v);
    if (self.registry) |v| c.wl_registry_destroy(v);

    _ = c.wl_display_flush(self.display);
    c.wl_display_disconnect(self.display);
    self.alloc.destroy(self);
}

/// Non-blocking event pump used by `Backend.pollEvent`.
pub fn pump(self: *Display) void {
    if (c.wl_display_dispatch_pending(self.display) < 0) {
        General.reportError(error.WaylandDispatchFailed);
        return;
    }

    if (c.wl_display_prepare_read(self.display) != 0) {
        _ = c.wl_display_dispatch_pending(self.display);
        return;
    }

    if (c.wl_display_flush(self.display) < 0) General.reportError(error.WaylandFlushFailed);

    var fds = [_]std.posix.pollfd{.{
        .fd = c.wl_display_get_fd(self.display),
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&fds, 0) catch 0;
    if (ready > 0 and (fds[0].revents & std.posix.POLL.IN) != 0) {
        if (c.wl_display_read_events(self.display) < 0) {
            General.reportError(error.WaylandDispatchFailed);
            return;
        }
        _ = c.wl_display_dispatch_pending(self.display);
    } else {
        c.wl_display_cancel_read(self.display);
    }
}

pub fn flush(self: *Display) void {
    if (c.wl_display_flush(self.display) < 0) General.reportError(error.WaylandFlushFailed);
}

pub fn roundtrip(self: *Display) void {
    if (c.wl_display_roundtrip(self.display) < 0) General.reportError(error.WaylandRoundtripFailed);
}

pub fn bindOutput(self: *Display, global: Global) ?*c.struct_wl_output {
    const version = @min(global.version, 4);
    const raw = c.wl_registry_bind(self.registry, global.name, &c.wl_output_interface, version) orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn bind(comptime T: type, registry: ?*c.struct_wl_registry, name: u32, iface: *const c.struct_wl_interface, version: u32) ?*T {
    const raw = c.wl_registry_bind(registry, name, iface, version) orelse return null;
    return @ptrCast(@alignCast(raw));
}

const registry_listener = c.struct_wl_registry_listener{
    .global = registryGlobal,
    .global_remove = registryGlobalRemove,
};

fn registryGlobal(
    data: ?*anyopaque,
    registry: ?*c.struct_wl_registry,
    name: u32,
    interface: [*c]const u8,
    version: u32,
) callconv(.c) void {
    const self: *Display = @ptrCast(@alignCast(data orelse return));
    if (interface == null) return;
    const iface = std.mem.span(@as([*:0]const u8, @ptrCast(interface)));

    if (std.mem.eql(u8, iface, "wl_compositor")) {
        if (self.compositor == null)
            self.compositor = bind(c.struct_wl_compositor, registry, name, &c.wl_compositor_interface, @min(version, 4));
    } else if (std.mem.eql(u8, iface, "wl_seat")) {
        if (self.seat == null)
            self.seat = bind(c.struct_wl_seat, registry, name, &c.wl_seat_interface, @min(version, 7));
    } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
        if (self.wm_base == null) {
            self.wm_base = bind(c.struct_xdg_wm_base, registry, name, &c.xdg_wm_base_interface, @min(version, 5));
            if (self.wm_base) |wm_base| _ = c.xdg_wm_base_add_listener(wm_base, &wm_base_listener, null);
        }
    } else if (std.mem.eql(u8, iface, "wl_data_device_manager")) {
        if (self.data_device_manager == null)
            self.data_device_manager = bind(c.struct_wl_data_device_manager, registry, name, &c.wl_data_device_manager_interface, @min(version, 3));
    } else if (std.mem.eql(u8, iface, "zxdg_decoration_manager_v1")) {
        if (self.decoration_manager == null)
            self.decoration_manager = bind(c.struct_zxdg_decoration_manager_v1, registry, name, &c.zxdg_decoration_manager_v1_interface, 1);
    } else if (std.mem.eql(u8, iface, "wp_cursor_shape_manager_v1")) {
        if (self.cursor_shape_manager == null)
            self.cursor_shape_manager = bind(c.struct_wp_cursor_shape_manager_v1, registry, name, &c.wp_cursor_shape_manager_v1_interface, 1);
    } else if (std.mem.eql(u8, iface, "wp_alpha_modifier_v1")) {
        if (self.alpha_modifier == null)
            self.alpha_modifier = bind(c.struct_wp_alpha_modifier_v1, registry, name, &c.wp_alpha_modifier_v1_interface, 1);
    } else if (std.mem.eql(u8, iface, "zwp_text_input_manager_v3")) {
        if (self.text_input_manager == null)
            self.text_input_manager = bind(c.struct_zwp_text_input_manager_v3, registry, name, &c.zwp_text_input_manager_v3_interface, 1);
    } else if (std.mem.eql(u8, iface, "zwp_tablet_manager_v2")) {
        if (self.tablet_manager == null)
            self.tablet_manager = bind(c.struct_zwp_tablet_manager_v2, registry, name, &c.zwp_tablet_manager_v2_interface, 1);
    } else if (std.mem.eql(u8, iface, "wl_output")) {
        self.outputs.append(self.alloc, .{ .name = name, .version = version }) catch |err| General.reportError(err);
    }
}

fn registryGlobalRemove(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32) callconv(.c) void {
    _ = data;
    _ = registry;
    _ = name;
}

const wm_base_listener = c.struct_xdg_wm_base_listener{
    .ping = onWmBasePing,
};

fn onWmBasePing(data: ?*anyopaque, wm_base: ?*c.struct_xdg_wm_base, serial: u32) callconv(.c) void {
    _ = data;
    const base = wm_base orelse return;
    c.xdg_wm_base_pong(base, serial);
}
