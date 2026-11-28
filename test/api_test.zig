//! API completeness and backend-independent behavior tests.
//!
//! Run with `zig build test -Dbackend=null|wayland`; the build supplies
//! `@import("zcwl")` compiled with that backend.
//!
//! The suite checks that the public API exists, is callable, and that
//! platform-independent rules hold (validation, ownership, event queue).
//! Wayland-only behavior is not asserted; without a compositor those cases
//! skip silently.
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
        _ = zcwl.Event.DragEnter;
        _ = zcwl.Event.DragMotion;
        _ = zcwl.Event.DragLeave;
        _ = zcwl.Event.FileDrop;
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
        _ = zcwl.App.getClipboardMimeTypes;
        _ = zcwl.App.getClipboardData;
        _ = zcwl.App.setClipboardData;
        _ = zcwl.App.setClipboardItems;

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
        _ = zcwl.Window.setCursorImage;
        _ = zcwl.Window.clearCursorImage;
        _ = zcwl.Window.setAspectRatio;
        _ = zcwl.Window.requestAttention;
        _ = zcwl.Window.startDragFiles;

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
        _ = General.ClipboardItem;
        _ = zcwl.Config.CursorImage;
        _ = @TypeOf(General.Reporter);
        _ = @TypeOf((zcwl.Config.AppConfig{}).reporter);
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

    if (app.getClipboardText(std.testing.allocator)) |maybe_text| {
        if (maybe_text) |text| std.testing.allocator.free(text);
    } else |_| {}
    app.setClipboardText("memory") catch {};

    if (app.getClipboardMimeTypes(std.testing.allocator)) |maybe_mimes| {
        if (maybe_mimes) |mimes| {
            for (mimes) |mime| std.testing.allocator.free(mime);
            std.testing.allocator.free(mimes);
        }
    } else |_| {}
    if (app.getClipboardData("text/plain", std.testing.allocator) catch null) |data| {
        std.testing.allocator.free(data);
    }
    app.setClipboardData("text/plain", "memory") catch {};
    app.setClipboardItems(&[_]General.ClipboardItem{
        .{ .mime = "text/plain", .data = "memory" },
    }) catch {};

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
    _ = win.createContext(.{ .api = .opengl, .major = 3, .minor = 3 }, null) catch {};

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
    win.setSize(.{ .w = 320, .h = 240 }) catch {};
    _ = win.getPos();
    win.setPos(.{ .x = 0, .y = 0 }) catch {};
    _ = win.getFramebufferSize();
    _ = win.getDpiScale();
    win.setResizable(true) catch {};
    win.setMinSize(null) catch {};
    win.setMaxSize(null) catch {};
    win.setFullscreen(false) catch {};
    win.setCursor(.arrow) catch {};
    win.setFocus() catch {};
    win.minimize() catch {};
    win.maximize() catch {};
    win.setImeAllowed(true) catch {};
    win.setImeCursorArea(.{ .x = 0, .y = 0 }, .{ .w = 1, .h = 1 }) catch {};
    win.setIcon(&.{}, 0, 0) catch {};
    win.setDecorated(true) catch {};
    win.setAlwaysOnTop(false) catch {};
    try win.setOpacity(1.0);
    try win.setVisible(true);
    win.setCursorVisible(true) catch {};
    win.setAspectRatio(null) catch {};
    win.requestAttention() catch {};
    win.startDragFiles(&.{}) catch {};
    var cursor_pixel = [_]u8{ 0, 0, 0, 0 };
    win.setCursorImage(.arrow, .{
        .pixels = &cursor_pixel,
        .width = 1,
        .height = 1,
    }) catch {};
    win.clearCursorImage(.arrow) catch {};
    _ = win.getNative();
    _ = win.getTitle();
    try win.setTitle("api");
    try std.testing.expectEqualStrings("api", win.getTitle());
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
        // Creation must not leave the context bound; callers opt in explicitly.
        try std.testing.expect(zcwl.Context.getCurrent() == null);
        ctx.makeCurrent() catch {};
        _ = zcwl.Context.getCurrent();
        _ = ctx.getProcAddress("glClear");
        ctx.swapBuffers() catch {};
        ctx.setSwapInterval(0) catch {};
        ctx.clearCurrent() catch {};
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

var test_info_count: usize = 0;

fn countInfo(_: General.SystemInfo) void {
    test_info_count += 1;
}

test "reporter belongs to its App instance" {
    test_info_count = 0;
    const with_reporter = zcwl.App.init(std.testing.allocator, .{
        .reporter = .{ .info_fn = countInfo },
    }) catch return;
    defer with_reporter.uninit();
    try std.testing.expectEqual(@as(usize, 1), test_info_count);

    // A second App with no reporter must not inherit the first one's sink.
    const silent = zcwl.App.init(std.testing.allocator, .{}) catch return;
    defer silent.uninit();
    try std.testing.expectEqual(@as(usize, 1), test_info_count);
}

test "null backend event queue" {
    const app = zcwl.App.init(std.testing.allocator, .{}) catch return;
    defer app.uninit();
    if (app.getBackendInfo().effective != .null) return;

    var ev: zcwl.Event.Core = .none;
    try std.testing.expect(!app.pollEvent(&ev));
    try std.testing.expectEqual(std.meta.activeTag(ev), .none);

    app.pushEvent(.{ .custom = .{
        .window_id = 1,
        .ev_type = 7,
        .act = .{ .uint = 42 },
        .act_2 = .{ .boolean = true },
    } });
    try std.testing.expect(app.pollEvent(&ev));
    switch (ev) {
        .custom => |e| {
            try std.testing.expectEqual(@as(u32, 7), e.ev_type);
            try std.testing.expectEqual(@as(u32, 42), e.act.uint);
            try std.testing.expect(e.act_2.boolean);
        },
        else => try std.testing.expect(false),
    }
    try std.testing.expect(!app.pollEvent(&ev));
}

test "null backend window state and API gates" {
    const app = zcwl.App.init(std.testing.allocator, .{}) catch return;
    defer app.uninit();
    if (app.getBackendInfo().effective != .null) return;

    const win = try app.createWindow(.{ .visible = false });
    const id = win.getId();
    try std.testing.expect(app.getWindowById(id) == win);
    try win.setSize(.{ .w = 320, .h = 200 });
    try std.testing.expectEqual(@as(u32, 320), win.getSize().w);
    try std.testing.expectError(error.InvalidSize, win.setSize(.{ .w = 0, .h = 200 }));
    try std.testing.expectError(error.InvalidSize, win.setSize(.{
        .w = @as(u32, std.math.maxInt(i32)) + 1,
        .h = 1,
    }));
    try win.setSize(.{ .w = std.math.maxInt(i32), .h = std.math.maxInt(i32) });
    try std.testing.expectEqual(@as(u32, std.math.maxInt(i32)), win.getFramebufferSize().w);
    try win.setSize(.{ .w = 320, .h = 200 });
    try std.testing.expectError(error.InvalidSize, win.setMinSize(.{ .w = 0, .h = 1 }));
    try win.setMaxSize(.{ .w = 100, .h = 100 });
    try std.testing.expectError(error.InvalidSizeRange, win.setMinSize(.{ .w = 101, .h = 50 }));
    try win.setMinSize(null);
    try win.setMaxSize(null);
    try win.setVisible(true);
    try win.setAspectRatio(.{ .numerator = 16, .denominator = 9 });
    try std.testing.expectError(error.InvalidRatio, win.setAspectRatio(.{ .numerator = 16, .denominator = 0 }));
    try std.testing.expectError(error.InvalidRatio, win.setAspectRatio(.{ .numerator = 0, .denominator = 1 }));
    try std.testing.expectError(error.InvalidArgument, win.setIcon(&.{ 0, 0, 0 }, 1, 1));
    try std.testing.expectError(error.InvalidSize, win.setIcon(&.{}, 0, 0));

    try std.testing.expectError(error.InvalidOpacity, win.setOpacity(std.math.nan(f32)));
    try win.setOpacity(2.0);
    try std.testing.expectEqual(@as(f32, 1.0), win.getOpacity());
    try win.setOpacity(-1.0);
    try std.testing.expectEqual(@as(f32, 0.0), win.getOpacity());

    var cursor_pixel: [4]u8 = @splat(0);
    try std.testing.expectError(error.InvalidArgument, win.setCursorImage(.arrow, .{
        .pixels = &cursor_pixel,
        .width = 1,
        .height = 1,
        .hotspot_x = 1,
    }));
    try std.testing.expectError(error.InvalidArgument, win.setCursorImage(.arrow, .{
        .pixels = cursor_pixel[0..3],
        .width = 1,
        .height = 1,
    }));

    try std.testing.expectError(error.InvalidSize, app.createWindow(.{
        .size = .{ .w = 0, .h = 1 },
    }));
    try std.testing.expectError(error.InvalidSize, app.createWindow(.{
        .size = .{ .w = @as(u32, std.math.maxInt(i32)) + 1, .h = 1 },
    }));
    try std.testing.expectError(error.InvalidSize, win.setImeCursorArea(
        .{ .x = 0, .y = 0 },
        .{ .w = @as(u32, std.math.maxInt(i32)) + 1, .h = 1 },
    ));
    try std.testing.expectError(error.Unsupported, win.createContext(.{}, null));

    const gl_win = try app.createWindow(.{ .client_api = .opengl });
    defer gl_win.destroy();
    try std.testing.expectError(error.UnsupportedApi, gl_win.createContext(.{ .api = .opengles }, null));

    const vk_win = try app.createWindow(.{ .client_api = .vulkan });
    defer vk_win.destroy();
    try std.testing.expectError(error.UnsupportedApi, vk_win.createContext(.{}, null));

    // Backend ids are per-App; windows from different Apps must not compare
    // equal even when they share the same numeric id.
    const app2 = try zcwl.App.init(std.testing.allocator, .{});
    defer app2.uninit();
    const win2 = try app2.createWindow(.{});
    defer win2.destroy();
    try std.testing.expect(!win.eq(win2));

    win.destroy();
    try std.testing.expect(app.getWindowById(id) == null);
    // The Window struct is retained until App.uninit(), so repeated teardown
    // is a no-op instead of a use-after-free.
    win.destroy();
}
