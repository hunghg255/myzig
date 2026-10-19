//! Markdown into a rich text document, with the parser of Markdown views
//! (CommonMark with GitHub's extensions): headings (the fourth level and
//! deeper as the third), paragraphs, quotations, fenced and indented code
//! (a block per line), bulleted, numbered and task lists nested by their
//! levels, and tables as lines of their cells apart by tabs. Inlines keep
//! bold, italics, strikethrough, code, links and `<u>` underlines.
const std = @import("std");
const model = @import("model.zig");
const mdoc = @import("../markdown/document.zig");
const inl = @import("../markdown/inlines.zig");
const Doc = model.Doc;
const Marks = model.Marks;
const BlockStyle = model.BlockStyle;

const P = struct {
    d: *Doc,
    md: *mdoc.Document,
    quote: bool = false,
    /// The level the next list's items are at.
    depth: u8 = 0,
    /// Underlined by `<u>` until `</u>`.
    underline: bool = false,

    fn add(p: *P, st: BlockStyle) *model.Block {
        var s = st;
        if (p.quote and s.kind == .paragraph) s.kind = .quote;
        p.d.blocks.append(p.d.gpa, .{ .style = s }) catch @panic("OOM");
        return &p.d.blocks.items[p.d.blocks.items.len - 1];
    }

    fn blocks(p: *P, parent: u32) void {
        var it = p.md.children(parent);
        while (it.next()) |i| p.block(i, .{ .indent = if (p.depth > 0) @min(p.depth, model.max_indent) else 0 });
    }

    fn block(p: *P, i: u32, st: BlockStyle) void {
        const b = p.md.block(i).*;
        switch (b.kind) {
            .paragraph => p.inlines(i, p.add(st)),
            .heading => p.inlines(i, p.add(.{ .kind = .heading(b.level) })),
            .code_block, .html_block => {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(p.d.gpa);
                p.md.contentInto(i, &buf, p.d.gpa) catch @panic("OOM");
                var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, buf.items, "\n"), '\n');
                while (lines.next()) |line| {
                    const kind: model.Kind = if (b.kind == .code_block) .code else if (p.quote) .quote else .paragraph;
                    const nb = p.add(.{ .kind = kind });
                    nb.insert(p.d.gpa, 0, line, .{});
                }
            },
            .quote => {
                const saved = p.quote;
                p.quote = true;
                p.blocks(i);
                p.quote = saved;
            },
            .list => {
                var items = p.md.children(i);
                while (items.next()) |it| p.item(b, it);
            },
            .table => {
                var rows = p.md.children(i);
                while (rows.next()) |r| {
                    const nb = p.add(.{});
                    var cells = p.md.children(r);
                    var first = true;
                    while (cells.next()) |cell| {
                        if (!first) nb.insert(p.d.gpa, nb.len(), "\t", .{});
                        first = false;
                        p.inlines(cell, nb);
                    }
                }
            },
            .thematic_break, .root, .item, .table_row, .table_cell => {},
        }
    }

    /// An item: its first paragraph is the item, what follows it is
    /// indented under it, and lists in it a level deeper.
    fn item(p: *P, list: mdoc.Block, i: u32) void {
        const task = p.md.block(i).task;
        const st: BlockStyle = .{
            .kind = if (task != .none) .task else if (list.ordered) .numbered else .bullet,
            .indent = @min(p.depth, model.max_indent),
            .checked = task == .checked,
        };
        var it = p.md.children(i);
        const first = it.next();
        const saved = p.quote;
        p.quote = false;
        defer p.quote = saved;
        if (first != null and p.md.block(first.?).kind == .paragraph) {
            p.inlines(first.?, p.add(st));
        } else {
            _ = p.add(st);
            if (first) |f| p.nested(f);
        }
        while (it.next()) |c| p.nested(c);
    }

    fn nested(p: *P, i: u32) void {
        p.depth += 1;
        defer p.depth -= 1;
        p.block(i, .{ .indent = @min(p.depth, model.max_indent) });
    }

    fn inlines(p: *P, i: u32, b: *model.Block) void {
        const x = p.md.inlines(i);
        p.underline = false;
        p.walk(x, 0, @intCast(x.nodes.len), .{}, b);
    }

    fn put(p: *P, b: *model.Block, s: []const u8, m: Marks) void {
        var mm = m;
        if (p.underline) mm.underline = true;
        b.insert(p.d.gpa, b.len(), s, mm);
    }

    fn walk(p: *P, x: *const inl.Inlines, from: u32, to: u32, m: Marks, b: *model.Block) void {
        var j = from;
        while (j < to) {
            const n = x.nodes[j];
            switch (n.kind) {
                .text => p.put(b, x.text(j), m),
                .softbreak, .hardbreak => p.put(b, " ", m),
                .code => {
                    var c = m;
                    c.code = true;
                    p.put(b, x.text(j), c);
                },
                .html => {
                    const t = x.text(j);
                    if (std.ascii.eqlIgnoreCase(t, "<u>")) {
                        p.underline = true;
                    } else if (std.ascii.eqlIgnoreCase(t, "</u>")) {
                        p.underline = false;
                    } else p.put(b, t, m);
                },
                .emph, .strong, .strike => {
                    var c = m;
                    switch (n.kind) {
                        .emph => c.italic = true,
                        .strong => c.bold = true,
                        else => c.strike = true,
                    }
                    p.walk(x, j + 1, n.next, c, b);
                },
                .link => {
                    var c = m;
                    c.link = p.d.link(x.text(j));
                    p.walk(x, j + 1, n.next, c, b);
                },
                .image => p.walk(x, j + 1, n.next, m, b),
            }
            j = n.next;
        }
    }
};

/// `md` as a document, in memory of `gpa`.
pub fn parse(gpa: std.mem.Allocator, md: []const u8) Doc {
    var d = Doc.init(gpa);
    d.blocks.clearRetainingCapacity();
    var m = mdoc.Document.parse(gpa, md, .gfm);
    defer m.deinit();
    var p: P = .{ .d = &d, .md = &m };
    p.blocks(0);
    if (d.count() == 0) d.blocks.append(gpa, .{}) catch @panic("OOM");
    return d;
}

const testing = std.testing;

test "Markdown's blocks and inlines" {
    const gpa = testing.allocator;
    var d = parse(gpa,
        \\# Title
        \\
        \\Some **bold** and *it* `code` ~~gone~~ [zig](https://ziglang.org) <u>under</u>.
        \\
        \\- one
        \\  - nested
        \\1. first
        \\- [x] done
        \\
        \\> quoted
        \\
        \\```
        \\a
        \\b
        \\```
    );
    defer d.deinit();
    const kinds = [_]model.Kind{ .heading1, .paragraph, .bullet, .bullet, .numbered, .task, .quote, .code, .code };
    try testing.expectEqual(kinds.len, d.count());
    for (kinds, 0..) |k, i| try testing.expectEqual(k, d.block(i).style.kind);
    try testing.expectEqual(@as(u8, 1), d.block(3).style.indent);
    try testing.expect(d.block(5).style.checked);
    const para = d.block(1);
    try testing.expectEqualStrings("Some bold and it code gone zig under.", para.str());
    try testing.expect(para.marksAt(5).bold);
    try testing.expect(para.marksAt(14).italic);
    try testing.expect(para.marksAt(17).code);
    try testing.expect(para.marksAt(22).strike);
    try testing.expectEqualStrings("https://ziglang.org", d.url(para.marksAt(27).link));
    try testing.expect(para.marksAt(31).underline);
    try testing.expect(!para.marksAt(36).underline);
}
