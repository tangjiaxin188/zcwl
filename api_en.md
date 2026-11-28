# zcwl API (English)

Version: `v0.0.1-wl`

```zig
const zcwl = @import("zcwl");
```

Conventions:

- All heap allocations use the caller-provided `std.mem.Allocator`.
- “Caller-owned” return values must be freed by the caller.
- “Borrowed” slices are valid only for the documented lifetime.
- `error.Unsupported`: the backend does not implement the feature.
- `error.WouldBlock`: a required pointer serial is unavailable, or an async
  clipboard transfer is still pending (the interface says which).
- All window setters return `!void`; unsupported features return an error and
  the caller decides whether to ignore it.
- Diagnostic callbacks are configured per `App` (`Config.AppConfig.reporter`);
  there are no global `error_reporter` / `info_reporter` variables.
- Apart from the thread-local current-context semantics of `Context`,
  `App`/`Window`/`Context` are not thread-safe; synchronize externally. A
  context made current on thread A must be cleared or destroyed on thread A.

---

## root

| API | Description | Return |
|---|---|---|
| `getVersion() []const u8` | Library version | Borrowed static string |
| `App`, `Window`, `Context` | App, window, GL/GLES context | Type exports |
| `Event`, `General`, `Config`, `Vulkan` | Events, common types, config, Vulkan WSI | Type exports |
| `Backend` | Low-level backend dispatcher | Advanced API |

---

## App

`App` owns the backend, window registry and event queue.

| Signature | Description | Parameters | Return |
|---|---|---|---|
| `init(alloc, config) !*App` | Create an app | Allocator; `Config.AppConfig` | New `*App` |
| `uninit(self) void` | Destroy backend and live windows, then free window structs | — | All `Window`/`Context` pointers become invalid |
| `createWindow(self, config) !*Window` | Create a window | `Config.WindowConfig` | `*Window`; destroy with `destroy()` |
| `getWindowById(self, id) ?*Window` | Look up a window | Window id | Window or `null` |
| `pollEvent(self, *Event.Core) bool` | Poll one event (non-blocking) | Output event | `true` if written; `.none`/`false` otherwise |
| `pushEvent(self, ev) void` | Push an event | `Event.Core` | —; does not copy `TextInput.text` |
| `getVulkanInstanceExtensions(self)` | Required Vulkan instance extensions | — | Backend-owned slice |
| `getBackendInfo(self)` | Requested/effective backend and platform | — | `General.BackendInfo` |
| `getMonitors(self, alloc) ![]MonitorInfo` | Query monitors | Allocator | Caller-owned array |
| `setClipboardText(self, text) !void` | Set text clipboard | UTF-8 text | `Uninitialized` when unsupported |
| `getClipboardText(self, alloc) !?[]u8` | Read text clipboard | Allocator | Caller-owned text, or `null` |
| `getClipboardMimeTypes(self, alloc) !?[][]u8` | Read all MIME aliases | Allocator | Caller-owned strings, or `null` |
| `getClipboardData(self, mime, alloc) !?[]u8` | Read one MIME representation | MIME, allocator | Caller-owned bytes; `null`/`WouldBlock`/`Unsupported` |
| `setClipboardData(self, mime, data) !void` | Set one MIME representation | MIME, bytes | Backend copies input |
| `setClipboardItems(self, items) !void` | Set multiple MIME representations | Slice of `ClipboardItem` | Backend copies input |

---

## Window

### Lifecycle and context

| Signature | Description | Parameters | Return |
|---|---|---|---|
| `destroy(self) void` | Destroy window/context and unregister from App | — | Pointer becomes invalid; repeated calls are safe |
| `uninit(self) void` | Same internal teardown as `destroy` | — | Advanced; struct retained until `App.uninit` |
| `init(app, backend_window, client_api) !*Window` | Internal constructor | Internal types | Advanced |
| `createContext(self, config, share) !*Context` | Create GL/GLES context | `config.api` must match the window's `client_api`; optional share context | Context; `UnsupportedApi` for Vulkan windows or an API mismatch |
| `destroyContext(self) void` | Destroy current context | — | — |
| `getContext(self) ?*Context` | Current context | — | Context or `null` |
| `getNative(self) NativeWindow` | Native WSI handles | — | `ndt`/`nwh`, not owned |
| `getClientApi(self) GraphicsApi` | Graphics API reserved by the window | — | `.opengl`/`.opengles`/`.vulkan` |
| `eq(self, other) bool` | Compare windows in the same `App` | Other window | `true` if equal; always `false` across Apps |
| `getId(self) u32` | Backend window id | — | id |

**Ownership**: the `App` owns the `Window` struct. `destroy()`/`uninit()` release backend resources and the context but keep the small struct until `App.uninit()`, so repeated teardown is safe. Do not call other methods after destruction, and never touch window/context pointers after `App.uninit()`.

### Size, position, state

All setters return `!void`; unsupported features return an error that the
caller may ignore with `catch`.

| Signature | Description | Parameters | Return |
|---|---|---|---|
| `getInfo(self) WindowInfo` | Window state | — | `General.WindowInfo` |
| `setTitle(self, title) !void` | Set title | UTF-8 title | May fail |
| `getTitle(self) []const u8` | Get title | — | Borrowed until next `setTitle` |
| `setSize(self, size) !void` | Request logical size | `General.Size` | `InvalidSize` for zero or `i32`-overflowing dimensions; platform may adjust/ignore |
| `getSize(self) Size` | Logical client size | — | Logical size |
| `getFramebufferSize(self) Size` | Physical framebuffer size | — | For `glViewport` |
| `getDpiScale(self) f32` | Logical-to-physical scale | — | Scale |
| `setPos(self, pos) !void` | Request position | `General.Position` | No-op without global positions |
| `getPos(self) ?Position` | Window position | — | `null` when unavailable |
| `setMinSize(self, ?Size) !void` | Minimum size; `null` clears | Optional size | Zero or `i32`-overflowing dimensions rejected; above the current maximum returns `InvalidSizeRange` |
| `setMaxSize(self, ?Size) !void` | Maximum size; `null` clears | Optional size | Zero or `i32`-overflowing dimensions rejected; below the current minimum returns `InvalidSizeRange` |
| `setResizable(self, bool) !void` | Toggle resizing | bool | May fail |
| `setFullscreen(self, bool) !void` | Toggle fullscreen | bool | May fail |
| `minimize(self) !void` / `maximize(self) !void` | Minimize/maximize | — | May fail |
| `setFocus(self) !void` | Request focus | — | Compositor/WM may ignore |
| `requestAttention(self) !void` | Request attention | — | `Unsupported` when unavailable |

### Appearance

| Signature | Description | Parameters | Return |
|---|---|---|---|
| `setIcon(self, rgba, width, height) !void` | Set window icon | RGBA8 pixels, dimensions | Zero dimensions return `InvalidSize`; length mismatch returns `InvalidArgument`; `Unsupported` when unavailable |
| `setDecorated(self, bool) !void` | Set decorations | bool | May fail |
| `setAlwaysOnTop(self, bool) !void` | Set always-on-top | bool | `Unsupported` when unavailable |
| `setOpacity(self, opacity) !void` | Whole-window opacity | `f32` | Non-finite returns `InvalidOpacity`; finite values clamp to `[0,1]`; `Unsupported` when unavailable |
| `setVisible(self, visible) !void` | Show window / delay first map | bool | Wayland cannot unmap a mapped toplevel: `false` returns `Unsupported` |
| `setAspectRatio(self, ?Ratio) !void` | Aspect-ratio constraint | Optional ratio | Zero numerator or denominator returns `InvalidRatio`; ignored when unsupported |
| `isFullscreen` / `isMaximized` / `isMinimized` / `isFocused` / `isResizable` / `isDecorated` / `isAlwaysOnTop` | State queries | — | `bool` |
| `getOpacity(self) f32` | Current opacity | — | `f32` |

### Cursor and IME

| Signature | Description | Parameters | Return |
|---|---|---|---|
| `setCursor(self, state) !void` | Select current cursor state | `General.Cursor` | Error when unsupported/no serial |
| `setCursorImage(self, state, image) !void` | Set an image for one cursor state | State and `Config.CursorImage` | Application-global per state (last writer wins); invalid input returns `InvalidSize`/`InvalidArgument` |
| `clearCursorImage(self, state) !void` | Remove a state image and restore system shape | State | Application-global; may fail |
| `setCursorVisible(self, visible) !void` | Show/hide cursor | bool | `Unsupported` without a pointer; `WouldBlock` without a valid serial |
| `setImeAllowed(self, allowed) !void` | Enable/disable IME for this window | bool | Applies when this window has keyboard focus; `Unsupported` when unavailable |
| `setImeCursorArea(self, pos, size) !void` | IME candidate area | Logical position/size | `InvalidSize` above `i32`; zero means an empty area |

### File drag and drop

| Signature | Description | Parameters | Return |
|---|---|---|---|
| `startDragFiles(self, paths) !void` | Start dragging files | Absolute paths or `file://` URIs | `InvalidArgument` for an empty list; `WouldBlock` without pointer serial; `Unsupported` when unavailable |

Events: `drag_enter`, `drag_motion`, `drag_leave`, `file_drop`.

---

## Context

`Context` is owned by the `Window` that created it. Prefer
`Window.destroyContext()` or `Window.destroy()`. Calling `Context.uninit()`
directly clears `Window.context` first, so it does not leave a dangling
pointer; do not call it twice and do not use the pointer afterwards.

| Signature | Description | Parameters | Return |
|---|---|---|---|
| `init(alloc, backend_context, reporter, backend) !*Context` | Internal constructor | Internal types | Advanced |
| `getKind(self) GraphicsApi` | Context API | — | `.opengl`/`.opengles` |
| `getInfo(self) ContextInfo` | Vendor/renderer/version/GLSL | — | Strings owned by Context |
| `getNative(self)` | Native EGL/WGL/CGL context | — | Owned by Context |
| `makeCurrent(self) !void` | Bind to current thread | — | May fail |
| `clearCurrent(self) !void` | Unbind this context on the calling thread | — | `NotCurrent` if not bound here; cannot unbind another thread |
| `getCurrent() ?*Context` | Current thread context | — | Context or `null` |
| `getProcAddress(self, name) ?ProcAddr` | Look up GL symbol | C string | `null` if absent |
| `swapBuffers(self) !void` | Present frame | — | May fail |
| `setSwapInterval(self, interval) !void` | VSync interval | `i32` | May fail |
| `uninit(self) void` | Internal teardown; also clears `Window.context` | — | Pointer becomes invalid; see ownership note above |


---

## Event

`Event.Core` is a tagged union. Slices are borrowed unless stated otherwise.

```zig
pub const Core = union(enum) {
    none,
    window_should_close: WindowRef,
    window_resized: WindowResized,
    window_moved: WindowMoved,
    window_scale_changed: WindowScaleChanged,
    window_focus_gained: WindowRef,
    window_focus_lost: WindowRef,
    window_minimized: WindowRef,
    window_maximized: WindowRef,
    window_restored: WindowRef,
    key_down: KeyDown,
    key_up: KeyUp,
    text_input: TextInput,
    mouse_entered: WindowRef,
    mouse_left: WindowRef,
    mouse_moved: MouseMoved,
    mouse_button_down: MouseButtonDown,
    mouse_button_up: MouseButtonUp,
    mouse_scrolled: MouseScrolled,
    pen_entered: PenState,
    pen_left: PenLeft,
    pen_down: PenState,
    pen_up: PenState,
    pen_moved: PenState,
    pen_button_down: PenButton,
    pen_button_up: PenButton,
    drag_enter: DragEnter,
    drag_motion: DragMotion,
    drag_leave: DragLeave,
    file_drop: FileDrop,
    custom: CustomType,
    unknown,
};
```

| Type | Fields | Description |
|---|---|---|
| `WindowRef` | `window_id` | Window id |
| `WindowResized` | `window_id,width,height` | Logical/configure size |
| `WindowMoved` | `window_id,x,y` | Only where global positions exist |
| `WindowScaleChanged` | `window_id,scale` | Logical-to-physical scale change |
| `KeyDown` | `window_id,key,mods,repeat` | `repeat=false` first press, `true` long-press repeat |
| `KeyUp` | `window_id,key,mods` | Release |
| `TextInput` | `window_id,text` | UTF-8, borrowed |
| `MouseMoved` | `window_id,x,y,mods` | Logical coordinates |
| `MouseButtonDown` | `window_id,button,mods,click_count` | `MouseButton` |
| `MouseButtonUp` | `window_id,button,mods` | — |
| `MouseScrolled` | `window_id,dx,dy,mods` | Scroll delta |
| `PenState` | `window_id,pen_id,x,y,pressure,tilt_x,tilt_y,rotation,eraser` | Coordinate/pressure/angle fields are `f32`, matching mouse events; ids are `u32`, button indices `u8`; pressure 0..1, angles in degrees |
| `PenLeft` | `window_id,pen_id` | Leave |
| `PenButton` | `window_id,pen_id,button,x,y,pressure,tilt_x,tilt_y,rotation,eraser` | Pen button |
| `DragEnter` | `window_id,x,y,mimes` | MIME list borrowed until next drag/teardown |
| `DragMotion` | `window_id,x,y` | Drag movement |
| `DragLeave` | `window_id` | Leave |
| `FileDrop` | `window_id,x,y,uris` | Raw `text/uri-list`, borrowed until next drop/teardown |
| `CustomType` | `window_id,ev_type,act,act_2` | User event; `act`/`act_2` are tagged `CustomValue` (`uint`/`int`/`float`/`boolean`) |

`Mods`: `shift`, `control`, `alt`, `super`, `caps_lock`, `num_lock`.

`MouseButton`: `left`, `right`, `middle`, `back`, `forward`, `unknown`.

---

## General

### Basic types

| Type | Fields/values | Description |
|---|---|---|
| `Size` | `w,h: u32` | Logical or physical size |
| `Position` | `x,y: i32` | Screen position |
| `Vector2` | `x,y: f32` | Floating-point coordinates |
| `Ratio` | `numerator,denominator: u32` | Aspect ratio |
| `NativeWindow` | `ndt,nwh: ?*anyopaque` | Native display/window handles |
| `ProcAddr` | `*const fn() callconv(.c) void` | GL function pointer |

### `Cursor`

| Value | Meaning |
|---|---|
| `arrow` | Default |
| `ibeam` | Text |
| `crosshair` | Crosshair |
| `pointing_hand` | Clickable |
| `resize_ew/ns/nwse/nesw/all` | Resize |
| `not_allowed` | Forbidden |
| `wait` / `progress` | Busy |
| `help` | Help |
| `move` | Move |
| `copy` | Copy |
| `no_drop` | Drop forbidden |
| `grab` | Grabbable |
| `grabbing` | Dragging/grabbing |

### Other enums/structs

| Type | Description |
|---|---|
| `GraphicsApi` | `.opengl`, `.opengles`, `.vulkan` |
| `BackendKind` | `.wayland`, `.x11`, `.both`, `.null`, `.windows`, `.macos` |
| `Platform` | `.wayland`, `.x11`, `.win32`, `.cocoa`, `.null` |
| `ContextCreator` | `.egl`, `.wgl`, `.cgl`, `.none` |
| `GlProfile` | `.core`, `.compatibility`, `.es` |
| `ClipboardItem` | `mime: []const u8; data: []const u8` |
| `ContextInfo` | `kind,major,minor,profile,vendor,renderer,version,shading_language,creator` |
| `WindowInfo` | size/framebuffer/position/dpi/client_api/state fields |
| `MonitorInfo` | id/name/position/size/work_area/dpi_scale/refresh_hz |
| `BackendInfo` | requested/effective/platform/context_creator/os/arch |
| `SystemInfo` | os/arch/backend for info reporter |

### Reporters

Callbacks are configured per `App` instance; there is no global mutable state.
Both sinks default to silent.

| API | Description |
|---|---|
| `General.ErrorReporter` | `*const fn (anyerror) void` |
| `General.InfoReporter` | `*const fn (SystemInfo) void` |
| `General.Reporter` | `{ error_fn: ?ErrorReporter, info_fn: ?InfoReporter }`, copied into `App` and backend |
| `Reporter.reportError(err)` / `reportInfo(info)` | Internal dispatch; no-op when unset |
| `Config.AppConfig.reporter` | Where the application installs its sinks |


---

## Config

| Type | Fields | Description |
|---|---|---|
| `AppConfig` | `application_id: []const u8 = ""`, `reporter: General.Reporter = .{}` | Wayland app_id / X11 WM_CLASS / Win32 AppUserModelID / macOS bundle id; diagnostic sinks |
| `WindowConfig` | `client_api`, `title`, `size`, `position`, `resizable`, `decorated`, `always_on_top`, `visible` | Window creation; `size` dimensions must be non-zero and fit `i32`; `client_api` defaults to `.opengl`, so creating a context for another API returns `UnsupportedApi` |
| `ContextConfig` | `api`, `major`, `minor`, `profile`, `debug` | GL/GLES context |
| `CursorImage` | `pixels: []const u8`, `width`, `height`, `hotspot_x`, `hotspot_y` | Row-major straight-alpha RGBA8, no padding, length exactly `width*height*4`; the library premultiplies. Dimensions/stride/total size must fit `i32`; hotspot must be inside the image |

---

## Vulkan

The library only provides WSI types and surface creation; it never owns Vulkan objects.

| Type | Description |
|---|---|
| `Instance` | `*anyopaque`, VkInstance |
| `SurfaceKHR` | `u64`, raw VkSurfaceKHR |
| `AllocationCallbacks` | `anyopaque`, VkAllocationCallbacks |
| `GetInstanceProcAddr` | Compatible vkGetInstanceProcAddr function pointer |

| Window API | Description | Return |
|---|---|---|
| `createVulkanSurface(instance, get_instance_proc_addr, allocator)` | Create a surface for a `.vulkan` window | `Vulkan.SurfaceKHR`; caller-owned |
| `getNative()` | Native WSI handles | `General.NativeWindow` |
| `App.getVulkanInstanceExtensions()` | Required instance extensions | Backend-owned slice |

---

## Backend (advanced)

Normal users use `App`/`Window`/`Context`; `Backend` is the compile-time backend dispatcher.

| API | Description |
|---|---|
| `Backend.kind` / `Backend.effective` | Requested/effective backend |
| `Backend.Handle` / `Window` / `Context` / `NativeWindow` / `NativeContext` | Backend type exports |
| `init` / `uninit` | Backend lifecycle |
| `initWindow` / `initContext` | Low-level creation |
| `pollEvent` / `pushEvent` | Event pump |
| `getVulkanInstanceExtensions` / `getInfo` / `getMonitors` | Queries |
| `setClipboardText` / `getClipboardText` / `getClipboardMimeTypes` / `getClipboardData` / `setClipboardData` / `setClipboardItems` | Clipboard backend |

---

## Errors and ownership

| Case | Behavior |
|---|---|
| Backend unsupported | `error.Unsupported` |
| Requested backend not implemented | Compile error, or `error.BackendUnavailable` from `App.init` |
| Clipboard unavailable | `error.Uninitialized` |
| Empty clipboard/no representation | `null` for getters |
| Clipboard async transfer pending | `error.WouldBlock` |
| MIME not offered | `error.Unsupported` |
| Pointer serial unavailable | `error.WouldBlock` |
| GL context on a Vulkan window, or context API not matching `client_api` | `error.UnsupportedApi` |
| Second context on one window | `error.WindowHadContext` |
| Second Vulkan surface | `error.WindowHadVulkanSurface` |
| Zero aspect-ratio denominator | `error.InvalidRatio` |
| `Context.clearCurrent(self)` on a context not bound on this thread | `error.NotCurrent` |
| Share context from another backend/display | `error.IncompatibleShareContext` |

Ownership:

- `getMonitors`, `getClipboardMimeTypes`, `getClipboardData`, `getClipboardText`: caller-owned.
- `getTitle`, `ContextInfo` strings, `WindowInfo`, `MonitorInfo.name`: borrowed; `getTitle` until the next `setTitle`, `MonitorInfo.name` until the output is removed or `App.uninit`.
- `startDragFiles`, `setClipboardData`, `setClipboardItems`, `setCursorImage`: library copies/creates resources.
- `pushEvent` does not copy `TextInput.text`.
- `Context` is owned by its `Window`; only call `Window.destroyContext()`/`destroy()` to destroy it.

