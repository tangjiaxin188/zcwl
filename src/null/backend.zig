//! Headless null backend.
//!
//! No OS calls, no graphics: windows and events are kept in memory so the
//! platform-independent layer can be exercised anywhere (CI, tests). Context
//! creation is not supported (`error.Unsupported`) and the Vulkan helpers are
//! empty.
//!
//! `init` reports static system information through the opt-in
//! `General.info_reporter`; the backend never logs or performs I/O by itself.

const std = @import("std");
const builtin = @import("builtin");

const Event = @import("../Event.zig");
const General = @import("../General.zig");
const Config = @import("../Config.zig");
const Vulkan = @import("../Vulkan.zig");

pub const Backend = @This();

alloc: std.mem.Allocator,
queue: std.ArrayList(Event.Core) = .empty,
next_id: u32 = 1,

/// Shared WSI descriptor (`ndt`/`nwh`); both null for the null backend.
pub const NativeWindow = General.NativeWindow;

/// GL handles (EGL-like layout). Unused here: `initContext` is unsupported.
pub const NativeContext = struct {
    display: *anyopaque,
    config: *anyopaque,
    context: *anyopaque,
    surface: *anyopaque,
};

pub fn init(alloc: std.mem.Allocator, config: Config.AppConfig) !*Backend {
    _ = config;
    const b = try alloc.create(Backend);
    b.* = .{ .alloc = alloc };

    // Opt-in only: no reporter installed means no logging and no I/O.
    General.reportInfo(.{
        .os = builtin.os.tag,
        .arch = builtin.cpu.arch,
        .backend = "null",
    });
    return b;
}

pub fn uninit(self: *Backend) void {
    self.queue.deinit(self.alloc);
    self.alloc.destroy(self);
}

pub fn initWindow(self: *Backend, config: Config.WindowConfig) !*Window {
    const w = try self.alloc.create(Window);
    w.* = .{
        .backend = self,
        .id = self.next_id,
        .native = .{},
        .title = config.title,
        .size = config.size,
        .pos = config.position,
        .resizable = config.resizable,
        .decorated = config.decorated,
        .always_on_top = config.always_on_top,
        .client_api = config.client_api,
    };
    self.next_id += 1;
    return w;
}

pub fn initContext(
    self: *Backend,
    native: *const NativeWindow,
    config: Config.ContextConfig,
    share: ?*Context,
) !*Context {
    _ = self;
    _ = native;
    _ = config;
    _ = share;
    return error.Unsupported;
}

pub fn pollEvent(self: *Backend, ev: *Event.Core) bool {
    if (self.queue.items.len == 0) {
        ev.* = .none;
        return false;
    }
    ev.* = self.queue.orderedRemove(0);
    return true;
}

pub fn pushEvent(self: *Backend, ev: Event.Core) void {
    self.queue.append(self.alloc, ev) catch |err| General.reportError(err);
}

pub fn getVulkanInstanceExtensions(self: *Backend) []const [*:0]const u8 {
    _ = self;
    return &.{};
}

pub fn getInfo(self: *Backend) General.BackendInfo {
    _ = self;
    return .{
        .platform = .null,
        .context_creator = .none,
        .os = builtin.os.tag,
        .arch = builtin.cpu.arch,
    };
}

pub fn getMonitors(self: *Backend, allocator: std.mem.Allocator) ![]General.MonitorInfo {
    _ = self;
    return allocator.alloc(General.MonitorInfo, 0);
}

pub fn setClipboardText(self: *Backend, text: []const u8) !void {
    _ = self;
    _ = text;
}

pub fn getClipboardText(self: *Backend, allocator: std.mem.Allocator) ![]u8 {
    _ = self;
    return allocator.dupe(u8, "");
}

pub const Window = struct {
    backend: *Backend,
    id: u32,
    native: NativeWindow,
    title: []const u8 = "",
    size: General.Size = .{ .w = 640, .h = 480 },
    pos: ?General.Position = null,
    dpi: f32 = 1.0,
    resizable: bool = true,
    min_size: ?General.Size = null,
    max_size: ?General.Size = null,
    fullscreen: bool = false,
    maximized: bool = false,
    minimized: bool = false,
    focused: bool = false,
    client_api: General.GraphicsApi = .opengl,
    cursor: General.Cursor = .arrow,
    cursor_visible: bool = true,
    aspect_ratio: ?General.Ratio = null,
    decorated: bool = true,
    always_on_top: bool = false,
    opacity: f32 = 1.0,
    ime_allowed: bool = false,
    ime_pos: General.Position = .{ .x = 0, .y = 0 },
    ime_size: General.Size = .{ .w = 0, .h = 0 },

    pub fn getId(self: *Window) u32 {
        return self.id;
    }

    pub fn uninit(self: *Window) void {
        self.backend.alloc.destroy(self);
    }

    /// Both handles are null for the null backend.
    pub fn getNative(self: *Window) NativeWindow {
        return self.native;
    }

    /// Borrowed for the lifetime of the window; the null backend never copies.
    pub fn setTitle(self: *Window, title: []const u8) !void {
        self.title = title;
    }

    pub fn getTitle(self: *Window) []const u8 {
        return self.title;
    }

    pub fn setMaxSize(self: *Window, max_size: ?General.Size) void {
        self.max_size = max_size;
    }

    pub fn setSize(self: *Window, size: General.Size) void {
        self.size = size;
    }

    pub fn getSize(self: *Window) General.Size {
        return self.size;
    }

    pub fn setPos(self: *Window, pos: General.Position) void {
        self.pos = pos;
    }

    pub fn getPos(self: *Window) ?General.Position {
        return self.pos;
    }

    pub fn getFramebufferSize(self: *Window) General.Size {
        return .{
            .w = @intFromFloat(@as(f32, @floatFromInt(self.size.w)) * self.dpi),
            .h = @intFromFloat(@as(f32, @floatFromInt(self.size.h)) * self.dpi),
        };
    }

    pub fn getDpiScale(self: *Window) f32 {
        return self.dpi;
    }

    pub fn setResizable(self: *Window, resizable: bool) void {
        self.resizable = resizable;
    }

    pub fn setMinSize(self: *Window, min_size: ?General.Size) void {
        self.min_size = min_size;
    }

    pub fn setFullscreen(self: *Window, fullscreen: bool) !void {
        self.fullscreen = fullscreen;
    }

    pub fn setCursor(self: *Window, cursor: General.Cursor) !void {
        self.cursor = cursor;
    }

    pub fn setFocus(self: *Window) void {
        self.focused = true;
    }

    pub fn minimize(self: *Window) void {
        self.minimized = true;
    }

    pub fn maximize(self: *Window) void {
        self.maximized = true;
    }

    pub fn setImeAllowed(self: *Window, allowed: bool) !void {
        self.ime_allowed = allowed;
    }

    pub fn setImeCursorArea(self: *Window, pos: General.Position, size: General.Size) void {
        self.ime_pos = pos;
        self.ime_size = size;
    }

    pub fn getInfo(self: *Window) General.WindowInfo {
        return .{
            .size = self.size,
            .framebuffer_size = self.getFramebufferSize(),
            .position = self.pos,
            .dpi_scale = self.dpi,
            .client_api = self.client_api,
            .fullscreen = self.fullscreen,
            .maximized = self.maximized,
            .minimized = self.minimized,
            .focused = self.focused,
            .resizable = self.resizable,
            .decorated = self.decorated,
            .always_on_top = self.always_on_top,
            .opacity = self.opacity,
        };
    }

    pub fn setIcon(self: *Window, rgba: []const u8, width: u32, height: u32) !void {
        _ = self;
        _ = rgba;
        _ = width;
        _ = height;
    }

    pub fn setDecorated(self: *Window, decorated: bool) !void {
        self.decorated = decorated;
    }

    pub fn setAlwaysOnTop(self: *Window, always_on_top: bool) !void {
        self.always_on_top = always_on_top;
    }

    pub fn setOpacity(self: *Window, opacity: f32) !void {
        self.opacity = opacity;
    }

    pub fn setCursorVisible(self: *Window, visible: bool) void {
        self.cursor_visible = visible;
    }

    pub fn setAspectRatio(self: *Window, ratio: ?General.Ratio) void {
        self.aspect_ratio = ratio;
    }

    pub fn requestAttention(self: *Window) !void {
        _ = self;
    }

    pub fn createVulkanSurface(
        self: *Window,
        instance: Vulkan.Instance,
        get_instance_proc_addr: Vulkan.GetInstanceProcAddr,
        allocator: ?*const Vulkan.AllocationCallbacks,
    ) !Vulkan.SurfaceKHR {
        _ = self;
        _ = instance;
        _ = get_instance_proc_addr;
        _ = allocator;
        return error.Unsupported;
    }
};

/// Present only so the backend interface compiles; `initContext` never
/// succeeds, so no Context instance is ever created by this backend.
pub const Context = struct {
    backend: *Backend,
    kind: General.GraphicsApi = .opengl,
    native: NativeContext,

    pub fn getKind(self: *Context) General.GraphicsApi {
        return self.kind;
    }

    pub fn getInfo(self: *Context) General.ContextInfo {
        return .{ .kind = self.kind, .creator = .none };
    }

    pub fn getNative(self: *Context) *const NativeContext {
        return &self.native;
    }

    pub fn uninit(self: *Context) void {
        _ = self;
        @panic("null backend: Context.uninit called");
    }

    pub fn makeCurrent(self: *Context) !void {
        _ = self;
        return error.Unsupported;
    }

    pub fn clearCurrent(self: *Context) !void {
        _ = self;
        return error.Unsupported;
    }

    pub fn getProcAddress(self: *Context, name: [*:0]const u8) ?General.ProcAddr {
        _ = self;
        _ = name;
        return null;
    }

    pub fn swapBuffers(self: *Context) !void {
        _ = self;
        return error.Unsupported;
    }

    pub fn setSwapInterval(self: *Context, interval: i32) !void {
        _ = self;
        _ = interval;
        return error.Unsupported;
    }
};
