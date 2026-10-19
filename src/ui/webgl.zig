//! The WebGL 2 renderer, in browsers: the instances Metal and Direct3D
//! draw (`gpu.zig`), in one instanced draw a frame, with the shaders of
//! `webgl_shaders.zig` (`gl.glsl` in GLSL ES 3.0), so its pixels are the
//! CPU renderer's (`raster.zig`) to a level of blending's rounding.
//! WebGL is JavaScript's: the page's host (`web/host.js`) holds the
//! context of each window's canvas, its program, buffer and textures; this
//! side keeps them in step (the atlases as they change) and hands it each
//! frame's instances, with the plan of the passes of its effects and
//! blurred layers (`Plan`, which the host runs as `gl_fx.zig` does).
const std = @import("std");
const gpu = @import("gpu.zig");
const types = @import("types.zig");
const raster = @import("raster.zig");
const images_mod = @import("images.zig");
const shaders = @import("webgl_shaders.zig");
const effect = @import("effect.zig");
const backdrop = @import("backdrop.zig");
const raster_fx = @import("raster_fx.zig");
const fx_src = @import("gl_fx.zig");
const damage = @import("damage.zig");

pub const Instance = gpu.Instance;

extern "myzig" fn gl_init(id: u32, vs: [*]const u8, vs_len: usize, fs: [*]const u8, fs_len: usize) bool;
extern "myzig" fn gl_atlas(id: u32, pixels: [*]const u8, size: u32) void;
extern "myzig" fn gl_images(id: u32, pixels: [*]const u8, side: u32, row0: u32, row1: u32) void;
extern "myzig" fn gl_draw(id: u32, instances: [*]const u8, count: usize, width: u32, height: u32, scale: f32, r: f32, g: f32, b: f32, plans: [*]const f32, plan_floats: usize, x0: i32, y0: i32, x1: i32, y1: i32) void;
extern "myzig" fn gl_fx(id: u32, src: [*]const u8, len: usize, main: [*]const u8, main_len: usize, plain: [*]const u8, plain_len: usize) void;
extern "myzig" fn gl_effect(id: u32, index: u32, color: [*]const u8, len: usize) void;

comptime {
    // The host reads six vec4s an instance, in this order.
    std.debug.assert(@sizeOf(Instance) == 96 and @offsetOf(Instance, "uv") == 48 and @offsetOf(Instance, "radius") == 80);
}

/// An effect's or a layer's passes, as the host runs them: what it is (a
/// `gpu.Kind`) and where it goes among the instances; for an effect, its
/// shader's index (-1: none); the pixels it draws (x0, y0, x1, y1); the
/// backdrop's (x0, y0, x1, y1), its texels across and down, how far it is
/// averaged down, its blur (a layer's too) and how far that reaches; the
/// shape (x, y, w, h in pixels), its radius, the scale and the clip's
/// rounding, the clip (points); then, from 32, the effect's parameters.
pub const Plan = [48]f32;

pub const Renderer = struct {
    /// The canvas's window, as the host knows it.
    id: u32,
    atlas_size: u32 = 0,
    atlas_generation: u64 = std.math.maxInt(u64),
    images_generation: u64 = std.math.maxInt(u64),
    images_sent: bool = false,
    fx_sent: bool = false,
    /// The effects' shaders the host was given, by index.
    effects: [32]usize = @splat(0),
    effect_count: usize = 0,
    plans: std.ArrayList(Plan) = .empty,
    /// Frames draw only what changed since the last (`damage.zig`): the
    /// canvas keeps its drawing buffer (`preserveDrawingBuffer`), but as it
    /// is resized or its context restored.
    differ: damage.Differ = .init(std.heap.page_allocator),
    /// A frame's instances with its large shadows with continuous corners
    /// cut into pieces (`gpu_corners.zig`).
    pieces: std.ArrayList(Instance) = .empty,

    /// A renderer on the window's canvas; error.NoWebGL2 where the browser
    /// has none (frames are then drawn on the CPU).
    pub fn init(id: u32) !Renderer {
        if (!gl_init(id, shaders.vertex.ptr, shaders.vertex.len, shaders.fragment.ptr, shaders.fragment.len)) return error.NoWebGL2;
        return .{ .id = id };
    }

    /// The context was lost and restored: everything is sent again.
    pub fn reset(self: *Renderer) void {
        self.plans.deinit(std.heap.page_allocator);
        self.differ.deinit();
        self.pieces.deinit(std.heap.page_allocator);
        self.* = .{ .id = self.id };
    }

    /// Draws frame `f`, only where it changed since the last; false when
    /// nothing did, and the canvas is left alone.
    pub fn render(self: *Renderer, f: damage.Frame) bool {
        var part: ?damage.Box = null;
        if (self.differ.planOne(f, self.differ.diff(f))) |p| {
            if (damage.empty(p)) return false;
            part = p;
        }
        self.drawPart(f.instances, f.width, f.height, f.scale, f.clear, part);
        self.differ.remember(f);
        return true;
    }

    /// Brings the glyph atlas up to date (all of it, when it changed).
    pub fn syncAtlas(self: *Renderer, mask: raster.Mask, generation: u64) void {
        if (mask.size == 0) return;
        if (mask.size == self.atlas_size and generation == self.atlas_generation) return;
        gl_atlas(self.id, mask.pixels.ptr, mask.size);
        self.atlas_size = mask.size;
        self.atlas_generation = generation;
    }

    /// Brings the image atlas up to date: the rows that changed.
    pub fn syncImages(self: *Renderer, im: *images_mod.Images) void {
        if (im.pixels.len == 0 or im.generation == self.images_generation) return;
        const side = images_mod.size;
        if (!self.images_sent) {
            gl_images(self.id, im.pixels.ptr, side, 0, side);
            self.images_sent = true;
        } else if (im.dirty) |rows| if (rows[1] > rows[0]) {
            gl_images(self.id, im.pixels.ptr, side, rows[0], rows[1]);
        };
        im.dirty = null;
        self.images_generation = im.generation;
    }

    /// Draws `instances` over `clear`, `width` × `height` pixels at
    /// `scale` pixels a point; the browser shows it after this task.
    pub fn draw(self: *Renderer, instances: []const Instance, width: u32, height: u32, scale: f32, clear: types.Color) void {
        self.differ.invalidate();
        self.drawPart(instances, width, height, scale, clear, null);
    }

    /// Draws whole, or only within `part` (the host scissors to it), with
    /// the effects and layers in it.
    fn drawPart(self: *Renderer, all: []const Instance, width: u32, height: u32, scale: f32, clear: types.Color, part: ?damage.Box) void {
        const instances = @import("gpu_corners.zig").split(std.heap.page_allocator, all, scale, &self.pieces);
        const fr = gpu.Frame.of(instances);
        self.plans.clearRetainingCapacity();
        var markers: damage.Markers = .{ .part = part };
        for (fr.instances, 0..) |*i, k| {
            if (!gpu.isMarker(i.kind)) continue;
            // Turned with their box, they are not drawn (as on the CPU).
            if (!markers.draws(i, width, height, scale) or i.kind >= 16) continue;
            const p = self.plan(i, k, fr.rows, width, height, scale) orelse continue;
            self.plans.append(std.heap.page_allocator, p) catch return;
        }
        const bytes = std.mem.sliceAsBytes(instances);
        const plans = std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(self.plans.items));
        const p = part orelse damage.Box{ 0, 0, 0, 0 };
        gl_draw(self.id, bytes.ptr, instances.len, width, height, scale, clear.r, clear.g, clear.b, plans.ptr, plans.len, p[0], p[1], p[2], p[3]);
    }

    fn plan(self: *Renderer, i: *const Instance, k: usize, rows: []const [4]f32, w: u32, h: u32, scale: f32) ?Plan {
        var p: Plan = @splat(0);
        p[0] = i.kind;
        p[1] = @floatFromInt(k);
        p[2] = -1;
        if (!self.fx_sent) {
            gl_fx(self.id, fx_src.source.ptr, fx_src.source.len, fx_src.effect_main.ptr, fx_src.effect_main.len, fx_src.plain_color.ptr, fx_src.plain_color.len);
            self.fx_sent = true;
        }
        const a = raster_fx.area(w, h, i.rect, i.clip, scale) orelse [4]usize{ 0, 0, 0, 0 };
        for (0..4) |n| p[3 + n] = @floatFromInt(a[n]);
        if (i.kind != gpu.Kind.effect) {
            const sigma = i.border_width * scale;
            var buf: [backdrop.max_radius + 1]f32 = undefined;
            p[14] = sigma;
            p[15] = @floatFromInt(raster_fx.layerWeights(sigma, &buf).len - 1);
            return p;
        }
        const row: usize = @intFromFloat(i.uv[0]);
        if (row + effect.rows_per_effect > rows.len or a[2] <= a[0]) return null;
        if (effect.shaderOf(rows, row)) |s| if (s.glsl.len > 0) {
            if (self.effectIndex(s)) |n| p[2] = @floatFromInt(n);
        };
        const shape: [4]f32 = .{ i.rect[0] * scale, i.rect[1] * scale, i.rect[2] * scale, i.rect[3] * scale };
        const b = backdrop.Backdrop.of(shape, rows[row][0] * scale, w, h);
        const size = b.texels();
        if (size[0] == 0) return null;
        for ([_]usize{ b.x0, b.y0, b.x1, b.y1 }, 0..) |v, n| p[7 + n] = @floatFromInt(v);
        p[11] = @floatFromInt(size[0]);
        p[12] = @floatFromInt(size[1]);
        p[13] = @floatFromInt(b.down);
        p[14] = b.sigma;
        p[15] = @floatFromInt(b.radius);
        p[16..20].* = shape;
        p[20..24].* = .{ i.radius * scale, scale, i.clip_round, 0 };
        p[24..28].* = i.clip;
        const params = effect.paramsOf(rows, row);
        for (0..4) |n| p[32 + n * 4 ..][0..4].* = params[n];
        return p;
    }

    /// The index the host knows shader `s` by, given it the first time.
    fn effectIndex(self: *Renderer, s: *const effect.Shader) ?usize {
        const key = @intFromPtr(s);
        for (self.effects[0..self.effect_count], 0..) |e, n| if (e == key) return n;
        if (self.effect_count == self.effects.len) return null;
        const n = self.effect_count;
        self.effects[n] = key;
        self.effect_count += 1;
        gl_effect(self.id, @intCast(n), s.glsl.ptr, s.glsl.len);
        return n;
    }
};
