//! Glyphs rasterized by DirectWrite: IDWriteGlyphRunAnalysis gives a
//! glyph's grayscale coverage in natural symmetric rendering (antialiased
//! both ways, as Direct2D draws text at most sizes); a glyph of a color font
//! (Segoe UI Emoji's COLR layers) is translated into its layers, each
//! rasterized so and composited in its color into premultiplied BGRA.
const std = @import("std");
const api = @import("text_dw_api.zig");
const engine = @import("text_engine.zig");
const Engine = @import("text_dw.zig").Engine;

/// Glyph `glyph` of face `f` at `size` pixels, its pen `sub` pixels right of
/// a pixel boundary, into `out` (its pixels the engine's until the next
/// call); false when it has no ink.
pub fn rasterize(e: *Engine, f: usize, size: f32, glyph: u16, sub: f32, out: *engine.Bitmap) bool {
    const g = glyph;
    const zero: f32 = 0;
    const run: api.GlyphRun = .{ .face = @ptrFromInt(f), .em_size = size, .count = 1, .indices = @ptrCast(&g), .advances = @ptrCast(&zero), .offsets = null };
    if (e.isColor(f)) if (colorGlyph(e, &run, sub, out)) |ok| return ok;
    const a = analyze(e, &run, sub, 0) orelse return false;
    defer api.release(a.obj);
    const n = a.w() * a.h();
    e.scratch.resize(e.gpa, n) catch return false;
    if (!alpha(a, e.scratch.items)) return false;
    out.* = .{ .w = a.w(), .h = a.h(), .left = a.r.left, .top = a.r.top, .pixels = e.scratch.items };
    return true;
}

const Analysis = struct {
    obj: api.Object,
    r: api.Rect,

    fn w(a: Analysis) u32 {
        return @intCast(a.r.right - a.r.left);
    }
    fn h(a: Analysis) u32 {
        return @intCast(a.r.bottom - a.r.top);
    }
};

/// The grayscale analysis of a run drawn at (x, y), and its pixels' bounds;
/// null without ink.
fn analyze(e: *Engine, run: *const api.GlyphRun, x: f32, y: f32) ?Analysis {
    const f2 = e.factory2 orelse return null;
    var a: ?api.Object = null;
    const transform: ?*const [6]f32 = null;
    if (api.failed(api.call(f2, api.factory.create_glyph_run_analysis2, .{
        run,
        transform,
        @as(u32, api.rendering_mode_natural_symmetric),
        @as(u32, api.measuring_mode_natural),
        @as(u32, api.grid_fit_default),
        @as(u32, api.antialias_grayscale),
        x,
        y,
        &a,
    })) or a == null) return null;
    var r: api.Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (api.failed(api.call(a.?, api.analysis.get_alpha_texture_bounds, .{ @as(u32, api.texture_aliased_1x1), &r })) or r.right <= r.left or r.bottom <= r.top) {
        api.release(a);
        return null;
    }
    return .{ .obj = a.?, .r = r };
}

fn alpha(a: Analysis, out: []u8) bool {
    return !api.failed(api.call(a.obj, api.analysis.create_alpha_texture, .{ @as(u32, api.texture_aliased_1x1), &a.r, out.ptr, @as(u32, @intCast(out.len)) }));
}

/// A color glyph composited from its layers; null when the glyph has no
/// color (DWRITE_E_NOCOLOR) and draws as any other.
fn colorGlyph(e: *Engine, run: *const api.GlyphRun, sub: f32, out: *engine.Bitmap) ?bool {
    const f2 = e.factory2 orelse return null;
    var layers: ?api.Object = null;
    const desc: ?*const api.GlyphRunDescription = null;
    const transform: ?*const [6]f32 = null;
    if (api.failed(api.call(f2, api.factory.translate_color_glyph_run, .{ sub, @as(f32, 0), run, desc, @as(u32, api.measuring_mode_natural), transform, @as(u32, 0), &layers })) or layers == null) return null;
    defer api.release(layers);
    const Layer = struct { r: api.Rect, at: usize, color: [4]f32 };
    var list: [64]Layer = undefined;
    var count: usize = 0;
    var box: api.Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    e.layers.clearRetainingCapacity();
    while (count < list.len) {
        var more: i32 = 0;
        if (api.failed(api.call(layers.?, api.color_runs.move_next, .{&more})) or more == 0) break;
        var cr: ?*const api.ColorGlyphRun = null;
        if (api.failed(api.call(layers.?, api.color_runs.get_current_run, .{&cr}))) break;
        const c = cr orelse break;
        const a = analyze(e, &c.run, c.x, c.y) orelse continue;
        defer api.release(a.obj);
        const at = e.layers.items.len;
        e.layers.resize(e.gpa, at + a.w() * a.h()) catch break;
        if (!alpha(a, e.layers.items[at..])) {
            e.layers.items.len = at;
            continue;
        }
        const color: [4]f32 = if (c.palette_index == api.palette_foreground) .{ 0, 0, 0, 1 } else c.color;
        box = if (count == 0) a.r else .{ .left = @min(box.left, a.r.left), .top = @min(box.top, a.r.top), .right = @max(box.right, a.r.right), .bottom = @max(box.bottom, a.r.bottom) };
        list[count] = .{ .r = a.r, .at = at, .color = color };
        count += 1;
    }
    if (count == 0) return false;
    const w: usize = @intCast(box.right - box.left);
    const h: usize = @intCast(box.bottom - box.top);
    e.scratch.resize(e.gpa, w * h * 4) catch return false;
    const px = e.scratch.items;
    @memset(px, 0);
    for (list[0..count]) |l| {
        const lw: usize = @intCast(l.r.right - l.r.left);
        const lh: usize = @intCast(l.r.bottom - l.r.top);
        const ox: usize = @intCast(l.r.left - box.left);
        const oy: usize = @intCast(l.r.top - box.top);
        for (0..lh) |y| for (0..lw) |x| {
            const cov = @as(f32, @floatFromInt(e.layers.items[l.at + y * lw + x])) / 255 * l.color[3];
            if (cov == 0) continue;
            const p = px[((oy + y) * w + ox + x) * 4 ..][0..4];
            // Premultiplied BGRA, this layer over the ones below.
            const rgb = [3]f32{ l.color[2], l.color[1], l.color[0] };
            for (0..3) |k| p[k] = @intFromFloat(@round(rgb[k] * cov * 255 + @as(f32, @floatFromInt(p[k])) * (1 - cov)));
            p[3] = @intFromFloat(@round(cov * 255 + @as(f32, @floatFromInt(p[3])) * (1 - cov)));
        };
    }
    out.* = .{ .w = @intCast(w), .h = @intCast(h), .left = box.left, .top = box.top, .color = true, .pixels = px };
    return true;
}
