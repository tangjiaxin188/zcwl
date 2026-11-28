const std = @import("std");

const BackendChoice = enum { auto, null, wayland, x11, both, windows, macos };
const Backend = enum { null, wayland, x11, both, windows, macos };

const WaylandProtocol = struct {
    /// Path relative to the wayland-protocols installation directory.
    xml: []const u8,
    /// Basename used for `-client.h` / `-protocol.c` in protocols/.
    name: []const u8,
};

/// Protocols needed by the current Wayland backend. The generated headers are
/// included by the handwritten `bindings.h`; each `-protocol.c` is compiled
/// into the module.
const wayland_protocols = [_]WaylandProtocol{
    .{ .xml = "stable/xdg-shell/xdg-shell.xml", .name = "xdg-shell" },
    .{ .xml = "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml", .name = "xdg-decoration-unstable-v1" },
    .{ .xml = "staging/cursor-shape/cursor-shape-v1.xml", .name = "cursor-shape-v1" },
    .{ .xml = "unstable/tablet/tablet-unstable-v2.xml", .name = "tablet-unstable-v2" },
    .{ .xml = "staging/alpha-modifier/alpha-modifier-v1.xml", .name = "alpha-modifier-v1" },
    .{ .xml = "unstable/text-input/text-input-unstable-v3.xml", .name = "text-input-unstable-v3" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const requested = b.option(
        BackendChoice,
        "backend",
        "Backend selection (default: auto)",
    ) orelse .auto;
    const backend = resolveBackend(target, requested);

    const wayland_protocols_dir = b.option(
        []const u8,
        "wayland-protocols",
        "wayland-protocols installation directory (default: /usr/share/wayland-protocols)",
    ) orelse "/usr/share/wayland-protocols";

    // Generate a selector containing exactly one backend import. A static
    // comptime switch is not equivalent: Zig still resolves/parses imports in
    // unselected arms, which breaks fresh headless builds when the Wayland
    // protocol headers have not been generated.
    const backend_selector = addBackendSelector(b, backend);

    // Wayland protocol sources are only needed by the Wayland backend.
    const gen_protocols: ?*std.Build.Step = if (backend == .wayland)
        addWaylandProtocols(b, wayland_protocols_dir)
    else
        null;
    if (gen_protocols) |gen| b.getInstallStep().dependOn(gen);
    b.getInstallStep().dependOn(backend_selector);

    const mod = createZcwlModule(b, target, optimize, backend);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    mod_tests.step.dependOn(backend_selector);
    if (gen_protocols) |gen| mod_tests.step.dependOn(gen);
    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.stdio = .inherit;

    const unit_step = b.step("test-unit", "Run library unit tests");
    unit_step.dependOn(&run_mod_tests.step);

    const test_step = b.step("test", "Run API tests for the selected backend");

    // Example executable (source at <project>/example). `zig build run example`
    // both builds and runs it.
    const example_mod = b.createModule(.{
        .root_source_file = b.path("example/draw_triangle.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_mod.addImport("zcwl", mod);
    const example_exe = b.addExecutable(.{
        .name = "zcwl-example",
        .root_module = example_mod,
    });
    example_exe.step.dependOn(backend_selector);
    if (gen_protocols) |gen| example_exe.step.dependOn(gen);
    b.installArtifact(example_exe);

    const run_example = b.addRunArtifact(example_exe);
    run_example.stdio = .inherit;
    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_example.step);

    const example_step = b.step("example", "Build the example");
    example_step.dependOn(&example_exe.step);

    // One API suite per build graph. A second zcwl module with a different
    // backend would read the same generated selector file and compile the
    // wrong backend (and with the wrong linker/libc setup). Select the
    // backend with `-Dbackend=null|wayland` instead.
    const run_api = addApiTest(b, target, optimize, "test/api_test.zig", backend, gen_protocols, backend_selector);
    test_step.dependOn(&run_api.step);

    const null_step = b.step("null", "API tests for the null backend (-Dbackend=null)");
    if (backend == .null) {
        null_step.dependOn(&run_api.step);
    } else {
        null_step.dependOn(&b.addFail("zig build null requires -Dbackend=null").step);
    }

    const wayland_step = b.step("wayland", "API tests for the Wayland backend (-Dbackend=wayland)");
    if (backend == .wayland) {
        wayland_step.dependOn(&run_api.step);
    } else {
        wayland_step.dependOn(&b.addFail("zig build wayland requires -Dbackend=wayland").step);
    }
}

/// Generate `src/backend_selected.zig` with exactly one backend import so
/// unselected backends are neither resolved nor analyzed. The file is
/// gitignored and only ever contains a single import line.
///
/// `name` lets `Backend.zig` detect a selector overwritten by a concurrent
/// build with a different `-Dbackend`. Writes are atomic so a reader never sees
/// a partially written file.
fn addBackendSelector(b: *std.Build, backend: Backend) *std.Build.Step {
    const out = b.root.joinString(b.allocator, "src/backend_selected.zig") catch @panic("OOM");
    const import_path = switch (backend) {
        .wayland => "linux/wayland/backend.zig",
        else => "null/backend.zig",
    };
    const content = b.fmt(
        "// Generated by build.zig. Do not edit.\n" ++
            "pub const name = \"{s}\";\n" ++
            "pub const impl = @import(\"{s}\");\n",
        .{ @tagName(backend), import_path },
    );
    // Pass the content and path as positional arguments so paths containing
    // spaces or quotes are not re-parsed by the shell.
    const run = b.addSystemCommand(&.{
        "sh",
        "-c",
        "trap 'rm -f \"$2.tmp.$$\"' EXIT; printf '%s' \"$1\" > \"$2.tmp.$$\" && mv \"$2.tmp.$$\" \"$2\"",
        "sh",
        content,
        out,
    });
    run.has_side_effects = true;
    return &run.step;
}

/// Build the `zcwl` module; the backend selector is generated by
/// `addBackendSelector` before compilation.
fn createZcwlModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    backend: Backend,
) *std.Build.Module {
    const zcwl = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const opts = b.addOptions();
    opts.addOption(Backend, "backend", backend);
    zcwl.addOptions("build_options", opts);
    if (backend == .wayland) configureWaylandModule(b, zcwl);
    return zcwl;
}

/// Generate Wayland client headers/private code and the translate-c bindings
/// into `src/linux/wayland/protocols/`. The output files are gitignored.
fn addWaylandProtocols(b: *std.Build, protocols_dir: []const u8) *std.Build.Step {
    const out_dir = b.root.joinString(b.allocator, "src/linux/wayland/protocols") catch @panic("OOM");
    const gen_step = b.step("wayland-protocols", "Generate Wayland protocol sources");

    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", out_dir });
    mkdir.has_side_effects = true;
    gen_step.dependOn(&mkdir.step);

    var header_steps = std.ArrayList(*std.Build.Step).empty;
    defer header_steps.deinit(b.allocator);

    for (wayland_protocols) |proto| {
        const xml = b.pathJoin(&.{ protocols_dir, proto.xml });
        const header = b.pathJoin(&.{ out_dir, b.fmt("{s}-client.h", .{proto.name}) });
        const code = b.pathJoin(&.{ out_dir, b.fmt("{s}-protocol.c", .{proto.name}) });

        // Atomic temp+rename: concurrent builds of the same backend write
        // identical content, so readers never see a partial file.
        const gen_header = b.addSystemCommand(&.{
            "sh",                                                                                                    "-c",
            "trap 'rm -f \"$3.tmp.$$\"' EXIT; \"$1\" client-header \"$2\" \"$3.tmp.$$\" && mv \"$3.tmp.$$\" \"$3\"", "sh",
            "wayland-scanner",                                                                                       xml,
            header,
        });
        gen_header.has_side_effects = true;
        gen_header.step.dependOn(&mkdir.step);

        const gen_code = b.addSystemCommand(&.{
            "sh",                                                                                                   "-c",
            "trap 'rm -f \"$3.tmp.$$\"' EXIT; \"$1\" private-code \"$2\" \"$3.tmp.$$\" && mv \"$3.tmp.$$\" \"$3\"", "sh",
            "wayland-scanner",                                                                                      xml,
            code,
        });
        gen_code.has_side_effects = true;
        gen_code.step.dependOn(&mkdir.step);

        header_steps.append(b.allocator, &gen_header.step) catch @panic("OOM");
        gen_step.dependOn(&gen_header.step);
        gen_step.dependOn(&gen_code.step);
    }

    // Zig 0.17 removed @cImport; translate-c is the supported replacement.
    // This runs after all generated headers exist.
    const bindings_zig = b.pathJoin(&.{ out_dir, "bindings.zig" });
    const bindings_h = b.root.joinString(b.allocator, "src/linux/wayland/bindings.h") catch @panic("OOM");
    const translate = b.addSystemCommand(&.{
        "sh",                                                                                                              "-c",
        "trap 'rm -f \"$4.tmp.$$\"' EXIT; \"$1\" translate-c -I \"$2\" \"$3\" > \"$4.tmp.$$\" && mv \"$4.tmp.$$\" \"$4\"", "sh",
        b.graph.zig_exe,                                                                                                   out_dir,
        bindings_h,                                                                                                        bindings_zig,
    });
    translate.has_side_effects = true;
    for (header_steps.items) |step| translate.step.dependOn(step);
    gen_step.dependOn(&translate.step);

    return gen_step;
}

/// Link and compile everything the wayland backend needs into `mod`.
fn configureWaylandModule(b: *std.Build, mod: *std.Build.Module) void {
    mod.linkSystemLibrary("wayland-client", .{});
    mod.link_libc = true;
    mod.addIncludePath(b.path("src/linux/wayland/protocols"));
    for (wayland_protocols) |proto| {
        mod.addCSourceFile(.{
            .file = b.path(b.fmt("src/linux/wayland/protocols/{s}-protocol.c", .{proto.name})),
        });
    }
    mod.addCMacro("_GNU_SOURCE", "1");
}

/// Resolve `auto` from the target OS and validate explicit selections. This is
/// the only place that maps an OS to a default backend; Backend.zig stays a
/// pure dispatcher.
fn resolveBackend(target: std.Build.ResolvedTarget, requested: BackendChoice) Backend {
    const os = target.result.os.tag;
    const backend: Backend = switch (requested) {
        .auto => switch (os) {
            .linux => .wayland,
            .windows => .windows,
            .macos => .macos,
            else => .null,
        },
        .null => .null,
        .wayland => .wayland,
        .x11 => .x11,
        .both => .both,
        .windows => .windows,
        .macos => .macos,
    };

    switch (backend) {
        .wayland => {
            if (os != .linux) std.process.fatal("wayland backend requires a Linux target", .{});
        },
        .x11, .both, .windows, .macos => {
            std.process.fatal("selected backend is not implemented yet; use -Dbackend=null or -Dbackend=wayland", .{});
        },
        .null => {},
    }
    return backend;
}

fn addApiTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    file: []const u8,
    backend: Backend,
    gen_protocols: ?*std.Build.Step,
    backend_selector: *std.Build.Step,
) *std.Build.Step.Run {
    const zcwl = createZcwlModule(b, target, optimize, backend);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(file),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("zcwl", zcwl);

    tests.step.dependOn(backend_selector);
    if (gen_protocols) |gen| tests.step.dependOn(gen);

    const run = b.addRunArtifact(tests);
    // Show the test runner output (and always execute, so `zig build test null`
    // has visible results instead of Zig's default silent-on-success behavior).
    run.stdio = .inherit;
    return run;
}
