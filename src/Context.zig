//! OpenGL / OpenGL ES context. The library creates contexts but does not wrap
//! GL; use `getNative()` and `getProcAddress()` for renderer integration.
const Context = @This();

const Backend = @import("Backend.zig");
const General = @import("General.zig");

const std = @import("std");

const ProcAddr = General.ProcAddr;

alloc: std.mem.Allocator,
backendContext: *Backend.Context,
backend: *Backend.Handle,
kind: General.GraphicsApi,
reporter: General.Reporter,
/// Slot in the owning `Window`; cleared on teardown so a direct `uninit()`
/// cannot leave `Window.context` dangling.
owner: ?*?*Context = null,

/// mirror of the context bound on this thread; each thread has its own slot
threadlocal var _current: ?*Context = null;

pub fn init(
    alloc: std.mem.Allocator,
    bctx: *Backend.Context,
    reporter: General.Reporter,
    backend: *Backend.Handle,
) !*Context {
    const ctx = try alloc.create(Context);
    ctx.* = .{
        .alloc = alloc,
        .backendContext = bctx,
        .backend = backend,
        .kind = bctx.getKind(),
        .reporter = reporter,
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

/// Internal teardown called by `Window`. Bound-thread unbind failures go to
/// this App's reporter. Destroy the context on the thread that made it
/// current, or call `clearCurrent()` there first; the cached current-context
/// pointer is thread-local and cannot be repaired from another thread.
pub fn uninit(self: *Context) void {
    if (self.owner) |slot| {
        if (slot.* == self) slot.* = null;
        self.owner = null;
    }
    if (_current == self) {
        self.backendContext.clearCurrent() catch |err| self.reporter.reportError(err);
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

/// Unbind this context from the calling thread.
/// Returns `error.NotCurrent` when this context is not bound on this thread;
/// a context bound on another thread cannot be released from here.
pub fn clearCurrent(self: *Context) !void {
    if (_current != self) return error.NotCurrent;
    try self.backendContext.clearCurrent();
    _current = null;
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
