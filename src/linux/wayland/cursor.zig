//! Cursor handling: system shapes through `wp_cursor_shape_v1`, plus
//! caller-provided images keyed by `General.Cursor` state.

const General = @import("../../General.zig");
const Config = @import("../../Config.zig");
const c = @import("protocols.zig").c;
const image_surface = @import("image_surface.zig");

const CursorCount = @typeInfo(General.Cursor).@"enum".field_names.len;

const ImageSlot = struct {
    image: image_surface.ImageSurface,
    hotspot_x: i32,
    hotspot_y: i32,
};

pub const Cursor = struct {
    manager: ?*c.struct_wp_cursor_shape_manager_v1,
    pointer: ?*c.struct_wl_pointer,
    compositor: ?*c.struct_wl_compositor,
    shm: ?*c.struct_wl_shm,
    device: ?*c.struct_wp_cursor_shape_device_v1 = null,
    last_shape: General.Cursor = .arrow,
    visible: bool = true,
    images: [CursorCount]?ImageSlot = @splat(null),

    pub fn init(
        manager: ?*c.struct_wp_cursor_shape_manager_v1,
        pointer: ?*c.struct_wl_pointer,
        compositor: ?*c.struct_wl_compositor,
        shm: ?*c.struct_wl_shm,
    ) Cursor {
        return .{
            .manager = manager,
            .pointer = pointer,
            .compositor = compositor,
            .shm = shm,
        };
    }

    pub fn deinit(self: *Cursor) void {
        for (0..CursorCount) |i| {
            if (self.images[i]) |*slot| slot.image.deinit();
        }
        if (self.device) |device| c.wp_cursor_shape_device_v1_destroy(device);
        self.* = undefined;
    }

    /// Set the current cursor state. If an image is configured for this
    /// state, use it; otherwise use the system shape.
    pub fn set(self: *Cursor, serial: u32, shape: General.Cursor) !void {
        self.last_shape = shape;
        self.visible = true;
        try self.applyCurrent(serial);
    }

    /// Configure an image for one cursor state. The image is retained and is
    /// used whenever that state becomes current. The library does not draw
    /// any icon itself.
    pub fn setImage(
        self: *Cursor,
        serial: u32,
        state: General.Cursor,
        image: Config.CursorImage,
    ) !void {
        var new_image = try image_surface.create(self.compositor, self.shm, image);
        errdefer new_image.deinit();

        const index: usize = @intCast(@backingInt(state));
        if (self.images[index]) |*old| old.image.deinit();
        self.images[index] = .{
            .image = new_image,
            .hotspot_x = image.hotspot_x,
            .hotspot_y = image.hotspot_y,
        };

        if (state == self.last_shape and self.visible and serial != 0) {
            try self.applyCurrent(serial);
        }
    }

    /// Remove the custom image for a state. If it is the current state, the
    /// system shape is applied again.
    pub fn clearImage(self: *Cursor, serial: u32, state: General.Cursor) !void {
        const index: usize = @intCast(@backingInt(state));
        if (self.images[index]) |*old| old.image.deinit();
        self.images[index] = null;

        if (state == self.last_shape and self.visible) {
            try self.applyCurrent(serial);
        }
    }

    pub fn setVisible(self: *Cursor, serial: u32, visible: bool) !void {
        if (visible) {
            self.visible = true;
            try self.applyCurrent(serial);
            return;
        }
        self.visible = false;
        const pointer = self.pointer orelse return error.Unsupported;
        if (serial == 0) return error.WouldBlock;
        c.wl_pointer_set_cursor(pointer, serial, null, 0, 0);
    }

    fn applyCurrent(self: *Cursor, serial: u32) !void {
        const pointer = self.pointer orelse return error.Unsupported;
        if (serial == 0) return error.WouldBlock;

        const index: usize = @intCast(@backingInt(self.last_shape));
        if (self.images[index]) |slot| {
            c.wl_pointer_set_cursor(pointer, serial, slot.image.surface, slot.hotspot_x, slot.hotspot_y);
            return;
        }
        try self.applyShape(pointer, serial, self.last_shape);
    }

    fn applyShape(self: *Cursor, pointer: *c.struct_wl_pointer, serial: u32, shape: General.Cursor) !void {
        const manager = self.manager orelse return error.Unsupported;
        if (self.device == null)
            self.device = c.wp_cursor_shape_manager_v1_get_pointer(manager, pointer);
        const device = self.device orelse return error.Unsupported;
        c.wp_cursor_shape_device_v1_set_shape(device, serial, mapShape(shape));
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
        .copy => @intCast(c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_COPY),
        .no_drop => @intCast(c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NO_DROP),
        .grab => @intCast(c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_GRAB),
        .grabbing => @intCast(c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_GRABBING),
    };
}
