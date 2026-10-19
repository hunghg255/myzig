//! AT-SPI's Text and EditableText of text fields, text areas and plain
//! text: the text by characters, words and lines (the rows it is drawn
//! in), the caret and the selection, read and set, where characters and
//! ranges are drawn and the character at a point, and the text replaced.
//! Offsets are characters (code points) of the text.
const std = @import("std");
const dbus = @import("dbus.zig");
const proto = @import("atspi_proto.zig");
const serve = @import("atspi_serve.zig");
const atext = @import("../ui/access_text.zig");
const types = @import("../ui/types.zig");
const TextRow = @import("../ui/access.zig").TextRow;
const Node = @import("../ui/access_tree.zig").Node;

pub fn hasText(n: *const Node) bool {
    return atext.hasText(n);
}

fn count(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// The byte of character `i` (the end past the last).
pub fn byteOf(s: []const u8, i: usize) usize {
    var b: usize = 0;
    var k: usize = 0;
    while (b < s.len and k < i) : (k += 1) b += std.unicode.utf8ByteSequenceLength(s[b]) catch 1;
    return @min(b, s.len);
}

pub fn charOf(s: []const u8, byte: usize) usize {
    return count(s[0..@min(byte, s.len)]);
}

pub fn property(n: *const Node, name: []const u8) ?proto.Variant {
    if (!hasText(n)) return null;
    const s = atext.textOf(n);
    if (std.mem.eql(u8, name, "CharacterCount")) return .{ .i = @intCast(count(s)) };
    if (std.mem.eql(u8, name, "CaretOffset")) return .{ .i = @intCast(charOf(s, n.caret)) };
    return null;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80 or c == '_';
}

/// Characters [start, end) of the unit around character `at`: 0 a
/// character, 1 a word, 2 a sentence, 3 a line (as drawn, where the rows
/// are known), 4 a paragraph.
pub fn unitAt(s: []const u8, rows: []const TextRow, at: usize, granularity: u32) [2]usize {
    const n = count(s);
    const i = @min(at, n);
    switch (granularity) {
        0 => return .{ i, @min(i + 1, n) },
        1 => {
            const b = byteOf(s, i);
            var lo = b;
            if (b < s.len and isWord(s[b])) while (lo > 0 and isWord(s[lo - 1])) {
                lo -= 1;
            };
            var hi = b;
            while (hi < s.len and isWord(s[hi])) hi += 1;
            // Off a word: the word after.
            if (lo == hi) {
                while (hi < s.len and !isWord(s[hi])) hi += 1;
                lo = hi;
                while (hi < s.len and isWord(s[hi])) hi += 1;
            }
            return .{ charOf(s, lo), charOf(s, hi) };
        },
        else => {
            const b = byteOf(s, i);
            var r: atext.Range = .{ .start = b, .end = b };
            r.expand(s, rows, if (granularity == 3) .line else .paragraph);
            return .{ charOf(s, r.start), charOf(s, r.end) };
        },
    }
}

fn slice(s: []const u8, start: usize, end: usize) []const u8 {
    const a = byteOf(s, start);
    return s[a..@max(a, byteOf(s, end))];
}

/// What replaced what between two texts: the characters kept before, and
/// the bytes taken out and put in there.
pub const Edit = struct { at: usize, removed: []const u8, inserted: []const u8 };

pub fn edit(old: []const u8, new: []const u8) Edit {
    var p: usize = 0;
    while (p < old.len and p < new.len and old[p] == new[p]) p += 1;
    p = atext.floorChar(old, p);
    var q: usize = 0;
    while (q < old.len - p and q < new.len - p and old[old.len - 1 - q] == new[new.len - 1 - q]) q += 1;
    // On characters of both.
    while (q > 0 and (atext.floorChar(old, old.len - q) != old.len - q or atext.floorChar(new, new.len - q) != new.len - q)) q -= 1;
    return .{ .at = charOf(old, p), .removed = old[p .. old.len - q], .inserted = new[p .. new.len - q] };
}

/// A box in the coordinates AT-SPI asks for: 0 the screen, else the window.
fn place(o: serve.Object, r: types.Rect, coords: u32) types.Rect {
    var x = r;
    if (coords == 0) {
        x.x += o.window.?.origin.x;
        x.y += o.window.?.origin.y;
    }
    return x;
}

fn extents(e: *dbus.Encoder, r: types.Rect) !void {
    try e.structStart();
    for ([_]f32{ r.x, r.y, r.w, r.h }) |v| try e.i32_(@intFromFloat(@round(v)));
}

/// The boxes of characters [start, end) joined; the node's box without rows.
fn rangeBox(n: *const Node, start: usize, end: usize) types.Rect {
    const s = atext.textOf(n);
    if (n.rows.len == 0) return n.rect;
    return atext.bounds(n.rows, byteOf(s, start), byteOf(s, end)) orelse .{};
}

/// Selects characters from `anchor` to `caret`, as the pointer would.
fn select(o: serve.Object, n: *const Node, anchor: i32, caret: i32) bool {
    if (!n.actions.select_text) return false;
    const s = atext.textOf(n);
    const len: i32 = @intCast(count(s));
    const a = byteOf(s, @intCast(std.math.clamp(anchor, 0, len)));
    const c = byteOf(s, @intCast(std.math.clamp(caret, 0, len)));
    const win = o.window.?;
    win.perform(win.ptr, n.id, n.role, .{ .select_text = .{ @intCast(a), @intCast(c) } });
    return true;
}

pub fn handle(o: serve.Object, n: *const Node, member: []const u8, d: *dbus.Decoder, e: *dbus.Encoder) !?serve.Answer {
    const eql = std.mem.eql;
    const win = o.window.?;
    if (n.actions.set_value and eql(u8, member, "SetTextContents")) {
        win.perform(win.ptr, n.id, n.role, .{ .set_value = try d.string() });
        try e.boolean(true);
        return .{ .signature = "b" };
    }
    if (!hasText(n)) return null;
    const s = atext.textOf(n);
    const len = count(s);
    if (eql(u8, member, "GetText")) {
        const start = try proto.readInt(d);
        const end = try proto.readInt(d);
        const lo: usize = @intCast(std.math.clamp(start, 0, @as(i32, @intCast(len))));
        const hi: usize = if (end < 0) len else @intCast(std.math.clamp(end, @as(i32, @intCast(lo)), @as(i32, @intCast(len))));
        try e.string(slice(s, lo, hi));
        return .{ .signature = "s" };
    }
    if (eql(u8, member, "GetStringAtOffset")) {
        const at = try proto.readInt(d);
        const g = try d.u32_();
        const r = unitAt(s, n.rows, @intCast(@max(at, 0)), g);
        try e.string(slice(s, r[0], r[1]));
        try e.i32_(@intCast(r[0]));
        try e.i32_(@intCast(r[1]));
        return .{ .signature = "sii" };
    }
    if (eql(u8, member, "GetCharacterAtOffset")) {
        const at: usize = @intCast(@max(try proto.readInt(d), 0));
        const ch = slice(s, at, at + 1);
        const cp: i32 = if (ch.len == 0) 0 else @intCast(std.unicode.utf8Decode(ch) catch 0);
        try e.i32_(cp);
        return .{ .signature = "i" };
    }
    if (eql(u8, member, "GetCaretOffset")) {
        try e.i32_(@intCast(charOf(s, n.caret)));
        return .{ .signature = "i" };
    }
    if (eql(u8, member, "GetNSelections")) {
        try e.i32_(@intFromBool(n.sel_end > n.sel_start));
        return .{ .signature = "i" };
    }
    if (eql(u8, member, "GetSelection")) {
        try e.i32_(@intCast(charOf(s, n.sel_start)));
        try e.i32_(@intCast(charOf(s, n.sel_end)));
        return .{ .signature = "ii" };
    }
    if (eql(u8, member, "SetCaretOffset")) {
        const at = try proto.readInt(d);
        try e.boolean(select(o, n, at, at));
        return .{ .signature = "b" };
    }
    if (eql(u8, member, "SetSelection")) {
        const k = try proto.readInt(d);
        const start = try proto.readInt(d);
        const end = try proto.readInt(d);
        try e.boolean(k == 0 and select(o, n, start, end));
        return .{ .signature = "b" };
    }
    if (eql(u8, member, "AddSelection")) {
        // One selection at most: added where there is none.
        const start = try proto.readInt(d);
        const end = try proto.readInt(d);
        try e.boolean(n.sel_end == n.sel_start and select(o, n, start, end));
        return .{ .signature = "b" };
    }
    if (eql(u8, member, "RemoveSelection")) {
        const k = try proto.readInt(d);
        const caret: i32 = @intCast(charOf(s, n.caret));
        try e.boolean(k == 0 and n.sel_end > n.sel_start and select(o, n, caret, caret));
        return .{ .signature = "b" };
    }
    if (eql(u8, member, "GetCharacterExtents")) {
        const at: usize = @intCast(@max(try proto.readInt(d), 0));
        const coords = try d.u32_();
        try extents(e, place(o, rangeBox(n, at, @min(at + 1, len)), coords));
        return .{ .signature = "(iiii)" };
    }
    if (eql(u8, member, "GetRangeExtents")) {
        const start: usize = @intCast(@max(try proto.readInt(d), 0));
        const end: usize = @intCast(@max(try proto.readInt(d), 0));
        const coords = try d.u32_();
        try extents(e, place(o, rangeBox(n, @min(start, end), @max(start, end)), coords));
        return .{ .signature = "(iiii)" };
    }
    if (eql(u8, member, "GetOffsetAtPoint")) {
        const x = try proto.readInt(d);
        const y = try proto.readInt(d);
        const coords = try d.u32_();
        const shift = place(o, .{}, coords);
        const p: types.Point = .{ .x = @as(f32, @floatFromInt(x)) - shift.x, .y = @as(f32, @floatFromInt(y)) - shift.y };
        const at: i32 = if (atext.offsetAt(s, n.rows, p)) |b| @intCast(charOf(s, b)) else -1;
        try e.i32_(at);
        return .{ .signature = "i" };
    }
    return null;
}

test "words, lines and characters of a value; what an edit replaced" {
    const s = "héllo wide world";
    try std.testing.expectEqual([2]usize{ 0, 5 }, unitAt(s, &.{}, 2, 1));
    try std.testing.expectEqual([2]usize{ 6, 10 }, unitAt(s, &.{}, 5, 1));
    try std.testing.expectEqual([2]usize{ 1, 2 }, unitAt(s, &.{}, 1, 0));
    try std.testing.expectEqualStrings("é", slice(s, 1, 2));
    try std.testing.expectEqual([2]usize{ 0, 3 }, unitAt("ab\ncd", &.{}, 1, 3));
    try std.testing.expectEqual([2]usize{ 3, 5 }, unitAt("ab\ncd", &.{}, 4, 3));
    const x = edit("hello world", "hello wide world");
    try std.testing.expectEqual(@as(usize, 7), x.at);
    try std.testing.expectEqualStrings("", x.removed);
    try std.testing.expectEqualStrings("ide w", x.inserted);
    const y = edit("añb", "aüb");
    try std.testing.expectEqual(@as(usize, 1), y.at);
    try std.testing.expectEqualStrings("ñ", y.removed);
    try std.testing.expectEqualStrings("ü", y.inserted);
}
