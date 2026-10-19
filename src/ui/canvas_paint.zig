//! What a canvas paints with, and where: solid colors and linear and
//! radial gradients (their colors found exactly at each pixel, between
//! the two stops around it, and dithered: an 8×8 Bayer pattern of less
//! than half a level keeps 8-bit pixels from showing bands), composited
//! source-over into premultiplied BGRA pixels, the coverage of a path
//! times the clip's, in layers that are blended down with an opacity.
const std = @import("std");
const types = @import("types.zig");
const path = @import("path.zig");
const Color = types.Color;
const Point = path.Point;
const Transform = path.Transform;

/// What a gradient does past its ends: keeps their colors, goes back and
/// forth, or starts over.
pub const Spread = enum(u8) { pad, reflect, repeat };

pub const Stop = struct {
    /// From 0 to 1 along the gradient, in order.
    offset: f32,
    color: Color,
};

/// From `from` to `to` (in the units of what it fills, through
/// `transform`), as SVG's linearGradient and Canvas 2D's.
pub const Linear = struct {
    from: Point,
    to: Point,
    stops: []const Stop,
    spread: Spread = .pad,
    /// From the gradient's space to the drawing's (SVG's gradientTransform).
    transform: Transform = .identity,
};

/// Out from `focal` (the center unless given) to the circle around
/// `center`, as SVG's radialGradient.
pub const Radial = struct {
    center: Point,
    radius: f32,
    focal: ?Point = null,
    stops: []const Stop,
    spread: Spread = .pad,
    transform: Transform = .identity,
};

pub const Paint = union(enum) {
    solid: Color,
    linear: Linear,
    radial: Radial,

    pub fn color(c: Color) Paint {
        return .{ .solid = c };
    }
};

/// A paint made ready for the pixels of one fill.
pub const Shader = struct {
    kind: enum { solid, linear, radial, none },
    solid: [4]f32 = .{ 0, 0, 0, 0 },
    /// A gradient's stops (kept by the recording) and its opacity.
    stops: []const Stop = &.{},
    alpha: f32 = 1,
    spread: Spread = .pad,
    /// Device pixels to the gradient's space.
    inv: Transform = .identity,
    // Linear: t = dot(g - from, dir) * inv_len2.
    from: Point = .{ 0, 0 },
    dir: Point = .{ 0, 0 },
    inv_len2: f32 = 0,
    // Radial, from the focal point.
    focal: Point = .{ 0, 0 },
    cd: Point = .{ 0, 0 },
    r: f32 = 0,
    a: f32 = 0,

    /// `ctm` takes the drawing's units to device pixels; `alpha` fades it.
    pub fn init(paint: Paint, ctm: Transform, alpha: f32) Shader {
        switch (paint) {
            .solid => |c| return .{ .kind = .solid, .solid = premul(c, alpha) },
            .linear => |g| {
                if (g.stops.len == 0) return .{ .kind = .none };
                var s: Shader = .{ .kind = .linear, .spread = g.spread };
                const inv = g.transform.then(ctm).invert() orelse return solidOf(g.stops, alpha);
                s.inv = inv;
                s.from = g.from;
                s.dir = .{ g.to[0] - g.from[0], g.to[1] - g.from[1] };
                const l2 = s.dir[0] * s.dir[0] + s.dir[1] * s.dir[1];
                if (l2 == 0) return solidOf(g.stops[g.stops.len - 1 ..], alpha);
                s.inv_len2 = 1 / l2;
                s.stops = g.stops;
                s.alpha = alpha;
                return s;
            },
            .radial => |g| {
                if (g.stops.len == 0) return .{ .kind = .none };
                if (!(g.radius > 0)) return solidOf(g.stops[g.stops.len - 1 ..], alpha);
                var s: Shader = .{ .kind = .radial, .spread = g.spread };
                s.inv = g.transform.then(ctm).invert() orelse return solidOf(g.stops, alpha);
                var f = g.focal orelse g.center;
                // A focal point outside the circle is brought inside, as SVG 1.1 does.
                const fx = f[0] - g.center[0];
                const fy = f[1] - g.center[1];
                const fd = std.math.hypot(fx, fy);
                if (fd > g.radius * 0.99) {
                    const k = g.radius * 0.99 / fd;
                    f = .{ g.center[0] + fx * k, g.center[1] + fy * k };
                }
                s.focal = f;
                s.cd = .{ g.center[0] - f[0], g.center[1] - f[1] };
                s.r = g.radius;
                s.a = s.cd[0] * s.cd[0] + s.cd[1] * s.cd[1] - g.radius * g.radius;
                s.stops = g.stops;
                s.alpha = alpha;
                return s;
            },
        }
    }

    fn solidOf(stops: []const Stop, alpha: f32) Shader {
        return .{ .kind = .solid, .solid = premul(stops[0].color, alpha) };
    }

    /// The premultiplied color at the device pixel (x, y)'s center.
    pub inline fn at(s: *const Shader, x: usize, y: usize) [4]f32 {
        if (s.kind == .solid) return s.solid;
        const g = s.inv.apply(.{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 });
        const t = switch (s.kind) {
            .linear => ((g[0] - s.from[0]) * s.dir[0] + (g[1] - s.from[1]) * s.dir[1]) * s.inv_len2,
            .radial => blk: {
                // The circle through g, of the family from the focal point
                // (radius 0) to the gradient's (radius r): g = f + t(q - f).
                const px = g[0] - s.focal[0];
                const py = g[1] - s.focal[1];
                const b = px * s.cd[0] + py * s.cd[1];
                const pp = px * px + py * py;
                const disc = b * b - s.a * pp;
                break :blk (b - @sqrt(@max(0, disc))) / s.a;
            },
            else => 0,
        };
        return colorAt(s.stops, s.alpha, spreadOf(s.spread, t));
    }
};

/// Where `t_in` falls in [0, 1], by the spread.
fn spreadOf(spread: Spread, t_in: f32) f32 {
    if (!std.math.isFinite(t_in)) return 0;
    const t = switch (spread) {
        .pad => std.math.clamp(t_in, 0, 1),
        .repeat => t_in - @floor(t_in),
        .reflect => blk: {
            const m = @mod(t_in, 2);
            break :blk if (m > 1) 2 - m else m;
        },
    };
    return t;
}

pub fn premul(c: Color, alpha: f32) [4]f32 {
    const a = std.math.clamp(c.a * alpha, 0, 1);
    return .{ c.r * a, c.g * a, c.b * a, a };
}

/// The gradient's color at `t` (0 to 1), premultiplied, interpolated
/// between the stops around it (premultiplied, as browsers do).
pub fn colorAt(stops: []const Stop, alpha: f32, t: f32) [4]f32 {
    // The last stop at or before t: by halves when there are many.
    var k: usize = 0;
    if (stops.len > 8) {
        var lo: usize = 0;
        var hi: usize = stops.len;
        while (lo + 1 < hi) {
            const m = (lo + hi) / 2;
            if (stops[m].offset <= t) lo = m else hi = m;
        }
        k = lo;
    } else while (k + 1 < stops.len and stops[k + 1].offset <= t) k += 1;
    const a = stops[k];
    if (k + 1 >= stops.len or t <= a.offset) return premul(a.color, alpha);
    const b = stops[k + 1];
    const span = b.offset - a.offset;
    const u = if (span > 0) (t - a.offset) / span else 1;
    const pa = premul(a.color, alpha);
    const pb = premul(b.color, alpha);
    var e: [4]f32 = undefined;
    for (0..4) |ch| e[ch] = pa[ch] + (pb[ch] - pa[ch]) * u;
    return e;
}

/// The ordered dither at device pixel (x, y): an 8×8 Bayer matrix's
/// level, from -0.49 to 0.49 of an 8-bit step.
pub inline fn dither(x: usize, y: usize) f32 {
    var b: u32 = 0;
    const xy: u32 = @truncate(x ^ y);
    const yy: u32 = @truncate(y);
    inline for (0..3) |i| b = (b << 2) | (((xy >> i) & 1) << 1) | ((yy >> i) & 1);
    return (@as(f32, @floatFromInt(b)) + 0.5) / 64 - 0.5;
}

/// Pixels a canvas draws into: layers of premultiplied BGRA, and the clip.
pub const Target = struct {
    w: usize,
    h: usize,
    /// The layer drawn into; the bottom one is the canvas's.
    px: []u8,
    /// What is inside the clip, 0 to 255 per pixel; null: all of it.
    clip: ?[]const u8 = null,
};

/// Paints a fill's coverage rows with a shader: the sink of `Coverage.sweep`.
pub const FillSink = struct {
    t: *const Target,
    shader: *const Shader,

    pub fn row(s: FillSink, y: usize, x0: usize, alphas: []const f32) void {
        const t = s.t;
        const sh = s.shader;
        const base = y * t.w + x0;
        if (sh.kind == .solid) {
            const c = sh.solid;
            for (alphas, 0..) |cov, i| {
                var a = cov;
                if (t.clip) |m| a *= @as(f32, @floatFromInt(m[base + i])) * (1.0 / 255.0);
                if (a < 1.0 / 512.0) continue;
                blend(t.px[(base + i) * 4 ..][0..4], .{ c[0] * a, c[1] * a, c[2] * a, c[3] * a });
            }
            return;
        }
        for (alphas, 0..) |cov, i| {
            var a = cov;
            if (t.clip) |m| a *= @as(f32, @floatFromInt(m[base + i])) * (1.0 / 255.0);
            if (a < 1.0 / 512.0) continue;
            const c = sh.at(x0 + i, y);
            blendDither(t.px[(base + i) * 4 ..][0..4], .{ c[0] * a, c[1] * a, c[2] * a, c[3] * a }, dither(x0 + i, y));
        }
    }
};

/// Writes a clip's coverage, times the clip it is inside, into a mask.
pub const ClipSink = struct {
    out: []u8,
    outer: ?[]const u8,
    w: usize,

    pub fn row(s: ClipSink, y: usize, x0: usize, alphas: []const f32) void {
        const base = y * s.w + x0;
        for (alphas, 0..) |cov, i| {
            var a = @min(1, cov);
            if (s.outer) |m| a *= @as(f32, @floatFromInt(m[base + i])) * (1.0 / 255.0);
            s.out[base + i] = @intFromFloat(a * 255 + 0.5);
        }
    }
};

/// Source over: `src` is premultiplied RGBA, 0 to 1; `dst` BGRA bytes.
pub inline fn blend(dst: *[4]u8, src: [4]f32) void {
    const k = 1 - src[3];
    const b = @as(f32, @floatFromInt(dst[0])) * k + src[2] * 255;
    const g = @as(f32, @floatFromInt(dst[1])) * k + src[1] * 255;
    const r = @as(f32, @floatFromInt(dst[2])) * k + src[0] * 255;
    const a = @as(f32, @floatFromInt(dst[3])) * k + src[3] * 255;
    dst.* = .{ byte(b), byte(g), byte(r), byte(a) };
}

/// `blend`, with `n` (an 8-bit step's fraction) added to the color before
/// it is rounded, kept within the alpha.
pub inline fn blendDither(dst: *[4]u8, src: [4]f32, n: f32) void {
    const k = 1 - src[3];
    const a = byte(@as(f32, @floatFromInt(dst[3])) * k + src[3] * 255);
    const b = byte(@as(f32, @floatFromInt(dst[0])) * k + src[2] * 255 + n);
    const g = byte(@as(f32, @floatFromInt(dst[1])) * k + src[1] * 255 + n);
    const r = byte(@as(f32, @floatFromInt(dst[2])) * k + src[0] * 255 + n);
    dst.* = .{ @min(b, a), @min(g, a), @min(r, a), a };
}

inline fn byte(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v + 0.5, 0, 255));
}

/// Blends a layer down onto the one under it, faded by `opacity`.
pub fn compositeLayer(dst: []u8, src: []const u8, opacity: f32) void {
    const o = std.math.clamp(opacity, 0, 1);
    var i: usize = 0;
    while (i < src.len) : (i += 4) {
        if (src[i + 3] == 0) continue;
        const k = o * (1.0 / 255.0);
        blend(dst[i..][0..4], .{
            @as(f32, @floatFromInt(src[i + 2])) * k,
            @as(f32, @floatFromInt(src[i + 1])) * k,
            @as(f32, @floatFromInt(src[i])) * k,
            @as(f32, @floatFromInt(src[i + 3])) * k,
        });
    }
}

test "a linear gradient runs between its stops; past its ends it pads" {
    const s = Shader.init(.{ .linear = .{
        .from = .{ 0, 0 },
        .to = .{ 10, 0 },
        .stops = &.{ .{ .offset = 0, .color = .{ .r = 1, .a = 1 } }, .{ .offset = 1, .color = .{ .b = 1, .a = 1 } } },
    } }, .identity, 1);
    const left = s.at(0, 0);
    const mid = s.at(4, 3);
    const past = s.at(40, 0);
    try std.testing.expect(left[0] > 0.9);
    try std.testing.expectApproxEqAbs(@as(f32, 0.45), mid[2], 0.01);
    try std.testing.expectEqual(@as(f32, 1), past[2]);
}

test "a radial gradient goes out from its center" {
    const s = Shader.init(.{ .radial = .{
        .center = .{ 10, 10 },
        .radius = 10,
        .stops = &.{ .{ .offset = 0, .color = .white }, .{ .offset = 1, .color = .{ .a = 0 } } },
    } }, .identity, 1);
    try std.testing.expect(s.at(9, 9)[3] > 0.9);
    try std.testing.expectApproxEqAbs(@as(f32, 0.547), s.at(14, 9)[3], 0.01);
    try std.testing.expectEqual(@as(f32, 0), s.at(0, 0)[3]);
}

test "a gradient of seven stops has no bands: steps of a level or two, its stops exact" {
    const gpa = std.testing.allocator;
    const render = @import("canvas_render.zig");
    const hue = [_]Stop{
        .{ .offset = 0, .color = .hex(0xff0000) },     .{ .offset = 1.0 / 6.0, .color = .hex(0xffff00) },
        .{ .offset = 2.0 / 6.0, .color = .hex(0x00ff00) }, .{ .offset = 0.5, .color = .hex(0x00ffff) },
        .{ .offset = 4.0 / 6.0, .color = .hex(0x0000ff) }, .{ .offset = 5.0 / 6.0, .color = .hex(0xff00ff) },
        .{ .offset = 1, .color = .hex(0xff0000) },
    };
    const w = 1000;
    const h = 8;
    var data: path.Path = .init(gpa);
    defer data.deinit();
    data.rect(0, 0, w, h);
    const cmds = [_]render.Cmd{.{ .fill = .{ .path = data.data(), .paint = .{ .linear = .{ .from = .{ 0.5, 0 }, .to = .{ w + 0.5, 0 }, .stops = &hue } } } }};
    const px = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(px);
    @memset(px, 0);
    try render.render(gpa, &cmds, px, w, h, .identity);
    var distinct = std.AutoHashMap(u32, void).init(gpa);
    defer distinct.deinit();
    for (0..h) |y| for (0..w) |x| {
        const p = px[(y * w + x) * 4 ..][0..4];
        try distinct.put(std.mem.readInt(u32, p, .little), {});
        try std.testing.expectEqual(@as(u8, 255), p[3]);
        if (x == 0) continue;
        // A neighbor differs by the slope (1.5 levels a pixel) and the dither.
        const q = px[(y * w + x - 1) * 4 ..][0..4];
        for (0..3) |ch| try std.testing.expect(@abs(@as(i32, p[ch]) - @as(i32, q[ch])) <= 3);
    };
    // A table of 256 colors gave about 256; every level shows now.
    try std.testing.expect(distinct.count() > 1000);
    // At a stop (pixel 500's center is t = 0.5: cyan), and at the start.
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 0, 255 }, px[(3 * w + 500) * 4 ..][0..4]);
    const first = px[0..4];
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, first);
    // Solid fills are not dithered.
    const flat = [_]render.Cmd{.{ .fill = .{ .path = data.data(), .paint = .{ .solid = .{ .r = 0.5, .g = 0.25, .b = 0.75, .a = 1 } } } }};
    @memset(px, 0);
    try render.render(gpa, &flat, px, w, h, .identity);
    for (0..w * h) |i| try std.testing.expectEqualSlices(u8, px[0..4], px[i * 4 ..][0..4]);
}

test "the dither is a permutation of 64 levels, centered" {
    var seen: [64]bool = @splat(false);
    var sum: f32 = 0;
    for (0..8) |y| for (0..8) |x| {
        const n = dither(x, y);
        sum += n;
        const k: usize = @intFromFloat((n + 0.5) * 64 - 0.5);
        try std.testing.expect(!seen[k]);
        seen[k] = true;
        try std.testing.expectEqual(n, dither(x + 8, y + 16));
    };
    try std.testing.expectApproxEqAbs(@as(f32, 0), sum, 1e-4);
}
