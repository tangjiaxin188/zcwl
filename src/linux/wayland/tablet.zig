//! Wayland tablet (stylus) support via `zwp_tablet_manager_v2`.
//!
//! Tablet tools are reported as `Event.Pen*` with logical surface coordinates,
//! normalized pressure (0..1), tilt/rotation in degrees and an eraser flag.
//! Pads are ignored.

const std = @import("std");
const Event = @import("../../Event.zig");
const General = @import("../../General.zig");
const c = @import("protocols.zig").c;
const Sink = @import("event.zig").Sink;

pub const TabletSeat = struct {
    alloc: std.mem.Allocator,
    sink: Sink,
    object: *c.struct_zwp_tablet_seat_v2,
    tools: std.ArrayList(*Tool) = .empty,
    tablets: std.ArrayList(*Tablet) = .empty,
    next_pen_id: u32 = 1,

    pub fn init(
        alloc: std.mem.Allocator,
        manager: ?*c.struct_zwp_tablet_manager_v2,
        seat: ?*c.struct_wl_seat,
        sink: Sink,
    ) !?*TabletSeat {
        if (manager == null or seat == null) return null;
        const object = c.zwp_tablet_manager_v2_get_tablet_seat(manager, seat) orelse return null;

        const self = try alloc.create(TabletSeat);
        self.* = .{ .alloc = alloc, .sink = sink, .object = object };
        _ = c.zwp_tablet_seat_v2_add_listener(object, &seat_listener, self);
        return self;
    }

    pub fn deinit(self: *TabletSeat) void {
        for (self.tools.items) |tool| tool.deinit();
        for (self.tablets.items) |tablet| tablet.deinit();
        self.tools.deinit(self.alloc);
        self.tablets.deinit(self.alloc);
        c.zwp_tablet_seat_v2_destroy(self.object);
        self.alloc.destroy(self);
    }

    const seat_listener = c.struct_zwp_tablet_seat_v2_listener{
        .tablet_added = onTabletAdded,
        .tool_added = onToolAdded,
        .pad_added = onPadAdded,
    };

    fn onTabletAdded(data: ?*anyopaque, seat: ?*c.struct_zwp_tablet_seat_v2, id: ?*c.struct_zwp_tablet_v2) callconv(.c) void {
        _ = seat;
        const self: *TabletSeat = @ptrCast(@alignCast(data orelse return));
        const object = id orelse return;
        const tablet = Tablet.init(self.alloc, object) catch |err| {
            General.reportError(err);
            c.zwp_tablet_v2_destroy(object);
            return;
        };
        self.tablets.append(self.alloc, tablet) catch |err| {
            General.reportError(err);
            tablet.deinit();
        };
    }

    fn onToolAdded(data: ?*anyopaque, seat: ?*c.struct_zwp_tablet_seat_v2, id: ?*c.struct_zwp_tablet_tool_v2) callconv(.c) void {
        _ = seat;
        const self: *TabletSeat = @ptrCast(@alignCast(data orelse return));
        const object = id orelse return;
        const tool = Tool.init(self.alloc, self, object, self.next_pen_id) catch |err| {
            General.reportError(err);
            c.zwp_tablet_tool_v2_destroy(object);
            return;
        };
        self.next_pen_id +%= 1;
        self.tools.append(self.alloc, tool) catch |err| {
            General.reportError(err);
            tool.deinit();
        };
    }

    fn onPadAdded(data: ?*anyopaque, seat: ?*c.struct_zwp_tablet_seat_v2, id: ?*c.struct_zwp_tablet_pad_v2) callconv(.c) void {
        _ = data;
        _ = seat;
        // Pads are not exposed by Event.Core; destroy the unused object.
        if (id) |pad| c.zwp_tablet_pad_v2_destroy(pad);
    }
};

const Tablet = struct {
    alloc: std.mem.Allocator,
    object: *c.struct_zwp_tablet_v2,
    removed: bool = false,

    fn init(alloc: std.mem.Allocator, object: *c.struct_zwp_tablet_v2) !*Tablet {
        const self = try alloc.create(Tablet);
        self.* = .{ .alloc = alloc, .object = object };
        _ = c.zwp_tablet_v2_add_listener(object, &listener, self);
        return self;
    }

    fn deinit(self: *Tablet) void {
        c.zwp_tablet_v2_destroy(self.object);
        self.alloc.destroy(self);
    }

    const listener = c.struct_zwp_tablet_v2_listener{
        .name = onName,
        .id = onId,
        .path = onPath,
        .done = onDone,
        .removed = onRemoved,
    };

    fn onName(data: ?*anyopaque, tablet: ?*c.struct_zwp_tablet_v2, name: [*c]const u8) callconv(.c) void {
        _ = data;
        _ = tablet;
        _ = name;
    }

    fn onId(data: ?*anyopaque, tablet: ?*c.struct_zwp_tablet_v2, vid: u32, pid: u32) callconv(.c) void {
        _ = data;
        _ = tablet;
        _ = vid;
        _ = pid;
    }

    fn onPath(data: ?*anyopaque, tablet: ?*c.struct_zwp_tablet_v2, path: [*c]const u8) callconv(.c) void {
        _ = data;
        _ = tablet;
        _ = path;
    }

    fn onDone(data: ?*anyopaque, tablet: ?*c.struct_zwp_tablet_v2) callconv(.c) void {
        _ = data;
        _ = tablet;
    }

    fn onRemoved(data: ?*anyopaque, tablet: ?*c.struct_zwp_tablet_v2) callconv(.c) void {
        _ = tablet;
        const self: *Tablet = @ptrCast(@alignCast(data orelse return));
        self.removed = true;
    }
};
const Tool = struct {
    alloc: std.mem.Allocator,
    owner: *TabletSeat,
    object: *c.struct_zwp_tablet_tool_v2,
    id: u32,
    eraser: bool = false,
    window_id: ?u32 = null,
    in_proximity: bool = false,
    down: bool = false,
    removed: bool = false,
    x: f64 = 0,
    y: f64 = 0,
    pressure: f64 = 0,
    tilt_x: f64 = 0,
    tilt_y: f64 = 0,
    rotation: f64 = 0,

    fn init(
        alloc: std.mem.Allocator,
        owner: *TabletSeat,
        object: *c.struct_zwp_tablet_tool_v2,
        id: u32,
    ) !*Tool {
        const self = try alloc.create(Tool);
        self.* = .{
            .alloc = alloc,
            .owner = owner,
            .object = object,
            .id = id,
        };
        _ = c.zwp_tablet_tool_v2_add_listener(object, &listener, self);
        return self;
    }

    fn deinit(self: *Tool) void {
        c.zwp_tablet_tool_v2_destroy(self.object);
        self.alloc.destroy(self);
    }

    fn state(self: *Tool) Event.PenState {
        return .{
            .window_id = self.window_id orelse 0,
            .pen_id = self.id,
            .x = self.x,
            .y = self.y,
            .pressure = self.pressure,
            .tilt_x = self.tilt_x,
            .tilt_y = self.tilt_y,
            .rotation = self.rotation,
            .eraser = self.eraser,
        };
    }

    fn buttonState(self: *Tool, button: u32) Event.PenButton {
        return .{
            .window_id = self.window_id orelse 0,
            .pen_id = self.id,
            .button = mapButton(button),
            .x = self.x,
            .y = self.y,
            .pressure = self.pressure,
            .tilt_x = self.tilt_x,
            .tilt_y = self.tilt_y,
            .rotation = self.rotation,
            .eraser = self.eraser,
        };
    }

    fn emitMoved(self: *Tool) void {
        if (self.window_id == null) return;
        self.owner.sink.push(.{ .pen_moved = self.state() });
    }

    fn emitLeft(self: *Tool) void {
        const window_id = self.window_id orelse return;
        self.owner.sink.push(.{ .pen_left = .{ .window_id = window_id, .pen_id = self.id } });
    }

    fn onType(data: ?*anyopaque, tool: ?*c.struct_zwp_tablet_tool_v2, tool_type: u32) callconv(.c) void {
        _ = tool;
        const self: *Tool = @ptrCast(@alignCast(data orelse return));
        self.eraser = tool_type == @as(u32, @intCast(c.ZWP_TABLET_TOOL_V2_TYPE_ERASER));
    }

    fn onProximityIn(
        data: ?*anyopaque,
        tool: ?*c.struct_zwp_tablet_tool_v2,
        serial: u32,
        tablet: ?*c.struct_zwp_tablet_v2,
        surface: ?*c.struct_wl_surface,
    ) callconv(.c) void {
        _ = tool;
        _ = serial;
        _ = tablet;
        const self: *Tool = @ptrCast(@alignCast(data orelse return));
        self.window_id = self.owner.sink.windowForSurface(surface);
        self.in_proximity = true;
        if (self.window_id) |window_id| {
            self.owner.sink.push(.{ .pen_entered = self.state() });
            _ = window_id;
        }
    }

    fn onProximityOut(data: ?*anyopaque, tool: ?*c.struct_zwp_tablet_tool_v2) callconv(.c) void {
        _ = tool;
        const self: *Tool = @ptrCast(@alignCast(data orelse return));
        self.emitLeft();
        self.in_proximity = false;
        self.window_id = null;
    }

    fn onDown(data: ?*anyopaque, tool: ?*c.struct_zwp_tablet_tool_v2, serial: u32) callconv(.c) void {
        _ = tool;
        _ = serial;
        const self: *Tool = @ptrCast(@alignCast(data orelse return));
        self.down = true;
        if (self.window_id != null) self.owner.sink.push(.{ .pen_down = self.state() });
    }

    fn onUp(data: ?*anyopaque, tool: ?*c.struct_zwp_tablet_tool_v2) callconv(.c) void {
        _ = tool;
        const self: *Tool = @ptrCast(@alignCast(data orelse return));
        self.down = false;
        if (self.window_id != null) self.owner.sink.push(.{ .pen_up = self.state() });
    }

    fn onMotion(data: ?*anyopaque, tool: ?*c.struct_zwp_tablet_tool_v2, x: c.wl_fixed_t, y: c.wl_fixed_t) callconv(.c) void {
        _ = tool;
        const self: *Tool = @ptrCast(@alignCast(data orelse return));
        self.x = fixedToDouble(x);
        self.y = fixedToDouble(y);
        self.emitMoved();
    }

    fn onPressure(data: ?*anyopaque, tool: ?*c.struct_zwp_tablet_tool_v2, pressure: u32) callconv(.c) void {
        _ = tool;
        const self: *Tool = @ptrCast(@alignCast(data orelse return));
        self.pressure = @as(f64, @floatFromInt(pressure)) / 65535.0;
        self.emitMoved();
    }

    fn onTilt(data: ?*anyopaque, tool: ?*c.struct_zwp_tablet_tool_v2, tilt_x: c.wl_fixed_t, tilt_y: c.wl_fixed_t) callconv(.c) void {
        _ = tool;
        const self: *Tool = @ptrCast(@alignCast(data orelse return));
        self.tilt_x = fixedToDouble(tilt_x);
        self.tilt_y = fixedToDouble(tilt_y);
        self.emitMoved();
    }

    fn onRotation(data: ?*anyopaque, tool: ?*c.struct_zwp_tablet_tool_v2, degrees: c.wl_fixed_t) callconv(.c) void {
        _ = tool;
        const self: *Tool = @ptrCast(@alignCast(data orelse return));
        self.rotation = fixedToDouble(degrees);
        self.emitMoved();
    }

    fn onButton(
        data: ?*anyopaque,
        tool: ?*c.struct_zwp_tablet_tool_v2,
        serial: u32,
        button: u32,
        button_state: u32,
    ) callconv(.c) void {
        _ = tool;
        _ = serial;
        const self: *Tool = @ptrCast(@alignCast(data orelse return));
        if (self.window_id == null) return;
        if (button_state == @as(u32, @intCast(c.ZWP_TABLET_TOOL_V2_BUTTON_STATE_PRESSED))) {
            self.owner.sink.push(.{ .pen_button_down = self.buttonState(button) });
        } else {
            self.owner.sink.push(.{ .pen_button_up = self.buttonState(button) });
        }
    }

    fn onRemoved(data: ?*anyopaque, tool: ?*c.struct_zwp_tablet_tool_v2) callconv(.c) void {
        _ = tool;
        const self: *Tool = @ptrCast(@alignCast(data orelse return));
        self.emitLeft();
        self.in_proximity = false;
        self.window_id = null;
        self.removed = true;
    }

    const listener = c.struct_zwp_tablet_tool_v2_listener{
        .type = onType,
        .hardware_serial = onHardwareSerial,
        .hardware_id_wacom = onHardwareId,
        .capability = onCapability,
        .done = onDone,
        .removed = onRemoved,
        .proximity_in = onProximityIn,
        .proximity_out = onProximityOut,
        .down = onDown,
        .up = onUp,
        .motion = onMotion,
        .pressure = onPressure,
        .distance = onDistance,
        .tilt = onTilt,
        .rotation = onRotation,
        .slider = onSlider,
        .wheel = onWheel,
        .button = onButton,
        .frame = onFrame,
    };

    fn onHardwareSerial(data: ?*anyopaque, tool: ?*c.struct_zwp_tablet_tool_v2, hi: u32, lo: u32) callconv(.c) void {
        _ = data;
        _ = tool;
        _ = hi;
        _ = lo;
    }

    fn onHardwareId(data: ?*anyopaque, tool: ?*c.struct_zwp_tablet_tool_v2, hi: u32, lo: u32) callconv(.c) void {
        _ = data;
        _ = tool;
        _ = hi;
        _ = lo;
    }

    fn onCapability(data: ?*anyopaque, tool: ?*c.struct_zwp_tablet_tool_v2, capability: u32) callconv(.c) void {
        _ = data;
        _ = tool;
        _ = capability;
    }

    fn onDone(data: ?*anyopaque, tool: ?*c.struct_zwp_tablet_tool_v2) callconv(.c) void {
        _ = data;
        _ = tool;
    }

    fn onDistance(data: ?*anyopaque, tool: ?*c.struct_zwp_tablet_tool_v2, distance: u32) callconv(.c) void {
        _ = data;
        _ = tool;
        _ = distance;
    }

    fn onSlider(data: ?*anyopaque, tool: ?*c.struct_zwp_tablet_tool_v2, position: i32) callconv(.c) void {
        _ = data;
        _ = tool;
        _ = position;
    }

    fn onWheel(data: ?*anyopaque, tool: ?*c.struct_zwp_tablet_tool_v2, degrees: c.wl_fixed_t, clicks: i32) callconv(.c) void {
        _ = data;
        _ = tool;
        _ = degrees;
        _ = clicks;
    }

    fn onFrame(data: ?*anyopaque, tool: ?*c.struct_zwp_tablet_tool_v2, time: u32) callconv(.c) void {
        _ = data;
        _ = tool;
        _ = time;
    }
};

fn fixedToDouble(value: c.wl_fixed_t) f64 {
    return @as(f64, @floatFromInt(value)) / 256.0;
}

fn mapButton(button: u32) u8 {
    return switch (button) {
        0x14b => 1, // BTN_STYLUS
        0x14c => 2, // BTN_STYLUS2
        0x14a => 3, // BTN_TOUCH
        else => @intCast(button & 0xff),
    };
}
