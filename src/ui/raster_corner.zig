//! Continuous corners (`Style.corners = .continuous`): Core Animation's,
//! the corners macOS shows for CALayer's continuous corner curve and
//! SwiftUI's rounded rectangles, after mygo (its `internal/raster/corner.go`,
//! from QuartzCore's supercircle_sdf). An instance's negative `radius`
//! asks for them; every renderer computes them by this arithmetic (the
//! shaders' `cont_*` functions).
//!
//! In a corner's own terms, u and v are how far a point is inside its
//! vertical and horizontal edges, r its radius and e = `extent`·r how far
//! from the corner the curve leaves the edges. With a = max(0, 1 − (u,
//! v)/e) the point's place in the box of the curve, and ρ the ratio of a's
//! smaller coordinate to its larger, the curve is where
//!
//!     |a| + 1 − 1/(1 − ρ²·min(|a|, 1)·P(ρ)) = 1,
//!
//! P a quartic: a quarter circle of radius r around the diagonal, which
//! bends less and less toward the edges. Where a side is too short for
//! both of its corners' curves, the curves blend along it toward quarter
//! circles by the side's clamp factor: 0 while the curves fit, 1 once the
//! side is no longer than two radii, as a pill's ends. The shape is the
//! intersection of its corners' (the largest of their values) and of its
//! sides'; a corner's curve is computed only in its box (u and v under e),
//! and anywhere else the value is the distance to the nearest side, as for
//! square corners. Edges are smoothed by the value's gradient, found by
//! finite differences a sixteenth of a pixel apart.
const std = @import("std");

/// How far from its corner the curve of a corner of radius 1 leaves the
/// edges.
pub const extent: f32 = 1.528665;

fn clamp01(v: f32) f32 {
    return std.math.clamp(v, 0, 1);
}

/// The four corners of a box half `hw` by `hh`, all of radius `r` (at
/// most `hw` and `hh`, and positive): the curve leaves the edges `e` from
/// the corner, blended toward a quarter circle by `cx` along the
/// horizontal edges and `cy` along the vertical ones; `eff` is where the
/// curve's box ends as clamped.
pub const Corner = struct {
    r: f32,
    e: f32,
    eff: f32,
    cx: f32,
    cy: f32,

    pub fn of(hw: f32, hh: f32, r: f32) Corner {
        const e = extent * r;
        const cx = clamp01((extent - hw / r) / (extent - 1));
        const cy = clamp01((extent - hh / r) / (extent - 1));
        return .{ .r = r, .e = e, .eff = e + (r - e) * @max(cx, cy), .cx = cx, .cy = cy };
    }

    /// The corner's value at the point `u` inside its vertical edge and `v`
    /// inside its horizontal one: about the signed distance to its edge
    /// near it, positive outside.
    pub fn dist(c: Corner, u: f32, v: f32) f32 {
        const ax = @max(0, 1 - u / c.e);
        const ay = @max(0, 1 - v / c.e);
        const l = @sqrt(ax * ax + ay * ay);
        const hi = @max(ax, ay);
        const lo = @min(ax, ay);
        const rho: f32 = if (hi > 0) @min(lo / hi, 1) else 0;
        const p = (((-0.926054 * rho + 3.15601) * rho - 3.64122) * rho + 1.26803) * rho + 0.268531;
        const f1 = l + 1 - 1 / (1 - rho * rho * @min(l, 1) * p);
        const qx = @max(0, ax * extent - (extent - 1));
        const qy = @max(0, ay * extent - (extent - 1));
        const f2 = @sqrt(qx * qx + qy * qy) * 0.654166 + 0.345834;
        // The clamp along the edge the point is nearer to, blended across
        // the diagonal.
        const s: f32 = if (ay > ax) 1 else -1;
        const w = clamp01(0.5 - s + s * rho);
        const fx = f1 + (f2 - f1) * c.cx;
        const fy = f1 + (f2 - f1) * c.cy;
        const f = fx + (fy - fx) * w;
        return @min(@max(c.eff - u, c.eff - v), 0) + c.e * (f - 1);
    }

    /// How far inside its vertical edge the corner's edge is `v` inside
    /// its horizontal one: where `dist` is 0, between the quarter circles
    /// of radius r and e, found by regula falsi (Illinois) in five steps,
    /// within a hundredth of a pixel at radii of a few hundred.
    pub fn inset(c: Corner, v: f32) f32 {
        if (v >= c.e or c.r <= 0) return 0;
        var lo = circle(c.r, v);
        var hi = circle(c.e, v);
        var dlo = c.dist(lo, v);
        var dhi = c.dist(hi, v);
        if (dlo <= 0) return lo;
        if (dhi >= 0) return hi;
        var side: i32 = 0;
        for (0..5) |_| {
            const m = (lo * dhi - hi * dlo) / (dhi - dlo);
            const dm = c.dist(m, v);
            if (dm > 0) {
                lo = m;
                dlo = dm;
                if (side == 1) dhi /= 2;
                side = 1;
            } else {
                hi = m;
                dhi = dm;
                if (side == -1) dlo /= 2;
                side = -1;
            }
        }
        return (lo * dhi - hi * dlo) / (dhi - dlo);
    }
};

fn circle(r: f32, v: f32) f32 {
    if (v >= r) return 0;
    return r - @sqrt(v * (2 * r - v));
}

/// The value of a box half `hw` by `hh` with continuous corners at `p`
/// (from its center): the largest of its sides' signed distances and of
/// the values of the corners in `corners` (1 top left, 2 top right, 4
/// bottom right, 8 bottom left) whose box holds it; and whether one did.
pub fn value(c: Corner, px: f32, py: f32, hw: f32, hh: f32, corners: u4) struct { f32, bool } {
    const left = px + hw;
    const right = hw - px;
    const top = py + hh;
    const bottom = hh - py;
    var d = @max(@max(-left, -right), @max(-top, -bottom));
    var curved = false;
    const uvs = [4][2]f32{ .{ left, top }, .{ right, top }, .{ right, bottom }, .{ left, bottom } };
    inline for (uvs, 0..) |uv, k| {
        if (corners & (1 << k) != 0 and uv[0] < c.e and uv[1] < c.e) {
            d = @max(d, c.dist(uv[0], uv[1]));
            curved = true;
        }
    }
    return .{ d, curved };
}

/// The value at `p` and its gradient (x, y), as `raster_xf.zig`'s
/// `distance` gives a rounded box's: by finite differences `step` apart in
/// the corners' boxes, and the nearest side's direction elsewhere.
pub fn distance(px: f32, py: f32, hw: f32, hh: f32, r: f32, step: f32, corners: u4) [3]f32 {
    const c: Corner = .of(hw, hh, r);
    const d, const curved = value(c, px, py, hw, hh, corners);
    if (!curved) {
        const sx: f32 = if (px < 0) -1 else 1;
        const sy: f32 = if (py < 0) -1 else 1;
        return if (@abs(px) - hw > @abs(py) - hh) .{ d, sx, 0 } else .{ d, 0, sy };
    }
    const dx = value(c, px + step, py, hw, hh, corners)[0];
    const dy = value(c, px, py + step, hw, hh, corners)[0];
    return .{ d, (dx - d) / step, (dy - d) / step };
}

/// The signed distance at `p` (from the center) to a box half `hw` by
/// `hh` with corners of `radius` (an instance's: negative for continuous
/// corners) and the sum of the absolute values of its gradient, as
/// `raster.roundedBox` gives them; `inv` is a pixel's size.
pub fn box(px: f32, py: f32, hw: f32, hh: f32, radius: f32, inv: f32) [2]f32 {
    if (!(radius < 0)) return @import("raster.zig").roundedBox(px, py, hw, hh, @min(radius, @min(hw, hh)));
    const g = distance(px, py, hw, hh, @min(-radius, @min(hw, hh)), inv / 16, 15);
    return .{ g[0], @abs(g[1]) + @abs(g[2]) };
}

/// How far the corners of `radius` reach along the edges from a corner:
/// their radius, or the curve's extent for continuous ones.
pub fn reach(radius: f32, hw: f32, hh: f32) f32 {
    if (radius < 0) return @min(-radius, @min(hw, hh)) * extent;
    return @min(radius, @min(hw, hh));
}

test "a continuous corner lies between the quarter circles of its radius and its extent" {
    const c: Corner = .of(100, 100, 20);
    try std.testing.expect(c.cx == 0 and c.cy == 0);
    // On the diagonal, the curve is farther in than a circle's.
    const at = c.inset(5);
    try std.testing.expect(at > circle(20, 5) and at < circle(c.e, 5));
    try std.testing.expect(@abs(c.dist(at, 5)) < 0.01);
    // Away from the corner's box, nothing is cut.
    try std.testing.expectEqual(@as(f32, 0), c.inset(c.e + 1));
    const d, const curved = value(c, 0, 0, 100, 100, 15);
    try std.testing.expectEqual(@as(f32, -100), d);
    try std.testing.expect(!curved);
    // At the corner, outside; along an edge, at it.
    try std.testing.expect(value(c, -99.5, -99.5, 100, 100, 15)[0] > 0);
    try std.testing.expect(@abs(value(c, -100, 0, 100, 100, 15)[0]) < 1e-4);
    // A circle's corners, clamped both ways, are quarter circles.
    const pill: Corner = .of(10, 10, 10);
    try std.testing.expectEqual(@as(f32, 1), pill.cx);
    try std.testing.expectApproxEqAbs(circle(10, 3), pill.inset(3), 0.02);
}

test "its gradient is about one across the edge" {
    const g = distance(-49.9, -42, 50, 50, 12, 1.0 / 32.0, 15);
    try std.testing.expect(g[1] < -0.9 and @abs(g[2]) < 0.5);
    const b = box(-49.9, -42, 50, 50, -12, 0.5);
    try std.testing.expect(b[1] > 0.9 and b[1] < 1.6);
}
