//! Optional `zwp_text_input_v3` integration.
//!
//! The protocol object is per seat, not per window, so the backend owns one
//! `Ime` instance and tracks the window that currently has keyboard focus.

const std = @import("std");
const General = @import("../../General.zig");
const c = @import("protocols.zig").c;
const Sink = @import("event.zig").Sink;

pub const Ime = struct {
    object: *c.struct_zwp_text_input_v3,
    sink: Sink,
    focused_window: ?u32 = null,
    enabled: bool = false,
    cursor_pos: General.Position = .{ .x = 0, .y = 0 },
    cursor_size: General.Size = .{ .w = 0, .h = 0 },

    pub fn init(
        manager: *c.struct_zwp_text_input_manager_v3,
        seat: ?*c.struct_wl_seat,
        sink: Sink,
    ) ?Ime {
        const object = c.zwp_text_input_manager_v3_get_text_input(manager, seat) orelse return null;
        return Ime{ .object = object, .sink = sink };
    }

    /// The listener stores `&self`, so the Ime must live in stable memory.
    /// `Backend` calls this again after moving the value into its field.
    pub fn rebind(self: *Ime) void {
        _ = c.zwp_text_input_v3_add_listener(self.object, &listener, self);
    }

    pub fn deinit(self: *Ime) void {
        c.zwp_text_input_v3_destroy(self.object);
    }

    pub fn setAllowed(self: *Ime, allowed: bool) void {
        self.enabled = allowed;
        if (allowed) {
            c.zwp_text_input_v3_enable(self.object);
        } else {
            c.zwp_text_input_v3_disable(self.object);
        }
        c.zwp_text_input_v3_commit(self.object);
    }

    pub fn setCursorArea(self: *Ime, window_id: u32, pos: General.Position, size: General.Size) void {
        if (self.focused_window != window_id or !self.enabled) return;
        self.cursor_pos = pos;
        self.cursor_size = size;
        c.zwp_text_input_v3_set_cursor_rectangle(self.object, pos.x, pos.y, @intCast(size.w), @intCast(size.h));
        c.zwp_text_input_v3_commit(self.object);
    }

    pub fn focus(self: *Ime, window_id: ?u32) void {
        self.focused_window = window_id;
        if (self.enabled) {
            if (window_id != null) {
                c.zwp_text_input_v3_enable(self.object);
                c.zwp_text_input_v3_set_cursor_rectangle(self.object, self.cursor_pos.x, self.cursor_pos.y, @intCast(self.cursor_size.w), @intCast(self.cursor_size.h));
            } else {
                c.zwp_text_input_v3_disable(self.object);
            }
            c.zwp_text_input_v3_commit(self.object);
        }
    }

    const listener = c.struct_zwp_text_input_v3_listener{
        .enter = onEnter,
        .leave = onLeave,
        .preedit_string = onPreedit,
        .commit_string = onCommit,
        .delete_surrounding_text = onDelete,
        .done = onDone,
        .action = onAction,
        .language = onLanguage,
        .preedit_hint = onPreeditHint,
    };

    fn onEnter(data: ?*anyopaque, text_input: ?*c.struct_zwp_text_input_v3, surface: ?*c.struct_wl_surface) callconv(.c) void {
        _ = text_input;
        const self: *Ime = @ptrCast(@alignCast(data orelse return));
        self.focused_window = self.sink.windowForSurface(surface);
    }

    fn onLeave(data: ?*anyopaque, text_input: ?*c.struct_zwp_text_input_v3, surface: ?*c.struct_wl_surface) callconv(.c) void {
        _ = text_input;
        _ = surface;
        const self: *Ime = @ptrCast(@alignCast(data orelse return));
        self.focused_window = null;
    }

    fn onPreedit(data: ?*anyopaque, text_input: ?*c.struct_zwp_text_input_v3, text: [*c]const u8, cursor_begin: i32, cursor_end: i32) callconv(.c) void {
        _ = data;
        _ = text_input;
        _ = text;
        _ = cursor_begin;
        _ = cursor_end;
    }

    fn onCommit(data: ?*anyopaque, text_input: ?*c.struct_zwp_text_input_v3, text: [*c]const u8) callconv(.c) void {
        _ = text_input;
        const self: *Ime = @ptrCast(@alignCast(data orelse return));
        if (text == null) return;
        const window_id = self.focused_window orelse return;
        self.sink.text(window_id, std.mem.span(@as([*:0]const u8, @ptrCast(text))));
    }

    fn onDelete(data: ?*anyopaque, text_input: ?*c.struct_zwp_text_input_v3, before_length: u32, after_length: u32) callconv(.c) void {
        _ = data;
        _ = text_input;
        _ = before_length;
        _ = after_length;
    }

    fn onDone(data: ?*anyopaque, text_input: ?*c.struct_zwp_text_input_v3, serial: u32) callconv(.c) void {
        _ = data;
        _ = text_input;
        _ = serial;
    }

    fn onAction(data: ?*anyopaque, text_input: ?*c.struct_zwp_text_input_v3, action: u32, serial: u32) callconv(.c) void {
        _ = data;
        _ = text_input;
        _ = action;
        _ = serial;
    }

    fn onLanguage(data: ?*anyopaque, text_input: ?*c.struct_zwp_text_input_v3, language: [*c]const u8) callconv(.c) void {
        _ = data;
        _ = text_input;
        _ = language;
    }

    fn onPreeditHint(data: ?*anyopaque, text_input: ?*c.struct_zwp_text_input_v3, start: u32, end: u32, hint: u32) callconv(.c) void {
        _ = data;
        _ = text_input;
        _ = start;
        _ = end;
        _ = hint;
    }
};
