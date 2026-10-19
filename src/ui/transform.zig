//! Transforms of boxes: affine maps of the plane, as CSS's `transform`
//! (translate, scale, rotate, skew), after mygo's `ui.Transform`. A box's
//! transform moves it and everything in it as drawn, about its origin
//! (`Style.transform_origin`), after layout, which keeps its place; the
//! pointer follows what is drawn.
//!
//!     .transform = ui.Affine.scaling(1.1, 1.1).then(.rotation(12)).then(.translation(40, 0)),
//!
//! Maps compose in call order: `a.then(b)` is `a`, then `b`. A parent's
//! transform acts after its children's.
const std = @import("std");
const types = @import("types.zig");

/// x' = a·x + c·y + x0, y' = b·x + d·y + y0: CSS's matrix(a, b, c, d, x0, y0).
pub const Affine = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    x: f32 = 0,
    y: f32 = 0,

    pub const identity: Affine = .{};

    pub fn translation(x: f32, y: f32) Affine {
        return .{ .x = x, .y = y };
    }

    /// Scales by `sx` across and `sy` down; negative values reflect.
    pub fn scaling(sx: f32, sy: f32) Affine {
        return .{ .a = sx, .d = sy };
    }

    /// Turns by `degrees`, clockwise on the screen (y goes down).
    pub fn rotation(degrees: f32) Affine {
        const turn = @mod(degrees, 360);
        // Exact quarter turns: no rounding in sin and cos.
        if (turn == 0) return .{};
        if (turn == 90) return .{ .a = 0, .b = 1, .c = -1, .d = 0 };
        if (turn == 180) return .{ .a = -1, .d = -1 };
        if (turn == 270) return .{ .a = 0, .b = -1, .c = 1, .d = 0 };
        const r = turn * std.math.pi / 180;
        const s = @sin(r);
        const co = @cos(r);
        return .{ .a = co, .b = s, .c = -s, .d = co };
    }

    /// Slants by `x` degrees along x and `y` along y, as CSS's skew().
    pub fn skewing(x: f32, y: f32) Affine {
        return .{ .c = @tan(x * std.math.pi / 180), .b = @tan(y * std.math.pi / 180) };
    }

    /// `m`, then `n`.
    pub fn then(m: Affine, n: Affine) Affine {
        return n.mul(m);
    }

    /// `m · n`: `n` acts first.
    pub fn mul(m: Affine, n: Affine) Affine {
        return .{
            .a = m.a * n.a + m.c * n.b,
            .b = m.b * n.a + m.d * n.b,
            .c = m.a * n.c + m.c * n.d,
            .d = m.b * n.c + m.d * n.d,
            .x = m.a * n.x + m.c * n.y + m.x,
            .y = m.b * n.x + m.d * n.y + m.y,
        };
    }

    pub fn translate(m: Affine, x: f32, y: f32) Affine {
        return m.then(translation(x, y));
    }

    pub fn scale(m: Affine, sx: f32, sy: f32) Affine {
        return m.then(scaling(sx, sy));
    }

    pub fn rotate(m: Affine, degrees: f32) Affine {
        return m.then(rotation(degrees));
    }

    pub fn skew(m: Affine, x: f32, y: f32) Affine {
        return m.then(skewing(x, y));
    }

    /// `m` acting about the point `o` rather than the origin.
    pub fn about(m: Affine, o: types.Point) Affine {
        return translation(o.x, o.y).mul(m).mul(translation(-o.x, -o.y));
    }

    pub fn apply(m: Affine, p: types.Point) types.Point {
        return .{ .x = m.a * p.x + m.c * p.y + m.x, .y = m.b * p.x + m.d * p.y + m.y };
    }

    pub fn det(m: Affine) f32 {
        return m.a * m.d - m.b * m.c;
    }

    /// The map back, or null for one that flattens the plane (a zero
    /// scale), which shows nothing.
    pub fn inverse(m: Affine) ?Affine {
        const dt = m.det();
        if (!(@abs(dt) > 1e-12) or !std.math.isFinite(dt)) return null;
        const k = 1 / dt;
        return .{
            .a = m.d * k,
            .b = -m.b * k,
            .c = -m.c * k,
            .d = m.a * k,
            .x = (m.c * m.y - m.d * m.x) * k,
            .y = (m.b * m.x - m.a * m.y) * k,
        };
    }

    pub fn isIdentity(m: Affine) bool {
        return m.a == 1 and m.b == 0 and m.c == 0 and m.d == 1 and m.x == 0 and m.y == 0;
    }

    /// Whether it only moves and scales alike in both directions (by a
    /// positive factor): boxes stay boxes, corners stay round, and the
    /// renderers draw it as they draw any box.
    pub fn isSimilar(m: Affine) bool {
        return m.b == 0 and m.c == 0 and m.a == m.d and m.a > 0;
    }

    /// The smallest box holding `r` mapped.
    pub fn bounds(m: Affine, r: types.Rect) types.Rect {
        const ps = [4]types.Point{
            m.apply(.{ .x = r.x, .y = r.y }),
            m.apply(.{ .x = r.x + r.w, .y = r.y }),
            m.apply(.{ .x = r.x, .y = r.y + r.h }),
            m.apply(.{ .x = r.x + r.w, .y = r.y + r.h }),
        };
        var x0 = ps[0].x;
        var y0 = ps[0].y;
        var x1 = x0;
        var y1 = y0;
        for (ps[1..]) |p| {
            x0 = @min(x0, p.x);
            y0 = @min(y0, p.y);
            x1 = @max(x1, p.x);
            y1 = @max(y1, p.y);
        }
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    pub fn finite(m: Affine) bool {
        inline for (.{ "a", "b", "c", "d", "x", "y" }) |f| if (!std.math.isFinite(@field(m, f))) return false;
        return true;
    }
};

const testing = std.testing;

test "transforms compose in call order, about an origin, and invert" {
    const p: types.Point = .{ .x = 10, .y = 0 };
    // Scale, then turn a quarter clockwise, then move.
    const m = Affine.scaling(2, 2).then(.rotation(90)).then(.translation(5, 0));
    const q = m.apply(p);
    try testing.expectApproxEqAbs(@as(f32, 5), q.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 20), q.y, 1e-5);
    const back = m.inverse().?.apply(q);
    try testing.expectApproxEqAbs(p.x, back.x, 1e-4);
    try testing.expectApproxEqAbs(p.y, back.y, 1e-4);
    // About its center, a box turned half a turn stays in place.
    const half = Affine.rotation(180).about(.{ .x = 50, .y = 20 });
    const b = half.bounds(.{ .x = 0, .y = 0, .w = 100, .h = 40 });
    try testing.expectApproxEqAbs(@as(f32, 0), b.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 100), b.w, 1e-4);
    try testing.expect(Affine.scaling(0, 1).inverse() == null);
    try testing.expect(Affine.scaling(2, 2).translate(3, 4).isSimilar());
    try testing.expect(!Affine.rotation(30).isSimilar());
    const sk = Affine.skewing(45, 0).apply(.{ .x = 0, .y = 10 });
    try testing.expectApproxEqAbs(@as(f32, 10), sk.x, 1e-4);
}
