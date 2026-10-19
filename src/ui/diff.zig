//! Comparing texts, as mygo's `internal/diff` does: the lines of two texts
//! by Myers's O(ND) algorithm in linear space, with xdiff's cost limit,
//! which bounds the time on large unrelated texts at the price of a
//! minimal diff; and the words of two lines, for what changed within them.
const std = @import("std");

/// Elements a0 to a1 of the old sequence replaced by b0 to b1 of the new.
/// a0 == a1 is an insertion before a0; b0 == b1 a deletion.
pub const Hunk = struct { a0: usize, a1: usize, b0: usize, b1: usize };

/// A range of bytes.
pub const Range = struct { start: usize, end: usize };

const max_cost_min = 256;
const line_max: i64 = std.math.maxInt(i64) >> 2;

const Differ = struct {
    a: []const u32,
    b: []const u32,
    da: []bool,
    db: []bool,
    v: []i64,
    extra: i64,

    fn mark(d: *Differ, a0: usize, a1: usize, b0: usize, b1: usize) void {
        @memset(d.da[a0..a1], true);
        @memset(d.db[b0..b1], true);
    }

    fn compare(d: *Differ, off1_in: usize, lim1_in: usize, off2_in: usize, lim2_in: usize, need_min: bool) void {
        var off1 = off1_in;
        var lim1 = lim1_in;
        var off2 = off2_in;
        var lim2 = lim2_in;
        while (off1 < lim1 and off2 < lim2 and d.a[off1] == d.b[off2]) {
            off1 += 1;
            off2 += 1;
        }
        while (off1 < lim1 and off2 < lim2 and d.a[lim1 - 1] == d.b[lim2 - 1]) {
            lim1 -= 1;
            lim2 -= 1;
        }
        if (off1 == lim1 or off2 == lim2) return d.mark(off1, lim1, off2, lim2);
        const s = d.split(@intCast(off1), @intCast(lim1), @intCast(off2), @intCast(lim2), need_min);
        d.compare(off1, s.x1, off2, s.x2, s.min_lo);
        d.compare(s.x1, lim1, s.x2, lim2, s.min_hi);
    }

    const Split = struct { x1: usize, x2: usize, min_lo: bool, min_hi: bool };

    /// Where to split a[off1..lim1] and b[off2..lim2]: the middle snake, or
    /// past the cost limit the furthest the diagonals got.
    fn split(d: *Differ, off1: i64, lim1: i64, off2: i64, lim2: i64, need_min: bool) Split {
        const nd: usize = d.a.len + d.b.len + 3;
        const base: i64 = @intCast(d.b.len + 1);
        const vf = d.v[0..nd];
        const vb = d.v[nd .. 2 * nd];
        const at = struct {
            fn f(bs: i64, k: i64) usize {
                return @intCast(bs + k);
            }
        }.f;
        const dmin = off1 - lim2;
        const dmax = lim1 - off2;
        const fmid = off1 - off2;
        const bmid = lim1 - lim2;
        const odd = @mod(fmid - bmid, 2) != 0;
        var fmin = fmid;
        var fmax = fmid;
        var bmin = bmid;
        var bmax = bmid;
        vf[at(base, fmid)] = off1;
        vb[at(base, bmid)] = lim1;
        var ec: i64 = 1;
        while (true) : (ec += 1) {
            if (fmin > dmin) {
                fmin -= 1;
                vf[at(base, fmin - 1)] = -1;
            } else fmin += 1;
            if (fmax < dmax) {
                fmax += 1;
                vf[at(base, fmax + 1)] = -1;
            } else fmax -= 1;
            var k = fmax;
            while (k >= fmin) : (k -= 2) {
                var x1 = if (vf[at(base, k - 1)] >= vf[at(base, k + 1)]) vf[at(base, k - 1)] + 1 else vf[at(base, k + 1)];
                var x2 = x1 - k;
                while (x1 < lim1 and x2 < lim2 and d.a[@intCast(x1)] == d.b[@intCast(x2)]) {
                    x1 += 1;
                    x2 += 1;
                }
                vf[at(base, k)] = x1;
                if (odd and bmin <= k and k <= bmax and vb[at(base, k)] <= x1)
                    return .{ .x1 = @intCast(x1), .x2 = @intCast(x2), .min_lo = true, .min_hi = true };
            }
            if (bmin > dmin) {
                bmin -= 1;
                vb[at(base, bmin - 1)] = line_max;
            } else bmin += 1;
            if (bmax < dmax) {
                bmax += 1;
                vb[at(base, bmax + 1)] = line_max;
            } else bmax -= 1;
            k = bmax;
            while (k >= bmin) : (k -= 2) {
                var x1 = if (vb[at(base, k - 1)] < vb[at(base, k + 1)]) vb[at(base, k - 1)] else vb[at(base, k + 1)] - 1;
                var x2 = x1 - k;
                while (x1 > off1 and x2 > off2 and d.a[@intCast(x1 - 1)] == d.b[@intCast(x2 - 1)]) {
                    x1 -= 1;
                    x2 -= 1;
                }
                vb[at(base, k)] = x1;
                if (!odd and fmin <= k and k <= fmax and x1 <= vf[at(base, k)])
                    return .{ .x1 = @intCast(x1), .x2 = @intCast(x2), .min_lo = true, .min_hi = true };
            }
            if (need_min or ec < d.extra) continue;
            // Too costly: split where the furthest diagonals got.
            var fbest: i64 = -1;
            var fbest1: i64 = -1;
            k = fmax;
            while (k >= fmin) : (k -= 2) {
                var x1 = @min(vf[at(base, k)], lim1);
                var x2 = x1 - k;
                if (lim2 < x2) {
                    x1 = lim2 + k;
                    x2 = lim2;
                }
                if (fbest < x1 + x2) {
                    fbest = x1 + x2;
                    fbest1 = x1;
                }
            }
            var bbest: i64 = line_max;
            var bbest1: i64 = line_max;
            k = bmax;
            while (k >= bmin) : (k -= 2) {
                var x1 = @max(off1, vb[at(base, k)]);
                var x2 = x1 - k;
                if (x2 < off2) {
                    x1 = off2 + k;
                    x2 = off2;
                }
                if (x1 + x2 < bbest) {
                    bbest = x1 + x2;
                    bbest1 = x1;
                }
            }
            if ((lim1 + lim2) - bbest < fbest - (off1 + off2))
                return .{ .x1 = @intCast(fbest1), .x2 = @intCast(fbest - fbest1), .min_lo = true, .min_hi = false };
            return .{ .x1 = @intCast(bbest1), .x2 = @intCast(bbest - bbest1), .min_lo = false, .min_hi = true };
        }
    }
};

/// The hunks turning `a` into `b`, sequences of interned elements (equal
/// elements, equal numbers), in order; free with `gpa`.
pub fn ints(gpa: std.mem.Allocator, a: []const u32, b: []const u32) ![]Hunk {
    const da = try gpa.alloc(bool, a.len);
    defer gpa.free(da);
    const db = try gpa.alloc(bool, b.len);
    defer gpa.free(db);
    @memset(da, false);
    @memset(db, false);
    const nd = a.len + b.len + 3;
    const v = try gpa.alloc(i64, 2 * nd);
    defer gpa.free(v);
    var cost: i64 = 1;
    while (cost * cost < @as(i64, @intCast(nd))) cost <<= 1;
    var d: Differ = .{ .a = a, .b = b, .da = da, .db = db, .v = v, .extra = @max(cost, max_cost_min) };
    d.compare(0, a.len, 0, b.len, false);
    var out: std.ArrayList(Hunk) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len or j < b.len) {
        if (i < a.len and j < b.len and !da[i] and !db[j]) {
            i += 1;
            j += 1;
            continue;
        }
        var h: Hunk = .{ .a0 = i, .a1 = i, .b0 = j, .b1 = j };
        while (i < a.len and da[i]) i += 1;
        while (j < b.len and db[j]) j += 1;
        h.a1 = i;
        h.b1 = j;
        if (h.a0 == h.a1 and h.b0 == h.b1) {
            // Unpaired unchanged elements cannot happen; never loop.
            if (i < a.len) i += 1;
            if (j < b.len) j += 1;
            continue;
        }
        try out.append(gpa, h);
    }
    return out.toOwnedSlice(gpa);
}

/// Numbers the distinct strings of `a` and `b`, equal strings alike.
fn intern(gpa: std.mem.Allocator, a: []const []const u8, b: []const []const u8) ![2][]u32 {
    var ids: std.StringHashMapUnmanaged(u32) = .empty;
    defer ids.deinit(gpa);
    var out: [2][]u32 = undefined;
    for ([2][]const []const u8{ a, b }, 0..) |side, k| {
        out[k] = try gpa.alloc(u32, side.len);
        for (side, 0..) |s, i| {
            const gop = try ids.getOrPut(gpa, s);
            if (!gop.found_existing) gop.value_ptr.* = @intCast(ids.count() - 1);
            out[k][i] = gop.value_ptr.*;
        }
    }
    return out;
}

/// The hunks of lines turning `a` into `b`.
pub fn lines(gpa: std.mem.Allocator, a: []const []const u8, b: []const []const u8) ![]Hunk {
    const ia = try intern(gpa, a, b);
    defer gpa.free(ia[0]);
    defer gpa.free(ia[1]);
    return ints(gpa, ia[0], ia[1]);
}

/// The lines of `s` (without newlines): a text ending in a newline has
/// an empty last line.
pub fn splitLines(gpa: std.mem.Allocator, s: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| try out.append(gpa, l);
    return out.toOwnedSlice(gpa);
}

fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

/// Words, runs of spaces, and other characters one at a time.
fn tokens(gpa: std.mem.Allocator, s: []const u8) ![]Range {
    var out: std.ArrayList(Range) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        var j = i + 1;
        if (isWordByte(s[i])) {
            while (j < s.len and isWordByte(s[j])) j += 1;
        } else if (s[i] == ' ' or s[i] == '\t') {
            while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
        }
        try out.append(gpa, .{ .start = i, .end = j });
        i = j;
    }
    return out.toOwnedSlice(gpa);
}

pub const Words = struct {
    a: []Range,
    b: []Range,
    /// How much of the two texts stayed the same, by their bytes, 0 to 1.
    same: f32,

    pub fn deinit(w: Words, gpa: std.mem.Allocator) void {
        gpa.free(w.a);
        gpa.free(w.b);
    }
};

/// What changed between two lines, word by word: the byte ranges of each
/// that changed, joined across the spaces between them.
pub fn words(gpa: std.mem.Allocator, a: []const u8, b: []const u8) !Words {
    const ta = try tokens(gpa, a);
    defer gpa.free(ta);
    const tb = try tokens(gpa, b);
    defer gpa.free(tb);
    const sa = try gpa.alloc([]const u8, ta.len);
    defer gpa.free(sa);
    const sb = try gpa.alloc([]const u8, tb.len);
    defer gpa.free(sb);
    for (ta, 0..) |r, i| sa[i] = a[r.start..r.end];
    for (tb, 0..) |r, i| sb[i] = b[r.start..r.end];
    const hunks = try lines(gpa, sa, sb);
    defer gpa.free(hunks);
    var ra: std.ArrayList(Range) = .empty;
    errdefer ra.deinit(gpa);
    var rb: std.ArrayList(Range) = .empty;
    errdefer rb.deinit(gpa);
    var changed: usize = 0;
    for (hunks) |h| {
        if (h.a0 < h.a1) {
            try join(gpa, &ra, .{ .start = ta[h.a0].start, .end = ta[h.a1 - 1].end }, a);
            changed += ta[h.a1 - 1].end - ta[h.a0].start;
        }
        if (h.b0 < h.b1) {
            try join(gpa, &rb, .{ .start = tb[h.b0].start, .end = tb[h.b1 - 1].end }, b);
            changed += tb[h.b1 - 1].end - tb[h.b0].start;
        }
    }
    const total = a.len + b.len;
    const same: f32 = if (total == 0) 1 else 1 - @as(f32, @floatFromInt(changed)) / @as(f32, @floatFromInt(total));
    return .{ .a = try ra.toOwnedSlice(gpa), .b = try rb.toOwnedSlice(gpa), .same = same };
}

/// Appends `r`, merged with the last range when only spaces are between.
fn join(gpa: std.mem.Allocator, rs: *std.ArrayList(Range), r: Range, s: []const u8) !void {
    if (rs.items.len > 0) {
        const last = &rs.items[rs.items.len - 1];
        const gap = s[last.end..r.start];
        if (std.mem.trim(u8, gap, " \t").len == 0) {
            last.end = r.end;
            return;
        }
    }
    try rs.append(gpa, r);
}
