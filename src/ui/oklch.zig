//! Colors in Oklch, as CSS's oklch(l c h), after mygo's `ui.Oklch`:
//! lightness from 0 to 1, chroma (about 0 to 0.4) and hue in degrees, a
//! space where colors of one lightness look as light, for palettes and
//! accents derived from one hue. A color sRGB cannot show loses chroma,
//! keeping its lightness and hue, as CSS maps colors into a gamut.
//!
//!     const accent = ui.oklch(0.62, 0.19, 255);
//!     const hover = ui.oklch(0.55, 0.19, 255);
const std = @import("std");
const Color = @import("types.zig").Color;

/// The sRGB color of oklch(`l` `c` `h`), opaque.
pub fn oklch(l: f32, c: f32, h: f32) Color {
    const L = std.math.clamp(l, 0, 1);
    var chroma = @max(0, c);
    const rad = h * std.math.pi / 180;
    if (L <= 0) return .{ .r = 0, .g = 0, .b = 0 };
    if (L >= 1) return .white;
    if (inGamut(L, chroma, rad)) return encode(L, chroma, rad);
    // The most chroma that fits, by halves.
    var lo: f32 = 0;
    var hi = chroma;
    for (0..24) |_| {
        chroma = (lo + hi) / 2;
        if (inGamut(L, chroma, rad)) lo = chroma else hi = chroma;
    }
    return encode(L, lo, rad);
}

/// The Oklch of `c` (sRGB): lightness, chroma, hue in degrees.
pub fn toOklch(c: Color) [3]f32 {
    const lab = oklab(decode(c.r), decode(c.g), decode(c.b));
    const chroma = @sqrt(lab[1] * lab[1] + lab[2] * lab[2]);
    var h = std.math.atan2(lab[2], lab[1]) * 180 / std.math.pi;
    if (h < 0) h += 360;
    return .{ lab[0], chroma, if (chroma < 1e-4) 0 else h };
}

fn linear(L: f32, c: f32, rad: f32) [3]f32 {
    const a = c * @cos(rad);
    const b = c * @sin(rad);
    const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
    const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
    const s_ = L - 0.0894841775 * a - 1.2914855480 * b;
    const l3 = l_ * l_ * l_;
    const m3 = m_ * m_ * m_;
    const s3 = s_ * s_ * s_;
    return .{
        4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
        -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
        -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3,
    };
}

fn inGamut(L: f32, c: f32, rad: f32) bool {
    const eps = 1.0 / 4096.0;
    for (linear(L, c, rad)) |v| if (v < -eps or v > 1 + eps) return false;
    return true;
}

fn encode(L: f32, c: f32, rad: f32) Color {
    const v = linear(L, c, rad);
    return .{ .r = gammaEncode(v[0]), .g = gammaEncode(v[1]), .b = gammaEncode(v[2]) };
}

fn gammaEncode(v: f32) f32 {
    const x = std.math.clamp(v, 0, 1);
    return if (x <= 0.0031308) 12.92 * x else 1.055 * std.math.pow(f32, x, 1.0 / 2.4) - 0.055;
}

fn decode(v: f32) f32 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

fn oklab(r: f32, g: f32, b: f32) [3]f32 {
    const l = std.math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const m = std.math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const s = std.math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    return .{
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    };
}

test "oklch" {
    const t = std.testing;
    // CSS's oklch(62.8% 0.2577 29.23) is sRGB red.
    const red = oklch(0.628, 0.2577, 29.23);
    try t.expectApproxEqAbs(@as(f32, 1), red.r, 0.01);
    try t.expectApproxEqAbs(@as(f32, 0), red.g, 0.01);
    try t.expectApproxEqAbs(@as(f32, 0), red.b, 0.01);
    // Gray has no chroma.
    const gray = oklch(0.6, 0, 0);
    try t.expectApproxEqAbs(gray.r, gray.g, 0.001);
    // Out of gamut: chroma goes, lightness and hue stay.
    const loud = oklch(0.7, 0.5, 145);
    const back = toOklch(loud);
    try t.expectApproxEqAbs(@as(f32, 0.7), back[0], 0.01);
    try t.expectApproxEqAbs(@as(f32, 145), back[2], 2);
    try t.expect(back[1] < 0.5);
    const round = toOklch(Color.hex(0x0a84ff));
    const again = oklch(round[0], round[1], round[2]);
    try t.expectApproxEqAbs(Color.hex(0x0a84ff).b, again.b, 0.01);
}
