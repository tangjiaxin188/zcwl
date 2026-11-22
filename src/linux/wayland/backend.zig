//! Wayland backend entry point.
//!
//! Owns the display connection, the optional native loaders, input state,
//! windows, contexts, monitors and the clipboard bridge.

const std = @import("std");
const builtin = @import("builtin");

const Event = @import("../../Event.zig");
const General = @import("../../General.zig");
const Config = @import("../../Config.zig");
const c = @import("protocols.zig").c;

const display_mod = @import("display.zig");
const Display = display_mod.Display;
const event_mod = @import("event.zig");
const Queue = event_mod.Queue;
const Sink = event_mod.Sink;
const input_mod = @import("input.zig");
const Input = input_mod.Input;
const monitor_mod = @import("monitor.zig");
const Monitor = monitor_mod.Monitor;
const clipboard_mod = @import("clipboard.zig");
const Clipboard = clipboard_mod.Clipboard;
const cursor_mod = @import("cursor.zig");
const Cursor = cursor_mod.Cursor;
const ime_mod = @import("ime.zig");
const Ime = ime_mod.Ime;
const window_mod = @import("window.zig");
const WindowImpl = window_mod.Window;
const context_mod = @import("context.zig");
const ContextImpl = context_mod.Context;
const loader_mod = @import("loader.zig");

pub const Backend = @This();

pub const Window = WindowImpl;
pub const Context = ContextImpl;
pub const NativeContext = ContextImpl.NativeContext;
pub const NativeWindow = General.NativeWindow;

alloc: std.mem.Allocator,
display: *Display,
loader: loader_mod.Loader,
input: *Input,
queue: Queue,
clipboard: Clipboard,
ime: ?Ime = null,
cursor: Cursor,
monitors: std.ArrayList(*Monitor) = .empty,
windows: std.ArrayList(*WindowImpl) = .empty,
contexts: std.ArrayList(*ContextImpl) = .empty,
owned_text: std.ArrayList([]u8) = .empty,
next_id: u32 = 1,
app_id: []u8,

pub fn init(alloc: std.mem.Allocator, config: Config.AppConfig) !*Backend {
    const display = try Display.init(alloc);
    errdefer display.uninit();

    const app_id = try dupeZ(alloc, if (config.application_id.len == 0) "zcwl-app" else config.application_id);
    errdefer alloc.free(app_id);

    const self = try alloc.create(Backend);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .display = display,
        .loader = loader_mod.Loader.init(),
        .input = undefined,
        .queue = Queue.init(alloc),
        .clipboard = undefined,
        .cursor = undefined,
        .app_id = app_id,
    };

    self.input = Input.init(
        alloc,
        self.sink(),
        if (self.loader.xkb) |*xkb| xkb else null,
        display.seat,
    ) catch |err| {
        self.loader.deinit();
        self.queue.deinit();
        return err;
    };
    // A second roundtrip delivers wl_seat capabilities and creates the
    // pointer/keyboard objects.
    display.roundtrip();

    self.clipboard = Clipboard.init(alloc, display.data_device_manager, display.seat);
    self.clipboard.rebind();

    if (display.text_input_manager) |manager| {
        self.ime = Ime.init(manager, display.seat, self.sink());
        if (self.ime) |*ime| ime.rebind();
    }
    self.cursor = Cursor.init(display.cursor_shape_manager, self.input.pointerDevice());

    for (display.outputs.items) |global| {
        if (Monitor.init(alloc, self, display, global)) |monitor| {
            self.monitors.append(alloc, monitor) catch monitor.uninit();
        }
    }
    // Deliver wl_output geometry/mode/scale/name before the first query.
    display.roundtrip();

    General.reportInfo(.{
        .os = builtin.os.tag,
        .arch = builtin.cpu.arch,
        .backend = "wayland",
    });
    return self;
}

pub fn uninit(self: *Backend) void {
    while (self.contexts.items.len > 0) {
        self.contexts.items[self.contexts.items.len - 1].uninit();
    }
    while (self.windows.items.len > 0) {
        self.windows.items[self.windows.items.len - 1].uninit();
    }
    for (self.owned_text.items) |text| self.alloc.free(text);
    self.owned_text.deinit(self.alloc);
    for (self.monitors.items) |monitor| monitor.uninit();
    self.monitors.deinit(self.alloc);
    self.windows.deinit(self.alloc);
    self.contexts.deinit(self.alloc);
    self.queue.deinit();
    self.cursor.deinit();
    if (self.ime) |*ime| ime.deinit();
    self.clipboard.deinit();
    self.input.uninit();
    self.loader.deinit();
    self.display.uninit();
    self.alloc.free(self.app_id);
    self.alloc.destroy(self);
}
pub fn initWindow(self: *Backend, config: Config.WindowConfig) !*WindowImpl {
    const id = self.next_id;
    self.next_id += 1;
    const window = try WindowImpl.init(self, config, id);
    errdefer window.uninit();
    try self.windows.append(self.alloc, window);
    return window;
}

pub fn initContext(
    self: *Backend,
    native: *const NativeWindow,
    config: Config.ContextConfig,
    share: ?*ContextImpl,
) !*ContextImpl {
    const context = try ContextImpl.init(self, native, config, share);
    errdefer context.uninit();
    try self.contexts.append(self.alloc, context);
    return context;
}

pub fn pollEvent(self: *Backend, ev: *Event.Core) bool {
    self.clipboard.last_serial = self.input.lastSerial();
    self.display.pump();
    self.clipboard.last_serial = self.input.lastSerial();
    self.clipboard.poll();

    if (self.queue.pop()) |event| {
        ev.* = event;
        return true;
    }
    ev.* = .none;
    return false;
}

pub fn pushEvent(self: *Backend, ev: Event.Core) void {
    if (!self.queue.push(ev)) General.reportError(error.OutOfMemory);
}

pub fn getVulkanInstanceExtensions(self: *Backend) []const [*:0]const u8 {
    _ = self;
    return &vulkan_extensions;
}

const vulkan_extensions = [_][*:0]const u8{
    "VK_KHR_surface",
    "VK_KHR_wayland_surface",
};

pub fn getInfo(self: *Backend) General.BackendInfo {
    _ = self;
    return .{
        .platform = .wayland,
        .context_creator = .egl,
        .os = builtin.os.tag,
        .arch = builtin.cpu.arch,
    };
}

pub fn getMonitors(self: *Backend, allocator: std.mem.Allocator) ![]General.MonitorInfo {
    const result = try allocator.alloc(General.MonitorInfo, self.monitors.items.len);
    for (self.monitors.items, result) |monitor, *info| info.* = monitor.info();
    return result;
}

pub fn setClipboardText(self: *Backend, text: []const u8) !void {
    try self.clipboard.setText(text, self.input.lastSerial());
    self.display.flush();
}

pub fn getClipboardText(self: *Backend, allocator: std.mem.Allocator) ![]u8 {
    return self.clipboard.getText(allocator);
}

fn sink(self: *Backend) Sink {
    return .{
        .ctx = @ptrCast(self),
        .push_fn = pushThunk,
        .text_fn = textThunk,
        .surface_window_fn = surfaceWindowThunk,
        .apply_cursor_fn = applyCursorThunk,
        .focus_fn = focusThunk,
    };
}

fn pushThunk(ctx: *anyopaque, ev: Event.Core) void {
    const self: *Backend = @ptrCast(@alignCast(ctx));
    self.pushEvent(ev);
}

fn textThunk(ctx: *anyopaque, window_id: u32, text: []const u8) void {
    // Backends normalize text to UTF-8 before calling this; the bytes are
    // copied only to keep the event alive until Backend.uninit.
    const self: *Backend = @ptrCast(@alignCast(ctx));
    const copy = self.alloc.dupe(u8, text) catch |err| {
        General.reportError(err);
        return;
    };
    self.owned_text.append(self.alloc, copy) catch |err| {
        General.reportError(err);
        self.alloc.free(copy);
        return;
    };
    self.pushEvent(.{ .text_input = .{ .window_id = window_id, .text = copy } });
}

fn surfaceWindowThunk(ctx: *anyopaque, surface: ?*c.struct_wl_surface) ?u32 {
    const self: *Backend = @ptrCast(@alignCast(ctx));
    return self.windowIdForSurface(surface orelse return null);
}

fn applyCursorThunk(ctx: *anyopaque, window_id: u32, serial: u32) void {
    const self: *Backend = @ptrCast(@alignCast(ctx));
    if (self.windowById(window_id)) |window| window.applyCursor(serial);
}

fn focusThunk(ctx: *anyopaque, window_id: ?u32) void {
    const self: *Backend = @ptrCast(@alignCast(ctx));
    if (self.ime) |*ime| ime.focus(window_id);
}

pub fn windowIdForSurface(self: *Backend, surface: *c.struct_wl_surface) ?u32 {
    for (self.windows.items) |window| {
        if (window.surface == surface) return window.id;
    }
    return null;
}

pub fn windowById(self: *Backend, id: u32) ?*WindowImpl {
    for (self.windows.items) |window| {
        if (window.id == id) return window;
    }
    return null;
}

pub fn windowSizeById(self: *Backend, id: u32) General.Size {
    if (self.windowById(id)) |window| {
        if (!window.isConfigured()) return window.getRequestedSize();
        return window.getSize();
    }
    return .{ .w = 640, .h = 480 };
}

pub fn windowIsConfigured(self: *Backend, id: u32) bool {
    if (self.windowById(id)) |window| return window.isConfigured();
    return false;
}

pub fn resizeContexts(self: *Backend, window_id: u32, size: General.Size) void {
    for (self.contexts.items) |context| {
        if (context.window_id == window_id) context.resize(size);
    }
}

pub fn monitorScaleChanged(self: *Backend, output: *c.struct_wl_output) void {
    for (self.windows.items) |window| {
        if (window.hasOutput(output)) window.updateScale();
    }
}

pub fn scaleForOutput(self: *Backend, output: *c.struct_wl_output) f32 {
    for (self.monitors.items) |monitor| {
        if (monitor.output == output) return @floatFromInt(monitor.scale);
    }
    return 1.0;
}

pub fn removeWindow(self: *Backend, window: *WindowImpl) void {
    for (self.windows.items, 0..) |item, i| {
        if (item == window) {
            _ = self.windows.orderedRemove(i);
            return;
        }
    }
}

pub fn removeContext(self: *Backend, context: *ContextImpl) void {
    for (self.contexts.items, 0..) |item, i| {
        if (item == context) {
            _ = self.contexts.orderedRemove(i);
            return;
        }
    }
}

fn dupeZ(alloc: std.mem.Allocator, value: []const u8) ![]u8 {
    const buf = try alloc.alloc(u8, value.len + 1);
    @memcpy(buf[0..value.len], value);
    buf[value.len] = 0;
    return buf;
}
