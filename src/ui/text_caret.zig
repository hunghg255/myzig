//! Carets, hit testing and selections over a laid out line, in either
//! direction: a caret before byte `at` sits at the leading edge of the
//! cluster that starts there (its left edge reading left to right, its
//! right edge reading right to left) or, at the end of the text, at the
//! trailing edge of the logically last cluster. Inside a cluster of several
//! characters (a ligature) the caret is placed in proportion. A selection
//! of bytes `a`..`b` shows as the extents of its clusters, which in mixed
//! text are several ranges of x.
//!
//! A line whose clusters all read left to right in logical order has no
//! cluster list (`Layout.clusters` is empty): there carets follow the
//! glyphs, as they always did. The functions take any layout with glyphs
//! (CoreText's too, which has no clusters).
const std = @import("std");
const runs = @import("text_runs.zig");
const utf8 = @import("utf8.zig");

const Layout = runs.Layout;
const Cluster = runs.Cluster;

fn clustersOf(lay: anytype) []const Cluster {
    return if (@hasField(@TypeOf(lay), "clusters")) lay.clusters else &.{};
}

/// The x of the first glyph at or after byte `at`, else the line's end.
pub fn glyphX(lay: anytype, at: usize) f32 {
    for (lay.glyphs) |g| if (g.index >= at) return g.x;
    return lay.width;
}

fn chars(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) i += utf8.seqLen(s[i]);
    return n;
}

/// The byte `k` characters after `from`.
fn charsAfter(s: []const u8, from: usize, k: usize) usize {
    var i = from;
    var left = k;
    while (left > 0 and i < s.len) : (left -= 1) i += utf8.seqLen(s[i]);
    return @min(i, s.len);
}

/// Where byte `at` falls in cluster `c`, as an x.
fn inside(c: Cluster, s: []const u8, at: usize) f32 {
    const total = chars(s[c.start..@min(c.end, s.len)]);
    const before = chars(s[c.start..@min(at, s.len)]);
    const f: f32 = if (total == 0) 0 else @as(f32, @floatFromInt(before)) / @as(f32, @floatFromInt(total));
    const w = c.x1 - c.x0;
    return if (c.rtl) c.x1 - f * w else c.x0 + f * w;
}

/// The x of the caret before byte `at` of `s`, laid out as `lay`.
pub fn caretX(lay: anytype, s: []const u8, at: usize) f32 {
    const clusters = clustersOf(lay);
    if (clusters.len == 0) return if (at == 0) 0 else glyphX(lay, at);
    var next: ?Cluster = null;
    var last: Cluster = clusters[0];
    for (clusters) |c| {
        if (at >= c.start and at < c.end) return inside(c, s, at);
        if (c.start >= at and (next == null or c.start < next.?.start)) next = c;
        if (c.end > last.end) last = c;
    }
    if (next) |c| return if (c.rtl) c.x1 else c.x0;
    return if (last.rtl) last.x0 else last.x1;
}

/// The byte of `s` whose caret is nearest `x`.
pub fn indexAt(lay: anytype, s: []const u8, x: f32) usize {
    const clusters = clustersOf(lay);
    if (clusters.len == 0) {
        var best: usize = s.len;
        var best_d = @abs(lay.width - x);
        for (lay.glyphs) |g| {
            const d = @abs(g.x - x);
            if (d < best_d) {
                best_d = d;
                best = g.index;
            }
        }
        return best;
    }
    const first = clusters[0];
    const end = clusters[clusters.len - 1];
    if (x < first.x0) return if (first.rtl) first.end else first.start;
    if (x >= end.x1) return if (end.rtl) end.start else end.end;
    for (clusters) |c| {
        if (x < c.x0 or x >= c.x1) continue;
        const total = chars(s[c.start..@min(c.end, s.len)]);
        const f = (x - c.x0) / @max(c.x1 - c.x0, 1e-3);
        const t: f32 = if (c.rtl) 1 - f else f;
        const k: usize = @intFromFloat(@round(t * @as(f32, @floatFromInt(total))));
        return charsAfter(s, c.start, k);
    }
    return s.len;
}

/// The ranges of x (left to right, merged where they touch) that bytes
/// `a`..`b` of `s` cover, written to `out`; returns how many.
pub fn selection(lay: anytype, s: []const u8, a: usize, b: usize, out: [][2]f32) usize {
    if (a >= b or out.len == 0) return 0;
    const clusters = clustersOf(lay);
    if (clusters.len == 0) {
        const x0 = caretX(lay, s, a);
        const x1 = caretX(lay, s, b);
        out[0] = .{ @min(x0, x1), @max(x0, x1) };
        return 1;
    }
    var n: usize = 0;
    for (clusters) |c| {
        const lo = @max(a, c.start);
        const hi = @min(b, c.end);
        if (lo >= hi) continue;
        const p = inside(c, s, lo);
        const q = if (hi >= c.end) (if (c.rtl) c.x0 else c.x1) else inside(c, s, hi);
        const r: [2]f32 = .{ @min(p, q), @max(p, q) };
        if (n > 0 and @abs(out[n - 1][1] - r[0]) < 0.01) {
            out[n - 1][1] = r[1];
        } else if (n < out.len) {
            out[n] = r;
            n += 1;
        } else out[n - 1][1] = r[1];
    }
    return n;
}

/// The width of `s`'s characters before each byte, in logical order, as
/// line breaking measures text: `out` has `s.len + 1` entries.
pub fn logicalX(lay: anytype, s: []const u8, out: []f32) void {
    std.debug.assert(out.len == s.len + 1);
    const clusters = clustersOf(lay);
    if (clusters.len == 0) {
        // Glyphs in logical order: the x of the next glyph at each byte.
        var gi: usize = 0;
        for (0..s.len + 1) |i| {
            while (gi < lay.glyphs.len and lay.glyphs[gi].index < i) gi += 1;
            out[i] = if (gi < lay.glyphs.len) lay.glyphs[gi].x else lay.width;
        }
        return;
    }
    // Each cluster's width added at its bytes, then summed.
    @memset(out, 0);
    for (clusters) |c| {
        const end = @min(c.end, s.len);
        if (c.start >= end) continue;
        const total = chars(s[c.start..end]);
        const step = (c.x1 - c.x0) / @as(f32, @floatFromInt(@max(total, 1)));
        var i: usize = c.start;
        while (i < end) {
            const n = utf8.seqLen(s[i]);
            out[@min(i + n, s.len)] += step;
            i += n;
        }
    }
    var sum: f32 = 0;
    for (out, 0..) |*v, i| {
        sum += v.*;
        v.* = sum;
        // Bytes inside a character measure as its start.
        if (i > 0 and i < s.len and (s[i] & 0xc0) == 0x80) v.* = out[i - 1];
    }
}

test "carets, hits and selections in mixed text" {
    // "ab" then two Hebrew letters (bytes 2..4, 4..6) shown right to left.
    const s = "ab\xd7\x90\xd7\x91";
    const clusters = [_]Cluster{
        .{ .start = 0, .end = 1, .x0 = 0, .x1 = 5, .rtl = false },
        .{ .start = 1, .end = 2, .x0 = 5, .x1 = 11, .rtl = false },
        .{ .start = 4, .end = 6, .x0 = 11, .x1 = 18, .rtl = true },
        .{ .start = 2, .end = 4, .x0 = 18, .x1 = 26, .rtl = true },
    };
    const lay: Layout = .{ .width = 26, .glyphs = &.{}, .clusters = &clusters };
    const t = std.testing;
    try t.expectEqual(@as(f32, 0), caretX(lay, s, 0));
    try t.expectEqual(@as(f32, 26), caretX(lay, s, 2)); // before alef: its right edge
    try t.expectEqual(@as(f32, 18), caretX(lay, s, 4)); // before bet
    try t.expectEqual(@as(f32, 11), caretX(lay, s, 6)); // the end: bet's left edge
    try t.expectEqual(@as(usize, 2), indexAt(lay, s, 25));
    try t.expectEqual(@as(usize, 6), indexAt(lay, s, 12));
    try t.expectEqual(@as(usize, 0), indexAt(lay, s, -3));
    // Selecting "b" and alef: two ranges, apart.
    var out: [4][2]f32 = undefined;
    const n = selection(lay, s, 1, 4, &out);
    try t.expectEqual(@as(usize, 2), n);
    try t.expectEqual([2]f32{ 5, 11 }, out[0]);
    try t.expectEqual([2]f32{ 18, 26 }, out[1]);
    var xs: [s.len + 1]f32 = undefined;
    logicalX(lay, s, &xs);
    try t.expectEqual(@as(f32, 11), xs[2]);
    try t.expectEqual(@as(f32, 19), xs[4]);
    try t.expectEqual(@as(f32, 26), xs[6]);
}
