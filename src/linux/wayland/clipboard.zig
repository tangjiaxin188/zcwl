//! Wayland clipboard through `wl_data_device_manager`.
//!
//! The backend stores every offered MIME type, eagerly reads each one into an
//! owned byte cache, and exposes MIME list/data lookup plus multi-item sources.
//!
//! Empty clipboard: `null`; unavailable clipboard: `error.Uninitialized`;
//! async transfer not finished: `error.WouldBlock`.

const std = @import("std");
const General = @import("../../General.zig");
const c = @import("protocols.zig").c;
const Sink = @import("event.zig").Sink;

const text_mime = "text/plain;charset=utf-8";
const text_aliases = [_][]const u8{ text_mime, "text/plain", "UTF8_STRING" };
const uri_mime = "text/uri-list";
const max_read_bytes: usize = 64 * 1024 * 1024;

const Mime = struct {
    text: [:0]u8, // NUL-terminated allocation; slice length excludes NUL
};

const Cached = struct {
    mime: [:0]u8,
    data: []u8,
};

const Read = struct {
    mime: [:0]u8,
    fd: c_int,
    buf: std.ArrayList(u8) = .empty,

    fn deinit(self: *Read, alloc: std.mem.Allocator) void {
        _ = c.close(self.fd);
        alloc.free(self.mime);
        self.buf.deinit(alloc);
    }
};

const SourceItem = struct {
    mime: [:0]u8,
    data: []u8,
};

pub const Clipboard = struct {
    alloc: std.mem.Allocator,
    sink: Sink,
    manager: ?*c.struct_wl_data_device_manager,
    device: ?*c.struct_wl_data_device = null,
    initialized: bool = false,

    pending_offer: ?*c.struct_wl_data_offer = null,
    pending_mimes: std.ArrayList(Mime) = .empty,

    offer: ?*c.struct_wl_data_offer = null,
    mimes: std.ArrayList(Mime) = .empty,
    reads: std.ArrayList(Read) = .empty,
    cache: std.ArrayList(Cached) = .empty,
    pending_reads: bool = false,

    drag_offer: ?*c.struct_wl_data_offer = null,
    /// Set by the offer's `action` event; `finish` is illegal before it.
    drag_action: u32 = 0,
    drag_window: ?u32 = null,
    drag_x: f32 = 0,
    drag_y: f32 = 0,
    drag_serial: u32 = 0,
    drag_mimes: std.ArrayList(Mime) = .empty,
    drag_mime: ?[:0]u8 = null,
    drag_mime_slices: std.ArrayList([]const u8) = .empty,
    drag_read_fd: ?c_int = null,
    drag_read_buf: std.ArrayList(u8) = .empty,
    drag_drop_active: bool = false,
    drag_drop_uris: std.ArrayList(u8) = .empty,

    source: ?*c.struct_wl_data_source = null,
    source_items: std.ArrayList(SourceItem) = .empty,
    drag_source: ?*c.struct_wl_data_source = null,
    drag_source_items: std.ArrayList(SourceItem) = .empty,
    last_serial: u32 = 0,

    pub fn init(
        alloc: std.mem.Allocator,
        sink: Sink,
        manager: ?*c.struct_wl_data_device_manager,
        seat: ?*c.struct_wl_seat,
    ) Clipboard {
        var self = Clipboard{ .alloc = alloc, .sink = sink, .manager = manager };
        if (manager) |m| {
            if (seat) |s| {
                self.device = c.wl_data_device_manager_get_data_device(m, s);
            }
        }
        self.initialized = self.device != null;
        return self;
    }

    /// Called by `Backend` after the value has been placed in stable memory.
    pub fn rebind(self: *Clipboard) void {
        if (self.device) |device| {
            _ = c.wl_data_device_add_listener(device, &device_listener, self);
        }
    }

    pub fn deinit(self: *Clipboard) void {
        self.clearOffer();
        self.clearPending();
        self.clearDrag();
        self.clearSource();
        self.clearDragSource();
        if (self.device) |device| {
            // wl_data_device.release is a request since version 3.
            if (c.wl_data_device_get_version(device) >= 3) {
                c.wl_data_device_release(device);
            } else {
                c.wl_data_device_destroy(device);
            }
        }
        self.mimes.deinit(self.alloc);
        self.pending_mimes.deinit(self.alloc);
        self.reads.deinit(self.alloc);
        self.cache.deinit(self.alloc);
        self.drag_mimes.deinit(self.alloc);
        self.drag_mime_slices.deinit(self.alloc);
        self.drag_read_buf.deinit(self.alloc);
        self.drag_drop_uris.deinit(self.alloc);
        self.source_items.deinit(self.alloc);
        self.drag_source_items.deinit(self.alloc);
    }
    pub fn setText(self: *Clipboard, text: []const u8, serial: u32) !void {
        const items = [_]General.ClipboardItem{
            .{ .mime = text_mime, .data = text },
            .{ .mime = "text/plain", .data = text },
        };
        return self.setItems(&items, serial);
    }

    pub fn setData(self: *Clipboard, mime: []const u8, data: []const u8, serial: u32) !void {
        const item = General.ClipboardItem{ .mime = mime, .data = data };
        return self.setItems(&.{item}, serial);
    }

    pub fn setItems(self: *Clipboard, items: []const General.ClipboardItem, serial: u32) !void {
        if (!self.initialized) return error.Uninitialized;
        if (serial == 0) return error.WouldBlock;
        if (items.len == 0) return error.InvalidArgument;

        var prepared: std.ArrayList(SourceItem) = .empty;
        errdefer {
            for (prepared.items) |item| {
                self.alloc.free(item.mime);
                self.alloc.free(item.data);
            }
            prepared.deinit(self.alloc);
        }

        for (items) |item| {
            const mime = try dupeZ(self.alloc, item.mime);
            const data = self.alloc.dupe(u8, item.data) catch |err| {
                self.alloc.free(mime);
                return err;
            };
            prepared.append(self.alloc, .{ .mime = mime, .data = data }) catch |err| {
                self.alloc.free(mime);
                self.alloc.free(data);
                return err;
            };
        }

        const source = c.wl_data_device_manager_create_data_source(self.manager) orelse
            return error.Uninitialized;
        // Keep the old selection alive if creating the new source failed above.
        self.clearSource();
        self.source = source;
        self.source_items = prepared;
        _ = c.wl_data_source_add_listener(source, &source_listener, self);
        for (self.source_items.items) |item| {
            c.wl_data_source_offer(source, item.mime.ptr);
        }
        c.wl_data_device_set_selection(self.device, source, serial);
    }

    pub fn startDragFiles(
        self: *Clipboard,
        surface: *c.struct_wl_surface,
        paths: []const []const u8,
        serial: u32,
    ) !void {
        if (!self.initialized) return error.Unsupported;
        if (serial == 0) return error.WouldBlock;
        if (paths.len == 0) return error.InvalidArgument;

        const uris = try buildUriList(self.alloc, paths);
        // `startDragItems` copies the payload; this URI list is temporary.
        defer self.alloc.free(uris);

        const items = [_]General.ClipboardItem{
            .{ .mime = uri_mime, .data = uris },
        };
        try self.startDragItems(surface, &items, serial);
    }

    fn startDragItems(
        self: *Clipboard,
        surface: *c.struct_wl_surface,
        items: []const General.ClipboardItem,
        serial: u32,
    ) !void {
        var prepared: std.ArrayList(SourceItem) = .empty;
        errdefer {
            for (prepared.items) |item| {
                self.alloc.free(item.mime);
                self.alloc.free(item.data);
            }
            prepared.deinit(self.alloc);
        }

        for (items) |item| {
            const mime = try dupeZ(self.alloc, item.mime);
            const data = self.alloc.dupe(u8, item.data) catch |err| {
                self.alloc.free(mime);
                return err;
            };
            prepared.append(self.alloc, .{ .mime = mime, .data = data }) catch |err| {
                self.alloc.free(mime);
                self.alloc.free(data);
                return err;
            };
        }

        const source = c.wl_data_device_manager_create_data_source(self.manager) orelse
            return error.Uninitialized;
        // Keep the old drag source alive if creating the new one failed.
        self.clearDragSource();
        self.drag_source = source;
        self.drag_source_items = prepared;
        _ = c.wl_data_source_add_listener(source, &source_listener, self);
        if (c.wl_data_source_get_version(source) >= 3) {
            c.wl_data_source_set_actions(source, @intCast(c.WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY));
        }
        for (self.drag_source_items.items) |item| {
            c.wl_data_source_offer(source, item.mime.ptr);
        }
        c.wl_data_device_start_drag(self.device, source, surface, null, serial);
    }

    pub fn getText(self: *Clipboard, allocator: std.mem.Allocator) !?[]u8 {
        if (!self.initialized) return error.Uninitialized;
        for (text_aliases) |alias| {
            if (findMime(self, alias) == null) continue;
            return self.getData(alias, allocator);
        }
        return null;
    }

    pub fn getMimeTypes(self: *Clipboard, allocator: std.mem.Allocator) !?[][]u8 {
        if (!self.initialized) return error.Uninitialized;
        if (self.mimes.items.len == 0) return null;

        const result = try allocator.alloc([]u8, self.mimes.items.len);
        var filled: usize = 0;
        errdefer {
            for (result[0..filled]) |mime| allocator.free(mime);
            allocator.free(result);
        }
        for (self.mimes.items, 0..) |mime, i| {
            result[i] = try allocator.dupe(u8, mime.text);
            filled += 1;
        }
        return result;
    }

    pub fn getData(self: *Clipboard, mime: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        if (!self.initialized) return error.Uninitialized;
        if (self.mimes.items.len == 0) return null;

        if (findCached(self, mime)) |cached| {
            const copy = try allocator.dupe(u8, cached.data);
            return copy;
        }
        if (findMime(self, mime) == null) return error.Unsupported;
        return error.WouldBlock;
    }

    /// Drain all pending clipboard transfers. Safe to call from the event pump.
    pub fn poll(self: *Clipboard) void {
        if (self.pending_reads and self.last_serial != 0) self.startReads();

        var i: usize = 0;
        while (i < self.reads.items.len) {
            const read = &self.reads.items[i];
            var fds = [_]std.posix.pollfd{.{
                .fd = read.fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = std.posix.poll(&fds, 0) catch 0;
            if (ready <= 0) {
                i += 1;
                continue;
            }

            var chunk: [8192]u8 = undefined;
            const n = c.read(read.fd, &chunk, chunk.len);
            if (n > 0) {
                if (read.buf.items.len + @as(usize, @intCast(n)) > max_read_bytes) {
                    self.sink.report(error.ClipboardTooLarge);
                    var removed = self.reads.orderedRemove(i);
                    removed.deinit(self.alloc);
                    continue;
                }
                read.buf.appendSlice(self.alloc, chunk[0..@intCast(n)]) catch |err| {
                    self.sink.report(err);
                    var removed = self.reads.orderedRemove(i);
                    removed.deinit(self.alloc);
                    continue;
                };
                i += 1;
                continue;
            }

            var removed = self.reads.orderedRemove(i);
            if (n == 0) {
                const data = removed.buf.toOwnedSlice(self.alloc) catch |err| {
                    self.sink.report(err);
                    removed.deinit(self.alloc);
                    continue;
                };
                self.cache.append(self.alloc, .{ .mime = removed.mime, .data = data }) catch |err| {
                    self.sink.report(err);
                    self.alloc.free(removed.mime);
                    self.alloc.free(data);
                    _ = c.close(removed.fd);
                    removed.buf.deinit(self.alloc);
                    continue;
                };
                _ = c.close(removed.fd);
                removed.buf.deinit(self.alloc);
                // `wl_data_offer.finish` is only valid for drag-and-drop
                // offers (and only since version 3). Calling it on a
                // clipboard selection offer is a protocol error.
            } else {
                self.sink.report(error.ClipboardReadFailed);
                removed.deinit(self.alloc);
            }
        }

        self.pollDrag();
    }

    fn pollDrag(self: *Clipboard) void {
        const fd = self.drag_read_fd orelse return;
        var fds = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&fds, 0) catch 0;
        if (ready <= 0) return;

        var chunk: [8192]u8 = undefined;
        const n = c.read(fd, &chunk, chunk.len);
        if (n > 0) {
            if (self.drag_read_buf.items.len + @as(usize, @intCast(n)) > max_read_bytes) {
                self.sink.report(error.ClipboardTooLarge);
                self.clearDragOffer();
                return;
            }
            self.drag_read_buf.appendSlice(self.alloc, chunk[0..@intCast(n)]) catch |err| {
                self.sink.report(err);
                self.clearDragOffer();
            };
            return;
        }

        if (n < 0) {
            self.sink.report(error.ClipboardReadFailed);
            self.clearDragOffer();
            return;
        }

        const data = self.drag_read_buf.toOwnedSlice(self.alloc) catch |err| {
            self.sink.report(err);
            self.clearDragOffer();
            return;
        };
        const window_id = self.drag_window;
        const x = self.drag_x;
        const y = self.drag_y;

        self.drag_drop_uris.clearRetainingCapacity();
        self.drag_drop_uris.appendSlice(self.alloc, data) catch |err| {
            self.sink.report(err);
            self.alloc.free(data);
            self.clearDragOffer();
            return;
        };
        self.alloc.free(data);

        if (self.drag_offer) |offer| {
            // `finish` requires offer version >= 3 and a chosen action.
            if (c.wl_data_offer_get_version(offer) >= 3 and self.drag_action != 0) {
                c.wl_data_offer_finish(offer);
            }
        }
        self.clearDragOffer();
        if (window_id) |id| {
            self.sink.push(.{ .file_drop = .{
                .window_id = id,
                .x = x,
                .y = y,
                .uris = self.drag_drop_uris.items,
            } });
        }
    }

    fn buildDragMimeSlices(self: *Clipboard) void {
        self.drag_mime_slices.clearRetainingCapacity();
        for (self.drag_mimes.items) |mime| {
            self.drag_mime_slices.append(self.alloc, mime.text) catch |err| {
                self.sink.report(err);
                return;
            };
        }
    }

    fn startReads(self: *Clipboard) void {
        const offer = self.offer orelse return;
        if (self.last_serial == 0) {
            self.pending_reads = true;
            return;
        }
        self.pending_reads = false;

        for (self.mimes.items) |mime| {
            if (findCached(self, mime.text) != null or findRead(self, mime.text) != null) continue;

            const read_mime = dupeZ(self.alloc, mime.text) catch |err| {
                self.sink.report(err);
                continue;
            };
            var fds: [2]c_int = undefined;
            if (c.pipe(&fds) != 0) {
                self.alloc.free(read_mime);
                continue;
            }
            c.wl_data_offer_accept(offer, self.last_serial, mime.text.ptr);
            c.wl_data_offer_receive(offer, mime.text.ptr, fds[1]);
            _ = c.close(fds[1]);
            self.reads.append(self.alloc, .{ .mime = read_mime, .fd = fds[0] }) catch |err| {
                self.sink.report(err);
                _ = c.close(fds[0]);
                self.alloc.free(read_mime);
            };
        }
    }

    fn clearOffer(self: *Clipboard) void {
        for (self.reads.items) |*read| read.deinit(self.alloc);
        self.reads.clearRetainingCapacity();
        for (self.cache.items) |cached| {
            self.alloc.free(cached.mime);
            self.alloc.free(cached.data);
        }
        self.cache.clearRetainingCapacity();
        for (self.mimes.items) |mime| self.alloc.free(mime.text);
        self.mimes.clearRetainingCapacity();
        if (self.offer) |offer| c.wl_data_offer_destroy(offer);
        self.offer = null;
        self.pending_reads = false;
    }

    fn clearPending(self: *Clipboard) void {
        for (self.pending_mimes.items) |mime| self.alloc.free(mime.text);
        self.pending_mimes.clearRetainingCapacity();
        if (self.pending_offer) |offer| c.wl_data_offer_destroy(offer);
        self.pending_offer = null;
    }

    fn clearDragOffer(self: *Clipboard) void {
        if (self.drag_read_fd) |fd| {
            _ = c.close(fd);
            self.drag_read_fd = null;
        }
        self.drag_read_buf.clearRetainingCapacity();
        if (self.drag_mime) |mime| self.alloc.free(mime);
        self.drag_mime = null;
        if (self.drag_offer) |offer| c.wl_data_offer_destroy(offer);
        self.drag_offer = null;
        self.drag_action = 0;
        self.drag_window = null;
        self.drag_x = 0;
        self.drag_y = 0;
        self.drag_serial = 0;
        self.drag_drop_active = false;
    }

    fn clearDragMimes(self: *Clipboard) void {
        for (self.drag_mimes.items) |mime| self.alloc.free(mime.text);
        self.drag_mimes.clearRetainingCapacity();
        self.drag_mime_slices.clearRetainingCapacity();
    }

    fn clearDrag(self: *Clipboard) void {
        self.clearDragOffer();
        self.clearDragMimes();
        self.drag_drop_uris.clearRetainingCapacity();
    }

    fn clearDragSource(self: *Clipboard) void {
        if (self.drag_source) |source| c.wl_data_source_destroy(source);
        self.drag_source = null;
        for (self.drag_source_items.items) |item| {
            self.alloc.free(item.mime);
            self.alloc.free(item.data);
        }
        self.drag_source_items.clearRetainingCapacity();
    }

    fn clearSource(self: *Clipboard) void {
        if (self.source) |source| c.wl_data_source_destroy(source);
        self.source = null;
        for (self.source_items.items) |item| {
            self.alloc.free(item.mime);
            self.alloc.free(item.data);
        }
        self.source_items.clearRetainingCapacity();
    }

    fn beginPending(self: *Clipboard, offer: *c.struct_wl_data_offer) void {
        self.clearPending();
        self.pending_offer = offer;
        _ = c.wl_data_offer_add_listener(offer, &offer_listener, self);
    }

    fn beginDrag(self: *Clipboard, offer: *c.struct_wl_data_offer) void {
        self.clearDragOffer();
        self.clearDragMimes();
        self.drag_offer = offer;
        const from_pending = self.pending_offer == offer;
        if (from_pending) {
            self.drag_mimes = self.pending_mimes;
            self.pending_mimes = .empty;
            self.pending_offer = null;
        } else {
            self.clearPending();
        }
        if (!from_pending) _ = c.wl_data_offer_add_listener(offer, &offer_listener, self);
    }

    fn beginOffer(self: *Clipboard, offer: *c.struct_wl_data_offer) void {
        self.clearOffer();
        self.offer = offer;
        const from_pending = self.pending_offer == offer;
        if (from_pending) {
            self.mimes = self.pending_mimes;
            self.pending_mimes = .empty;
            self.pending_offer = null;
        } else {
            self.clearPending();
        }
        if (!from_pending) _ = c.wl_data_offer_add_listener(offer, &offer_listener, self);
    }

    fn selectDragMime(self: *Clipboard) void {
        if (self.drag_mime) |old| {
            self.alloc.free(old);
            self.drag_mime = null;
        }
        if (self.drag_mimes.items.len == 0) return;
        var selected: []const u8 = self.drag_mimes.items[0].text;
        for (self.drag_mimes.items) |mime| {
            if (std.mem.eql(u8, mime.text, uri_mime)) {
                selected = mime.text;
                break;
            }
        }
        self.drag_mime = dupeZ(self.alloc, selected) catch |err| {
            self.sink.report(err);
            return;
        };
    }

    fn acceptDrag(self: *Clipboard) void {
        const offer = self.drag_offer orelse return;
        const mime = self.drag_mime orelse return;
        if (c.wl_data_offer_get_version(offer) >= 3) {
            const copy: u32 = @intCast(c.WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);
            c.wl_data_offer_set_actions(offer, copy, copy);
        }
        c.wl_data_offer_accept(offer, self.drag_serial, mime.ptr);
    }
};

fn dupeZ(alloc: std.mem.Allocator, value: []const u8) ![:0]u8 {
    const buf = try alloc.allocSentinel(u8, value.len, 0);
    @memcpy(buf, value);
    return buf;
}

fn findMime(self: *Clipboard, mime: []const u8) ?*Mime {
    for (self.mimes.items) |*item| {
        if (std.mem.eql(u8, item.text, mime)) return item;
    }
    return null;
}

fn findRead(self: *Clipboard, mime: []const u8) ?*Read {
    for (self.reads.items) |*read| {
        if (std.mem.eql(u8, read.mime, mime)) return read;
    }
    return null;
}

fn findCached(self: *Clipboard, mime: []const u8) ?*Cached {
    for (self.cache.items) |*cached| {
        if (std.mem.eql(u8, cached.mime, mime)) return cached;
    }
    return null;
}

fn containsMime(mimes: []const Mime, mime: []const u8) bool {
    for (mimes) |item| {
        if (std.mem.eql(u8, item.text, mime)) return true;
    }
    return false;
}

fn fixedToFloat(value: c.wl_fixed_t) f32 {
    return @as(f32, @floatFromInt(value)) / 256.0;
}

fn appendEncodedUriPath(out: *std.ArrayList(u8), alloc: std.mem.Allocator, path: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (path) |byte| {
        const safe = (byte >= 'a' and byte <= 'z') or
            (byte >= 'A' and byte <= 'Z') or
            (byte >= '0' and byte <= '9') or
            byte == '/' or byte == '-' or byte == '.' or byte == '_' or byte == '~';
        if (safe) {
            try out.append(alloc, byte);
        } else {
            try out.append(alloc, '%');
            try out.append(alloc, hex[byte >> 4]);
            try out.append(alloc, hex[byte & 0x0f]);
        }
    }
}

fn buildUriList(alloc: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    for (paths) |path| {
        if (std.mem.startsWith(u8, path, "file://")) {
            try out.appendSlice(alloc, path);
        } else {
            if (!std.fs.path.isAbsolute(path)) return error.InvalidArgument;
            try out.appendSlice(alloc, "file://");
            try appendEncodedUriPath(&out, alloc, path);
        }
        try out.appendSlice(alloc, "\r\n");
    }
    return out.toOwnedSlice(alloc);
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
    if (id) |offer| self.beginPending(offer);
}

fn onSelection(data: ?*anyopaque, device: ?*c.struct_wl_data_device, id: ?*c.struct_wl_data_offer) callconv(.c) void {
    _ = device;
    const self: *Clipboard = @ptrCast(@alignCast(data orelse return));
    if (id == null) {
        self.clearOffer();
        self.clearPending();
        return;
    }
    if (self.offer == null or self.offer != id) self.beginOffer(id.?);
    self.startReads();
}

const offer_listener = c.struct_wl_data_offer_listener{
    .offer = onOffer,
    .source_actions = onOfferSourceActions,
    .action = onOfferAction,
};

fn onOffer(data: ?*anyopaque, offer: ?*c.struct_wl_data_offer, mime_type: [*c]const u8) callconv(.c) void {
    _ = offer;
    const self: *Clipboard = @ptrCast(@alignCast(data orelse return));
    if (mime_type == null or self.pending_offer == null) return;
    const mime = std.mem.span(@as([*:0]const u8, @ptrCast(mime_type)));
    if (containsMime(self.pending_mimes.items, mime)) return;
    const copy = dupeZ(self.alloc, mime) catch |err| {
        self.sink.report(err);
        return;
    };
    self.pending_mimes.append(self.alloc, .{ .text = copy }) catch |err| {
        self.sink.report(err);
        self.alloc.free(copy);
    };
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
    const self: *Clipboard = @ptrCast(@alignCast(data orelse return));
    if (mime_type == null) {
        _ = c.close(fd);
        return;
    }
    const items = if (self.source == source)
        self.source_items.items
    else if (self.drag_source == source)
        self.drag_source_items.items
    else {
        _ = c.close(fd);
        return;
    };
    const mime = std.mem.span(@as([*:0]const u8, @ptrCast(mime_type)));
    for (items) |item| {
        if (!std.mem.eql(u8, item.mime, mime)) continue;
        var written: usize = 0;
        while (written < item.data.len) {
            const n = c.write(fd, item.data[written..].ptr, item.data.len - written);
            if (n < 0) {
                self.sink.report(error.ClipboardWriteFailed);
                break;
            }
            if (n == 0) break;
            written += @intCast(n);
        }
        break;
    }
    _ = c.close(fd);
}

fn onCancelled(data: ?*anyopaque, source: ?*c.struct_wl_data_source) callconv(.c) void {
    const self: *Clipboard = @ptrCast(@alignCast(data orelse return));
    if (self.source == source) {
        self.clearSource();
    } else if (self.drag_source == source) {
        self.clearDragSource();
    }
}

fn onDataEnter(data: ?*anyopaque, device: ?*c.struct_wl_data_device, serial: u32, surface: ?*c.struct_wl_surface, x: c.wl_fixed_t, y: c.wl_fixed_t, id: ?*c.struct_wl_data_offer) callconv(.c) void {
    _ = device;
    const self: *Clipboard = @ptrCast(@alignCast(data orelse return));
    const offer = id orelse {
        self.clearDragOffer();
        return;
    };
    self.beginDrag(offer);
    self.drag_serial = serial;
    self.drag_x = fixedToFloat(x);
    self.drag_y = fixedToFloat(y);
    self.drag_window = self.sink.windowForSurface(surface);
    if (self.drag_window == null) {
        self.clearDragOffer();
        return;
    }
    self.selectDragMime();
    self.buildDragMimeSlices();
    self.acceptDrag();
    self.sink.push(.{ .drag_enter = .{
        .window_id = self.drag_window.?,
        .x = self.drag_x,
        .y = self.drag_y,
        .mimes = self.drag_mime_slices.items,
    } });
}

fn onDataLeave(data: ?*anyopaque, device: ?*c.struct_wl_data_device) callconv(.c) void {
    _ = device;
    const self: *Clipboard = @ptrCast(@alignCast(data orelse return));
    if (self.drag_window) |window_id| {
        self.sink.push(.{ .drag_leave = .{ .window_id = window_id } });
    }
    if (self.drag_drop_active) return;
    self.clearDragOffer();
}

fn onDataMotion(data: ?*anyopaque, device: ?*c.struct_wl_data_device, time: u32, x: c.wl_fixed_t, y: c.wl_fixed_t) callconv(.c) void {
    _ = device;
    _ = time;
    const self: *Clipboard = @ptrCast(@alignCast(data orelse return));
    const window_id = self.drag_window orelse return;
    self.drag_x = fixedToFloat(x);
    self.drag_y = fixedToFloat(y);
    self.acceptDrag();
    self.sink.push(.{ .drag_motion = .{
        .window_id = window_id,
        .x = self.drag_x,
        .y = self.drag_y,
    } });
}

fn onDataDrop(data: ?*anyopaque, device: ?*c.struct_wl_data_device) callconv(.c) void {
    _ = device;
    const self: *Clipboard = @ptrCast(@alignCast(data orelse return));
    const offer = self.drag_offer orelse return;
    if (self.drag_mime == null) self.selectDragMime();
    const mime = self.drag_mime orelse {
        self.clearDragOffer();
        return;
    };
    if (self.drag_read_fd != null) return;

    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) {
        self.sink.report(error.ClipboardReadFailed);
        self.clearDragOffer();
        return;
    }
    self.drag_drop_active = true;
    self.drag_drop_uris.clearRetainingCapacity();
    self.drag_read_buf.clearRetainingCapacity();
    c.wl_data_offer_accept(offer, self.drag_serial, mime.ptr);
    c.wl_data_offer_receive(offer, mime.ptr, fds[1]);
    _ = c.close(fds[1]);
    self.drag_read_fd = fds[0];
}

fn onOfferSourceActions(data: ?*anyopaque, offer: ?*c.struct_wl_data_offer, source_actions: u32) callconv(.c) void {
    _ = data;
    _ = offer;
    _ = source_actions;
}

fn onOfferAction(data: ?*anyopaque, offer: ?*c.struct_wl_data_offer, dnd_action: u32) callconv(.c) void {
    const self: *Clipboard = @ptrCast(@alignCast(data orelse return));
    if (self.drag_offer == offer) self.drag_action = dnd_action;
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
    const self: *Clipboard = @ptrCast(@alignCast(data orelse return));
    if (self.drag_source == source) self.clearDragSource();
}

fn onSourceAction(data: ?*anyopaque, source: ?*c.struct_wl_data_source, dnd_action: u32) callconv(.c) void {
    _ = data;
    _ = source;
    _ = dnd_action;
}
