//! Strokes as polygons: each segment of a polyline becomes a rectangle
//! along it, each corner a join (a miter, a bevel or a round wedge) on its
//! outer side, each open end a cap, and dashes cut the polylines into
//! pieces first. Every polygon is wound the same way, so a nonzero fill of
//! them all (`path_raster.zig`) is their union: the stroke. A polyline's
//! directions are found once, shared by its segments and joins, and its
//! segments are wound as they are made, so dense polylines (a chart's
//! thousands of points) cost little more than their edges.
const std = @import("std");
const path = @import("path.zig");
const Point = path.Point;

pub const Join = enum(u8) { miter, round, bevel };

/// The most steps an arc of a round join or cap is cut into.
const max_arc = 256;
pub const Cap = enum(u8) { butt, round, square };

pub const Stroke = struct {
    width: f32 = 1,
    join: Join = .miter,
    cap: Cap = .butt,
    /// Longest a miter may be, in widths of the stroke, before it is beveled.
    miter_limit: f32 = 4,
    /// Lengths on and off, repeated (an odd count is taken twice); empty
    /// for a solid line.
    dash: []const f32 = &.{},
    dash_offset: f32 = 0,
};

/// Turns polylines into polygons, handed to `sink.polygon(pts)`; `tol` is
/// how far round joins and caps may be from circles, in the polylines' units.
pub fn Stroker(comptime Sink: type) type {
    return struct {
        const Self = @This();
        gpa: std.mem.Allocator,
        sink: Sink,
        style: Stroke,
        tol: f32,
        buf: std.ArrayList(Point) = .empty,
        clean: std.ArrayList(Point) = .empty,
        /// The unit direction of each segment of the polyline.
        dirs: std.ArrayList(Point) = .empty,

        pub fn deinit(s: *Self) void {
            s.buf.deinit(s.gpa);
            s.clean.deinit(s.gpa);
            s.dirs.deinit(s.gpa);
        }

        pub fn polylines(s: *Self, pl: *const path.Polylines) !void {
            if (!(s.style.width > 0)) return;
            if (dashed(s.style.dash)) {
                for (pl.runs.items) |r| try s.dashes(pl.run(r), r.closed);
            } else for (pl.runs.items) |r| try s.polyline(pl.run(r), r.closed);
        }

        /// One polyline, its consecutive repeated points dropped.
        pub fn polyline(s: *Self, raw: []const Point, closed_in: bool) !void {
            s.clean.clearRetainingCapacity();
            for (raw) |p| {
                if (s.clean.items.len > 0 and same(s.clean.items[s.clean.items.len - 1], p)) continue;
                try s.clean.append(s.gpa, p);
            }
            var pts = s.clean.items;
            var closed = closed_in;
            if (closed and pts.len > 1 and same(pts[0], pts[pts.len - 1])) pts = pts[0 .. pts.len - 1];
            if (pts.len == 0) return;
            const hw = s.style.width / 2;
            if (pts.len == 1) {
                // A dot: what its caps draw.
                switch (s.style.cap) {
                    .butt => {},
                    .round => try s.disk(pts[0], hw),
                    .square => try s.emit(&.{ .{ pts[0][0] - hw, pts[0][1] - hw }, .{ pts[0][0] + hw, pts[0][1] - hw }, .{ pts[0][0] + hw, pts[0][1] + hw }, .{ pts[0][0] - hw, pts[0][1] + hw } }),
                }
                return;
            }
            if (pts.len == 2) closed = false;
            const n = pts.len;
            const segs = if (closed) n else n - 1;
            try s.dirs.resize(s.gpa, segs);
            const dirs = s.dirs.items;
            for (dirs, 0..) |*d, i| {
                const a = pts[i];
                const b = pts[(i + 1) % n];
                d.* = unit(a, b);
                // The rectangle along it, wound positively: a - n, b - n,
                // b + n, a + n with the normal (-dy, dx).
                const nv: Point = .{ -d[1] * hw, d[0] * hw };
                try s.sink.polygon(&.{ sub(a, nv), sub(b, nv), add(b, nv), add(a, nv) });
            }
            // Joins: at every inner point, and at all of them when closed.
            const first: usize = if (closed) 0 else 1;
            const last: usize = if (closed) n else n - 1;
            for (first..last) |i| try s.joinDirs(dirs[(i + segs - 1) % segs], pts[i], dirs[i % segs], hw);
            if (!closed) {
                try s.cap(pts[1], pts[0], hw);
                try s.cap(pts[n - 2], pts[n - 1], hw);
            }
        }

        /// The cap at `end`, the end of the segment from `from`.
        fn cap(s: *Self, from: Point, end: Point, hw: f32) !void {
            switch (s.style.cap) {
                .butt => {},
                .round => try s.disk(end, hw),
                .square => {
                    const d = unit(from, end);
                    const nv = normal(from, end, hw);
                    const out: Point = .{ end[0] + d[0] * hw, end[1] + d[1] * hw };
                    try s.emit(&.{ add(end, nv), add(out, nv), sub(out, nv), sub(end, nv) });
                },
            }
        }

        /// The join at `v` from direction `d1` into `d2`.
        fn joinDirs(s: *Self, d1: Point, v: Point, d2: Point, hw: f32) !void {
            const cross = d1[0] * d2[1] - d1[1] * d2[0];
            const dot = d1[0] * d2[0] + d1[1] * d2[1];
            if (@abs(cross) < 1e-6 and dot > 0) return;
            // The outer side: away from where the line turns.
            const side: f32 = if (cross > 0) -1 else 1;
            const n1: Point = .{ -d1[1] * side, d1[0] * side };
            const n2: Point = .{ -d2[1] * side, d2[0] * side };
            const p1: Point = .{ v[0] + n1[0] * hw, v[1] + n1[1] * hw };
            const p2: Point = .{ v[0] + n2[0] * hw, v[1] + n2[1] * hw };
            switch (s.style.join) {
                .bevel => try s.emit(&.{ v, p1, p2 }),
                .miter => {
                    const k = 1 + n1[0] * n2[0] + n1[1] * n2[1];
                    // 1/cos of half the angle between the normals: the
                    // miter's length in widths.
                    if (k > 1e-6 and @sqrt(2 / k) <= s.style.miter_limit) {
                        const m: Point = .{ v[0] + (n1[0] + n2[0]) / k * hw, v[1] + (n1[1] + n2[1]) / k * hw };
                        try s.emit(&.{ v, p1, m, p2 });
                    } else try s.emit(&.{ v, p1, p2 });
                },
                .round => {
                    var da = std.math.atan2(n2[1], n2[0]) - std.math.atan2(n1[1], n1[0]);
                    if (da > std.math.pi) da -= 2 * std.math.pi;
                    if (da < -std.math.pi) da += 2 * std.math.pi;
                    // The wedge: the corner, then its arc, turned step by
                    // step from n1 to n2.
                    var pts: [max_arc + 2]Point = undefined;
                    pts[0] = v;
                    const steps = s.arcSteps(hw, @abs(da));
                    const step = da / @as(f32, @floatFromInt(steps));
                    const cs = @cos(step);
                    const sn = @sin(step);
                    var r: Point = .{ n1[0] * hw, n1[1] * hw };
                    for (0..steps + 1) |k| {
                        pts[k + 1] = if (k == steps) p2 else .{ v[0] + r[0], v[1] + r[1] };
                        r = .{ r[0] * cs - r[1] * sn, r[0] * sn + r[1] * cs };
                    }
                    orient(pts[0 .. steps + 2]);
                    try s.sink.polygon(pts[0 .. steps + 2]);
                },
            }
        }

        fn arcSteps(s: *const Self, r: f32, angle: f32) usize {
            const step = 2 * std.math.acos(@max(0, 1 - @min(s.tol, r) / r));
            const n = @ceil(angle / @max(step, 0.01));
            return @intFromFloat(std.math.clamp(n, 1, max_arc));
        }

        fn disk(s: *Self, c: Point, r: f32) !void {
            s.buf.clearRetainingCapacity();
            const steps = @max(8, s.arcSteps(r, 2 * std.math.pi));
            for (0..steps) |k| {
                const t = 2 * std.math.pi * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(steps));
                try s.buf.append(s.gpa, .{ c[0] + @cos(t) * r, c[1] + @sin(t) * r });
            }
            try s.emitOwned();
        }

        fn emitOwned(s: *Self) !void {
            orient(s.buf.items);
            try s.sink.polygon(s.buf.items);
        }

        fn emit(s: *Self, pts: []const Point) !void {
            var tmp: [4]Point = undefined;
            @memcpy(tmp[0..pts.len], pts);
            orient(tmp[0..pts.len]);
            try s.sink.polygon(tmp[0..pts.len]);
        }

        /// The pieces of a polyline the dash pattern keeps, stroked as open lines.
        fn dashes(s: *Self, pts_in: []const Point, closed: bool) !void {
            const pattern = s.style.dash;
            const reps: usize = if (pattern.len % 2 == 1) 2 else 1;
            var period: f32 = 0;
            for (pattern) |v| period += v;
            period *= @floatFromInt(reps);
            const count = pattern.len * reps;
            // Where the pattern starts: the offset into it.
            var idx: usize = 0;
            var left = pattern[0];
            var phase = @mod(s.style.dash_offset, period);
            while (phase > 0) {
                if (phase < left) {
                    left -= phase;
                    break;
                }
                phase -= left;
                idx = (idx + 1) % count;
                left = pattern[idx % pattern.len];
            }
            var piece: std.ArrayList(Point) = .empty;
            defer piece.deinit(s.gpa);
            const n = pts_in.len;
            const segs = if (closed) n else n -| 1;
            if (n > 0 and idx % 2 == 0) try piece.append(s.gpa, pts_in[0]);
            for (0..segs) |i| {
                var a = pts_in[i];
                const b = pts_in[(i + 1) % n];
                var len = std.math.hypot(b[0] - a[0], b[1] - a[1]);
                while (len > 0) {
                    const on = idx % 2 == 0;
                    if (left >= len) {
                        left -= len;
                        if (on) try piece.append(s.gpa, b);
                        break;
                    }
                    const t = left / len;
                    const m: Point = .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t };
                    if (on) {
                        try piece.append(s.gpa, m);
                        try s.polyline(piece.items, false);
                        piece.clearRetainingCapacity();
                    } else try piece.append(s.gpa, m);
                    len -= left;
                    a = m;
                    idx = (idx + 1) % count;
                    left = pattern[idx % pattern.len];
                }
            }
            if (idx % 2 == 0 and piece.items.len > 1) try s.polyline(piece.items, false);
        }
    };
}

fn dashed(pattern: []const f32) bool {
    if (pattern.len == 0) return false;
    var sum: f32 = 0;
    for (pattern) |v| {
        if (v < 0 or !std.math.isFinite(v)) return false;
        sum += v;
    }
    return sum > 0;
}

fn same(a: Point, b: Point) bool {
    return @abs(a[0] - b[0]) < 1e-5 and @abs(a[1] - b[1]) < 1e-5;
}

fn add(a: Point, b: Point) Point {
    return .{ a[0] + b[0], a[1] + b[1] };
}

fn sub(a: Point, b: Point) Point {
    return .{ a[0] - b[0], a[1] - b[1] };
}

fn unit(a: Point, b: Point) Point {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const l = std.math.hypot(dx, dy);
    if (l == 0) return .{ 1, 0 };
    return .{ dx / l, dy / l };
}

/// The normal of a→b, `hw` long.
fn normal(a: Point, b: Point, hw: f32) Point {
    const d = unit(a, b);
    return .{ -d[1] * hw, d[0] * hw };
}

/// Winds a polygon positively (its signed area above 0).
fn orient(pts: []Point) void {
    var area: f32 = 0;
    for (pts, 0..) |p, i| {
        const q = pts[(i + 1) % pts.len];
        area += p[0] * q[1] - q[0] * p[1];
    }
    if (area < 0) std.mem.reverse(Point, pts);
}

const raster = @import("path_raster.zig");

const TestSink = struct {
    cv: *raster.Coverage,
    pub fn polygon(t: TestSink, pts: []const Point) !void {
        t.cv.polygon(pts);
    }
};

fn strokeTest(gpa: std.mem.Allocator, w: usize, h: usize, p: *const path.Path, style: Stroke) ![]u8 {
    var cv = try raster.Coverage.init(gpa, w, h);
    defer cv.deinit(gpa);
    var pl: path.Polylines = .{};
    defer pl.deinit(gpa);
    try path.flatten(gpa, p.data(), .identity, 0.05, &pl);
    var st: Stroker(TestSink) = .{ .gpa = gpa, .sink = .{ .cv = &cv }, .style = style, .tol = 0.05 };
    defer st.deinit();
    try st.polylines(&pl);
    const out = try gpa.alloc(u8, w * h);
    @memset(out, 0);
    const scratch = try gpa.alloc(f32, w);
    defer gpa.free(scratch);
    cv.sweep(.nonzero, scratch, raster.MaskSink{ .out = out, .w = w });
    return out;
}

fn covered(px: []const u8) f32 {
    var s: f32 = 0;
    for (px) |v| s += @as(f32, @floatFromInt(v)) / 255;
    return s;
}

test "a stroke's area: its length by its width, plus its caps" {
    const gpa = std.testing.allocator;
    var p: path.Path = .init(gpa);
    defer p.deinit();
    p.moveTo(10, 20);
    p.lineTo(50, 20);
    const butt = try strokeTest(gpa, 64, 40, &p, .{ .width = 4 });
    defer gpa.free(butt);
    try std.testing.expectApproxEqAbs(@as(f32, 160), covered(butt), 0.1);
    try std.testing.expectEqual(@as(u8, 255), butt[19 * 64 + 30]);
    try std.testing.expectEqual(@as(u8, 0), butt[23 * 64 + 30]);
    const square = try strokeTest(gpa, 64, 40, &p, .{ .width = 4, .cap = .square });
    defer gpa.free(square);
    try std.testing.expectApproxEqAbs(@as(f32, 176), covered(square), 0.1);
    const round = try strokeTest(gpa, 64, 40, &p, .{ .width = 4, .cap = .round });
    defer gpa.free(round);
    try std.testing.expectApproxEqAbs(@as(f32, 160 + 4 * std.math.pi), covered(round), 0.5);
}

test "joins: a square's outline is whole at its corners with miters, cut with bevels" {
    const gpa = std.testing.allocator;
    var p: path.Path = .init(gpa);
    defer p.deinit();
    p.rect(10, 10, 20, 20);
    const miter = try strokeTest(gpa, 40, 40, &p, .{ .width = 4 });
    defer gpa.free(miter);
    // Outer square 24² minus inner 16².
    try std.testing.expectApproxEqAbs(@as(f32, 576 - 256), covered(miter), 0.2);
    try std.testing.expectEqual(@as(u8, 255), miter[8 * 40 + 8]);
    const bevel = try strokeTest(gpa, 40, 40, &p, .{ .width = 4, .join = .bevel });
    defer gpa.free(bevel);
    try std.testing.expectApproxEqAbs(@as(f32, 576 - 256 - 4 * 2), covered(bevel), 0.2);
    try std.testing.expectEqual(@as(u8, 0), bevel[8 * 40 + 8]);
}

test "dashes: on and off along the line" {
    const gpa = std.testing.allocator;
    var p: path.Path = .init(gpa);
    defer p.deinit();
    p.moveTo(0, 5);
    p.lineTo(40, 5);
    const out = try strokeTest(gpa, 40, 10, &p, .{ .width = 2, .dash = &.{ 5, 5 } });
    defer gpa.free(out);
    try std.testing.expectApproxEqAbs(@as(f32, 40), covered(out), 0.1);
    try std.testing.expectEqual(@as(u8, 255), out[4 * 40 + 2]);
    try std.testing.expectEqual(@as(u8, 0), out[4 * 40 + 7]);
    try std.testing.expectEqual(@as(u8, 255), out[4 * 40 + 12]);
    const shifted = try strokeTest(gpa, 40, 10, &p, .{ .width = 2, .dash = &.{ 5, 5 }, .dash_offset = 5 });
    defer gpa.free(shifted);
    try std.testing.expectEqual(@as(u8, 0), shifted[4 * 40 + 2]);
    try std.testing.expectEqual(@as(u8, 255), shifted[4 * 40 + 7]);
}

test "dense polylines: every join and cap of thousands of points, in their union" {
    const gpa = std.testing.allocator;
    var p: path.Path = .init(gpa);
    defer p.deinit();
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    var y: f32 = 30;
    for (0..2000) |i| {
        y = std.math.clamp(y + (r.float(f32) - 0.5) * 12, 4, 56);
        const x = 2 + 196 * @as(f32, @floatFromInt(i)) / 1999;
        if (i == 0) p.moveTo(x, y) else p.lineTo(x, y);
    }
    for ([_]Join{ .miter, .round, .bevel }) |j| {
        const out = try strokeTest(gpa, 200, 60, &p, .{ .width = 1.5, .join = j, .cap = .round });
        defer gpa.free(out);
        // Wholly inside where the line is flat at its start, nothing far from it.
        try std.testing.expect(covered(out) > 300);
        try std.testing.expectEqual(@as(u8, 0), out[0]);
        for (out) |v| try std.testing.expect(v <= 255);
    }
}
