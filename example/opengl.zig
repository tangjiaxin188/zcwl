//! Minimal OpenGL / OpenGL ES wrapper for the triangle example.
//!
//! It loads only the entry points needed to draw one triangle through
//! `zcwl.Context.getProcAddress`, so it does not link against libGL and works
//! with either a desktop GL or a GLES context.
const std = @import("std");
const zcwl = @import("zcwl");

pub const GLuint = u32;
pub const GLint = i32;
pub const GLenum = u32;
pub const GLsizei = i32;
pub const GLfloat = f32;
pub const GLboolean = u8;
pub const GLbitfield = u32;
pub const GLchar = u8;

pub const GL_ARRAY_BUFFER: GLenum = 0x8892;
pub const GL_STATIC_DRAW: GLenum = 0x88E4;
pub const GL_FLOAT: GLenum = 0x1406;
pub const GL_FALSE: GLboolean = 0;
pub const GL_TRIANGLES: GLenum = 0x0004;
pub const GL_COLOR_BUFFER_BIT: GLbitfield = 0x00004000;
pub const GL_VERTEX_SHADER: GLenum = 0x8B31;
pub const GL_FRAGMENT_SHADER: GLenum = 0x8B30;
pub const GL_COMPILE_STATUS: GLenum = 0x8B81;
pub const GL_LINK_STATUS: GLenum = 0x8B82;

const Viewport = *const fn (GLint, GLint, GLsizei, GLsizei) callconv(.c) void;
const ClearColor = *const fn (GLfloat, GLfloat, GLfloat, GLfloat) callconv(.c) void;
const Clear = *const fn (GLbitfield) callconv(.c) void;
const GenVertexArrays = *const fn (GLsizei, [*c]GLuint) callconv(.c) void;
const BindVertexArray = *const fn (GLuint) callconv(.c) void;
const DeleteVertexArrays = *const fn (GLsizei, [*c]const GLuint) callconv(.c) void;
const GenBuffers = *const fn (GLsizei, [*c]GLuint) callconv(.c) void;
const BindBuffer = *const fn (GLenum, GLuint) callconv(.c) void;
const BufferData = *const fn (GLenum, isize, ?*const anyopaque, GLenum) callconv(.c) void;
const DeleteBuffers = *const fn (GLsizei, [*c]const GLuint) callconv(.c) void;
const VertexAttribPointer = *const fn (GLuint, GLint, GLenum, GLboolean, GLsizei, ?*const anyopaque) callconv(.c) void;
const EnableVertexAttribArray = *const fn (GLuint) callconv(.c) void;
const CreateShader = *const fn (GLenum) callconv(.c) GLuint;
const ShaderSource = *const fn (GLuint, GLsizei, [*c]const [*c]const GLchar, [*c]const GLint) callconv(.c) void;
const CompileShader = *const fn (GLuint) callconv(.c) void;
const GetShaderiv = *const fn (GLuint, GLenum, [*c]GLint) callconv(.c) void;
const GetShaderInfoLog = *const fn (GLuint, GLsizei, [*c]GLsizei, [*c]GLchar) callconv(.c) void;
const DeleteShader = *const fn (GLuint) callconv(.c) void;
const CreateProgram = *const fn () callconv(.c) GLuint;
const AttachShader = *const fn (GLuint, GLuint) callconv(.c) void;
const BindAttribLocation = *const fn (GLuint, GLuint, [*c]const GLchar) callconv(.c) void;
const LinkProgram = *const fn (GLuint) callconv(.c) void;
const GetProgramiv = *const fn (GLuint, GLenum, [*c]GLint) callconv(.c) void;
const GetProgramInfoLog = *const fn (GLuint, GLsizei, [*c]GLsizei, [*c]GLchar) callconv(.c) void;
const UseProgram = *const fn (GLuint) callconv(.c) void;
const DrawArrays = *const fn (GLenum, GLint, GLsizei) callconv(.c) void;
const DeleteProgram = *const fn (GLuint) callconv(.c) void;
pub const Gl = struct {
    viewport: Viewport,
    clearColor: ClearColor,
    clear: Clear,
    genVertexArrays: GenVertexArrays,
    bindVertexArray: BindVertexArray,
    deleteVertexArrays: DeleteVertexArrays,
    genBuffers: GenBuffers,
    bindBuffer: BindBuffer,
    bufferData: BufferData,
    deleteBuffers: DeleteBuffers,
    vertexAttribPointer: VertexAttribPointer,
    enableVertexAttribArray: EnableVertexAttribArray,
    createShader: CreateShader,
    shaderSource: ShaderSource,
    compileShader: CompileShader,
    getShaderiv: GetShaderiv,
    getShaderInfoLog: GetShaderInfoLog,
    deleteShader: DeleteShader,
    createProgram: CreateProgram,
    attachShader: AttachShader,
    bindAttribLocation: BindAttribLocation,
    linkProgram: LinkProgram,
    getProgramiv: GetProgramiv,
    getProgramInfoLog: GetProgramInfoLog,
    useProgram: UseProgram,
    drawArrays: DrawArrays,
    deleteProgram: DeleteProgram,

    pub fn load(ctx: *zcwl.Context) !Gl {
        return .{
            .viewport = try loadProc(Viewport, ctx, "glViewport"),
            .clearColor = try loadProc(ClearColor, ctx, "glClearColor"),
            .clear = try loadProc(Clear, ctx, "glClear"),
            .genVertexArrays = try loadProc(GenVertexArrays, ctx, "glGenVertexArrays"),
            .bindVertexArray = try loadProc(BindVertexArray, ctx, "glBindVertexArray"),
            .deleteVertexArrays = try loadProc(DeleteVertexArrays, ctx, "glDeleteVertexArrays"),
            .genBuffers = try loadProc(GenBuffers, ctx, "glGenBuffers"),
            .bindBuffer = try loadProc(BindBuffer, ctx, "glBindBuffer"),
            .bufferData = try loadProc(BufferData, ctx, "glBufferData"),
            .deleteBuffers = try loadProc(DeleteBuffers, ctx, "glDeleteBuffers"),
            .vertexAttribPointer = try loadProc(VertexAttribPointer, ctx, "glVertexAttribPointer"),
            .enableVertexAttribArray = try loadProc(EnableVertexAttribArray, ctx, "glEnableVertexAttribArray"),
            .createShader = try loadProc(CreateShader, ctx, "glCreateShader"),
            .shaderSource = try loadProc(ShaderSource, ctx, "glShaderSource"),
            .compileShader = try loadProc(CompileShader, ctx, "glCompileShader"),
            .getShaderiv = try loadProc(GetShaderiv, ctx, "glGetShaderiv"),
            .getShaderInfoLog = try loadProc(GetShaderInfoLog, ctx, "glGetShaderInfoLog"),
            .deleteShader = try loadProc(DeleteShader, ctx, "glDeleteShader"),
            .createProgram = try loadProc(CreateProgram, ctx, "glCreateProgram"),
            .attachShader = try loadProc(AttachShader, ctx, "glAttachShader"),
            .bindAttribLocation = try loadProc(BindAttribLocation, ctx, "glBindAttribLocation"),
            .linkProgram = try loadProc(LinkProgram, ctx, "glLinkProgram"),
            .getProgramiv = try loadProc(GetProgramiv, ctx, "glGetProgramiv"),
            .getProgramInfoLog = try loadProc(GetProgramInfoLog, ctx, "glGetProgramInfoLog"),
            .useProgram = try loadProc(UseProgram, ctx, "glUseProgram"),
            .drawArrays = try loadProc(DrawArrays, ctx, "glDrawArrays"),
            .deleteProgram = try loadProc(DeleteProgram, ctx, "glDeleteProgram"),
        };
    }
};

fn loadProc(comptime T: type, ctx: *zcwl.Context, name: [:0]const u8) !T {
    const proc = ctx.getProcAddress(name.ptr) orelse return error.MissingGlSymbol;
    return @ptrCast(proc);
}
