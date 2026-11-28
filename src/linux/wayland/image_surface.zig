//! Caller-provided straight-alpha RGBA image converted to a Wayland `wl_shm`
//! surface. This module does not draw any cursor or drag icon of its own.

const std = @import("std");
const Config = @import("../../Config.zig");
const cursor_image = @import("../../cursor_image.zig");
const c = @import("protocols.zig").c;

pub const ImageSurface = struct {
    surface: *c.struct_wl_surface,
    buffer: *c.struct_wl_buffer,
    mem: []align(std.heap.page_size_min) u8,

    pub fn deinit(self: *ImageSurface) void {
        c.wl_surface_destroy(self.surface);
        c.wl_buffer_destroy(self.buffer);
        std.posix.munmap(self.mem);
        self.* = undefined;
    }
};

pub fn create(
    compositor: ?*c.struct_wl_compositor,
    shm: ?*c.struct_wl_shm,
    image: Config.CursorImage,
) !ImageSurface {
    const layout = try cursor_image.layout(image);
    if (compositor == null or shm == null) return error.Unsupported;

    const fd = try std.posix.memfd_create("zcwl-image", 0);
    defer _ = std.c.close(fd);
    if (std.c.ftruncate(fd, @intCast(layout.byte_size)) != 0) return error.ImageCreateFailed;

    const mem = try std.posix.mmap(
        null,
        layout.byte_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    errdefer std.posix.munmap(mem);

    // Wayland ARGB8888 is little-endian 0xAARRGGBB with premultiplied alpha;
    // the caller supplies straight-alpha RGBA.
    const pixels: [*]u32 = @ptrCast(@alignCast(mem.ptr));
    for (0..layout.pixel_count) |i| {
        const off = i * 4;
        pixels[i] = cursor_image.argbPremultiplied(
            image.pixels[off],
            image.pixels[off + 1],
            image.pixels[off + 2],
            image.pixels[off + 3],
        );
    }

    const pool = c.wl_shm_create_pool(shm, fd, @intCast(layout.byte_size)) orelse
        return error.ImageCreateFailed;
    const buffer = c.wl_shm_pool_create_buffer(
        pool,
        0,
        @intCast(image.width),
        @intCast(image.height),
        @intCast(layout.stride),
        @intCast(c.WL_SHM_FORMAT_ARGB8888),
    ) orelse {
        c.wl_shm_pool_destroy(pool);
        return error.ImageCreateFailed;
    };
    c.wl_shm_pool_destroy(pool);

    const surface = c.wl_compositor_create_surface(compositor) orelse {
        c.wl_buffer_destroy(buffer);
        return error.ImageCreateFailed;
    };
    errdefer c.wl_surface_destroy(surface);

    c.wl_surface_attach(surface, buffer, 0, 0);
    c.wl_surface_damage(surface, 0, 0, @intCast(image.width), @intCast(image.height));
    c.wl_surface_commit(surface);

    return .{ .surface = surface, .buffer = buffer, .mem = mem };
}
