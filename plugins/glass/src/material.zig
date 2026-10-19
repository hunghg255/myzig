//! A pane of Liquid Glass as numbers, after mygo's glass plugin (itself
//! measured from macOS 27's NSGlassEffectView): how much what shows
//! through blurs, how the bezel bends it (`lens`), how its lightness maps
//! to the glass's (`tone`), the tint, and the rim's light. Everything in
//! device pixels.
const std = @import("std");

pub const Style = enum { regular, clear };

/// A pane's parameters, in device pixels.
pub const Material = struct {
    /// The standard deviation of the blur of what shows through.
    blur: f32,
    /// How far from the edge the surface curves, and how far at most the
    /// bezel bends what shows through toward the middle.
    bezel: f32,
    refraction: f32,
    /// The lightness black and white, blurred, show at, along a curve
    /// bent by `curve` (1: a line); `saturation` multiplies how far colors
    /// are from their lightness.
    low: f32,
    high: f32,
    curve: f32,
    saturation: f32,
    /// Straight RGBA; colors the glass by its alpha.
    tint: [4]f32 = .{ 0, 0, 0, 0 },
    /// How much the rim is lit, within about `rim_width` of the edge, by
    /// light from `light` (radians, clockwise from the right).
    rim: f32 = 0.35,
    rim_width: f32 = 1,
    light: f32 = std.math.pi / 2.0,
};

/// The material of a pane `w`×`h` DIPs at `scale`, in a dark window or not:
/// the regular glass maps black to 54% and white to 100% in light mode,
/// and to 15% and 51% in dark mode; larger panes blur more, up to 10 DIPs;
/// the bezel curves the last 36 DIPs, at most half the pane.
pub fn of(style: Style, tint: ?[4]f32, w: f32, h: f32, scale: f32, dark: bool) Material {
    const m = @min(w, h);
    const bezel = @min(36, m / 2);
    var mat: Material = .{
        .blur = std.math.clamp(m * 0.035, 1, 10) * scale,
        .bezel = bezel * scale,
        .refraction = 1.6 * bezel * scale,
        .low = 0.541,
        .high = 1,
        .curve = 1.2,
        .saturation = 1,
    };
    if (style == .clear) {
        mat.blur = scale;
        mat.low = 0.125;
        mat.high = 1.082;
        mat.curve = 1;
    } else if (dark) {
        mat.low = 0.15;
        mat.high = 0.51;
        mat.curve = 2;
        mat.saturation = 2.2;
    }
    if (tint) |t| if (t[3] > 0) {
        mat.tint = t;
        mat.tint[3] *= 0.88;
    };
    return mat;
}

/// The signed distance from (px, py) to the edge of the rounded rectangle
/// `r` (x, y, w, h) with corner radii (top left, top right, bottom right,
/// bottom left), negative inside.
pub fn sdRoundRect(r: [4]f32, radii: [4]f32, px: f32, py: f32) f32 {
    const hx = r[2] / 2;
    const hy = r[3] / 2;
    const qx = px - r[0] - hx;
    const qy = py - r[1] - hy;
    const rad = @min(corner(radii, qx, qy), hx, hy);
    const ax = @abs(qx) - hx + rad;
    const ay = @abs(qy) - hy + rad;
    const mx = @max(ax, 0);
    const my = @max(ay, 0);
    return @sqrt(mx * mx + my * my) + @min(@max(ax, ay), 0) - rad;
}

fn corner(radii: [4]f32, qx: f32, qy: f32) f32 {
    if (qx < 0 and qy < 0) return radii[0];
    if (qy < 0) return radii[1];
    if (qx >= 0) return radii[2];
    return radii[3];
}

/// How far, as a fraction of the refraction, the glass bends what shows
/// through `t` pixels inside its edge, within a bezel of `bezel`: the
/// surface is Apple's squircle profile, ⁴√(1-(1-x)⁴), and light coming
/// straight down bends entering glass of index 1.5 (Snell's law).
pub fn lens(t: f32, bezel: f32) f32 {
    if (bezel <= 0 or t >= bezel) return 0;
    const u = 1 - @max(t, 0) / bezel;
    const v = 1 - u * u * u * u;
    const a = @sqrt(v * @sqrt(v));
    const b = u * u * u;
    const n = @sqrt(a * a + b * b);
    const s = b / n;
    const c = a / n;
    const st = s / 1.5;
    const ct = @sqrt(1 - st * st);
    return (s * ct - c * st) / (c * ct + s * st) / 1.1180340;
}

fn sign(v: f32) f32 {
    return if (v > 0) 1 else if (v < 0) -1 else 0;
}

/// The direction away from the middle of the rounded rectangle at (px, py),
/// its edge's normal there, smoothed as of corners half again as round.
pub fn normal(px: f32, py: f32, r: [4]f32, radii: [4]f32) [2]f32 {
    const hx = r[2] / 2;
    const hy = r[3] / 2;
    const cx = px - r[0] - hx;
    const cy = py - r[1] - hy;
    const rad = @min(corner(radii, cx, cy) * 1.5, hx, hy);
    const qx = @abs(cx) - (hx - rad);
    const qy = @abs(cy) - (hy - rad);
    if (qx > 0 or qy > 0) {
        const mx = @max(qx, 0);
        const my = @max(qy, 0);
        const n = @sqrt(mx * mx + my * my);
        return .{ sign(cx) * mx / n, sign(cy) * my / n };
    }
    return if (qx > qy) .{ sign(cx), 0 } else .{ 0, sign(cy) };
}

/// The glass's own color for the premultiplied color `c` behind it, by its
/// lightness `l` mapped to `t`, keeping its colors' distance from it.
pub fn toneAt(c: [3]f32, l: f32, t: f32, m: *const Material) [3]f32 {
    const k = (m.high - m.low) * m.saturation;
    var out = c;
    for (&out) |*v| v.* = std.math.clamp(t + (v.* - l) * k, 0, 1);
    return out;
}

/// `toneAt` along the material's curve.
pub fn tone(c: [3]f32, m: *const Material) [3]f32 {
    const l = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
    const t = m.low + (m.high - m.low) * (1 - std.math.pow(f32, @max(1 - l, 0), m.curve));
    return toneAt(c, l, t, m);
}

test "the lens bends most at the edge, not at all past the bezel" {
    try std.testing.expectEqual(@as(f32, 0), lens(10, 10));
    try std.testing.expect(lens(0, 10) > lens(5, 10));
    try std.testing.expectApproxEqAbs(@as(f32, 1), lens(0, 10), 0.01);
}

test "the regular glass maps black and white" {
    const light = of(.regular, null, 200, 44, 2, false);
    const black = tone(.{ 0, 0, 0 }, &light);
    try std.testing.expectApproxEqAbs(@as(f32, 0.541), black[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1), tone(.{ 1, 1, 1 }, &light)[1], 1e-4);
    const dark = of(.regular, null, 200, 44, 2, true);
    try std.testing.expectApproxEqAbs(@as(f32, 0.15), tone(.{ 0, 0, 0 }, &dark)[2], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 44 * 0.035 * 2), light.blur, 1e-4);
    try std.testing.expectEqual(@as(f32, 22 * 2), light.bezel);
}

test "distances and normals of a rounded rectangle" {
    const r: [4]f32 = .{ 0, 0, 100, 50 };
    const radii: [4]f32 = @splat(10);
    try std.testing.expectApproxEqAbs(@as(f32, -25), sdRoundRect(r, radii, 50, 25), 1e-4);
    try std.testing.expect(sdRoundRect(r, radii, 1, 1) > 0); // outside the corner's curve
    try std.testing.expectEqual([2]f32{ 0, -1 }, normal(50, 2, r, radii));
    try std.testing.expectEqual([2]f32{ 1, 0 }, normal(98, 25, r, radii));
}
