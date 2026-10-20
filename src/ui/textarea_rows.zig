//! A text view's rows: the bytes of a long row in view, and the spans
//! of a line clipped to one of its rows.
const std = @import("std");
const types = @import("types.zig");
const layout = @import("textlayout.zig");
const Context = @import("context.zig").Context;

/// The bytes of row `sub` (bytes `r`) of `lr` whose glyphs lie between
/// `lo` and `hi` (in the row's coordinates), at the glyphs' boundaries.
pub fn shownBytes(lr: layout.LineRows, sub: usize, r: [2]usize, lo: f32, hi: f32) [2]usize {
    const gs = lr.lay.glyphs;
    const x0 = layout.xAt(lr.lay, r[0]);
    const first = struct {
        fn f(g: []const @import("text.zig").Glyph, x: f32) usize {
            var a: usize = 0;
            var b: usize = g.len;
            while (a < b) {
                const m = (a + b) / 2;
                if (g[m].x < x) a = m + 1 else b = m;
            }
            return a;
        }
    }.f;
    _ = sub;
    const i = first(gs, x0 + lo) -| 1;
    const j = first(gs, x0 + hi);
    const a = if (i < gs.len) std.math.clamp(gs[i].index, r[0], r[1]) else r[1];
    const b = if (j < gs.len) std.math.clamp(gs[j].index, a, r[1]) else r[1];
    return .{ a, b };
}

/// The spans of a line clipped to its row [a, b), from the row's start.
/// The spans are sorted: those of the row are a run of them, given as
/// they are where the row starts the line and holds them whole (a line
/// that does not wrap), else clipped in one allocation of frame memory.
pub fn rowSpans(c: *Context, spans: []const types.Span, a: usize, b: usize) []const types.Span {
    return clipSpans(c.alloc(), spans, a, b);
}

pub fn clipSpans(arena: std.mem.Allocator, spans: []const types.Span, a: usize, b: usize) []const types.Span {
    var i: usize = 0;
    while (i < spans.len and spans[i].end <= a) i += 1;
    var j = i;
    while (j < spans.len and spans[j].start < b) j += 1;
    const run = spans[i..j];
    if (run.len == 0) return &.{};
    var whole = a == 0;
    for (run) |sp| whole = whole and sp.end <= b and sp.end > sp.start;
    if (whole) return run;
    const out = arena.alloc(types.Span, run.len) catch return &.{};
    var n: usize = 0;
    for (run) |sp| {
        if (sp.end <= a or sp.start >= b) continue;
        var s = sp;
        s.start = @intCast(@max(sp.start, a) - a);
        s.end = @intCast(@min(sp.end, b) - a);
        out[n] = s;
        n += 1;
    }
    return out[0..n];
}

test "a row's spans: the line's own where it does not wrap, clipped where it does" {
    const spans = [_]types.Span{ .{ .start = 0, .end = 3 }, .{ .start = 4, .end = 9 }, .{ .start = 12, .end = 14 } };
    // A row of the whole line allocates nothing.
    var none: std.heap.FixedBufferAllocator = .init(&.{});
    const all = clipSpans(none.allocator(), &spans, 0, 14);
    try std.testing.expectEqual(@as([*]const types.Span, &spans), all.ptr);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    // A row from byte 5: the second clipped, the third moved.
    var buf: [256]u8 = undefined;
    var fb: std.heap.FixedBufferAllocator = .init(&buf);
    const rest = clipSpans(fb.allocator(), &spans, 5, 14);
    try std.testing.expectEqual(@as(usize, 2), rest.len);
    try std.testing.expectEqual(@as(u32, 0), rest[0].start);
    try std.testing.expectEqual(@as(u32, 4), rest[0].end);
    try std.testing.expectEqual(@as(u32, 7), rest[1].start);
}
