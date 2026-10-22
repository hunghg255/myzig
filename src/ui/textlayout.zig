//! Where the text of a text area or an editor goes: lines broken into rows
//! at a width, offsets to rows and x positions and back, and the rows of
//! every line, kept as the document changes (`WrapCache`) so that a view
//! finds the rows in view without laying out the lines above them.
//!
//! Lines a view has not laid out yet count the rows their length suggests;
//! once shown, they count what they really take.
const std = @import("std");
const types = @import("types.zig");
const text = @import("text.zig");
const TextDoc = @import("textdoc.zig").TextDoc;

/// What breaking lines into rows takes, for one frame.
pub const Geo = struct {
    ts: *text.TextSystem,
    style: types.TextStyle,
    /// The width lines wrap at; 0 when they don't.
    wrap: f32 = 0,
    row_h: f32,
    /// Rows Page Up and Page Down move by.
    page_rows: usize = 10,
    /// The frame's memory, for the lines read.
    arena: std.mem.Allocator,
    /// Long lines laid out in pieces, a budget a frame, and kept
    /// (`textlayout_long.zig`); without, they are laid out whole.
    long: ?*long_mod.LongLines = null,
};

const long_mod = @import("textlayout_long.zig");

/// The pen position at byte `at` of a laid out line.
pub fn xAt(lay: text.Layout, at: usize) f32 {
    const k = firstAt(lay, at);
    for (lay.glyphs[k..]) |g| if (g.index >= at) return g.x;
    return lay.width;
}

/// Where to look for the glyph of byte `at`: found by halves in a line
/// whose glyphs are in logical order (no clusters out of it, `text.Layout`),
/// as a long line's are; from the first otherwise.
fn firstAt(lay: text.Layout, at: usize) usize {
    if (!ordered(lay) or lay.glyphs.len < 64) return 0;
    var a: usize = 0;
    var b: usize = lay.glyphs.len;
    while (a < b) {
        const m = (a + b) / 2;
        if (lay.glyphs[m].index < at) a = m + 1 else b = m;
    }
    return a;
}

/// Whether the glyphs of `lay` are in the order of their bytes (layouts
/// that know their clusters say so; CoreText's are not assumed to be).
fn ordered(lay: text.Layout) bool {
    if (comptime !@hasField(text.Layout, "clusters")) return false;
    return lay.clusters.len == 0;
}

/// The byte of [from, to] whose caret position is nearest `x` (in the
/// line's coordinates).
pub fn indexAt(lay: text.Layout, from: usize, to: usize, x: f32) usize {
    var best = to;
    var best_d = @abs(xAt(lay, to) - x);
    for (lay.glyphs[firstAt(lay, from)..]) |g| {
        if (ordered(lay) and g.index >= to) break;
        if (g.index < from or g.index >= to) continue;
        const d = @abs(g.x - x);
        if (d < best_d) {
            best_d = d;
            best = g.index;
        }
    }
    return best;
}

/// The bytes rows of `s` start at, wrapped at `width`: after the last
/// space that fits, or between characters for a word wider than the row.
/// Every byte belongs to a row (spaces end the row they follow).
pub fn breakRows(gpa: std.mem.Allocator, lay: text.Layout, s: []const u8, width: f32) []u32 {
    var b: long_mod.Breaker = .{};
    b.reset(gpa);
    if (width > 0) b.run(gpa, lay, s, width, true, std.math.maxInt(usize));
    return b.rows.items;
}

/// A line laid out: its text, its shaping and where its rows start.
pub const LineRows = struct {
    start: usize,
    str: []const u8,
    lay: text.Layout,
    rows: []const u32,

    /// Row `i`'s bytes in the line.
    pub fn row(l: LineRows, i: usize) [2]usize {
        const a = l.rows[i];
        const b = if (i + 1 < l.rows.len) l.rows[i + 1] else l.str.len;
        return .{ a, b };
    }

    /// The row of byte `at` (in the line): the row it starts, except at the
    /// line's end.
    pub fn rowOf(l: LineRows, at: usize) usize {
        var i = l.rows.len - 1;
        while (i > 0 and l.rows[i] > at) i -= 1;
        return i;
    }

    /// x of byte `at` (in the line) within its row `i`.
    pub fn xIn(l: LineRows, i: usize, at: usize) f32 {
        return xAt(l.lay, at) - xAt(l.lay, l.rows[i]);
    }

    /// The byte of row `i` nearest `x`; the end of a wrapped row is the
    /// last byte before the next row, so that the caret stays on it.
    pub fn atX(l: LineRows, i: usize, x: f32) usize {
        const r = l.row(i);
        const last = if (i + 1 < l.rows.len) prevBoundary(l.str, r[1]) else r[1];
        return indexAt(l.lay, r[0], @max(r[0], last), x + xAt(l.lay, r[0]));
    }
};

fn prevBoundary(s: []const u8, i: usize) usize {
    if (i == 0) return 0;
    var j = i - 1;
    while (j > 0 and (s[j] & 0xc0) == 0x80) j -= 1;
    return j;
}

/// Line `line` of `doc`, laid out in `g`: a long one as far as the
/// frame's budget lets (`Geo.long`).
pub fn lineRows(g: Geo, doc: *const TextDoc, line: usize) LineRows {
    if (g.long) |l| if (doc.lineEnd(line) - doc.lineStart(line) >= long_mod.long_line) return l.rows(g, doc, line);
    return wholeRows(g, doc, line);
}

/// Line `line` of `doc`, laid out whole in `g`.
pub fn wholeRows(g: Geo, doc: *const TextDoc, line: usize) LineRows {
    const start = doc.lineStart(line);
    const str = doc.line(g.arena, line);
    const lay = g.ts.layout(str, g.style);
    const one = g.arena.alloc(u32, 1) catch unreachable;
    one[0] = 0;
    const rows = if (g.wrap > 0) breakRows(g.arena, lay, str, g.wrap) else one;
    return .{ .start = start, .str = str, .lay = lay, .rows = if (rows.len == 0) one else rows };
}

/// Where byte `at` of `doc` is drawn: its line, the row in the line, and
/// its x in the row.
pub const Pos = struct { line: usize, sub: usize, x: f32 };

pub fn posOf(g: Geo, doc: *const TextDoc, at: usize) Pos {
    const line = doc.lineOf(at);
    const l = lineRows(g, doc, line);
    const in = at - l.start;
    const sub = l.rowOf(in);
    return .{ .line = line, .sub = sub, .x = l.xIn(sub, in) };
}

/// The rows of every line, as last laid out or estimated.
pub const WrapCache = struct {
    /// Rows of each line; the top bit marks lines laid out.
    rows: std.ArrayList(u32) = .empty,
    seen: u64 = 0,
    synced: bool = false,
    width: f32 = 0,
    char_w: f32 = 0,
    total: usize = 0,

    const measured_bit: u32 = 1 << 31;

    pub fn deinit(w: *WrapCache, gpa: std.mem.Allocator) void {
        w.rows.deinit(gpa);
    }

    fn estimate(w: *const WrapCache, bytes: usize) u32 {
        const cols = @max(1, w.width / @max(1, w.char_w));
        return @max(1, @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(bytes)) / cols))));
    }

    /// Follows the document's edits; lays everything out again (by
    /// estimate) when the width changes, or wrapping is turned off (0).
    pub fn sync(w: *WrapCache, gpa: std.mem.Allocator, doc: *const TextDoc, width: f32, char_w: f32) void {
        if (width <= 0) {
            w.synced = false;
            w.width = 0;
            return;
        }
        const fresh = !w.synced or @abs(width - w.width) > 0.5 or char_w != w.char_w;
        w.width = width;
        w.char_w = char_w;
        if (!fresh) if (doc.splicesSince(w.seen)) |splices| {
            for (splices) |sp| {
                if (sp.line + sp.old > w.rows.items.len) break;
                for (w.rows.items[sp.line .. sp.line + sp.old]) |r| w.total -= r & ~measured_bit;
                var fill: [64]u32 = undefined;
                // usize: @min with the array's length gives a u7, which
                // counting on past it (a paste of 128 lines) overflows.
                const n: usize = @min(sp.new, fill.len);
                for (0..n) |k| {
                    const li = sp.line + k;
                    fill[k] = if (li < doc.lineCount()) w.estimate(doc.lineEnd(li) - doc.lineStart(li)) else 1;
                    w.total += fill[k];
                }
                w.rows.replaceRange(gpa, sp.line, sp.old, fill[0..n]) catch break;
                // More lines than the stack holds: the rest by estimate too.
                var k = n;
                while (k < sp.new) : (k += 1) {
                    const li = sp.line + k;
                    const e = if (li < doc.lineCount()) w.estimate(doc.lineEnd(li) - doc.lineStart(li)) else 1;
                    w.rows.insert(gpa, li, e) catch break;
                    w.total += e;
                }
            }
            w.seen = doc.spliceSeq();
            if (w.rows.items.len == doc.lineCount()) return;
        };
        w.rows.clearRetainingCapacity();
        w.total = 0;
        var it = doc.rope.lines(gpa, 0);
        defer it.deinit();
        while (it.next()) |l| {
            const e = w.estimate(l.len);
            w.rows.append(gpa, e) catch break;
            w.total += e;
        }
        w.seen = doc.spliceSeq();
        w.synced = true;
    }

    fn wrapping(w: *const WrapCache, doc: *const TextDoc) bool {
        return w.width > 0 and w.synced and w.rows.items.len == doc.lineCount();
    }

    pub fn rowsOf(w: *const WrapCache, doc: *const TextDoc, line: usize) usize {
        if (!w.wrapping(doc)) return 1;
        return w.rows.items[@min(line, w.rows.items.len - 1)] & ~measured_bit;
    }

    /// Records the rows line `line` took when laid out.
    pub fn measured(w: *WrapCache, doc: *const TextDoc, line: usize, rows: usize) void {
        if (!w.wrapping(doc) or line >= w.rows.items.len) return;
        const old = w.rows.items[line] & ~measured_bit;
        w.total = w.total - old + rows;
        w.rows.items[line] = @as(u32, @intCast(rows)) | measured_bit;
    }

    pub fn totalRows(w: *const WrapCache, doc: *const TextDoc) usize {
        return if (w.wrapping(doc)) w.total else doc.lineCount();
    }

    /// The first row of line `line`.
    pub fn rowOf(w: *const WrapCache, doc: *const TextDoc, line: usize) usize {
        if (!w.wrapping(doc)) return line;
        var n: usize = 0;
        for (w.rows.items[0..@min(line, w.rows.items.len)]) |r| n += r & ~measured_bit;
        return n;
    }

    /// The line row `row` is in, and the row in it.
    pub fn lineAt(w: *const WrapCache, doc: *const TextDoc, row: usize) struct { line: usize, sub: usize } {
        if (!w.wrapping(doc)) return .{ .line = @min(row, doc.lineCount() - 1), .sub = 0 };
        var n: usize = 0;
        for (w.rows.items, 0..) |r_, i| {
            const r = r_ & ~measured_bit;
            if (row < n + r) return .{ .line = i, .sub = row - n };
            n += r;
        }
        const last = w.rows.items.len - 1;
        return .{ .line = last, .sub = (w.rows.items[last] & ~measured_bit) - 1 };
    }
};

test "a wrapped document takes a paste of more lines than the stack holds" {
    const gpa = std.testing.allocator;
    var doc = TextDoc.init(gpa, "one\ntwo\n");
    defer doc.deinit();
    var w: WrapCache = .{};
    defer w.deinit(gpa);
    w.sync(gpa, &doc, 100, 10);
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(gpa);
    for (0..300) |_| try many.appendSlice(gpa, "a line\n");
    doc.replace(0, 0, many.items);
    w.sync(gpa, &doc, 100, 10);
    try std.testing.expectEqual(doc.lineCount(), w.rows.items.len);
    try std.testing.expectEqual(doc.lineCount(), w.totalRows(&doc));
}
