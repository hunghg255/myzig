//! Long lines of a text area or an editor laid out within a frame's
//! budget, after mygo's 9965d50 (which bounds how much of the text a frame
//! reads and measures). Shaping a line in one call costs more the longer
//! it is, and a line of megabytes (minified code, a log without breaks)
//! laid out whole took seconds in the frame that showed it, and every
//! frame then copied and wrapped it again.
//!
//! A line of `long_line` bytes or more is laid out in pieces of at most
//! `piece_bytes` (ending after a space where one is near, else between
//! characters: what the shaping fast path takes, `text_simple.zig`), and
//! kept with its rows across frames (`LongLines`). A frame shapes and
//! wraps at most `budget_bytes` of the long lines it shows, in order; a
//! line not laid out to its end shows as far as it is, and frames follow
//! until it is (`pending`). An edit keeps the pieces before it: typing in
//! a long line shapes the piece it is in and those after, not the line.
const std = @import("std");
const text = @import("text.zig");
const layout = @import("textlayout.zig");
const TextDoc = @import("textdoc.zig").TextDoc;
const Glyph = text.Glyph;

/// Lines this long are laid out in pieces and kept.
pub const long_line = 4096;
/// The most bytes of a piece.
pub const piece_bytes = 256;
/// The most bytes of long lines a frame shapes (wrapping counts an eighth).
pub const budget_bytes = 32 << 10;

/// Where the greedy wrap of a line stands (`layout.breakRows`): rows so
/// far, the glyph it goes on from, the row it is in, and the last space
/// it may break after.
pub const Breaker = struct {
    rows: std.ArrayList(u32) = .empty,
    next: usize = 0,
    row_start: usize = 0,
    row_x: f32 = 0,
    space: ?struct { at: usize, x: f32 } = null,

    pub fn reset(b: *Breaker, gpa: std.mem.Allocator) void {
        b.rows.clearRetainingCapacity();
        b.rows.append(gpa, 0) catch {};
        b.next = 0;
        b.row_start = 0;
        b.row_x = 0;
        b.space = null;
    }

    /// Wraps glyphs from `next` on, up to `limit` of them, at `width`: of
    /// `lay` for `s`, whose glyphs may not be all laid out yet (`whole`
    /// tells that they are: the last glyph's end is then the width).
    pub fn run(b: *Breaker, gpa: std.mem.Allocator, lay: text.Layout, s: []const u8, width: f32, whole: bool, limit: usize) void {
        const gs = lay.glyphs;
        // Without the glyph after it, a glyph's end is unknown.
        const last = if (whole) gs.len else gs.len -| 1;
        const stop = @min(last, b.next + limit);
        while (b.next < stop) : (b.next += 1) {
            const i = b.next;
            const g = gs[i];
            const end_x = if (i + 1 < gs.len) gs[i + 1].x else lay.width;
            const at: usize = g.index;
            if (at >= s.len) continue;
            if (end_x - b.row_x > width and at > b.row_start and s[at] != ' ') {
                const brk = if (b.space) |sp| if (sp.at > b.row_start) sp else null else null;
                const cut = if (brk) |sp| sp.at else at;
                b.rows.append(gpa, @intCast(cut)) catch return;
                b.row_start = cut;
                b.row_x = if (brk) |sp| sp.x else g.x;
                b.space = null;
            }
            if (s[at] == ' ' or s[at] == '\t') b.space = .{ .at = at + 1, .x = end_x };
        }
    }
};

/// A long line as laid out so far.
const Entry = struct {
    line: usize,
    version: u64,
    start: usize,
    style: u64,
    width: f32,
    str: std.ArrayList(u8) = .empty,
    glyphs: std.ArrayList(Glyph) = .empty,
    /// Where each piece ends, and the pen there.
    ends: std.ArrayList(u32) = .empty,
    xs: std.ArrayList(f32) = .empty,
    breaker: Breaker = .{},
    /// The frame it was last laid out in.
    frame: u64,

    fn deinit(e: *Entry, gpa: std.mem.Allocator) void {
        e.str.deinit(gpa);
        e.glyphs.deinit(gpa);
        e.ends.deinit(gpa);
        e.xs.deinit(gpa);
        e.breaker.rows.deinit(gpa);
    }

    fn done(e: *const Entry) usize {
        return if (e.ends.items.len == 0) 0 else e.ends.items[e.ends.items.len - 1];
    }

    fn pen(e: *const Entry) f32 {
        return if (e.xs.items.len == 0) 0 else e.xs.items[e.xs.items.len - 1];
    }

    fn lay(e: *const Entry) text.Layout {
        return .{ .width = e.pen(), .glyphs = e.glyphs.items };
    }

    /// Forgets what follows byte `keep` of the line: the pieces from the
    /// one it is in, and the rows from the one they start in.
    fn truncate(e: *Entry, keep: usize) void {
        var n = e.ends.items.len;
        while (n > 0 and e.ends.items[n - 1] > keep) n -= 1;
        e.ends.shrinkRetainingCapacity(n);
        e.xs.shrinkRetainingCapacity(n);
        const d = e.done();
        var g = e.glyphs.items.len;
        while (g > 0 and e.glyphs.items[g - 1].index >= d) g -= 1;
        e.glyphs.shrinkRetainingCapacity(g);
        // The wrap goes on from the start of the row the cut is in.
        const b = &e.breaker;
        var r = b.rows.items.len;
        while (r > 1 and b.rows.items[r - 1] >= d) r -= 1;
        b.rows.shrinkRetainingCapacity(r);
        b.row_start = b.rows.items[r - 1];
        var k: usize = 0;
        while (k < e.glyphs.items.len and e.glyphs.items[k].index < b.row_start) k += 1;
        b.next = k;
        b.row_x = if (k < e.glyphs.items.len) e.glyphs.items[k].x else e.pen();
        b.space = null;
    }
};

/// The long lines a text keeps laid out, and the frame's budget.
pub const LongLines = struct {
    gpa: std.mem.Allocator = std.heap.page_allocator,
    entries: std.ArrayList(Entry) = .empty,
    frame: u64 = 0,
    left: usize = budget_bytes,
    /// Bytes shaped in this frame, for tests.
    shaped: usize = 0,
    /// A line shown is not laid out to its end: another frame should follow.
    pending: bool = false,

    pub fn deinit(l: *LongLines) void {
        for (l.entries.items) |*e| e.deinit(l.gpa);
        l.entries.deinit(l.gpa);
    }

    /// A new frame's budget; the lines not shown in the last frames go.
    pub fn beginFrame(l: *LongLines, gpa: std.mem.Allocator, frame: u64) void {
        // The passes of one frame share its budget.
        if (frame == l.frame and l.entries.items.len > 0) return;
        l.gpa = gpa;
        l.frame = frame;
        l.left = budget_bytes;
        l.shaped = 0;
        l.pending = false;
        var i: usize = 0;
        while (i < l.entries.items.len) {
            if (l.entries.items[i].frame + 2 < frame) {
                l.entries.items[i].deinit(gpa);
                _ = l.entries.swapRemove(i);
            } else i += 1;
        }
    }

    /// Line `line` of `doc` (a long one) laid out as far as the budget
    /// lets, in `g`: as `layout.lineRows` gives it, its text and glyphs
    /// up to where it is laid out.
    pub fn rows(l: *LongLines, g: layout.Geo, doc: *const TextDoc, line: usize) layout.LineRows {
        const gpa = l.gpa;
        const start = doc.lineStart(line);
        var h = std.hash.Wyhash.init(0x10a9);
        h.update(std.mem.asBytes(&[_]f32{ g.style.size, g.style.leading }));
        h.update(&.{ @intFromEnum(g.style.weight), @intFromBool(g.style.mono), @intFromBool(g.style.italic) });
        const style = h.final();
        const e = l.entryOf(gpa, line, style) orelse return layout.wholeRows(g, doc, line);
        if (e.frame != l.frame or e.version != doc.version) l.advance(gpa, e, g, doc, line, start, style);
        if (e.done() < e.str.items.len) l.pending = true;
        const one = g.arena.alloc(u32, 1) catch unreachable;
        one[0] = 0;
        const rs = if (g.wrap > 0 and e.breaker.rows.items.len > 0) e.breaker.rows.items else one;
        return .{ .start = start, .str = e.str.items[0..e.done()], .lay = e.lay(), .rows = rs };
    }

    fn entryOf(l: *LongLines, gpa: std.mem.Allocator, line: usize, style: u64) ?*Entry {
        for (l.entries.items) |*e| if (e.line == line) return e;
        l.entries.append(gpa, .{ .line = line, .version = std.math.maxInt(u64), .start = 0, .style = style, .width = -1, .frame = l.frame -% 1 }) catch return null;
        return &l.entries.items[l.entries.items.len - 1];
    }

    /// Brings `e` to the line as it is, then lays more of it out.
    fn advance(l: *LongLines, gpa: std.mem.Allocator, e: *Entry, g: layout.Geo, doc: *const TextDoc, line: usize, start: usize, style: u64) void {
        e.frame = l.frame;
        if (e.version != doc.version or e.start != start or e.style != style) {
            const now = doc.line(g.arena, line);
            // The pieces before what changed are kept.
            var same: usize = 0;
            if (e.style == style) {
                const old = e.str.items;
                const n = @min(old.len, now.len);
                same = n;
                if (std.mem.indexOfDiff(u8, old[0..n], now[0..n])) |d| same = d;
            }
            e.str.clearRetainingCapacity();
            e.str.appendSlice(gpa, now) catch {};
            if (same == 0) {
                e.glyphs.clearRetainingCapacity();
                e.ends.clearRetainingCapacity();
                e.xs.clearRetainingCapacity();
                e.breaker.reset(gpa);
            } else e.truncate(same);
            e.version = doc.version;
            e.start = start;
            e.style = style;
        }
        if (@abs(e.width - g.wrap) > 0.5) {
            e.width = g.wrap;
            e.breaker.reset(gpa);
        }
        const s = e.str.items;
        while (e.done() < s.len and l.left > 0) {
            const a = e.done();
            const b = pieceEnd(s, a);
            const piece = g.ts.layout(s[a..b], g.style);
            const x = e.pen();
            for (piece.glyphs) |pg| {
                var q = pg;
                q.x += x;
                q.index += @intCast(a);
                e.glyphs.append(gpa, q) catch return;
            }
            e.ends.append(gpa, @intCast(b)) catch return;
            e.xs.append(gpa, x + piece.width) catch return;
            l.left -|= b - a;
            l.shaped += b - a;
        }
        if (g.wrap > 0) {
            if (e.breaker.rows.items.len == 0) e.breaker.reset(gpa);
            const whole = e.done() == s.len;
            const before = e.breaker.next;
            e.breaker.run(gpa, e.lay(), s[0..e.done()], g.wrap, whole, @max(l.left * 8, 1024));
            l.left -|= (e.breaker.next - before) / 8;
            if (whole and e.breaker.next < e.glyphs.items.len) l.pending = true;
        }
    }
};

/// Where the piece from byte `a` of `s` ends: after the last space of at
/// most `piece_bytes`, else at the last character boundary.
fn pieceEnd(s: []const u8, a: usize) usize {
    if (s.len - a <= piece_bytes) return s.len;
    var b = a + piece_bytes;
    var k = b;
    while (k > a + piece_bytes / 2) : (k -= 1) if (s[k - 1] == ' ') return k;
    while (b > a + 1 and (s[b] & 0xc0) == 0x80) b -= 1;
    return b;
}

test "pieces end after a space, or between characters" {
    var s: [600]u8 = @splat('x');
    try std.testing.expectEqual(@as(usize, 256), pieceEnd(&s, 0));
    s[200] = ' ';
    try std.testing.expectEqual(@as(usize, 201), pieceEnd(&s, 0));
    // A character of three bytes across the limit stays whole.
    s[200] = 'x';
    s[255] = 0xe2;
    s[256] = 0x82;
    s[257] = 0xac;
    try std.testing.expectEqual(@as(usize, 255), pieceEnd(&s, 0));
    // The last piece is what is left.
    try std.testing.expectEqual(@as(usize, 600), pieceEnd(&s, 400));
}
