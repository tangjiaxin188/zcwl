//! Triangle example: creates a window, logs keyboard/mouse/window events and
//! draws a colored triangle with OpenGL 3.3 core.

const std = @import("std");
const zcwl = @import("zcwl");
const gl = @import("opengl.zig");

const allocator = std.heap.page_allocator;

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.iterateAllocator(init.minimal.args, allocator);
    defer args.deinit();
    const argv0 = args.next() orelse return error.MissingExecutablePath;
    const self_path = try executablePath(allocator, init.io, argv0);
    defer allocator.free(self_path);

    const app = try zcwl.App.init(allocator, .{
        .application_id = "org.zcwl.example.triangle",
        .reporter = .{
            .error_fn = reportError,
            .info_fn = reportInfo,
        },
    });
    defer app.uninit();

    const window = try app.createWindow(.{
        .title = "zcwl triangle",
        .size = .{ .w = 800, .h = 600 },
        .client_api = .opengl,
    });
    defer window.destroy();

    // The window reserves .opengl, so the context must request the same API.
    const context = try window.createContext(.{
        .api = .opengl,
        .major = 3,
        .minor = 3,
        .profile = .core,
    }, null);
    defer window.destroyContext();

    try context.makeCurrent();
    var renderer = try Renderer.init(context);
    defer renderer.deinit();

    window.setImeAllowed(true) catch |err| {
        std.log.warn("IME unavailable: {s}", .{@errorName(err)});
    };
    updateImeArea(window);

    std.log.info("triangle window ready (backend={s}) \n      title = ({s})", .{
        @tagName(app.getBackendInfo().effective),
        window.getTitle(),
    });

    var running = true;
    var mouse_x: f32 = 0;
    var mouse_y: f32 = 0;
    var dragging_self = false;
    var event: zcwl.Event.Core = .none;
    while (running) {
        while (app.pollEvent(&event)) {
            switch (event) {
                .none => {},
                .window_should_close => |e| {
                    std.log.info("window_should_close window={d}", .{e.window_id});
                    running = false;
                },
                .window_resized => |e| {
                    std.log.info("window_resized window={d} size={d}x{d}", .{ e.window_id, e.width, e.height });
                    updateImeArea(window);
                },
                .window_moved => |e| std.log.info("window_moved window={d} pos={d},{d}", .{ e.window_id, e.x, e.y }),
                .window_scale_changed => |e| std.log.info("window_scale_changed window={d} scale={d}", .{ e.window_id, e.scale }),
                .window_focus_gained => |e| {
                    std.log.info("window_focus_gained window={d}", .{e.window_id});
                    updateImeArea(window);
                },
                .window_focus_lost => |e| std.log.info("window_focus_lost window={d}", .{e.window_id}),
                .window_minimized => |e| std.log.info("window_minimized window={d}", .{e.window_id}),
                .window_maximized => |e| std.log.info("window_maximized window={d}", .{e.window_id}),
                .window_restored => |e| std.log.info("window_restored window={d}", .{e.window_id}),

                .key_down => |e| {
                    std.log.info(
                        "key_down window={d} key={s} repeat={} mods(shift={} ctrl={} alt={} super={})",
                        .{ e.window_id, @tagName(e.key), e.repeat, e.mods.shift, e.mods.control, e.mods.alt, e.mods.super },
                    );
                    if (e.key == zcwl.Event.KeyCode.v and e.mods.control and !e.repeat) {
                        logClipboard(app);
                    }
                },
                .key_up => |e| std.log.info(
                    "key_up window={d} key={s} mods(shift={} ctrl={} alt={} super={})",
                    .{ e.window_id, @tagName(e.key), e.mods.shift, e.mods.control, e.mods.alt, e.mods.super },
                ),
                .text_input => |e| std.log.info("text_input window={d} text='{s}'", .{ e.window_id, e.text }),

                .mouse_entered => |e| std.log.info("mouse_entered window={d}", .{e.window_id}),
                .mouse_left => |e| std.log.info("mouse_left window={d}", .{e.window_id}),
                .mouse_moved => |e| {
                    mouse_x = e.x;
                    mouse_y = e.y;
                    std.log.info("mouse_moved window={d} pos={d:.2},{d:.2}", .{ e.window_id, e.x, e.y });
                },
                .mouse_button_down => |e| {
                    std.log.info(
                        "mouse_button_down window={d} button={s} clicks={d}",
                        .{ e.window_id, @tagName(e.button), e.click_count },
                    );
                    if (e.button == .left and pointInTriangle(mouse_x, mouse_y, window.getSize())) {
                        std.log.info("dragging executable: {s}", .{self_path});
                        dragging_self = true;
                        setDragCursor(window, true);
                        window.startDragFiles(&.{self_path}) catch |err| {
                            dragging_self = false;
                            setDragCursor(window, false);
                            std.log.warn("startDragFiles failed: {s}", .{@errorName(err)});
                        };
                        if (dragging_self) setDragCursor(window, true);
                    }
                },
                .mouse_button_up => |e| {
                    std.log.info(
                        "mouse_button_up window={d} button={s}",
                        .{ e.window_id, @tagName(e.button) },
                    );
                    if (dragging_self) {
                        dragging_self = false;
                        setDragCursor(window, false);
                    }
                },
                .mouse_scrolled => |e| std.log.info("mouse_scrolled window={d} dx={d:.2} dy={d:.2}", .{ e.window_id, e.dx, e.dy }),

                .pen_entered => |e| std.log.info("pen_entered window={d} pen={d}", .{ e.window_id, e.pen_id }),
                .pen_left => |e| std.log.info("pen_left window={d} pen={d}", .{ e.window_id, e.pen_id }),
                .pen_down => |e| std.log.info("pen_down window={d} pen={d}", .{ e.window_id, e.pen_id }),
                .pen_up => |e| std.log.info("pen_up window={d} pen={d}", .{ e.window_id, e.pen_id }),
                .pen_moved => |e| std.log.info("pen_moved window={d} pen={d} pos={d:.2},{d:.2} pressure={d:.3}", .{ e.window_id, e.pen_id, e.x, e.y, e.pressure }),
                .pen_button_down => |e| std.log.info("pen_button_down window={d} pen={d} button={d}", .{ e.window_id, e.pen_id, e.button }),
                .pen_button_up => |e| std.log.info("pen_button_up window={d} pen={d} button={d}", .{ e.window_id, e.pen_id, e.button }),

                .drag_enter => |e| {
                    std.log.info(
                        "drag_enter window={d} pos={d:.2},{d:.2} mimes={d}",
                        .{ e.window_id, e.x, e.y, e.mimes.len },
                    );
                    if (dragging_self) setDragCursor(window, true);
                },
                .drag_motion => |e| std.log.info(
                    "drag_motion window={d} pos={d:.2},{d:.2}",
                    .{ e.window_id, e.x, e.y },
                ),
                .drag_leave => |e| {
                    std.log.info("drag_leave window={d}", .{e.window_id});
                    if (dragging_self) {
                        dragging_self = false;
                        setDragCursor(window, false);
                    }
                },
                .file_drop => |e| {
                    std.log.info(
                        "file_drop window={d} pos={d:.2},{d:.2} uris='{s}'",
                        .{ e.window_id, e.x, e.y, e.uris },
                    );
                    if (dragging_self) {
                        dragging_self = false;
                        setDragCursor(window, false);
                    }
                },

                .custom => |e| std.log.info("custom window={d} type={d}", .{ e.window_id, e.ev_type }),
                .unknown => std.log.info("unknown event", .{}),
            }
        }

        const fb = window.getFramebufferSize();
        if (fb.w > 0 and fb.h > 0) {
            renderer.draw(fb.w, fb.h);
            context.swapBuffers() catch |err| {
                // The null backend has no WouldBlock in its error set, so
                // compare by name instead of switching on the error value.
                if (std.mem.eql(u8, @errorName(err), "WouldBlock")) {} else return err;
            };
        }

        sleepMs(16);
    }
}

fn reportError(err: anyerror) void {
    std.log.err("zcwl error: {s}", .{@errorName(err)});
}

fn reportInfo(info: zcwl.General.SystemInfo) void {
    std.log.info("zcwl backend={s} os={s} arch={s}", .{
        info.backend,
        @tagName(info.os),
        @tagName(info.arch),
    });
}

fn sleepMs(ms: u64) void {
    _ = std.posix.poll(&[_]std.posix.pollfd{}, @intCast(ms)) catch {};
}

fn updateImeArea(window: *zcwl.Window) void {
    const size = window.getSize();
    if (size.w == 0 or size.h == 0) return;
    window.setImeCursorArea(
        .{ .x = @intCast(size.w / 2), .y = @intCast(size.h / 2) },
        .{ .w = 1, .h = 1 },
    ) catch |err| {
        std.log.warn("setImeCursorArea failed: {s}", .{@errorName(err)});
    };
}
const vertex_shader_gl: [:0]const u8 =
    \\#version 330 core
    \\in vec2 a_pos;
    \\in vec3 a_color;
    \\out vec3 v_color;
    \\void main() {
    \\    gl_Position = vec4(a_pos, 0.0, 1.0);
    \\    v_color = a_color;
    \\}
;

const fragment_shader_gl: [:0]const u8 =
    \\#version 330 core
    \\in vec3 v_color;
    \\out vec4 frag_color;
    \\void main() {
    \\    frag_color = vec4(v_color, 1.0);
    \\}
;

const vertex_shader_es: [:0]const u8 =
    \\#version 300 es
    \\in vec2 a_pos;
    \\in vec3 a_color;
    \\out vec3 v_color;
    \\void main() {
    \\    gl_Position = vec4(a_pos, 0.0, 1.0);
    \\    v_color = a_color;
    \\}
;

const fragment_shader_es: [:0]const u8 =
    \\#version 300 es
    \\precision mediump float;
    \\in vec3 v_color;
    \\out vec4 frag_color;
    \\void main() {
    \\    frag_color = vec4(v_color, 1.0);
    \\}
;

pub const Renderer = struct {
    gl: gl.Gl,
    is_es: bool,
    program: gl.GLuint = 0,
    vao: gl.GLuint = 0,
    vbo: gl.GLuint = 0,

    pub fn init(ctx: *zcwl.Context) !Renderer {
        var self = Renderer{
            .gl = undefined,
            .is_es = ctx.getKind() == .opengles,
        };
        self.gl = try gl.Gl.load(ctx);
        errdefer self.deinit();
        try self.build();
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        if (self.program != 0) self.gl.deleteProgram(self.program);
        if (self.vbo != 0) self.gl.deleteBuffers(1, &self.vbo);
        if (self.vao != 0) self.gl.deleteVertexArrays(1, &self.vao);
        self.program = 0;
        self.vbo = 0;
        self.vao = 0;
    }

    pub fn draw(self: *Renderer, width: u32, height: u32) void {
        if (width == 0 or height == 0) return;
        self.gl.viewport(0, 0, @intCast(width), @intCast(height));
        self.gl.clearColor(0.08, 0.09, 0.12, 0.2);
        self.gl.clear(gl.GL_COLOR_BUFFER_BIT);
        self.gl.useProgram(self.program);
        self.gl.bindVertexArray(self.vao);
        self.gl.drawArrays(gl.GL_TRIANGLES, 0, 3);
    }

    fn build(self: *Renderer) !void {
        const vs_source = if (self.is_es) vertex_shader_es else vertex_shader_gl;
        const fs_source = if (self.is_es) fragment_shader_es else fragment_shader_gl;

        const vertex = try self.compile(gl.GL_VERTEX_SHADER, vs_source);
        defer self.gl.deleteShader(vertex);
        const fragment = try self.compile(gl.GL_FRAGMENT_SHADER, fs_source);
        defer self.gl.deleteShader(fragment);

        const program = self.gl.createProgram();
        if (program == 0) return error.CreateProgramFailed;
        self.program = program;

        self.gl.attachShader(program, vertex);
        self.gl.attachShader(program, fragment);
        self.gl.bindAttribLocation(program, 0, "a_pos");
        self.gl.bindAttribLocation(program, 1, "a_color");
        self.gl.linkProgram(program);

        var linked: gl.GLint = 0;
        self.gl.getProgramiv(program, gl.GL_LINK_STATUS, &linked);
        if (linked == 0) {
            self.logProgramError(program);
            return error.LinkProgramFailed;
        }

        const vertices = [_]gl.GLfloat{
            -0.6, -0.5, 1.0, 0.2, 0.2,
            0.6,  -0.5, 0.2, 1.0, 0.3,
            0.0,  0.6,  0.2, 0.4, 1.0,
        };
        self.gl.genVertexArrays(1, &self.vao);
        self.gl.bindVertexArray(self.vao);
        self.gl.genBuffers(1, &self.vbo);
        self.gl.bindBuffer(gl.GL_ARRAY_BUFFER, self.vbo);
        self.gl.bufferData(gl.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(vertices)), &vertices, gl.GL_STATIC_DRAW);

        const stride: gl.GLsizei = 5 * @sizeOf(gl.GLfloat);
        self.gl.vertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, stride, null);
        self.gl.enableVertexAttribArray(0);
        self.gl.vertexAttribPointer(1, 3, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(2 * @sizeOf(gl.GLfloat)));
        self.gl.enableVertexAttribArray(1);
    }

    fn compile(self: *Renderer, kind: gl.GLenum, source: [:0]const u8) !gl.GLuint {
        const shader = self.gl.createShader(kind);
        if (shader == 0) return error.CreateShaderFailed;
        errdefer self.gl.deleteShader(shader);

        var sources = [_][*c]const gl.GLchar{source.ptr};
        self.gl.shaderSource(shader, 1, &sources, null);
        self.gl.compileShader(shader);

        var compiled: gl.GLint = 0;
        self.gl.getShaderiv(shader, gl.GL_COMPILE_STATUS, &compiled);
        if (compiled == 0) {
            self.logShaderError(shader);
            return error.CompileShaderFailed;
        }
        return shader;
    }

    fn logShaderError(self: *Renderer, shader: gl.GLuint) void {
        var buf: [1024]u8 = undefined;
        var len: gl.GLsizei = 0;
        self.gl.getShaderInfoLog(shader, buf.len, &len, &buf);
        std.log.err("shader compile failed: {s}", .{buf[0..@intCast(len)]});
    }

    fn logProgramError(self: *Renderer, program: gl.GLuint) void {
        var buf: [1024]u8 = undefined;
        var len: gl.GLsizei = 0;
        self.gl.getProgramInfoLog(program, buf.len, &len, &buf);
        std.log.err("program link failed: {s}", .{buf[0..@intCast(len)]});
    }
};

fn executablePath(alloc: std.mem.Allocator, io: std.Io, argv0: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(argv0)) return alloc.dupe(u8, argv0);
    const cwd = try std.process.currentPathAlloc(io, alloc);
    defer alloc.free(cwd);
    return std.fs.path.resolveAlloc(alloc, &.{ cwd, argv0 });
}

fn setDragCursor(window: *zcwl.Window, active: bool) void {
    if (active) {
        window.setCursor(.grabbing) catch |err| {
            std.log.warn("set grabbing cursor failed: {s}", .{@errorName(err)});
        };
    } else {
        window.setCursor(.arrow) catch |err| {
            std.log.warn("restore cursor failed: {s}", .{@errorName(err)});
        };
    }
}

fn triangleEdge(ax: f32, ay: f32, bx: f32, by: f32, px: f32, py: f32) f32 {
    return (px - ax) * (by - ay) - (py - ay) * (bx - ax);
}

fn pointInTriangle(x: f32, y: f32, size: zcwl.General.Size) bool {
    if (size.w == 0 or size.h == 0) return false;
    const px = (x / @as(f32, @floatFromInt(size.w))) * 2.0 - 1.0;
    const py = 1.0 - (y / @as(f32, @floatFromInt(size.h))) * 2.0;

    const ax: f32 = -0.6;
    const ay: f32 = -0.5;
    const bx: f32 = 0.6;
    const by: f32 = -0.5;
    const cx: f32 = 0.0;
    const cy: f32 = 0.6;

    const d1 = triangleEdge(ax, ay, bx, by, px, py);
    const d2 = triangleEdge(bx, by, cx, cy, px, py);
    const d3 = triangleEdge(cx, cy, ax, ay, px, py);

    const has_neg = d1 < 0 or d2 < 0 or d3 < 0;
    const has_pos = d1 > 0 or d2 > 0 or d3 > 0;
    return !(has_neg and has_pos);
}

fn freeMimeList(mimes: [][]u8) void {
    for (mimes) |mime| allocator.free(mime);
    allocator.free(mimes);
}

fn joinMimes(mimes: []const []u8, alloc: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (mimes, 0..) |mime, i| {
        if (i != 0) try out.appendSlice(alloc, ", ");
        try out.appendSlice(alloc, mime);
    }
    return out.toOwnedSlice(alloc);
}

fn logClipboard(app: *zcwl.App) void {
    const mimes_opt = app.getClipboardMimeTypes(allocator) catch |err| {
        std.log.warn("clipboard unavailable: {s}", .{@errorName(err)});
        return;
    };
    const mimes = mimes_opt orelse {
        std.log.info("clipboard is empty", .{});
        return;
    };
    defer freeMimeList(mimes);

    // One paste = one line. The clipboard often advertises several aliases for
    // the same payload; join all aliases into one array-like list and show the
    // first readable representation's metadata.
    const joined = joinMimes(mimes, allocator) catch |err| {
        std.log.warn("clipboard mime list unavailable: {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(joined);

    var selected_mime: ?[]const u8 = null;
    var selected_data: ?[]u8 = null;
    var last_error: ?anyerror = null;
    for (mimes) |mime| {
        const data_opt = app.getClipboardData(mime, allocator) catch |err| {
            last_error = err;
            continue;
        };
        if (data_opt) |data| {
            selected_mime = mime;
            selected_data = data;
            break;
        }
    }
    defer {
        if (selected_data) |data| allocator.free(data);
    }

    if (selected_mime) |mime| {
        const data = selected_data orelse return;
        const prefix_len: usize = if (data.len < 4) data.len else 4;
        const prefix = data[0..prefix_len];

        std.log.info(
            "clipboard mimes=[{s}] data_mime={s} bytes={d} first4={s}",
            .{ joined, mime, data.len, prefix },
        );
    } else if (last_error) |err| {
        std.log.warn("clipboard mimes=[{s}] error={s}", .{ joined, @errorName(err) });
    } else {
        std.log.info("clipboard mimes=[{s}] no readable data", .{joined});
    }
}
