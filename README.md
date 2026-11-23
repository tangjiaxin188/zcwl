# zcwl

<p align="center">
  <img alt="Wayland" src="https://img.shields.io/badge/Wayland-1.26-ffcc00?logo=wayland&logoColor=black">
  <img alt="Linux" src="https://img.shields.io/badge/Linux-any-FCC624?logo=linux&logoColor=black">
  <img alt="Zig" src="https://img.shields.io/badge/Zig-0.17.1-F7A41D?logo=zig&logoColor=black">
</p>

[**简体中文**](README.md) | [English](README_en.md) | [API 中文](api_zh.md) | [API English](api_en.md)

zcwl 是一个用 Zig 编写的跨平台库——尽管目前它还不跨平台。灵感来自 [RGFW](https://github.com/ColleagueRiley/RGFW) 和 [GLFW](https://github.com/glfw/glfw)。

## 平台支持

| 平台 | 状态 |
| --- | --- |
| Windows | ❌ 未实现 |
| Linux Wayland | ✅ 已实现 |
| Linux X11 | ❌ 未实现 |
| macOS | ❌ 未实现 |

## 起源

本项目最初是作为我的 Wayland 学习项目开发的。过程中本来只想通过 AI 了解如何开发这样的库，但由于自己开发效率较低，最后还是直接使用了 AI 生成的代码，主要包括后端代码、测试代码和文档等信息。

## 编译示例

依赖：Zig 0.17.1；Linux 上需要 `wayland-scanner`、`wayland-protocols`、`libwayland-client`，以及可选的 EGL、xkbcommon 和 wayland-egl。

```bash
# 编译并运行示例（example/draw_trangle.zig）
zig build run example
```

只编译不运行：

```bash
zig build example
```

`zig build` 也会安装示例到 `zig-out/bin/zcwl-example`。Wayland 协议源码在构建时生成到 `src/linux/wayland/protocols/`，不会提交到仓库。

## 测试代码

```bash
# 当前后端 API 测试（Linux auto 默认使用 Wayland）
zig build test

# 指定平台 API 测试
zig build null
zig build wayland
```

## 感谢

GLM、DeepSeek、Cline
