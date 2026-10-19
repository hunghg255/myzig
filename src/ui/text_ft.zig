//! Glyphs rasterized by FreeType on Linux, unhinted and antialiased as
//! Pango and cairo draw them by default: outlines at the size and the
//! quarter pixel asked (slanted for italics a face lacks, emboldened for a
//! weight it lacks), color glyphs in BGRA (COLR layers, or a color font's
//! bitmaps, such as Noto Color Emoji's, scaled from their strike's size).
const std = @import("std");
const api = @import("text_hb_api.zig");
const engine = @import("text_engine.zig");
const Engine = @import("text_hb.zig").Engine;

/// FreeType's face of handle `h`, opened on first use.
pub fn ftFace(e: *Engine, h: usize) ?*api.FaceRec {
    const f = e.faceAt(h);
    if (f.ft_tried) return f.ft;
    f.ft_tried = true;
    const lib = e.ft_lib orelse return null;
    var out: ?*api.FaceRec = null;
    if (api.ft.FT_New_Face(lib, f.path.ptr, f.index, &out) != 0) return null;
    f.ft = out;
    return out;
}

/// Glyph `glyph` of face `h` at `size` pixels, its pen `sub` pixels right
/// of a pixel boundary, into `out` (its pixels the engine's until the next
/// call); false when it has no ink.
pub fn rasterize(e: *Engine, h: usize, size: f32, glyph: u16, sub: f32, out: *engine.Bitmap) bool {
    const ft = ftFace(e, h) orelse return false;
    const f = e.faceAt(h);
    const color = ft.face_flags & api.face_flag_color != 0;
    if (ft.face_flags & api.face_flag_scalable == 0) return strike(e, ft, size, glyph, out);
    if (api.ft.FT_Set_Char_Size(ft, 0, @intFromFloat(@round(size * 64)), 72, 72) != 0) return false;
    const slant: api.Matrix = .{ .xx = 0x10000, .xy = 0x3333, .yx = 0, .yy = 0x10000 };
    const delta: api.Vector = .{ .x = @intFromFloat(@round(sub * 64)), .y = 0 };
    api.ft.FT_Set_Transform(ft, if (f.slant) &slant else null, &delta);
    const flags: i32 = api.load_no_hinting | (if (color) @as(i32, api.load_color) else 0);
    if (api.ft.FT_Load_Glyph(ft, glyph, flags) != 0) return false;
    const slot = ft.glyph;
    if (f.bold) api.ft.FT_GlyphSlot_Embolden(slot);
    if (api.ft.FT_Render_Glyph(slot, api.render_mode_normal) != 0) return false;
    return copy(e, slot, out, 1);
}

/// A glyph of a font of bitmaps only: its strike nearest above the size,
/// scaled down to it.
fn strike(e: *Engine, ft: *api.FaceRec, size: f32, glyph: u16, out: *engine.Bitmap) bool {
    const sizes = ft.available_sizes orelse return false;
    const n: usize = @intCast(@max(0, ft.num_fixed_sizes));
    if (n == 0) return false;
    var best: usize = 0;
    for (0..n) |i| {
        const ppem = @as(f32, @floatFromInt(sizes[i].y_ppem)) / 64;
        const best_ppem = @as(f32, @floatFromInt(sizes[best].y_ppem)) / 64;
        if ((best_ppem < size and ppem > best_ppem) or (ppem >= size and ppem < best_ppem)) best = i;
    }
    if (api.ft.FT_Select_Size(ft, @intCast(best)) != 0) return false;
    if (api.ft.FT_Load_Glyph(ft, glyph, api.load_color) != 0) return false;
    const slot = ft.glyph;
    if (slot.bitmap.buffer == null and api.ft.FT_Render_Glyph(slot, api.render_mode_normal) != 0) return false;
    const ppem = @as(f32, @floatFromInt(sizes[best].y_ppem)) / 64;
    return copy(e, slot, out, if (ppem > 0) size / ppem else 1);
}

/// The slot's bitmap into `out`, scaled by `k` (≤ 1) by averaging.
fn copy(e: *Engine, slot: *api.GlyphSlotRec, out: *engine.Bitmap, k: f32) bool {
    const b = slot.bitmap;
    const w: usize = b.width;
    const h: usize = b.rows;
    const src = b.buffer orelse return false;
    if (w == 0 or h == 0) return false;
    const bgra = b.pixel_mode == api.pixel_mode_bgra;
    const bpp: usize = if (bgra) 4 else 1;
    const pitch: usize = @abs(b.pitch);
    const ow: usize = @max(1, @as(usize, @intFromFloat(@ceil(@as(f32, @floatFromInt(w)) * k))));
    const oh: usize = @max(1, @as(usize, @intFromFloat(@ceil(@as(f32, @floatFromInt(h)) * k))));
    e.scratch.resize(e.gpa, ow * oh * bpp) catch return false;
    const px = e.scratch.items;
    @memset(px, 0);
    const texel = struct {
        fn at(s: [*]u8, p: usize, mode: u8, x: usize, y: usize, c: usize) u8 {
            if (mode == api.pixel_mode_mono) return if (s[y * p + x / 8] & (@as(u8, 0x80) >> @intCast(x % 8)) != 0) 255 else 0;
            if (mode == api.pixel_mode_bgra) return s[y * p + x * 4 + c];
            return s[y * p + x];
        }
    }.at;
    if (k >= 0.999) {
        for (0..h) |y| for (0..w) |x| for (0..bpp) |c| {
            px[(y * ow + x) * bpp + c] = texel(src, pitch, b.pixel_mode, x, y, c);
        };
    } else {
        // Each output pixel the mean of the source pixels it covers.
        const inv = 1 / k;
        for (0..oh) |oy| for (0..ow) |ox| {
            const x0: usize = @intFromFloat(@floor(@as(f32, @floatFromInt(ox)) * inv));
            const y0: usize = @intFromFloat(@floor(@as(f32, @floatFromInt(oy)) * inv));
            const x1: usize = @min(w, @max(x0 + 1, @as(usize, @intFromFloat(@floor(@as(f32, @floatFromInt(ox + 1)) * inv)))));
            const y1: usize = @min(h, @max(y0 + 1, @as(usize, @intFromFloat(@floor(@as(f32, @floatFromInt(oy + 1)) * inv)))));
            if (x0 >= w or y0 >= h) continue;
            for (0..bpp) |c| {
                var sum: u32 = 0;
                for (y0..y1) |y| for (x0..x1) |x| {
                    sum += texel(src, pitch, b.pixel_mode, x, y, c);
                };
                px[(oy * ow + ox) * bpp + c] = @intCast(sum / @as(u32, @intCast((x1 - x0) * (y1 - y0))));
            }
        };
    }
    out.* = .{
        .w = @intCast(ow),
        .h = @intCast(oh),
        .left = @intFromFloat(@floor(@as(f32, @floatFromInt(slot.bitmap_left)) * k)),
        .top = @intFromFloat(@floor(-@as(f32, @floatFromInt(slot.bitmap_top)) * k)),
        .color = bgra,
        .pixels = px,
    };
    return true;
}
