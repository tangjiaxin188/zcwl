# 后端接口契约（中文）

> 英文版：[`backend_en.md`](backend_en.md)

**状态**：本文档描述平台无关层已经依赖的完整后端契约。当前只有
`src/null/backend.zig` 实现，所有 `-Dbackend=...` 选择都会回退到 null。真实后端必须
实现本契约；`test/api_test.zig` 会在编译期检查公开 API 及其调用的后端方法是否齐全。

---

## 1. 模块划分

不要把全部实现塞进一个文件。建议每个后端目录按职责拆分，`backend.zig` 只做入口与
组合，类型的方法放在各自类型所在的文件里。

```text
src/<os>/
├── backend.zig      # Backend 对象：初始化/销毁、事件泵、信息、监视器、剪贴板
├── window.zig       # Backend.Window 及其方法
├── context.zig      # Backend.Context + NativeContext（EGL/WGL/CGL 句柄）
├── event.zig        # 事件队列、Event.Core 构造辅助
├── input.zig        # 键盘/鼠标/触摸/数位笔/IME 状态 -> Event.Core
├── monitor.zig      # 监视器枚举与变化跟踪
├── clipboard.zig    # 全局剪贴板
├── cursor.zig       # 光标形状/生命周期
├── vulkan.zig       # Vulkan WSI：所需扩展 + surface 创建
├── loader.zig       # 可选原生库的 dlopen/dlsym 表
├── native.zig       # General.NativeWindow 的平台辅助（可选）
└── protocols/       # 生成的协议源码（Wayland、X11 扩展等）
```

规则：

- `backend.zig` 只做 re-export 与组合；类型方法放在 `window.zig` / `context.zig`。
- 平台代码不得 import `App.zig` / `Window.zig` / `Context.zig`（避免上层→后端→上层的
  反向依赖和循环）。
- 共享叶子模块只有 `General.zig`、`Config.zig`、`Event.zig`、`Vulkan.zig`。
- `Backend.zig` 通过编译期选择 re-export 一个后端的
  `Backend`/`Window`/`Context`/`NativeContext`/函数。

---

## 2. 共享类型

```zig
// General.zig — 上层与后端共享
pub const NativeWindow = struct {
    ndt: ?*anyopaque = null, // wl_display*、Display* 等
    nwh: ?*anyopaque = null, // wl_surface*、X11 Window、HWND 等
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
    name: []const u8, // 借用
    position: Position,
    size: Size,
    work_area: Size,
    dpi_scale: f32,
    refresh_hz: f32,
};

pub const BackendInfo = struct {
    requested: BackendKind = .null, // 由 Backend.zig 填写
    effective: BackendKind = .null, // 由 Backend.zig 填写
    platform: Platform,
    context_creator: ContextCreator,
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
};
```

`General.NativeWindow` 按值传递，包含 bgfx 风格渲染器需要的两个原生 C 句柄；平台不提供
时对应字段为 `null`。库不解释、不拥有这些值。

`Config.AppConfig` 提供 `application_id`（`[]const u8`，默认空，空值由后端回退为
`"zcwl-app"`），Wayland 后端用它调用 `xdg_toplevel.set_app_id`；`WindowConfig` /
`ContextConfig` 是具体的创建参数。

---

## 3. Backend 对象

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
    pub fn getClipboardText(self: *Backend, allocator: std.mem.Allocator) ![]u8;
};
```

| 接口 | 说明 |
|---|---|
| `init` | 建立平台连接/全局状态；失败返回错误，不得留下半初始化状态。 |
| `uninit` | 释放所有全局资源；不得再调用其他方法。 |
| `initWindow` | 创建原生窗口；返回值由上层包装，最终调用 `Window.uninit`。 |
| `initContext` | 在给定原生窗口上创建 GL/GLES 上下文；`share` 为同一 display 的已存在后端上下文。 |
| `pollEvent` | 有事件写入 `ev` 并返回 `true`；无事件写入 `.none` 并返回 `false`。 |
| `pushEvent` | 把事件放入后端队列；不得复制借用的 `TextInput.text`。 |
| `getVulkanInstanceExtensions` | 返回创建 VkInstance 时需要启用的平台扩展；切片由后端持有。 |
| `getInfo` | 填 `platform`/`context_creator`/`os`/`arch`；`requested`/`effective` 由 `Backend.zig` 覆盖。 |
| `getMonitors` | 返回调用方拥有的监视器数组；无监视器返回空数组。 |
| `setClipboardText` | 设置全局剪贴板文本；不支持时返回 `error.Unsupported`。 |
| `getClipboardText` | 返回调用方拥有的 UTF-8 文本；不支持时返回 `error.Unsupported`。 |

附加规则：

- `init` 成功后，`uninit` 必须能安全处理“部分资源创建失败”的状态。
- `pollEvent` 是单事件接口；不做批量、阻塞等待或回调。
- 不实现 `waitEvent` / `pollEvents` / 事件回调 / 独立 UserEvent。
- 事件只带 `window_id`；窗口是否有效由用户调用 `App.getWindowById()` 判断，
  返回 `null` 表示已销毁。后端不做过期事件过滤。
- `window_should_close` 只是请求，后端不得隐藏/销毁窗口，也不发送
  `window_destroyed`（该事件已移除）。用户调用 `Window.destroy()`。

---

## 4. Backend.Window

```zig
pub const Window = struct {
    pub fn getId(self: *Window) u32;
    pub fn uninit(self: *Window) void;
    pub fn getNative(self: *Window) General.NativeWindow;

    pub fn setTitle(self: *Window, title: []const u8) !void;
    pub fn getTitle(self: *Window) []const u8; // 借用，直到下一次 set

    pub fn setMaxSize(self: *Window, max_size: ?General.Size) void;
    pub fn setMinSize(self: *Window, min_size: ?General.Size) void;
    pub fn setSize(self: *Window, size: General.Size) void;
    pub fn getSize(self: *Window) General.Size;
    pub fn setPos(self: *Window, pos: General.Position) void;
    pub fn getPos(self: *Window) ?General.Position;
    pub fn getFramebufferSize(self: *Window) General.Size;
    pub fn getDpiScale(self: *Window) f32;

    pub fn setResizable(self: *Window, resizable: bool) void;
    pub fn setFullscreen(self: *Window, fullscreen: bool) !void;
    pub fn minimize(self: *Window) void;
    pub fn maximize(self: *Window) void;
    pub fn setFocus(self: *Window) void;
    pub fn requestAttention(self: *Window) !void;

    pub fn setCursor(self: *Window, cursor: General.Cursor) !void;
    pub fn setCursorVisible(self: *Window, visible: bool) void;
    pub fn setAspectRatio(self: *Window, ratio: ?General.Ratio) void;

    pub fn setImeAllowed(self: *Window, allowed: bool) !void;
    pub fn setImeCursorArea(self: *Window, pos: General.Position, size: General.Size) void;

    pub fn getInfo(self: *Window) General.WindowInfo;

    pub fn setIcon(self: *Window, rgba: []const u8, width: u32, height: u32) !void;
    pub fn setDecorated(self: *Window, decorated: bool) !void;
    pub fn setAlwaysOnTop(self: *Window, always_on_top: bool) !void;
    pub fn setOpacity(self: *Window, opacity: f32) !void;

    pub fn createVulkanSurface(
        self: *Window,
        instance: Vulkan.Instance,
        get_instance_proc_addr: Vulkan.GetInstanceProcAddr,
        allocator: ?*const Vulkan.AllocationCallbacks,
    ) !Vulkan.SurfaceKHR;
};
```

| 接口 | 说明 |
|---|---|
| `getId` | 稳定的 u32 窗口 id，由后端分配且唯一；事件用它引用窗口。 |
| `uninit` | 释放原生窗口；上层移除包装、Context 和指针。 |
| `getNative` | 返回 `ndt`/`nwh`；不需要平台分支，交给 bgfx 等使用。 |
| `setTitle` / `getTitle` | 标题可借用；返回值只在下一次 `setTitle` 前有效。 |
| `setMaxSize` / `setMinSize` | `null` = 无限制；后端保存并应用到原生窗口。 |
| `setSize` / `getSize` | 逻辑尺寸；平台无法程序化调整时，`setSize` 可请求/记录，`getSize` 返回实际值。 |
| `setPos` / `getPos` | 逻辑坐标；Wayland 无全局位置时 `getPos` 返回 `null`，`setPos` 可 no-op。 |
| `getFramebufferSize` | 物理像素；HiDPI 下 = `getSize() * getDpiScale()`。 |
| `getDpiScale` | 逻辑→物理比例；无 HiDPI 为 1.0。 |
| `setResizable` | 保存可调整状态；不支持时 no-op 或记录。 |
| `setFullscreen` | 切换全屏/窗口；失败返回错误。 |
| `minimize` / `maximize` | 最小化/最大化；状态反映到 `getInfo`。 |
| `setFocus` | 请求焦点；平台可忽略（Wayland 由合成器决定）。 |
| `requestAttention` | 请求用户注意；不支持返回 `error.Unsupported`。 |
| `setCursor` | 设置鼠标光标形状；失败返回错误。 |
| `setCursorVisible` | 显示/隐藏光标；不支持时 no-op/记录。 |
| `setAspectRatio` | 宽高比限制；`null` 清除；不支持时 no-op/记录。 |
| `setImeAllowed` / `setImeCursorArea` | 启用 IME / 设置候选框区域；不支持返回错误或 no-op（按平台）。 |
| `getInfo` | 返回一致的当前状态快照；所有 getter 应从这里取值。 |
| `setIcon` | RGBA8 图标；不支持返回 `error.Unsupported`。 |
| `setDecorated` | 装饰开关；Wayland 可用 xdg-decoration/CSD，其他平台对应 API。 |
| `setAlwaysOnTop` | 置顶；Wayland xdg-shell 无标准实现，可返回 `error.Unsupported`。 |
| `setOpacity` | 整窗不透明度；失败由上层 `General.error_reporter` 记录，不抛异常。 |
| `createVulkanSurface` | 用调用方 loader 创建 `VkSurfaceKHR`；一个窗口只能成功一次，第二次返回 `error.WindowHadVulkanSurface`。 |

注意：

- `Backend.Window` **不** 负责 `createContext`/`destroyContext`；GL context 由
  `Backend.initContext` 创建，由上层 `Window` 管理。
- 所有 getter 必须返回后端保存/查询到的真实状态，不能只返回配置默认值。
- 借用切片（title、MonitorInfo.name、ContextInfo 字符串）生命周期在各自接口注释中定义。

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

| 接口 | 说明 |
|---|---|
| `getKind` | 返回 `.opengl` 或 `.opengles`；Vulkan 不是 Context。 |
| `getInfo` | 创建时缓存的版本/profile/vendor/renderer/creator；字符串由 Context 持有。 |
| `getNative` | 返回平台 `NativeContext`（EGL/WGL/CGL 句柄），供 bgfx/ImGui 等使用。 |
| `uninit` | 释放上下文；上层 `Context.uninit` 会先解绑线程。 |
| `makeCurrent` / `clearCurrent` | 绑定/解绑当前线程的上下文；失败返回错误。 |
| `getProcAddress` | 纯转发后端 loader（EGL/WGL/CGL），不做 fallback。 |
| `swapBuffers` | 呈现当前帧；Vulkan 不使用 Context。 |
| `setSwapInterval` | 垂直同步；不支持返回 `error.Unsupported`。 |

**share**：`Backend.initContext(..., share: ?*Context)` 的 `share` 是同一 backend/display
上已存在的上下文。后端用 EGL/WGL/CGL 的共享机制创建新上下文；不同 display/backend
返回 `error.IncompatibleShareContext`。上层已保证只把 GL/GLES 上下文作为 `share`。

---

## 6. 所有权、错误与线程

- **分配器**：所有堆分配使用传入的 `std.mem.Allocator`；后端不得使用全局分配器。
- **切片**：`getTitle`、`MonitorInfo.name`、`ContextInfo` 字符串是借用；其余返回
  数组（`getMonitors`、`getClipboardText`）由调用方释放。
- **事件**：`pushEvent` 不复制 `TextInput.text`；生产者必须保证切片在下一次 poll
  前有效。`pushEvent` 的线程安全由后端文档声明；不保证时仅主线程调用。
- **错误**：不支持的功能返回 `error.Unsupported`；上层已拦截的路径返回
  `error.UnsupportedApi`；其他约定错误名：
  `WindowHadContext`、`WindowHadVulkanSurface`、`IncompatibleShareContext`。
- **不要为“平台不支持” panic**：只有违反契约（空指针、重复初始化等）才可
  `panic`/`unreachable`。
- **Opacity**：`Window.setOpacity` 的上层会捕获后端 `!void` 错误并交给
  `General.error_reporter`，因此后端返回错误即可，不要抛异常。
- **线程安全**：`Backend`/`Window`/`Context` 默认不是线程安全的；需要跨线程
  使用时由用户同步。Context 的“当前上下文”状态由上层 `threadlocal` 维护。

---

## 7. 构建期选择

- `build.zig` 的 `-Dbackend=auto|null|wayland|x11|both|windows|macos` 选择后端；
  `auto` 由 `build.zig` 根据 target OS 解析并校验。
- `src/Backend.zig` 只做编译期 dispatch：`Kind = General.BackendKind`，
  `effective` 表示实际链接的后端；未实现的选项回退到 null。
- `src/root.zig` 导出 `Backend`，用户可命名 `Backend.NativeContext`，并通过
  `App.getBackendInfo()` 获取平台/上下文创建器。

---

## 8. 契约测试

```bash
zig build test null
```

`test/api_test.zig` 会：

- 用 `comptime` 引用全部公开 API，强迫分析上层包装方法；
- 调用 `App.init` / `createWindow` / `createContext` 等入口，检查后端方法签名；
- 不传 mock、不断言平台行为。
