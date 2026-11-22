//! API completeness tests.
//!
//! Built by a backend step (for example `zig build test null`), which supplies
//! `@import("zcwl")` compiled with that backend.
//!
//! This suite only checks that the public API exists, is callable and has the
//! expected shape. It asserts no backend-specific values.
//!
//! Rules for keeping it backend-agnostic:
//!   * only use the public API (`@import("zcwl")`) and the shared Config types;
//!   * never pass fake native handles to backend functions;
//!   * ignore results/errors of backend-dependent operations.

const std = @import("std");
const zcwl = @import("zcwl");

const General = zcwl.General;

test "public API surface" {
    comptime {
        _ = zcwl.App;
        _ = zcwl.Window;
        _ = zcwl.Context;
        _ = zcwl.Event;
        _ = zcwl.Event.Core;
        _ = zcwl.General;
        _ = zcwl.Vulkan;
        _ = zcwl.Config;

        // App (init/createWindow are generic: exercised in the callable test).
        _ = zcwl.App.uninit;
        _ = zcwl.App.getWindowById;
        _ = zcwl.App.pollEvent;
        _ = zcwl.App.pushEvent;
        _ = zcwl.App.getVulkanInstanceExtensions;
        _ = zcwl.App.getBackendInfo;
        _ = zcwl.App.getMonitors;
        _ = zcwl.App.setClipboardText;
        _ = zcwl.App.getClipboardText;

        // Window (createContext is generic: exercised in the callable test).
        _ = zcwl.Window.destroy;
        _ = zcwl.Window.destroyContext;
        _ = zcwl.Window.getContext;
        _ = zcwl.Window.setTitle;
        _ = zcwl.Window.getTitle;
        _ = zcwl.Window.getId;
        _ = zcwl.Window.getClientApi;
        _ = zcwl.Window.setMaxSize;
        _ = zcwl.Window.setSize;
        _ = zcwl.Window.getSize;
        _ = zcwl.Window.setPos;
        _ = zcwl.Window.getPos;
        _ = zcwl.Window.getFramebufferSize;
        _ = zcwl.Window.getDpiScale;
        _ = zcwl.Window.setResizable;
        _ = zcwl.Window.setMinSize;
        _ = zcwl.Window.setFullscreen;
        _ = zcwl.Window.setCursor;
        _ = zcwl.Window.setFocus;
        _ = zcwl.Window.minimize;
        _ = zcwl.Window.maximize;
        _ = zcwl.Window.setImeAllowed;
        _ = zcwl.Window.setImeCursorArea;
        _ = zcwl.Window.createVulkanSurface;
        _ = zcwl.Window.getNative;
        _ = zcwl.Window.eq;
        _ = zcwl.Window.getInfo;
        _ = zcwl.Window.isFullscreen;
        _ = zcwl.Window.isMaximized;
        _ = zcwl.Window.isMinimized;
        _ = zcwl.Window.isFocused;
        _ = zcwl.Window.isResizable;
        _ = zcwl.Window.isDecorated;
        _ = zcwl.Window.isAlwaysOnTop;
        _ = zcwl.Window.getOpacity;
        _ = zcwl.Window.setIcon;
        _ = zcwl.Window.setDecorated;
        _ = zcwl.Window.setAlwaysOnTop;
        _ = zcwl.Window.setOpacity;
        _ = zcwl.Window.setCursorVisible;
        _ = zcwl.Window.setAspectRatio;
        _ = zcwl.Window.requestAttention;

        // Context
        _ = zcwl.Context.getKind;
        _ = zcwl.Context.getInfo;
        _ = zcwl.Context.getNative;
        _ = zcwl.Context.uninit;
        _ = zcwl.Context.makeCurrent;
        _ = zcwl.Context.clearCurrent;
        _ = zcwl.Context.getCurrent;
        _ = zcwl.Context.getProcAddress;
        _ = zcwl.Context.swapBuffers;
        _ = zcwl.Context.setSwapInterval;

        // Types and opt-in hooks
        _ = zcwl.Vulkan.Instance;
        _ = zcwl.Vulkan.SurfaceKHR;
        _ = zcwl.Vulkan.AllocationCallbacks;
        _ = zcwl.Vulkan.GetInstanceProcAddr;
        _ = zcwl.Config.WindowConfig;
        _ = General.Size;
        _ = General.Position;
        _ = General.Cursor;
        _ = General.GraphicsApi;
        _ = General.SystemInfo;
        _ = General.NativeWindow;
        _ = General.BackendInfo;
        _ = General.ContextInfo;
        _ = General.WindowInfo;
        _ = General.MonitorInfo;
        _ = @TypeOf(General.error_reporter);
        _ = @TypeOf(General.info_reporter);
    }

    try std.testing.expectEqual(@as(usize, 1), @sizeOf(General.Cursor));
    const default_window_config = zcwl.Config.WindowConfig{};
    try std.testing.expectEqual(General.GraphicsApi.opengl, default_window_config.client_api);
    try std.testing.expect(zcwl.getVersion().len > 0);
}

test "backend memory ownership" {
    // `std.testing.allocator` fails the test if any allocation made through
    // the library is not returned. All getters that allocate are explicitly
    // freed here; borrowed strings (title, WindowInfo/ContextInfo) are not.
    const app = zcwl.App.init(std.testing.allocator, .{
        .application_id = "org.zcwl.test",
    }) catch return;
    defer app.uninit();

    const win = app.createWindow(.{
        .title = "memory",
        .client_api = .opengles,
    }) catch return;
    defer win.destroy();

    // Borrowed: must not be freed by the caller.
    _ = win.getTitle();
    try win.setTitle("memory-2");
    _ = win.getTitle();

    // Caller-owned arrays/text.
    const monitors = try app.getMonitors(std.testing.allocator);
    defer std.testing.allocator.free(monitors);
    for (monitors) |monitor| {
        // Borrowed: the monitor owns this string.
        _ = monitor.name;
    }

    if (app.getClipboardText(std.testing.allocator)) |text| {
        defer std.testing.allocator.free(text);
    } else |_| {}
    app.setClipboardText("memory") catch {};

    // Context is optional (backend may lack EGL), so only its lifecycle is
    // checked when creation succeeds.
    if (win.createContext(.{ .api = .opengles, .major = 3, .minor = 0 }, null)) |ctx| {
        _ = ctx.getInfo(); // borrowed strings owned by Context
        ctx.makeCurrent() catch {};
        _ = ctx.getProcAddress("glClear");
        ctx.swapBuffers() catch {};
        win.destroyContext();
        try std.testing.expect(win.getContext() == null);
    } else |_| {}
}

test "app uninit releases live windows" {
    const app = zcwl.App.init(std.testing.allocator, .{}) catch return;

    const win = app.createWindow(.{ .title = "still-open" }) catch {
        app.uninit();
        return;
    };
    try std.testing.expect(app.getWindowById(win.getId()) == win);
    _ = win.createContext(.{ .api = .opengles, .major = 3, .minor = 0 }, null) catch {};

    // Deliberately do NOT call win.destroy(): App.uninit must release the
    // window wrapper, backend window, context list and the window table.
    app.uninit();
}

fn appLifetime(allocator: std.mem.Allocator) !void {
    const app = try zcwl.App.init(allocator, .{
        .application_id = "org.zcwl.oom",
    });
    defer app.uninit();
}

test "allocation failures during App.init are cleaned up" {
    // Skip on machines without a usable backend: the failure-walk below only
    // makes sense if the first init succeeds.
    const probe = zcwl.App.init(std.testing.allocator, .{}) catch return;
    probe.uninit();

    try std.testing.checkAllAllocationFailures(std.testing.allocator, appLifetime, .{});
}

fn windowLifetime(allocator: std.mem.Allocator) !void {
    const app = try zcwl.App.init(allocator, .{
        .application_id = "org.zcwl.oom",
    });
    defer app.uninit();

    const win = try app.createWindow(.{
        .title = "oom",
        .client_api = .opengles,
    });
    defer win.destroy();
    try win.setTitle("oom-2");
    _ = win.getTitle();
}

test "allocation failures during window creation are cleaned up" {
    const probe = zcwl.App.init(std.testing.allocator, .{}) catch return;
    probe.uninit();

    try std.testing.checkAllAllocationFailures(std.testing.allocator, windowLifetime, .{});
}

test "public API is callable" {
    const app = zcwl.App.init(std.testing.allocator, zcwl.Config.AppConfig{
        .application_id = "org.zcwl.test",
    }) catch return;
    defer app.uninit();

    const win = app.createWindow(zcwl.Config.WindowConfig{}) catch return;
    defer win.destroy();

    const backend_info = app.getBackendInfo();
    try std.testing.expectEqual(backend_info.requested, backend_info.effective);

    // Window API: call everything; backend-specific results are not asserted.
    _ = win.getId();
    _ = win.getClientApi();
    _ = win.getInfo();
    _ = win.isFullscreen();
    _ = win.isMaximized();
    _ = win.isMinimized();
    _ = win.isFocused();
    _ = win.isResizable();
    _ = win.isDecorated();
    _ = win.isAlwaysOnTop();
    _ = win.getOpacity();
    _ = win.getSize();
    win.setSize(.{ .w = 320, .h = 240 });
    _ = win.getPos();
    win.setPos(.{ .x = 0, .y = 0 });
    _ = win.getFramebufferSize();
    _ = win.getDpiScale();
    win.setResizable(true);
    win.setMinSize(null);
    win.setMaxSize(null);
    win.setFullscreen(false) catch {};
    win.setCursor(.arrow) catch {};
    win.setFocus();
    win.minimize();
    win.maximize();
    win.setImeAllowed(true) catch {};
    win.setImeCursorArea(.{ .x = 0, .y = 0 }, .{ .w = 1, .h = 1 });
    win.setIcon(&.{}, 0, 0) catch {};
    win.setDecorated(true) catch {};
    win.setAlwaysOnTop(false) catch {};
    win.setOpacity(1.0);
    win.setCursorVisible(true);
    win.setAspectRatio(null);
    win.requestAttention() catch {};
    _ = win.getNative();
    _ = win.getTitle();
    win.setTitle("api") catch {};
    _ = app.getWindowById(win.getId());

    // App-level queries and clipboard.
    _ = app.getBackendInfo();
    const monitors = app.getMonitors(std.testing.allocator) catch null;
    if (monitors) |m| std.testing.allocator.free(m);
    app.setClipboardText("") catch {};
    const clipboard = app.getClipboardText(std.testing.allocator) catch null;
    if (clipboard) |c| std.testing.allocator.free(c);

    // Context API: only available if this backend can create a context.
    if (win.createContext(zcwl.Config.ContextConfig{}, null)) |ctx| {
        defer win.destroyContext();
        _ = ctx.getKind();
        _ = ctx.getInfo();
        _ = ctx.getNative();
        ctx.makeCurrent() catch {};
        _ = zcwl.Context.getCurrent();
        _ = ctx.getProcAddress("glClear");
        ctx.swapBuffers() catch {};
        ctx.setSwapInterval(0) catch {};
        zcwl.Context.clearCurrent() catch {};
    } else |_| {}

    // Vulkan helpers: only the shape is checked here; no fake VkInstance is
    // passed to the backend.
    const extensions: []const [*:0]const u8 = app.getVulkanInstanceExtensions();
    _ = extensions.len;

    const vk_win = app.createWindow(zcwl.Config.WindowConfig{ .client_api = .vulkan }) catch null;
    if (vk_win) |w| {
        defer w.destroy();
        // The client-api gate rejects this before reaching the backend.
        _ = w.createContext(zcwl.Config.ContextConfig{}, null) catch {};
    }

    // Event API: call poll/push; queue contents are backend-specific.
    var ev: zcwl.Event.Core = .none;
    _ = app.pollEvent(&ev);
    app.pushEvent(.unknown);
}
