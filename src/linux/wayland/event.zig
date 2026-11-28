//! Internal event queue shared by the Wayland modules.
//!
//! `push` deliberately does not copy borrowed payloads. Text produced by
//! xkb/IME is copied by the backend before it enters the queue (see
//! `Backend.textThunk`), so the queue itself stays allocation-free per event.

const Event = @import("../../Event.zig");
const c = @import("protocols.zig").c;

pub const Queue = @import("../../EventQueue.zig").Queue;

/// Callback interface implemented by `Backend` and handed to `input.zig` /
/// `ime.zig`. Keeping it as function pointers avoids a circular type
/// dependency between those modules and `backend.zig`.
pub const Sink = struct {
    ctx: *anyopaque,
    push_fn: *const fn (ctx: *anyopaque, ev: Event.Core) void,
    text_fn: *const fn (ctx: *anyopaque, window_id: u32, text: []const u8) void,
    surface_window_fn: *const fn (ctx: *anyopaque, surface: ?*c.struct_wl_surface) ?u32,
    apply_cursor_fn: *const fn (ctx: *anyopaque, window_id: u32, serial: u32) void,
    focus_fn: *const fn (ctx: *anyopaque, window_id: ?u32) void,
    ime_allowed_fn: *const fn (ctx: *anyopaque, window_id: u32) bool,
    report_fn: *const fn (ctx: *anyopaque, err: anyerror) void,
    pointer_changed_fn: *const fn (ctx: *anyopaque, pointer: ?*c.struct_wl_pointer) void,

    pub fn push(self: Sink, ev: Event.Core) void {
        self.push_fn(self.ctx, ev);
    }

    pub fn text(self: Sink, window_id: u32, value: []const u8) void {
        self.text_fn(self.ctx, window_id, value);
    }

    pub fn windowForSurface(self: Sink, surface: ?*c.struct_wl_surface) ?u32 {
        return self.surface_window_fn(self.ctx, surface);
    }

    pub fn applyCursor(self: Sink, window_id: u32, serial: u32) void {
        self.apply_cursor_fn(self.ctx, window_id, serial);
    }

    pub fn focus(self: Sink, window_id: ?u32) void {
        self.focus_fn(self.ctx, window_id);
    }

    /// Per-window IME switch. Missing/destroyed windows are disabled.
    pub fn imeAllowed(self: Sink, window_id: u32) bool {
        return self.ime_allowed_fn(self.ctx, window_id);
    }

    /// Route a diagnostic to the App-owned reporter.
    pub fn report(self: Sink, err: anyerror) void {
        self.report_fn(self.ctx, err);
    }

    /// Notify the backend that the seat's pointer proxy changed.
    pub fn pointerChanged(self: Sink, pointer: ?*c.struct_wl_pointer) void {
        self.pointer_changed_fn(self.ctx, pointer);
    }
};
