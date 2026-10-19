//! Backdrop effects and blurred layers on OpenGL: `d3d11_fx.zig`'s passes
//! (the CPU renderer's steps, `raster_fx.zig`) with framebuffers, drawn
//! between the parts of a frame (`gl.zig`'s `draw`). The frame drawn into
//! counts rows from the bottom; the passes' textures hold them from the
//! top, as the CPU's pixels do, so copies between them flip. The passes'
//! programs (`gl_fx.glsl`, and each effect's) are made when first needed.
const std = @import("std");
const gl = @import("gl_api.zig");
const gpu = @import("gpu.zig");
const effect = @import("effect.zig");
const backdrop = @import("backdrop.zig");
const raster_fx = @import("raster_fx.zig");

const gpa = std.heap.page_allocator;
pub const source = @import("shader_min.zig").minify(@embedFile("gl_fx.glsl"));

/// The effect pass's entry, after the effect's `effect_color`.
pub const effect_main =
    \\
    \\void main() {
    \\    EffectIn i = effect_in();
    \\    float cov = effect_cover(i);
    \\    if (cov <= 0.0) discard;
    \\    // Rounded as the CPU rounds where the shape covers the pixel whole.
    \\    vec3 c = floor(clamp(effect_color(i), 0.0, 1.0) * 255.0 + 0.5) / 255.0;
    \\    out_color = vec4(c * cov, cov);
    \\}
    \\
;

/// The backdrop as it is: an effect without a shader.
pub const plain_color =
    \\
    \\vec3 effect_color(EffectIn i) { return backdrop_at(i, i.p); }
;

/// The passes' uniforms (`fx` in `gl_fx.glsl`).
const Constants = extern struct {
    area: [4]f32 = @splat(0),
    info: [4]f32 = @splat(0),
    dir: [4]f32 = @splat(0),
    shape: [4]f32 = @splat(0),
    shape2: [4]f32 = @splat(0),
    clip: [4]f32 = @splat(0),
    params: [4][4]f32 = @splat(@splat(0)),
    origin: [4]f32 = @splat(0),
    target: [4]f32 = @splat(0),
};

/// A texture drawn into and read, and its framebuffer.
const Tex = struct {
    tex: u32 = 0,
    fb: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,

    fn init(w: u32, h: u32) Tex {
        const g = &gl.api;
        var t: Tex = .{ .w = @max(w, 1), .h = @max(h, 1) };
        g.glGenTextures(1, &t.tex);
        g.glBindTexture(gl.texture_2d, t.tex);
        inline for (.{ gl.texture_min_filter, gl.texture_mag_filter }) |p| g.glTexParameteri(gl.texture_2d, p, gl.nearest);
        inline for (.{ gl.texture_wrap_s, gl.texture_wrap_t }) |p| g.glTexParameteri(gl.texture_2d, p, gl.clamp_to_edge);
        g.glTexImage2D(gl.texture_2d, 0, gl.rgba8, @intCast(t.w), @intCast(t.h), 0, gl.rgba, gl.unsigned_byte, null);
        g.glGenFramebuffers(1, &t.fb);
        g.glBindFramebuffer(gl.framebuffer, t.fb);
        g.glFramebufferTexture2D(gl.framebuffer, gl.color_attachment0, gl.texture_2d, t.tex, 0);
        return t;
    }

    fn deinit(t: *Tex) void {
        const g = &gl.api;
        if (t.fb != 0) g.glDeleteFramebuffers(1, &t.fb);
        if (t.tex != 0) g.glDeleteTextures(1, &t.tex);
        t.* = .{};
    }
};

const Program = struct {
    id: u32 = 0,
    fx: i32 = -1,

    fn deinit(p: *Program) void {
        if (p.id != 0) gl.api.glDeleteProgram(p.id);
        p.* = .{};
    }
};

const Saved = struct { tex: Tex, area: [4]usize };

/// The passes' textures, kept from frame to frame by their size (as
/// `d3d11_fx.zig`'s): an effect or a layer whose box moves draws through
/// the textures of the frame before; those no frame took for a while go.
pub const Pool = struct {
    kept: std.ArrayList(struct { tex: Tex, used: u64 }) = .empty,
    frame: u64 = 0,
    made: usize = 0,
    const idle_frames = 120;
    const most = 24;

    fn take(p: *Pool, w: u32, h: u32) Tex {
        const tw = @max(w, 1);
        const th = @max(h, 1);
        for (p.kept.items, 0..) |k, i| if (k.tex.w == tw and k.tex.h == th) return p.kept.swapRemove(i).tex;
        p.made += 1;
        return Tex.init(tw, th);
    }

    fn give(p: *Pool, t: *Tex) void {
        if (t.tex == 0) return;
        if (p.kept.items.len < most) {
            p.kept.append(gpa, .{ .tex = t.*, .used = p.frame }) catch return t.deinit();
            t.* = .{};
        } else t.deinit();
    }

    fn sweep(p: *Pool) void {
        p.frame += 1;
        var i: usize = 0;
        while (i < p.kept.items.len) {
            if (p.frame - p.kept.items[i].used > idle_frames) {
                p.kept.items[i].tex.deinit();
                _ = p.kept.swapRemove(i);
            } else i += 1;
        }
    }

    fn deinit(p: *Pool) void {
        for (p.kept.items) |*k| k.tex.deinit();
        p.kept.deinit(gpa);
        p.* = .{};
    }

    pub fn count(p: *const Pool) usize {
        return p.kept.items.len;
    }
};

/// The frame being drawn: its framebuffer, size and scale.
pub const Frame = struct { fb: u32, w: u32, h: u32, scale: f32 };

pub const Passes = struct {
    state: enum { unmade, made, failed } = .unmade,
    es: bool = false,
    vao: u32 = 0,
    down: Program = .{},
    blur: Program = .{},
    layer: Program = .{},
    clear: Program = .{},
    plain: Program = .{},
    effects: std.AutoHashMapUnmanaged(usize, ?Program) = .empty,
    layers: std.ArrayList(Saved) = .empty,
    pool: Pool = .{},

    /// A frame drawn: textures of passes no frame used for a while go.
    pub fn endFrame(p: *Passes) void {
        if (p.state == .made) p.pool.sweep();
    }

    pub fn deinit(p: *Passes) void {
        p.pool.deinit();
        for (p.layers.items) |*l| l.tex.deinit();
        p.layers.deinit(gpa);
        var it = p.effects.valueIterator();
        while (it.next()) |v| if (v.*) |*prog| prog.deinit();
        p.effects.deinit(gpa);
        if (p.state == .made) {
            inline for (.{ "down", "blur", "layer", "clear", "plain" }) |f| @field(p, f).deinit();
            gl.api.glDeleteVertexArrays(1, &p.vao);
        }
        p.* = .{};
    }

    fn make(p: *Passes, es: bool) !void {
        if (p.state == .made) return;
        if (p.state == .failed) return error.Unavailable;
        errdefer p.state = .failed;
        p.es = es;
        p.down = try program(es, "#define DOWN 1\n", "");
        p.blur = try program(es, "#define BLUR 1\n", "");
        p.layer = try program(es, "#define LAYER 1\n", "");
        p.clear = try program(es, "#define CLEAR 1\n", "");
        p.plain = try program(es, "#define EFFECT 1\n", plain_color);
        gl.api.glGenVertexArrays(1, &p.vao);
        p.state = .made;
    }

    /// Draws the effect or layer mark `i` between the parts of a frame.
    pub fn apply(p: *Passes, es: bool, f: Frame, i: *const gpu.Instance, rows: []const [4]f32) void {
        // Turned with their box, they are not drawn (as on the CPU).
        if (i.kind >= 16) return;
        p.make(es) catch return;
        const g = &gl.api;
        g.glDisable(gl.scissor_test);
        g.glBindVertexArray(p.vao);
        if (i.kind == gpu.Kind.effect) {
            p.drawEffect(f, i, rows);
        } else if (i.kind == gpu.Kind.layer) {
            p.beginLayer(f, i) catch {};
        } else p.endLayer(f, i);
        g.glBindFramebuffer(gl.framebuffer, f.fb);
        g.glBindVertexArray(0);
    }

    fn drawEffect(p: *Passes, f: Frame, i: *const gpu.Instance, rows: []const [4]f32) void {
        const row: usize = @intFromFloat(i.uv[0]);
        if (row + effect.rows_per_effect > rows.len) return;
        const a = raster_fx.area(f.w, f.h, i.rect, i.clip, f.scale) orelse return;
        const s = f.scale;
        const shape: [4]f32 = .{ i.rect[0] * s, i.rect[1] * s, i.rect[2] * s, i.rect[3] * s };
        const b = backdrop.Backdrop.of(shape, rows[row][0] * s, f.w, f.h);
        const size = b.texels();
        if (size[0] == 0) return;
        const tw: u32 = @intCast(size[0]);
        const th: u32 = @intCast(size[1]);
        var copy = p.pool.take(@intCast(b.x1 - b.x0), @intCast(b.y1 - b.y0));
        defer p.pool.give(&copy);
        copyFrom(f, copy, .{ b.x0, b.y0, b.x1, b.y1 });
        var t0 = p.pool.take(tw, th);
        defer p.pool.give(&t0);
        var t1 = p.pool.take(tw, th);
        defer p.pool.give(&t1);
        const down: f32 = @floatFromInt(b.down);
        const radius: f32 = @floatFromInt(b.radius);
        const whole: [4]f32 = .{ 0, 0, @floatFromInt(tw), @floatFromInt(th) };
        pass(p.down, copy.tex, t0.fb, tw, th, .{ .area = whole, .info = .{ down, b.sigma, radius, 0 }, .dir = .{ 0, 0, @floatFromInt(copy.w), @floatFromInt(copy.h) } }, false, false);
        if (b.radius > 0) {
            pass(p.blur, t0.tex, t1.fb, tw, th, .{ .area = whole, .info = .{ down, b.sigma, radius, 0 }, .dir = .{ 1, 0, @floatFromInt(tw), @floatFromInt(th) } }, false, false);
            pass(p.blur, t1.tex, t0.fb, tw, th, .{ .area = whole, .info = .{ down, b.sigma, radius, 0 }, .dir = .{ 0, 1, @floatFromInt(tw), @floatFromInt(th) } }, false, false);
        }
        var k: Constants = .{
            .area = areaOf(a),
            .info = .{ down, b.sigma, radius, 0 },
            .shape = shape,
            .shape2 = .{ i.radius * s, s, i.clip_round, 0 },
            .clip = i.clip,
            .origin = .{ @floatFromInt(b.x0), @floatFromInt(b.y0), @floatFromInt(tw), @floatFromInt(th) },
        };
        k.params = effect.paramsOf(rows, row).*;
        pass(p.programFor(effect.shaderOf(rows, row)), t0.tex, f.fb, f.w, f.h, k, true, true);
    }

    fn beginLayer(p: *Passes, f: Frame, i: *const gpu.Instance) !void {
        const a = raster_fx.area(f.w, f.h, i.rect, i.clip, f.scale) orelse [4]usize{ 0, 0, 0, 0 };
        var kept = p.pool.take(@intCast(a[2] - a[0]), @intCast(a[3] - a[1]));
        errdefer p.pool.give(&kept);
        if (a[2] > a[0] and a[3] > a[1]) {
            copyFrom(f, kept, a);
            pass(p.clear, 0, f.fb, f.w, f.h, .{ .area = areaOf(a) }, false, true);
        }
        try p.layers.append(gpa, .{ .tex = kept, .area = a });
    }

    fn endLayer(p: *Passes, f: Frame, i: *const gpu.Instance) void {
        var l = p.layers.pop() orelse return;
        defer p.pool.give(&l.tex);
        const a = l.area;
        if (a[2] <= a[0] or a[3] <= a[1]) return;
        const aw: u32 = @intCast(a[2] - a[0]);
        const ah: u32 = @intCast(a[3] - a[1]);
        var layer = p.pool.take(aw, ah);
        defer p.pool.give(&layer);
        copyFrom(f, layer, a);
        const sigma = i.border_width * f.scale;
        var buf: [backdrop.max_radius + 1]f32 = undefined;
        const radius: f32 = @floatFromInt(raster_fx.layerWeights(sigma, &buf).len - 1);
        if (radius > 0) {
            var t = p.pool.take(aw, ah);
            defer p.pool.give(&t);
            const whole: [4]f32 = .{ 0, 0, @floatFromInt(aw), @floatFromInt(ah) };
            pass(p.blur, layer.tex, t.fb, aw, ah, .{ .area = whole, .info = .{ 1, sigma, radius, 1 }, .dir = .{ 1, 0, @floatFromInt(aw), @floatFromInt(ah) } }, false, false);
            pass(p.blur, t.tex, layer.fb, aw, ah, .{ .area = whole, .info = .{ 1, sigma, radius, 1 }, .dir = .{ 0, 1, @floatFromInt(aw), @floatFromInt(ah) } }, false, false);
        }
        // What was under it, then the layer over it.
        copyTo(f, l.tex, a);
        pass(p.layer, layer.tex, f.fb, f.w, f.h, .{ .area = areaOf(a) }, true, true);
    }

    /// The program of an effect, made the first time it draws.
    fn programFor(p: *Passes, s: ?*const effect.Shader) Program {
        const shader = s orelse return p.plain;
        if (shader.glsl.len == 0) return p.plain;
        const gop = p.effects.getOrPut(gpa, @intFromPtr(shader)) catch return p.plain;
        if (!gop.found_existing) gop.value_ptr.* = program(p.es, "#define EFFECT 1\n", shader.glsl) catch |e| blk: {
            std.log.warn("myzig: effect {s}: {s}", .{ shader.name, @errorName(e) });
            break :blk null;
        };
        return gop.value_ptr.* orelse p.plain;
    }
};

fn areaOf(a: [4]usize) [4]f32 {
    return .{ @floatFromInt(a[0]), @floatFromInt(a[1]), @floatFromInt(a[2] - a[0]), @floatFromInt(a[3] - a[1]) };
}

/// Copies pixels `a` (x0, y0, x1, y1, rows from the top) of the frame into `dst`.
fn copyFrom(f: Frame, dst: Tex, a: [4]usize) void {
    const g = &gl.api;
    const h: i32 = @intCast(f.h);
    g.glBindFramebuffer(gl.read_framebuffer, f.fb);
    g.glBindFramebuffer(gl.draw_framebuffer, dst.fb);
    g.glBlitFramebuffer(@intCast(a[0]), h - @as(i32, @intCast(a[3])), @intCast(a[2]), h - @as(i32, @intCast(a[1])), 0, @intCast(dst.h), @intCast(dst.w), 0, gl.color_buffer_bit, gl.nearest);
}

/// Copies `src` back into pixels `a` of the frame.
fn copyTo(f: Frame, src: Tex, a: [4]usize) void {
    const g = &gl.api;
    const h: i32 = @intCast(f.h);
    g.glBindFramebuffer(gl.read_framebuffer, src.fb);
    g.glBindFramebuffer(gl.draw_framebuffer, f.fb);
    g.glBlitFramebuffer(0, 0, @intCast(src.w), @intCast(src.h), @intCast(a[0]), h - @as(i32, @intCast(a[1])), @intCast(a[2]), h - @as(i32, @intCast(a[3])), gl.color_buffer_bit, gl.nearest);
}

/// A pass of `prog` reading `src` into framebuffer `fb` (`w` × `h`):
/// the frame (`into_frame`, rows counted from the bottom) or a texture.
fn pass(prog: Program, src: u32, fb: u32, w: u32, h: u32, k_in: Constants, blend: bool, into_frame: bool) void {
    const g = &gl.api;
    var k = k_in;
    k.target = .{ @floatFromInt(w), @floatFromInt(h), if (into_frame) 1 else 0, 0 };
    g.glBindFramebuffer(gl.framebuffer, fb);
    g.glViewport(0, 0, @intCast(w), @intCast(h));
    g.glUseProgram(prog.id);
    g.glUniform4fv(prog.fx, 12, @ptrCast(&k));
    g.glActiveTexture(gl.texture0);
    g.glBindTexture(gl.texture_2d, src);
    if (blend) {
        g.glEnable(gl.blend);
        g.glBlendFunc(gl.one, gl.one_minus_src_alpha);
    } else g.glDisable(gl.blend);
    g.glDrawArrays(gl.triangle_strip, 0, 4);
}

fn program(es: bool, define: []const u8, color: []const u8) !Program {
    const g = &gl.api;
    const version: []const u8 = if (es) "#version 300 es\n" else "#version 330 core\n";
    const vs = try compile(gl.vertex_shader, &.{ version, "#define VERTEX 1\n", source });
    defer g.glDeleteShader(vs);
    const tail: []const u8 = if (color.len > 0) effect_main else "";
    const fs = try compile(gl.fragment_shader, &.{ version, define, source, color, tail });
    defer g.glDeleteShader(fs);
    const id = g.glCreateProgram();
    g.glAttachShader(id, vs);
    g.glAttachShader(id, fs);
    g.glLinkProgram(id);
    var ok: i32 = 0;
    g.glGetProgramiv(id, gl.link_status, &ok);
    if (ok == 0) {
        g.glDeleteProgram(id);
        return error.ShaderLink;
    }
    g.glUseProgram(id);
    g.glUniform1i(g.glGetUniformLocation(id, "src"), 0);
    return .{ .id = id, .fx = g.glGetUniformLocation(id, "fx") };
}

fn compile(kind: gl.Enum, parts: []const []const u8) !u32 {
    const g = &gl.api;
    var ptrs: [6][*]const u8 = undefined;
    var lens: [6]i32 = undefined;
    for (parts, 0..) |s, k| {
        ptrs[k] = s.ptr;
        lens[k] = @intCast(s.len);
    }
    const s = g.glCreateShader(kind);
    g.glShaderSource(s, @intCast(parts.len), &ptrs, &lens);
    g.glCompileShader(s);
    var ok: i32 = 0;
    g.glGetShaderiv(s, gl.compile_status, &ok);
    if (ok == 0) {
        var n: i32 = 0;
        g.glGetShaderiv(s, gl.info_log_length, &n);
        var buf: [2048]u8 = undefined;
        g.glGetShaderInfoLog(s, buf.len, null, &buf);
        std.log.warn("myzig: OpenGL effect pass: {s}", .{std.mem.sliceTo(&buf, 0)});
        g.glDeleteShader(s);
        return error.ShaderCompile;
    }
    return s;
}
