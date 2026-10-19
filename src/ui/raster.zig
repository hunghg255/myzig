//! The renderer on the CPU: the instances `shader.metal` draws, drawn to
//! the same pixels in memory (BGRA, premultiplied, sRGB-encoded values
//! blended as the GPU blends them). Windows present them where myzig has
//! no GPU renderer, and the Tester renders with it there. A test proves it
//! matches the Metal renderer.
//!
//! A frame is drawn in bands of rows, on several cores when it is large:
//! every pixel is what drawing it alone gives, so bands draw the same
//! pixels in any order. Within an instance, what is the same along a row
//! or a column is found once, a solid fill is copied, and texels that are
//! empty are skipped, each giving the very value the general path gives.
const std = @import("std");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const shadow = @import("raster_shadow.zig").shadow;
const lanes = @import("raster_lanes.zig");
const xf = @import("raster_xf.zig");
const fx = @import("raster_fx.zig");
const corner = @import("raster_corner.zig");
const quad_fill = @import("raster_fill.zig");
const Inner = quad_fill.Inner;

/// The glyph atlas, as the shader samples it: one byte per texel.
pub const Mask = struct {
    pixels: []const u8,
    size: u32,
};

/// The image atlas: BGRA premultiplied, `size` × `size` (empty: none).
pub const Pictures = struct {
    pixels: []const u8 = &.{},
    size: u32 = 0,
};

/// Rows a band has: a core takes bands in turn, as rows differ in work.
const band_rows = 64;
/// Less work than this a core (`work`: about a pixel's fill each) is not
/// worth waking a thread of the pool (`raster_pool.zig`) for.
const work_per_core = 1 << 18;
const pool = @import("raster_pool.zig");
const max_workers = pool.max;

/// About how much drawing a frame is: clearing it, and the pixels its
/// instances cover, a shadow's costing more.
fn work(out: gpu.Pixels, instances: []const gpu.Instance, rows: []const [4]f32, scale: f32, part: [4]usize) usize {
    var total = (part[2] - part[0]) * (part[3] - part[1]) / 4;
    for (instances) |*i| {
        const b = boundsOf(out, i, rows, scale) orelse continue;
        const x0 = @max(b[0], part[0]);
        const y0 = @max(b[1], part[1]);
        const x1 = @min(b[2], part[2]);
        const y1 = @min(b[3], part[3]);
        if (x1 <= x0 or y1 <= y0) continue;
        const area = (x1 - x0) * (y1 - y0);
        total += if (i.kind == gpu.Kind.shadow) area * 3 else if (xf.general(i)) area * 4 else area;
    }
    return total;
}

const Frame = struct {
    out: gpu.Pixels,
    instances: []const gpu.Instance,
    rows: []const [4]f32,
    mask: Mask,
    pictures: Pictures,
    scale: f32,
    /// The color the frame starts as, or null to draw over what is there.
    clear: ?u32,
    /// The pixels drawn (x0, y0, x1, y1): the frame's, or a part of it.
    part: [4]usize,
    next: std.atomic.Value(usize) = .init(0),

    fn shared(ctx: *anyopaque) void {
        bands(@ptrCast(@alignCast(ctx)));
    }

    fn bands(f: *Frame) void {
        const p = f.part;
        const n = (p[3] - p[1] + band_rows - 1) / band_rows;
        while (true) {
            const band = f.next.fetchAdd(1, .monotonic);
            if (band >= n) return;
            const y0 = p[1] + band * band_rows;
            f.bandRows(y0, @min(y0 + band_rows, p[3]));
        }
    }

    fn bandRows(f: *const Frame, y0: usize, y1: usize) void {
        const p = f.part;
        if (f.clear) |px| f.clearRows(px, y0, y1);
        for (f.instances) |*i| {
            var b = boundsOf(f.out, i, f.rows, f.scale) orelse continue;
            b[0] = @max(b[0], p[0]);
            b[1] = @max(b[1], y0);
            b[2] = @min(b[2], p[2]);
            b[3] = @min(b[3], y1);
            if (b[3] <= b[1] or b[2] <= b[0]) continue;
            if (xf.general(i)) {
                xf.draw(f.out, i, f.rows, f.mask, f.pictures, f.scale, b);
            } else drawOne(f.out, i, f.mask, f.pictures, f.scale, b);
        }
    }

    /// Clears rows [y0, y1) of the part but the pixels the first instance
    /// sets to its fill whatever is under them (as a window's background
    /// does): those would be written twice.
    fn clearRows(f: *const Frame, px: u32, y0: usize, y1: usize) void {
        const p = f.part;
        const all = words(f.out);
        const lead: ?*const gpu.Instance = if (f.instances.len > 0 and quad_fill.opaqueQuad(&f.instances[0])) &f.instances[0] else null;
        const lb = if (lead) |l| bounds(f.out, l, f.scale) else null;
        const inner: Inner = if (lead) |l| .of(l, f.scale) else undefined;
        for (y0..y1) |y| {
            const at = y * f.out.width;
            var span: [2]usize = .{ p[2], p[2] };
            if (lb) |b| if (y >= b[1] and y < b[3]) {
                span = inner.span(@max(b[0], p[0]), @min(b[2], p[2]), y);
            };
            if (span[0] == span[1]) {
                @memset(all[at + p[0] .. at + p[2]], px);
                continue;
            }
            @memset(all[at + p[0] .. at + span[0]], px);
            @memset(all[at + span[1] .. at + p[2]], px);
        }
    }
};

/// Draws `instances` over `clear` into `out` (sized `out.width` ×
/// `out.height` pixels, `scale` pixels a point). A frame with effects or
/// blurred layers (`gpu.Kind.effect`, `layer`) is drawn in parts, each
/// over the one before, the effect or layer between them.
pub fn draw(out: gpu.Pixels, instances: []const gpu.Instance, mask: Mask, pictures: Pictures, scale: f32, clear: types.Color) void {
    drawPart(out, instances, mask, pictures, scale, clear, .{ 0, 0, out.width, out.height });
}

/// Draws only the pixels `part` (x0, y0, x1, y1) of the frame, as drawing
/// it whole draws them, leaving the others as they are (`damage.zig`):
/// effects and layers that meet the part must lie in it (`damage.grow`),
/// and those outside are not drawn.
pub fn drawPart(out: gpu.Pixels, instances: []const gpu.Instance, mask: Mask, pictures: Pictures, scale: f32, clear: types.Color, part_in: [4]usize) void {
    const part: [4]usize = .{ @min(part_in[0], out.width), @min(part_in[1], out.height), @min(part_in[2], out.width), @min(part_in[3], out.height) };
    if (part[2] <= part[0] or part[3] <= part[1]) return;
    const px: [4]u8 = .{ unit(clear.b), unit(clear.g), unit(clear.r), 255 };
    const fr = gpu.Frame.of(instances);
    const whole = part[0] == 0 and part[1] == 0 and part[2] == out.width and part[3] == out.height;
    var markers: @import("damage.zig").Markers = .{ .part = if (whole) null else .{ @intCast(part[0]), @intCast(part[1]), @intCast(part[2]), @intCast(part[3]) } };
    const w: u32 = @intCast(out.width);
    const h: u32 = @intCast(out.height);
    var start: usize = 0;
    var first = true;
    var layers: fx.Layers = .{};
    defer layers.deinit();
    for (fr.instances, 0..) |*i, k| {
        if (!fx.marker(i.kind)) continue;
        segment(out, fr.instances[start..k], fr.rows, mask, pictures, scale, if (first) @bitCast(px) else null, part);
        first = false;
        if (markers.draws(i, w, h, scale)) fx.apply(out, i, fr.rows, scale, &layers);
        start = k + 1;
    }
    segment(out, fr.instances[start..], fr.rows, mask, pictures, scale, if (first) @bitCast(px) else null, part);
}

fn segment(out: gpu.Pixels, instances: []const gpu.Instance, rows: []const [4]f32, mask: Mask, pictures: Pictures, scale: f32, clear: ?u32, part: [4]usize) void {
    if (clear == null and instances.len == 0) return;
    var f: Frame = .{ .out = out, .instances = instances, .rows = rows, .mask = mask, .pictures = pictures, .scale = scale, .clear = clear, .part = part };
    if (@import("builtin").single_threaded) return f.bands();
    const cores = std.Thread.getCpuCount() catch 1;
    const workers = @min(cores, max_workers, @max(1, work(out, instances, rows, scale, part) / work_per_core));
    if (workers == 1) return f.bands();
    if (pool.share(workers - 1, Frame.shared, &f)) return;
    var threads: [max_workers]std.Thread = undefined;
    var spawned: usize = 0;
    // Each takes the next band until none is left: one that fails to
    // start leaves its bands to the others.
    while (spawned + 1 < workers) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, Frame.bands, .{&f}) catch break;
    }
    f.bands();
    for (threads[0..spawned]) |t| t.join();
}

/// The pixels an instance covers, whichever path draws it.
fn boundsOf(out: gpu.Pixels, i: *const gpu.Instance, rows: []const [4]f32, scale: f32) ?[4]usize {
    if (xf.general(i)) return xf.bounds(out.width, out.height, i, rows, scale);
    return bounds(out, i, scale);
}

fn words(out: gpu.Pixels) []u32 {
    return @alignCast(std.mem.bytesAsSlice(u32, out.bytes[0 .. out.width * out.height * 4]));
}

fn unit(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

/// The pixels an instance covers: its quad (grown for a shadow's blur),
/// within its clip and the frame.
fn bounds(out: gpu.Pixels, i: *const gpu.Instance, scale: f32) ?[4]usize {
    const grow: f32 = if (i.kind == gpu.Kind.shadow) i.border_width * 3 else 0;
    const x0 = @max(i.rect[0] - grow, i.clip[0]);
    const y0 = @max(i.rect[1] - grow, i.clip[1]);
    const x1 = @min(i.rect[0] + i.rect[2] + grow, i.clip[2]);
    const y1 = @min(i.rect[1] + i.rect[3] + grow, i.clip[3]);
    if (x1 <= x0 or y1 <= y0) return null;
    const w: f32 = @floatFromInt(out.width);
    const h: f32 = @floatFromInt(out.height);
    // A pixel is drawn when its center is inside, as the GPU rasterizes.
    const px0 = std.math.clamp(@round(x0 * scale), 0, w);
    const py0 = std.math.clamp(@round(y0 * scale), 0, h);
    const px1 = std.math.clamp(@round(x1 * scale), 0, w);
    const py1 = std.math.clamp(@round(y1 * scale), 0, h);
    if (px1 <= px0 or py1 <= py0) return null;
    return .{ @intFromFloat(px0), @intFromFloat(py0), @intFromFloat(px1), @intFromFloat(py1) };
}

fn drawOne(out: gpu.Pixels, i: *const gpu.Instance, mask: Mask, pictures: Pictures, scale: f32, b: [4]usize) void {
    if (i.kind == gpu.Kind.text) return glyph(out, i, mask, scale, b);
    if (i.kind == gpu.Kind.image) return picture(out, i, pictures, scale, b);
    if (i.kind == gpu.Kind.shadow) return shadow(out, i, scale, b);
    quad(out, i, scale, b);
}

const V4 = @Vector(4, f32);

/// Blends a premultiplied color over the pixel at byte `at`.
pub inline fn blend(bytes: []u8, at: usize, r: f32, g: f32, bl: f32, a: f32) void {
    if (a <= 0) return;
    const d = bytes[at..][0..4];
    const dv: V4 = @floatFromInt(@as(@Vector(4, u8), d.*));
    const sv: V4 = .{ bl, g, r, a };
    const v = @min(@as(V4, @splat(255)), sv * @as(V4, @splat(255)) + dv * @as(V4, @splat(1 - a)) + @as(V4, @splat(0.5)));
    d.* = @as(@Vector(4, u8), @intFromFloat(v));
}

/// An 8×8 ordered dither's offset at pixel (x, y), in levels of 1/255:
/// between -0.49 and 0.49 of one, so exact levels stay exact while smooth
/// gradients and shadows don't show bands. Every renderer adds the same
/// (`dither` in the shaders) to gradients' color and shadows' alpha.
pub inline fn ditherAt(x: usize, y: usize) f32 {
    const xv: u32 = @intCast(x & 7);
    const yv: u32 = @intCast(y & 7);
    var b: u32 = 0;
    inline for (0..3) |k| b = (b << 2) | ((((xv ^ yv) >> k) & 1) << 1) | ((yv >> k) & 1);
    return ((@as(f32, @floatFromInt(b)) + 0.5) / 64 - 0.5) * (1.0 / 255.0);
}

/// A gradient's premultiplied pixel, dithered: its color moved by the
/// pixel's offset.
pub inline fn ditherColor(s: [4]f32, n: f32) [4]f32 {
    if (s[3] <= 0) return s;
    return .{ std.math.clamp(s[0] + n, 0, 1), std.math.clamp(s[1] + n, 0, 1), std.math.clamp(s[2] + n, 0, 1), s[3] };
}

/// A shadow's alpha, dithered (zero stays zero).
pub inline fn ditherAlpha(a: f32, n: f32) f32 {
    return if (a > 0) std.math.clamp(a + n, 0, 1) else 0;
}

pub fn smoothstep(e0: f32, e1: f32, x: f32) f32 {
    const t = std.math.clamp((x - e0) / (e1 - e0), 0, 1);
    return t * t * (3 - 2 * t);
}

/// The signed distance to a rounded box centered at 0, and the sum of the
/// absolute values of its gradient (what `fwidth` measures per pixel).
pub fn roundedBox(px: f32, py: f32, hw: f32, hh: f32, r: f32) [2]f32 {
    const qx = @abs(px) - hw + r;
    const qy = @abs(py) - hh + r;
    const mx = @max(qx, 0);
    const my = @max(qy, 0);
    const len = @sqrt(mx * mx + my * my);
    const d = len + @min(@max(qx, qy), 0) - r;
    const grad: f32 = if (len > 0) (mx + my) / len else 1;
    return .{ d, grad };
}

/// How much of the pixel at `wx`, `wy` the instance's clip lets through:
/// all of it, but in the clip's rounded corners (as the shader's
/// `clip_cover`).
pub inline fn clipCover(i: *const gpu.Instance, wx: f32, wy: f32, inv: f32) f32 {
    if (i.clip_round <= 0) return 1;
    const round = gpu.clipCorners(i.clip_round);
    const c = i.clip;
    const hw = (c[2] - c[0]) * 0.5;
    const hh = (c[3] - c[1]) * 0.5;
    const r = @min(round.radius, @min(hw, hh));
    const qx = wx - c[0] - hw;
    const qy = wy - c[1] - hh;
    if (round.continuous) {
        // Its curves reach farther, and may reach past the middle of a
        // side: only the corners in `corners` cut.
        const e = r * corner.extent;
        if ((wx > c[0] + e and wx < c[2] - e) or (wy > c[1] + e and wy < c[3] - e)) return 1;
        const g = corner.distance(qx, qy, hw, hh, r, inv / 16, round.corners);
        const aa = @max((@abs(g[1]) + @abs(g[2])) * inv, 0.0001) * 0.5;
        return 1 - smoothstep(-aa, aa, g[0]);
    }
    // Between the corners, nothing is cut.
    if ((wx > c[0] + r and wx < c[2] - r) or (wy > c[1] + r and wy < c[3] - r)) return 1;
    const bit: u4 = if (qy < 0) (if (qx < 0) 1 else 2) else (if (qx < 0) 8 else 4);
    if (round.corners & bit == 0) return 1;
    const sd = roundedBox(qx, qy, hw, hh, r);
    const aa = @max(sd[1] * inv, 0.0001) * 0.5;
    return 1 - smoothstep(-aa, aa, sd[0]);
}

/// The pixel centers' x in points.
pub inline fn centerOf(x: usize, inv: f32) f32 {
    return (@as(f32, @floatFromInt(x)) + 0.5) * inv;
}

fn quad(out: gpu.Pixels, i: *const gpu.Instance, scale: f32, b: [4]usize) void {
    const inner: Inner = .of(i, scale);
    const hw = inner.hw;
    const hh = inner.hh;
    const cx = inner.cx;
    const cy = inner.cy;
    const r = @min(i.radius, @min(hw, hh));
    const cont = i.radius < 0;
    const bw = i.border_width;
    const has_border = bw > 0 and i.border_color[3] > 0;
    const c = i.color;
    const bc = i.border_color;
    const solid = inner.solid;
    const inv = inner.inv;
    // Where nothing clips the corners, the fill's pixel is the same all
    // along the inside of a row; opaque, it is what blending gives over
    // any pixel.
    const plain = i.clip_round <= 0;
    var fill: u32 = 0;
    if (plain and c[3] == 1) {
        var p: [4]u8 = .{ 0, 0, 0, 0 };
        blend(&p, 0, c[0], c[1], c[2], 1);
        fill = @bitCast(p);
    }
    const all = words(out);
    for (b[1]..b[3]) |y| {
        const wy = centerOf(y, inv);
        const py = wy - cy;
        const row = y * out.width * 4;
        const inner_y = @abs(py) < hh - solid;
        if (plain) {
            // (r is the instance's radius for continuous corners.)
            const q: lanes.QuadRow = .{ .inv = inv, .cx = cx, .py = py, .hw = hw, .hh = hh, .r = if (cont) i.radius else r, .bw = bw, .has_border = has_border, .c = c, .bc = bc };
            // The clear (`Frame.clearRows`) leaves this span to the first quad.
            const span = inner.span(b[0], b[2], y);
            // Continuous corners' edges are drawn a pixel at a time.
            const edges = if (cont) &quadPixels else &lanes.quadEdges;
            if (span[0] == span[1]) {
                edges(out.bytes, row, b[0], b[2], q);
                continue;
            }
            // Within the span the pixel is the fill's (cut is 1 here).
            if (fill != 0) {
                @memset(all[y * out.width + span[0] .. y * out.width + span[1]], fill);
            } else {
                const a = c[3];
                for (span[0]..span[1]) |x| blend(out.bytes, row + x * 4, c[0] * a, c[1] * a, c[2] * a, a);
            }
            edges(out.bytes, row, b[0], span[0], q);
            edges(out.bytes, row, span[1], b[2], q);
            continue;
        }
        for (b[0]..b[2]) |x| {
            const wx = centerOf(x, inv);
            const pxl = wx - cx;
            const cut = clipCover(i, wx, wy, inv);
            if (inner_y and @abs(pxl) < hw - solid) {
                const a = c[3] * cut;
                blend(out.bytes, row + x * 4, c[0] * a, c[1] * a, c[2] * a, a);
                continue;
            }
            quadPixel(out.bytes, row + x * 4, i, pxl, py, inv, cut);
        }
    }
}

/// The pixels [x0, x1) of a quad's row with continuous corners, each on
/// its own (`quadPixel`), where no clip rounds its corners.
fn quadPixels(bytes: []u8, row: usize, x0: usize, x1: usize, q: lanes.QuadRow) void {
    for (x0..x1) |x| {
        const sd = corner.box(centerOf(x, q.inv) - q.cx, q.py, q.hw, q.hh, q.r, q.inv);
        shadeQuad(bytes, row + x * 4, q.c, q.bc, q.bw, sd, q.inv, 1);
    }
}

/// A quad's pixel at `pxl`, `py` from its center, through its edge, its
/// corners and its border, cut by `cut`.
fn quadPixel(bytes: []u8, at: usize, i: *const gpu.Instance, pxl: f32, py: f32, inv: f32, cut: f32) void {
    const sd = corner.box(pxl, py, i.rect[2] * 0.5, i.rect[3] * 0.5, i.radius, inv);
    shadeQuad(bytes, at, i.color, i.border_color, i.border_width, sd, inv, cut);
}

/// Blends the quad's color at the signed distance `sd` (and its gradient)
/// from its edge.
fn shadeQuad(bytes: []u8, at: usize, c: [4]f32, bc: [4]f32, bw: f32, sd: [2]f32, inv: f32, cut: f32) void {
    const aa = @max(sd[1] * inv, 0.0001) * 0.5;
    const coverage = 1 - smoothstep(-aa, aa, sd[0]);
    if (coverage <= 0) return;
    var col = c;
    if (bw > 0 and bc[3] > 0) {
        const t = smoothstep(-bw - aa, -bw + aa, sd[0]);
        for (0..4) |k| col[k] = c[k] + (bc[k] - c[k]) * t;
    }
    const a = col[3] * coverage * cut;
    blend(bytes, at, col[0] * a, col[1] * a, col[2] * a, a);
}

/// Where a texture coordinate falls between texels, as Metal's linear
/// filter with clamped edges finds it: the two texels and the weight of
/// the second.
const Tap = struct { t0: u32, t1: u32, w: f32 };

fn tap(size: u32, u: f32) Tap {
    const s: f32 = @floatFromInt(size);
    const f = u * s - 0.5;
    const f0 = @floor(f);
    const max: i64 = @as(i64, size) - 1;
    return .{
        .t0 = @intCast(std.math.clamp(@as(i64, @intFromFloat(f0)), 0, max)),
        .t1 = @intCast(std.math.clamp(@as(i64, @intFromFloat(f0)) + 1, 0, max)),
        .w = f - f0,
    };
}

/// Columns a glyph's taps are kept for; wider ones find them per pixel.
const max_glyph_cols = 512;

fn glyph(out: gpu.Pixels, i: *const gpu.Instance, mask: Mask, scale: f32, b: [4]usize) void {
    if (mask.size == 0) return;
    const inv = 1 / scale;
    const c = i.color;
    const n: usize = mask.size;
    const cols = b[2] - b[0];
    var taps: [max_glyph_cols]Tap = undefined;
    const keep = cols <= max_glyph_cols;
    if (keep) for (0..cols) |k| {
        const tx = (centerOf(b[0] + k, inv) - i.rect[0]) / i.rect[2];
        taps[k] = tap(mask.size, i.uv[0] + (i.uv[2] - i.uv[0]) * tx);
    };
    for (b[1]..b[3]) |y| {
        const wy = centerOf(y, inv);
        const ty = (wy - i.rect[1]) / i.rect[3];
        const tv = tap(mask.size, i.uv[1] + (i.uv[3] - i.uv[1]) * ty);
        const top_row = mask.pixels[tv.t0 * n ..];
        const bottom_row = mask.pixels[tv.t1 * n ..];
        const row = y * out.width * 4;
        for (b[0]..b[2], 0..) |x, k| {
            const th = if (keep) taps[k] else tap(mask.size, i.uv[0] + (i.uv[2] - i.uv[0]) * ((centerOf(x, inv) - i.rect[0]) / i.rect[2]));
            const t00 = top_row[th.t0];
            const t01 = top_row[th.t1];
            const t10 = bottom_row[th.t0];
            const t11 = bottom_row[th.t1];
            // Nothing of the glyph here: the sample is 0, and so is alpha.
            if (t00 | t01 | t10 | t11 == 0) continue;
            const a0: f32 = @floatFromInt(t00);
            const b0: f32 = @floatFromInt(t01);
            const c0: f32 = @floatFromInt(t10);
            const d0: f32 = @floatFromInt(t11);
            const top = a0 + (b0 - a0) * th.w;
            const bottom = c0 + (d0 - c0) * th.w;
            const sample = (top + (bottom - top) * tv.w) / 255;
            const a = sample * c[3] * clipCover(i, centerOf(x, inv), wy, inv);
            blend(out.bytes, row + x * 4, c[0] * a, c[1] * a, c[2] * a, a);
        }
    }
}

/// The image atlas's texel nearest `u`, `v`, for pictures drawn pixelated
/// (an image instance whose border width is positive), as the shaders'
/// `picture` reads it.
pub fn nearestPicture(p: Pictures, u: f32, v: f32) [4]f32 {
    const s: f32 = @floatFromInt(p.size);
    const x: usize = @intFromFloat(std.math.clamp(@floor(u * s), 0, s - 1));
    const y: usize = @intFromFloat(std.math.clamp(@floor(v * s), 0, s - 1));
    const t = p.pixels[(y * p.size + x) * 4 ..][0..4];
    return .{ @as(f32, @floatFromInt(t[0])) / 255, @as(f32, @floatFromInt(t[1])) / 255, @as(f32, @floatFromInt(t[2])) / 255, @as(f32, @floatFromInt(t[3])) / 255 };
}

/// A BGRA texel of the image atlas, bilinear as Metal's sampler.
fn samplePicture(p: Pictures, u: f32, v: f32) [4]f32 {
    const tu = tap(p.size, u);
    const tv = tap(p.size, v);
    const xs = [2]usize{ tu.t0, tu.t1 };
    const ys = [2]usize{ tv.t0, tv.t1 };
    const tx = tu.w;
    const ty = tv.w;
    var out: [4]f32 = .{ 0, 0, 0, 0 };
    const weights = [4]f32{ (1 - tx) * (1 - ty), tx * (1 - ty), (1 - tx) * ty, tx * ty };
    for (0..4) |k| {
        const t = p.pixels[(ys[k / 2] * p.size + xs[k % 2]) * 4 ..][0..4];
        for (0..4) |ch| out[ch] += @as(f32, @floatFromInt(t[ch])) / 255 * weights[k];
    }
    return out;
}

fn picture(out: gpu.Pixels, i: *const gpu.Instance, p: Pictures, scale: f32, b: [4]usize) void {
    if (p.size == 0) return;
    const inv = 1 / scale;
    const hw = i.rect[2] * 0.5;
    const hh = i.rect[3] * 0.5;
    for (b[1]..b[3]) |y| {
        const wy = centerOf(y, inv);
        const ty = (wy - i.rect[1]) / i.rect[3];
        const v = i.uv[1] + (i.uv[3] - i.uv[1]) * ty;
        const row = y * out.width * 4;
        for (b[0]..b[2]) |x| {
            const wx = centerOf(x, inv);
            const tx = (wx - i.rect[0]) / i.rect[2];
            const sd = corner.box(wx - i.rect[0] - hw, wy - i.rect[1] - hh, hw, hh, i.radius, inv);
            const aa = @max(sd[1] * inv, 0.0001) * 0.5;
            const k = (1 - smoothstep(-aa, aa, sd[0])) * i.color[3] * clipCover(i, wx, wy, inv);
            if (k <= 0) continue;
            const u = i.uv[0] + (i.uv[2] - i.uv[0]) * tx;
            const t = if (i.border_width > 0) nearestPicture(p, u, v) else samplePicture(p, u, v);
            blend(out.bytes, row + x * 4, t[2] * k, t[1] * k, t[0] * k, t[3] * k);
        }
    }
}

test "rounded boxes, borders, glyphs and shadows" {
    const gpa = std.testing.allocator;
    const bytes = try gpa.alloc(u8, 40 * 40 * 4);
    defer gpa.free(bytes);
    const out: gpu.Pixels = .{ .bytes = bytes, .width = 40, .height = 40 };
    var texels: [4]u8 = .{ 255, 255, 255, 255 };
    draw(out, &.{
        .{ .rect = .{ 2, 2, 16, 16 }, .color = .{ 1, 0, 0, 1 }, .radius = 4 },
        .{ .rect = .{ 0, 0, 10, 10 }, .color = .{ 0, 0, 1, 1 }, .uv = .{ 0, 0, 1, 1 }, .kind = gpu.Kind.text, .clip = .{ 0, 0, 5, 20 } },
    }, .{ .pixels = &texels, .size = 2 }, .{}, 2, .{ .r = 1, .g = 1, .b = 1 });
    const at = struct {
        fn f(o: gpu.Pixels, x: usize, y: usize) [4]u8 {
            return o.bytes[(y * o.width + x) * 4 ..][0..4].*;
        }
    }.f;
    // The middle of the box is red (BGRA); its rounded corner is not.
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(out, 20, 20));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(out, 4, 34));
    // The glyph is blue where its clip lets it be.
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, at(out, 2, 2));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(out, 15, 2));
}

test "a clip's rounded corners cut what it clips, only where asked" {
    const gpa = std.testing.allocator;
    const bytes = try gpa.alloc(u8, 40 * 40 * 4);
    defer gpa.free(bytes);
    const out: gpu.Pixels = .{ .bytes = bytes, .width = 40, .height = 40 };
    // A square filling its clip, whose left corners round by 8.
    draw(out, &.{
        .{ .rect = .{ 0, 0, 20, 20 }, .color = .{ 1, 0, 0, 1 }, .clip = .{ 0, 0, 20, 20 }, .clip_round = gpu.clipRound(8, 1 | 8) },
    }, .{ .pixels = &.{}, .size = 0 }, .{}, 2, .{ .r = 1, .g = 1, .b = 1 });
    const at = struct {
        fn f(o: gpu.Pixels, x: usize, y: usize) [4]u8 {
            return o.bytes[(y * o.width + x) * 4 ..][0..4].*;
        }
    }.f;
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(out, 0, 0));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(out, 0, 39));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(out, 39, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(out, 39, 39));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(out, 20, 20));
    const unpacked = gpu.clipCorners(gpu.clipRound(8, 1 | 8));
    try std.testing.expectEqual(@as(f32, 8), unpacked.radius);
    try std.testing.expectEqual(@as(u4, 9), unpacked.corners);
}
