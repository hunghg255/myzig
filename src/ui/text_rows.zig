//! Rows of a wrapped line in either direction, for views that draw each row
//! as a text of its own (text areas, the code editor, rich text): rows break
//! where the line's characters, measured in logical order, pass the width,
//! and a row's carets, hits and selections are those of the row laid out
//! alone, which the bidirectional order makes differ from the line's when
//! the row reads right to left. The same contract as `textlayout.zig`'s
//! glyph-walking versions, which they replace where text may read right to
//! left; for text that reads left to right they give the same results.
const std = @import("std");
const text = @import("text.zig");
const types = @import("types.zig");
const caret = @import("text_caret.zig");
const utf8 = @import("utf8.zig");

/// The bytes rows of `s` (laid out as `lay`) start at, wrapped at `width`:
/// after the last space that fits, or between characters for a word wider
/// than the row. Every byte belongs to a row (spaces end the row they
/// follow). In `gpa` (a frame's arena).
pub fn breakRows(gpa: std.mem.Allocator, lay: anytype, s: []const u8, width: f32) []u32 {
    var out: std.ArrayList(u32) = .empty;
    out.append(gpa, 0) catch return &.{};
    if (width <= 0 or s.len == 0) return out.items;
    const xs = gpa.alloc(f32, s.len + 1) catch return out.items;
    defer gpa.free(xs);
    caret.logicalX(lay, s, xs);
    var row_start: usize = 0;
    var row_x: f32 = 0;
    var space: ?struct { at: usize, x: f32 } = null;
    var i: usize = 0;
    while (i < s.len) {
        const next = @min(s.len, i + utf8.seqLen(s[i]));
        const end_x = xs[next];
        if (end_x - row_x > width and i > row_start and s[i] != ' ') {
            const brk = if (space) |sp| if (sp.at > row_start) sp else null else null;
            const b = if (brk) |sp| sp.at else i;
            out.append(gpa, @intCast(b)) catch break;
            row_start = b;
            row_x = if (brk) |sp| sp.x else xs[i];
            space = null;
        }
        if (s[i] == ' ' or s[i] == '\t') space = .{ .at = next, .x = end_x };
        i = next;
    }
    return out.items;
}

/// The x of the caret before byte `at` of a row (bytes `row[0]`..`row[1]`
/// of line `line`), from the row's start, as the row is drawn alone.
pub fn xIn(ts: *text.TextSystem, style: types.TextStyle, line: []const u8, row: [2]usize, at: usize) f32 {
    const str = line[row[0]..row[1]];
    if (str.len == 0) return 0;
    return caret.caretX(ts.layout(str, style), str, @min(at, row[1]) - @min(row[0], at));
}

/// The byte of a row nearest `x` (from the row's start), in the line.
pub fn atX(ts: *text.TextSystem, style: types.TextStyle, line: []const u8, row: [2]usize, x: f32) usize {
    const str = line[row[0]..row[1]];
    if (str.len == 0) return row[0];
    return row[0] + caret.indexAt(ts.layout(str, style), str, x);
}

/// The ranges of x (from the row's start) bytes `a`..`b` of the line cover
/// in a row, written to `out`; returns how many.
pub fn selectionIn(ts: *text.TextSystem, style: types.TextStyle, line: []const u8, row: [2]usize, a: usize, b: usize, out: [][2]f32) usize {
    const str = line[row[0]..row[1]];
    const lo = @max(a, row[0]);
    const hi = @min(b, row[1]);
    if (str.len == 0 or hi <= lo) return 0;
    return caret.selection(ts.layout(str, style), str, lo - row[0], hi - row[0], out);
}

test "rows break by logical width, in either direction" {
    const gpa = std.testing.allocator;
    var ts = text.TextSystem.init(gpa);
    defer ts.deinit();
    const style: types.TextStyle = .{ .size = 14 };
    const tl = @import("textlayout.zig");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // Left to right: what the glyph walk gives.
    const s = "The quick brown fox jumps over the lazy dog, and on and on it goes";
    const lay = ts.layout(s, style);
    try std.testing.expectEqualSlices(u32, tl.breakRows(a, lay, s, 120), breakRows(a, lay, s, 120));
    // Hebrew: rows no wider than asked, each laid out alone.
    const he = "\xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d \xd7\xa2\xd7\x95\xd7\x9c\xd7\x9d \xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d \xd7\xa2\xd7\x95\xd7\x9c\xd7\x9d \xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d";
    const hl = ts.layout(he, style);
    const rows = breakRows(a, hl, he, hl.width / 2);
    try std.testing.expect(rows.len >= 2);
    for (rows, 0..) |r0, k| {
        const r1 = if (k + 1 < rows.len) rows[k + 1] else he.len;
        const row = std.mem.trimEnd(u8, he[r0..r1], " ");
        try std.testing.expect(ts.width(row, style) <= hl.width / 2 + 0.5);
        // The row's first character is at its right; a hit there finds it.
        const w = ts.width(row, style);
        try std.testing.expectApproxEqAbs(w, xIn(&ts, style, he, .{ r0, r0 + row.len }, r0), 0.5);
        try std.testing.expectEqual(@as(usize, r0), atX(&ts, style, he, .{ r0, r0 + row.len }, w - 0.5));
    }
}
