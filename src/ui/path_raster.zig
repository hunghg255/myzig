//! Polygons to antialiased coverage, for paths (`ui.canvas`), after the
//! accumulation rasterizer of font-rs that glyphs use (`tt/raster.zig`):
//! each line adds its signed area to the cells it crosses, and a running
//! sum along each row turns those into the winding of each pixel, with
//! fractions on the edges. Overlapping contours sum, so both fill rules
//! fall out of the sum (nonzero: its size up to 1; even-odd: its distance
//! to the nearest even number), and so does the union of the pieces a
//! stroke is made of. Rows keep two spare cells, so the sum never runs
//! from one row into the next. Each row marks the blocks of cells lines
//! touched: the sweep runs over those, and across the blocks between
//! them only where the sum covers something (inside a fill), so a thin
//! stroke wandering over a large canvas costs its own cells, not the
//! canvas's.
const std = @import("std");
const path = @import("path.zig");
const Point = path.Point;
const Rule = path.Rule;

/// Cells a block has: what a row marks as touched.
const block_shift = 4;
const block = 1 << block_shift;

pub const Coverage = struct {
    w: usize,
    h: usize,
    stride: usize,
    acc: []f32,
    /// Per row, a bit for each block of cells lines touched.
    touched: []u64,
    words: usize,
    /// What lines touched since the last sweep: rows [y0, y1), cells [x0, x1).
    y0: usize,
    y1: usize = 0,
    x0: usize,
    x1: usize = 0,

    pub fn init(gpa: std.mem.Allocator, w: usize, h: usize) !Coverage {
        const stride = w + 2;
        const acc = try gpa.alloc(f32, stride * h);
        errdefer gpa.free(acc);
        @memset(acc, 0);
        const words = ((stride + block - 1) / block + 63) / 64;
        const touched = try gpa.alloc(u64, words * h);
        @memset(touched, 0);
        return .{ .w = w, .h = h, .stride = stride, .acc = acc, .touched = touched, .words = words, .y0 = h, .x0 = stride };
    }

    pub fn deinit(cv: *Coverage, gpa: std.mem.Allocator) void {
        gpa.free(cv.acc);
        gpa.free(cv.touched);
    }

    /// Marks the blocks of cells [a, b] of row y as touched.
    inline fn mark(cv: *Coverage, y: usize, a: usize, b: usize) void {
        const bits = cv.touched[y * cv.words ..][0..cv.words];
        var k = a >> block_shift;
        const e = b >> block_shift;
        while (k <= e) : (k += 1) bits[k >> 6] |= @as(u64, 1) << @intCast(k & 63);
    }

    pub fn empty(cv: *const Coverage) bool {
        return cv.y1 <= cv.y0;
    }

    /// A polygon's edges (closed back to its first point).
    pub fn polygon(cv: *Coverage, pts: []const Point) void {
        if (pts.len < 2) return;
        for (pts, 0..) |p, i| {
            const q = pts[(i + 1) % pts.len];
            cv.line(p, q);
        }
    }

    /// Adds a line's signed area to the cells it crosses.
    pub fn line(cv: *Coverage, a: Point, b: Point) void {
        if (a[1] == b[1]) return;
        if (!(std.math.isFinite(a[0]) and std.math.isFinite(a[1]) and std.math.isFinite(b[0]) and std.math.isFinite(b[1]))) return;
        const dir: f32 = if (a[1] < b[1]) 1 else -1;
        const p0 = if (a[1] < b[1]) a else b;
        const p1 = if (a[1] < b[1]) b else a;
        const hf: f32 = @floatFromInt(cv.h);
        if (p1[1] <= 0 or p0[1] >= hf) return;
        const wf: f32 = @floatFromInt(cv.w);
        const dxdy = (p1[0] - p0[0]) / (p1[1] - p0[1]);
        var x = p0[0];
        if (p0[1] < 0) x -= p0[1] * dxdy;
        const y_start: usize = @intFromFloat(@max(0, p0[1]));
        const y_end: usize = @intFromFloat(@min(hf, @ceil(p1[1])));
        cv.y0 = @min(cv.y0, y_start);
        cv.y1 = @max(cv.y1, y_end);
        var y = y_start;
        while (y < y_end) : (y += 1) {
            const yf: f32 = @floatFromInt(y);
            const dy = @min(yf + 1, p1[1]) - @max(yf, p0[1]);
            const xnext = x + dxdy * dy;
            const d = dy * dir;
            // Kept inside the row: what lies left of it still covers it,
            // what lies right of it lands in the spare cells.
            const x0 = std.math.clamp(@min(x, xnext), 0, wf);
            const x1 = std.math.clamp(@max(x, xnext), 0, wf);
            const row = cv.acc[y * cv.stride ..][0..cv.stride];
            const x0f = @floor(x0);
            const x1c = @ceil(x1);
            const x0i: usize = @intFromFloat(x0f);
            const x1i: usize = @intFromFloat(x1c);
            cv.x0 = @min(cv.x0, x0i);
            cv.x1 = @max(cv.x1, x1i + 2);
            cv.mark(y, x0i, x1i + 1);
            if (x1i <= x0i + 1) {
                const xm = 0.5 * (x0 + x1) - x0f;
                row[x0i] += d - d * xm;
                row[x0i + 1] += d * xm;
            } else {
                const s = 1 / (x1 - x0);
                const fr0 = x0 - x0f;
                const a0 = 0.5 * s * (1 - fr0) * (1 - fr0);
                const fr1 = x1 - x1c + 1;
                const am = 0.5 * s * fr1 * fr1;
                row[x0i] += d * a0;
                if (x1i == x0i + 2) {
                    row[x0i + 1] += d * (1 - a0 - am);
                } else {
                    const a1 = s * (1.5 - fr0);
                    row[x0i + 1] += d * (a1 - a0);
                    for (x0i + 2..x1i - 1) |xi| row[xi] += d * s;
                    const a2 = a1 + @as(f32, @floatFromInt(x1i - x0i - 3)) * s;
                    row[x1i - 1] += d * (1 - a2 - am);
                }
                row[x1i] += d * am;
            }
            x = xnext;
        }
    }

    /// Hands each touched row's coverage (0 to 1, by `rule`) to
    /// `sink.row(y, x0, alphas)`, in runs of the pixels from x0 on (a row
    /// may come in several), and clears the cells for the next path.
    /// Pixels left out cover less than 1/1024: nothing, in bytes.
    /// `scratch` holds at least `w` values.
    pub fn sweep(cv: *Coverage, rule: Rule, scratch: []f32, sink: anytype) void {
        if (cv.empty()) return;
        const x0 = @min(cv.x0, cv.w);
        const x1 = @min(cv.x1, cv.stride);
        const xe = @min(x1, cv.w);
        const b0 = x0 >> block_shift;
        const b1 = (x1 + block - 1) >> block_shift;
        for (cv.y0..cv.y1) |y| {
            const row = cv.acc[y * cv.stride ..][0..cv.stride];
            const bits = cv.touched[y * cv.words ..][0..cv.words];
            var sum: f32 = 0;
            // The run of pixels being gathered for the sink.
            var run: ?usize = null;
            var b = b0;
            while (b < b1) : (b += 1) {
                const s = @max(b << block_shift, x0);
                const e = @min((b + 1) << block_shift, xe);
                const hit = bits[b >> 6] & (@as(u64, 1) << @intCast(b & 63)) != 0;
                if (!hit) {
                    // Untouched: the sum holds, and so does the coverage.
                    const a = alpha(rule, sum);
                    if (a < 1.0 / 1024.0) {
                        if (run) |r| if (s > r) sink.row(y, r, scratch[r..s]);
                        run = null;
                        continue;
                    }
                    if (s < e) {
                        @memset(scratch[s..e], a);
                        if (run == null) run = s;
                    }
                    continue;
                }
                if (run == null and s < e) run = s;
                for (s..e) |x| {
                    sum += row[x];
                    scratch[x] = alpha(rule, sum);
                }
                const c0 = b << block_shift;
                @memset(row[c0..@min(c0 + block, cv.stride)], 0);
            }
            if (run) |r| if (xe > r) sink.row(y, r, scratch[r..xe]);
            @memset(bits, 0);
        }
        cv.y0 = cv.h;
        cv.y1 = 0;
        cv.x0 = cv.stride;
        cv.x1 = 0;
    }
};

/// How much a pixel whose winding sums to `s` is inside.
pub fn alpha(rule: Rule, s: f32) f32 {
    const a = @abs(s);
    return switch (rule) {
        .nonzero => @min(1, a),
        .evenodd => blk: {
            const m = @mod(a, 2);
            break :blk if (m > 1) 2 - m else m;
        },
    };
}

/// Coverage into a buffer of bytes, for tests and masks.
pub const MaskSink = struct {
    out: []u8,
    w: usize,

    pub fn row(s: MaskSink, y: usize, x0: usize, alphas: []const f32) void {
        for (alphas, 0..) |a, i| s.out[y * s.w + x0 + i] = @intFromFloat(@min(1, a) * 255 + 0.5);
    }
};

fn fillTest(gpa: std.mem.Allocator, w: usize, h: usize, d: path.Data, rule: Rule) ![]u8 {
    var cv = try Coverage.init(gpa, w, h);
    defer cv.deinit(gpa);
    var pl: path.Polylines = .{};
    defer pl.deinit(gpa);
    try path.flatten(gpa, d, .identity, 0.1, &pl);
    for (pl.runs.items) |r| cv.polygon(pl.run(r));
    const out = try gpa.alloc(u8, w * h);
    @memset(out, 0);
    const scratch = try gpa.alloc(f32, w);
    defer gpa.free(scratch);
    cv.sweep(rule, scratch, MaskSink{ .out = out, .w = w });
    return out;
}

fn total(px: []const u8) f32 {
    var s: f32 = 0;
    for (px) |v| s += @as(f32, @floatFromInt(v)) / 255;
    return s;
}

test "a square: full inside, half on a half-pixel edge, nothing outside" {
    const gpa = std.testing.allocator;
    var p: path.Path = .init(gpa);
    defer p.deinit();
    p.rect(2, 2, 4.5, 4);
    const out = try fillTest(gpa, 8, 8, p.data(), .nonzero);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(u8, 255), out[3 * 8 + 3]);
    try std.testing.expectEqual(@as(u8, 0), out[1 * 8 + 3]);
    try std.testing.expectEqual(@as(u8, 128), out[3 * 8 + 6]);
    try std.testing.expectEqual(@as(u8, 0), out[3 * 8 + 7]);
    try std.testing.expectApproxEqAbs(@as(f32, 18), total(out), 0.05);
}

test "the area of a circle, within the flattening tolerance" {
    const gpa = std.testing.allocator;
    var p: path.Path = .init(gpa);
    defer p.deinit();
    p.circle(50.3, 49.7, 40);
    const out = try fillTest(gpa, 100, 100, p.data(), .nonzero);
    defer gpa.free(out);
    const want = std.math.pi * 40 * 40;
    // Chords within 0.1 of the curve lose about 2/3 × 0.1 × its perimeter.
    try std.testing.expectApproxEqRel(@as(f32, want), total(out), 0.003);
    try std.testing.expect(total(out) < want);
}

test "fill rules: a square inside a square, wound the same way" {
    const gpa = std.testing.allocator;
    var p: path.Path = .init(gpa);
    defer p.deinit();
    p.rect(0, 0, 10, 10);
    p.rect(3, 3, 4, 4);
    const nz = try fillTest(gpa, 10, 10, p.data(), .nonzero);
    defer gpa.free(nz);
    const eo = try fillTest(gpa, 10, 10, p.data(), .evenodd);
    defer gpa.free(eo);
    try std.testing.expectEqual(@as(u8, 255), nz[5 * 10 + 5]);
    try std.testing.expectEqual(@as(u8, 0), eo[5 * 10 + 5]);
    try std.testing.expectEqual(@as(u8, 255), eo[1 * 10 + 1]);
    try std.testing.expectApproxEqAbs(@as(f32, 84), total(eo), 0.05);
}

test "shapes partly outside are clipped, rows never leak into the next" {
    const gpa = std.testing.allocator;
    var p: path.Path = .init(gpa);
    defer p.deinit();
    p.rect(-5, -5, 30, 8);
    const out = try fillTest(gpa, 10, 10, p.data(), .nonzero);
    defer gpa.free(out);
    try std.testing.expectApproxEqAbs(@as(f32, 30), total(out), 0.01);
    try std.testing.expectEqual(@as(u8, 255), out[2 * 10 + 9]);
    try std.testing.expectEqual(@as(u8, 0), out[3 * 10 + 0]);
}

/// The sweep over every cell of the touched rows and columns, as it was
/// before rows marked their blocks: what `sweep` must match.
fn sweepDense(cv: *Coverage, rule: Rule, scratch: []f32, sink: anytype) void {
    if (cv.empty()) return;
    const x0 = @min(cv.x0, cv.w);
    const x1 = @min(cv.x1, cv.stride);
    const xe = @min(x1, cv.w);
    for (cv.y0..cv.y1) |y| {
        const row = cv.acc[y * cv.stride ..][0..cv.stride];
        var sum: f32 = 0;
        for (x0..xe) |x| {
            sum += row[x];
            scratch[x] = alpha(rule, sum);
        }
        @memset(row[x0..x1], 0);
        @memset(cv.touched[y * cv.words ..][0..cv.words], 0);
        sink.row(y, x0, scratch[x0..xe]);
    }
    cv.y0 = cv.h;
    cv.y1 = 0;
    cv.x0 = cv.stride;
    cv.x1 = 0;
}

test "the sweep by touched blocks gives every pixel the dense sweep gives" {
    const gpa = std.testing.allocator;
    const w = 300;
    const h = 120;
    var cv = try Coverage.init(gpa, w, h);
    defer cv.deinit(gpa);
    const scratch = try gpa.alloc(f32, w);
    defer gpa.free(scratch);
    const a = try gpa.alloc(u8, w * h);
    defer gpa.free(a);
    const b = try gpa.alloc(u8, w * h);
    defer gpa.free(b);
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const r = prng.random();
    for (0..40) |round| {
        const rule: Rule = if (round % 2 == 0) .nonzero else .evenodd;
        // Random polygons, some large (filled insides), some thin and long.
        var pts: [24]Point = undefined;
        const n = 3 + r.uintLessThan(usize, 20);
        for (pts[0..n]) |*p| p.* = .{ r.float(f32) * 340 - 20, r.float(f32) * 150 - 15 };
        for (0..2) |pass| {
            cv.polygon(pts[0..n]);
            cv.polygon(&.{ .{ 10, 50 }, .{ 290, 52 }, .{ 290, 53.5 }, .{ 10, 51.5 } });
            const out = if (pass == 0) a else b;
            @memset(out, 0);
            if (pass == 0) cv.sweep(rule, scratch, MaskSink{ .out = out, .w = w }) else sweepDense(&cv, rule, scratch, MaskSink{ .out = out, .w = w });
        }
        try std.testing.expectEqualSlices(u8, b, a);
    }
}
