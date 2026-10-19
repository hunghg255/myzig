//! OpenGL, loaded when the first renderer is made: no headers and no
//! libraries at build time. Each function is looked up by its field's name
//! through libepoxy, which GTK 3 links and which finds the function of
//! whichever context is current (GLX or EGL, OpenGL or OpenGL ES), or, without
//! it, through EGL's or GLX's `GetProcAddress`.
const std = @import("std");

pub const Enum = u32;

pub const Api = struct {
    glGetString: *const fn (name: Enum) callconv(.c) ?[*:0]const u8,
    glGetError: *const fn () callconv(.c) Enum,
    glGetIntegerv: *const fn (name: Enum, out: *i32) callconv(.c) void,
    glCreateShader: *const fn (kind: Enum) callconv(.c) u32,
    glShaderSource: *const fn (shader: u32, count: i32, sources: [*]const [*]const u8, lengths: ?[*]const i32) callconv(.c) void,
    glCompileShader: *const fn (shader: u32) callconv(.c) void,
    glGetShaderiv: *const fn (shader: u32, name: Enum, out: *i32) callconv(.c) void,
    glGetShaderInfoLog: *const fn (shader: u32, size: i32, len: ?*i32, log: [*]u8) callconv(.c) void,
    glDeleteShader: *const fn (shader: u32) callconv(.c) void,
    glCreateProgram: *const fn () callconv(.c) u32,
    glAttachShader: *const fn (program: u32, shader: u32) callconv(.c) void,
    glBindAttribLocation: *const fn (program: u32, index: u32, name: [*:0]const u8) callconv(.c) void,
    glLinkProgram: *const fn (program: u32) callconv(.c) void,
    glGetProgramiv: *const fn (program: u32, name: Enum, out: *i32) callconv(.c) void,
    glGetProgramInfoLog: *const fn (program: u32, size: i32, len: ?*i32, log: [*]u8) callconv(.c) void,
    glUseProgram: *const fn (program: u32) callconv(.c) void,
    glDeleteProgram: *const fn (program: u32) callconv(.c) void,
    glGetUniformLocation: *const fn (program: u32, name: [*:0]const u8) callconv(.c) i32,
    glUniform1i: *const fn (location: i32, v: i32) callconv(.c) void,
    glUniform3f: *const fn (location: i32, x: f32, y: f32, z: f32) callconv(.c) void,
    glUniform4fv: *const fn (location: i32, count: i32, v: [*]const f32) callconv(.c) void,
    glDrawArrays: *const fn (mode: Enum, first: i32, count: i32) callconv(.c) void,
    glGenVertexArrays: *const fn (n: i32, out: *u32) callconv(.c) void,
    glBindVertexArray: *const fn (array: u32) callconv(.c) void,
    glDeleteVertexArrays: *const fn (n: i32, arrays: *const u32) callconv(.c) void,
    glGenBuffers: *const fn (n: i32, out: *u32) callconv(.c) void,
    glBindBuffer: *const fn (target: Enum, buffer: u32) callconv(.c) void,
    glBufferData: *const fn (target: Enum, size: isize, data: ?*const anyopaque, usage: Enum) callconv(.c) void,
    glBufferSubData: *const fn (target: Enum, offset: isize, size: isize, data: *const anyopaque) callconv(.c) void,
    glDeleteBuffers: *const fn (n: i32, buffers: *const u32) callconv(.c) void,
    glEnableVertexAttribArray: *const fn (index: u32) callconv(.c) void,
    glVertexAttribPointer: *const fn (index: u32, size: i32, kind: Enum, normalized: u8, stride: i32, offset: usize) callconv(.c) void,
    glVertexAttribDivisor: *const fn (index: u32, divisor: u32) callconv(.c) void,
    glGenTextures: *const fn (n: i32, out: *u32) callconv(.c) void,
    glBindTexture: *const fn (target: Enum, texture: u32) callconv(.c) void,
    glActiveTexture: *const fn (unit: Enum) callconv(.c) void,
    glTexImage2D: *const fn (target: Enum, level: i32, internal: i32, w: i32, h: i32, border: i32, format: Enum, kind: Enum, pixels: ?*const anyopaque) callconv(.c) void,
    glTexSubImage2D: *const fn (target: Enum, level: i32, x: i32, y: i32, w: i32, h: i32, format: Enum, kind: Enum, pixels: *const anyopaque) callconv(.c) void,
    glTexParameteri: *const fn (target: Enum, name: Enum, v: i32) callconv(.c) void,
    glDeleteTextures: *const fn (n: i32, textures: *const u32) callconv(.c) void,
    glPixelStorei: *const fn (name: Enum, v: i32) callconv(.c) void,
    glViewport: *const fn (x: i32, y: i32, w: i32, h: i32) callconv(.c) void,
    glScissor: *const fn (x: i32, y: i32, w: i32, h: i32) callconv(.c) void,
    glEnable: *const fn (cap: Enum) callconv(.c) void,
    glDisable: *const fn (cap: Enum) callconv(.c) void,
    glBlendFunc: *const fn (src: Enum, dst: Enum) callconv(.c) void,
    glClearColor: *const fn (r: f32, g: f32, b: f32, a: f32) callconv(.c) void,
    glClear: *const fn (mask: u32) callconv(.c) void,
    glDrawArraysInstanced: *const fn (mode: Enum, first: i32, count: i32, instances: i32) callconv(.c) void,
    glReadPixels: *const fn (x: i32, y: i32, w: i32, h: i32, format: Enum, kind: Enum, pixels: *anyopaque) callconv(.c) void,
    glGenFramebuffers: *const fn (n: i32, out: *u32) callconv(.c) void,
    glBindFramebuffer: *const fn (target: Enum, fb: u32) callconv(.c) void,
    glFramebufferTexture2D: *const fn (target: Enum, attachment: Enum, tex_target: Enum, texture: u32, level: i32) callconv(.c) void,
    glCheckFramebufferStatus: *const fn (target: Enum) callconv(.c) Enum,
    glDeleteFramebuffers: *const fn (n: i32, fbs: *const u32) callconv(.c) void,
    glBlitFramebuffer: *const fn (sx0: i32, sy0: i32, sx1: i32, sy1: i32, dx0: i32, dy0: i32, dx1: i32, dy1: i32, mask: u32, filter: Enum) callconv(.c) void,
};

pub var api: Api = undefined;
var loaded = false;

const GetProc = *const fn (name: [*:0]const u8) callconv(.c) ?*anyopaque;

/// Loads the functions; false when there is no OpenGL (or some is missing).
/// Called with a context current, which `GetProcAddress` may need.
pub fn load() bool {
    if (loaded) return true;
    const epoxy = std.c.dlopen("libepoxy.so.0", .{ .NOW = true, .GLOBAL = true });
    var get: ?GetProc = null;
    if (epoxy == null) {
        if (std.c.dlopen("libEGL.so.1", .{ .NOW = true, .GLOBAL = true })) |egl| {
            if (std.c.dlsym(egl, "eglGetProcAddress")) |p| get = @ptrCast(@alignCast(p));
        }
        if (get == null) if (std.c.dlopen("libGL.so.1", .{ .NOW = true, .GLOBAL = true })) |glx| {
            if (std.c.dlsym(glx, "glXGetProcAddressARB")) |p| get = @ptrCast(@alignCast(p));
        };
        if (get == null) return false;
    }
    inline for (@typeInfo(Api).@"struct".field_names) |name| {
        const sym: ?*anyopaque = if (epoxy) |e| blk: {
            // libepoxy exports a pointer to each function: a stub that
            // finds the current context's function when first called.
            const slot = std.c.dlsym(e, "epoxy_" ++ name) orelse break :blk null;
            break :blk @as(*const ?*anyopaque, @ptrCast(@alignCast(slot))).*;
        } else get.?(name);
        @field(api, name) = @ptrCast(@alignCast(sym orelse {
            std.log.info("myzig: OpenGL lacks {s}", .{name});
            return false;
        }));
    }
    loaded = true;
    return true;
}

/// Whether the current context is OpenGL ES (its version says so).
pub fn isES() bool {
    const v = api.glGetString(version) orelse return false;
    return std.mem.startsWith(u8, std.mem.span(v), "OpenGL ES");
}

// Enumerations.
pub const version = 0x1F02;
pub const renderer = 0x1F01;
pub const no_error = 0;
pub const vertex_shader = 0x8B31;
pub const fragment_shader = 0x8B30;
pub const compile_status = 0x8B81;
pub const link_status = 0x8B82;
pub const info_log_length = 0x8B84;
pub const array_buffer = 0x8892;
pub const stream_draw = 0x88E0;
pub const float = 0x1406;
pub const unsigned_byte = 0x1401;
pub const texture_2d = 0x0DE1;
pub const texture0 = 0x84C0;
pub const texture_min_filter = 0x2801;
pub const texture_mag_filter = 0x2800;
pub const texture_wrap_s = 0x2802;
pub const texture_wrap_t = 0x2803;
pub const nearest = 0x2600;
pub const clamp_to_edge = 0x812F;
pub const red = 0x1903;
pub const r8 = 0x8229;
pub const rgba = 0x1908;
pub const rgba8 = 0x8058;
pub const rgba32f = 0x8814;
pub const unpack_alignment = 0x0CF5;
pub const pack_alignment = 0x0D05;
pub const blend = 0x0BE2;
pub const scissor_test = 0x0C11;
pub const depth_test = 0x0B71;
pub const cull_face = 0x0B44;
pub const one = 1;
pub const one_minus_src_alpha = 0x0303;
pub const color_buffer_bit = 0x4000;
pub const triangle_strip = 0x0005;
pub const framebuffer = 0x8D40;
pub const read_framebuffer = 0x8CA8;
pub const draw_framebuffer = 0x8CA9;
pub const draw_framebuffer_binding = 0x8CA6;
pub const color_attachment0 = 0x8CE0;
pub const framebuffer_complete = 0x8CD5;
