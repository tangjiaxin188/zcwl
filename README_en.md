# zcwl

<p align="center">
  <img alt="Wayland" src="https://img.shields.io/badge/Wayland-1.26-ffcc00?logo=wayland&logoColor=black">
  <img alt="Linux" src="https://img.shields.io/badge/Linux-any-FCC624?logo=linux&logoColor=black">
  <img alt="Zig" src="https://img.shields.io/badge/Zig-0.17.1-F7A41D?logo=zig&logoColor=black">
</p>

[简体中文](README.md) | [**English**](README_en.md) | [API 中文](api_zh.md) | [API English](api_en.md)

zcwl is a cross-platform library written in Zig—although it is not cross-platform yet. It is inspired by [RGFW](https://github.com/ColleagueRiley/RGFW) and [GLFW](https://github.com/glfw/glfw).

## Platform support

| Platform | Status |
| --- | --- |
| Windows | ❌ Not implemented |
| Linux Wayland | ✅ Implemented |
| Linux X11 | ❌ Not implemented |
| macOS | ❌ Not implemented |

## Origin

This project started as my Wayland learning project. At first I only wanted to use AI to understand how to build a library like this, but because my own development efficiency was low, I ended up directly using AI-generated code, mainly the backend, tests, and documentation.

## Building the example

Requirements: Zig 0.17.1; on Linux you also need `wayland-scanner`, `wayland-protocols`, `libwayland-client`, and optionally EGL, xkbcommon and wayland-egl.

```bash
# Build and run the example (example/draw_triangle.zig)
zig build run example
```

Build only:

```bash
zig build example
```

`zig build` also installs the example to `zig-out/bin/zcwl-example`. Wayland protocol sources are generated at build time into `src/linux/wayland/protocols/` and are not committed.

## Tests

```bash
# API tests for the selected backend (Linux auto selects Wayland)
zig build test

# Backend-specific API tests (one backend per build graph)
zig build test -Dbackend=null
zig build test -Dbackend=wayland
```

## Thanks

GLM, DeepSeek, Cline
