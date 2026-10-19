//! The rich text editor's document: blocks (paragraphs with a style of
//! their own: headings, quotations, lines of code, items of lists nested by
//! their indent) of UTF-8 text in runs of marks (bold, italics, underline,
//! strikethrough, inline code, links, colors and highlights).
//!
//! Lists are flat, as in Quill and Notes: an item's `indent` is its level,
//! and items next to each other make a list, numbered at each level from 1.
//! Positions are a block and a byte offset in its text.
const std = @import("std");
const types = @import("../types.zig");
const Color = types.Color;

pub const Kind = enum(u8) {
    paragraph,
    heading1,
    heading2,
    heading3,
    quote,
    code,
    bullet,
    numbered,
    task,

    pub fn isList(k: Kind) bool {
        return k == .bullet or k == .numbered or k == .task;
    }

    pub fn isHeading(k: Kind) bool {
        return k == .heading1 or k == .heading2 or k == .heading3;
    }

    /// Heading `level` from 1 to 3 (0 is a paragraph; deeper ones are 3).
    pub fn heading(n: u8) Kind {
        return switch (n) {
            0 => .paragraph,
            1 => .heading1,
            2 => .heading2,
            else => .heading3,
        };
    }

    pub fn level(k: Kind) u8 {
        return switch (k) {
            .heading1 => 1,
            .heading2 => 2,
            .heading3 => 3,
            else => 0,
        };
    }
};

pub const max_indent = 6;

pub const BlockStyle = struct {
    kind: Kind = .paragraph,
    /// A list item's level, or how far a paragraph is indented.
    indent: u8 = 0,
    /// A task's.
    checked: bool = false,
};

pub const Marks = struct {
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
    code: bool = false,
    /// A link: its URL's index in `Doc.links`, plus one (0: none).
    link: u32 = 0,
    /// The text's own color, and a highlight behind it.
    color: ?Color = null,
    highlight: ?Color = null,

    pub fn eql(a: Marks, b: Marks) bool {
        return std.meta.eql(a, b);
    }

    /// What text typed right after a run of these marks gets: links and
    /// code hold only what they hold, as in NSTextView.
    pub fn extending(m: Marks) Marks {
        var e = m;
        e.link = 0;
        e.code = false;
        return e;
    }
};

/// One mark set or cleared: what formatting a range does.
pub const Mark = union(enum) {
    bold: bool,
    italic: bool,
    underline: bool,
    strike: bool,
    code: bool,
    link: u32,
    color: ?Color,
    highlight: ?Color,

    pub fn apply(ch: Mark, m: *Marks) void {
        switch (ch) {
            .bold => |v| m.bold = v,
            .italic => |v| m.italic = v,
            .underline => |v| m.underline = v,
            .strike => |v| m.strike = v,
            .code => |v| m.code = v,
            .link => |v| m.link = v,
            .color => |v| m.color = v,
            .highlight => |v| m.highlight = v,
        }
    }

    /// Whether `m` has it as it would set it.
    pub fn in(ch: Mark, m: Marks) bool {
        var n = m;
        ch.apply(&n);
        return n.eql(m);
    }
};

/// The bools of `Marks` by name, for toggling: `.bold`, `.code`, …
pub const Toggle = enum { bold, italic, underline, strike, code };

pub fn toggleMark(t: Toggle, on: bool) Mark {
    return switch (t) {
        .bold => .{ .bold = on },
        .italic => .{ .italic = on },
        .underline => .{ .underline = on },
        .strike => .{ .strike = on },
        .code => .{ .code = on },
    };
}

pub const Run = struct { len: u32, marks: Marks };

pub const Block = struct {
    style: BlockStyle = .{},
    text: std.ArrayList(u8) = .empty,
    /// Lengths add up to the text's; none while it is empty.
    runs: std.ArrayList(Run) = .empty,
    /// Its rows' height when last laid out, at the width `h_w` (-1: not
    /// laid out since it changed).
    h: f32 = 0,
    h_w: f32 = -1,

    pub fn init(gpa: std.mem.Allocator, style: BlockStyle, s: []const u8, marks: Marks) Block {
        var b: Block = .{ .style = style };
        b.insert(gpa, 0, s, marks);
        return b;
    }

    pub fn deinit(b: *Block, gpa: std.mem.Allocator) void {
        b.text.deinit(gpa);
        b.runs.deinit(gpa);
    }

    pub fn clone(b: *const Block, gpa: std.mem.Allocator) Block {
        var n: Block = .{ .style = b.style, .h = b.h, .h_w = b.h_w };
        n.text.appendSlice(gpa, b.text.items) catch @panic("OOM");
        n.runs.appendSlice(gpa, b.runs.items) catch @panic("OOM");
        return n;
    }

    pub fn len(b: *const Block) usize {
        return b.text.items.len;
    }

    pub fn str(b: *const Block) []const u8 {
        return b.text.items;
    }

    fn touched(b: *Block) void {
        b.h_w = -1;
    }

    /// The marks of byte `i` (the last run's past the end).
    pub fn marksAt(b: *const Block, i: usize) Marks {
        var at: usize = 0;
        for (b.runs.items) |r| {
            if (i < at + r.len) return r.marks;
            at += r.len;
        }
        return if (b.runs.items.len > 0) b.runs.items[b.runs.items.len - 1].marks else .{};
    }

    /// The marks text typed at `off` gets: those of the byte before it
    /// (extending), or at a block's start those of the byte after it.
    pub fn typingMarks(b: *const Block, off: usize) Marks {
        if (b.len() == 0) return .{};
        if (off == 0) return b.marksAt(0).extending();
        const before = b.marksAt(off - 1);
        // Inside a link or code (not at its end), typing stays in it.
        if (off < b.len()) {
            const after = b.marksAt(off);
            if (after.eql(before)) return before;
        }
        return before.extending();
    }

    /// Makes a run boundary at `at`; returns the index of the run starting there.
    fn cut(b: *Block, gpa: std.mem.Allocator, at: usize) usize {
        var pos: usize = 0;
        for (b.runs.items, 0..) |r, i| {
            if (pos == at) return i;
            if (at < pos + r.len) {
                const head: u32 = @intCast(at - pos);
                b.runs.items[i].len = head;
                b.runs.insert(gpa, i + 1, .{ .len = r.len - head, .marks = r.marks }) catch @panic("OOM");
                return i + 1;
            }
            pos += r.len;
        }
        return b.runs.items.len;
    }

    /// Joins neighbors with the same marks and drops empty runs.
    fn normalize(b: *Block) void {
        var out: usize = 0;
        for (b.runs.items) |r| {
            if (r.len == 0) continue;
            if (out > 0 and b.runs.items[out - 1].marks.eql(r.marks)) {
                b.runs.items[out - 1].len += r.len;
                continue;
            }
            b.runs.items[out] = r;
            out += 1;
        }
        b.runs.shrinkRetainingCapacity(out);
    }

    pub fn insert(b: *Block, gpa: std.mem.Allocator, at_in: usize, s: []const u8, marks: Marks) void {
        if (s.len == 0) return;
        const at = @min(at_in, b.len());
        b.text.insertSlice(gpa, at, s) catch @panic("OOM");
        const i = b.cut(gpa, at);
        b.runs.insert(gpa, i, .{ .len = @intCast(s.len), .marks = marks }) catch @panic("OOM");
        b.normalize();
        b.touched();
    }

    /// Removes bytes [a, b).
    pub fn remove(b: *Block, gpa: std.mem.Allocator, a_in: usize, b_in: usize) void {
        const a = @min(a_in, b.len());
        const e = @min(@max(a, b_in), b.len());
        if (a == e) return;
        const i = b.cut(gpa, a);
        const j = b.cut(gpa, e);
        b.runs.replaceRange(gpa, i, j - i, &.{}) catch @panic("OOM");
        b.text.replaceRange(gpa, a, e - a, &.{}) catch @panic("OOM");
        b.normalize();
        b.touched();
    }

    pub fn truncate(b: *Block, gpa: std.mem.Allocator, at: usize) void {
        b.remove(gpa, at, b.len());
    }

    /// Appends bytes [a, e) of `src` with their marks.
    pub fn appendFrom(b: *Block, gpa: std.mem.Allocator, src: *const Block, a: usize, e: usize) void {
        if (e <= a) return;
        b.text.appendSlice(gpa, src.text.items[a..e]) catch @panic("OOM");
        var pos: usize = 0;
        for (src.runs.items) |r| {
            const ra = @max(pos, a);
            const rb = @min(pos + r.len, e);
            if (rb > ra) b.runs.append(gpa, .{ .len = @intCast(rb - ra), .marks = r.marks }) catch @panic("OOM");
            pos += r.len;
        }
        b.normalize();
        b.touched();
    }

    /// Sets (or clears) `ch` over bytes [a, e).
    pub fn format(b: *Block, gpa: std.mem.Allocator, a: usize, e: usize, ch: Mark) void {
        if (e <= a) return;
        const i = b.cut(gpa, a);
        const j = b.cut(gpa, @min(e, b.len()));
        for (b.runs.items[i..j]) |*r| ch.apply(&r.marks);
        b.normalize();
        b.touched();
    }

    /// Whether every byte of [a, e) has `ch` as it would set it.
    pub fn has(b: *const Block, a: usize, e: usize, ch: Mark) bool {
        var pos: usize = 0;
        for (b.runs.items) |r| {
            if (pos + r.len > a and pos < e and !ch.in(r.marks)) return false;
            pos += r.len;
        }
        return true;
    }

    /// The bytes of the run of marks equal to byte `at`'s around it,
    /// limited to those whose link is `link` (a link's whole extent).
    pub fn linkExtent(b: *const Block, at: usize, link: u32) [2]usize {
        var lo = at;
        var hi = at;
        while (lo > 0 and b.marksAt(lo - 1).link == link) lo -= 1;
        while (hi < b.len() and b.marksAt(hi).link == link) hi += 1;
        return .{ lo, hi };
    }

    pub fn setStyle(b: *Block, s: BlockStyle) void {
        b.style = s;
        b.touched();
    }
};

pub const Pos = struct {
    block: usize = 0,
    off: usize = 0,

    pub fn order(a: Pos, b: Pos) std.math.Order {
        if (a.block != b.block) return std.math.order(a.block, b.block);
        return std.math.order(a.off, b.off);
    }

    pub fn eql(a: Pos, b: Pos) bool {
        return a.block == b.block and a.off == b.off;
    }

    pub fn min(a: Pos, b: Pos) Pos {
        return if (a.order(b) == .gt) b else a;
    }

    pub fn max(a: Pos, b: Pos) Pos {
        return if (a.order(b) == .lt) b else a;
    }
};

/// A selection: where it started and its caret.
pub const Sel = struct {
    anchor: Pos = .{},
    caret: Pos = .{},

    pub fn at(p: Pos) Sel {
        return .{ .anchor = p, .caret = p };
    }

    pub fn lo(s: Sel) Pos {
        return s.anchor.min(s.caret);
    }

    pub fn hi(s: Sel) Pos {
        return s.anchor.max(s.caret);
    }

    pub fn empty(s: Sel) bool {
        return s.anchor.eql(s.caret);
    }
};

pub const Doc = struct {
    gpa: std.mem.Allocator,
    /// Never empty: an empty document is one empty paragraph.
    blocks: std.ArrayList(Block) = .empty,
    /// The URLs links point to, kept until the document goes (undo
    /// brings back runs that name them).
    links: std.ArrayList([]u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Doc {
        var d: Doc = .{ .gpa = gpa };
        d.blocks.append(gpa, .{}) catch @panic("OOM");
        return d;
    }

    pub fn deinit(d: *Doc) void {
        for (d.blocks.items) |*b| b.deinit(d.gpa);
        d.blocks.deinit(d.gpa);
        for (d.links.items) |l| d.gpa.free(l);
        d.links.deinit(d.gpa);
    }

    /// Empties the document (one empty paragraph); links are kept.
    pub fn clear(d: *Doc) void {
        for (d.blocks.items) |*b| b.deinit(d.gpa);
        d.blocks.clearRetainingCapacity();
        d.blocks.append(d.gpa, .{}) catch @panic("OOM");
    }

    pub fn count(d: *const Doc) usize {
        return d.blocks.items.len;
    }

    pub fn block(d: *const Doc, i: usize) *Block {
        return &d.blocks.items[i];
    }

    pub fn end(d: *const Doc) Pos {
        const last = d.count() - 1;
        return .{ .block = last, .off = d.blocks.items[last].len() };
    }

    pub fn clamp(d: *const Doc, p: Pos) Pos {
        const bi = @min(p.block, d.count() - 1);
        return .{ .block = bi, .off = @min(p.off, d.blocks.items[bi].len()) };
    }

    /// The id of `url` in the links (interned), for `Marks.link`.
    pub fn link(d: *Doc, u: []const u8) u32 {
        for (d.links.items, 0..) |l, i| if (std.mem.eql(u8, l, u)) return @intCast(i + 1);
        d.links.append(d.gpa, d.gpa.dupe(u8, u) catch @panic("OOM")) catch @panic("OOM");
        return @intCast(d.links.items.len);
    }

    pub fn url(d: *const Doc, id: u32) []const u8 {
        if (id == 0 or id > d.links.items.len) return "";
        return d.links.items[id - 1];
    }

    /// Adds a block at the end (building a document).
    pub fn append(d: *Doc, style: BlockStyle, s: []const u8, marks: Marks) void {
        d.blocks.append(d.gpa, .init(d.gpa, style, s, marks)) catch @panic("OOM");
    }

    /// Puts `new` (taken) in place of blocks [at, at + n) and returns
    /// those, taken, in memory of the document's allocator.
    pub fn swap(d: *Doc, at: usize, n: usize, new: []const Block) []Block {
        const old = d.gpa.dupe(Block, d.blocks.items[at .. at + n]) catch @panic("OOM");
        d.blocks.replaceRange(d.gpa, at, n, new) catch @panic("OOM");
        return old;
    }

    /// Splits block `p.block` at `p.off`: the text after it goes to a new
    /// block after it, of the same style.
    pub fn split(d: *Doc, p: Pos) void {
        const b = d.block(p.block);
        var tail: Block = .{ .style = b.style };
        tail.appendFrom(d.gpa, b, p.off, b.len());
        b.truncate(d.gpa, p.off);
        d.blocks.insert(d.gpa, p.block + 1, tail) catch @panic("OOM");
    }

    /// Deletes [lo, hi). Joined blocks take the style of the block the
    /// first byte left comes from, as word processors fix paragraph
    /// styles: deleting a heading's end joins the next block into it, and
    /// deleting it whole leaves the block after it.
    pub fn delete(d: *Doc, lo: Pos, hi: Pos) void {
        if (lo.block == hi.block) return d.block(lo.block).remove(d.gpa, lo.off, hi.off);
        const first = d.block(lo.block);
        const last = d.block(hi.block);
        const style = if (lo.off == 0) last.style else first.style;
        first.truncate(d.gpa, lo.off);
        first.appendFrom(d.gpa, last, hi.off, last.len());
        first.setStyle(style);
        for (d.blocks.items[lo.block + 1 .. hi.block + 1]) |*b| b.deinit(d.gpa);
        d.blocks.replaceRange(d.gpa, lo.block + 1, hi.block - lo.block, &.{}) catch @panic("OOM");
    }

    /// The characters of [lo, hi), blocks apart by newlines.
    pub fn plain(d: *const Doc, gpa: std.mem.Allocator, lo: Pos, hi: Pos) []u8 {
        var out: std.ArrayList(u8) = .empty;
        var i = lo.block;
        while (i <= hi.block) : (i += 1) {
            const s = d.blocks.items[i].str();
            const a = if (i == lo.block) lo.off else 0;
            const e = if (i == hi.block) hi.off else s.len;
            out.appendSlice(gpa, s[@min(a, s.len)..@min(e, s.len)]) catch @panic("OOM");
            if (i < hi.block) out.append(gpa, '\n') catch @panic("OOM");
        }
        return out.toOwnedSlice(gpa) catch @panic("OOM");
    }

    /// The whole text's characters.
    pub fn text(d: *const Doc, gpa: std.mem.Allocator) []u8 {
        return d.plain(gpa, .{}, d.end());
    }
};

const testing = std.testing;

test "runs split, join and follow edits" {
    const gpa = testing.allocator;
    var b: Block = .init(gpa, .{}, "hello world", .{});
    defer b.deinit(gpa);
    b.format(gpa, 0, 5, .{ .bold = true });
    try testing.expectEqual(@as(usize, 2), b.runs.items.len);
    try testing.expect(b.marksAt(4).bold and !b.marksAt(5).bold);
    // Typing at the end of bold continues it; at its start, it does not.
    try testing.expect(b.typingMarks(5).bold);
    try testing.expect(b.typingMarks(0).bold);
    b.insert(gpa, 5, "!", b.typingMarks(5));
    try testing.expectEqualStrings("hello! world", b.str());
    try testing.expectEqual(@as(usize, 2), b.runs.items.len);
    b.format(gpa, 0, b.len(), .{ .bold = false });
    try testing.expectEqual(@as(usize, 1), b.runs.items.len);
    b.remove(gpa, 2, 8);
    try testing.expectEqualStrings("heorld", b.str());
    try testing.expect(b.has(0, b.len(), .{ .bold = false }));
}

test "links and code hold only what they hold" {
    const gpa = testing.allocator;
    var d = Doc.init(gpa);
    defer d.deinit();
    const id = d.link("https://ziglang.org");
    try testing.expectEqual(id, d.link("https://ziglang.org"));
    const b = d.block(0);
    b.insert(gpa, 0, "zig", .{ .link = id });
    try testing.expectEqual(@as(u32, 0), b.typingMarks(3).link);
    b.insert(gpa, 3, " rocks", .{});
    try testing.expectEqual(id, b.typingMarks(2).link);
    try testing.expectEqual([2]usize{ 0, 3 }, b.linkExtent(1, id));
    try testing.expectEqualStrings("https://ziglang.org", d.url(id));
}

test "deleting across blocks keeps the style of the first byte left" {
    const gpa = testing.allocator;
    var d = Doc.init(gpa);
    defer d.deinit();
    d.block(0).insert(gpa, 0, "Title", .{});
    d.block(0).setStyle(.{ .kind = .heading1 });
    d.append(.{}, "body", .{});
    d.append(.{}, "more", .{});
    d.delete(.{ .block = 0, .off = 5 }, .{ .block = 1, .off = 0 });
    try testing.expectEqual(Kind.heading1, d.block(0).style.kind);
    try testing.expectEqualStrings("Titlebody", d.block(0).str());
    d.split(.{ .block = 0, .off = 5 });
    try testing.expectEqual(@as(usize, 3), d.count());
    d.block(1).setStyle(.{});
    // The heading whole, its newline too: the block after it is left.
    d.delete(.{ .block = 0, .off = 0 }, .{ .block = 1, .off = 0 });
    try testing.expectEqual(Kind.paragraph, d.block(0).style.kind);
    const t = d.text(gpa);
    defer gpa.free(t);
    try testing.expectEqualStrings("body\nmore", t);
}
