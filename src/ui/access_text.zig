//! The text of an element as assistive technology reads it, shared by the
//! platforms: its units (characters, words, lines, paragraphs, the
//! document) found from any byte, ranges moved and grown by them as UI
//! Automation's text ranges are, and where a range is drawn, from the
//! rows the widget described (`access.TextRow`). Offsets are bytes of the
//! element's text; each platform counts its own units at its edge.
const std = @import("std");
const types = @import("types.zig");
const access = @import("access.zig");
const Node = @import("access_tree.zig").Node;
const TextRow = access.TextRow;

/// UI Automation's text units, in its order.
pub const Unit = enum(u8) {
    character,
    format,
    word,
    line,
    paragraph,
    page,
    document,

    pub fn of(v: i32) Unit {
        return @fromBackingInt(@intCast(std.math.clamp(v, 0, 6)));
    }

    /// One unit holds the whole text: a single format, a single page.
    fn whole(u: Unit) bool {
        return u == .format or u == .page or u == .document;
    }
};

/// Whether the element shows a text that ranges read: a field's value
/// (but a password's), or a text's words.
pub fn hasText(n: *const Node) bool {
    return switch (n.role) {
        .text_field, .combo_box => !n.states.password,
        .text => true,
        else => false,
    };
}

pub fn textOf(n: *const Node) []const u8 {
    return if (n.role == .text) n.name else n.value;
}

fn charStart(s: []const u8, i: usize) bool {
    return i == 0 or i >= s.len or (s[i] & 0xc0) != 0x80;
}

/// The start of the character holding byte `i`.
pub fn floorChar(s: []const u8, i: usize) usize {
    var j = @min(i, s.len);
    while (j > 0 and j < s.len and !charStart(s, j)) j -= 1;
    return j;
}

pub fn nextChar(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    var j = i + 1;
    while (j < s.len and !charStart(s, j)) j += 1;
    return j;
}

pub fn prevChar(s: []const u8, i: usize) usize {
    if (i == 0) return 0;
    var j = @min(i, s.len) - 1;
    while (j > 0 and !charStart(s, j)) j -= 1;
    return j;
}

fn cpAt(s: []const u8, i: usize) u21 {
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return s[i];
    if (i + len > s.len) return s[i];
    return std.unicode.utf8Decode(s[i .. i + len]) catch s[i];
}

fn isSpace(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c, 0xa0, 0x2028, 0x2029, 0x3000 => true,
        else => false,
    };
}

/// Words, spaces and punctuation: 1, 0 and 2.
fn class(cp: u21) u2 {
    if (isSpace(cp)) return 0;
    if (cp >= 0x80 or cp == '_' or std.ascii.isAlphanumeric(@intCast(cp))) return 1;
    return 2;
}

fn rowStarts(rows: []const TextRow, i: usize) bool {
    for (rows) |r| if (r.start == i) return true;
    return false;
}

/// Whether byte `i` of `s` starts a unit. A word takes the spaces after
/// it; a line ends after a line break or where a row wraps.
pub fn isBoundary(s: []const u8, rows: []const TextRow, i: usize, unit: Unit) bool {
    if (i == 0 or i >= s.len) return true;
    if (!charStart(s, i)) return false;
    return switch (unit) {
        .character => true,
        .word => blk: {
            const a = cpAt(s, prevChar(s, i));
            const b = cpAt(s, i);
            break :blk a == '\n' or (!isSpace(b) and (isSpace(a) or class(a) != class(b)));
        },
        .line => s[i - 1] == '\n' or rowStarts(rows, i),
        .paragraph => s[i - 1] == '\n',
        .format, .page, .document => false,
    };
}

/// The start of the next unit after `i`, or the end.
pub fn next(s: []const u8, rows: []const TextRow, i: usize, unit: Unit) usize {
    if (unit.whole()) return s.len;
    var j = nextChar(s, i);
    while (j < s.len and !isBoundary(s, rows, j, unit)) j = nextChar(s, j);
    return j;
}

/// The start of the last unit before `i`, or 0.
pub fn prev(s: []const u8, rows: []const TextRow, i: usize, unit: Unit) usize {
    if (unit.whole()) return 0;
    var j = prevChar(s, i);
    while (j > 0 and !isBoundary(s, rows, j, unit)) j = prevChar(s, j);
    return j;
}

/// A range of a text: bytes [start, end).
pub const Range = struct {
    start: usize,
    end: usize,

    /// Within the text, on characters, the start first.
    pub fn clamp(r: *Range, s: []const u8) void {
        r.start = floorChar(s, r.start);
        r.end = floorChar(s, r.end);
        if (r.end < r.start) r.end = r.start;
    }

    /// Becomes the unit holding its start.
    pub fn expand(r: *Range, s: []const u8, rows: []const TextRow, unit: Unit) void {
        if (unit.whole()) {
            r.* = .{ .start = 0, .end = s.len };
            return;
        }
        var a = r.start;
        if (a >= s.len and s.len > 0) a = prevChar(s, s.len);
        if (!isBoundary(s, rows, a, unit)) a = prev(s, rows, a, unit);
        r.* = .{ .start = a, .end = next(s, rows, a, unit) };
    }

    /// Moves its start (or its end) by `count` units, the other end with
    /// it where they cross: how many it moved.
    pub fn moveEndpoint(r: *Range, s: []const u8, rows: []const TextRow, end: bool, unit_in: Unit, count_in: i32) i32 {
        const unit: Unit = if (unit_in == .page) .document else unit_in;
        var at = if (end) r.end else r.start;
        var count = count_in;
        var moved: i32 = 0;
        while (count > 0 and at < s.len) : (count -= 1) {
            at = next(s, rows, at, unit);
            moved += 1;
        }
        while (count < 0 and at > 0) : (count += 1) {
            at = prev(s, rows, at, unit);
            moved -= 1;
        }
        if (end) {
            r.end = at;
            r.start = @min(r.start, at);
        } else {
            r.start = at;
            r.end = @max(r.end, at);
        }
        return moved;
    }

    /// Moves by `count` units as UI Automation's Move does: a caret moves
    /// as one; a range goes back to the start of its unit, moves by
    /// units, then takes the unit there, never past the last one.
    pub fn move(r: *Range, s: []const u8, rows: []const TextRow, unit: Unit, count: i32) i32 {
        if (count == 0) return 0;
        if (r.start == r.end) {
            const moved = r.moveEndpoint(s, rows, false, unit, count);
            r.end = r.start;
            return moved;
        }
        if (unit.whole()) {
            r.* = .{ .start = 0, .end = s.len };
            return 0;
        }
        var at = r.start;
        if (at < s.len and !isBoundary(s, rows, at, unit)) at = prev(s, rows, at, unit);
        var moved: i32 = 0;
        while (moved < count) : (moved += 1) {
            const nx = next(s, rows, at, unit);
            if (nx >= s.len or nx == at) break;
            at = nx;
        }
        while (moved > count and at > 0) : (moved -= 1) at = prev(s, rows, at, unit);
        r.* = .{ .start = at, .end = next(s, rows, at, unit) };
        return moved;
    }
};

/// The boxes of bytes [start, end), a box for each row they are on (in
/// the rows' points); a caret's is one point wide. Without rows, none.
pub fn rects(gpa: std.mem.Allocator, rows: []const TextRow, start: usize, end: usize) ![]types.Rect {
    var out: std.ArrayList(types.Rect) = .empty;
    errdefer out.deinit(gpa);
    for (rows, 0..) |r, k| {
        if (start == end) {
            const last = k + 1 == rows.len or rows[k + 1].start > start;
            if (start < r.start or start > r.end or (start == r.end and !last)) continue;
            const x = r.xOf(start);
            try out.append(gpa, .{ .x = x, .y = r.rect.y, .w = 1, .h = r.rect.h });
            break;
        }
        const a = @max(start, r.start);
        const b = @min(end, r.end);
        if (a < b) {
            const x0 = r.xOf(a);
            try out.append(gpa, .{ .x = x0, .y = r.rect.y, .w = @max(1, r.xOf(b) - x0), .h = r.rect.h });
        } else if (r.start == r.end and start <= r.start and end > r.start) {
            // An empty line within the range.
            try out.append(gpa, .{ .x = r.rect.x, .y = r.rect.y, .w = 1, .h = r.rect.h });
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The box around bytes [start, end) on all their rows; null without
/// rows, or where none holds them.
pub fn bounds(rows: []const TextRow, start: usize, end: usize) ?types.Rect {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const boxes = rects(fba.allocator(), rows, start, end) catch return null;
    if (boxes.len == 0) return null;
    var u = boxes[0];
    for (boxes[1..]) |b| {
        const x1 = @max(u.x + u.w, b.x + b.w);
        const y1 = @max(u.y + u.h, b.y + b.h);
        u.x = @min(u.x, b.x);
        u.y = @min(u.y, b.y);
        u.w = x1 - u.x;
        u.h = y1 - u.y;
    }
    return u;
}

/// The byte nearest the point `p` (in the rows' points): on the row
/// under it, or the nearest row; null without rows.
pub fn offsetAt(s: []const u8, rows: []const TextRow, p: types.Point) ?usize {
    if (rows.len == 0) return null;
    var best: usize = 0;
    var best_d: f32 = std.math.inf(f32);
    for (rows, 0..) |r, k| {
        const d = if (p.y < r.rect.y) r.rect.y - p.y else if (p.y >= r.rect.y + r.rect.h) p.y - (r.rect.y + r.rect.h) + 0.001 else 0;
        if (d < best_d) {
            best_d = d;
            best = k;
        }
    }
    const r = rows[best];
    var at: usize = r.start;
    var near: f32 = std.math.inf(f32);
    var i: usize = r.start;
    while (true) {
        const d = @abs(r.xOf(i) - p.x);
        if (d < near) {
            near = d;
            at = i;
        }
        if (i >= r.end or i >= s.len) break;
        i = nextChar(s, i);
    }
    return @min(at, s.len);
}

/// The ranges of the rows that show in `clip`, rows that follow one
/// another joined.
pub fn visible(gpa: std.mem.Allocator, s: []const u8, rows: []const TextRow, clip: types.Rect) ![][2]usize {
    var out: std.ArrayList([2]usize) = .empty;
    errdefer out.deinit(gpa);
    for (rows) |r| {
        if (r.rect.y + r.rect.h <= clip.y or r.rect.y >= clip.y + clip.h) continue;
        // A row ending at a line break holds it.
        const end = if (r.end < s.len and s[r.end] == '\n') r.end + 1 else r.end;
        if (out.items.len > 0 and out.items[out.items.len - 1][1] >= r.start) {
            out.items[out.items.len - 1][1] = @max(out.items[out.items.len - 1][1], end);
        } else try out.append(gpa, .{ r.start, end });
    }
    return out.toOwnedSlice(gpa);
}

/// Where `needle` is in `hay`, the first (or the last); ASCII letters
/// compared without case when asked.
pub fn find(hay: []const u8, needle: []const u8, backward: bool, ignore_case: bool) ?usize {
    if (needle.len == 0 or needle.len > hay.len) return null;
    const last = hay.len - needle.len;
    var k: usize = 0;
    while (k <= last) : (k += 1) {
        const i = if (backward) last - k else k;
        const at = hay[i .. i + needle.len];
        if (if (ignore_case) std.ascii.eqlIgnoreCase(at, needle) else std.mem.eql(u8, at, needle)) return i;
    }
    return null;
}

/// The x of each byte [from, to] of a laid out line, from `base` (the
/// pen at the row's start): a layout's `glyphs` (`index`, `x`) and
/// `width`, as `textlayout.xAt` finds them, in one pass.
pub fn rowXs(gpa: std.mem.Allocator, lay: anytype, from: usize, to: usize, base: f32) []f32 {
    const xs = gpa.alloc(f32, to - from + 1) catch return &.{};
    @memset(xs, std.math.nan(f32));
    var end_x: ?f32 = null;
    for (lay.glyphs) |g| {
        const at: usize = @intCast(g.index);
        if (at >= from and at < to) {
            if (std.math.isNan(xs[at - from])) xs[at - from] = g.x - base;
        } else if (at >= to and end_x == null) end_x = g.x;
    }
    xs[xs.len - 1] = (end_x orelse lay.width) - base;
    var k = xs.len - 1;
    while (k > 0) {
        k -= 1;
        if (std.math.isNan(xs[k])) xs[k] = xs[k + 1];
    }
    return xs;
}

/// UTF-16 code units of `s` before byte `b` (NSRange, UI Automation's lengths).
pub fn utf16Of(s: []const u8, b: usize) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < @min(b, s.len)) : (i = nextChar(s, i)) n += if (cpAt(s, i) >= 0x10000) 2 else 1;
    return n;
}

/// The byte at `u` UTF-16 code units into `s` (its end past them).
pub fn byteOfUtf16(s: []const u8, u: usize) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < u) : (i = nextChar(s, i)) n += if (cpAt(s, i) >= 0x10000) 2 else 1;
    return i;
}

const testing = std.testing;

test "units: words take their spaces, lines end at breaks and wraps" {
    const s = "hello wide world";
    var r: Range = .{ .start = 2, .end = 2 };
    r.expand(s, &.{}, .word);
    try testing.expectEqualStrings("hello ", s[r.start..r.end]);
    try testing.expectEqual(@as(i32, 1), r.move(s, &.{}, .word, 1));
    try testing.expectEqualStrings("wide ", s[r.start..r.end]);
    try testing.expectEqual(@as(i32, 1), r.move(s, &.{}, .word, 5));
    try testing.expectEqualStrings("world", s[r.start..r.end]);
    try testing.expectEqual(@as(i32, -2), r.move(s, &.{}, .word, -2));
    try testing.expectEqualStrings("hello ", s[r.start..r.end]);

    const t = "first line\nsecond line";
    r = .{ .start = 3, .end = 3 };
    r.expand(t, &.{}, .line);
    try testing.expectEqualStrings("first line\n", t[r.start..r.end]);
    _ = r.move(t, &.{}, .line, 1);
    try testing.expectEqualStrings("second line", t[r.start..r.end]);
    // A row wrapped at "line": a line of its own.
    const rows = [_]TextRow{ .{ .start = 11, .end = 18, .rect = .{} }, .{ .start = 18, .end = 22, .rect = .{} } };
    r = .{ .start = 19, .end = 19 };
    r.expand(t, &rows, .line);
    try testing.expectEqualStrings("line", t[r.start..r.end]);
    r = .{ .start = 19, .end = 19 };
    r.expand(t, &rows, .paragraph);
    try testing.expectEqualStrings("second line", t[r.start..r.end]);

    // Characters are code points; the end of a caret moves with it.
    const u = "añb";
    r = .{ .start = 0, .end = 0 };
    try testing.expectEqual(@as(i32, 2), r.move(u, &.{}, .character, 2));
    try testing.expectEqual(@as(usize, 3), r.start);
    try testing.expectEqual(r.start, r.end);
    try testing.expectEqual(@as(i32, 1), r.moveEndpoint(u, &.{}, true, .character, 1));
    try testing.expectEqualStrings("b", u[r.start..r.end]);
    try testing.expectEqual(@as(usize, 3), utf16Of("a😀b", 5));
    try testing.expectEqual(@as(usize, 5), byteOfUtf16("a😀b", 3));
    try testing.expectEqual(@as(?usize, 6), find(s, "WIDE", false, true));
    try testing.expectEqual(@as(?usize, null), find(s, "WIDE", false, false));
}

test "geometry: boxes of a range, the byte at a point, rows in view" {
    const s = "ab cd\nef";
    const xs0 = [_]f32{ 0, 10, 20, 30, 40, 50 };
    const xs1 = [_]f32{ 0, 10, 20 };
    const rows = [_]TextRow{
        .{ .start = 0, .end = 5, .rect = .{ .x = 100, .y = 10, .w = 50, .h = 20 }, .xs = &xs0 },
        .{ .start = 6, .end = 8, .rect = .{ .x = 100, .y = 30, .w = 20, .h = 20 }, .xs = &xs1 },
    };
    const gpa = testing.allocator;
    const all = try rects(gpa, &rows, 0, s.len);
    defer gpa.free(all);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqual(@as(f32, 50), all[0].w);
    try testing.expectEqual(@as(f32, 30), all[1].y);
    const word = try rects(gpa, &rows, 3, 5);
    defer gpa.free(word);
    try testing.expectEqual(@as(usize, 1), word.len);
    try testing.expectEqual(types.Rect{ .x = 130, .y = 10, .w = 20, .h = 20 }, word[0]);
    try testing.expectEqual(@as(?usize, 3), offsetAt(s, &rows, .{ .x = 131, .y = 15 }));
    try testing.expectEqual(@as(?usize, 7), offsetAt(s, &rows, .{ .x = 112, .y = 90 }));
    const shown = try visible(gpa, s, &rows, .{ .x = 0, .y = 0, .w = 500, .h = 500 });
    defer gpa.free(shown);
    try testing.expectEqual(@as(usize, 1), shown.len);
    try testing.expectEqual([2]usize{ 0, 8 }, shown[0]);
    const top = try visible(gpa, s, &rows, .{ .x = 0, .y = 0, .w = 500, .h = 25 });
    defer gpa.free(top);
    try testing.expectEqual([2]usize{ 0, 6 }, top[0]);

    const Glyph = struct { index: u32, x: f32 };
    const lay = .{ .glyphs = &[_]Glyph{ .{ .index = 0, .x = 0 }, .{ .index = 1, .x = 8 }, .{ .index = 3, .x = 16 } }, .width = @as(f32, 24) };
    const xs = rowXs(gpa, lay, 0, 4, 0);
    defer gpa.free(xs);
    try testing.expectEqualSlices(f32, &.{ 0, 8, 16, 16, 24 }, xs);
}
