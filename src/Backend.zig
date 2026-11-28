//! Compile-time backend dispatcher. `build.zig` supplies the
//! `backend_selected` module, which imports exactly one backend, so
//! unselected backends are not parsed or compiled.
//!
//!   .wayland => linux/wayland/backend.zig
//!   .null    => null/backend.zig
//!   other    => rejected by build.zig (not implemented yet)

const std = @import("std");

const options = @import("build_options");
const Event = @import("Event.zig");
const General = @import("General.zig");
const Config = @import("Config.zig");

pub const Kind = General.BackendKind;

/// Backend selected by build.zig (already resolved and validated).
pub const kind: Kind = switch (options.backend) {
    .null => .null,
    .wayland => .wayland,
    .x11 => .x11,
    .both => .both,
    .windows => .windows,
    .macos => .macos,
};

/// What is actually linked. Unimplemented selections are rejected by
/// `build.zig`, so this always matches `kind`.
pub const effective: Kind = kind;

const selected = @import("backend_selected.zig");

comptime {
    // build.zig generates this file. If another build with a different
    // -Dbackend overwrote it between generation and compilation, fail with a
    // clear message instead of an unrelated protocol/type error.
    if (!std.mem.eql(u8, selected.name, @tagName(options.backend))) {
        @compileError("backend_selected.zig does not match -Dbackend; " ++
            "run builds with different -Dbackend values serially");
    }
}

const impl = selected.impl;

/// The backend object stored by `App`.
pub const Handle = impl.Backend;
pub const NativeWindow = General.NativeWindow;
pub const NativeContext = impl.NativeContext;
pub const Window = impl.Window;
pub const Context = impl.Context;

// Compile-time backend contract check. A missing declaration is reported
// here instead of surfacing deep inside the forwarding wrappers.
comptime {
    for (.{
        "Backend",          "NativeContext",    "Window",                      "Context",
        "init",             "uninit",           "initWindow",                  "initContext",
        "pollEvent",        "pushEvent",        "getVulkanInstanceExtensions", "getInfo",
        "getMonitors",      "setClipboardText", "getClipboardText",            "getClipboardMimeTypes",
        "getClipboardData", "setClipboardData", "setClipboardItems",
    }) |name| {
        if (!@hasDecl(impl, name)) @compileError("backend missing declaration: " ++ name);
        _ = @field(impl, name);
    }

    for (.{
        "getId",            "uninit",             "getNative",        "setTitle",            "getTitle",
        "setMaxSize",       "setMinSize",         "setSize",          "getSize",             "setPos",
        "getPos",           "getFramebufferSize", "getDpiScale",      "setResizable",        "setFullscreen",
        "minimize",         "maximize",           "setFocus",         "requestAttention",    "setCursor",
        "setCursorVisible", "setAspectRatio",     "setImeAllowed",    "setImeCursorArea",    "getInfo",
        "setIcon",          "setDecorated",       "setAlwaysOnTop",   "setOpacity",          "setVisible",
        "startDragFiles",   "setCursorImage",     "clearCursorImage", "createVulkanSurface",
    }) |name| {
        if (!@hasDecl(impl.Window, name)) @compileError("backend Window missing method: " ++ name);
        _ = @field(impl.Window, name);
    }

    for (.{
        "getKind",      "getInfo",        "getNative",   "uninit",          "makeCurrent",
        "clearCurrent", "getProcAddress", "swapBuffers", "setSwapInterval",
    }) |name| {
        if (!@hasDecl(impl.Context, name)) @compileError("backend Context missing method: " ++ name);
        _ = @field(impl.Context, name);
    }
}

pub fn init(alloc: std.mem.Allocator, config: Config.AppConfig) !*Handle {
    return impl.init(alloc, config);
}

pub fn uninit(self: *Handle) void {
    impl.uninit(self);
}

pub fn initWindow(self: *Handle, config: Config.WindowConfig) !*Window {
    return impl.initWindow(self, config);
}

pub fn initContext(
    self: *Handle,
    native: *const NativeWindow,
    config: Config.ContextConfig,
    share: ?*Context,
) !*Context {
    return impl.initContext(self, native, config, share);
}

pub fn pollEvent(self: *Handle, ev: *Event.Core) bool {
    return impl.pollEvent(self, ev);
}

pub fn pushEvent(self: *Handle, ev: Event.Core) void {
    impl.pushEvent(self, ev);
}

pub fn getVulkanInstanceExtensions(self: *Handle) []const [*:0]const u8 {
    return impl.getVulkanInstanceExtensions(self);
}

pub fn getInfo(self: *Handle) General.BackendInfo {
    var info = impl.getInfo(self);
    info.requested = kind;
    info.effective = effective;
    return info;
}

pub fn getMonitors(self: *Handle, allocator: std.mem.Allocator) ![]General.MonitorInfo {
    return impl.getMonitors(self, allocator);
}

pub fn setClipboardText(self: *Handle, text: []const u8) !void {
    return impl.setClipboardText(self, text);
}

pub fn getClipboardText(self: *Handle, allocator: std.mem.Allocator) !?[]u8 {
    return impl.getClipboardText(self, allocator);
}

pub fn getClipboardMimeTypes(self: *Handle, allocator: std.mem.Allocator) !?[][]u8 {
    return impl.getClipboardMimeTypes(self, allocator);
}

pub fn getClipboardData(self: *Handle, mime: []const u8, allocator: std.mem.Allocator) !?[]u8 {
    return impl.getClipboardData(self, mime, allocator);
}

pub fn setClipboardData(self: *Handle, mime: []const u8, data: []const u8) !void {
    return impl.setClipboardData(self, mime, data);
}

pub fn setClipboardItems(self: *Handle, items: []const General.ClipboardItem) !void {
    return impl.setClipboardItems(self, items);
}
