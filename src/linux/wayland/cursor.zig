//! Cursor handling through `wp_cursor_shape_v1`.
//!
//! `wl_pointer.set_cursor` needs the serial of the enter event, so a shape is
//! only applied while the pointer is over a window owned by this backend.

const std = @import("std");
const General = @import("../../General.zig");
const c = @import("protocols.zig").c;

pub const Cursor = struct {
    manager: ?*c.struct_wp_cursor_shape_manager_v1,
    pointer: ?*c.struct_wl_pointer,
    device: ?*c.struct_wp_cursor_shape_device_v1 = null,
    last_shape: General.Cursor = .arrow,
    visible: bool = true,

    pub fn init(manager: ?*c.struct_wp_cursor_shape_manager_v1, pointer: ?*c.struct_wl_pointer) Cursor {
        return .{ .manager = manager, .pointer = pointer };
    }

    pub fn deinit(self: *Cursor) void {
        if (self.device) |device| c.wp_cursor_shape_device_v1_destroy(device);
        self.* = .{ .manager = null, .pointer = null };
    }

    pub fn set(self: *Cursor, serial: u32, shape: General.Cursor) !void {
        self.last_shape = shape;
        self.visible = true;
        const manager = self.manager orelse return error.Unsupported;
        const pointer = self.pointer orelse return error.Unsupported;
        if (serial == 0) return error.WouldBlock;

        if (self.device == null)
            self.device = c.wp_cursor_shape_manager_v1_get_pointer(manager, pointer);
        const device = self.device orelse return error.Unsupported;

        c.wp_cursor_shape_device_v1_set_shape(device, serial, mapShape(shape));
    }

    pub fn setVisible(self: *Cursor, serial: u32, visible: bool) !void {
        if (visible) {
            if (!self.visible) return self.set(serial, self.last_shape);
            return;
        }
        self.visible = false;
        const pointer = self.pointer orelse return error.Unsupported;
        if (serial == 0) return error.WouldBlock;
        c.wl_pointer_set_cursor(pointer, serial, null, 0, 0);
    }
};

fn mapShape(shape: General.Cursor) u32 {
    return switch (shape) {
        .arrow => @intCast(c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT),
        .ibeam => @intCast(c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_TEXT),
        .crosshair => @intCast(c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_CROSSHAIR),
        .pointing_hand => @intCast(c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_POINTER),
        .resize_ew => @intCast(c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_EW_RESIZE),
        .resize_ns => @intCast(c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NS_RESIZE),
        .resize_nwse => @intCast(c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NWSE_RESIZE),
        .resize_nesw => @intCast(c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NESW_RESIZE),
        .resize_all => @intCast(c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ALL_RESIZE),
        .not_allowed => @intCast(c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NOT_ALLOWED),
        .wait => @intCast(c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_WAIT),
        .progress => @intCast(c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_PROGRESS),
        .help => @intCast(c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_HELP),
        .move => @intCast(c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_MOVE),
    };
}
