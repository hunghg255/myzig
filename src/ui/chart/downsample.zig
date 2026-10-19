//! Fewer points for long series: a streaming chart of thousands of
//! samples keeps, for each of a few buckets (about one a pixel across its
//! plot), the bucket's lowest and highest point, in the order they came.
//! A line through them covers what the full line covers: every peak and
//! every dip shows, at a fraction of the points to stroke.
const std = @import("std");

/// The lowest and highest point of each of `buckets` runs of `points`
/// (x, y; NaN y: none there) of about equal length, in order, into `out`
/// (room for 2 × `buckets`); returns the points written. A bucket of
/// only NaNs keeps one, so the line still breaks there. Series no longer
/// than `out` are copied whole.
pub fn downsampleMinMax(points: []const [2]f64, buckets: usize, out: [][2]f64) [][2]f64 {
    const room = @min(out.len, 2 * buckets);
    if (points.len <= room) {
        @memcpy(out[0..points.len], points);
        return out[0..points.len];
    }
    const n = room / 2;
    if (n == 0) return out[0..0];
    var k: usize = 0;
    for (0..n) |b| {
        const s = b * points.len / n;
        const e = (b + 1) * points.len / n;
        var lo: ?usize = null;
        var hi: ?usize = null;
        for (s..e) |i| {
            const v = points[i][1];
            if (std.math.isNan(v)) continue;
            if (lo == null or v < points[lo.?][1]) lo = i;
            if (hi == null or v > points[hi.?][1]) hi = i;
        }
        const a = lo orelse {
            out[k] = points[s];
            k += 1;
            continue;
        };
        const z = hi.?;
        out[k] = points[@min(a, z)];
        k += 1;
        if (a != z) {
            out[k] = points[@max(a, z)];
            k += 1;
        }
    }
    return out[0..k];
}

/// `downsampleMinMax` over values at x = 0, 1, 2, …
pub fn downsampleValues(values: []const f64, buckets: usize, out: [][2]f64) [][2]f64 {
    const room = @min(out.len, 2 * buckets);
    const n = room / 2;
    if (values.len <= room) {
        for (values, 0..) |v, i| out[i] = .{ @floatFromInt(i), v };
        return out[0..values.len];
    }
    if (n == 0) return out[0..0];
    var k: usize = 0;
    for (0..n) |b| {
        const s = b * values.len / n;
        const e = (b + 1) * values.len / n;
        var lo: ?usize = null;
        var hi: ?usize = null;
        for (s..e) |i| {
            if (std.math.isNan(values[i])) continue;
            if (lo == null or values[i] < values[lo.?]) lo = i;
            if (hi == null or values[i] > values[hi.?]) hi = i;
        }
        const a = lo orelse {
            out[k] = .{ @floatFromInt(s), std.math.nan(f64) };
            k += 1;
            continue;
        };
        const z = hi.?;
        out[k] = .{ @floatFromInt(@min(a, z)), values[@min(a, z)] };
        k += 1;
        if (a != z) {
            out[k] = .{ @floatFromInt(@max(a, z)), values[@max(a, z)] };
            k += 1;
        }
    }
    return out[0..k];
}

const testing = std.testing;

test "each bucket keeps its lowest and highest point, in order" {
    var pts: [1000][2]f64 = undefined;
    for (&pts, 0..) |*p, i| p.* = .{ @floatFromInt(i), @sin(@as(f64, @floatFromInt(i)) / 7) };
    // A spike and a dip that must survive.
    pts[333][1] = 5;
    pts[777][1] = -5;
    var out: [100][2]f64 = undefined;
    const got = downsampleMinMax(&pts, 50, &out);
    try testing.expect(got.len <= 100 and got.len >= 50);
    var top: f64 = -10;
    var bottom: f64 = 10;
    for (got, 0..) |p, i| {
        top = @max(top, p[1]);
        bottom = @min(bottom, p[1]);
        if (i > 0) try testing.expect(p[0] > got[i - 1][0]);
    }
    try testing.expectEqual(@as(f64, 5), top);
    try testing.expectEqual(@as(f64, -5), bottom);
    // Short series pass through.
    const few = downsampleMinMax(pts[0..30], 50, &out);
    try testing.expectEqual(@as(usize, 30), few.len);
    try testing.expectEqual(pts[29], few[29]);
}

test "values: x is the index; a run of NaNs keeps a gap" {
    var vals: [400]f64 = undefined;
    for (&vals, 0..) |*v, i| v.* = @floatFromInt(i % 10);
    for (100..200) |i| vals[i] = std.math.nan(f64);
    var out: [40][2]f64 = undefined;
    const got = downsampleValues(&vals, 20, &out);
    var gaps: usize = 0;
    for (got) |p| {
        if (std.math.isNan(p[1])) gaps += 1 else try testing.expect(p[1] == 0 or p[1] == 9);
    }
    try testing.expectEqual(@as(usize, 5), gaps);
    try testing.expectEqual(@as(f64, 0), got[0][1]);
}
