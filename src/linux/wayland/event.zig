//! Internal event queue shared by the Wayland modules.
//!
//! `push` deliberately does not copy borrowed payloads. Text produced by
//! xkb/IME is copied by the backend before it enters the queue (see
//! `Backend.pushText`), so the queue itself stays allocation-free per event.

const std = @import("std");
const Event = @import("../../Event.zig");
const c = @import("protocols.zig").c;

pub const Queue = struct {
    alloc: std.mem.Allocator,
    items: std.ArrayList(Event.Core) = .empty,

    pub fn init(alloc: std.mem.Allocator) Queue {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Queue) void {
        self.items.deinit(self.alloc);
    }

    pub fn push(self: *Queue, ev: Event.Core) bool {
        self.items.append(self.alloc, ev) catch return false;
        return true;
    }

    pub fn pop(self: *Queue) ?Event.Core {
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }
};

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
};
