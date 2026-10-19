//! The CPU renderer's general path: an instance drawn transformed (its
//! transform's rows, `gpu.transform_rows`) or filled by a gradient, each
//! pixel found from where its center is in the instance's own coordinates.
//! The GPU renderers' shaders do this arithmetic too (`d3d11.hlsl`'s
//! `general`), so their pixels are these.
//!
//! The pixels drawn are the window's box around the instance's quad (its
//! rectangle within its clip, grown by its blur, and by a pixel where its
//! edge is smoothed), within the clip around its transform, rounded to
//! pixels as `raster.bounds` rounds; of those, the pixels whose centers
//! fall in the quad. Distances are smoothed by their exact gradient
//! through the transform, as `fwidth` would measure it.
const std = @import("std");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const gradient = @import("gradient.zig");
const Mask = raster.Mask;
const Pictures = raster.Pictures;

/// The map from the window to an instance's coordinates and back, and the
/// clip around it; identity for an instance drawn as it is.
pub const Map = struct {
    ia: f32 = 1,
    ib: f32 = 0,
    ic: f32 = 0,
    id: f32 = 1,
    ix: f32 = 0,
    iy: f32 = 0,
    fa: f32 = 1,
    fb: f32 = 0,
    fc: f32 = 0,
    fd: f32 = 1,
    fx: f32 = 0,
    fy: f32 = 0,
    outer: [4]f32 = .{ -1e6, -1e6, 1e6, 1e6 },

    pub fn of(i: *const gpu.Instance, rows: []const [4]f32) Map {
        const t = gpu.transformOf(i.kind) orelse return .{};
        if (t + gpu.transform_rows > rows.len) return .{};
        const r = rows[t..][0..gpu.transform_rows];
        return .{
            .ia = r[0][0], .ib = r[0][1], .ic = r[0][2], .id = r[0][3],
            .ix = r[1][0], .iy = r[1][1], .fx = r[1][2], .fy = r[1][3],
            .fa = r[2][0], .fb = r[2][1], .fc = r[2][2], .fd = r[2][3],
            .outer = r[3],
        };
    }

    /// How long a pixel is, at most, in the instance's coordinates.
    fn pixel(m: Map, inv: f32) f32 {
        return @max(@abs(m.ia) + @abs(m.ic), @abs(m.ib) + @abs(m.id)) * inv;
    }
};

/// Whether the instance takes the general path.
pub fn general(i: *const gpu.Instance) bool {
    return i.kind >= 16 or i.kind == gpu.Kind.gradient;
}

/// The instance's quad in its own coordinates: x0, y0, x1, y1.
fn quadOf(i: *const gpu.Instance, kind: f32, pix: f32) [4]f32 {
    const grow: f32 = if (kind == gpu.Kind.shadow) i.border_width * 3 + pix else if (kind == gpu.Kind.quad or kind == gpu.Kind.gradient) pix else 0;
    return .{
        @max(i.rect[0] - grow, i.clip[0]),
        @max(i.rect[1] - grow, i.clip[1]),
        @min(i.rect[0] + i.rect[2] + grow, i.clip[2]),
        @min(i.rect[1] + i.rect[3] + grow, i.clip[3]),
    };
}

/// The pixels the instance may cover (as `raster.bounds`).
pub fn bounds(width: usize, height: usize, i: *const gpu.Instance, rows: []const [4]f32, scale: f32) ?[4]usize {
    const m = Map.of(i, rows);
    const kind = gpu.kindOf(i.kind);
    const q = quadOf(i, kind, m.pixel(1 / scale));
    if (q[2] <= q[0] or q[3] <= q[1]) return null;
    var x0: f32 = std.math.inf(f32);
    var y0: f32 = std.math.inf(f32);
    var x1: f32 = -std.math.inf(f32);
    var y1: f32 = -std.math.inf(f32);
    for ([_][2]f32{ .{ q[0], q[1] }, .{ q[2], q[1] }, .{ q[0], q[3] }, .{ q[2], q[3] } }) |p| {
        const wx = m.fa * p[0] + m.fc * p[1] + m.fx;
        const wy = m.fb * p[0] + m.fd * p[1] + m.fy;
        x0 = @min(x0, wx);
        y0 = @min(y0, wy);
        x1 = @max(x1, wx);
        y1 = @max(y1, wy);
    }
    x0 = @max(x0, m.outer[0]);
    y0 = @max(y0, m.outer[1]);
    x1 = @min(x1, m.outer[2]);
    y1 = @min(y1, m.outer[3]);
    if (x1 <= x0 or y1 <= y0) return null;
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    const px0 = std.math.clamp(@round(x0 * scale), 0, w);
    const py0 = std.math.clamp(@round(y0 * scale), 0, h);
    const px1 = std.math.clamp(@round(x1 * scale), 0, w);
    const py1 = std.math.clamp(@round(y1 * scale), 0, h);
    if (px1 <= px0 or py1 <= py0) return null;
    return .{ @intFromFloat(px0), @intFromFloat(py0), @intFromFloat(px1), @intFromFloat(py1) };
}

/// A rounded box's signed distance at `p` (from its center) and the
/// direction it grows fastest.
fn distance(px: f32, py: f32, hw: f32, hh: f32, r: f32) [3]f32 {
    const qx = @abs(px) - hw + r;
    const qy = @abs(py) - hh + r;
    const mx = @max(qx, 0);
    const my = @max(qy, 0);
    const len = @sqrt(mx * mx + my * my);
    const d = len + @min(@max(qx, qy), 0) - r;
    const sx: f32 = if (px < 0) -1 else 1;
    const sy: f32 = if (py < 0) -1 else 1;
    if (len > 0) return .{ d, sx * mx / len, sy * my / len };
    return if (qx > qy) .{ d, sx, 0 } else .{ d, 0, sy };
}

/// How much of a pixel a distance covers, smoothed by its gradient `g`
/// through the map, per pixel.
fn cover(m: Map, d: [3]f32, inv: f32) [2]f32 {
    const dx = d[1] * m.ia + d[2] * m.ib;
    const dy = d[1] * m.ic + d[2] * m.id;
    const aa = @max((@abs(dx) + @abs(dy)) * inv, 0.0001) * 0.5;
    return .{ 1 - raster.smoothstep(-aa, aa, d[0]), aa };
}

fn sampleMask(mask: Mask, u: f32, v: f32) f32 {
    const tu = tap(mask.size, u);
    const tv = tap(mask.size, v);
    const n: usize = mask.size;
    const t00: f32 = @floatFromInt(mask.pixels[tv[1] * n + tu[1]]);
    const t01: f32 = @floatFromInt(mask.pixels[tv[1] * n + tu[2]]);
    const t10: f32 = @floatFromInt(mask.pixels[tv[2] * n + tu[1]]);
    const t11: f32 = @floatFromInt(mask.pixels[tv[2] * n + tu[2]]);
    const top = t00 + (t01 - t00) * tu[0];
    const bottom = t10 + (t11 - t10) * tu[0];
    return (top + (bottom - top) * tv[0]) / 255;
}

/// A linear filter's tap: the second texel's weight, the two texels.
fn tap(size: u32, u: f32) struct { f32, usize, usize } {
    const s: f32 = @floatFromInt(size);
    const f = u * s - 0.5;
    const f0 = @floor(f);
    const max: f32 = s - 1;
    return .{ f - f0, @intFromFloat(std.math.clamp(f0, 0, max)), @intFromFloat(std.math.clamp(f0 + 1, 0, max)) };
}

fn rgbaOf(t: [4]f32) [4]f32 {
    return .{ t[2], t[1], t[0], t[3] };
}

fn samplePicture(p: Pictures, u: f32, v: f32) [4]f32 {
    const tu = tap(p.size, u);
    const tv = tap(p.size, v);
    const n: usize = p.size;
    const w = [4]f32{ (1 - tu[0]) * (1 - tv[0]), tu[0] * (1 - tv[0]), (1 - tu[0]) * tv[0], tu[0] * tv[0] };
    const at = [4]usize{ tv[1] * n + tu[1], tv[1] * n + tu[2], tv[2] * n + tu[1], tv[2] * n + tu[2] };
    var out: [4]f32 = .{ 0, 0, 0, 0 };
    for (0..4) |k| {
        const t = p.pixels[at[k] * 4 ..][0..4];
        for (0..4) |ch| out[ch] += @as(f32, @floatFromInt(t[ch])) / 255 * w[k];
    }
    // BGRA to RGBA.
    return .{ out[2], out[1], out[0], out[3] };
}

/// The premultiplied color the instance gives the pixel centered at (lx,
/// ly) of its coordinates.
fn shade(i: *const gpu.Instance, kind: f32, m: Map, lx: f32, ly: f32, rows: []const [4]f32, mask: Mask, pictures: Pictures, inv: f32) [4]f32 {
    const c = i.color;
    if (kind == gpu.Kind.text) {
        if (mask.size == 0) return .{ 0, 0, 0, 0 };
        const tx = (lx - i.rect[0]) / i.rect[2];
        const ty = (ly - i.rect[1]) / i.rect[3];
        const a = sampleMask(mask, i.uv[0] + (i.uv[2] - i.uv[0]) * tx, i.uv[1] + (i.uv[3] - i.uv[1]) * ty) * c[3];
        return .{ c[0] * a, c[1] * a, c[2] * a, a };
    }
    const hw = i.rect[2] * 0.5;
    const hh = i.rect[3] * 0.5;
    const px = lx - i.rect[0] - hw;
    const py = ly - i.rect[1] - hh;
    const r = std.math.sign(i.radius) * @min(@abs(i.radius), @min(hw, hh));
    if (kind == gpu.Kind.shadow) {
        const a = @import("raster_shadow.zig").alphaAt(px, py, hw, hh, r, @max(i.border_width, 0.25)) * c[3];
        return .{ c[0] * a, c[1] * a, c[2] * a, a };
    }
    // Continuous corners' gradient, by differences a sixteenth of a pixel
    // of the instance's coordinates apart.
    const d = if (r < 0) @import("raster_corner.zig").distance(px, py, hw, hh, -r, m.pixel(inv) / 16, 15) else distance(px, py, hw, hh, r);
    const cv = cover(m, d, inv);
    if (cv[0] <= 0) return .{ 0, 0, 0, 0 };
    if (kind == gpu.Kind.image) {
        if (pictures.size == 0) return .{ 0, 0, 0, 0 };
        const tx = (lx - i.rect[0]) / i.rect[2];
        const ty = (ly - i.rect[1]) / i.rect[3];
        const u = i.uv[0] + (i.uv[2] - i.uv[0]) * tx;
        const v = i.uv[1] + (i.uv[3] - i.uv[1]) * ty;
        const t = if (i.border_width > 0) rgbaOf(raster.nearestPicture(pictures, u, v)) else samplePicture(pictures, u, v);
        const k = cv[0] * c[3];
        return .{ t[0] * k, t[1] * k, t[2] * k, t[3] * k };
    }
    // A quad's fill and border mix straight; a gradient's premultiplied.
    var col: [4]f32 = undefined;
    const bw = i.border_width;
    const bc = i.border_color;
    const t = if (bw > 0 and bc[3] > 0) raster.smoothstep(-bw - cv[1], -bw + cv[1], d[0]) else 0;
    if (kind == gpu.Kind.gradient) {
        const row: usize = @intFromFloat(i.uv[0]);
        const g = if (row + 2 <= rows.len) gradient.colorAt(rows, row, lx, ly) else [4]f32{ 0, 0, 0, 0 };
        const pb = [4]f32{ bc[0] * bc[3], bc[1] * bc[3], bc[2] * bc[3], bc[3] };
        for (0..4) |k| col[k] = (g[k] + (pb[k] - g[k]) * t) * cv[0];
        return col;
    }
    for (0..4) |k| col[k] = c[k] + (bc[k] - c[k]) * t;
    const a = col[3] * cv[0];
    return .{ col[0] * a, col[1] * a, col[2] * a, a };
}

/// Draws the rows `b` covers of instance `i`, which takes the general path.
pub fn draw(out: gpu.Pixels, i: *const gpu.Instance, rows: []const [4]f32, mask: Mask, pictures: Pictures, scale: f32, b: [4]usize) void {
    const m = Map.of(i, rows);
    const kind = gpu.kindOf(i.kind);
    const inv = 1 / scale;
    const q = quadOf(i, kind, m.pixel(inv));
    // The instance's clip's rounded corners, in its coordinates.
    var local = i.*;
    local.kind = kind;
    for (b[1]..b[3]) |y| {
        const wy = raster.centerOf(y, inv);
        const row = y * out.width * 4;
        for (b[0]..b[2]) |x| {
            const wx = raster.centerOf(x, inv);
            const lx = m.ia * wx + m.ic * wy + m.ix;
            const ly = m.ib * wx + m.id * wy + m.iy;
            if (lx < q[0] or lx > q[2] or ly < q[1] or ly > q[3]) continue;
            const cut = raster.clipCover(&local, lx, ly, m.pixel(inv));
            if (cut <= 0) continue;
            const s = shade(i, kind, m, lx, ly, rows, mask, pictures, inv);
            if (s[3] <= 0) continue;
            var d: [4]f32 = .{ s[0] * cut, s[1] * cut, s[2] * cut, s[3] * cut };
            if (kind == gpu.Kind.gradient) {
                d = raster.ditherColor(d, raster.ditherAt(x, y));
            } else if (kind == gpu.Kind.shadow) {
                const na = raster.ditherAlpha(d[3], raster.ditherAt(x, y));
                const k = na / d[3];
                d = .{ d[0] * k, d[1] * k, d[2] * k, na };
            }
            raster.blend(out.bytes, row + x * 4, d[0], d[1], d[2], d[3]);
        }
    }
}
