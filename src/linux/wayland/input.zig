//! `wl_seat` input handling: pointer, keyboard and touch.
//! Touchscreen input is mapped to left mouse-button events, not a touch type.
//!
//! Keyboard translation uses xkbcommon when available. A key event is emitted
//! for the initial press (`repeat = false`), repeated presses (`repeat = true`)
//! and the final release (`key_up`). Repetition is detected from the Wayland
//! `REPEATED` state (keyboard v10+) or from a second press while the key is
//! still logically down; no client-side repeat timer is installed.

const std = @import("std");
const Event = @import("../../Event.zig");
const General = @import("../../General.zig");
const c = @import("protocols.zig").c;
const Sink = @import("event.zig").Sink;
const loader = @import("loader.zig");
const tablet_mod = @import("tablet.zig");
const xkb_mod = @import("../xkb.zig");

pub const Input = @This();

alloc: std.mem.Allocator,
sink: Sink,
xkb: ?*loader.Xkb,
seat: ?*c.struct_wl_seat,

pointer: ?*c.struct_wl_pointer = null,
keyboard: ?*c.struct_wl_keyboard = null,
touch: ?*c.struct_wl_touch = null,
tablet: ?*tablet_mod.TabletSeat = null,

xkb_context: ?*xkb_mod.Context = null,
xkb_keymap: ?*xkb_mod.Keymap = null,
xkb_state: ?*xkb_mod.State = null,

idx_shift: xkb_mod.ModIndex = 0,
idx_control: xkb_mod.ModIndex = 0,
idx_alt: xkb_mod.ModIndex = 0,
idx_super: xkb_mod.ModIndex = 0,
idx_caps: xkb_mod.ModIndex = 0,
idx_num: xkb_mod.ModIndex = 0,

mods: Event.Mods = .{},
keys_down: std.bit_set.Static(1024) = .empty,
last_serial: u32 = 0,
pointer_serial: u32 = 0,
pointer_window: ?u32 = null,
pointer_pos: General.Vector2 = .{ .x = 0, .y = 0 },
keyboard_window: ?u32 = null,
repeat_rate: i32 = 0,
repeat_delay: i32 = 0,
touch_active_id: ?i32 = null,
touch_window: ?u32 = null,
touch_x: f32 = 0,
touch_y: f32 = 0,

pub fn init(
    alloc: std.mem.Allocator,
    sink: Sink,
    xkb: ?*loader.Xkb,
    tablet_manager: ?*c.struct_zwp_tablet_manager_v2,
    seat: ?*c.struct_wl_seat,
) !*Input {
    const self = try alloc.create(Input);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .sink = sink,
        .xkb = xkb,
        .seat = seat,
    };

    if (xkb) |x| {
        self.xkb_context = x.contextNew(xkb_mod.CONTEXT_NO_FLAGS);
        if (self.xkb_context == null) return error.XkbContextFailed;
    }
    errdefer {
        if (xkb) |x| {
            if (self.xkb_context) |ctx| x.contextUnref(ctx);
        }
    }
    self.tablet = try tablet_mod.TabletSeat.init(alloc, tablet_manager, seat, sink);
    if (seat) |s| {
        _ = c.wl_seat_add_listener(s, &seat_listener, self);
    }
    return self;
}

pub fn uninit(self: *Input) void {
    if (self.tablet) |value| value.deinit();
    if (self.touch) |v| releaseTouch(v);
    if (self.keyboard) |v| releaseKeyboard(v);
    if (self.pointer) |v| releasePointer(v);
    if (self.xkb) |x| {
        if (self.xkb_state) |v| x.stateUnref(v);
        if (self.xkb_keymap) |v| x.keymapUnref(v);
        if (self.xkb_context) |v| x.contextUnref(v);
    }
    self.alloc.destroy(self);
}

pub fn lastSerial(self: *Input) u32 {
    if (self.pointer_serial > self.last_serial) return self.pointer_serial;
    return self.last_serial;
}

pub fn pointerDevice(self: *Input) ?*c.struct_wl_pointer {
    return self.pointer;
}

pub fn pointerSerial(self: *Input) u32 {
    return self.pointer_serial;
}

fn finishTouch(self: *Input) void {
    if (self.touch_window) |window_id| {
        self.sink.push(.{ .mouse_button_up = .{
            .window_id = window_id,
            .button = .left,
            .mods = .{},
        } });
        self.sink.push(.{ .mouse_left = .{ .window_id = window_id } });
    }
    self.touch_active_id = null;
    self.touch_window = null;
}

pub fn keyboardFocusWindow(self: *Input) ?u32 {
    return self.keyboard_window;
}

const seat_listener = c.struct_wl_seat_listener{
    .capabilities = onCapabilities,
    .name = onSeatName,
};

fn onCapabilities(data: ?*anyopaque, seat: ?*c.struct_wl_seat, capabilities: u32) callconv(.c) void {
    const self: *Input = @ptrCast(@alignCast(data orelse return));

    if ((capabilities & @as(u32, @intCast(c.WL_SEAT_CAPABILITY_POINTER))) != 0) {
        if (self.pointer == null) {
            self.pointer = c.wl_seat_get_pointer(seat);
            if (self.pointer) |pointer| _ = c.wl_pointer_add_listener(pointer, &pointer_listener, self);
            self.sink.pointerChanged(self.pointer);
        }
    } else if (self.pointer) |pointer| {
        if (self.pointer_window) |window_id| {
            self.sink.push(.{ .mouse_left = .{ .window_id = window_id } });
            self.pointer_window = null;
        }
        self.sink.pointerChanged(null);
        releasePointer(pointer);
        self.pointer = null;
    }

    if ((capabilities & @as(u32, @intCast(c.WL_SEAT_CAPABILITY_KEYBOARD))) != 0) {
        if (self.keyboard == null) {
            self.keyboard = c.wl_seat_get_keyboard(seat);
            if (self.keyboard) |keyboard| _ = c.wl_keyboard_add_listener(keyboard, &keyboard_listener, self);
        }
    } else if (self.keyboard) |keyboard| {
        if (self.keyboard_window) |window_id| {
            self.sink.push(.{ .window_focus_lost = .{ .window_id = window_id } });
            self.keyboard_window = null;
            self.sink.focus(null);
        }
        self.keys_down = .empty;
        releaseKeyboard(keyboard);
        self.keyboard = null;
    }

    if ((capabilities & @as(u32, @intCast(c.WL_SEAT_CAPABILITY_TOUCH))) != 0) {
        if (self.touch == null) {
            self.touch = c.wl_seat_get_touch(seat);
            if (self.touch) |touch| _ = c.wl_touch_add_listener(touch, &touch_listener, self);
        }
    } else if (self.touch) |touch| {
        self.finishTouch();
        releaseTouch(touch);
        self.touch = null;
    }
}

fn onSeatName(data: ?*anyopaque, seat: ?*c.struct_wl_seat, name: [*c]const u8) callconv(.c) void {
    _ = data;
    _ = seat;
    _ = name;
}
const pointer_listener = c.struct_wl_pointer_listener{
    .enter = onPointerEnter,
    .leave = onPointerLeave,
    .motion = onPointerMotion,
    .button = onPointerButton,
    .axis = onPointerAxis,
    .frame = onPointerFrame,
    .axis_source = onPointerAxisSource,
    .axis_stop = onPointerAxisStop,
    .axis_discrete = onPointerAxisDiscrete,
    .axis_value120 = onPointerAxisValue120,
    .axis_relative_direction = onPointerAxisRelativeDirection,
    .warp = onPointerWarp,
};

fn fixedToFloat(value: c.wl_fixed_t) f32 {
    return @as(f32, @floatFromInt(value)) / 256.0;
}

fn onPointerEnter(
    data: ?*anyopaque,
    pointer: ?*c.struct_wl_pointer,
    serial: u32,
    surface: ?*c.struct_wl_surface,
    surface_x: c.wl_fixed_t,
    surface_y: c.wl_fixed_t,
) callconv(.c) void {
    _ = pointer;
    const self: *Input = @ptrCast(@alignCast(data orelse return));
    self.pointer_serial = serial;
    if (serial > self.last_serial) self.last_serial = serial;
    self.pointer_pos = .{ .x = fixedToFloat(surface_x), .y = fixedToFloat(surface_y) };
    self.pointer_window = self.sink.windowForSurface(surface);
    if (self.pointer_window) |window_id| {
        self.sink.push(.{ .mouse_entered = .{ .window_id = window_id } });
        self.sink.applyCursor(window_id, serial);
    }
}

fn onPointerLeave(
    data: ?*anyopaque,
    pointer: ?*c.struct_wl_pointer,
    serial: u32,
    surface: ?*c.struct_wl_surface,
) callconv(.c) void {
    _ = pointer;
    _ = serial;
    _ = surface;
    const self: *Input = @ptrCast(@alignCast(data orelse return));
    if (self.pointer_window) |window_id| {
        self.sink.push(.{ .mouse_left = .{ .window_id = window_id } });
    }
    self.pointer_window = null;
}

fn onPointerMotion(
    data: ?*anyopaque,
    pointer: ?*c.struct_wl_pointer,
    time: u32,
    surface_x: c.wl_fixed_t,
    surface_y: c.wl_fixed_t,
) callconv(.c) void {
    _ = pointer;
    _ = time;
    const self: *Input = @ptrCast(@alignCast(data orelse return));
    self.pointer_pos = .{ .x = fixedToFloat(surface_x), .y = fixedToFloat(surface_y) };
    const window_id = self.pointer_window orelse return;
    self.sink.push(.{ .mouse_moved = .{
        .window_id = window_id,
        .x = self.pointer_pos.x,
        .y = self.pointer_pos.y,
        .mods = self.mods,
    } });
}

fn onPointerButton(
    data: ?*anyopaque,
    pointer: ?*c.struct_wl_pointer,
    serial: u32,
    time: u32,
    button: u32,
    state: u32,
) callconv(.c) void {
    _ = pointer;
    _ = time;
    const self: *Input = @ptrCast(@alignCast(data orelse return));
    self.pointer_serial = serial;
    if (serial > self.last_serial) self.last_serial = serial;
    const window_id = self.pointer_window orelse return;
    const mapped = mapButton(button);
    if (state == @as(u32, @intCast(c.WL_POINTER_BUTTON_STATE_PRESSED))) {
        self.sink.push(.{ .mouse_button_down = .{
            .window_id = window_id,
            .button = mapped,
            .mods = self.mods,
            .click_count = 1,
        } });
    } else {
        self.sink.push(.{ .mouse_button_up = .{
            .window_id = window_id,
            .button = mapped,
            .mods = self.mods,
        } });
    }
}

fn onPointerAxis(
    data: ?*anyopaque,
    pointer: ?*c.struct_wl_pointer,
    time: u32,
    axis: u32,
    value: c.wl_fixed_t,
) callconv(.c) void {
    _ = pointer;
    _ = time;
    const self: *Input = @ptrCast(@alignCast(data orelse return));
    const window_id = self.pointer_window orelse return;
    const amount = fixedToFloat(value);
    const dx: f32 = if (axis == 1) amount else 0;
    const dy: f32 = if (axis == 0) amount else 0;
    self.sink.push(.{ .mouse_scrolled = .{
        .window_id = window_id,
        .dx = dx,
        .dy = dy,
        .mods = self.mods,
    } });
}

fn mapButton(button: u32) Event.MouseButton {
    return switch (button) {
        0x110 => .left,
        0x111 => .right,
        0x112 => .middle,
        0x113 => .back,
        0x114 => .forward,
        else => .unknown,
    };
}

const keyboard_listener = c.struct_wl_keyboard_listener{
    .keymap = onKeyboardKeymap,
    .enter = onKeyboardEnter,
    .leave = onKeyboardLeave,
    .key = onKeyboardKey,
    .modifiers = onKeyboardModifiers,
    .repeat_info = onKeyboardRepeatInfo,
};

fn onKeyboardKeymap(
    data: ?*anyopaque,
    keyboard: ?*c.struct_wl_keyboard,
    format: u32,
    fd: c_int,
    size: u32,
) callconv(.c) void {
    _ = keyboard;
    const self: *Input = @ptrCast(@alignCast(data orelse return));
    const x = self.xkb orelse {
        _ = c.close(fd);
        return;
    };
    if (format != @as(u32, @intCast(c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1))) {
        _ = c.close(fd);
        return;
    }

    const total: usize = @intCast(size);
    const mapped = std.posix.mmap(
        null,
        total,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    ) catch |err| {
        self.sink.report(err);
        _ = c.close(fd);
        return;
    };
    defer std.posix.munmap(mapped);
    _ = c.close(fd);

    const keymap = x.keymapNewFromBuffer(
        self.xkb_context,
        @ptrCast(mapped.ptr),
        total,
        xkb_mod.KEYMAP_FORMAT_TEXT_V1,
        xkb_mod.KEYMAP_COMPILE_NO_FLAGS,
    ) orelse {
        self.sink.report(error.WaylandKeymapFailed);
        return;
    };
    const state = x.stateNew(keymap) orelse {
        self.sink.report(error.WaylandKeymapFailed);
        x.keymapUnref(keymap);
        return;
    };

    if (self.xkb_state) |old| x.stateUnref(old);
    if (self.xkb_keymap) |old| x.keymapUnref(old);
    self.xkb_keymap = keymap;
    self.xkb_state = state;

    self.idx_shift = x.keymapModGetIndex(keymap, "Shift");
    self.idx_control = x.keymapModGetIndex(keymap, "Control");
    self.idx_alt = x.keymapModGetIndex(keymap, "Mod1");
    self.idx_super = x.keymapModGetIndex(keymap, "Mod4");
    self.idx_caps = x.keymapModGetIndex(keymap, "Lock");
    self.idx_num = x.keymapModGetIndex(keymap, "Mod2");
}

fn refreshMods(self: *Input) void {
    const x = self.xkb orelse return;
    const state = self.xkb_state orelse return;
    const effective: xkb_mod.StateComponent = xkb_mod.STATE_MODS_EFFECTIVE;
    self.mods = .{
        .shift = x.stateModIndexIsActive(state, self.idx_shift, effective) != 0,
        .control = x.stateModIndexIsActive(state, self.idx_control, effective) != 0,
        .alt = x.stateModIndexIsActive(state, self.idx_alt, effective) != 0,
        .super = x.stateModIndexIsActive(state, self.idx_super, effective) != 0,
        .caps_lock = x.stateModIndexIsActive(state, self.idx_caps, effective) != 0,
        .num_lock = x.stateModIndexIsActive(state, self.idx_num, effective) != 0,
    };
}

fn restoreKeysDown(self: *Input, keys: [*c]c.struct_wl_array) void {
    self.keys_down = .empty;
    if (keys == null) return;
    const array = keys[0];
    if (array.data == null) return;
    const count = array.size / @sizeOf(u32);
    const data: [*]const u32 = @ptrCast(@alignCast(array.data.?));
    for (0..count) |i| {
        const index = @as(u64, data[i]) + 8;
        if (index < @TypeOf(self.keys_down).bit_length) {
            self.keys_down.set(@intCast(index));
        }
    }
}

fn onKeyboardEnter(
    data: ?*anyopaque,
    keyboard: ?*c.struct_wl_keyboard,
    serial: u32,
    surface: ?*c.struct_wl_surface,
    keys: [*c]c.struct_wl_array,
) callconv(.c) void {
    _ = keyboard;
    const self: *Input = @ptrCast(@alignCast(data orelse return));
    restoreKeysDown(self, keys);
    self.last_serial = serial;
    self.keyboard_window = self.sink.windowForSurface(surface);
    self.sink.focus(self.keyboard_window);
    if (self.keyboard_window) |window_id| {
        self.sink.push(.{ .window_focus_gained = .{ .window_id = window_id } });
    }
}

fn onKeyboardLeave(
    data: ?*anyopaque,
    keyboard: ?*c.struct_wl_keyboard,
    serial: u32,
    surface: ?*c.struct_wl_surface,
) callconv(.c) void {
    _ = keyboard;
    _ = serial;
    _ = surface;
    const self: *Input = @ptrCast(@alignCast(data orelse return));
    self.keys_down = .empty;
    if (self.keyboard_window) |window_id| {
        self.sink.push(.{ .window_focus_lost = .{ .window_id = window_id } });
    }
    self.keyboard_window = null;
    self.sink.focus(null);
}

fn onKeyboardKey(
    data: ?*anyopaque,
    keyboard: ?*c.struct_wl_keyboard,
    serial: u32,
    time: u32,
    key: u32,
    state: u32,
) callconv(.c) void {
    _ = keyboard;
    _ = time;
    const self: *Input = @ptrCast(@alignCast(data orelse return));
    self.last_serial = serial;
    const window_id = self.keyboard_window orelse return;

    const x = self.xkb orelse return;
    const xkb_state = self.xkb_state orelse return;
    const keycode: xkb_mod.Keycode = key + 8;
    const key_index: usize = @intCast(keycode);
    const tracked = key_index < @TypeOf(self.keys_down).bit_length;
    const keysym = x.stateKeyGetOneSym(xkb_state, keycode);
    const mapped = xkb_mod.mapKey(keysym);

    if (state == @as(u32, @intCast(c.WL_KEYBOARD_KEY_STATE_RELEASED))) {
        if (tracked) self.keys_down.unset(key_index);
        self.sink.push(.{ .key_up = .{
            .window_id = window_id,
            .key = mapped,
            .mods = self.mods,
        } });
        return;
    }

    const was_down = tracked and self.keys_down.isSet(key_index);
    if (tracked) self.keys_down.set(key_index);

    self.sink.push(.{ .key_down = .{
        .window_id = window_id,
        .key = mapped,
        .mods = self.mods,
        .repeat = state == @as(u32, @intCast(c.WL_KEYBOARD_KEY_STATE_REPEATED)) or was_down,
    } });

    var text_buf: [64]u8 = undefined;
    const n = x.stateKeyGetUtf8(xkb_state, keycode, &text_buf, text_buf.len);
    if (n > 0) {
        const text = text_buf[0..@intCast(n)];
        if (text.len > 0 and text[0] >= 0x20 and text[0] != 0x7f) {
            self.sink.text(window_id, text);
        }
    }
}

fn onKeyboardModifiers(
    data: ?*anyopaque,
    keyboard: ?*c.struct_wl_keyboard,
    serial: u32,
    mods_depressed: u32,
    mods_latched: u32,
    mods_locked: u32,
    group: u32,
) callconv(.c) void {
    _ = keyboard;
    const self: *Input = @ptrCast(@alignCast(data orelse return));
    self.last_serial = serial;
    const x = self.xkb orelse return;
    const state = self.xkb_state orelse return;
    _ = x.stateUpdateMask(state, mods_depressed, mods_latched, mods_locked, 0, 0, group);
    self.refreshMods();
}

fn onKeyboardRepeatInfo(data: ?*anyopaque, keyboard: ?*c.struct_wl_keyboard, rate: i32, delay: i32) callconv(.c) void {
    _ = keyboard;
    const self: *Input = @ptrCast(@alignCast(data orelse return));
    self.repeat_rate = rate;
    self.repeat_delay = delay;
}

fn onPointerFrame(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer) callconv(.c) void {
    _ = data;
    _ = pointer;
}

fn onPointerAxisSource(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, axis_source: u32) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = axis_source;
}

fn onPointerAxisStop(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, time: u32, axis: u32) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = time;
    _ = axis;
}

fn onPointerAxisDiscrete(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, axis: u32, discrete: i32) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = axis;
    _ = discrete;
}

fn onPointerAxisValue120(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, axis: u32, value120: i32) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = axis;
    _ = value120;
}

fn onPointerAxisRelativeDirection(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, axis: u32, direction: u32) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = axis;
    _ = direction;
}

fn onPointerWarp(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, surface_x: c.wl_fixed_t, surface_y: c.wl_fixed_t) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = surface_x;
    _ = surface_y;
}
const touch_listener = c.struct_wl_touch_listener{
    .down = onTouchDown,
    .up = onTouchUp,
    .motion = onTouchMotion,
    .frame = onTouchFrame,
    .cancel = onTouchCancel,
    .shape = onTouchShape,
    .orientation = onTouchOrientation,
};

fn onTouchDown(
    data: ?*anyopaque,
    touch: ?*c.struct_wl_touch,
    serial: u32,
    time: u32,
    surface: ?*c.struct_wl_surface,
    id: i32,
    x: c.wl_fixed_t,
    y: c.wl_fixed_t,
) callconv(.c) void {
    _ = touch;
    _ = time;
    const self: *Input = @ptrCast(@alignCast(data orelse return));
    if (serial > self.last_serial) self.last_serial = serial;
    if (self.touch_active_id != null) return;

    self.touch_active_id = id;
    self.touch_window = self.sink.windowForSurface(surface);
    self.touch_x = fixedToFloat(x);
    self.touch_y = fixedToFloat(y);

    if (self.touch_window) |window_id| {
        self.sink.push(.{ .mouse_entered = .{ .window_id = window_id } });
        self.sink.push(.{ .mouse_moved = .{
            .window_id = window_id,
            .x = self.touch_x,
            .y = self.touch_y,
            .mods = .{},
        } });
        self.sink.push(.{ .mouse_button_down = .{
            .window_id = window_id,
            .button = .left,
            .mods = .{},
            .click_count = 1,
        } });
    }
}

fn onTouchUp(
    data: ?*anyopaque,
    touch: ?*c.struct_wl_touch,
    serial: u32,
    time: u32,
    id: i32,
) callconv(.c) void {
    _ = touch;
    _ = time;
    const self: *Input = @ptrCast(@alignCast(data orelse return));
    if (serial > self.last_serial) self.last_serial = serial;
    if (self.touch_active_id != id) return;
    self.finishTouch();
}

fn onTouchMotion(
    data: ?*anyopaque,
    touch: ?*c.struct_wl_touch,
    time: u32,
    id: i32,
    x: c.wl_fixed_t,
    y: c.wl_fixed_t,
) callconv(.c) void {
    _ = touch;
    _ = time;
    const self: *Input = @ptrCast(@alignCast(data orelse return));
    if (self.touch_active_id != id) return;
    self.touch_x = fixedToFloat(x);
    self.touch_y = fixedToFloat(y);
    if (self.touch_window) |window_id| {
        self.sink.push(.{ .mouse_moved = .{
            .window_id = window_id,
            .x = self.touch_x,
            .y = self.touch_y,
            .mods = .{},
        } });
    }
}

fn onTouchCancel(data: ?*anyopaque, touch: ?*c.struct_wl_touch) callconv(.c) void {
    _ = touch;
    const self: *Input = @ptrCast(@alignCast(data orelse return));
    self.finishTouch();
}

fn onTouchFrame(data: ?*anyopaque, touch: ?*c.struct_wl_touch) callconv(.c) void {
    _ = data;
    _ = touch;
}

fn onTouchShape(data: ?*anyopaque, touch: ?*c.struct_wl_touch, id: i32, major: c.wl_fixed_t, minor: c.wl_fixed_t) callconv(.c) void {
    _ = data;
    _ = touch;
    _ = id;
    _ = major;
    _ = minor;
}

fn onTouchOrientation(data: ?*anyopaque, touch: ?*c.struct_wl_touch, id: i32, orientation: c.wl_fixed_t) callconv(.c) void {
    _ = data;
    _ = touch;
    _ = id;
    _ = orientation;
}

/// `release` is a request since wl_pointer/wl_keyboard/wl_touch version 3;
/// older compositors only support the client-side `destroy`.
fn releasePointer(pointer: *c.struct_wl_pointer) void {
    if (c.wl_pointer_get_version(pointer) >= 3) {
        c.wl_pointer_release(pointer);
    } else {
        c.wl_pointer_destroy(pointer);
    }
}

fn releaseKeyboard(keyboard: *c.struct_wl_keyboard) void {
    if (c.wl_keyboard_get_version(keyboard) >= 3) {
        c.wl_keyboard_release(keyboard);
    } else {
        c.wl_keyboard_destroy(keyboard);
    }
}

fn releaseTouch(touch: *c.struct_wl_touch) void {
    if (c.wl_touch_get_version(touch) >= 3) {
        c.wl_touch_release(touch);
    } else {
        c.wl_touch_destroy(touch);
    }
}
