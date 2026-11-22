//! Linux-generic xkbcommon loader and key-code mapping.
//!
//! Shared by the Wayland backend and a future X11 backend. It has no Wayland
//! dependency; all layout data comes from the compositor/server keymap.

const std = @import("std");
const Event = @import("../Event.zig");

pub const Context = opaque {};
pub const Keymap = opaque {};
pub const State = opaque {};

pub const Keysym = u32;
pub const Keycode = u32;
pub const ModIndex = u32;
pub const ModMask = u32;
pub const LayoutIndex = u32;
pub const StateComponent = u32;

pub const CONTEXT_NO_FLAGS: u32 = 0;
pub const KEYMAP_FORMAT_TEXT_V1: u32 = 1;
pub const KEYMAP_COMPILE_NO_FLAGS: u32 = 0;
pub const STATE_MODS_EFFECTIVE: StateComponent = 8;

const names = [_][]const u8{ "libxkbcommon.so.0", "libxkbcommon.so" };

const ContextNew = *const fn (flags: u32) callconv(.c) ?*Context;
const ContextUnref = *const fn (context: ?*Context) callconv(.c) void;
const KeymapNewFromString = *const fn (context: ?*Context, string: [*c]const u8, format: u32, flags: u32) callconv(.c) ?*Keymap;
const KeymapNewFromBuffer = *const fn (context: ?*Context, buffer: [*c]const u8, length: usize, format: u32, flags: u32) callconv(.c) ?*Keymap;
const KeymapUnref = *const fn (keymap: ?*Keymap) callconv(.c) void;
const KeymapModGetIndex = *const fn (keymap: ?*Keymap, name: [*c]const u8) callconv(.c) ModIndex;
const KeymapKeyRepeats = *const fn (keymap: ?*Keymap, key: Keycode) callconv(.c) c_int;
const StateNew = *const fn (keymap: ?*Keymap) callconv(.c) ?*State;
const StateUnref = *const fn (state: ?*State) callconv(.c) void;
const StateUpdateMask = *const fn (state: ?*State, depressed_mods: ModMask, latched_mods: ModMask, locked_mods: ModMask, depressed_layout: LayoutIndex, latched_layout: LayoutIndex, locked_layout: LayoutIndex) callconv(.c) StateComponent;
const StateKeyGetOneSym = *const fn (state: ?*State, key: Keycode) callconv(.c) Keysym;
const StateKeyGetUtf8 = *const fn (state: ?*State, key: Keycode, buffer: [*c]u8, size: usize) callconv(.c) c_int;
const StateModIndexIsActive = *const fn (state: ?*State, idx: ModIndex, component: StateComponent) callconv(.c) c_int;
const KeysymToUtf32 = *const fn (keysym: Keysym) callconv(.c) u32;

pub const Error = error{
    XkbUnavailable,
    MissingXkbSymbol,
};
pub const Xkb = struct {
    lib: std.DynLib,
    contextNew: ContextNew,
    contextUnref: ContextUnref,
    keymapNewFromString: KeymapNewFromString,
    keymapNewFromBuffer: KeymapNewFromBuffer,
    keymapUnref: KeymapUnref,
    keymapModGetIndex: KeymapModGetIndex,
    keymapKeyRepeats: KeymapKeyRepeats,
    stateNew: StateNew,
    stateUnref: StateUnref,
    stateUpdateMask: StateUpdateMask,
    stateKeyGetOneSym: StateKeyGetOneSym,
    stateKeyGetUtf8: StateKeyGetUtf8,
    stateModIndexIsActive: StateModIndexIsActive,
    keysymToUtf32: KeysymToUtf32,

    pub fn open() !Xkb {
        var lib = openFirst("ZCWL_XKBCOMMON_LIB", &names) orelse return error.XkbUnavailable;
        errdefer lib.close();

        var x: Xkb = undefined;
        x.lib = lib;
        x.contextNew = x.lib.lookup(@TypeOf(x.contextNew), "xkb_context_new") orelse return error.MissingXkbSymbol;
        x.contextUnref = x.lib.lookup(@TypeOf(x.contextUnref), "xkb_context_unref") orelse return error.MissingXkbSymbol;
        x.keymapNewFromString = x.lib.lookup(@TypeOf(x.keymapNewFromString), "xkb_keymap_new_from_string") orelse return error.MissingXkbSymbol;
        x.keymapNewFromBuffer = x.lib.lookup(@TypeOf(x.keymapNewFromBuffer), "xkb_keymap_new_from_buffer") orelse return error.MissingXkbSymbol;
        x.keymapUnref = x.lib.lookup(@TypeOf(x.keymapUnref), "xkb_keymap_unref") orelse return error.MissingXkbSymbol;
        x.keymapModGetIndex = x.lib.lookup(@TypeOf(x.keymapModGetIndex), "xkb_keymap_mod_get_index") orelse return error.MissingXkbSymbol;
        x.keymapKeyRepeats = x.lib.lookup(@TypeOf(x.keymapKeyRepeats), "xkb_keymap_key_repeats") orelse return error.MissingXkbSymbol;
        x.stateNew = x.lib.lookup(@TypeOf(x.stateNew), "xkb_state_new") orelse return error.MissingXkbSymbol;
        x.stateUnref = x.lib.lookup(@TypeOf(x.stateUnref), "xkb_state_unref") orelse return error.MissingXkbSymbol;
        x.stateUpdateMask = x.lib.lookup(@TypeOf(x.stateUpdateMask), "xkb_state_update_mask") orelse return error.MissingXkbSymbol;
        x.stateKeyGetOneSym = x.lib.lookup(@TypeOf(x.stateKeyGetOneSym), "xkb_state_key_get_one_sym") orelse return error.MissingXkbSymbol;
        x.stateKeyGetUtf8 = x.lib.lookup(@TypeOf(x.stateKeyGetUtf8), "xkb_state_key_get_utf8") orelse return error.MissingXkbSymbol;
        x.stateModIndexIsActive = x.lib.lookup(@TypeOf(x.stateModIndexIsActive), "xkb_state_mod_index_is_active") orelse return error.MissingXkbSymbol;
        x.keysymToUtf32 = x.lib.lookup(@TypeOf(x.keysymToUtf32), "xkb_keysym_to_utf32") orelse return error.MissingXkbSymbol;
        return x;
    }

    pub fn close(self: *Xkb) void {
        self.lib.close();
    }

    pub fn isModActive(self: *Xkb, state: ?*State, idx: ModIndex) bool {
        return self.stateModIndexIsActive(state, idx, STATE_MODS_EFFECTIVE) != 0;
    }
};

fn openFirst(env_name: [:0]const u8, candidates: []const []const u8) ?std.DynLib {
    if (std.c.getenv(env_name)) |path| {
        if (std.DynLib.open(std.mem.span(path))) |lib| return lib else |_| {}
    }
    for (candidates) |name| {
        if (std.DynLib.open(name)) |lib| return lib else |_| {}
    }
    return null;
}

pub fn mapKey(sym: Keysym) Event.KeyCode {
    const k: u32 = @intCast(sym);

    if (k >= 0x61 and k <= 0x7a) return @fromBackingInt(@intCast(@backingInt(Event.KeyCode.a) + (k - 0x61)));
    if (k >= 0x41 and k <= 0x5a) return @fromBackingInt(@intCast(@backingInt(Event.KeyCode.a) + (k - 0x41)));
    if (k >= 0x30 and k <= 0x39) return @fromBackingInt(@intCast(@backingInt(Event.KeyCode.digit0) + (k - 0x30)));

    switch (k) {
        0x0060 => return .backquote,
        0x002d => return .minus,
        0x003d => return .equal,
        0x005b => return .bracket_left,
        0x005d => return .bracket_right,
        0x005c => return .backslash,
        0x003b => return .semicolon,
        0x0027 => return .quote,
        0x002c => return .comma,
        0x002e => return .period,
        0x002f => return .slash,

        0xff08 => return .backspace,
        0xff09, 0xfe20 => return .tab,
        0xff0d => return .enter,
        0xff1b => return .escape,
        0xffe5 => return .caps_lock,
        0x0020 => return .space,
        0xffff => return .delete,
        0xff63 => return .insert,
        0xff50 => return .home,
        0xff57 => return .end,
        0xff55 => return .page_up,
        0xff56 => return .page_down,
        0xff51 => return .arrow_left,
        0xff52 => return .arrow_up,
        0xff53 => return .arrow_right,
        0xff54 => return .arrow_down,

        0xff61 => return .print_screen,
        0xff14 => return .scroll_lock,
        0xff13 => return .pause,
        0xff67 => return .context_menu,
        0x003c => return .non_us_backslash,

        0xffe1 => return .shift_left,
        0xffe2 => return .shift_right,
        0xffe3 => return .control_left,
        0xffe4 => return .control_right,
        0xffe9 => return .alt_left,
        0xffea => return .alt_right,
        0xffeb => return .super_left,
        0xffec => return .super_right,

        0xffb0 => return .keypad_0,
        0xffb1 => return .keypad_1,
        0xffb2 => return .keypad_2,
        0xffb3 => return .keypad_3,
        0xffb4 => return .keypad_4,
        0xffb5 => return .keypad_5,
        0xffb6 => return .keypad_6,
        0xffb7 => return .keypad_7,
        0xffb8 => return .keypad_8,
        0xffb9 => return .keypad_9,
        0xffae => return .keypad_decimal,
        0xffaf => return .keypad_divide,
        0xffaa => return .keypad_multiply,
        0xffad => return .keypad_subtract,
        0xffab => return .keypad_add,
        0xff8d => return .keypad_enter,
        0xffbd => return .keypad_equal,

        else => {},
    }

    if (k >= 0xffbe and k <= 0xffd5) {
        return @fromBackingInt(@intCast(@backingInt(Event.KeyCode.f1) + (k - 0xffbe)));
    }

    return .unknown;
}
