//! Event payloads. Slices (notably `TextInput.text`) are borrowed and remain
//! valid only until the event has been consumed.
const std = @import("std");

pub const Mods = packed struct(u8) {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _pad: u2 = 0,

    pub const none: Mods = .{};
};

pub const MouseButton = enum(u8) {
    left,
    right,
    middle,
    back,
    forward,
    unknown,
};

pub const KeyCode = enum(u16) { a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z, digit0, digit1, digit2, digit3, digit4, digit5, digit6, digit7, digit8, digit9, backquote, minus, equal, bracket_left, bracket_right, backslash, semicolon, quote, comma, period, slash, escape, tab, caps_lock, space, enter, backspace, delete, insert, home, end, page_up, page_down, arrow_left, arrow_right, arrow_up, arrow_down, print_screen, scroll_lock, pause, context_menu, non_us_backslash, shift_left, control_left, alt_left, super_left, shift_right, control_right, alt_right, super_right, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24, keypad_0, keypad_1, keypad_2, keypad_3, keypad_4, keypad_5, keypad_6, keypad_7, keypad_8, keypad_9, keypad_decimal, keypad_divide, keypad_multiply, keypad_subtract, keypad_add, keypad_enter, keypad_equal, intl_backslash, intl_ro, intl_yen, unknown };

pub const WindowRef = struct { window_id: u32 };
pub const WindowResized = struct { window_id: u32, width: u32, height: u32 };
pub const WindowMoved = struct { window_id: u32, x: i32, y: i32 };
/// Logical-to-physical scale changed; recreate drawable/viewport.
pub const WindowScaleChanged = struct { window_id: u32, scale: f32 };
pub const KeyDown = struct { window_id: u32, key: KeyCode, mods: Mods, repeat: bool };
pub const KeyUp = struct { window_id: u32, key: KeyCode, mods: Mods };

/// UTF-8 committed text (IME/keyboard). Borrowed and not copied; copy it if
/// it must outlive the event.
pub const TextInput = struct { window_id: u32, text: []const u8 };

pub const MouseMoved = struct { window_id: u32, x: f32, y: f32, mods: Mods };
pub const MouseButtonDown = struct { window_id: u32, button: MouseButton, mods: Mods, click_count: u8 };
pub const MouseButtonUp = struct { window_id: u32, button: MouseButton, mods: Mods };
pub const MouseScrolled = struct { window_id: u32, dx: f32, dy: f32, mods: Mods };

pub const PenState = struct {
    window_id: u32,
    pen_id: u32,
    x: f64,
    y: f64,
    pressure: f64,
    tilt_x: f64,
    tilt_y: f64,
    rotation: f64,
    eraser: bool,
};

pub const PenLeft = struct { window_id: u32, pen_id: u32 };

pub const PenButton = struct {
    window_id: u32,
    pen_id: u32,
    button: u8,
    x: f64,
    y: f64,
    pressure: f64,
    tilt_x: f64,
    tilt_y: f64,
    rotation: f64,
    eraser: bool,
};

pub const CustomType = struct {
    window_id: u32,
    ev_type: u32,
    act: union {
        act_u: u32,
        act_i: i32,
        act_f: f64,
        act_b: bool,
    },
    act_2: union {
        act_u: u32,
        act_i: i32,
        act_f: f64,
        act_b: bool,
    },
};

const CoreEvent = union(enum) {
    none,

    /// Close request only; the application decides when to destroy the window.
    window_should_close: WindowRef,
    window_resized: WindowResized,
    window_moved: WindowMoved,
    window_scale_changed: WindowScaleChanged,
    window_focus_gained: WindowRef,
    window_focus_lost: WindowRef,
    window_minimized: WindowRef,
    window_maximized: WindowRef,
    window_restored: WindowRef,

    key_down: KeyDown,
    key_up: KeyUp,
    text_input: TextInput,

    mouse_entered: WindowRef,
    mouse_left: WindowRef,
    mouse_moved: MouseMoved,
    mouse_button_down: MouseButtonDown,
    mouse_button_up: MouseButtonUp,
    mouse_scrolled: MouseScrolled,

    pen_entered: PenState,
    pen_left: PenLeft,
    pen_down: PenState,
    pen_up: PenState,
    pen_moved: PenState,
    pen_button_down: PenButton,
    pen_button_up: PenButton,

    custom: CustomType,
    unknown,
};

pub const Core = CoreEvent;
