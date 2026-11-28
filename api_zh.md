# zcwl API（中文）

版本：`v0.0.1-wl`

```zig
const zcwl = @import("zcwl");
```

约定：

- 所有堆分配都使用调用方传入的 `std.mem.Allocator`。
- 标为“调用方拥有”的返回值必须由调用方释放。
- 标为“借用”的切片只在文档说明的期间有效。
- 返回 `error.Unsupported` 表示当前 backend 不支持该功能。
- `error.WouldBlock` 专指操作需要有效的 pointer serial；剪贴板异步数据未就绪也使用该错误，文档会在对应接口注明具体含义。
- 所有窗口 setter 统一返回 `!void`，不支持的功能返回错误，由调用方决定忽略还是处理。
- 诊断回调按 `App` 实例配置（`Config.AppConfig.reporter`），不再有全局 `error_reporter` / `info_reporter`。
- 除 `Context` 的线程局部当前上下文语义外，`App`/`Window`/`Context` 默认不是线程安全的；跨线程访问需外部同步。若上下文已在线程 A `makeCurrent`，请在线程 A 先 `clearCurrent()` 或在该线程销毁，不能从线程 B 销毁。

---

## root

| 接口 | 说明 | 返回 |
|---|---|---|
| `getVersion() []const u8` | 库版本字符串 | 借用，静态 |
| `App` / `Window` / `Context` | 应用、窗口、GL/GLES 上下文 | 类型导出 |
| `Event` / `General` / `Config` / `Vulkan` | 事件、公共类型、配置、Vulkan WSI | 类型导出 |
| `Backend` | 底层 backend 调度层 | 高级接口 |

---

## App

`App` 拥有 backend、窗口注册表和事件队列。

| 签名 | 功能 | 参数 | 返回 |
|---|---|---|---|
| `init(alloc, config) !*App` | 创建应用 | `alloc` 分配器；`config` 为 `Config.AppConfig` | 成功返回 `*App`，失败返回错误 |
| `uninit(self) void` | 销毁 backend、所有仍存活窗口，并释放窗口结构体 | — | 之后所有 `Window`/`Context` 指针失效 |
| `createWindow(self, config) !*Window` | 创建窗口 | `Config.WindowConfig` | 成功返回 `*Window`，调用方用 `destroy()` 释放 |
| `getWindowById(self, id) ?*Window` | 按 id 查窗口 | 后端分配的窗口 id | 存在返回窗口，否则 `null` |
| `pollEvent(self, *Event.Core) bool` | 非阻塞取一个事件 | 输出参数 | 有事件 `true`，空队列写 `.none` 并返回 `false` |
| `pushEvent(self, Event.Core) void` | 推入事件 | 事件值 | 无；`TextInput.text` 不复制 |
| `getVulkanInstanceExtensions(self)` | 创建 Vulkan instance 所需扩展 | — | backend 拥有的 `[]const [*:0]const u8` |
| `getBackendInfo(self)` | requested/effective backend、平台、上下文创建器 | — | `General.BackendInfo` |
| `getMonitors(self, alloc) ![]MonitorInfo` | 获取监视器列表 | 调用方 allocator | 调用方拥有的数组 |
| `setClipboardText(self, text) !void` | 设置文本剪贴板 | UTF-8 文本 | 未初始化返回 `error.Uninitialized` |
| `getClipboardText(self, alloc) !?[]u8` | 读取文本剪贴板 | 调用方 allocator | 调用方拥有的文本；空/无文本返回 `null` |
| `getClipboardMimeTypes(self, alloc) !?[][]u8` | 获取全部 MIME 别名 | 调用方 allocator | 调用方拥有的字符串数组；空返回 `null` |
| `getClipboardData(self, mime, alloc) !?[]u8` | 读取一个 MIME | MIME 字符串、allocator | 调用方拥有的字节；空 `null`，未完成 `WouldBlock`，未提供 `Unsupported` |
| `setClipboardData(self, mime, data) !void` | 设置一个 MIME | MIME、字节 | 后端复制输入；未初始化 `Uninitialized` |
| `setClipboardItems(self, items) !void` | 一次设置多个 MIME | `[]const General.ClipboardItem` | 后端复制所有项 |

---

## Window

### 生命周期与上下文

| 签名 | 功能 | 参数 | 返回 |
|---|---|---|---|
| `destroy(self) void` | 销毁窗口、上下文并从 App 注销 | — | 指针失效；重复调用安全 |
| `uninit(self) void` | 与 `destroy` 相同的内部清理 | — | 高级接口；窗口结构体保留到 `App.uninit` |
| `init(app, backend_window, client_api) !*Window` | 内部构造包装对象 | 内部类型 | 高级接口 |
| `createContext(self, config, share) !*Context` | 创建 GL/GLES 上下文 | `config.api` 必须与窗口 `client_api` 一致；`share` 可为 `null` | 新上下文；API 不匹配或 Vulkan 窗口返回 `UnsupportedApi` |
| `destroyContext(self) void` | 销毁当前上下文 | — | 无 |
| `getContext(self) ?*Context` | 当前上下文 | — | 无则 `null` |
| `getNative(self) NativeWindow` | 原生 WSI 句柄 | — | `ndt`/`nwh`，库不拥有 |
| `getClientApi(self) GraphicsApi` | 窗口预留的图形 API | — | `.opengl` / `.opengles` / `.vulkan` |
| `eq(self, other) bool` | 比较同一 `App` 内的窗口 | 另一个窗口 | 相等 `true`；跨 `App` 永远 `false` |
| `getId(self) u32` | 后端窗口 id | — | id |

**所有权约定**：`Window` 结构体由 `App` 拥有，`destroy()`/`uninit()` 只释放后端资源和上下文，结构体本身在 `App.uninit()` 时统一释放。因此重复 `destroy()` 是安全的，但销毁后不要再调用其他窗口方法。`App.uninit()` 之后不得再访问任何窗口/上下文指针。

### 尺寸、位置与状态

所有 setter 统一返回 `!void`：平台不支持用 `error.Unsupported` 表示，被调用方用 `catch` 决定如何处理。

| 签名 | 功能 | 参数 | 返回 |
|---|---|---|---|
| `getInfo(self) WindowInfo` | 查询窗口状态 | — | `General.WindowInfo` |
| `setTitle(self, title) !void` | 设置标题 | UTF-8 标题 | 可能返回错误 |
| `getTitle(self) []const u8` | 获取标题 | — | 借用，直到下一次 `setTitle` |
| `setSize(self, size) !void` | 请求逻辑尺寸 | `General.Size` | 宽/高为 0 或超过 `i32` 返回 `InvalidSize`；平台可能忽略/调整 |
| `getSize(self) Size` | 逻辑客户区尺寸 | — | 逻辑尺寸 |
| `getFramebufferSize(self) Size` | 物理 framebuffer 尺寸 | — | 用于 `glViewport` |
| `getDpiScale(self) f32` | 逻辑到物理缩放 | — | 比例 |
| `setPos(self, pos) !void` | 请求窗口位置 | `General.Position` | 无全局位置的平台 no-op |
| `getPos(self) ?Position` | 窗口位置 | — | 无全局位置返回 `null` |
| `setMinSize(self, ?Size) !void` | 最小尺寸，`null` 取消 | `?General.Size` | 宽高必须非零且不超过 `i32`；超过当前最大值返回 `InvalidSizeRange` |
| `setMaxSize(self, ?Size) !void` | 最大尺寸，`null` 取消 | `?General.Size` | 宽高必须非零且不超过 `i32`；小于当前最小值返回 `InvalidSizeRange` |
| `setResizable(self, bool) !void` | 是否可调整大小 | `bool` | 可能返回错误 |
| `setFullscreen(self, bool) !void` | 切换全屏 | `bool` | 可能返回错误 |
| `minimize(self) !void` / `maximize(self) !void` | 最小化/最大化 | — | 可能返回错误 |
| `setFocus(self) !void` | 请求焦点 | — | compositor/WM 可忽略 |
| `requestAttention(self) !void` | 请求用户注意 | — | 不支持返回 `Unsupported` |

### 外观

| 签名 | 功能 | 参数 | 返回 |
|---|---|---|---|
| `setIcon(self, rgba, width, height) !void` | 设置窗口图标 | RGBA8 像素、宽高 | 宽高为 0 返回 `InvalidSize`；`rgba.len != width*height*4` 返回 `InvalidArgument`；不支持返回 `Unsupported` |
| `setDecorated(self, bool) !void` | 服务端/客户端装饰 | `bool` | 可能返回错误 |
| `setAlwaysOnTop(self, bool) !void` | 置顶 | `bool` | 不支持返回 `Unsupported` |
| `setOpacity(self, opacity) !void` | 整窗透明度 | `f32` | 非有限值返回 `InvalidOpacity`；有限值 clamp 到 `[0,1]`；不支持返回 `Unsupported` |
| `setVisible(self, visible) !void` | 显示窗口 / 延迟首次映射 | `bool` | Wayland 无法取消映射已映射窗口，`false` 返回 `Unsupported` |
| `setAspectRatio(self, ?Ratio) !void` | 宽高比约束 | `?General.Ratio` | 分子或分母为 0 返回 `InvalidRatio`；不支持的平台忽略 |
| `isFullscreen` / `isMaximized` / `isMinimized` / `isFocused` / `isResizable` / `isDecorated` / `isAlwaysOnTop` | 状态查询 | — | `bool` |
| `getOpacity(self) f32` | 当前透明度 | — | `f32` |

### 鼠标与 IME

| 签名 | 功能 | 参数 | 返回 |
|---|---|---|---|
| `setCursor(self, state) !void` | 选择当前鼠标状态 | `General.Cursor` | 不支持/无 serial 返回错误 |
| `setCursorImage(self, state, image) !void` | 给指定状态设置自定义图标 | `General.Cursor`、`Config.CursorImage` | 按状态在整个应用内生效（最后设置者覆盖）；非法图像返回 `InvalidSize`/`InvalidArgument` |
| `clearCursorImage(self, state) !void` | 删除状态图标并恢复系统 shape | `General.Cursor` | 影响整个应用；可能返回错误 |
| `setCursorVisible(self, visible) !void` | 显示/隐藏光标 | `bool` | 无 pointer 返回 `Unsupported`，无有效 serial 返回 `WouldBlock` |
| `setImeAllowed(self, allowed) !void` | 启用/禁用本窗口 IME | `bool` | 窗口获得键盘焦点时生效；不支持返回 `Unsupported` |
| `setImeCursorArea(self, pos, size) !void` | 设置 IME 候选区域 | 逻辑坐标/尺寸 | 尺寸超过 `i32` 返回 `InvalidSize`，0 表示空区域 |

### 文件拖拽

| 签名 | 功能 | 参数 | 返回 |
|---|---|---|---|
| `startDragFiles(self, paths) !void` | 发起文件拖拽 | 绝对路径或 `file://` 的数组 | 空数组 `InvalidArgument`；无有效 pointer serial `WouldBlock`；不支持 `Unsupported` |

对应事件：`drag_enter`、`drag_motion`、`drag_leave`、`file_drop`。
---

## Context

`Context` 是 GL/GLES 上下文，不包装 GL 函数。

**所有权约定**：`Context` 归创建它的 `Window` 所有。优先使用
`Window.destroyContext()` 或 `Window.destroy()`。直接调用 `Context.uninit()` 会先清空
`Window.context`，不会留下悬空指针；但不要重复调用，之后也不得再访问该 `Context` 指针。

| 签名 | 功能 | 参数 | 返回 |
|---|---|---|---|
| `init(alloc, backend_context, reporter, backend) !*Context` | 内部构造上下文包装 | 内部类型 | 高级接口 |
| `getKind(self) GraphicsApi` | 上下文 API | — | `.opengl` / `.opengles` |
| `getInfo(self) ContextInfo` | vendor/renderer/version/GLSL 等 | — | 字符串由 Context 拥有 |
| `getNative(self)` | 原生 EGL/WGL/CGL 上下文 | — | Context 拥有 |
| `makeCurrent(self) !void` | 绑定到当前线程 | — | 成功/错误 |
| `clearCurrent(self) !void` | 解绑当前线程的该上下文 | — | 不是当前上下文返回 `NotCurrent`；不能解绑其他线程的绑定 |
| `getCurrent() ?*Context` | 当前线程上下文 | — | 无则 `null` |
| `getProcAddress(self, name) ?ProcAddr` | 查询 GL 函数 | C 字符串函数名 | 失败 `null` |
| `swapBuffers(self) !void` | 提交当前帧 | — | 成功/错误 |
| `setSwapInterval(self, interval) !void` | 垂直同步间隔 | `i32` | 成功/错误 |
| `uninit(self) void` | 内部销毁上下文并清空 `Window.context` | — | 指针随即失效；见上方所有权约定 |

---

## Event

`Event.Core` 是 tagged union。所有 slice 默认是借用，除非另行说明。

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

### 事件字段

| 类型 | 字段 | 说明 |
|---|---|---|
| `WindowRef` | `window_id` | 窗口 id |
| `WindowResized` | `window_id,width,height` | 逻辑尺寸或 configure 尺寸 |
| `WindowMoved` | `window_id,x,y` | 平台支持全局位置时有效 |
| `WindowScaleChanged` | `window_id,scale` | 逻辑到物理缩放变化 |
| `KeyDown` | `window_id,key,mods,repeat` | `repeat=false` 首次按下，`true` 长按重复 |
| `KeyUp` | `window_id,key,mods` | 松开 |
| `TextInput` | `window_id,text` | UTF-8，借用；超出事件生命周期需复制 |
| `MouseMoved` | `window_id,x,y,mods` | 逻辑坐标 |
| `MouseButtonDown` | `window_id,button,mods,click_count` | `button` 为 `MouseButton` |
| `MouseButtonUp` | `window_id,button,mods` | — |
| `MouseScrolled` | `window_id,dx,dy,mods` | 滚动增量 |
| `PenState` | `window_id,pen_id,x,y,pressure,tilt_x,tilt_y,rotation,eraser` | 坐标/角度均为 `f32`，与鼠标事件一致；压感 0..1，角度为度 |
| `PenLeft` | `window_id,pen_id` | 离开 |
| `PenButton` | `window_id,pen_id,button,x,y,pressure,tilt_x,tilt_y,rotation,eraser` | 笔按键 |
| `DragEnter` | `window_id,x,y,mimes` | MIME 列表借用，直到下一次 drag/teardown |
| `DragMotion` | `window_id,x,y` | 拖拽移动 |
| `DragLeave` | `window_id` | 离开 |
| `FileDrop` | `window_id,x,y,uris` | 原始 `text/uri-list`，借用到下一次 drop/teardown |
| `CustomType` | `window_id,ev_type,act,act_2` | 用户事件；`act`/`act_2` 为带标签的 `CustomValue`（`uint`/`int`/`float`/`boolean`） |

`Mods` 字段：`shift`、`control`、`alt`、`super`、`caps_lock`、`num_lock`。

`MouseButton`：`left`、`right`、`middle`、`back`、`forward`、`unknown`。

---


## General

### 基础类型

| 类型 | 字段/值 | 说明 |
|---|---|---|
| `Size` | `w,h: u32` | 逻辑或物理尺寸 |
| `Position` | `x,y: i32` | 屏幕位置 |
| `Vector2` | `x,y: f32` | 浮点坐标 |
| `Ratio` | `numerator,denominator: u32` | 宽高比 |
| `NativeWindow` | `ndt,nwh: ?*anyopaque` | 原生 display/window 句柄 |
| `ProcAddr` | `*const fn() callconv(.c) void` | GL 函数指针 |

### `Cursor`

| 值 | 语义 |
|---|---|
| `arrow` | 默认指针 |
| `ibeam` | 文本输入 |
| `crosshair` | 十字 |
| `pointing_hand` | 可点击 |
| `resize_ew/ns/nwse/nesw/all` | 调整大小 |
| `not_allowed` | 禁止 |
| `wait` / `progress` | 忙碌 |
| `help` | 帮助 |
| `move` | 移动 |
| `copy` | 复制 |
| `no_drop` | 禁止放置 |
| `grab` | 可抓取 |
| `grabbing` | 正在抓取/拖拽 |

### 其他枚举/结构

| 类型 | 说明 |
|---|---|
| `GraphicsApi` | `.opengl`、`.opengles`、`.vulkan` |
| `BackendKind` | `.wayland`、`.x11`、`.both`、`.null`、`.windows`、`.macos` |
| `Platform` | `.wayland`、`.x11`、`.win32`、`.cocoa`、`.null` |
| `ContextCreator` | `.egl`、`.wgl`、`.cgl`、`.none` |
| `GlProfile` | `.core`、`.compatibility`、`.es` |
| `ClipboardItem` | `mime: []const u8; data: []const u8` |
| `ContextInfo` | `kind,major,minor,profile,vendor,renderer,version,shading_language,creator` |
| `WindowInfo` | size/framebuffer/position/dpi/client_api/状态字段 |
| `MonitorInfo` | id/name/position/size/work_area/dpi_scale/refresh_hz |
| `BackendInfo` | requested/effective/platform/context_creator/os/arch |
| `SystemInfo` | os/arch/backend，供 info reporter 使用 |

### 错误/信息 reporter

回调按 `App` 实例配置，没有全局变量。两个回调都默认静默。

| 接口 | 说明 |
|---|---|
| `General.ErrorReporter` | `*const fn (anyerror) void` |
| `General.InfoReporter` | `*const fn (SystemInfo) void` |
| `General.Reporter` | `{ error_fn: ?ErrorReporter, info_fn: ?InfoReporter }`，按值复制进 `App` 与后端 |
| `Reporter.reportError(err)` / `reportInfo(info)` | 内部调用；未安装回调时为空操作 |
| `Config.AppConfig.reporter` | 用户设置 reporter 的入口 |

---

## Config

| 类型 | 字段 | 说明 |
|---|---|---|
| `AppConfig` | `application_id: []const u8 = ""`, `reporter: General.Reporter = .{}` | Wayland app_id / X11 WM_CLASS / Win32 AppUserModelID / macOS bundle id；诊断回调 |
| `WindowConfig` | `client_api`, `title`, `size`, `position`, `resizable`, `decorated`, `always_on_top`, `visible` | 窗口创建参数；`size` 宽高必须非零且不超过 `i32`；`client_api` 默认 `.opengl`，创建其他 API 的上下文返回 `UnsupportedApi` |
| `ContextConfig` | `api`, `major`, `minor`, `profile`, `debug` | GL/GLES 上下文参数 |
| `CursorImage` | `pixels: []const u8`, `width`, `height`, `hotspot_x`, `hotspot_y` | 行优先、直通 alpha 的 RGBA8，无行填充，长度必须严格等于 `width*height*4`；库负责预乘。宽/高/stride/总字节数须适配 `i32`，hotspot 必须在图像内 |

---

## Vulkan

库只提供 WSI 类型和 surface 创建；不拥有 Vulkan 对象。

| 类型 | 说明 |
|---|---|
| `Instance` | `*anyopaque`，VkInstance |
| `SurfaceKHR` | `u64`，VkSurfaceKHR 原始值 |
| `AllocationCallbacks` | `anyopaque`，VkAllocationCallbacks |
| `GetInstanceProcAddr` | `vkGetInstanceProcAddr` 兼容函数指针 |

| Window 接口 | 说明 | 返回 |
|---|---|---|
| `createVulkanSurface(instance, get_instance_proc_addr, allocator)` | 为 `.vulkan` 窗口创建 surface | `Vulkan.SurfaceKHR`；调用方拥有 |
| `getNative()` | 原生 WSI 句柄 | `General.NativeWindow` |
| `App.getVulkanInstanceExtensions()` | 创建 instance 所需扩展 | backend 拥有的切片 |

---

## Backend（高级）

一般用户使用 `App`/`Window`/`Context`；`Backend` 是编译期 backend 调度层。

| 接口 | 说明 |
|---|---|
| `Backend.kind` / `Backend.effective` | 请求/实际 backend |
| `Backend.Handle` / `Window` / `Context` / `NativeWindow` / `NativeContext` | backend 类型导出 |
| `init` / `uninit` | backend 生命周期 |
| `initWindow` / `initContext` | 创建底层窗口/上下文 |
| `pollEvent` / `pushEvent` | 事件泵 |
| `getVulkanInstanceExtensions` / `getInfo` / `getMonitors` | 查询 |
| `setClipboardText` / `getClipboardText` / `getClipboardMimeTypes` / `getClipboardData` / `setClipboardData` / `setClipboardItems` | 剪贴板后端实现 |

---

## 错误与所有权

| 情况 | 行为 |
|---|---|
| backend 不支持 | `error.Unsupported` |
| 请求的 backend 未实现（编译期/运行时兜底） | 编译期失败 / `error.BackendUnavailable` |
| 剪贴板未初始化/无能力 | `error.Uninitialized` |
| 剪贴板为空或无对应表示 | `null`（读取接口） |
| 剪贴板异步数据未完成 | `error.WouldBlock` |
| MIME 未提供 | `error.Unsupported` |
| 需要 pointer serial 但没有 | `error.WouldBlock` |
| Vulkan 窗口创建 GL 上下文，或 context API 与窗口 `client_api` 不一致 | `error.UnsupportedApi` |
| 一个窗口创建第二个上下文 | `error.WindowHadContext` |
| 一个窗口创建第二个 Vulkan surface | `error.WindowHadVulkanSurface` |
| `setAspectRatio` 分母为 0 | `error.InvalidRatio` |
| `Context.clearCurrent(self)` 不是当前线程绑定的上下文 | `error.NotCurrent` |
| share context 来自其他 backend/display | `error.IncompatibleShareContext` |

所有权：

- `getMonitors`、`getClipboardMimeTypes`、`getClipboardData`、`getClipboardText`：调用方拥有。
- `getTitle`、`ContextInfo` 字符串、`WindowInfo`、`MonitorInfo.name`：借用；`getTitle` 到下一次 `setTitle`，`MonitorInfo.name` 到对应输出移除或 `App.uninit`。
- `startDragFiles`、`setClipboardData`、`setClipboardItems`、`setCursorImage`：库复制或创建所需资源。
- `pushEvent` 不复制 `TextInput.text`。
