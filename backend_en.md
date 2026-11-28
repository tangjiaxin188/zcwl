# Backend Interface Contract

> Chinese version: [`backend_zh.md`](backend_zh.md)

**Status**: This document is the complete backend contract already consumed by
the platform-independent layer. Implemented backends:
`src/linux/wayland/backend.zig` and `src/null/backend.zig`. Unimplemented
choices (x11/both/windows/macos) are rejected by `build.zig` instead of falling
back to null. A real backend must implement this contract; `Backend.zig` has
compile-time declaration checks and `test/api_test.zig` checks the public API
and behavior.

---

## 1. Module layout

Do not put everything into one file. Split each backend by responsibility;
`backend.zig` is the entry/composition point, and methods live next to their
type.

```text
src/<os>/
├── backend.zig      # Backend object: init/uninit, event pump, info, monitors, clipboard
├── window.zig       # Backend.Window + its methods
├── context.zig      # Backend.Context + NativeContext (EGL/WGL/CGL handles)
├── event.zig        # event queue and Event.Core construction helpers
├── input.zig        # keyboard/pointer/touch/pen/IME state -> Event.Core
├── monitor.zig      # monitor enumeration and change tracking
├── clipboard.zig    # global clipboard
├── cursor.zig       # cursor shape/lifecycle
├── vulkan.zig       # Vulkan WSI: required extensions + surface creation
├── loader.zig       # dlopen/dlsym tables for optional native libraries
├── native.zig       # platform helpers for General.NativeWindow (optional)
└── protocols/       # generated protocol sources (Wayland, X11 extras, ...)
```

Rules:

- `backend.zig` only re-exports/composes; type methods live in
  `window.zig` / `context.zig`.
- Platform code must not import the upper wrappers (`App.zig`, `Window.zig`,
  `Context.zig`).
- Shared leaf modules are only `General.zig`, `Config.zig`, `Event.zig`,
  `Vulkan.zig`, `EventQueue.zig`.
- `Backend.zig` re-exports the selected backend's
  `Backend`/`Window`/`Context`/`NativeContext`/functions at compile time.

---

## 2. Shared types

```zig
// General.zig — shared by the upper layer and backends
pub const NativeWindow = struct {
    ndt: ?*anyopaque = null, // wl_display*, Display*, ...
    nwh: ?*anyopaque = null, // wl_surface*, X11 Window, HWND, ...
};

pub const BackendKind = enum { wayland, x11, both, null, windows, macos };
pub const Platform = enum { wayland, x11, win32, cocoa, null };
pub const ContextCreator = enum { egl, wgl, cgl, none };
pub const GlProfile = enum { core, compatibility, es };

pub const ContextInfo = struct {
    kind: GraphicsApi,
    major: u8 = 0,
    minor: u8 = 0,
    profile: GlProfile = .core,
    vendor: []const u8 = "",
    renderer: []const u8 = "",
    version: []const u8 = "",
    shading_language: []const u8 = "",
    creator: ContextCreator = .none,
};

pub const WindowInfo = struct {
    size: Size,
    framebuffer_size: Size,
    position: ?Position,
    dpi_scale: f32,
    client_api: GraphicsApi,
    fullscreen: bool = false,
    maximized: bool = false,
    minimized: bool = false,
    focused: bool = false,
    resizable: bool = true,
    decorated: bool = true,
    always_on_top: bool = false,
    opacity: f32 = 1.0,
};

pub const MonitorInfo = struct {
    id: u32,
    name: []const u8, // borrowed
    position: Position,
    size: Size,
    work_area: Size,
    dpi_scale: f32,
    refresh_hz: f32,
};

pub const BackendInfo = struct {
    requested: BackendKind = .null, // filled by Backend.zig
    effective: BackendKind = .null, // filled by Backend.zig
    platform: Platform,
    context_creator: ContextCreator,
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
};
```

`General.NativeWindow` is passed by value and contains the two C-level handles
expected by bgfx-style renderers. Either field may be `null` when the platform
does not expose it. The library never interprets or owns these values.

`Config.AppConfig` provides `application_id` (`[]const u8`, empty by default;
backends fall back to `"zcwl-app"`). The Wayland backend passes it to
`xdg_toplevel.set_app_id`. `WindowConfig` / `ContextConfig` are the concrete
creation parameters.

---

## 3. Backend object

```zig
pub const Backend = struct {
    pub fn init(alloc: std.mem.Allocator, config: Config.AppConfig) !*Backend;
    pub fn uninit(self: *Backend) void;

    pub fn initWindow(self: *Backend, config: Config.WindowConfig) !*Window;
    pub fn initContext(
        self: *Backend,
        native: *const General.NativeWindow,
        config: Config.ContextConfig,
        share: ?*Context,
    ) !*Context;

    pub fn pollEvent(self: *Backend, ev: *Event.Core) bool;
    pub fn pushEvent(self: *Backend, ev: Event.Core) void;

    pub fn getVulkanInstanceExtensions(self: *Backend) []const [*:0]const u8;
    pub fn getInfo(self: *Backend) General.BackendInfo;

    pub fn getMonitors(self: *Backend, allocator: std.mem.Allocator) ![]General.MonitorInfo;
    pub fn setClipboardText(self: *Backend, text: []const u8) !void;
    pub fn getClipboardText(self: *Backend, allocator: std.mem.Allocator) !?[]u8;
    pub fn setClipboardData(self: *Backend, mime: []const u8, data: []const u8) !void;
    pub fn setClipboardItems(self: *Backend, items: []const General.ClipboardItem) !void;
    pub fn getClipboardMimeTypes(self: *Backend, allocator: std.mem.Allocator) !?[][]u8;
    pub fn getClipboardData(self: *Backend, mime: []const u8, allocator: std.mem.Allocator) !?[]u8;
};
```

| API | Description |
|---|---|
| `init` | Establish the platform connection/global state; on failure return an error and leave nothing half-initialized. |
| `uninit` | Release all global resources; no other method is called afterwards. |
| `initWindow` | Create a native window; the wrapper owns it and eventually calls `Window.uninit`. |
| `initContext` | Create a GL/GLES context on the native window; `share` is an existing backend context on the same display. |
| `pollEvent` | Write one event and return `true`; on an empty queue write `.none` and return `false`. |
| `pushEvent` | Enqueue an event; must not copy the borrowed `TextInput.text`. |
| `getVulkanInstanceExtensions` | Return the platform instance extensions required for surface creation; the backend owns the slice. |
| `getInfo` | Fill `platform`/`context_creator`/`os`/`arch`; `requested`/`effective` are overwritten by `Backend.zig`. |
| `getMonitors` | Return a caller-owned monitor array; return an empty array if none. |
| `setClipboardText` | Set UTF-8 clipboard text; the backend chooses the standard text MIME. Return `error.Uninitialized` when unavailable. |
| `getClipboardText` | Return caller-owned UTF-8 text; return `null` for an empty clipboard/no text representation. |
| `setClipboardData` | Set one MIME + byte payload; the backend copies both. Return `error.Uninitialized` when unavailable. |
| `setClipboardItems` | Set multiple MIME representations; return `error.Uninitialized` when unavailable. |
| `getClipboardMimeTypes` | Return a caller-owned MIME list; return `null` when empty; `error.Uninitialized` when unavailable. |
| `getClipboardData` | Return caller-owned bytes for a MIME; `null` when empty, `error.Uninitialized` when unavailable, `error.WouldBlock` while async transfer is pending, `error.Unsupported` when the MIME is not offered. |

Clipboard rules:

- MIME and data are opaque bytes; the backend must not interpret images, files or HTML.
- `text/plain;charset=utf-8`, `text/uri-list`, etc. are just MIME strings; file lists are parsed by the caller.
- `setClipboardData` / `setClipboardItems` must copy `mime` and `data`; the caller may reuse them immediately.
- Empty clipboard returns `null`; a backend without clipboard support returns `error.Uninitialized`; do not report “empty” as `Unsupported`.
- Reads may be asynchronous: return cached data when available, `error.WouldBlock` while pending, and `error.Unsupported` when the MIME is not offered.
- `getClipboardText` is only a text convenience wrapper over the same MIME/data rules.

### File drag and drop

`Window` adds:

```zig
pub fn startDragFiles(self: *Window, paths: []const []const u8) !void;
pub fn setCursorImage(self: *Window, state: General.Cursor, image: Config.CursorImage) !void;
pub fn clearCursorImage(self: *Window, state: General.Cursor) !void;
```

- `paths` must be absolute paths or `file://` URIs;
- the backend builds a `text/uri-list` and a `wl_data_source`;
- `start_drag` uses the latest pointer serial; no valid serial → `error.WouldBlock`;
- backends without DnD return `error.Unsupported`;
- the first version uses `icon_surface = null`.

Custom cursor rules:

- `Config.CursorImage.pixels` is row-major straight-alpha RGBA8 with exactly `width * height * 4` bytes;
- the library premultiplies alpha into `WL_SHM_FORMAT_ARGB8888`;
- `setCursorImage(state, image)` configures an image for one `General.Cursor` state; it is application-global per state (last writer wins);
- `setCursor(state)` prefers that state's image when present;
- `clearCursorImage(state)` removes it and restores the system shape for all windows;
- the library only creates the `wl_shm` surface and calls `wl_pointer.set_cursor`; no built-in move/file pattern;
- no custom image means no cursor change.

New events:

```zig
drag_enter: { window_id, x, y, mimes: []const []const u8 };
drag_motion: { window_id, x, y };
drag_leave: { window_id };
file_drop: { window_id, x, y, uris: []const u8 };
```

- `drag_enter.mimes` is borrowed until the next drag or backend teardown;
- `file_drop.uris` is the raw `text/uri-list`, borrowed until the next drop or teardown;
- data is read only on drop, never during enter/motion;
- only URIs are transferred; the backend never opens files;
- each URI line may contain CRLF and `#` comments;
- copy semantics are implemented; move/ask are future enhancements.


Additional rules:

- After a successful `init`, `uninit` must tolerate partially created resources.
- `pollEvent` is single-event only; no batching, blocking wait or callbacks.
- No `waitEvent` / `pollEvents` / event callbacks / separate UserEvent.
- Events carry only a `window_id`; validity is checked by the application via
  `App.getWindowById()`, where `null` means destroyed. The backend does not
  filter stale events.
- `window_should_close` is only a request; the backend must not hide/destroy
  the window and must not emit `window_destroyed` (removed). The application
  calls `Window.destroy()`.

---

## 4. Backend.Window

```zig
pub const Window = struct {
    pub fn getId(self: *Window) u32;
    pub fn uninit(self: *Window) void;
    pub fn getNative(self: *Window) General.NativeWindow;

    pub fn setTitle(self: *Window, title: []const u8) !void;
    pub fn getTitle(self: *Window) []const u8; // borrowed until next set

    pub fn setMaxSize(self: *Window, max_size: ?General.Size) !void;
    pub fn setMinSize(self: *Window, min_size: ?General.Size) !void;
    pub fn setSize(self: *Window, size: General.Size) !void;
    pub fn getSize(self: *Window) General.Size;
    pub fn setPos(self: *Window, pos: General.Position) !void;
    pub fn getPos(self: *Window) ?General.Position;
    pub fn getFramebufferSize(self: *Window) General.Size;
    pub fn getDpiScale(self: *Window) f32;

    pub fn setResizable(self: *Window, resizable: bool) !void;
    pub fn setFullscreen(self: *Window, fullscreen: bool) !void;
    pub fn minimize(self: *Window) !void;
    pub fn maximize(self: *Window) !void;
    pub fn setFocus(self: *Window) !void;
    pub fn requestAttention(self: *Window) !void;

    pub fn setCursor(self: *Window, cursor: General.Cursor) !void;
    pub fn setCursorVisible(self: *Window, visible: bool) !void;
    pub fn setAspectRatio(self: *Window, ratio: ?General.Ratio) !void;

    pub fn setImeAllowed(self: *Window, allowed: bool) !void;
    pub fn setImeCursorArea(self: *Window, pos: General.Position, size: General.Size) !void;

    pub fn getInfo(self: *Window) General.WindowInfo;

    pub fn setIcon(self: *Window, rgba: []const u8, width: u32, height: u32) !void;
    pub fn setDecorated(self: *Window, decorated: bool) !void;
    pub fn setAlwaysOnTop(self: *Window, always_on_top: bool) !void;
    pub fn setOpacity(self: *Window, opacity: f32) !void;
    pub fn setVisible(self: *Window, visible: bool) !void;

    pub fn createVulkanSurface(
        self: *Window,
        instance: Vulkan.Instance,
        get_instance_proc_addr: Vulkan.GetInstanceProcAddr,
        allocator: ?*const Vulkan.AllocationCallbacks,
    ) !Vulkan.SurfaceKHR;
};
```

| API | Description |
|---|---|
| `getId` | Stable unique u32 window id assigned by the backend; events reference it. |
| `uninit` | Release the native window; the wrapper removes contexts and pointers. |
| `getNative` | Return `ndt`/`nwh` without a platform branch, for bgfx and similar. |
| `setTitle` / `getTitle` | The returned title is borrowed and valid until the next `setTitle`. |
| `setMaxSize` / `setMinSize` | `null` means unlimited; the backend stores and applies it. |
| `setSize` / `getSize` | Logical size; when the platform cannot resize programmatically, `setSize` may request/record and `getSize` returns the actual size. |
| `setPos` / `getPos` | Logical position; Wayland has no global position, so `getPos` returns `null` and `setPos` may be a no-op. |
| `getFramebufferSize` | Physical pixels; on HiDPI this is `getSize() * getDpiScale()`. |
| `getDpiScale` | Logical-to-physical scale; 1.0 without HiDPI. |
| `setResizable` | Store the resizable state; no-op/record when unsupported. |
| `setFullscreen` | Toggle fullscreen/windowed; return an error on failure. |
| `minimize` / `maximize` | Minimize/maximize; state must be reflected by `getInfo`. |
| `setFocus` | Request focus; the platform may ignore it (Wayland: compositor decides). |
| `requestAttention` | Request user attention; return `error.Unsupported` if unavailable. |
| `setCursor` | Set the cursor shape; return an error on failure. |
| `setCursorVisible` | Show/hide the cursor; `Unsupported` without a pointer, `WouldBlock` without a valid serial. |
| `setAspectRatio` | Aspect-ratio constraint; `null` clears; no-op/record when unsupported. |
| `setImeAllowed` / `setImeCursorArea` | Enable IME / set the candidate area; return an error or no-op per platform. |
| `getInfo` | Return a consistent snapshot; all getters should derive from it. |
| `setIcon` | RGBA8 icon; return `error.Unsupported` when unavailable. |
| `setDecorated` | Toggle decorations; Wayland uses xdg-decoration/CSD, other platforms their native API. |
| `setAlwaysOnTop` | Always-on-top; xdg-shell has no standard support, so `error.Unsupported` is allowed. |
| `setOpacity` | Whole-window opacity; failures are returned directly to the caller. |
| `setVisible` | Show/hide the window; return `error.Unsupported` when hiding is impossible. Wayland only delays the first map. |
| `createVulkanSurface` | Create `VkSurfaceKHR` via the caller's loader; succeeds once per window, later calls return `error.WindowHadVulkanSurface`. |

Notes:

- `Backend.Window` does **not** own `createContext`/`destroyContext`; GL contexts
  are created by `Backend.initContext` and managed by the upper `Window`.
- Every getter must reflect the real backend state, not just configuration
  defaults.
- Borrowed slices (title, `MonitorInfo.name`, `ContextInfo` strings) have their
  lifetime defined by the corresponding API comment.

---

## 5. Backend.Context

```zig
pub const Context = struct {
    pub fn getKind(self: *Context) General.GraphicsApi;
    pub fn getInfo(self: *Context) General.ContextInfo;
    pub fn getNative(self: *Context) *const NativeContext;

    pub fn uninit(self: *Context) void;
    pub fn makeCurrent(self: *Context) !void;
    pub fn clearCurrent(self: *Context) !void;
    pub fn getProcAddress(self: *Context, name: [*:0]const u8) ?General.ProcAddr;
    pub fn swapBuffers(self: *Context) !void;
    pub fn setSwapInterval(self: *Context, interval: i32) !void;
};
```

| API | Description |
|---|---|
| `getKind` | Return `.opengl` or `.opengles`; Vulkan is not a Context. |
| `getInfo` | Version/profile/vendor/renderer/creator cached at creation; strings are owned by the context. |
| `getNative` | Return the platform `NativeContext` (EGL/WGL/CGL handles) for bgfx/ImGui. |
| `uninit` | Release the context; the upper `Context.uninit` unbinds the thread first. |
| `makeCurrent` / `clearCurrent` | Bind/unbind the context on the current thread; errors are propagated. |
| `getProcAddress` | Pure forwarding to the backend loader (EGL/WGL/CGL); no fallback. |
| `swapBuffers` | Present the frame; Vulkan does not use Context. |
| `setSwapInterval` | Vertical sync; return `error.Unsupported` when unavailable. |

**share**: `Backend.initContext(..., share: ?*Context)` receives an existing
context on the same backend/display. The backend uses the native sharing
mechanism (EGL/WGL/CGL); a different display/backend returns
`error.IncompatibleShareContext`. The upper layer only passes GL/GLES contexts.

---

## 6. Ownership, errors and threading

- **Allocator**: All heap allocations use the provided `std.mem.Allocator`; no
  global allocator.
- **Slices**: `getTitle`, `MonitorInfo.name`, `ContextInfo` strings are
  borrowed; arrays returned by `getMonitors`/`getClipboardMimeTypes`/
  `getClipboardData`/`getClipboardText` are
  caller-owned.
- **Events**: `pushEvent` does not copy `TextInput.text`; the producer keeps it
  valid until polled. Thread-safety of `pushEvent` is backend-defined;
  otherwise main thread only.
- **Errors**: Unsupported features return `error.Unsupported`; upper-layer
  gates use `error.UnsupportedApi`; other agreed names:
  `WindowHadContext`, `WindowHadVulkanSurface`, `IncompatibleShareContext`,
  `BackendUnavailable`, `InvalidRatio`, `NotCurrent`. `WouldBlock` means a
  missing pointer serial or pending async clipboard data (documented per API).
- **No panics for normal unsupported paths**: Do not panic for “platform
  unsupported”; only contract violations (null pointers, double init, ...) may
  panic/unreachable. Unimplemented backends are rejected by `build.zig`.
- **Diagnostics**: Backends use `config.reporter.reportError/reportInfo` for
  diagnostics that cannot be returned. Subsystems holding a `Sink` call
  `sink.report(err)`; those holding `*Backend` call `backend.reportError(err)`.
  Upper-layer setters return errors directly instead of routing them to a
  reporter.
- **Thread safety**: `Backend`/`Window`/`Context` are not thread-safe by
  default; callers must synchronize. The “current context” state is tracked by
  a `threadlocal` in the upper layer.

---

## 7. Build-time selection

- `build.zig`'s `-Dbackend=auto|null|wayland|x11|both|windows|macos` selects the
  backend; `auto` is resolved and validated by `build.zig` from the target OS.
- `src/Backend.zig` only dispatches at compile time: `Kind =
  General.BackendKind`; `effective` equals `kind`. Unimplemented selections are
  rejected by `build.zig`, with `error.BackendUnavailable` as a runtime guard in
  `App.init`.
- `src/backend_selected.zig` is generated by `build.zig` (gitignored) and
  contains exactly one `@import`. A static comptime switch is not equivalent:
  Zig still resolves imports in unselected arms, which would make null-only
  builds depend on generated Wayland headers. Parallel builds with different
  `-Dbackend` values share this file and must be serialized. Selector and
  protocol files are written atomically (temp + rename), and `Backend.zig`
  checks the selector's `name` against `-Dbackend` to fail clearly if a
  concurrent build overwrote it.
- `src/root.zig` exports `Backend`; users can name `Backend.NativeContext` and
  query platform/context creator via `App.getBackendInfo()`.

---

## 8. Contract test

```bash
zig build test -Dbackend=null
```

`test/api_test.zig`:

- references every public API at compile time, forcing analysis of the upper
  wrappers;
- calls `App.init` / `createWindow` / `createContext` and checks backend method
  signatures;
- with the null backend, asserts platform-independent behavior (event queue,
  window destruction, API gates, ratio validation);
- passes no mocks and asserts no backend-specific platform behavior. Without a
  compositor the Wayland suite skips most cases silently.
