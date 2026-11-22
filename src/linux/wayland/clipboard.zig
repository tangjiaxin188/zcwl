//! Clipboard through the core `wl_data_device_manager` protocol.
//!
//! Setting the selection is synchronous once a keyboard-focus serial is
//! available. Reading is asynchronous: the offer is accepted in the
//! `selection` event and the pipe is drained from `poll()`. Until the first
//! complete text arrives `getText` returns `error.Unsupported`.

const std = @import("std");
const General = @import("../../General.zig");
const c = @import("protocols.zig").c;

const text_mime = "text/plain;charset=utf-8";

pub const Clipboard = struct {
    alloc: std.mem.Allocator,
    manager: ?*c.struct_wl_data_device_manager,
    device: ?*c.struct_wl_data_device = null,
    source: ?*c.struct_wl_data_source = null,
    source_text: []u8 = &.{},

    offer: ?*c.struct_wl_data_offer = null,
    mime: [128]u8 = std.mem.zeroes([128]u8),
    mime_len: usize = 0,
    read_fd: ?c_int = null,
    read_buf: std.ArrayList(u8) = .empty,
    text: std.ArrayList(u8) = .empty,
    text_ready: bool = false,
    last_serial: u32 = 0,
    pending_receive: bool = false,

    pub fn init(
        alloc: std.mem.Allocator,
        manager: ?*c.struct_wl_data_device_manager,
        seat: ?*c.struct_wl_seat,
    ) Clipboard {
        var self = Clipboard{ .alloc = alloc, .manager = manager };
        if (manager) |m| {
            if (seat) |s| {
                self.device = c.wl_data_device_manager_get_data_device(m, s);
            }
        }
        return self;
    }

    /// Called by `Backend` after the value has been placed in stable memory.
    pub fn rebind(self: *Clipboard) void {
        if (self.device) |device| {
            _ = c.wl_data_device_add_listener(device, &device_listener, self);
        }
    }

    pub fn deinit(self: *Clipboard) void {
        if (self.read_fd) |fd| _ = c.close(fd);
        self.read_fd = null;
        if (self.offer) |offer| c.wl_data_offer_destroy(offer);
        if (self.source) |source| c.wl_data_source_destroy(source);
        if (self.device) |device| c.wl_data_device_release(device);
        self.read_buf.deinit(self.alloc);
        self.text.deinit(self.alloc);
        if (self.source_text.len > 0) self.alloc.free(self.source_text);
    }

    pub fn setText(self: *Clipboard, text: []const u8, serial: u32) !void {
        if (self.manager == null or self.device == null) return error.Unsupported;
        if (serial == 0) return error.WouldBlock;

        const copy = try self.alloc.dupe(u8, text);
        if (self.source_text.len > 0) self.alloc.free(self.source_text);
        self.source_text = copy;

        if (self.source == null) {
            self.source = c.wl_data_device_manager_create_data_source(self.manager);
            const source = self.source orelse return error.Unsupported;
            _ = c.wl_data_source_add_listener(source, &source_listener, self);
            c.wl_data_source_offer(source, text_mime);
            c.wl_data_source_offer(source, "text/plain");
        }
        const source = self.source orelse return error.Unsupported;
        c.wl_data_device_set_selection(self.device, source, serial);
    }

    pub fn getText(self: *Clipboard, allocator: std.mem.Allocator) ![]u8 {
        if (!self.text_ready) return error.Unsupported;
        return allocator.dupe(u8, self.text.items);
    }

    /// Drain a pending clipboard pipe. Safe to call from the event pump.
    pub fn poll(self: *Clipboard) void {
        if (self.pending_receive and self.last_serial != 0) {
            self.pending_receive = false;
            self.receive();
        }
        const fd = self.read_fd orelse return;
        var fds = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&fds, 0) catch 0;
        if (ready <= 0) return;

        var buf: [4096]u8 = undefined;
        const n = c.read(fd, &buf, buf.len);
        if (n > 0) {
            self.read_buf.appendSlice(self.alloc, buf[0..@intCast(n)]) catch |err| General.reportError(err);
            return;
        }
        if (n == 0) {
            _ = c.close(fd);
            self.read_fd = null;
            self.text.clearRetainingCapacity();
            self.text.appendSlice(self.alloc, self.read_buf.items) catch |err| General.reportError(err);
            self.text_ready = true;
            self.read_buf.clearRetainingCapacity();
            if (self.offer) |offer| c.wl_data_offer_finish(offer);
        } else {
            General.reportError(error.ClipboardReadFailed);
            _ = c.close(fd);
            self.read_fd = null;
            self.resetOffer();
        }
    }

    fn resetOffer(self: *Clipboard) void {
        if (self.read_fd) |fd| _ = c.close(fd);
        self.read_fd = null;
        self.read_buf.clearRetainingCapacity();
        self.mime_len = 0;
        self.text_ready = false;
    }

    fn beginOffer(self: *Clipboard, offer: *c.struct_wl_data_offer) void {
        if (self.offer) |old| c.wl_data_offer_destroy(old);
        self.offer = offer;
        self.resetOffer();
        _ = c.wl_data_offer_add_listener(offer, &offer_listener, self);
    }

    fn chooseMime(self: *Clipboard, mime: []const u8) bool {
        if (!(std.mem.eql(u8, mime, text_mime) or
            std.mem.eql(u8, mime, "text/plain") or
            std.mem.eql(u8, mime, "UTF8_STRING"))) return false;
        if (self.mime_len != 0 and !std.mem.eql(u8, mime, text_mime)) return false;
        self.mime_len = @min(mime.len, self.mime.len - 1);
        @memcpy(self.mime[0..self.mime_len], mime[0..self.mime_len]);
        self.mime[self.mime_len] = 0;
        return true;
    }

    fn receive(self: *Clipboard) void {
        const offer = self.offer orelse return;
        if (self.mime_len == 0 or self.read_fd != null) return;
        if (self.last_serial == 0) {
            self.pending_receive = true;
            return;
        }
        self.pending_receive = false;
        c.wl_data_offer_accept(offer, self.last_serial, &self.mime);
        var fds: [2]c_int = undefined;
        if (c.pipe(&fds) != 0) return;
        self.read_fd = fds[0];
        c.wl_data_offer_receive(offer, &self.mime, fds[1]);
        _ = c.close(fds[1]);
    }

    const device_listener = c.struct_wl_data_device_listener{
        .data_offer = onDataOffer,
        .enter = onDataEnter,
        .leave = onDataLeave,
        .motion = onDataMotion,
        .drop = onDataDrop,
        .selection = onSelection,
    };

    fn onDataOffer(data: ?*anyopaque, device: ?*c.struct_wl_data_device, id: ?*c.struct_wl_data_offer) callconv(.c) void {
        _ = device;
        const self: *Clipboard = @ptrCast(@alignCast(data orelse return));
        if (id) |offer| self.beginOffer(offer);
    }

    fn onSelection(data: ?*anyopaque, device: ?*c.struct_wl_data_device, id: ?*c.struct_wl_data_offer) callconv(.c) void {
        _ = device;
        const self: *Clipboard = @ptrCast(@alignCast(data orelse return));
        if (id == null) {
            if (self.offer) |old| c.wl_data_offer_destroy(old);
            self.offer = null;
            self.pending_receive = false;
            self.resetOffer();
            self.text_ready = false;
            return;
        }
        if (self.offer == null or self.offer != id) {
            self.beginOffer(id.?);
        }
        self.receive();
    }

    const offer_listener = c.struct_wl_data_offer_listener{
        .offer = onOffer,
        .source_actions = onOfferSourceActions,
        .action = onOfferAction,
    };

    fn onOffer(data: ?*anyopaque, offer: ?*c.struct_wl_data_offer, mime_type: [*c]const u8) callconv(.c) void {
        _ = offer;
        const self: *Clipboard = @ptrCast(@alignCast(data orelse return));
        if (mime_type == null) return;
        const mime = std.mem.span(@as([*:0]const u8, @ptrCast(mime_type)));
        if (self.chooseMime(mime)) self.receive();
    }

    const source_listener = c.struct_wl_data_source_listener{
        .target = onSourceTarget,
        .send = onSend,
        .cancelled = onCancelled,
        .dnd_drop_performed = onSourceDndDropPerformed,
        .dnd_finished = onSourceDndFinished,
        .action = onSourceAction,
    };

    fn onSend(data: ?*anyopaque, source: ?*c.struct_wl_data_source, mime_type: [*c]const u8, fd: c_int) callconv(.c) void {
        _ = source;
        _ = mime_type;
        const self: *Clipboard = @ptrCast(@alignCast(data orelse return));
        var written: usize = 0;
        while (written < self.source_text.len) {
            const n = c.write(fd, self.source_text[written..].ptr, self.source_text.len - written);
            if (n < 0) {
                General.reportError(error.ClipboardWriteFailed);
                break;
            }
            if (n == 0) break;
            written += @intCast(n);
        }
        _ = c.close(fd);
    }

    fn onCancelled(data: ?*anyopaque, source: ?*c.struct_wl_data_source) callconv(.c) void {
        _ = source;
        const self: *Clipboard = @ptrCast(@alignCast(data orelse return));
        if (self.source) |s| c.wl_data_source_destroy(s);
        self.source = null;
    }
};
fn onDataEnter(data: ?*anyopaque, device: ?*c.struct_wl_data_device, serial: u32, surface: ?*c.struct_wl_surface, x: c.wl_fixed_t, y: c.wl_fixed_t, id: ?*c.struct_wl_data_offer) callconv(.c) void {
    _ = data;
    _ = device;
    _ = serial;
    _ = surface;
    _ = x;
    _ = y;
    _ = id;
}

fn onDataLeave(data: ?*anyopaque, device: ?*c.struct_wl_data_device) callconv(.c) void {
    _ = data;
    _ = device;
}

fn onDataMotion(data: ?*anyopaque, device: ?*c.struct_wl_data_device, time: u32, x: c.wl_fixed_t, y: c.wl_fixed_t) callconv(.c) void {
    _ = data;
    _ = device;
    _ = time;
    _ = x;
    _ = y;
}

fn onDataDrop(data: ?*anyopaque, device: ?*c.struct_wl_data_device) callconv(.c) void {
    _ = data;
    _ = device;
}

fn onOfferSourceActions(data: ?*anyopaque, offer: ?*c.struct_wl_data_offer, source_actions: u32) callconv(.c) void {
    _ = data;
    _ = offer;
    _ = source_actions;
}

fn onOfferAction(data: ?*anyopaque, offer: ?*c.struct_wl_data_offer, dnd_action: u32) callconv(.c) void {
    _ = data;
    _ = offer;
    _ = dnd_action;
}

fn onSourceTarget(data: ?*anyopaque, source: ?*c.struct_wl_data_source, mime_type: [*c]const u8) callconv(.c) void {
    _ = data;
    _ = source;
    _ = mime_type;
}

fn onSourceDndDropPerformed(data: ?*anyopaque, source: ?*c.struct_wl_data_source) callconv(.c) void {
    _ = data;
    _ = source;
}

fn onSourceDndFinished(data: ?*anyopaque, source: ?*c.struct_wl_data_source) callconv(.c) void {
    _ = data;
    _ = source;
}

fn onSourceAction(data: ?*anyopaque, source: ?*c.struct_wl_data_source, dnd_action: u32) callconv(.c) void {
    _ = data;
    _ = source;
    _ = dnd_action;
}
