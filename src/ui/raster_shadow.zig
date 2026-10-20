//! Shadows on the CPU, as the shader draws them: a box's coverage blurred
//! by a Gaussian, exact along x with erf, sampled four times along y.
//! What depends only on the row (the samples along y, the curve of the
//! corners) is found once a row, and erf for eight pixels at once: each
//! lane does the scalar arithmetic, so the pixels are the shader's twin's.
//! Continuous corners (a negative radius) narrow the box where their
//! curve is (`raster_corner.zig`'s `inset`).
const std = @import("std");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const run = @import("raster_lanes.zig");
const corners = @import("raster_corner.zig");

const lanes = run.lanes;
const V = run.V;

fn gaussian(x: f32, sigma: f32) f32 {
    return @exp(-(x * x) / (2 * sigma * sigma)) / (@sqrt(2 * std.math.pi) * sigma);
}

fn erf(x: V) V {
    const s = @select(f32, x < @as(V, @splat(0)), @as(V, @splat(-1)), @as(V, @splat(1)));
    const a = @abs(x);
    var y = @as(V, @splat(1)) + (@as(V, @splat(0.278393)) + (@as(V, @splat(0.230389)) + @as(V, @splat(0.078108)) * (a * a)) * a) * a;
    y *= y;
    return s - s / (y * y);
}

/// One row's four samples along y: where the blurred box's edge curves
/// to, and the Gaussian's weight there.
const Samples = struct { curved: [4]f32, weight: [4]f32, step: f32 };

/// `corner` is the instance's radius, at most `hw` and `hh` (negative for
/// continuous corners).
fn samples(py: f32, hw: f32, hh: f32, corner_in: f32, sigma: f32) Samples {
    const cont = corner_in < 0;
    const corner = @abs(corner_in);
    const cc: corners.Corner = if (cont) .of(hw, hh, corner) else undefined;
    const low = py - hh;
    const high = py + hh;
    const start = std.math.clamp(-3 * sigma, low, high);
    const end = std.math.clamp(3 * sigma, low, high);
    var s: Samples = .{ .curved = undefined, .weight = undefined, .step = (end - start) / 4 };
    var y = start + s.step * 0.5;
    for (0..4) |k| {
        if (cont) {
            s.curved[k] = hw - cc.inset(hh - @abs(py - y));
        } else {
            const delta = @min(hh - corner - @abs(py - y), 0);
            s.curved[k] = hw - corner + @sqrt(@max(0, corner * corner - delta * delta));
        }
        s.weight[k] = gaussian(y, sigma);
        y += s.step;
    }
    return s;
}

/// The shadow's alpha at `px` (from the box's center) for eight pixels.
fn alphaOf(px: V, s: Samples, k: f32) V {
    const half: V = @splat(0.5);
    const kv: V = @splat(k);
    var alpha: V = @splat(0);
    for (0..4) |j| {
        const curved: V = @splat(s.curved[j]);
        const lo = half + half * erf((px - curved) * kv);
        const hi = half + half * erf((px + curved) * kv);
        alpha += (hi - lo) * @as(V, @splat(s.weight[j])) * @as(V, @splat(s.step));
    }
    return alpha;
}

/// The shadow's alpha at (px, py) from the center of its box, half `hw`
/// by `hh`, corners `r` (negative: continuous), blurred by `sigma`: one
/// pixel of `shadow`.
pub fn alphaAt(px: f32, py: f32, hw: f32, hh: f32, r: f32, sigma: f32) f32 {
    const s = samples(py, hw, hh, r, sigma);
    const a: [lanes]f32 = alphaOf(@splat(px), s, @sqrt(@as(f32, 0.5)) / sigma);
    return a[0];
}

/// Draws the shadow `i` in `b`, but where `cover` (the opaque box drawn
/// next, which casts it) sets the pixels whatever is under them.
pub fn shadow(out: gpu.Pixels, i: *const gpu.Instance, scale: f32, b: [4]usize, cover: ?Cover) void {
    const hw = i.rect[2] * 0.5;
    const hh = i.rect[3] * 0.5;
    const r = std.math.sign(i.radius) * @min(@abs(i.radius), @min(hw, hh));
    const sigma = @max(i.border_width, 0.25);
    const sh: Row = .{ .i = i, .cx = i.rect[0] + hw, .k = @sqrt(@as(f32, 0.5)) / sigma, .inv = 1 / scale };
    const cy = i.rect[1] + hh;
    for (b[1]..b[3]) |y| {
        const wy = raster.centerOf(y, sh.inv);
        const s = samples(wy - cy, hw, hh, r, sigma);
        const hole = if (cover) |cv| cv.span(b[0], b[2], y) else .{ b[2], b[2] };
        sh.draw(out, s, wy, y, b[0], hole[0]);
        sh.draw(out, s, wy, y, hole[1], b[2]);
    }
}

const Cover = @import("raster_fill.zig").Cover;

/// What a shadow's rows share.
const Row = struct {
    i: *const gpu.Instance,
    cx: f32,
    k: f32,
    inv: f32,

    /// Pixels [x0, x1) of row `y` (`wy` its center), `s` its samples.
    fn draw(sh: Row, out: gpu.Pixels, s: Samples, wy: f32, y: usize, x0: usize, x1: usize) void {
        const c = sh.i.color;
        const plain = sh.i.clip_round <= 0;
        const row = y * out.width * 4;
        var x = x0;
        while (x < x1) : (x += lanes) {
            const wx = run.centers(x, sh.inv);
            const av = alphaOf(wx - @as(V, @splat(sh.cx)), s, sh.k);
            if (plain and x + lanes <= x1) {
                // No clip to cut it: alpha * c[3] * 1, as below.
                const raw = av * @as(V, @splat(c[3]));
                const zero: V = @splat(0);
                const a = @select(f32, raw > zero, @max(zero, @min(raw + run.dither(x, y), @as(V, @splat(1)))), zero);
                run.blendRun(out.bytes, row + x * 4, .{ @as(V, @splat(c[2])) * a, @as(V, @splat(c[1])) * a, @as(V, @splat(c[0])) * a, a }, lanes);
                continue;
            }
            const alpha: [lanes]f32 = av;
            const wxs: [lanes]f32 = wx;
            for (0..@min(lanes, x1 - x)) |l| {
                const a = raster.ditherAlpha(alpha[l] * c[3] * raster.clipCover(sh.i, wxs[l], wy, sh.inv), raster.ditherAt(x + l, y));
                raster.blend(out.bytes, row + (x + l) * 4, c[0] * a, c[1] * a, c[2] * a, a);
            }
        }
    }
};
