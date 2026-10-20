//! The OpenGL renderer: one program, one instanced draw per frame, the
//! instances Metal and Direct3D draw (`gpu.zig`, `gl.glsl` after
//! `d3d11.hlsl`), into the framebuffer bound (a GtkGLArea's, on Linux) or
//! into an offscreen one. OpenGL 3.3 core or OpenGL ES 3.0, loaded at run
//! time (`gl_api.zig`). Its pixels are the CPU renderer's (`raster.zig`),
//! to a level or two of blending's rounding, so an area without OpenGL
//! shows the same frames drawn on the CPU (`linux/surface.zig`).
//!
//! A renderer belongs to the context current when it was made: every call
//! needs that context current.
const std = @import("std");
const gl = @import("gl_api.zig");
const gpu = @import("gpu.zig");
const types = @import("types.zig");
const raster = @import("raster.zig");
const images_mod = @import("images.zig");
const fx_mod = @import("gl_fx.zig");
const damage = @import("damage.zig");

pub const Instance = gpu.Instance;
pub const Pixels = gpu.Pixels;

const source = @import("shader_min.zig").minify(@embedFile("gl.glsl"));

pub const Renderer = struct {
    program: u32 = 0,
    vao: u32 = 0,
    buffer: u32 = 0,
    capacity: usize = 0,
    frame_loc: i32 = -1,
    /// The glyph atlas (R8) and the image atlas (BGRA bytes in RGBA), as uploaded.
    atlas: u32 = 0,
    atlas_size: u32 = 0,
    atlas_generation: u64 = std.math.maxInt(u64),
    images: u32 = 0,
    images_side: u32 = 0,
    images_generation: u64 = std.math.maxInt(u64),
    es: bool = false,
    /// The frame's rows (`gpu.Frame`), 1024 a texture row, RGBA floats.
    rows: u32 = 0,
    rows_height: i32 = 0,
    /// The first instance the attributes point at (0 but between the
    /// parts of a frame with effects).
    base: usize = 0,
    /// The passes of effects and blurred layers, made when first needed.
    fx: fx_mod.Passes = .{},
    /// A frame's instances with its large shadows with continuous corners
    /// cut into pieces (`gpu_corners.zig`), and their allocator.
    pieces: std.ArrayList(Instance) = .empty,
    gpa: std.mem.Allocator = std.heap.page_allocator,

    /// A renderer for the current context, or an error when it has no
    /// OpenGL 3.3 (or ES 3.0) or its shaders fail: the caller draws on the
    /// CPU then.
    pub fn init(gpa: std.mem.Allocator) !Renderer {
        if (!gl.load()) return error.NoOpenGL;
        const g = &gl.api;
        var self: Renderer = .{ .es = gl.isES(), .gpa = gpa };
        errdefer self.deinit();
        const vs = try compile(gpa, gl.vertex_shader, self.es);
        defer g.glDeleteShader(vs);
        const fs = try compile(gpa, gl.fragment_shader, self.es);
        defer g.glDeleteShader(fs);
        self.program = g.glCreateProgram();
        g.glAttachShader(self.program, vs);
        g.glAttachShader(self.program, fs);
        g.glLinkProgram(self.program);
        var ok: i32 = 0;
        g.glGetProgramiv(self.program, gl.link_status, &ok);
        if (ok == 0) {
            logInfo(gpa, self.program, g.glGetProgramiv, g.glGetProgramInfoLog);
            return error.ShaderLink;
        }
        g.glUseProgram(self.program);
        self.frame_loc = g.glGetUniformLocation(self.program, "frame");
        g.glUniform1i(g.glGetUniformLocation(self.program, "atlas"), 0);
        g.glUniform1i(g.glGetUniformLocation(self.program, "images"), 1);
        g.glUniform1i(g.glGetUniformLocation(self.program, "rows"), 2);

        // The instance's six vec4s, in `gpu.Instance`'s order, one per instance.
        comptime std.debug.assert(@sizeOf(Instance) == 96 and @offsetOf(Instance, "radius") == 80);
        g.glGenVertexArrays(1, &self.vao);
        g.glBindVertexArray(self.vao);
        g.glGenBuffers(1, &self.buffer);
        g.glBindBuffer(gl.array_buffer, self.buffer);
        for (0..6) |i| {
            const at: u32 = @intCast(i);
            g.glEnableVertexAttribArray(at);
            g.glVertexAttribPointer(at, 4, gl.float, 0, @sizeOf(Instance), i * 16);
            g.glVertexAttribDivisor(at, 1);
        }
        g.glBindVertexArray(0);
        if (g.glGetError() != gl.no_error) return error.OpenGL;
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        const g = &gl.api;
        self.fx.deinit();
        self.pieces.deinit(self.gpa);
        if (self.rows != 0) g.glDeleteTextures(1, &self.rows);
        if (self.atlas != 0) g.glDeleteTextures(1, &self.atlas);
        if (self.images != 0) g.glDeleteTextures(1, &self.images);
        if (self.buffer != 0) g.glDeleteBuffers(1, &self.buffer);
        if (self.vao != 0) g.glDeleteVertexArrays(1, &self.vao);
        if (self.program != 0) g.glDeleteProgram(self.program);
        self.* = .{};
    }

    /// The name of the context's renderer ("llvmpipe" for Mesa's on the CPU).
    pub fn name() []const u8 {
        const s = gl.api.glGetString(gl.renderer) orelse return "";
        return std.mem.span(s);
    }

    /// Brings the GPU's glyph atlas up to date: the rows that changed since
    /// the last sync (`Atlas.takeDirty`), or all of it when they are not
    /// known (null).
    pub fn syncAtlas(self: *Renderer, mask: raster.Mask, generation: u64, dirty: ?[2]u32) void {
        if (mask.size == 0) return;
        const g = &gl.api;
        const n: i32 = @intCast(mask.size);
        g.glPixelStorei(gl.unpack_alignment, 1);
        defer g.glPixelStorei(gl.unpack_alignment, 4);
        if (mask.size != self.atlas_size) {
            if (self.atlas != 0) g.glDeleteTextures(1, &self.atlas);
            self.atlas = texture(gl.r8, gl.red, n, mask.pixels.ptr);
            self.atlas_size = mask.size;
        } else if (generation != self.atlas_generation) {
            const rows: [2]u32 = dirty orelse .{ 0, mask.size };
            if (rows[1] > rows[0]) {
                g.glBindTexture(gl.texture_2d, self.atlas);
                g.glTexSubImage2D(gl.texture_2d, 0, 0, @intCast(rows[0]), n, @intCast(rows[1] - rows[0]), gl.red, gl.unsigned_byte, mask.pixels.ptr + @as(usize, rows[0]) * mask.size);
            }
        }
        self.atlas_generation = generation;
    }

    /// Brings the GPU's image atlas up to date: the rows that changed.
    pub fn syncImages(self: *Renderer, im: *images_mod.Images) void {
        if (im.pixels.len == 0 or im.generation == self.images_generation) return;
        const side: i32 = @intCast(im.side);
        const g = &gl.api;
        if (self.images == 0 or self.images_side != im.side) {
            if (self.images != 0) g.glDeleteTextures(1, &self.images);
            self.images = texture(gl.rgba8, gl.rgba, side, im.pixels.ptr);
            self.images_side = im.side;
        } else if (im.dirty) |rows| if (rows[1] > rows[0]) {
            g.glBindTexture(gl.texture_2d, self.images);
            const from = im.pixels.ptr + @as(usize, rows[0]) * im.side * 4;
            g.glTexSubImage2D(gl.texture_2d, 0, 0, @intCast(rows[0]), side, @intCast(rows[1] - rows[0]), gl.rgba, gl.unsigned_byte, from);
        };
        im.dirty = null;
        self.images_generation = im.generation;
    }

    /// Draws `instances` over `clear` into the framebuffer bound, `width` ×
    /// `height` pixels, `scale` pixels a point.
    pub fn draw(self: *Renderer, instances: []const Instance, scale: f32, width: u32, height: u32, clear: types.Color) !void {
        try self.drawPart(instances, scale, width, height, clear, null);
    }

    /// Draws `instances` as `draw` does, whole or only within `part`,
    /// keeping what the framebuffer holds elsewhere (`damage.zig`): the
    /// scissor test keeps the clear and the draws to the part, and only the
    /// effects and layers in it draw.
    pub fn drawPart(self: *Renderer, instances: []const Instance, scale: f32, width: u32, height: u32, clear: types.Color, part: ?damage.Box) !void {
        const g = &gl.api;
        const w: i32 = @intCast(@max(1, width));
        const h: i32 = @intCast(@max(1, height));
        g.glViewport(0, 0, w, h);
        g.glDisable(gl.scissor_test);
        g.glDisable(gl.depth_test);
        g.glDisable(gl.cull_face);
        g.glClearColor(clear.r, clear.g, clear.b, 1);
        if (part) |p| {
            // GL's rows go up.
            g.glEnable(gl.scissor_test);
            g.glScissor(p[0], h - p[3], p[2] - p[0], p[3] - p[1]);
        }
        g.glClear(gl.color_buffer_bit);
        const fr = gpu.Frame.of(@import("gpu_corners.zig").split(self.gpa, instances, scale, &self.pieces));
        if (fr.instances.len > 0) {
            self.upload(fr.instances);
            self.uploadRows(fr.rows);
            var target: i32 = 0;
            g.glGetIntegerv(gl.draw_framebuffer_binding, &target);
            const frame: fx_mod.Frame = .{ .fb = @intCast(target), .w = @intCast(w), .h = @intCast(h), .scale = scale };
            self.bindMain(frame, part);
            var markers: damage.Markers = .{ .part = part };
            var start: usize = 0;
            for (fr.instances, 0..) |*i, k| {
                if (!gpu.isMarker(i.kind)) continue;
                self.drawRange(start, k);
                if (markers.draws(i, @intCast(w), @intCast(h), scale)) {
                    self.fx.apply(self.es, frame, i, fr.rows);
                    self.bindMain(frame, part);
                }
                start = k + 1;
            }
            self.drawRange(start, fr.instances.len);
            g.glBindVertexArray(0);
            g.glActiveTexture(gl.texture0);
        }
        self.fx.endFrame();
        g.glDisable(gl.scissor_test);
        if (g.glGetError() != gl.no_error) return error.OpenGL;
    }

    /// A texture drawn into across frames, with its framebuffer: frames
    /// drawn in part, for tests.
    pub const Target = struct { tex: u32, fb: u32, w: u32, h: u32 };

    pub fn newTarget(_: *Renderer, w: u32, h: u32) !Target {
        const g = &gl.api;
        var t: Target = .{ .tex = 0, .fb = 0, .w = w, .h = h };
        g.glGenTextures(1, &t.tex);
        g.glBindTexture(gl.texture_2d, t.tex);
        g.glTexImage2D(gl.texture_2d, 0, gl.rgba8, @intCast(w), @intCast(h), 0, gl.rgba, gl.unsigned_byte, null);
        g.glGenFramebuffers(1, &t.fb);
        g.glBindFramebuffer(gl.framebuffer, t.fb);
        g.glFramebufferTexture2D(gl.framebuffer, gl.color_attachment0, gl.texture_2d, t.tex, 0);
        if (g.glCheckFramebufferStatus(gl.framebuffer) != gl.framebuffer_complete) return error.Framebuffer;
        return t;
    }

    pub fn freeTarget(_: *Renderer, t: *Target) void {
        const g = &gl.api;
        g.glDeleteFramebuffers(1, &t.fb);
        g.glDeleteTextures(1, &t.tex);
    }

    /// Draws into `t`, whole or only `part`, and reads it back.
    pub fn drawTarget(self: *Renderer, t: Target, instances: []const Instance, scale: f32, clear: types.Color, part: ?damage.Box) !void {
        gl.api.glBindFramebuffer(gl.framebuffer, t.fb);
        try self.drawPart(instances, scale, t.w, t.h, clear, part);
    }

    pub fn readTarget(_: *Renderer, gpa: std.mem.Allocator, t: Target) !Pixels {
        gl.api.glBindFramebuffer(gl.framebuffer, t.fb);
        return readFramebuffer(gpa, t.w, t.h);
    }

    /// Draws into a new offscreen framebuffer and returns its BGRA pixels,
    /// premultiplied, `width * 4` bytes per row: frames without a window.
    pub fn drawOffscreen(self: *Renderer, gpa: std.mem.Allocator, instances: []const Instance, size: types.Size, scale: f32, clear: types.Color) !Pixels {
        const w: u32 = @intFromFloat(@max(1, @round(size.w * scale)));
        const h: u32 = @intFromFloat(@max(1, @round(size.h * scale)));
        const g = &gl.api;
        var prev: i32 = 0;
        g.glGetIntegerv(gl.draw_framebuffer_binding, &prev);
        var tex: u32 = 0;
        g.glGenTextures(1, &tex);
        defer g.glDeleteTextures(1, &tex);
        g.glBindTexture(gl.texture_2d, tex);
        g.glTexImage2D(gl.texture_2d, 0, gl.rgba8, @intCast(w), @intCast(h), 0, gl.rgba, gl.unsigned_byte, null);
        var fb: u32 = 0;
        g.glGenFramebuffers(1, &fb);
        defer g.glDeleteFramebuffers(1, &fb);
        g.glBindFramebuffer(gl.framebuffer, fb);
        defer g.glBindFramebuffer(gl.framebuffer, @intCast(prev));
        g.glFramebufferTexture2D(gl.framebuffer, gl.color_attachment0, gl.texture_2d, tex, 0);
        if (g.glCheckFramebufferStatus(gl.framebuffer) != gl.framebuffer_complete) return error.Framebuffer;
        try self.draw(instances, scale, w, h, clear);
        return readFramebuffer(gpa, w, h);
    }

    /// The main program, drawing into the frame.
    fn bindMain(self: *Renderer, f: fx_mod.Frame, part: ?damage.Box) void {
        const g = &gl.api;
        g.glBindFramebuffer(gl.framebuffer, f.fb);
        g.glViewport(0, 0, @intCast(f.w), @intCast(f.h));
        if (part) |p| {
            g.glEnable(gl.scissor_test);
            g.glScissor(p[0], @as(i32, @intCast(f.h)) - p[3], p[2] - p[0], p[3] - p[1]);
        }
        g.glUseProgram(self.program);
        g.glUniform3f(self.frame_loc, @floatFromInt(f.w), @floatFromInt(f.h), f.scale);
        // Premultiplied alpha: one, one minus source alpha.
        g.glEnable(gl.blend);
        g.glBlendFunc(gl.one, gl.one_minus_src_alpha);
        g.glActiveTexture(gl.texture0);
        g.glBindTexture(gl.texture_2d, self.atlas);
        g.glActiveTexture(gl.texture0 + 1);
        g.glBindTexture(gl.texture_2d, self.images);
        g.glActiveTexture(gl.texture0 + 2);
        g.glBindTexture(gl.texture_2d, self.rows);
        g.glBindVertexArray(self.vao);
    }

    /// Draws instances [from, to): the attributes point at `from`.
    fn drawRange(self: *Renderer, from: usize, to: usize) void {
        if (to <= from) return;
        const g = &gl.api;
        if (self.base != from) {
            g.glBindBuffer(gl.array_buffer, self.buffer);
            for (0..6) |i| g.glVertexAttribPointer(@intCast(i), 4, gl.float, 0, @sizeOf(Instance), from * @sizeOf(Instance) + i * 16);
            self.base = from;
        }
        g.glDrawArraysInstanced(gl.triangle_strip, 0, 4, @intCast(to - from));
    }

    /// Copies a frame's rows into their texture, 1024 a texture row.
    fn uploadRows(self: *Renderer, rows: []const [4]f32) void {
        if (rows.len == 0) return;
        const g = &gl.api;
        const full: i32 = @intCast(rows.len / 1024);
        const rest: i32 = @intCast(rows.len % 1024);
        const height = full + @intFromBool(rest > 0);
        if (self.rows == 0) {
            g.glGenTextures(1, &self.rows);
            g.glBindTexture(gl.texture_2d, self.rows);
            inline for (.{ gl.texture_min_filter, gl.texture_mag_filter }) |p| g.glTexParameteri(gl.texture_2d, p, gl.nearest);
            inline for (.{ gl.texture_wrap_s, gl.texture_wrap_t }) |p| g.glTexParameteri(gl.texture_2d, p, gl.clamp_to_edge);
        } else g.glBindTexture(gl.texture_2d, self.rows);
        if (height > self.rows_height) {
            self.rows_height = @max(height, self.rows_height * 2, 1);
            g.glTexImage2D(gl.texture_2d, 0, gl.rgba32f, 1024, self.rows_height, 0, gl.rgba, gl.float, null);
        }
        if (full > 0) g.glTexSubImage2D(gl.texture_2d, 0, 0, 0, 1024, full, gl.rgba, gl.float, rows.ptr);
        if (rest > 0) g.glTexSubImage2D(gl.texture_2d, 0, 0, full, rest, 1, gl.rgba, gl.float, rows[@as(usize, @intCast(full)) * 1024 ..].ptr);
    }

    /// Copies `instances` into the instance buffer, grown as needed (and
    /// orphaned each frame, so the driver renames it rather than waiting).
    fn upload(self: *Renderer, instances: []const Instance) void {
        const g = &gl.api;
        const bytes = std.mem.sliceAsBytes(instances);
        g.glBindBuffer(gl.array_buffer, self.buffer);
        if (self.capacity < bytes.len) self.capacity = @max(bytes.len * 3 / 2, 64 * 1024);
        g.glBufferData(gl.array_buffer, @intCast(self.capacity), null, gl.stream_draw);
        g.glBufferSubData(gl.array_buffer, 0, @intCast(bytes.len), bytes.ptr);
    }
};

/// The bound framebuffer's pixels, `w` × `h`, as the CPU renderer draws
/// them: premultiplied BGRA rows from the top (GL's rows go up, its bytes
/// are RGBA).
pub fn readFramebuffer(gpa: std.mem.Allocator, w: u32, h: u32) !Pixels {
    const g = &gl.api;
    const row = @as(usize, w) * 4;
    const bytes = try gpa.alloc(u8, row * h);
    errdefer gpa.free(bytes);
    const tmp = try gpa.alloc(u8, row * h);
    defer gpa.free(tmp);
    g.glPixelStorei(gl.pack_alignment, 1);
    g.glReadPixels(0, 0, @intCast(w), @intCast(h), gl.rgba, gl.unsigned_byte, tmp.ptr);
    g.glPixelStorei(gl.pack_alignment, 4);
    if (g.glGetError() != gl.no_error) return error.ReadPixels;
    for (0..h) |y| swizzle(bytes[y * row ..][0..row], tmp[(h - 1 - y) * row ..][0..row]);
    return .{ .bytes = bytes, .width = w, .height = h };
}

/// RGBA to BGRA, or back.
fn swizzle(dst: []u8, src: []const u8) void {
    var i: usize = 0;
    while (i < src.len) : (i += 4) dst[i..][0..4].* = .{ src[i + 2], src[i + 1], src[i], src[i + 3] };
}

/// A `side` × `side` texture sampled by texel, without mipmaps.
fn texture(internal: i32, format: gl.Enum, side: i32, pixels: [*]const u8) u32 {
    const g = &gl.api;
    var t: u32 = 0;
    g.glGenTextures(1, &t);
    g.glBindTexture(gl.texture_2d, t);
    inline for (.{ gl.texture_min_filter, gl.texture_mag_filter }) |p| g.glTexParameteri(gl.texture_2d, p, gl.nearest);
    inline for (.{ gl.texture_wrap_s, gl.texture_wrap_t }) |p| g.glTexParameteri(gl.texture_2d, p, gl.clamp_to_edge);
    g.glPixelStorei(gl.unpack_alignment, 1);
    g.glTexImage2D(gl.texture_2d, 0, internal, side, side, 0, format, gl.unsigned_byte, pixels);
    g.glPixelStorei(gl.unpack_alignment, 4);
    return t;
}

fn compile(gpa: std.mem.Allocator, kind: gl.Enum, es: bool) !u32 {
    const g = &gl.api;
    const version: []const u8 = if (es) "#version 300 es\n" else "#version 330 core\n";
    const stage: []const u8 = if (kind == gl.vertex_shader) "#define VERTEX 1\n" else "#define FRAGMENT 1\n";
    const parts = [3][*]const u8{ version.ptr, stage.ptr, source.ptr };
    const lens = [3]i32{ @intCast(version.len), @intCast(stage.len), @intCast(source.len) };
    const s = g.glCreateShader(kind);
    g.glShaderSource(s, 3, &parts, &lens);
    g.glCompileShader(s);
    var ok: i32 = 0;
    g.glGetShaderiv(s, gl.compile_status, &ok);
    if (ok == 0) {
        logInfo(gpa, s, g.glGetShaderiv, g.glGetShaderInfoLog);
        g.glDeleteShader(s);
        return error.ShaderCompile;
    }
    return s;
}

fn logInfo(gpa: std.mem.Allocator, obj: u32, get: anytype, read: anytype) void {
    var n: i32 = 0;
    get(obj, gl.info_log_length, &n);
    if (n <= 1) return;
    const buf = gpa.alloc(u8, @intCast(n)) catch return;
    defer gpa.free(buf);
    read(obj, n, null, buf.ptr);
    std.log.warn("myzig: OpenGL: {s}", .{std.mem.trimEnd(u8, buf[0 .. buf.len - 1], " \n\r\x00")});
}

/// Shows frames drawn in memory (on the CPU) in the framebuffer bound: what
/// a GtkGLArea shows when the renderer cannot draw there, as GTK shows only
/// what OpenGL draws into a GtkGLArea. Belongs to one context, as a renderer.
pub const Presenter = struct {
    tex: u32 = 0,
    fb: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    rgba: []u8 = &.{},

    pub fn deinit(p: *Presenter, gpa: std.mem.Allocator) void {
        if (gl.load()) {
            if (p.tex != 0) gl.api.glDeleteTextures(1, &p.tex);
            if (p.fb != 0) gl.api.glDeleteFramebuffers(1, &p.fb);
        }
        gpa.free(p.rgba);
        p.* = .{};
    }

    /// Copies premultiplied BGRA pixels, `w` × `h`, rows from the top, into
    /// the bound framebuffer, which is that size.
    pub fn present(p: *Presenter, gpa: std.mem.Allocator, pixels: []const u8, w: u32, h: u32) !void {
        if (!gl.load()) return error.NoOpenGL;
        const g = &gl.api;
        const n = @as(usize, w) * h * 4;
        if (w == 0 or h == 0 or pixels.len < n) return;
        if (p.rgba.len != n) {
            gpa.free(p.rgba);
            p.rgba = &.{};
            p.rgba = try gpa.alloc(u8, n);
        }
        swizzle(p.rgba, pixels[0..n]);
        var target: i32 = 0;
        g.glGetIntegerv(gl.draw_framebuffer_binding, &target);
        if (p.tex == 0 or p.w != w or p.h != h) {
            if (p.tex != 0) g.glDeleteTextures(1, &p.tex);
            g.glGenTextures(1, &p.tex);
            g.glBindTexture(gl.texture_2d, p.tex);
            g.glTexImage2D(gl.texture_2d, 0, gl.rgba8, @intCast(w), @intCast(h), 0, gl.rgba, gl.unsigned_byte, null);
            if (p.fb == 0) g.glGenFramebuffers(1, &p.fb);
            g.glBindFramebuffer(gl.read_framebuffer, p.fb);
            g.glFramebufferTexture2D(gl.read_framebuffer, gl.color_attachment0, gl.texture_2d, p.tex, 0);
            p.w = w;
            p.h = h;
        }
        g.glBindTexture(gl.texture_2d, p.tex);
        g.glPixelStorei(gl.unpack_alignment, 1);
        g.glTexSubImage2D(gl.texture_2d, 0, 0, 0, @intCast(w), @intCast(h), gl.rgba, gl.unsigned_byte, p.rgba.ptr);
        g.glPixelStorei(gl.unpack_alignment, 4);
        g.glBindFramebuffer(gl.read_framebuffer, p.fb);
        g.glBindFramebuffer(gl.draw_framebuffer, @intCast(target));
        g.glDisable(gl.scissor_test);
        // Rows go down in memory and up in GL: the copy flips them.
        const wi: i32 = @intCast(w);
        const hi: i32 = @intCast(h);
        g.glBlitFramebuffer(0, 0, wi, hi, 0, hi, wi, 0, gl.color_buffer_bit, gl.nearest);
        g.glBindFramebuffer(gl.framebuffer, @intCast(target));
        if (g.glGetError() != gl.no_error) return error.OpenGL;
    }
};
