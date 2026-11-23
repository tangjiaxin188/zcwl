//! Caller-provided RGBA image converted to a Wayland `wl_shm` surface.
//! This module does not draw any cursor or drag icon of its own.

const std = @import("std");
const Config = @import("../../Config.zig");
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
    if (image.width == 0 or image.height == 0) return error.InvalidArgument;
    const width: usize = @intCast(image.width);
    const height: usize = @intCast(image.height);
    const pixel_count = std.math.mul(usize, width, height) catch return error.InvalidArgument;
    const byte_size = std.math.mul(usize, pixel_count, 4) catch return error.InvalidArgument;
    if (image.pixels.len < byte_size) return error.InvalidArgument;
    if (compositor == null or shm == null) return error.Unsupported;

    const fd = try std.posix.memfd_create("zcwl-image", 0);
    defer _ = std.c.close(fd);
    if (std.c.ftruncate(fd, @intCast(byte_size)) != 0) return error.ImageCreateFailed;

    const mem = try std.posix.mmap(
        null,
        byte_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    errdefer std.posix.munmap(mem);

    // Wayland ARGB8888 is little-endian 0xAARRGGBB; the caller supplies RGBA.
    const pixels: [*]u32 = @ptrCast(@alignCast(mem.ptr));
    for (0..pixel_count) |i| {
        const off = i * 4;
        const r = image.pixels[off];
        const g = image.pixels[off + 1];
        const b = image.pixels[off + 2];
        const a = image.pixels[off + 3];
        pixels[i] = (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
    }

    const pool = c.wl_shm_create_pool(shm, fd, @intCast(byte_size)) orelse
        return error.ImageCreateFailed;
    const buffer = c.wl_shm_pool_create_buffer(
        pool,
        0,
        @intCast(image.width),
        @intCast(image.height),
        @intCast(width * 4),
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
