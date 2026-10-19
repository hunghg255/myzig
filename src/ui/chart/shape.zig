//! The shapes of charts as paths, after mygo's `ui/chart`: lines and
//! areas through points (straight, monotone or in steps; a NaN breaks
//! them), pie slices and donut pieces, stacks of series, and the point
//! nearest the pointer.
const std = @import("std");
const types = @import("../types.zig");
const path_mod = @import("../path.zig");
const Path = path_mod.Path;
const Rect = types.Rect;

/// Where a fraction along the plot `r` is, in points.
pub fn x(r: Rect, f: f32) f32 {
    return r.x + f * r.w;
}

/// Where a fraction up the plot `r` is (0 at its bottom).
pub fn y(r: Rect, f: f32) f32 {
    return r.y + (1 - f) * r.h;
}

/// How a line goes from a point to the next, as d3's curves.
pub const Curve = enum {
    linear,
    /// Smooth, never past the values of the points it joins (d3's
    /// curveMonotoneX, Steffen's method).
    monotone,
    step_after,
    step_before,
    step,
};

/// Adds the line through `pts` (after its first point, where the pen is).
fn through(p: *Path, pts: []const [2]f32, k: Curve) void {
    const n = pts.len;
    if (n < 2) return;
    switch (k) {
        .monotone => if (n >= 3) {
            // Each point's slope: Steffen's inside, from the neighbors' at the ends.
            var m_buf: [512]f32 = undefined;
            const m = if (n <= m_buf.len) m_buf[0..n] else p.gpa.alloc(f32, n) catch @panic("OOM");
            defer if (n > m_buf.len) p.gpa.free(m);
            for (1..n - 1) |i| m[i] = slope3(pts[i - 1], pts[i], pts[i + 1]);
            m[0] = slope2(pts[0], pts[1], m[1]);
            m[n - 1] = slope2(pts[n - 2], pts[n - 1], m[n - 2]);
            for (1..n) |i| {
                const a = pts[i - 1];
                const b = pts[i];
                const dx = (b[0] - a[0]) / 3;
                p.cubicTo(a[0] + dx, a[1] + dx * m[i - 1], b[0] - dx, b[1] - dx * m[i], b[0], b[1]);
            }
            return;
        },
        .step_after, .step_before, .step => {
            for (1..n) |i| {
                const a = pts[i - 1];
                const b = pts[i];
                switch (k) {
                    .step_after => p.lineTo(b[0], a[1]),
                    .step_before => p.lineTo(a[0], b[1]),
                    else => {
                        const mx = (a[0] + b[0]) / 2;
                        p.lineTo(mx, a[1]);
                        p.lineTo(mx, b[1]);
                    },
                }
                p.lineTo(b[0], b[1]);
            }
            return;
        },
        .linear => {},
    }
    for (pts[1..]) |q| p.lineTo(q[0], q[1]);
}

fn slope3(a: [2]f32, b: [2]f32, c: [2]f32) f32 {
    const h0 = b[0] - a[0];
    const h1 = c[0] - b[0];
    if (h0 == 0 or h1 == 0) return 0;
    const s0 = (b[1] - a[1]) / h0;
    const s1 = (c[1] - b[1]) / h1;
    if ((s0 < 0) != (s1 < 0) or s0 == 0 or s1 == 0) return 0;
    const pp = (s0 * h1 + s1 * h0) / (h0 + h1);
    const m = @min(@min(@abs(s0), @abs(s1)), 0.5 * @abs(pp));
    return if (s0 < 0) -2 * m else 2 * m;
}

fn slope2(a: [2]f32, b: [2]f32, t: f32) f32 {
    const h = b[0] - a[0];
    if (h == 0) return t;
    return (3 * (b[1] - a[1]) / h - t) / 2;
}

/// Runs of indices whose values are numbers: a NaN breaks a line.
fn runs(ys: []const f32, i_in: usize) ?[2]usize {
    var i = i_in;
    while (i < ys.len and std.math.isNan(ys[i])) i += 1;
    if (i >= ys.len) return null;
    var j = i;
    while (j < ys.len and !std.math.isNan(ys[j])) j += 1;
    return .{ i, j };
}

/// The line through the points at `xs` and `ys` (fractions of the plot
/// `r`) into `p`.
pub fn line(p: *Path, r: Rect, xs: []const f32, ys: []const f32, k: Curve) void {
    const n = @min(xs.len, ys.len);
    var buf: std.ArrayList([2]f32) = .empty;
    defer buf.deinit(p.gpa);
    var at: usize = 0;
    while (runs(ys[0..n], at)) |run| : (at = run[1]) {
        buf.clearRetainingCapacity();
        for (run[0]..run[1]) |i| buf.append(p.gpa, .{ x(r, xs[i]), y(r, ys[i]) }) catch @panic("OOM");
        p.moveTo(buf.items[0][0], buf.items[0][1]);
        through(p, buf.items, k);
    }
}

/// The area between the lines `lo` (null: the plot's bottom) and `hi`.
pub fn area(p: *Path, r: Rect, xs: []const f32, lo: ?[]const f32, hi: []const f32, k: Curve) void {
    const n = @min(xs.len, hi.len);
    var top: std.ArrayList([2]f32) = .empty;
    defer top.deinit(p.gpa);
    var bottom: std.ArrayList([2]f32) = .empty;
    defer bottom.deinit(p.gpa);
    var at: usize = 0;
    while (runs(hi[0..n], at)) |run| : (at = run[1]) {
        top.clearRetainingCapacity();
        bottom.clearRetainingCapacity();
        for (run[0]..run[1]) |i| {
            top.append(p.gpa, .{ x(r, xs[i]), y(r, hi[i]) }) catch @panic("OOM");
            const l = if (lo) |v| (if (std.math.isNan(v[i])) 0 else v[i]) else 0;
            bottom.append(p.gpa, .{ x(r, xs[i]), y(r, l) }) catch @panic("OOM");
        }
        std.mem.reverse([2]f32, bottom.items);
        p.moveTo(top.items[0][0], top.items[0][1]);
        through(p, top.items, k);
        p.lineTo(bottom.items[0][0], bottom.items[0][1]);
        through(p, bottom.items, if (k == .step_after) .step_before else if (k == .step_before) .step_after else k);
        p.close();
    }
}

/// The index of the value of `xs` (ascending) nearest `f`, null for none.
pub fn nearest(xs: []const f32, f: f32) ?usize {
    if (xs.len == 0) return null;
    var lo: usize = 0;
    var hi: usize = xs.len;
    while (lo < hi) {
        const m = (lo + hi) / 2;
        if (xs[m] < f) lo = m + 1 else hi = m;
    }
    if (lo == xs.len) return lo - 1;
    if (lo > 0 and f - xs[lo - 1] <= xs[lo] - f) return lo - 1;
    return lo;
}

/// A value's part of a pie, in radians clockwise from twelve o'clock.
pub const Slice = struct {
    start: f64,
    end: f64,
    pad: f64 = 0,

    pub fn mid(s: Slice) f64 {
        return (s.start + s.end) / 2;
    }
};

/// Divides a circle among `values` in their order from twelve o'clock,
/// `pad` radians between slices; values below 0, and NaN, take no room.
pub fn pie(gpa: std.mem.Allocator, values: []const f64, pad_in: f64) ![]Slice {
    var sum: f64 = 0;
    for (values) |v| if (v > 0) {
        sum += v;
    };
    const n: f64 = @floatFromInt(values.len);
    const pad = std.math.clamp(pad_in, 0, 2 * std.math.pi / @max(n, 1));
    const k = if (sum > 0) (2 * std.math.pi - n * pad) / sum else 0;
    const out = try gpa.alloc(Slice, values.len);
    var a: f64 = 0;
    for (values, out) |v, *s| {
        var end = a + pad;
        if (v > 0) end += v * k;
        s.* = .{ .start = a, .end = end, .pad = pad };
        a = end;
    }
    return out;
}

/// The point at angle `a` (clockwise from twelve o'clock), `r` from (cx, cy).
pub fn polar(cx: f32, cy: f32, r: f32, a: f64) [2]f32 {
    return .{ cx + r * @as(f32, @floatCast(@sin(a))), cy - r * @as(f32, @floatCast(@cos(a))) };
}

/// A slice between the radii `inner` and `outer`: a wedge with inner 0,
/// a piece of a donut otherwise, its pad a gap of even width.
pub fn sector(p: *Path, cx: f32, cy: f32, inner_in: f32, outer: f32, s: Slice) void {
    if (outer <= 0 or s.end <= s.start) return;
    const inner = std.math.clamp(inner_in, 0, outer);
    const gap = s.pad * @sqrt(@as(f64, inner * inner + outer * outer));
    const Angles = struct {
        fn of(sl: Slice, g: f64, r: f32) [2]f64 {
            if (g > 0 and r > 0) {
                const d = std.math.asin(@min(1, g / 2 / @as(f64, r)));
                if (sl.end - sl.start > 2 * d) return .{ sl.start + d, sl.end - d };
                return .{ sl.mid(), sl.mid() };
            }
            return .{ sl.start, sl.end };
        }
    };
    const a = Angles.of(s, gap, outer);
    const start = polar(cx, cy, outer, a[0]);
    p.moveTo(start[0], start[1]);
    arc(p, cx, cy, outer, a[0], a[1]);
    if (inner > 0) {
        const b = Angles.of(s, gap, inner);
        const q = polar(cx, cy, inner, b[1]);
        p.lineTo(q[0], q[1]);
        arc(p, cx, cy, inner, b[1], b[0]);
    } else p.lineTo(cx, cy);
    p.close();
}

fn arc(p: *Path, cx: f32, cy: f32, r: f32, a0: f64, a1: f64) void {
    const n: usize = @intFromFloat(@ceil(@abs(a1 - a0) / (std.math.pi / 2.0)));
    if (n == 0) return;
    const step = (a1 - a0) / @as(f64, @floatFromInt(n));
    const k: f32 = @floatCast(4.0 / 3.0 * @tan(step / 4));
    for (0..n) |i| {
        const b0 = a0 + @as(f64, @floatFromInt(i)) * step;
        const b1 = b0 + step;
        const q0 = polar(cx, cy, r, b0);
        const q1 = polar(cx, cy, r, b1);
        const t0: [2]f32 = .{ @floatCast(@cos(b0)), @floatCast(@sin(b0)) };
        const t1: [2]f32 = .{ @floatCast(@cos(b1)), @floatCast(@sin(b1)) };
        p.cubicTo(q0[0] + k * r * t0[0], q0[1] + k * r * t0[1], q1[0] - k * r * t1[0], q1[1] - k * r * t1[1], q1[0], q1[1]);
    }
}

/// The slice at (dx, dy) from the center of a pie whose slices go from
/// `inner` to `outer`.
pub fn sliceAt(slices: []const Slice, dx: f32, dy: f32, inner: f32, outer: f32) ?usize {
    const d = std.math.hypot(dx, dy);
    if (d < inner or d > outer) return null;
    var a = std.math.atan2(@as(f64, dx), -@as(f64, dy));
    if (a < 0) a += 2 * std.math.pi;
    for (slices, 0..) |s, i| if (a >= s.start and a < s.end) return i;
    return null;
}

/// A value's stretch in a stack.
pub const Segment = struct { lo: f64, hi: f64 };

pub const Stacking = enum {
    /// Up from 0, and negative values down from it.
    standard,
    /// As standard, in shares of the stack's sum.
    normalized,
    /// Around 0, as a streamgraph.
    center,
};

/// Piles series up: `series[s][i]` is the i-th value of the s-th series,
/// and the result's `[s][i]` where it goes in the i-th stack.
pub fn stack(gpa: std.mem.Allocator, series: []const []const f64, how: Stacking) ![][]Segment {
    var n: usize = 0;
    for (series) |s| n = @max(n, s.len);
    const out = try gpa.alloc([]Segment, series.len);
    for (out) |*o| o.* = try gpa.alloc(Segment, n);
    for (0..n) |i| {
        var up: f64 = 0;
        var down: f64 = 0;
        var total: f64 = 0;
        for (series, 0..) |s, k| {
            const v = if (i < s.len and !std.math.isNan(s[i])) s[i] else 0;
            total += @abs(v);
            if (how == .center or v >= 0) {
                out[k][i] = .{ .lo = up, .hi = up + v };
                up += v;
            } else {
                out[k][i] = .{ .lo = down + v, .hi = down };
                down += v;
            }
        }
        const shift: f64 = if (how == .center) -up / 2 else 0;
        const scale: f64 = if (how == .normalized and total > 0) 1 / total else 1;
        for (out) |o| o[i] = .{ .lo = (o[i].lo + shift) * scale, .hi = (o[i].hi + shift) * scale };
    }
    return out;
}

test "nearest, pies and stacks" {
    try std.testing.expectEqual(@as(?usize, 1), nearest(&.{ 0, 0.5, 1 }, 0.6));
    try std.testing.expectEqual(@as(?usize, 2), nearest(&.{ 0, 0.5, 1 }, 2));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sl = try pie(a, &.{ 1, 1, 2 }, 0);
    try std.testing.expectApproxEqAbs(std.math.pi, sl[2].start, 1e-9);
    // Right of the center is a quarter turn: the first slice.
    try std.testing.expectEqual(@as(?usize, 0), sliceAt(sl, 10, -1, 0, 20));
    try std.testing.expectEqual(@as(?usize, 2), sliceAt(sl, -10, 0, 0, 20));
    try std.testing.expectEqual(@as(?usize, null), sliceAt(sl, 30, 0, 0, 20));
    const st = try stack(a, &.{ &.{ 1, -2 }, &.{ 3, 4 } }, .standard);
    try std.testing.expectEqual(Segment{ .lo = 1, .hi = 4 }, st[1][0]);
    try std.testing.expectEqual(Segment{ .lo = -2, .hi = 0 }, st[0][1]);
    const norm = try stack(a, &.{ &.{ 1, 1 }, &.{ 3, 1 } }, .normalized);
    try std.testing.expectEqual(@as(f64, 1), norm[1][0].hi);
}

test "a monotone line stays within its points' values; a NaN breaks it" {
    const gpa = std.testing.allocator;
    var p: Path = .init(gpa);
    defer p.deinit();
    const r: Rect = .{ .w = 100, .h = 100 };
    line(&p, r, &.{ 0, 0.5, 1 }, &.{ 0, 1, 1 }, .monotone);
    for (p.pts.items) |q| try std.testing.expect(q[1] >= -0.001 and q[1] <= 100.001);
    p.reset();
    line(&p, r, &.{ 0, 0.25, 0.5, 0.75 }, &.{ 0, 1, std.math.nan(f32), 1 }, .linear);
    try std.testing.expectEqualSlices(path_mod.Verb, &.{ .move, .line, .move }, p.verbs.items);
}
