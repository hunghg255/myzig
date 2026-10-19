//! The CPU renderer's pixels, eight at a time: each lane does the very
//! arithmetic `raster.zig` does for one pixel, so they come out the same.
const std = @import("std");
const raster = @import("raster.zig");

pub const lanes = 8;
pub const V = @Vector(lanes, f32);
const W = @Vector(lanes, u32);

pub inline fn splat(x: f32) V {
    return @splat(x);
}

/// The centers' x in points of the pixels from column `x`.
pub inline fn centers(x: usize, inv: f32) V {
    return (splat(@floatFromInt(x)) + std.simd.iota(f32, lanes) + splat(0.5)) * splat(inv);
}

/// `raster.ditherAt` for the pixels from column `x` of row `y`.
pub inline fn dither(x: usize, y: usize) V {
    const U = @Vector(lanes, u32);
    const xv: U = (@as(U, @splat(@intCast(x & 7))) + std.simd.iota(u32, lanes)) & @as(U, @splat(7));
    const yv: U = @splat(@intCast(y & 7));
    const one: U = @splat(1);
    var b: U = @splat(0);
    inline for (0..3) |k| {
        const sh: @Vector(lanes, u5) = @splat(k);
        b = (b << @as(@Vector(lanes, u5), @splat(2))) | ((((xv ^ yv) >> sh) & one) << @as(@Vector(lanes, u5), @splat(1))) | ((yv >> sh) & one);
    }
    const f: V = @floatFromInt(b);
    return ((f + splat(0.5)) / splat(64) - splat(0.5)) * splat(1.0 / 255.0);
}

/// Blends `n` (up to `lanes`) pixels from byte `at` as `raster.blend`
/// does: `src` is what it takes, premultiplied, in BGRA order.
pub inline fn blendRun(bytes: []u8, at: usize, src: [4]V, n: usize) void {
    if (n < lanes) {
        const b: [lanes]f32 = src[0];
        const g: [lanes]f32 = src[1];
        const r: [lanes]f32 = src[2];
        const a: [lanes]f32 = src[3];
        for (0..n) |l| raster.blend(bytes, at + l * 4, r[l], g[l], b[l], a[l]);
        return;
    }
    const keep = src[3] <= splat(0);
    if (@reduce(.And, keep)) return;
    const px: *align(1) [lanes]u32 = @ptrCast(bytes[at..][0 .. lanes * 4]);
    const d: W = px.*;
    const inv = splat(1) - src[3];
    var result: W = @splat(0);
    inline for (0..4) |ch| {
        const shift: @Vector(lanes, u5) = @splat(ch * 8);
        const dv: V = @floatFromInt((d >> shift) & @as(W, @splat(0xff)));
        const v = @min(splat(255), src[ch] * splat(255) + dv * inv + splat(0.5));
        const u: W = @intFromFloat(v);
        result |= u << shift;
    }
    px.* = @select(u32, keep, d, result);
}

fn smoothstep(e0: V, e1: V, x: V) V {
    const t = @max(splat(0), @min((x - e0) / (e1 - e0), splat(1)));
    return t * t * (splat(3) - splat(2) * t);
}

/// What a row of a quad needs, as `raster.quad` finds it.
pub const QuadRow = struct {
    inv: f32,
    cx: f32,
    py: f32,
    hw: f32,
    hh: f32,
    r: f32,
    bw: f32,
    has_border: bool,
    c: [4]f32,
    bc: [4]f32,
};

/// The pixels [x0, x1) of a quad's row through its edges, corners and
/// border, where no clip rounds its corners (the general path of
/// `raster.quad`, whose cut is then 1).
pub fn quadEdges(bytes: []u8, row: usize, x0: usize, x1: usize, q: QuadRow) void {
    var x = x0;
    while (x < x1) : (x += lanes) {
        const pxl = centers(x, q.inv) - splat(q.cx);
        // raster.roundedBox, lane by lane.
        const qx = @abs(pxl) - splat(q.hw) + splat(q.r);
        const qy = splat(@abs(q.py) - q.hh + q.r);
        const mx = @max(qx, splat(0));
        const my = @max(qy, splat(0));
        const len = @sqrt(mx * mx + my * my);
        const sd = len + @min(@max(qx, qy), splat(0)) - splat(q.r);
        const grad = @select(f32, len > splat(0), (mx + my) / len, splat(1));
        const aa = @max(grad * splat(q.inv), splat(0.0001)) * splat(0.5);
        const coverage = splat(1) - smoothstep(-aa, aa, sd);
        var col: [4]V = .{ splat(q.c[0]), splat(q.c[1]), splat(q.c[2]), splat(q.c[3]) };
        if (q.has_border) {
            const t = smoothstep(splat(-q.bw) - aa, splat(-q.bw) + aa, sd);
            for (0..4) |k| col[k] = splat(q.c[k]) + (splat(q.bc[k]) - splat(q.c[k])) * t;
        }
        const a = col[3] * coverage;
        blendRun(bytes, row + x * 4, .{ col[2] * a, col[1] * a, col[0] * a, a }, @min(lanes, x1 - x));
    }
}

test "quads and shadows drawn lanes at a time are what the per-pixel path draws" {
    const gpu = @import("gpu.zig");
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x1a9e5);
    const rnd = prng.random();
    const w = 300;
    const h = 200;
    const a = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(a);
    const b = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(b);
    for (0..60) |_| {
        var plain: [24]gpu.Instance = undefined;
        var cut: [24]gpu.Instance = undefined;
        for (&plain, &cut) |*p, *q| {
            const f = struct {
                fn f(r: std.Random, lo: f32, hi: f32) f32 {
                    return lo + r.float(f32) * (hi - lo);
                }
            }.f;
            p.* = .{
                .rect = .{ f(rnd, -10, 150), f(rnd, -10, 100), f(rnd, 0.5, 90), f(rnd, 0.5, 70) },
                .color = .{ rnd.float(f32), rnd.float(f32), rnd.float(f32), if (rnd.boolean()) 1 else rnd.float(f32) },
                .border_color = .{ rnd.float(f32), rnd.float(f32), rnd.float(f32), rnd.float(f32) },
                .radius = f(rnd, 0, 25),
                .border_width = if (rnd.boolean()) 0 else f(rnd, 0, 8),
                .kind = if (rnd.boolean()) gpu.Kind.quad else gpu.Kind.shadow,
            };
            // Corners rounded so far away that they cut nothing: each pixel
            // takes the per-pixel path, and must come out the same.
            q.* = p.*;
            q.clip_round = gpu.clipRound(8, 15);
        }
        raster.draw(.{ .bytes = a, .width = w, .height = h }, &plain, .{ .pixels = &.{}, .size = 0 }, .{}, 2, .{ .r = 0.2, .g = 0.5, .b = 0.9 });
        raster.draw(.{ .bytes = b, .width = w, .height = h }, &cut, .{ .pixels = &.{}, .size = 0 }, .{}, 2, .{ .r = 0.2, .g = 0.5, .b = 0.9 });
        try std.testing.expectEqualSlices(u8, b, a);
    }
}
