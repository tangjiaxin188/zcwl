//! Compile-time backend dispatcher. Wayland is implemented; other selections
//! currently fall back to the null backend.
//!
//!   .wayland => src/linux/wayland/backend.zig
//!   .x11 / .both / .windows / .macos / .null => null

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

/// What is actually linked. Only `.wayland` has a real driver today; other
/// selections fall back to null.
pub const effective: Kind = switch (kind) {
    .wayland => .wayland,
    .x11, .both, .windows, .macos, .null => .null,
};

const impl = switch (kind) {
    .wayland => @import("linux/wayland/backend.zig"),
    // TODO: x11, both, windows and macos drivers.
    .x11, .both, .windows, .macos, .null => @import("null/backend.zig"),
};

/// The backend object stored by `App`.
pub const Handle = impl.Backend;
pub const NativeWindow = General.NativeWindow;
pub const NativeContext = impl.NativeContext;
pub const Window = impl.Window;
pub const Context = impl.Context;

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

pub fn getClipboardText(self: *Handle, allocator: std.mem.Allocator) ![]u8 {
    return impl.getClipboardText(self, allocator);
}
