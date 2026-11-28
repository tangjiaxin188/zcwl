//! Cursor image validation and pixel conversion shared by the public API and
//! the Wayland shm backend. Kept backend-independent so it can be unit tested
//! on every build.
const std = @import("std");
const Config = @import("Config.zig");

pub const Layout = struct {
    width: usize,
    height: usize,
    pixel_count: usize,
    stride: usize,
    byte_size: usize,
};

/// Validate a caller-provided cursor image.
///
/// The input is straight-alpha RGBA8, row-major, exactly `width * height * 4`
/// bytes. Dimensions, stride and total size must fit in `i32` because the
/// Wayland `wl_shm` API uses `int32_t` for them.
pub fn layout(image: Config.CursorImage) !Layout {
    if (image.width == 0 or image.height == 0) return error.InvalidSize;
    if (image.width > std.math.maxInt(i32) or image.height > std.math.maxInt(i32))
        return error.InvalidSize;

    const width: usize = @intCast(image.width);
    const height: usize = @intCast(image.height);
    const pixel_count = std.math.mul(usize, width, height) catch return error.InvalidArgument;
    const stride = std.math.mul(usize, width, 4) catch return error.InvalidArgument;
    const byte_size = std.math.mul(usize, pixel_count, 4) catch return error.InvalidArgument;

    if (stride > std.math.maxInt(i32) or byte_size > std.math.maxInt(i32))
        return error.InvalidArgument;
    if (image.pixels.len != byte_size) return error.InvalidArgument;

    if (image.hotspot_x < 0 or image.hotspot_y < 0) return error.InvalidArgument;
    const hotspot_x: u32 = @intCast(image.hotspot_x);
    const hotspot_y: u32 = @intCast(image.hotspot_y);
    if (hotspot_x >= image.width or hotspot_y >= image.height) return error.InvalidArgument;

    return .{
        .width = width,
        .height = height,
        .pixel_count = pixel_count,
        .stride = stride,
        .byte_size = byte_size,
    };
}

/// Convert one straight-alpha RGBA pixel to the little-endian `0xAARRGGBB`
/// value expected by `WL_SHM_FORMAT_ARGB8888`. Alpha is premultiplied because
/// wl_shm alpha formats are defined as premultiplied.
pub fn argbPremultiplied(r: u8, g: u8, b: u8, a: u8) u32 {
    const alpha: u32 = a;
    const pr = (@as(u32, r) * alpha + 127) / 255;
    const pg = (@as(u32, g) * alpha + 127) / 255;
    const pb = (@as(u32, b) * alpha + 127) / 255;
    return (alpha << 24) | (pr << 16) | (pg << 8) | pb;
}

test "cursor image layout accepts a valid image" {
    var pixels: [16]u8 = @splat(0);
    const l = try layout(.{
        .pixels = &pixels,
        .width = 2,
        .height = 2,
        .hotspot_x = 1,
        .hotspot_y = 1,
    });
    try std.testing.expectEqual(@as(usize, 2), l.width);
    try std.testing.expectEqual(@as(usize, 2), l.height);
    try std.testing.expectEqual(@as(usize, 4), l.pixel_count);
    try std.testing.expectEqual(@as(usize, 8), l.stride);
    try std.testing.expectEqual(@as(usize, 16), l.byte_size);
}

test "cursor image layout rejects invalid input" {
    var pixels: [16]u8 = @splat(0);

    try std.testing.expectError(error.InvalidSize, layout(.{
        .pixels = &pixels,
        .width = 0,
        .height = 2,
    }));
    try std.testing.expectError(error.InvalidArgument, layout(.{
        .pixels = pixels[0..15],
        .width = 2,
        .height = 2,
    }));
    try std.testing.expectError(error.InvalidArgument, layout(.{
        .pixels = &pixels,
        .width = 2,
        .height = 2,
        .hotspot_x = 2,
    }));
    try std.testing.expectError(error.InvalidArgument, layout(.{
        .pixels = &pixels,
        .width = 2,
        .height = 2,
        .hotspot_y = -1,
    }));

    // Dimensions and stride must fit the Wayland int32 API.
    try std.testing.expectError(error.InvalidSize, layout(.{
        .pixels = &.{},
        .width = std.math.maxInt(u32),
        .height = 1,
    }));
    try std.testing.expectError(error.InvalidArgument, layout(.{
        .pixels = &.{},
        .width = 1 << 30,
        .height = 1,
    }));
}

test "cursor image pixels are premultiplied" {
    try std.testing.expectEqual(@as(u32, 0x00000000), argbPremultiplied(0, 0, 0, 0));
    try std.testing.expectEqual(@as(u32, 0xFF102030), argbPremultiplied(0x10, 0x20, 0x30, 0xFF));
    // Half-transparent red: R is premultiplied to 128.
    try std.testing.expectEqual(@as(u32, 0x80800000), argbPremultiplied(255, 0, 0, 128));
}
