//! A 2D camera, as raylib's `Camera2D`: it looks at the world's point
//! `x, y`, which shows at the middle of the view, `zoom` times as large,
//! turned `rotation` degrees; and `integerFit` for pixel art shown at the
//! largest whole multiple of its size that fits, letterboxed.
const std = @import("std");
const ui = @import("myzig").ui;

/// An affine transform: screen = (a·x + c·y + tx, b·x + d·y + ty).
pub const Transform = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    tx: f32 = 0,
    ty: f32 = 0,

    pub fn apply(t: Transform, x: f32, y: f32) [2]f32 {
        return .{ t.a * x + t.c * y + t.tx, t.b * x + t.d * y + t.ty };
    }

    pub fn invert(t: Transform) Transform {
        const det = t.a * t.d - t.b * t.c;
        const ia = t.d / det;
        const ib = -t.b / det;
        const ic = -t.c / det;
        const id = t.a / det;
        return .{ .a = ia, .b = ib, .c = ic, .d = id, .tx = -(ia * t.tx + ic * t.ty), .ty = -(ib * t.tx + id * t.ty) };
    }
};

pub const Camera = struct {
    x: f32 = 0,
    y: f32 = 0,
    zoom: f32 = 1,
    /// Degrees, clockwise.
    rotation: f32 = 0,

    /// World to the view `r` (a rect of the screen, in points). Unturned,
    /// the world moves by whole pixels of a screen of `scale` pixels a
    /// point, so tiles drawn at whole units keep their edges on them.
    pub fn transform(cam: Camera, r: ui.Rect, scale: f32) Transform {
        const rad = cam.rotation * std.math.pi / 180;
        const cos = @cos(rad) * cam.zoom;
        const sin = @sin(rad) * cam.zoom;
        const cx = r.x + r.w / 2;
        const cy = r.y + r.h / 2;
        var tx = cx - (cos * cam.x - sin * cam.y);
        var ty = cy - (sin * cam.x + cos * cam.y);
        if (cam.rotation == 0 and scale > 0) {
            tx = @round(tx * scale) / scale;
            ty = @round(ty * scale) / scale;
        }
        return .{ .a = cos, .b = sin, .c = -sin, .d = cos, .tx = tx, .ty = ty };
    }

    pub fn toScreen(cam: Camera, r: ui.Rect, scale: f32, x: f32, y: f32) [2]f32 {
        return cam.transform(r, scale).apply(x, y);
    }

    /// A point of the view (the pointer) in the world.
    pub fn toWorld(cam: Camera, r: ui.Rect, scale: f32, sx: f32, sy: f32) [2]f32 {
        return cam.transform(r, scale).invert().apply(sx, sy);
    }

    /// The world's part in view: a rect that covers it, turned or not.
    pub fn visible(cam: Camera, r: ui.Rect, scale: f32) ui.Rect {
        const inv = cam.transform(r, scale).invert();
        const corners = [_][2]f32{ inv.apply(r.x, r.y), inv.apply(r.x + r.w, r.y), inv.apply(r.x, r.y + r.h), inv.apply(r.x + r.w, r.y + r.h) };
        var lo = corners[0];
        var hi = corners[0];
        for (corners[1..]) |p| {
            lo = .{ @min(lo[0], p[0]), @min(lo[1], p[1]) };
            hi = .{ @max(hi[0], p[0]), @max(hi[1], p[1]) };
        }
        return .{ .x = lo[0], .y = lo[1], .w = hi[0] - lo[0], .h = hi[1] - lo[1] };
    }

    /// A world rect on the screen; null when it is out of view. Exact
    /// unturned (boxes are axis-aligned); turned, the rect around it.
    pub fn rect(cam: Camera, r: ui.Rect, scale: f32, world: ui.Rect) ?ui.Rect {
        const t = cam.transform(r, scale);
        const p0 = t.apply(world.x, world.y);
        const p1 = t.apply(world.x + world.w, world.y + world.h);
        const p2 = t.apply(world.x + world.w, world.y);
        const p3 = t.apply(world.x, world.y + world.h);
        const x0 = @min(@min(p0[0], p1[0]), @min(p2[0], p3[0]));
        const y0 = @min(@min(p0[1], p1[1]), @min(p2[1], p3[1]));
        const x1 = @max(@max(p0[0], p1[0]), @max(p2[0], p3[0]));
        const y1 = @max(@max(p0[1], p1[1]), @max(p2[1], p3[1]));
        if (x1 < r.x or y1 < r.y or x0 > r.x + r.w or y0 > r.y + r.h) return null;
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
};

/// The largest whole multiple of `w` × `h` that fits in `r`, centered:
/// the rect to show a canvas of that logical size in, and its scale.
pub fn integerFit(w: f32, h: f32, r: ui.Rect) struct { ui.Rect, f32 } {
    const k = @max(1, @floor(@min(r.w / w, r.h / h)));
    const dw = w * k;
    const dh = h * k;
    return .{ .{ .x = r.x + @floor((r.w - dw) / 2), .y = r.y + @floor((r.h - dh) / 2), .w = dw, .h = dh }, k };
}

test "the camera's point shows at the middle, zoomed, and back" {
    const view: ui.Rect = .{ .w = 200, .h = 100 };
    const cam: Camera = .{ .x = 50, .y = 20, .zoom = 2 };
    const p = cam.toScreen(view, 1, 50, 20);
    try std.testing.expectEqual([2]f32{ 100, 50 }, p);
    try std.testing.expectEqual([2]f32{ 120, 50 }, cam.toScreen(view, 1, 60, 20));
    const w = cam.toWorld(view, 1, 120, 50);
    try std.testing.expectApproxEqAbs(@as(f32, 60), w[0], 1e-4);
    const vis = cam.visible(view, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0), vis.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 100), vis.w, 1e-4);
    try std.testing.expectEqual(null, cam.rect(view, 1, .{ .x = 500, .y = 0, .w = 10, .h = 10 }));
    const r = cam.rect(view, 1, .{ .x = 50, .y = 20, .w = 10, .h = 5 }).?;
    try std.testing.expectEqual(ui.Rect{ .x = 100, .y = 50, .w = 20, .h = 10 }, r);
}

test "unturned, the world moves by whole pixels; turned, a quarter turn maps right to down" {
    const view: ui.Rect = .{ .w = 100, .h = 100 };
    const t = (Camera{ .x = 0.3 }).transform(view, 2);
    try std.testing.expectEqual(@as(f32, 49.5), t.tx);
    const turned: Camera = .{ .rotation = 90 };
    const p = turned.toScreen(view, 1, 10, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 50), p[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 60), p[1], 1e-4);
}

test integerFit {
    const r, const k = integerFit(480, 270, .{ .w = 1280, .h = 800 });
    try std.testing.expectEqual(@as(f32, 2), k);
    try std.testing.expectEqual(ui.Rect{ .x = 160, .y = 130, .w = 960, .h = 540 }, r);
}
