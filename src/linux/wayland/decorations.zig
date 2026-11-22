//! Optional `zxdg_decoration_manager_v1` integration.
//!
//! When the compositor does not advertise the protocol the window keeps its
//! requested `decorated` flag and `setDecorated` reports `error.Unsupported`.

const std = @import("std");
const c = @import("protocols.zig").c;

pub const Decoration = struct {
    object: *c.struct_zxdg_toplevel_decoration_v1,
    server_side: bool = true,

    pub fn init(
        manager: *c.struct_zxdg_decoration_manager_v1,
        toplevel: *c.struct_xdg_toplevel,
        decorated: bool,
    ) ?Decoration {
        const object = c.zxdg_decoration_manager_v1_get_toplevel_decoration(manager, toplevel) orelse return null;
        var self = Decoration{ .object = object };
        _ = c.zxdg_toplevel_decoration_v1_add_listener(object, &listener, null);
        self.setMode(decorated);
        return self;
    }

    pub fn deinit(self: *Decoration) void {
        c.zxdg_toplevel_decoration_v1_destroy(self.object);
    }

    pub fn setMode(self: *Decoration, decorated: bool) void {
        self.server_side = decorated;
        const mode: u32 = if (decorated)
            @intCast(c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE)
        else
            @intCast(c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE);
        c.zxdg_toplevel_decoration_v1_set_mode(self.object, mode);
    }

    const listener = c.struct_zxdg_toplevel_decoration_v1_listener{
        .configure = onConfigure,
    };

    fn onConfigure(data: ?*anyopaque, decoration: ?*c.struct_zxdg_toplevel_decoration_v1, mode: u32) callconv(.c) void {
        _ = data;
        _ = decoration;
        _ = mode;
    }
};
