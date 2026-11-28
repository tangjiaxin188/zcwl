/// Application: backend, window registry and event pump.
const App = @This();
const std = @import("std");

const Backend = @import("Backend.zig");
const Window = @import("Window.zig");
const Context = @import("Context.zig");
const Event = @import("Event.zig");
const General = @import("General.zig");
const Config = @import("Config.zig");

_alloc: std.mem.Allocator,
_wtable: std.AutoHashMapUnmanaged(u32, *Window),
/// Every `Window` struct ever allocated by this App. `Window.uninit()` keeps
/// the small struct alive until `App.uninit()` so repeated teardown is safe.
_windows: std.ArrayListUnmanaged(*Window) = .empty,
backend: *Backend.Handle, // backend do anythings
reporter: General.Reporter,

/// Create an App. All library allocations use `alloc`.
/// Unimplemented backends are rejected by build.zig, so
/// `error.BackendUnavailable` is a defensive guard for a future runtime
/// fallback and is not reachable with the current build-time selection.
pub fn init(alloc: std.mem.Allocator, config: Config.AppConfig) !*App {
    const back = try Backend.init(alloc, config);
    errdefer back.uninit();

    const info = Backend.getInfo(back);
    if (info.requested != info.effective) return error.BackendUnavailable;

    const app = try alloc.create(App);
    errdefer alloc.destroy(app);
    app.* = App{
        ._alloc = alloc,
        .backend = back,
        ._wtable = .empty,
        ._windows = .empty,
        .reporter = config.reporter,
    };
    return app;
}

/// Destroy the backend and all live windows, then free every `Window` struct
/// this App ever allocated. All `Window`/`Context` pointers become invalid.
pub fn uninit(self: *App) void {
    // `Window.uninit()` deregisters itself, so take an entry out of the table
    // before calling it instead of iterating while mutating.
    while (self._wtable.count() != 0) {
        var it = self._wtable.iterator();
        const entry = it.next().?;
        const id = entry.key_ptr.*;
        const w = entry.value_ptr.*;
        _ = self._wtable.remove(id);
        w.uninit();
    }
    self._wtable.deinit(self._alloc);
    self.backend.uninit();
    for (self._windows.items) |w| self._alloc.destroy(w);
    self._windows.deinit(self._alloc);
    self._alloc.destroy(self);
}

/// config : WindowConfig
pub fn createWindow(self: *App, config: Config.WindowConfig) !*Window {
    if (config.size.w == 0 or config.size.h == 0) return error.InvalidSize;
    if (config.size.w > std.math.maxInt(i32) or config.size.h > std.math.maxInt(i32)) return error.InvalidSize;

    const client_api = config.client_api;
    const bw = try self.backend.initWindow(config);
    const cw = try Window.init(self, bw, client_api);
    self._windows.append(self._alloc, cw) catch |err| {
        self._alloc.destroy(cw);
        bw.uninit();
        return err;
    };
    self._wtable.put(self._alloc, cw.id, cw) catch |err| {
        cw.uninit();
        return err;
    };
    return cw;
}

/// Returns the window for `win_id`, or null if it has been destroyed.
pub fn getWindowById(self: *App, win_id: u32) ?*Window {
    return self._wtable.get(win_id);
}

pub fn _removeWindow(self: *App, win: *Window) void {
    _ = self._wtable.remove(win.id);
}

/// Poll one event. Returns false and writes `.none` when the queue is empty.
/// Window events may refer to destroyed windows; resolve them with
/// `getWindowById()` and ignore `null`.
pub fn pollEvent(self: *App, ev: *Event.Core) bool {
    return self.backend.pollEvent(ev);
}

/// Push an event. `TextInput.text` is borrowed and must stay valid until polled.
pub fn pushEvent(self: *App, ev: Event.Core) void {
    return self.backend.pushEvent(ev);
}

/// Vulkan instance extensions required by the backend. The slice is
/// backend-owned; do not free it.
pub fn getVulkanInstanceExtensions(self: *App) []const [*:0]const u8 {
    return self.backend.getVulkanInstanceExtensions();
}

/// Requested/effective backend, platform and context creator.
pub fn getBackendInfo(self: *App) General.BackendInfo {
    return Backend.getInfo(self.backend);
}

/// Monitors known to the backend. The caller owns the returned slice.
pub fn getMonitors(self: *App, allocator: std.mem.Allocator) ![]General.MonitorInfo {
    return self.backend.getMonitors(allocator);
}

/// Set clipboard text. The backend chooses its standard UTF-8 text MIME.
pub fn setClipboardText(self: *App, text: []const u8) !void {
    return self.backend.setClipboardText(text);
}

/// Clipboard text. Returns null when empty or no text representation.
/// `error.Uninitialized` means the backend has no clipboard support.
pub fn getClipboardText(self: *App, allocator: std.mem.Allocator) !?[]u8 {
    return self.backend.getClipboardText(allocator);
}

/// MIME types currently offered. Returns null when the clipboard is empty;
/// `error.Uninitialized` when the backend has no clipboard support.
/// Each string and the outer slice are caller-owned.
pub fn getClipboardMimeTypes(self: *App, allocator: std.mem.Allocator) !?[][]u8 {
    return self.backend.getClipboardMimeTypes(allocator);
}

/// Read one MIME representation. Returns null when the clipboard is empty.
/// `error.Uninitialized` means the backend has no clipboard support;
/// `error.WouldBlock` means the async transfer is still in progress;
/// `error.Unsupported` means this MIME type is not offered.
pub fn getClipboardData(
    self: *App,
    mime: []const u8,
    allocator: std.mem.Allocator,
) !?[]u8 {
    return self.backend.getClipboardData(mime, allocator);
}

/// Set one MIME representation. The backend copies `mime` and `data`.
/// Returns `error.Uninitialized` when the backend has no clipboard support.
pub fn setClipboardData(self: *App, mime: []const u8, data: []const u8) !void {
    return self.backend.setClipboardData(mime, data);
}

/// Set multiple MIME representations at once.
pub fn setClipboardItems(self: *App, items: []const General.ClipboardItem) !void {
    return self.backend.setClipboardItems(items);
}
