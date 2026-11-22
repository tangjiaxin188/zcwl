# Wayland Backend Plan / Wayland 后端设计

**状态**: 已实现基础功能（窗口/xdg-shell、EGL、输入、监视器、剪贴板、装饰、
cursor-shape、alpha-modifier、text-input-v3、Vulkan WSI）。后端接口契约见项目根目录
`backend_zh.md`（English: `backend_en.md`）。协议源码在构建时生成，不提交到仓库。

## 0. 范围 / Scope

- 平台：Linux Wayland；X11 是独立后端，不在本文范围。
- 图形上下文：**只用 EGL**（OpenGL / OpenGL ES），不实现 GLX。
- Vulkan：库只提供 WSI（`VK_KHR_surface` + `VK_KHR_wayland_surface`、
  `vkCreateWaylandSurfaceKHR`、required instance extensions），
  instance/device/swapchain 全部由用户持有。
- 透明窗口：默认支持逐像素 alpha（EGL config alpha ≥ 8 / ARGB buffer；
  Vulkan swapchain 由用户选择 alpha format + compositeAlpha）。
- 未实现的路径仍然回退 null 后端。
- 编译期选择：`-Dbackend=wayland`（Linux 默认 `auto` → wayland；`both` 待 X11 后端）。

The backend contract is in `backend_en.md` (Chinese: `backend_zh.md`); this
file only describes the Wayland specifics: module split, initialization,
protocol mapping, and protocol files.

---

## 1. 模块划分 / Module layout

不要把所有代码放到一个文件。建议：

```text
src/linux/
├── egl.zig           # Linux 通用 EGL dlopen 加载器（Wayland/X11 共用）
├── xkb.zig           # Linux 通用 xkbcommon 加载器 + keycode 映射（Wayland/X11 共用）
└── wayland/
    ├── backend.zig       # Backend 入口：init/uninit、全局状态、事件泵、info、monitors/clipboard 转发
    ├── display.zig       # wl_display / wl_registry / globals / roundtrip / fd / flush
    ├── event.zig         # 内部 Event.Core 队列、poll/dispatch、事件构造辅助
    ├── window.zig        # wl_surface + xdg_surface + xdg_toplevel：configure/ack、commit、全部 Window 方法
    ├── input.zig         # wl_seat / wl_pointer / wl_keyboard / wl_touch -> Event.Core；使用 ../xkb.zig
    ├── tablet.zig        # zwp_tablet_manager_v2 -> Event.Pen*（压感/倾斜/旋转/按键/橡皮擦）
    ├── monitor.zig       # wl_output：geometry/mode/scale/name/hotplug
    ├── cursor.zig        # cursor-shape-v1；set_cursor / hide
    ├── context.zig       # Backend.Context + NativeContext（EGLDisplay/Config/Context/Surface）
    ├── vulkan.zig        # required instance extensions + vkCreateWaylandSurfaceKHR
    ├── clipboard.zig     # wl_data_device_manager：selection / data_source / data_offer
    ├── decorations.zig   # xdg-decoration
    ├── ime.zig           # text-input-v3 + set_cursor_rectangle
    ├── loader.zig        # 仅 wayland-egl；EGL/xkbcommon 转发自 ../egl.zig、../xkb.zig
    ├── bindings.h        # translate-c 的手写输入（协议 header/C 在构建时生成）
    ├── protocols.zig     # 统一导入生成的 protocols/bindings.zig
    ├── protocols/        # wayland-scanner + translate-c 生成物（构建时生成，gitignore）
    └── wayland.md        # 本文档
```

XCB 是 X11 协议绑定，Wayland 后端不使用；它属于未来的 `src/linux/x11`，因此没有放进
`src/linux` 的通用层。EGL 和 xkbcommon 才是 Wayland/X11 都需要的 Linux 通用部分。

Zig 的限制：类型方法必须写在类型所在文件里。因此 `window.zig` 定义
`pub const Window = struct { ... }`，`context.zig` 定义 `pub const Context = ...`；
`backend.zig` 只 re-export：

```zig
pub const Window = @import("window.zig").Window;
pub const Context = @import("context.zig").Context;
```

`input.zig` / `monitor.zig` / `clipboard.zig` 等提供状态与回调，由 `backend.zig`
组合；不得 import 上层 `App/Window/Context`。

---

## 2. 构建与链接 / Build and linking

### 2.1 编译期选择

`build.zig` 在 `wayland` 时（`both` 需要未来的 X11 后端）：

- 链接 `wayland-client`（生成的协议 C 会调用 `wl_proxy_*`）；
- 编译 `protocols/*.c`；
- include `protocols/` 与 Wayland 头文件路径；
- 需要 libc（协议 C 代码 + 头文件）；
- `wayland-egl` / `wayland-cursor` / `xkbcommon` 可以链接，也可以 dlopen；
- EGL / GL / GLES / Vulkan 建议 **dlopen**（`loader.zig`），避免硬依赖驱动；
- 可选 `libdecor`（如果决定用 libdecor 做 CSD）也是 dlopen。

Sketch:

```zig
if (linux_backend == .wayland or linux_backend == .both) {
    mod.linkSystemLibrary("wayland-client", .{});
    mod.link_libc = true;
    mod.addCSourceFiles(.{
        .root = b.path("src/linux/wayland/protocols"),
        .files = &.{
            "xdg-shell-protocol.c",
            // optional: xdg-decoration, fractional-scale, cursor-shape, ...
        },
        .flags = &.{},
    });
    mod.addIncludePath(b.path("src/linux/wayland/protocols"));
}
```

注意：`wayland-scanner` 生成的 C 文件依赖 `libwayland-client` 的
`wl_proxy_marshal_flags` / `wl_proxy_add_listener` 等符号，因此 **Wayland 构建必须
链接 wayland-client**。其余库可以 dlopen。

### 2.2 协议生成

协议生成由 `build.zig` 在编译时完成，生成物写到
`src/linux/wayland/protocols/`，并且 **不提交到仓库**（`.gitignore` 已忽略
`*-client.h`、`*-protocol.c`、`bindings.zig`）。仓库只保留手写的
`protocols.zig` 和 `bindings.h`（translate-c 输入）。

- `-Dwayland-protocols=/path` 可覆盖 XML 目录，默认 `/usr/share/wayland-protocols`；
- 只有 `-Dbackend=wayland` 才生成协议、链接 `wayland-client` 并解析 Wayland 后端源码；
  `null` / `x11` 构建通过生成的 `backend_selected.zig` 只导入自己的后端；
- 构建步骤按顺序：`wayland-scanner client-header` / `private-code` →
  `zig translate-c` 生成 `bindings.zig`；
- Zig 0.17 移除了 `@cImport`，所以用 `zig translate-c` 生成绑定；
- 生成 C 依赖 `libwayland-client` 的 `wl_proxy_*` 符号，Wayland 构建必须链接它；
- 交叉编译需要 host 安装 `wayland-scanner` 和对应协议 XML。

当前扫描的协议：`xdg-shell`、`xdg-decoration-unstable-v1`、`cursor-shape-v1`、
`tablet-unstable-v2`（数位笔事件，同时 cursor-shape 的 C 代码引用 tablet tool 接口）、
`alpha-modifier-v1`、`text-input-unstable-v3`。

```bash
wayland-scanner client-header "$XML" src/linux/wayland/protocols/xdg-shell-client.h
wayland-scanner private-code  "$XML" src/linux/wayland/protocols/xdg-shell-protocol.c
```

---

## 3. 初始化流程 / Initialization sequence

### 3.1 `Backend.init`

1. **连接 display**
   ```zig
   const display = wl_display_connect(null) orelse return error.WaylandConnectFailed;
   ```
   `both` 模式下连接失败应让 `Backend.init` 返回错误，由上层/构建时的运行时分派逻辑回退 X11。

2. **获取 registry 并绑定 globals**
   ```zig
   const registry = wl_display_get_registry(display);
   wl_registry_add_listener(registry, &registry_listener, self);
   wl_display_roundtrip(display); // 第一轮：拿到 global 列表
   wl_display_roundtrip(display); // 第二轮：output/seat 等子对象完成初始化
   ```

   必需 globals（缺失则 Wayland 后端不可用）：

   | global | 最低版本 | 用途 |
   |---|---|---|
   | `wl_compositor` | 4 | `wl_surface`、damage |
   | `wl_shm` | 1 | 软件 buffer / cursor / clipboard |
   | `wl_seat` | 5 | 输入、剪贴板焦点 |
   | `wl_output` | 4 | 监视器、scale、name/description |
   | `xdg_wm_base` | 2 | xdg_surface / xdg_toplevel |
   | `wl_data_device_manager` | 3 | 剪贴板/拖放 |

   可选 globals（不存在就降级）：

   | protocol | 用途 |
   |---|---|
   | `zxdg_decoration_manager_v1` | 服务端/客户端装饰模式 |
   | `wp_viewporter` | 分数缩放、viewport |
   | `wp_fractional_scale_manager_v1` | 分数 DPI |
   | `zwp_relative_pointer_manager_v1` | 相对鼠标 |
   | `zwp_pointer_constraints_v1` | 锁定/限制指针 |
   | `zwp_tablet_manager_v2` | 数位笔事件 |
   | `zwp_text_input_manager_v3` | IME |
   | `wp_cursor_shape_manager_v1` | 标准光标形状 |
   | `xdg_activation_v1` | 激活窗口/提醒 |
   | `xdg_toplevel_icon_manager_v1` | 窗口图标 |
   | `wp_alpha_modifier_v1` | 整窗 opacity |
   | `zwp_linux_dmabuf_v1` | 零拷贝 buffer（后续优化） |
   | `wp_presentation` | 呈现时间戳（后续优化） |
   | `zwp_idle_inhibit_manager_v1` | 阻止熄屏 |

3. **建立事件队列**
   - 使用一个 `wl_event_queue`（或直接 `wl_display_dispatch_pending`）；
   - 输入/registry/output 回调把 `Event.Core` push 到内部队列；
   - `pollEvent` 只做非阻塞 drain：
     ```zig
     wl_display_dispatch_pending(display); // 派发已经到达的事件
     wl_display_flush(display);            // 把请求刷给合成器
     if (queue.items.len == 0) { ev.* = .none; return false; }
     ev.* = queue.orderedRemove(0);
     return true;
     ```
   - 不要用阻塞的 `wl_display_dispatch()`；库不提供 `waitEvent`。用户想阻塞时自己 poll
     `wl_display_get_fd()` 再调用 `pollEvent`。

4. **EGL 延迟初始化**
   - `Backend.init` 可以只初始化 Wayland；EGL display 在第一次 `initContext` 时建立，
     或提前在 `Backend.init` 建立并缓存；
   - 建议提前建立 `EGLDisplay`，但 `EGLContext` 按窗口创建。

5. **seat / output 子对象**
   - `wl_seat` 绑定后添加 capabilities/keymap 等 listener；
   - `wl_output` 绑定后处理 geometry/mode/scale/name/description/done；
   - 热插拔：`wl_registry.global`/`global_remove` 更新 monitors 和 seat 列表。

### 3.2 EGL / OpenGL / OpenGL ES

```text
eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND_KHR, wl_display, null)
  └─ eglInitialize
  └─ eglBindAPI(EGL_OPENGL_API 或 EGL_OPENGL_ES_API)
  └─ eglChooseConfig(... EGL_ALPHA_SIZE >= 8 ...)   // 默认支持透明
  └─ eglCreateContext(display, config, share_context, attribs)
  └─ wl_egl_window_create(wl_surface, width, height)
  └─ eglCreateWindowSurface(display, config, egl_window, null)
  └─ eglMakeCurrent
```

- `eglGetPlatformDisplay` 是 EGL 1.5；旧实现用
  `eglGetProcAddress("eglGetPlatformDisplayEXT")`；
- `ContextConfig.api` → `EGL_OPENGL_API` / `EGL_OPENGL_ES_API`；
- `major/minor/profile/debug` → `EGL_KHR_create_context` 属性；
- **默认请求 `EGL_ALPHA_SIZE >= 8`**，实现逐像素透明；
- resize：`wl_egl_window_resize(egl_window, w, h, 0, 0)`；
- present：`eglSwapBuffers`；vsync：`eglSwapInterval`；
- `share`：`eglCreateContext(..., share.backend.egl.context, ...)`；
- `getProcAddress`：`eglGetProcAddress`；
- `ContextInfo.creator = .egl`，版本/字符串创建后缓存。

### 3.3 Vulkan WSI

- `App.getVulkanInstanceExtensions()` 返回：
  - `VK_KHR_surface`
  - `VK_KHR_wayland_surface`
- `Window.getNative()`：
  - `ndt = wl_display`
  - `nwh = wl_surface`
- `Window.createVulkanSurface(instance, get_instance_proc_addr, allocator)`：
  ```text
  pfn = get_instance_proc_addr(instance, "vkCreateWaylandSurfaceKHR")
  VkWaylandSurfaceCreateInfoKHR {
      .sType = VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
      .display = wl_display,
      .surface = wl_surface,
  }
  pfn(instance, &info, allocator, &surface)
  ```
- 库不创建 instance/device/swapchain；透明/alpha 由用户 swapchain 的 format 与
  `compositeAlpha` 决定。

### 3.4 关闭流程 / Shutdown

- 上层 `Window.destroy` 先销毁 Context，再销毁 backend window；
- backend window 顺序：
  `xdg_toplevel.destroy` → `xdg_surface.destroy` → `wl_surface.destroy`
  → `wl_egl_window_destroy`（如果由 backend 持有）→ 释放窗口状态；
- `Backend.uninit`：销毁 seats/outputs/registry，`eglTerminate`（如果 EGLDisplay 已建立），
  `wl_display_flush`，`wl_display_disconnect`；
- 不发送 `window_destroyed`；`window_should_close` 只是请求。

### 3.5 xdg-shell 关键规则

- `xdg_wm_base.ping` 必须回复 `pong`，否则合成器可能判定客户端无响应；
- 每个 `xdg_surface` 在首次 attach/commit 前必须收到并 `ack_configure`；
- `xdg_toplevel.configure` 的 width/height 为 0 表示客户端自选；非 0 表示建议尺寸；
- 收到 configure 后更新 `WindowInfo.size`，push `window_resized`；
- `xdg_toplevel.close` → push `window_should_close`；不销毁；
- `wl_surface.frame` 回调用于节流；EGL 下通常 `eglSwapBuffers` 已处理 commit；
- 透明：`wl_surface.set_opaque_region` 设为空（或忽略），让合成器按 alpha 混合。

---

## 4. 后端接口到 Wayland 实现的映射 / Interface mapping

### 4.1 Backend object

| 接口 | Wayland 实现 / 协议 | 说明 |
|---|---|---|
| `init` | `wl_display_connect`、`wl_registry`、`wl_compositor`、`wl_shm`、`wl_seat`、`wl_output`、`xdg_wm_base`、`wl_data_device_manager` | 缺失必需 global 时返回 `error.Unsupported` / `error.WaylandConnectFailed` |
| `uninit` | 销毁 seats/outputs/registry → `eglTerminate`（如有）→ `wl_display_disconnect` | 顺序不可反；Context/窗口先由上层销毁 |
| `initWindow` | `wl_compositor.create_surface`、`xdg_wm_base.get_xdg_surface`、`xdg_surface.get_toplevel` | 首次 commit 前等 configure 并 ack |
| `initContext` | EGL：`eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND_KHR, ...)` | 见 3.2；`share` 传给 `eglCreateContext` |
| `pollEvent` | `wl_display_dispatch_pending` + 内部队列 | 非阻塞；空队列写 `.none` 返回 false |
| `pushEvent` | 内部 `Event.Core` 队列 | 不复制 `TextInput.text` |
| `getVulkanInstanceExtensions` | 静态 `VK_KHR_surface`、`VK_KHR_wayland_surface` | 返回后端持有切片 |
| `getInfo` | `platform = .wayland`、`context_creator = .egl` | `requested/effective` 由 `Backend.zig` 覆盖 |
| `getMonitors` | `wl_output` + `xdg_output` | 见 4.5 |
| `set/getClipboardText` | `wl_data_device_manager` / `wl_data_device` | 见 4.6 |

### 4.2 Window

| 接口 | Wayland 实现 / 协议 | 说明 |
|---|---|---|
| `getId` | 后端自增/对象 id | 事件只带 id |
| `getNative` | `ndt = wl_display`，`nwh = wl_surface` | bgfx `PlatformData` 直接使用 |
| `setTitle/getTitle` | `xdg_toplevel.set_title` | 字符串需保持到 flush；后端保存副本 |
| `setSize/getSize` | `xdg_toplevel` 无程序化 set_size；用 buffer 尺寸 + configure | `setSize` 记录请求并 resize buffer/commit，`getSize` 返回 configure 结果 |
| `setPos/getPos` | Wayland 无全局坐标 | `setPos` no-op/丢弃，`getPos` 返回 null |
| `getFramebufferSize` | `size * buffer_scale`；分数缩放用 `wp_viewporter` + `wp_fractional_scale_v1` | commit buffer 的物理像素 |
| `getDpiScale` | `wl_output.scale`（整数）+ `wp_fractional_scale_v1` | 输出 enter/scale 变化时更新 |
| `setMaxSize/setMinSize` | `xdg_toplevel.set_max_size/set_min_size` | `null` → 0,0（无限制） |
| `setResizable` | 无直接 API；可记录/用 min=max 固定尺寸 | 真实实现受限，文档说明 |
| `setFullscreen` | `xdg_toplevel.set_fullscreen/unset_fullscreen` | 等 configure 更新状态 |
| `minimize/maximize` | `xdg_toplevel.set_minimized` / `set_maximized` / `unset_maximized` | 状态由 configure 更新 |
| `setFocus` | `xdg_activation_v1`（可选） | 合成器策略，可能被拒绝 |
| `requestAttention` | `xdg_activation_v1`（可选） | 无协议时返回 `error.Unsupported` |
| `setCursor` | `wl_pointer.set_cursor` + `wl_cursor_theme` 或 `wp_cursor_shape_v1` | 需要 pointer enter 的 serial |
| `setCursorVisible` | `wl_pointer.set_cursor(serial, null, 0, 0)` | 隐藏光标 |
| `setAspectRatio` | Wayland 无标准 | 记录/返回 no-op |
| `setImeAllowed` | `zwp_text_input_v3.enable/disable`（可选） | 需要 `zwp_text_input_manager_v3` |
| `setImeCursorArea` | `zwp_text_input_v3.set_cursor_rectangle` + `commit` | 无 text-input 时忽略 |
| `setIcon` | `xdg_toplevel_icon_v1`（staging，可选） | 无协议返回 `error.Unsupported` |
| `setDecorated` | `zxdg_toplevel_decoration_v1`（可选）或 CSD | 服务端装饰/客户端装饰二选一 |
| `setAlwaysOnTop` | xdg-shell 无标准 | 返回 `error.Unsupported`（layer-shell 不做默认） |
| `setOpacity` | `wp_alpha_modifier_v1`（staging，可选） | 无协议返回 `error.Unsupported`；上层 reporter 记录 |
| `getInfo` | 缓存 configure/scale/state | 所有 getter 基于此 |
| `createVulkanSurface` | `vkCreateWaylandSurfaceKHR` | 见 3.3；一个窗口一次 |

### 4.3 Context

| 接口 | 实现 |
|---|---|
| `getKind` | `.opengl` / `.opengles`（来自 `ContextConfig.api`） |
| `getInfo` | 创建后缓存 `eglQueryString` / `glGetString`：vendor/renderer/version/GLSL；`creator = .egl` |
| `getNative` | `NativeContext { display, config, context, surface }`（EGL 句柄） |
| `uninit` | `eglDestroySurface` → `eglDestroyContext`；`wl_egl_window_destroy` |
| `makeCurrent` | `eglMakeCurrent(display, surface, surface, context)` |
| `clearCurrent` | `eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)` |
| `getProcAddress` | `eglGetProcAddress` |
| `swapBuffers` | `eglSwapBuffers` |
| `setSwapInterval` | `eglSwapInterval` |

### 4.4 事件 / Events

| Event.Core | Wayland 来源 | 备注 |
|---|---|---|
| `key_down/key_up` | `wl_keyboard.key` + xkbcommon | keymap 来自 `wl_keyboard.keymap`；`Mods` 由 xkb state 生成；`repeat` 用 `repeat_info` + timer |
| `text_input` | `zwp_text_input_v3.commit_string` | `text` 借用/需复制到事件生命周期；可选协议 |
| `mouse_entered/mouse_left` | `wl_pointer.enter/leave` | 记录 serial、surface |
| `mouse_moved` | `wl_pointer.motion` | 逻辑坐标（wl_fixed） |
| `mouse_button_*` | `wl_pointer.button` | `click_count` 可由后端统计 |
| `mouse_scrolled` | `wl_pointer.axis` | `dx/dy`；离散/连续 |
| `window_should_close` | `xdg_toplevel.close` | 只发请求，不销毁 |
| `window_resized` | `xdg_toplevel.configure` + `xdg_surface.configure` | 更新 size；0 表示建议 |
| `window_scale_changed` | `wl_output.scale` / `wp_fractional_scale_v1.preferred_scale` | 输出 enter/leave 时计算 |
| `window_focus_gained/lost` | `xdg_toplevel.configure` states 或 keyboard enter/leave | 按实现选择 |
| `window_minimized/maximized/restored` | `xdg_toplevel.configure` states | `activated`/`maximized`/`fullscreen` |
| `pen_*` | `zwp_tablet_tool_v2` | pressure/tilt/rotation/eraser；已实现，无协议则不产生 |
| `custom` | `pushEvent` | 后端不解释 |
| `unknown` | 未映射事件 | 保留 |

Wayland 没有全局窗口位置，因此通常不产生 `window_moved`；`getPos()` 返回 null。

另外注意：

- `wl_keyboard.keymap` 是 fd + size，需要 `mmap` 后交给 `xkb_keymap_new_from_string`；
- key repeat 由 `wl_keyboard.repeat_info` 的 rate/delay 驱动，后端维护计时；不要依赖 compositor 重发 key；
- pointer serial 必须保存，用于 `set_cursor`、`set_selection`、drag；
- `wl_touch` 事件映射为鼠标左键：down → `mouse_entered`/`mouse_moved`/`mouse_button_down`，
  motion → `mouse_moved`，up/cancel → `mouse_button_up`/`mouse_left`；不产生 touch 类型事件。
- `zwp_tablet_manager_v2` 已实现，映射为 `pen_*`，包括压感、tilt、rotation、按键和橡皮擦。
- `zwp_relative_pointer_v1` 可提供 raw motion，当前 Event 没有专门字段，可先不支持；
- `zwp_pointer_constraints_v1` 用于锁定/限制指针，暂可不实现；
- `zwp_tablet_manager_v2` 对应 `pen_*`，可选；
- `zwp_text_input_manager_v3` 对应 text_input / IME，可选；
- 所有事件时间戳（`time`）可忽略或用于 click_count/双击检测。

### 4.5 Monitors / 监视器

- `wl_output`：`geometry`、`mode`、`scale`、`name`/`description`（v4）、`done`；
- `xdg_output_v1`（可选）：`logical_position`、`logical_size`、`name`、`description`；
- `getMonitors` 每次分配 `[]MonitorInfo`；`name` 由后端持有或复制到数组生命周期；
- `window_scale_changed` 在窗口进入不同 output 或 output scale/fractional 变化时发出；
- 热插拔通过 `wl_registry.global/global_remove` 更新列表。

### 4.6 Clipboard / 剪贴板

- `wl_data_device_manager.get_data_device(seat)`；
- 选择：`wl_data_source.offer("text/plain;charset=utf-8")` + `set_selection(serial)`；
- 读取：`wl_data_offer.receive("text/plain;charset=utf-8", fd)`，从 pipe 读；
- 需要键盘焦点/serial；异步事件驱动；
- `getClipboardText` 若在 `pollEvent` 外部同步等待会破坏事件循环，建议：
  - 先返回当前缓存（selection 事件时后台读取并缓存），或
  - 返回 `error.Unsupported`/`error.WouldBlock`，由用户驱动事件循环后再取；
  - 文档需明确选择。

### 4.7 透明 / Transparency

- EGL：`EGL_ALPHA_SIZE >= 8`；clear alpha < 1；
- 软件 buffer：`WL_SHM_FORMAT_ARGB8888`；
- `wl_surface.set_opaque_region(empty)`（默认通常为空，显式更清晰）；
- 合成器对 ARGB buffer 做混合；没有 xdg-shell 透明开关；
- 整窗 opacity：`wp_alpha_modifier_v1`（staging，可选）；无协议返回 `error.Unsupported`；
- Vulkan：用户 swapchain 选择 alpha format 和 `compositeAlpha`，库不创建 swapchain。

### 4.8 Cursor / Decorations / IME

- **Cursor**：
  - 优先 `wp_cursor_shape_manager_v1`（按 `General.Cursor` 映射 shape）；
  - 否则 `wl_cursor_theme_load(theme, size*scale, shm)` + `wl_cursor_image_get_buffer`；
  - `wl_pointer.set_cursor(serial, cursor_surface, hotspot_x, hotspot_y)`；
  - 隐藏：`set_cursor(serial, null, 0, 0)`；
  - 需要 `wl_pointer.enter` 保存的 serial。
- **Decorations**：
  - `zxdg_decoration_manager_v1` 请求 `server_side`/`client_side`；
  - 没有协议时只能 CSD 或接受无装饰；
  - `setDecorated(false)` 对应 `client_side` + 自绘/无边框。
- **IME**：
  - `zwp_text_input_manager_v3.get_text_input(seat)`；
  - `enable()` / `disable()`、`set_cursor_rectangle(x,y,w,h)`、`commit()`；
  - `preedit_string` / `commit_string` → `Event.text_input`；
  - 无协议时 `setImeAllowed` 返回 `error.Unsupported` 或 no-op。

---

## 5. 协议文件从哪里下载 / Where to get protocol files

### 5.1 系统包（推荐先装）

```bash
# Arch
sudo pacman -S wayland wayland-protocols

# Debian / Ubuntu
sudo apt install libwayland-dev wayland-protocols

# Fedora
sudo dnf install wayland-devel wayland-protocols-devel
```

安装后：

| 内容 | 路径 |
|---|---|
| wayland 核心 XML | `/usr/share/wayland/wayland.xml` |
| wayland-protocols XML | `/usr/share/wayland-protocols/` |
| Wayland C 头文件 | `/usr/include/wayland-client.h` 等 |
| `wayland-scanner` | `/usr/bin/wayland-scanner` |
| EGL 头文件 | `/usr/include/EGL/` |
| xkbcommon 头文件 | `/usr/include/xkbcommon/` |

### 5.2 源码仓库 / Source repositories

- Wayland（核心协议、libwayland、scanner）：
  - Git: `https://gitlab.freedesktop.org/wayland/wayland.git`
  - Releases: `https://wayland.freedesktop.org/releases.html`
- wayland-protocols（xdg-shell、fractional-scale、cursor-shape 等）：
  - Git: `https://gitlab.freedesktop.org/wayland/wayland-protocols.git`
  - Releases: `https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases`
- 如果决定支持 layer-shell（不计划默认支持）：
  - `https://gitlab.freedesktop.org/wlroots/wlr-protocols.git`

```bash
git clone https://gitlab.freedesktop.org/wayland/wayland.git
git clone https://gitlab.freedesktop.org/wayland/wayland-protocols.git
```

### 5.3 本项目需要的 XML

| 用途 | XML（wayland-protocols 相对路径） | 必需 |
|---|---|---|
| 窗口/标题/全屏/最小化 | `stable/xdg-shell/xdg-shell.xml` | 必需 |
| 分数缩放/viewport | `stable/viewporter/viewporter.xml` + `staging/fractional-scale/fractional-scale-v1.xml` | 可选 |
| 装饰 | `unstable/xdg-decoration/xdg-decoration-unstable-v1.xml` | 可选 |
| 光标形状 | `staging/cursor-shape/cursor-shape-v1.xml` | 可选 |
| 激活/提醒 | `staging/xdg-activation/xdg-activation-v1.xml` | 可选 |
| 窗口图标 | `staging/xdg-toplevel-icon/xdg-toplevel-icon-v1.xml` | 可选 |
| 整窗 opacity | `staging/alpha-modifier/alpha-modifier-v1.xml` | 可选 |
| IME | `unstable/text-input/text-input-unstable-v3.xml` | 可选 |
| 数位笔 | `unstable/tablet/tablet-unstable-v2.xml` | 可选 |
| 相对鼠标 | `unstable/relative-pointer/relative-pointer-unstable-v1.xml` | 可选 |
| 指针锁定 | `unstable/pointer-constraints/pointer-constraints-unstable-v1.xml` | 可选 |
| 监视器逻辑信息 | `unstable/xdg-output/xdg-output-unstable-v1.xml` | 可选 |
| 阻止熄屏 | `unstable/idle-inhibit/idle-inhibit-unstable-v1.xml` | 可选 |
| 零拷贝 buffer | `stable/linux-dmabuf/linux-dmabuf-v1.xml` | 后续优化 |
| 呈现时间戳 | `stable/presentation-time/presentation-time.xml` | 后续优化 |

Wayland 核心协议（`wl_display`、`wl_surface`、`wl_seat` 等）由 libwayland 自带，
不需要自己扫描；只需要 `xdg-shell` 及可选扩展。

### 5.4 生成命令

`build.zig` 会对每个协议执行下面的两条命令，并在所有 header 生成后运行
`zig translate-c` 生成 `bindings.zig`：

```bash
wayland-scanner client-header \
  /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml \
  src/linux/wayland/protocols/xdg-shell-client.h

wayland-scanner private-code \
  /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml \
  src/linux/wayland/protocols/xdg-shell-protocol.c
```

- 生成物在构建时写入 `protocols/`，仓库不提交；
- 生成 C 需要 `wayland-client` 的符号，所以 Wayland 构建必须链接 `libwayland-client`；
- 生成的 header 需要 `wayland-client-core.h` 等系统头文件路径；
- `private-code` 用于程序内部；`public-code` 只有在需要导出协议接口时才用。

---

## 6. 风险、决策与实现顺序 / Risks, decisions and order

### 6.1 已知限制

- `setSize`：Wayland 没有程序化 resize 请求；只能 resize buffer 并 commit，最终尺寸由
  compositor 决定。`getSize` 必须返回 configure 结果。
- `setPos`/`window_moved`：没有全局坐标；`getPos` 返回 null，`setPos` no-op。
- `setResizable`：没有直接 API；可用 `set_min_size == set_max_size` 固定尺寸近似。
- `setAlwaysOnTop`：xdg-shell 没有标准；默认不支持（不引入 layer-shell）。
- `setAspectRatio`：没有标准；记录/no-op。
- 装饰：需要 `xdg-decoration` 或自行实现 CSD；CSD 工作量大。
- 剪贴板读取是异步事件驱动；同步 `getClipboardText` 需要缓存或返回 `WouldBlock`。
- IME、数位笔、相对鼠标、指针锁定都依赖可选协议；缺失时返回 `error.Unsupported` 或忽略。
- `AppConfig.application_id` 已加入；空值时 Wayland 后端回退为 `"zcwl-app"`。
- 可选库（EGL / wayland-egl / xkbcommon）通过 `loader.zig` dlopen：先查候选 soname，
  再允许 `ZCWL_EGL_LIB` / `ZCWL_WAYLAND_EGL_LIB` / `ZCWL_XKBCOMMON_LIB` 覆盖；
  缺库时对应功能降级而不是整个后端启动失败。
- 键盘重复事件由 compositor 的 repeated key 事件上报，后端未安装客户端定时器。
- Wayland 无法获取窗口位置；`WindowInfo.position` 在 Wayland 下为 null。
- 透明：默认 alpha 配置；如果合成器/驱动不支持，表现为不透明或黑边，不是错误。

### 6.2 内存与日志约定

- 后端自身的堆分配全部使用 `Backend.init` 传入的 `std.mem.Allocator`；不使用全局分配器。
- `getMonitors` / `getClipboardText` 返回调用方拥有的内存；`getTitle`、`MonitorInfo.name`、
  `ContextInfo` 字符串是借用，生命周期由拥有者决定。
- IME/键盘产生的 `TextInput.text` 由后端复制到 `owned_text`，在 `Backend.uninit` 释放；
  事件队列本身不复制借用切片。
- `Window`/`Context`/`Monitor`/`Clipboard` 的销毁顺序由 `App`/`Backend` 统一管理；
  内存测试在 `test/api_test.zig`（`std.testing.allocator` + `checkAllAllocationFailures`）。
- 库代码不调用 `std.debug.print`/`std.log`；无法通过返回值报告的清理错误走
  `General.reportError`，初始化信息走 `General.info_reporter`。
- `dlopen`、EGL、xkbcommon、Wayland 库的内部内存由 libc/库自身管理，不属于传入
  allocator；本库只负责关闭自己持有的句柄。

### 6.3 建议实现顺序

1. `display.zig`：连接、registry、绑定 globals、roundtrip、事件泵骨架；
2. `window.zig` + `surface.zig`：wl_surface/xdg_surface/xdg_toplevel、configure/ack、
   title/min/max/fullscreen/close；
3. `event.zig` + `input.zig`：seat/pointer/keyboard/touch + xkbcommon，映射到 Event.Core；
4. `context.zig` + EGL：默认 alpha config、share、make current、swap、getProcAddress；
5. `monitor.zig` + `cursor.zig`：输出、scale、光标；
6. `clipboard.zig`、`decorations.zig`、`ime.zig`（可选协议逐个启用）；
7. `vulkan.zig`：extensions + `vkCreateWaylandSurfaceKHR`；
8. 可选优化：dmabuf、presentation-time、idle-inhibit、tablet、relative-pointer；
9. 最后补 Wayland 后端 API 测试（复用 `test/api_test.zig` 模式，build step 选 `.wayland`）。

### 6.3 构建时协议开关

建议在 build.zig 增加 Wayland 协议开关（默认只启用 xdg-shell）：

```text
-Dwayland-fractional-scale=true
-Dwayland-decoration=true
-Dwayland-cursor-shape=true
-Dwayland-text-input=true
-Dwayland-tablet=true
-Dwayland-idle-inhibit=true
```

每启用一个协议：
- 增加对应 XML 的 generated `.c`；
- 绑定对应 global（不存在则降级）；
- 后端接口按支持情况返回 `error.Unsupported` 或走降级路径。





