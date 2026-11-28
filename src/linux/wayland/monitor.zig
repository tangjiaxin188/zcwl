//! `wl_output` tracking. Without xdg-output this exposes the compositor's
//! logical geometry as-is; scale is the integer buffer scale.

const std = @import("std");
const General = @import("../../General.zig");
const c = @import("protocols.zig").c;
const Display = @import("display.zig").Display;
const Backend = @import("backend.zig").Backend;

pub const Monitor = @This();

alloc: std.mem.Allocator,
backend: *Backend,
output: *c.struct_wl_output,
version: u32,
global_name: u32,

name_buf: ?[]u8 = null,
position: General.Position = .{ .x = 0, .y = 0 },
size: General.Size = .{ .w = 0, .h = 0 },
scale: i32 = 1,
refresh_mhz: i32 = 0,
done: bool = false,

pub fn init(alloc: std.mem.Allocator, backend: *Backend, display: *Display, global: Display.Global) ?*Monitor {
    const output = display.bindOutput(global) orelse return null;
    const self = alloc.create(Monitor) catch |err| {
        backend.reportError(err);
        c.wl_output_release(output);
        return null;
    };
    self.* = .{
        .alloc = alloc,
        .backend = backend,
        .output = output,
        .version = @min(global.version, 4),
        .global_name = global.name,
    };
    _ = c.wl_output_add_listener(output, &listener, self);
    return self;
}

pub fn uninit(self: *Monitor) void {
    if (self.version >= 3) {
        c.wl_output_release(self.output);
    } else {
        c.wl_output_destroy(self.output);
    }
    if (self.name_buf) |buf| self.alloc.free(buf);
    self.alloc.destroy(self);
}

pub fn info(self: *Monitor) General.MonitorInfo {
    return .{
        .id = self.global_name,
        .name = self.name_buf orelse "",
        .position = self.position,
        .size = self.size,
        .work_area = self.size,
        .dpi_scale = @floatFromInt(self.scale),
        .refresh_hz = @as(f32, @floatFromInt(self.refresh_mhz)) / 1000.0,
    };
}

const listener = c.struct_wl_output_listener{
    .geometry = onGeometry,
    .mode = onMode,
    .done = onDone,
    .scale = onScale,
    .name = onName,
    .description = onDescription,
};

fn onGeometry(
    data: ?*anyopaque,
    output: ?*c.struct_wl_output,
    x: i32,
    y: i32,
    physical_width: i32,
    physical_height: i32,
    subpixel: i32,
    make: [*c]const u8,
    model: [*c]const u8,
    transform: i32,
) callconv(.c) void {
    _ = output;
    _ = physical_width;
    _ = physical_height;
    _ = subpixel;
    _ = make;
    _ = model;
    _ = transform;
    const self: *Monitor = @ptrCast(@alignCast(data orelse return));
    self.position = .{ .x = x, .y = y };
}

fn onMode(
    data: ?*anyopaque,
    output: ?*c.struct_wl_output,
    flags: u32,
    width: i32,
    height: i32,
    refresh: i32,
) callconv(.c) void {
    _ = output;
    const self: *Monitor = @ptrCast(@alignCast(data orelse return));
    if ((flags & @as(u32, @intCast(c.WL_OUTPUT_MODE_CURRENT))) != 0) {
        if (width > 0 and height > 0) {
            self.size = .{ .w = @intCast(width), .h = @intCast(height) };
        }
        self.refresh_mhz = refresh;
    }
}

fn onDone(data: ?*anyopaque, output: ?*c.struct_wl_output) callconv(.c) void {
    _ = output;
    const self: *Monitor = @ptrCast(@alignCast(data orelse return));
    self.done = true;
}

fn onScale(data: ?*anyopaque, output: ?*c.struct_wl_output, factor: i32) callconv(.c) void {
    _ = output;
    const self: *Monitor = @ptrCast(@alignCast(data orelse return));
    if (factor > 0) {
        self.scale = factor;
        self.backend.monitorScaleChanged(self.output);
    }
}

fn onName(data: ?*anyopaque, output: ?*c.struct_wl_output, name: [*c]const u8) callconv(.c) void {
    _ = output;
    const self: *Monitor = @ptrCast(@alignCast(data orelse return));
    if (name == null) return;
    const text = std.mem.span(@as([*:0]const u8, @ptrCast(name)));
    const copy = self.alloc.dupe(u8, text) catch |err| {
        self.backend.reportError(err);
        return;
    };
    if (self.name_buf) |old| self.alloc.free(old);
    self.name_buf = copy;
}

fn onDescription(data: ?*anyopaque, output: ?*c.struct_wl_output, description: [*c]const u8) callconv(.c) void {
    _ = data;
    _ = output;
    _ = description;
}
