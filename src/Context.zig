//! OpenGL / OpenGL ES context. The library creates contexts but does not wrap
//! GL; use `getNative()` and `getProcAddress()` for renderer integration.
const Context = @This();

const Backend = @import("Backend.zig");
const General = @import("General.zig");

const std = @import("std");

const ProcAddr = General.ProcAddr;

alloc: std.mem.Allocator,
backendContext: *Backend.Context,
kind: General.GraphicsApi,

/// mirror of the context bound on this thread; each thread has its own slot
threadlocal var _current: ?*Context = null;

pub fn init(alloc: std.mem.Allocator, bctx: *Backend.Context) !*Context {
    const ctx = try alloc.create(Context);
    ctx.* = .{
        .alloc = alloc,
        .backendContext = bctx,
        .kind = bctx.getKind(),
    };
    return ctx;
}

/// Graphics API of this context (`.opengl` or `.opengles`).
pub fn getKind(self: *Context) General.GraphicsApi {
    return self.kind;
}

/// Cached context information. Strings are owned by this Context.
pub fn getInfo(self: *Context) General.ContextInfo {
    return self.backendContext.getInfo();
}

/// Native context handles. Owned by this Context; do not destroy them.
/// Concrete layout is backend-defined (EGL/WGL/CGL).
pub fn getNative(self: *Context) *const Backend.NativeContext {
    return self.backendContext.getNative();
}

/// Destroy this context. Bound-thread unbind failures go to
/// `General.error_reporter`.
pub fn uninit(self: *Context) void {
    if (_current == self) {
        self.backendContext.clearCurrent() catch |err| General.reportError(err);
        _current = null;
    }
    self.backendContext.uninit();
    self.alloc.destroy(self);
}

/// Bind this context to the calling thread.
pub fn makeCurrent(self: *Context) !void {
    try self.backendContext.makeCurrent();
    _current = self;
}

/// Unbind the current thread's context; no-op if none is bound.
pub fn clearCurrent() !void {
    if (_current) |old| {
        try old.backendContext.clearCurrent();
        _current = null;
    }
}

/// The context bound on the calling thread, if any.
pub fn getCurrent() ?*Context {
    return _current;
}

/// Backend GL function loader; no fallback loading is performed here.
pub fn getProcAddress(self: *Context, name: [*:0]const u8) ?ProcAddr {
    return self.backendContext.getProcAddress(name);
}

/// Present the current frame; forwarded to the backend.
pub fn swapBuffers(self: *Context) !void {
    return self.backendContext.swapBuffers();
}

/// Vertical sync; forwarded to the backend.
pub fn setSwapInterval(self: *Context, interval: i32) !void {
    return self.backendContext.setSwapInterval(interval);
}
