//! What a line of shaped text is where myzig shapes it (Linux, Windows):
//! glyphs in visual order, left to right, each with the byte its cluster
//! starts at; and, for a line with text read right to left, its clusters
//! in visual order, with their bytes, their extent and their direction,
//! which carets, hit testing and selections read (`text_caret.zig`).
//!
//! Shapers (DirectWrite, HarfBuzz, myzig's own) give runs of one font and
//! direction, already in visual order with their glyphs left to right;
//! `build` places them on the line.
const std = @import("std");

/// A shaped glyph, as `text_mac.zig` has it.
pub const Glyph = struct { font: u16, glyph: u16, x: f32, y: f32, index: u32 = 0 };

/// A cluster of a line: bytes `start`..`end` drawn from `x0` to `x1`.
pub const Cluster = struct {
    start: u32,
    end: u32,
    x0: f32,
    x1: f32,
    rtl: bool,
};

pub const Layout = struct {
    width: f32,
    glyphs: []const Glyph,
    /// Empty when every cluster reads left to right in logical order:
    /// carets then follow the glyphs.
    clusters: []const Cluster = &.{},
    /// The paragraph reads right to left.
    rtl: bool = false,

    pub fn free(l: Layout, gpa: std.mem.Allocator) void {
        gpa.free(l.glyphs);
        if (l.clusters.len > 0) gpa.free(l.clusters);
    }
};

pub const Line = struct { start: usize, end: usize, width: f32 };

/// A glyph as a shaper gives it: its id, advance and offset (y up), and
/// the byte its cluster starts at.
pub const Shaped = struct {
    id: u16,
    advance: f32,
    dx: f32 = 0,
    dy: f32 = 0,
    cluster: u32,
};

/// Bytes `start`..`end` shaped in one run font and direction, glyphs left to
/// right (a right-to-left run's last character first).
pub const Run = struct {
    font: u16,
    level: u8 = 0,
    start: u32,
    end: u32,
    glyphs: []const Shaped,

    pub fn rtl(r: Run) bool {
        return r.level & 1 != 0;
    }

    pub fn width(r: Run) f32 {
        var w: f32 = 0;
        for (r.glyphs) |g| w += g.advance;
        return w;
    }
};

/// Places `runs` (visual order) side by side from x 0; the glyphs' bytes
/// are relative to `base`. Clusters are kept only where a run reads right
/// to left, or `clusters` is asked.
pub fn build(gpa: std.mem.Allocator, runs: []const Run, base: u32, para_rtl: bool, clusters: bool) !Layout {
    var n: usize = 0;
    var any_rtl = para_rtl;
    for (runs) |r| {
        n += r.glyphs.len;
        any_rtl = any_rtl or r.rtl();
    }
    const glyphs = try gpa.alloc(Glyph, n);
    errdefer gpa.free(glyphs);
    var cl: std.ArrayList(Cluster) = .empty;
    errdefer cl.deinit(gpa);
    const keep = clusters or any_rtl;
    var x: f32 = 0;
    var k: usize = 0;
    for (runs) |r| {
        var i: usize = 0;
        while (i < r.glyphs.len) {
            // The glyphs of one cluster are side by side.
            var j = i;
            const c = r.glyphs[i].cluster;
            const x0 = x;
            while (j < r.glyphs.len and r.glyphs[j].cluster == c) : (j += 1) {
                const g = r.glyphs[j];
                glyphs[k] = .{ .font = r.font, .glyph = g.id, .x = x + g.dx, .y = g.dy, .index = c - base };
                k += 1;
                x += g.advance;
            }
            if (keep) try cl.append(gpa, .{ .start = c - base, .end = clusterEnd(r, c) - base, .x0 = x0, .x1 = x, .rtl = r.rtl() });
            i = j;
        }
    }
    return .{ .width = x, .glyphs = glyphs, .clusters = if (keep) try cl.toOwnedSlice(gpa) else &.{}, .rtl = para_rtl };
}

/// The byte after the cluster starting at `c` of run `r`: the next
/// cluster's start in logical order, else the run's end.
fn clusterEnd(r: Run, c: u32) u32 {
    var end = r.end;
    for (r.glyphs) |g| if (g.cluster > c and g.cluster < end) {
        end = g.cluster;
    };
    return end;
}

test "runs placed in visual order with their clusters" {
    const gpa = std.testing.allocator;
    // "ab" then a right-to-left run of two characters (bytes 2..6), its
    // last character's glyph first.
    const ltr = [_]Shaped{ .{ .id = 1, .advance = 5, .cluster = 0 }, .{ .id = 2, .advance = 6, .cluster = 1 } };
    const rtl = [_]Shaped{ .{ .id = 4, .advance = 7, .cluster = 4 }, .{ .id = 3, .advance = 8, .cluster = 2 } };
    const runs = [_]Run{ .{ .font = 0, .start = 0, .end = 2, .glyphs = &ltr }, .{ .font = 0, .level = 1, .start = 2, .end = 6, .glyphs = &rtl } };
    const l = try build(gpa, &runs, 0, false, false);
    defer l.free(gpa);
    try std.testing.expectEqual(@as(f32, 26), l.width);
    try std.testing.expectEqual(@as(usize, 4), l.clusters.len);
    try std.testing.expectEqual(Cluster{ .start = 4, .end = 6, .x0 = 11, .x1 = 18, .rtl = true }, l.clusters[2]);
    try std.testing.expectEqual(Cluster{ .start = 2, .end = 4, .x0 = 18, .x1 = 26, .rtl = true }, l.clusters[3]);
    try std.testing.expectEqual(@as(u32, 2), l.glyphs[3].index);
}
