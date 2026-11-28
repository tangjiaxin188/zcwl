# 后端接口契约（中文）

> 英文版：[`backend_en.md`](backend_en.md)

**状态**：本文档描述平台无关层已经依赖的完整后端契约。已实现：
`src/linux/wayland/backend.zig`、`src/null/backend.zig`。未实现的选项
（x11/both/windows/macos）会在 `build.zig` 编译期被拒绝，不再静默回退到 null。
真实后端必须实现本契约；`Backend.zig` 有编译期方法存在性检查，
`test/api_test.zig` 检查公开 API 与行为。

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
- 共享叶子模块只有 `General.zig`、`Config.zig`、`Event.zig`、`Vulkan.zig`、`EventQueue.zig`。
- `Backend.zig` 通过 `backend_selected.zig` 编译期 re-export 一个后端的
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
`"zcwl-app"`）和 `reporter: General.Reporter`（默认静默）。Wayland 后端用
application_id 调用 `xdg_toplevel.set_app_id`，并通过 `config.reporter` 上报初始化信息与
异步诊断；后端不得使用全局 reporter 变量。`WindowConfig` / `ContextConfig` 是具体的创建参数。

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
    pub fn getClipboardText(self: *Backend, allocator: std.mem.Allocator) !?[]u8;
    pub fn setClipboardData(self: *Backend, mime: []const u8, data: []const u8) !void;
    pub fn setClipboardItems(self: *Backend, items: []const General.ClipboardItem) !void;
    pub fn getClipboardMimeTypes(self: *Backend, allocator: std.mem.Allocator) !?[][]u8;
    pub fn getClipboardData(self: *Backend, mime: []const u8, allocator: std.mem.Allocator) !?[]u8;
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
| `setClipboardText` | 设置 UTF-8 文本剪贴板；后端选择标准文本 MIME。未初始化返回 `error.Uninitialized`。 |
| `getClipboardText` | 返回调用方拥有的 UTF-8 文本；空剪贴板/无文本表示返回 `null`。 |
| `setClipboardData` | 设置一个 MIME + 字节；后端复制数据。未初始化返回 `error.Uninitialized`。 |
| `setClipboardItems` | 一次设置多个 MIME 表示；未初始化返回 `error.Uninitialized`。 |
| `getClipboardMimeTypes` | 返回调用方拥有的 MIME 列表；空剪贴板返回 `null`，未初始化返回 `error.Uninitialized`。 |
| `getClipboardData` | 返回指定 MIME 的调用方字节；空剪贴板返回 `null`，未初始化返回 `error.Uninitialized`，异步未完成返回 `error.WouldBlock`，未提供该 MIME 返回 `error.Unsupported`。 |

剪贴板规则：

- MIME 与数据是原始字节透传；后端不解释图片、文件或 HTML 格式。
- `text/plain;charset=utf-8`、`text/uri-list` 等只是 MIME 字符串；文件列表由调用方解析。
- `setClipboardData` / `setClipboardItems` 必须复制 `mime` 和 `data`，不能在调用返回后继续借用。
- 剪贴板为空返回 `null`；后端没有 clipboard 能力返回 `error.Uninitialized`；不要把“空”错误地报告成 `Unsupported`。
- 读取可以是异步的：已有缓存返回值；等待传输返回 `error.WouldBlock`；MIME 不存在返回 `error.Unsupported`。
- `getClipboardText` 是文本便捷接口，底层仍使用同一 MIME/数据规则。

### 文件拖拽 / Drag and Drop

`Window` 新增：

```zig
pub fn startDragFiles(self: *Window, paths: []const []const u8) !void;
pub fn setCursorImage(self: *Window, state: General.Cursor, image: Config.CursorImage) !void;
pub fn clearCursorImage(self: *Window, state: General.Cursor) !void;
```

- `paths` 必须是绝对路径或 `file://` URI；
- 后端生成 `text/uri-list`，并提供 `wl_data_source`；
- 使用最近 pointer serial 发起 `start_drag`；没有有效 serial 返回 `error.WouldBlock`；
- 无 DnD 支持的后端返回 `error.Unsupported`；
- 第一版不创建拖拽图标，`icon_surface = null`。

自定义鼠标图案规则：

- `Config.CursorImage` 的 `pixels` 是行优先、直通 alpha 的 RGBA8，长度严格等于 `width * height * 4`；
- 库负责预乘 alpha 并写入 `WL_SHM_FORMAT_ARGB8888`；
- `setCursorImage(state, image)` 为指定 `General.Cursor` 状态配置图案，按键状态全局生效（最后设置者覆盖）；
- 之后 `setCursor(state)` 时优先使用该状态的图案；
- `clearCursorImage(state)` 删除图案并恢复系统 shape，影响所有窗口；
- 库只负责创建 `wl_shm` surface 并调用 `wl_pointer.set_cursor`，不内置 move/文件图案；
- 没有自定义图案时不会改变 cursor。

新增事件：

```zig
drag_enter: { window_id, x, y, mimes: []const []const u8 };
drag_motion: { window_id, x, y };
drag_leave: { window_id };
file_drop: { window_id, x, y, uris: []const u8 };
```

- `drag_enter.mimes` 借用保存，直到下一次 drag 或 backend teardown；
- `file_drop.uris` 是 `text/uri-list` 原始内容，借用保存到下一次 drop 或 backend teardown；
- drop 只在用户松手后读取，enter/motion 阶段不读取文件内容；
- 文件拖拽只传 URI 列表，后端不打开文件、不读取文件内容；
- `text/uri-list` 每行一个 URI，允许 `#` 注释和 `\r\n`；
- 拖拽数据采用 copy 语义；move/ask 作为后续增强。


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
| `setCursorVisible` | 显示/隐藏光标；无 pointer 返回 `Unsupported`，无有效 serial 返回 `WouldBlock`。 |
| `setAspectRatio` | 宽高比限制；`null` 清除；不支持时 no-op/记录。 |
| `setImeAllowed` / `setImeCursorArea` | 启用 IME / 设置候选框区域；不支持返回错误或 no-op（按平台）。 |
| `getInfo` | 返回一致的当前状态快照；所有 getter 应从这里取值。 |
| `setIcon` | RGBA8 图标；不支持返回 `error.Unsupported`。 |
| `setDecorated` | 装饰开关；Wayland 可用 xdg-decoration/CSD，其他平台对应 API。 |
| `setAlwaysOnTop` | 置顶；Wayland xdg-shell 无标准实现，可返回 `error.Unsupported`。 |
| `setOpacity` | 整窗不透明度；失败直接返回错误，由上层决定是否忽略。 |
| `setVisible` | 显示窗口；`false` 表示隐藏，无法隐藏的后端返回 `error.Unsupported`。Wayland 只延迟首次映射。 |
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
  数组（`getMonitors`、`getClipboardMimeTypes`、`getClipboardData`、`getClipboardText`）由调用方释放。
- **事件**：`pushEvent` 不复制 `TextInput.text`；生产者必须保证切片在下一次 poll
  前有效。`pushEvent` 的线程安全由后端文档声明；不保证时仅主线程调用。
- **错误**：不支持的功能返回 `error.Unsupported`；上层已拦截的路径返回
  `error.UnsupportedApi`；其他约定错误名：
  `WindowHadContext`、`WindowHadVulkanSurface`、`IncompatibleShareContext`、
  `BackendUnavailable`、`InvalidRatio`、`NotCurrent`。
  `WouldBlock` 专指缺少 pointer serial 或剪贴板异步数据尚未就绪（接口文档注明具体含义）。
- **不要为“平台不支持” panic**：只有违反契约（空指针、重复初始化等）才可
  `panic`/`unreachable`。未实现的后端由 `build.zig` 在编译期拒绝。
- **诊断**：后端通过 `config.reporter.reportError/reportInfo` 上报无法返回的诊断；
  持有 `Sink` 的子系统用 `sink.report(err)`，持有 `*Backend` 的用 `backend.reportError(err)`。
  上层 setter 不再捕获错误写 reporter，而是直接把错误返回给调用方。
- **线程安全**：`Backend`/`Window`/`Context` 默认不是线程安全的；需要跨线程
  使用时由用户同步。Context 的“当前上下文”状态由上层 `threadlocal` 维护。

---

## 7. 构建期选择

- `build.zig` 的 `-Dbackend=auto|null|wayland|x11|both|windows|macos` 选择后端；
  `auto` 由 `build.zig` 根据 target OS 解析并校验。
- `src/Backend.zig` 只做编译期 dispatch：`Kind = General.BackendKind`，
  `effective` 与 `kind` 一致；未实现的选项在 `build.zig` 编译期报错，
  `App.init` 还有 `error.BackendUnavailable` 运行时兜底。
- `src/backend_selected.zig` 由 `build.zig` 生成（gitignored），只包含选中后端的
  一条 `@import`，未选中的后端不会被解析或分析。生成是必要的：静态 comptime switch
  仍会让 Zig 解析未选中分支的 import 路径，导致 null-only 构建依赖 Wayland 生成文件。
  注意：不同 `-Dbackend` 的构建会覆盖同一个 selector 文件，跨进程并行构建需串行执行。
  selector 和协议生成物都用原子写（临时文件 + rename）；`Backend.zig` 会校验
  selector 的 `name` 与 `-Dbackend` 一致，被并发构建覆盖时给出明确编译错误。
- `src/root.zig` 导出 `Backend`，用户可命名 `Backend.NativeContext`，并通过
  `App.getBackendInfo()` 获取平台/上下文创建器。

---

## 8. 契约测试

```bash
zig build test -Dbackend=null
```

`test/api_test.zig` 会：

- 用 `comptime` 引用全部公开 API，强迫分析上层包装方法；
- 调用 `App.init` / `createWindow` / `createContext` 等入口，检查后端方法签名；
- 在 null 后端下断言若干平台无关行为（事件队列、窗口销毁、API 门禁、比例校验）；
- 不传 mock、不断言具体平台行为。无 compositor 时 Wayland 套件中的用例会静默跳过。
