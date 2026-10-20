//! Where the CPU renderer's quads are wholly their fill, which is copied
//! rather than blended, and which the clear before them can leave.
const std = @import("std");
const gpu = @import("gpu.zig");
const xf = @import("raster_xf.zig");
const corner = @import("raster_corner.zig");
const centerOf = @import("raster.zig").centerOf;

/// Whether `quad` draws `i` and copies its fill inside its edges, over
/// any pixel: opaque, nothing clipping its corners.
pub fn opaqueQuad(i: *const gpu.Instance) bool {
    return i.kind == gpu.Kind.quad and !xf.general(i) and i.clip_round <= 0 and i.color[3] == 1;
}

/// Where a quad's pixels are wholly its fill: no edge, corner or border.
pub const Inner = struct {
    cx: f32,
    cy: f32,
    hw: f32,
    hh: f32,
    solid: f32,
    inv: f32,
    scale: f32,

    pub fn of(i: *const gpu.Instance, scale: f32) Inner {
        const hw = i.rect[2] * 0.5;
        const hh = i.rect[3] * 0.5;
        const has_border = i.border_width > 0 and i.border_color[3] > 0;
        return .{
            .cx = i.rect[0] + hw,
            .cy = i.rect[1] + hh,
            .hw = hw,
            .hh = hh,
            .solid = @max(corner.reach(i.radius, hw, hh), if (has_border) i.border_width else 0) + 2 / scale,
            .inv = 1 / scale,
            .scale = scale,
        };
    }

    /// The columns of row `y` within [x0, x1) that are the fill, or an
    /// empty span (x1, x1).
    pub fn span(n: Inner, x0: usize, x1: usize, y: usize) [2]usize {
        if (@abs(centerOf(y, n.inv) - n.cy) >= n.hh - n.solid) return .{ x1, x1 };
        return innerSpan(x0, x1, n.cx, n.hw - n.solid, n.inv, n.scale);
    }
};

/// The pixels an opaque quad drawn next sets to its fill (its `Inner`
/// within its bounds `b`): what is drawn there before it is not seen.
pub const Cover = struct {
    inner: Inner,
    b: [4]usize,

    /// The columns of row `y` within [x0, x1) the quad's fill covers, or an
    /// empty span (x1, x1).
    pub fn span(c: Cover, x0: usize, x1: usize, y: usize) [2]usize {
        if (y < c.b[1] or y >= c.b[3]) return .{ x1, x1 };
        const lo = @max(x0, c.b[0]);
        const hi = @min(x1, c.b[2]);
        if (hi <= lo) return .{ x1, x1 };
        const s = c.inner.span(lo, hi, y);
        return if (s[0] == s[1]) .{ x1, x1 } else s;
    }
};

/// The columns of [x0, x1) whose centers are within `lim` of `cx` (a run,
/// as the distance falls then grows), found by the very test each pixel
/// would make.
fn innerSpan(x0: usize, x1: usize, cx: f32, lim: f32, inv: f32, scale: f32) [2]usize {
    const in = struct {
        fn f(x: usize, c: f32, l: f32, iv: f32) bool {
            return @abs(centerOf(x, iv) - c) < l;
        }
    }.f;
    if (lim <= 0) return .{ x1, x1 };
    const guess = struct {
        fn f(v: f32, lo: usize, hi: usize) usize {
            return @intFromFloat(std.math.clamp(@floor(v), @as(f32, @floatFromInt(lo)), @as(f32, @floatFromInt(hi))));
        }
    }.f;
    var s = guess((cx - lim) * scale - 0.5, x0, x1);
    while (s < x1 and !in(s, cx, lim, inv)) s += 1;
    while (s > x0 and in(s - 1, cx, lim, inv)) s -= 1;
    if (s == x1) return .{ x1, x1 };
    var e = @max(s, guess((cx + lim) * scale - 0.5, x0, x1));
    while (e < x1 and in(e, cx, lim, inv)) e += 1;
    while (e > s and !in(e - 1, cx, lim, inv)) e -= 1;
    return .{ s, e };
}

test "a shadow left undrawn under its opaque box draws the pixels drawing it whole does" {
    const raster = @import("raster.zig");
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x5ad0);
    const rnd = prng.random();
    const w = 300;
    const h = 200;
    const a = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(a);
    const b = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(b);
    const f = struct {
        fn f(r: std.Random, lo: f32, hi: f32) f32 {
            return lo + r.float(f32) * (hi - lo);
        }
    }.f;
    for (0..60) |_| {
        // Each box after its shadow, and the same with an empty instance
        // between them, which leaves the shadow whole.
        var next: [16 * 2]gpu.Instance = undefined;
        var apart: [16 * 3]gpu.Instance = undefined;
        for (0..16) |k| {
            const rect: [4]f32 = .{ f(rnd, -10, 150), f(rnd, -10, 100), f(rnd, 0.5, 90), f(rnd, 0.5, 70) };
            const radius = if (rnd.boolean()) f(rnd, 0, 25) else -f(rnd, 0, 25);
            const clip: [4]f32 = if (rnd.boolean()) .{ -1e6, -1e6, 1e6, 1e6 } else .{ f(rnd, 0, 60), f(rnd, 0, 60), f(rnd, 80, 150), f(rnd, 60, 100) };
            const sh: gpu.Instance = .{ .rect = .{ rect[0], rect[1] + f(rnd, -4, 8), rect[2], rect[3] }, .color = .{ 0, 0, 0, f(rnd, 0.05, 1) }, .radius = radius, .border_width = f(rnd, 0.5, 12), .kind = gpu.Kind.shadow, .clip = clip };
            const box: gpu.Instance = .{
                .rect = rect,
                .color = .{ rnd.float(f32), rnd.float(f32), rnd.float(f32), if (rnd.uintLessThan(u8, 4) == 0) rnd.float(f32) else 1 },
                .border_color = .{ rnd.float(f32), rnd.float(f32), rnd.float(f32), 1 },
                .border_width = if (rnd.boolean()) 0 else f(rnd, 0, 8),
                .radius = radius,
                .clip = clip,
            };
            next[k * 2 ..][0..2].* = .{ sh, box };
            apart[k * 3 ..][0..3].* = .{ sh, .{ .rect = .{ 0, 0, 0, 0 }, .color = .{ 0, 0, 0, 0 } }, box };
        }
        raster.draw(.{ .bytes = a, .width = w, .height = h }, &next, .{ .pixels = &.{}, .size = 0 }, .{}, 2, .{ .r = 0.2, .g = 0.5, .b = 0.9 });
        raster.draw(.{ .bytes = b, .width = w, .height = h }, &apart, .{ .pixels = &.{}, .size = 0 }, .{}, 2, .{ .r = 0.2, .g = 0.5, .b = 0.9 });
        try std.testing.expectEqualSlices(u8, b, a);
    }
}
