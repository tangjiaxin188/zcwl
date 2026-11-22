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

    // Only the selected backend is imported. The generated selector lives in
    // the source tree (gitignored) so its relative imports resolve inside the
    // same module as Backend.zig.
    const backend_selector = addBackendSelector(b, backend);

    // Wayland protocol sources are only needed by the Wayland backend.
    const gen_protocols: ?*std.Build.Step = if (backend == .wayland)
        addWaylandProtocols(b, wayland_protocols_dir)
    else
        null;
    if (gen_protocols) |gen| b.getInstallStep().dependOn(gen);
    b.getInstallStep().dependOn(backend_selector);
    const wayland_active = backend == .wayland;

    const mod = b.addModule("zcwl", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod_opts = b.addOptions();
    mod_opts.addOption(Backend, "backend", backend);
    mod.addOptions("build_options", mod_opts);

    if (wayland_active) {
        configureWaylandModule(b, mod);
    }

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
        .root_source_file = b.path("example/draw_trangle.zig"),
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

    // Per-backend public API suites. `zig build test` runs the API suite for
    // the selected backend; `zig build test-unit` runs library unit tests.
    // `zig build null` / `zig build wayland` run one specific suite.
    const run_null_api = addApiTest(b, target, optimize, "test/api_test.zig", .null, gen_protocols, backend_selector);
    const null_step = b.step("null", "Run null backend API tests");
    null_step.dependOn(&run_null_api.step);

    var run_wayland_api: ?*std.Build.Step.Run = null;
    if (wayland_active) {
        run_wayland_api = addApiTest(b, target, optimize, "test/api_test.zig", .wayland, gen_protocols, backend_selector);
        const wayland_step = b.step("wayland", "Run Wayland backend API tests");
        wayland_step.dependOn(&run_wayland_api.?.step);
    }

    // `test` already includes the selected backend's API suite; on Linux that
    // is Wayland, otherwise fall back to the null suite.
    if (backend == .wayland and run_wayland_api != null) {
        test_step.dependOn(&run_wayland_api.?.step);
    } else {
        test_step.dependOn(&run_null_api.step);
    }
}

fn addBackendSelector(b: *std.Build, backend: Backend) *std.Build.Step {
    const out = b.root.joinString(b.allocator, "src/backend_selected.zig") catch @panic("OOM");
    const import_path = switch (backend) {
        .wayland => "linux/wayland/backend.zig",
        else => "null/backend.zig",
    };
    const cmd = b.fmt(
        "printf '%s\\n' '// Generated by build.zig. Do not edit.' 'pub const impl = @import(\"{s}\");' > '{s}'",
        .{ import_path, out },
    );
    const run = b.addSystemCommand(&.{ "sh", "-c", cmd });
    run.has_side_effects = true;
    return &run.step;
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

        const gen_header = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
        gen_header.addArg(xml);
        gen_header.addArg(header);
        gen_header.has_side_effects = true;
        gen_header.step.dependOn(&mkdir.step);

        const gen_code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        gen_code.addArg(xml);
        gen_code.addArg(code);
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
    const translate_cmd = b.fmt(
        "'{s}' translate-c -I '{s}' '{s}' > '{s}'",
        .{ b.graph.zig_exe, out_dir, bindings_h, bindings_zig },
    );
    const translate = b.addSystemCommand(&.{ "sh", "-c", translate_cmd });
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
        .wayland, .x11, .both => {
            if (os != .linux) @panic("wayland/x11/both backends require a Linux target");
        },
        .windows => {
            if (os != .windows) @panic("-Dbackend=windows requires a Windows target");
        },
        .macos => {
            if (os != .macos) @panic("-Dbackend=macos requires a macOS target");
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
    const opts = b.addOptions();
    opts.addOption(Backend, "backend", backend);

    const zcwl = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zcwl.addOptions("build_options", opts);

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
    if (backend == .wayland) {
        configureWaylandModule(b, zcwl);
    }

    const run = b.addRunArtifact(tests);
    // Show the test runner output (and always execute, so `zig build test null`
    // has visible results instead of Zig's default silent-on-success behavior).
    run.stdio = .inherit;
    return run;
}
