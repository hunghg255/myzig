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
