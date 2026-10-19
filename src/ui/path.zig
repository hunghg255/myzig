//! Paths of lines and curves, as a canvas, SVG and charts draw them
//! (`ui.canvas`): moves, lines, quadratic and cubic curves, arcs and
//! closes, in the units of whoever builds them, and the affine transforms
//! that place them. `flatten` turns a path into polylines, the curves cut
//! into lines no farther than a tolerance from them, for the rasterizer
//! (`path_raster.zig`) and the stroker (`path_stroke.zig`).
const std = @import("std");

pub const Point = [2]f32;

pub const Verb = enum(u8) { move, line, quad, cubic, close };

/// How the inside of a path is told from its outside: where its contours
/// wind around a point any number of times, or an odd number of times.
pub const Rule = enum(u8) { nonzero, evenodd };

/// An affine transform, as SVG's `matrix(a b c d e f)`: a point (x, y)
/// goes to (a x + c y + e, b x + d y + f).
pub const Transform = extern struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    e: f32 = 0,
    f: f32 = 0,

    pub const identity: Transform = .{};

    pub fn translation(x: f32, y: f32) Transform {
        return .{ .e = x, .f = y };
    }

    pub fn scaling(sx: f32, sy: f32) Transform {
        return .{ .a = sx, .d = sy };
    }

    /// A turn by `rad` radians, clockwise on the screen (y goes down).
    pub fn rotation(rad: f32) Transform {
        const s = @sin(rad);
        const co = @cos(rad);
        return .{ .a = co, .b = s, .c = -s, .d = co };
    }

    pub fn skewX(rad: f32) Transform {
        return .{ .c = @tan(rad) };
    }

    pub fn skewY(rad: f32) Transform {
        return .{ .b = @tan(rad) };
    }

    /// `t`, then `u`: points go through `t` first.
    pub fn then(t: Transform, u: Transform) Transform {
        return .{
            .a = u.a * t.a + u.c * t.b,
            .b = u.b * t.a + u.d * t.b,
            .c = u.a * t.c + u.c * t.d,
            .d = u.b * t.c + u.d * t.d,
            .e = u.a * t.e + u.c * t.f + u.e,
            .f = u.b * t.e + u.d * t.f + u.f,
        };
    }

    pub fn apply(t: Transform, p: Point) Point {
        return .{ t.a * p[0] + t.c * p[1] + t.e, t.b * p[0] + t.d * p[1] + t.f };
    }

    pub fn invert(t: Transform) ?Transform {
        const det = t.a * t.d - t.b * t.c;
        if (det == 0 or !std.math.isFinite(det)) return null;
        const k = 1 / det;
        return .{
            .a = t.d * k,
            .b = -t.b * k,
            .c = -t.c * k,
            .d = t.a * k,
            .e = (t.c * t.f - t.d * t.e) * k,
            .f = (t.b * t.e - t.a * t.f) * k,
        };
    }

    /// The most it stretches a length, in any direction: tolerances in
    /// device pixels divide by it to become tolerances before it.
    pub fn stretch(t: Transform) f32 {
        const p = (t.a * t.a + t.b * t.b + t.c * t.c + t.d * t.d) / 2;
        const h = (t.a * t.a + t.b * t.b - t.c * t.c - t.d * t.d) / 2;
        const q = @sqrt(h * h + (t.a * t.c + t.b * t.d) * (t.a * t.c + t.b * t.d));
        return @sqrt(p + q);
    }
};

/// A path's verbs and points, as recorded: one point for a move or a
/// line, two for a quadratic curve, three for a cubic one, none for a close.
pub const Data = struct {
    verbs: []const Verb = &.{},
    pts: []const Point = &.{},

    pub fn dupe(d: Data, gpa: std.mem.Allocator) !Data {
        return .{ .verbs = try gpa.dupe(Verb, d.verbs), .pts = try gpa.dupe(Point, d.pts) };
    }

    /// Its points' extent, control points included: [x0, y0, x1, y1].
    pub fn bounds(d: Data) [4]f32 {
        var b: [4]f32 = .{ std.math.inf(f32), std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
        for (d.pts) |p| b = .{ @min(b[0], p[0]), @min(b[1], p[1]), @max(b[2], p[0]), @max(b[3], p[1]) };
        if (d.pts.len == 0) return .{ 0, 0, 0, 0 };
        return b;
    }
};

/// A path being built. Its memory is `gpa`'s: the frame's (`p.path()` in
/// a canvas's draw function) or the app's, kept and drawn again.
pub const Path = struct {
    gpa: std.mem.Allocator,
    verbs: std.ArrayList(Verb) = .empty,
    pts: std.ArrayList(Point) = .empty,
    /// The pen, where the open subpath began, and whether there is one.
    cur: Point = .{ 0, 0 },
    start: Point = .{ 0, 0 },
    has_pen: bool = false,

    pub fn init(gpa: std.mem.Allocator) Path {
        return .{ .gpa = gpa };
    }

    pub fn deinit(p: *Path) void {
        p.verbs.deinit(p.gpa);
        p.pts.deinit(p.gpa);
    }

    /// Empties it, keeping its memory, to build another.
    pub fn reset(p: *Path) void {
        p.verbs.clearRetainingCapacity();
        p.pts.clearRetainingCapacity();
        p.has_pen = false;
    }

    pub fn data(p: *const Path) Data {
        return .{ .verbs = p.verbs.items, .pts = p.pts.items };
    }

    fn push(p: *Path, v: Verb, pts: []const Point) void {
        p.verbs.append(p.gpa, v) catch @panic("OOM");
        p.pts.appendSlice(p.gpa, pts) catch @panic("OOM");
    }

    /// Where the pen is, starting a subpath there when there is none.
    fn pen(p: *Path) Point {
        if (!p.has_pen) p.moveTo(p.cur[0], p.cur[1]);
        return p.cur;
    }

    pub fn moveTo(p: *Path, x: f32, y: f32) void {
        p.push(.move, &.{.{ x, y }});
        p.cur = .{ x, y };
        p.start = p.cur;
        p.has_pen = true;
    }

    pub fn lineTo(p: *Path, x: f32, y: f32) void {
        _ = p.pen();
        p.push(.line, &.{.{ x, y }});
        p.cur = .{ x, y };
    }

    pub fn quadTo(p: *Path, cx: f32, cy: f32, x: f32, y: f32) void {
        _ = p.pen();
        p.push(.quad, &.{ .{ cx, cy }, .{ x, y } });
        p.cur = .{ x, y };
    }

    pub fn cubicTo(p: *Path, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32) void {
        _ = p.pen();
        p.push(.cubic, &.{ .{ c1x, c1y }, .{ c2x, c2y }, .{ x, y } });
        p.cur = .{ x, y };
    }

    /// Closes the subpath with a line back to where it began; the pen goes
    /// there, and what follows continues from it.
    pub fn close(p: *Path) void {
        if (!p.has_pen) return;
        p.push(.close, &.{});
        p.cur = p.start;
        p.has_pen = false;
    }

    /// An arc of the circle around (cx, cy), from the angle `a0` to `a1`
    /// (radians from the +x axis, growing clockwise on the screen), the
    /// other way round when `ccw`, as Canvas 2D's `arc`: a line goes to its
    /// start from the pen, if there is one.
    pub fn arc(p: *Path, cx: f32, cy: f32, r: f32, a0: f32, a1: f32, ccw: bool) void {
        const tau = 2 * std.math.pi;
        var sweep = a1 - a0;
        if (!ccw) {
            if (sweep >= tau) sweep = tau else if (sweep < 0) sweep = @mod(sweep, tau);
        } else {
            if (sweep <= -tau) sweep = -tau else if (sweep > 0) sweep = @mod(sweep, tau) - tau;
        }
        const sx = cx + r * @cos(a0);
        const sy = cy + r * @sin(a0);
        if (p.has_pen) p.lineTo(sx, sy) else p.moveTo(sx, sy);
        arcCubics(p, cx, cy, r, r, 0, a0, sweep);
    }

    /// SVG's elliptical arc (`A rx ry rotation large sweep x y`) from the
    /// pen to (x, y), in cubic curves.
    pub fn svgArc(p: *Path, rx_in: f32, ry_in: f32, rotation_deg: f32, large: bool, sweep_flag: bool, x: f32, y: f32) void {
        const from = p.pen();
        var rx = @abs(rx_in);
        var ry = @abs(ry_in);
        if (from[0] == x and from[1] == y) return;
        if (rx == 0 or ry == 0) return p.lineTo(x, y);
        const phi = rotation_deg * std.math.pi / 180;
        const cphi = @cos(phi);
        const sphi = @sin(phi);
        // The endpoints' middle, in the ellipse's own axes (SVG F.6.5).
        const dx = (from[0] - x) / 2;
        const dy = (from[1] - y) / 2;
        const x1 = cphi * dx + sphi * dy;
        const y1 = -sphi * dx + cphi * dy;
        // Radii too small to reach are scaled up (F.6.6).
        const lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
        if (lambda > 1) {
            rx *= @sqrt(lambda);
            ry *= @sqrt(lambda);
        }
        const num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
        const den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
        var k = @sqrt(@max(0, num / den));
        if (large == sweep_flag) k = -k;
        const cxp = k * rx * y1 / ry;
        const cyp = -k * ry * x1 / rx;
        const cx = cphi * cxp - sphi * cyp + (from[0] + x) / 2;
        const cy = sphi * cxp + cphi * cyp + (from[1] + y) / 2;
        const ux = (x1 - cxp) / rx;
        const uy = (y1 - cyp) / ry;
        const vx = (-x1 - cxp) / rx;
        const vy = (-y1 - cyp) / ry;
        const theta = std.math.atan2(uy, ux);
        var delta = std.math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
        if (!sweep_flag and delta > 0) delta -= 2 * std.math.pi;
        if (sweep_flag and delta < 0) delta += 2 * std.math.pi;
        arcCubics(p, cx, cy, rx, ry, phi, theta, delta);
        // Exactly at the end, whatever rounding did.
        p.pts.items[p.pts.items.len - 1] = .{ x, y };
        p.cur = .{ x, y };
    }

    pub fn rect(p: *Path, x: f32, y: f32, w: f32, h: f32) void {
        p.moveTo(x, y);
        p.lineTo(x + w, y);
        p.lineTo(x + w, y + h);
        p.lineTo(x, y + h);
        p.close();
    }

    /// A rectangle with corners rounded by `rx` and `ry` (each at most half
    /// its side), clockwise from the top left.
    pub fn roundRect(p: *Path, x: f32, y: f32, w: f32, h: f32, rx_in: f32, ry_in: f32) void {
        const rx = @min(@max(0, rx_in), w / 2);
        const ry = @min(@max(0, ry_in), h / 2);
        if (rx == 0 or ry == 0) return p.rect(x, y, w, h);
        const k = 0.5522847498;
        p.moveTo(x + rx, y);
        p.lineTo(x + w - rx, y);
        p.cubicTo(x + w - rx + rx * k, y, x + w, y + ry - ry * k, x + w, y + ry);
        p.lineTo(x + w, y + h - ry);
        p.cubicTo(x + w, y + h - ry + ry * k, x + w - rx + rx * k, y + h, x + w - rx, y + h);
        p.lineTo(x + rx, y + h);
        p.cubicTo(x + rx - rx * k, y + h, x, y + h - ry + ry * k, x, y + h - ry);
        p.lineTo(x, y + ry);
        p.cubicTo(x, y + ry - ry * k, x + rx - rx * k, y, x + rx, y);
        p.close();
    }

    pub fn ellipse(p: *Path, cx: f32, cy: f32, rx: f32, ry: f32) void {
        p.moveTo(cx + rx, cy);
        arcCubics(p, cx, cy, rx, ry, 0, 0, 2 * std.math.pi);
        p.close();
    }

    pub fn circle(p: *Path, cx: f32, cy: f32, r: f32) void {
        p.ellipse(cx, cy, r, r);
    }

    /// Lines through `pts`, closed when `closed` (a polygon).
    pub fn polyline(p: *Path, pts: []const Point, closed: bool) void {
        for (pts, 0..) |q, i| if (i == 0) p.moveTo(q[0], q[1]) else p.lineTo(q[0], q[1]);
        if (closed and pts.len > 0) p.close();
    }

    /// Adds another path's verbs, transformed by `t`.
    pub fn append(p: *Path, d: Data, t: Transform) void {
        var i: usize = 0;
        for (d.verbs) |v| {
            const n: usize = switch (v) {
                .move, .line => 1,
                .quad => 2,
                .cubic => 3,
                .close => 0,
            };
            var q: [3]Point = undefined;
            for (0..n) |k| q[k] = t.apply(d.pts[i + k]);
            i += n;
            switch (v) {
                .move => p.moveTo(q[0][0], q[0][1]),
                .line => p.lineTo(q[0][0], q[0][1]),
                .quad => p.quadTo(q[0][0], q[0][1], q[1][0], q[1][1]),
                .cubic => p.cubicTo(q[0][0], q[0][1], q[1][0], q[1][1], q[2][0], q[2][1]),
                .close => p.close(),
            }
        }
    }
};

/// Cubic curves along the ellipse around (cx, cy), its axes turned by
/// `phi`, from the angle `theta` through `delta`, at most a quarter turn each.
fn arcCubics(p: *Path, cx: f32, cy: f32, rx: f32, ry: f32, phi: f32, theta: f32, delta: f32) void {
    const n: usize = @intFromFloat(@max(1, @ceil(@abs(delta) / (std.math.pi / 2.0) - 0.001)));
    const step = delta / @as(f32, @floatFromInt(n));
    const k = 4.0 / 3.0 * @tan(step / 4);
    const cphi = @cos(phi);
    const sphi = @sin(phi);
    const on = struct {
        fn f(ccx: f32, ccy: f32, a: f32, b: f32, cp: f32, sp: f32, x: f32, y: f32) Point {
            return .{ ccx + cp * a * x - sp * b * y, ccy + sp * a * x + cp * b * y };
        }
    }.f;
    for (0..n) |i| {
        const t0 = theta + step * @as(f32, @floatFromInt(i));
        const t1 = t0 + step;
        const c0 = @cos(t0);
        const s0 = @sin(t0);
        const c1 = @cos(t1);
        const s1 = @sin(t1);
        const q1 = on(cx, cy, rx, ry, cphi, sphi, c0 - k * s0, s0 + k * c0);
        const q2 = on(cx, cy, rx, ry, cphi, sphi, c1 + k * s1, s1 - k * c1);
        const q3 = on(cx, cy, rx, ry, cphi, sphi, c1, s1);
        p.cubicTo(q1[0], q1[1], q2[0], q2[1], q3[0], q3[1]);
    }
}

/// Polylines: runs of points, each open or closed.
pub const Polylines = struct {
    pts: std.ArrayList(Point) = .empty,
    runs: std.ArrayList(Run) = .empty,

    pub const Run = struct { start: u32, len: u32, closed: bool };

    pub fn deinit(pl: *Polylines, gpa: std.mem.Allocator) void {
        pl.pts.deinit(gpa);
        pl.runs.deinit(gpa);
    }

    pub fn clear(pl: *Polylines) void {
        pl.pts.clearRetainingCapacity();
        pl.runs.clearRetainingCapacity();
    }

    pub fn run(pl: *const Polylines, r: Run) []const Point {
        return pl.pts.items[r.start..][0..r.len];
    }
};

/// Most segments a curve is cut into.
const max_steps = 256;

/// The path through `t` as polylines in `out`, curves cut into lines
/// within `tol` of them (in the units after `t`).
pub fn flatten(gpa: std.mem.Allocator, d: Data, t: Transform, tol_in: f32, out: *Polylines) !void {
    const tol = @max(tol_in, 0.001);
    var open: ?u32 = null;
    var cur: Point = .{ 0, 0 };
    var start: Point = .{ 0, 0 };
    var i: usize = 0;
    const State = struct {
        fn begin(o: *Polylines, g: std.mem.Allocator, at: Point, op: *?u32) !void {
            try o.runs.append(g, .{ .start = @intCast(o.pts.items.len), .len = 1, .closed = false });
            try o.pts.append(g, at);
            op.* = @intCast(o.runs.items.len - 1);
        }
        fn add(o: *Polylines, g: std.mem.Allocator, at: Point, op: ?u32) !void {
            try o.pts.append(g, at);
            o.runs.items[op.?].len += 1;
        }
    };
    for (d.verbs) |v| switch (v) {
        .move => {
            cur = t.apply(d.pts[i]);
            start = cur;
            i += 1;
            try State.begin(out, gpa, cur, &open);
        },
        .line => {
            if (open == null) try State.begin(out, gpa, cur, &open);
            cur = t.apply(d.pts[i]);
            i += 1;
            try State.add(out, gpa, cur, open);
        },
        .quad => {
            if (open == null) try State.begin(out, gpa, cur, &open);
            const c1 = t.apply(d.pts[i]);
            const end = t.apply(d.pts[i + 1]);
            i += 2;
            const ddx = cur[0] - 2 * c1[0] + end[0];
            const ddy = cur[1] - 2 * c1[1] + end[1];
            const n = steps(@sqrt(ddx * ddx + ddy * ddy) / (4 * tol));
            for (1..n + 1) |s| {
                const u = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(n));
                const m = 1 - u;
                try State.add(out, gpa, .{
                    m * m * cur[0] + 2 * m * u * c1[0] + u * u * end[0],
                    m * m * cur[1] + 2 * m * u * c1[1] + u * u * end[1],
                }, open);
            }
            cur = end;
        },
        .cubic => {
            if (open == null) try State.begin(out, gpa, cur, &open);
            const c1 = t.apply(d.pts[i]);
            const c2 = t.apply(d.pts[i + 1]);
            const end = t.apply(d.pts[i + 2]);
            i += 3;
            const d1 = std.math.hypot(cur[0] - 2 * c1[0] + c2[0], cur[1] - 2 * c1[1] + c2[1]);
            const d2 = std.math.hypot(c1[0] - 2 * c2[0] + end[0], c1[1] - 2 * c2[1] + end[1]);
            const n = steps(3 * @max(d1, d2) / (4 * tol));
            for (1..n + 1) |s| {
                const u = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(n));
                const m = 1 - u;
                try State.add(out, gpa, .{
                    m * m * m * cur[0] + 3 * m * m * u * c1[0] + 3 * m * u * u * c2[0] + u * u * u * end[0],
                    m * m * m * cur[1] + 3 * m * m * u * c1[1] + 3 * m * u * u * c2[1] + u * u * u * end[1],
                }, open);
            }
            cur = end;
        },
        .close => {
            if (open) |r| out.runs.items[r].closed = true;
            open = null;
            cur = start;
        },
    };
}

/// Segments for a curve whose error with one segment is `e2` (it falls
/// with the square of their number).
fn steps(e2: f32) usize {
    if (!(e2 > 1)) return 1;
    const n = @ceil(@sqrt(e2));
    return @intFromFloat(@min(n, max_steps));
}

test "transforms compose, apply and invert" {
    const t = Transform.translation(10, 0).then(.scaling(2, 3));
    const q = t.apply(.{ 1, 1 });
    try std.testing.expectApproxEqAbs(@as(f32, 22), q[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 3), q[1], 1e-5);
    const back = t.invert().?.apply(q);
    try std.testing.expectApproxEqAbs(@as(f32, 1), back[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 3), Transform.scaling(2, 3).stretch(), 1e-5);
    const r = Transform.rotation(std.math.pi / 2.0).apply(.{ 1, 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 1), r[1], 1e-5);
}

test "a circle flattens within the tolerance, and arcs end where SVG says" {
    const gpa = std.testing.allocator;
    var p: Path = .init(gpa);
    defer p.deinit();
    p.circle(50, 50, 40);
    var pl: Polylines = .{};
    defer pl.deinit(gpa);
    try flatten(gpa, p.data(), .identity, 0.1, &pl);
    try std.testing.expectEqual(@as(usize, 1), pl.runs.items.len);
    try std.testing.expect(pl.runs.items[0].closed);
    for (pl.run(pl.runs.items[0])) |q| try std.testing.expectApproxEqAbs(@as(f32, 40), std.math.hypot(q[0] - 50, q[1] - 50), 0.05);
    p.reset();
    p.moveTo(0, 0);
    p.svgArc(10, 10, 0, false, true, 20, 0);
    // A half circle above the line, through (10, -10).
    try std.testing.expectEqual(@as(usize, 3), p.verbs.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, -10), p.pts.items[3][1], 1e-3);
    try std.testing.expectEqual(Point{ 20, 0 }, p.pts.items[p.pts.items.len - 1]);
}
