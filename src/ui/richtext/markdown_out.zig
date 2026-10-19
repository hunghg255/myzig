//! A rich text document as Markdown: CommonMark with GitHub's task lists
//! and strikethrough. Headings, quotations, fenced code, lists nested by
//! four spaces a level, `**bold**`, `*italic*`, `~~struck~~`, `` `code` ``,
//! links, and underlines as `<u>`. Colors and highlights have no Markdown
//! and are left out; what it writes reads back the same (`markdown_in`).
const std = @import("std");
const model = @import("model.zig");
const Doc = model.Doc;
const Block = model.Block;
const Marks = model.Marks;

const W = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,

    fn s(w: *W, str: []const u8) void {
        w.out.appendSlice(w.gpa, str) catch @panic("OOM");
    }

    fn byte(w: *W, b: u8) void {
        w.out.append(w.gpa, b) catch @panic("OOM");
    }

    fn print(w: *W, comptime fmt: []const u8, args: anytype) void {
        w.out.print(w.gpa, fmt, args) catch @panic("OOM");
    }

    /// Text with what Markdown would read as syntax escaped.
    fn escaped(w: *W, str: []const u8, at_start: bool) void {
        for (str, 0..) |c, i| {
            const lead = at_start and i == 0;
            switch (c) {
                '\\', '*', '_', '`', '[', ']', '<', '~', '|' => w.byte('\\'),
                '#', '>', '-', '+' => if (lead) w.byte('\\'),
                else => {},
            }
            // A number then a dot at the start would make a list.
            if (lead and std.ascii.isDigit(c)) {
                var k = i;
                while (k < str.len and std.ascii.isDigit(str[k])) k += 1;
                if (k < str.len and (str[k] == '.' or str[k] == ')')) {
                    w.s(str[0..k]);
                    w.byte('\\');
                    return w.escaped(str[k..], false);
                }
            }
            w.byte(c);
        }
    }

    fn codeSpan(w: *W, str: []const u8) void {
        const ticks: []const u8 = if (std.mem.indexOfScalar(u8, str, '`') != null) "``" else "`";
        const pad = str.len > 0 and (str[0] == '`' or str[str.len - 1] == '`');
        w.s(ticks);
        if (pad) w.byte(' ');
        w.s(str);
        if (pad) w.byte(' ');
        w.s(ticks);
    }
};

/// The emphasis marks Markdown writes, outermost first.
const Em = enum { link, bold, italic, strike, underline };

fn hasEm(m: Marks, e: Em) bool {
    return switch (e) {
        .link => m.link != 0,
        .bold => m.bold,
        .italic => m.italic,
        .strike => m.strike,
        .underline => m.underline,
    };
}

fn open(w: *W, e: Em) void {
    w.s(switch (e) {
        .link => "[",
        .bold => "**",
        .italic => "*",
        .strike => "~~",
        .underline => "<u>",
    });
}

fn close(w: *W, d: *const Doc, e: Em, link: u32) void {
    switch (e) {
        .link => {
            w.s("](");
            for (d.url(link)) |c| {
                if (c == ')' or c == '(' or c == ' ' or c == '\\') w.byte('\\');
                w.byte(c);
            }
            w.byte(')');
        },
        .bold => w.s("**"),
        .italic => w.s("*"),
        .strike => w.s("~~"),
        .underline => w.s("</u>"),
    }
}

/// A block's runs, their marks as delimiters around them. Spaces at a
/// run's edges stay outside its emphasis, which can't open or close
/// next to them.
fn inlines(w: *W, d: *const Doc, b: *const Block) void {
    var stack: [5]Em = undefined;
    var depth: usize = 0;
    var link: u32 = 0;
    var pos: usize = 0;
    var first = true;
    for (b.runs.items) |r| {
        const all = b.text.items[pos .. pos + r.len];
        pos += r.len;
        const lead = all.len - std.mem.trimStart(u8, all, " \t").len;
        const body = std.mem.trim(u8, all, " \t");
        const trail = all.len - lead - body.len;
        var pieces = [3]struct { str: []const u8, m: Marks }{
            .{ .str = all[0..lead], .m = r.marks },
            .{ .str = body, .m = r.marks },
            .{ .str = all[lead + body.len ..][0..trail], .m = r.marks },
        };
        for (&pieces, 0..) |*pc, k| if (k != 1 or body.len == 0) {
            pc.m.bold = false;
            pc.m.italic = false;
            pc.m.strike = false;
            pc.m.underline = false;
        };
        for (pieces) |pc| {
            if (pc.str.len == 0) continue;
            const m = pc.m;
            // Close what this piece doesn't have, and what was opened after it.
            var keep: usize = 0;
            while (keep < depth and hasEm(m, stack[keep]) and !(stack[keep] == .link and m.link != link)) keep += 1;
            while (depth > keep) {
                depth -= 1;
                close(w, d, stack[depth], link);
            }
            for (std.enums.values(Em)) |e| {
                if (!hasEm(m, e)) continue;
                if (std.mem.indexOfScalar(Em, stack[0..depth], e) != null) continue;
                open(w, e);
                stack[depth] = e;
                depth += 1;
                if (e == .link) link = m.link;
            }
            if (m.code) w.codeSpan(pc.str) else w.escaped(pc.str, first and depth == 0);
            first = false;
        }
    }
    while (depth > 0) {
        depth -= 1;
        close(w, d, stack[depth], link);
    }
}

/// `d` as Markdown, in memory of `gpa`.
pub fn write(gpa: std.mem.Allocator, d: *const Doc) []u8 {
    var w: W = .{ .gpa = gpa };
    var numbers: [model.max_indent + 1]u32 = @splat(0);
    var prev: ?model.BlockStyle = null;
    var level: u8 = 0;
    for (d.blocks.items) |*b| {
        const st = b.style;
        const k = st.kind;
        // Markdown has no empty paragraphs.
        if (b.len() == 0 and (k == .paragraph or k.isHeading() or k == .quote)) continue;
        if (prev) |pv| {
            const pk = pv.kind;
            if (pk == .code and k != .code) w.s("\n```");
            if (pk == .code and k == .code) {
                w.byte('\n');
            } else if (pk.isList() and k.isList()) {
                w.byte('\n');
            } else if (pk == .quote and k == .quote) {
                w.s("\n>\n");
            } else w.s("\n\n");
        }
        if (!k.isList()) {
            numbers = @splat(0);
            level = 0;
        }
        switch (k) {
            .paragraph => {},
            .heading1 => w.s("# "),
            .heading2 => w.s("## "),
            .heading3 => w.s("### "),
            .quote => w.s("> "),
            .code => if (prev == null or prev.?.kind != .code) w.s("```\n"),
            .bullet, .numbered, .task => {
                // A level at most one deeper than the item before.
                const was_list = prev != null and prev.?.kind.isList();
                const lv: u8 = if (was_list) @min(st.indent, level + 1) else 0;
                if (!was_list) numbers = @splat(0);
                for (numbers[lv + 1 ..]) |*n| n.* = 0;
                level = lv;
                for (0..lv) |_| w.s("    ");
                if (k == .numbered) {
                    numbers[lv] += 1;
                    w.print("{d}. ", .{numbers[lv]});
                } else {
                    numbers[lv] = 0;
                    w.s(if (k == .task) (if (st.checked) "- [x] " else "- [ ] ") else "- ");
                }
            },
        }
        if (k == .code) w.s(b.str()) else inlines(&w, d, b);
        prev = st;
    }
    if (prev != null and prev.?.kind == .code) w.s("\n```");
    if (w.out.items.len > 0) w.byte('\n');
    return w.out.toOwnedSlice(gpa) catch @panic("OOM");
}

const testing = std.testing;
const md_in = @import("markdown_in.zig");

test "Markdown out reads back the same" {
    const gpa = testing.allocator;
    const src =
        \\# Notes
        \\
        \\Some **bold** and *italic*, ~~struck~~, `code`, [links](https://ziglang.org) and <u>underlines</u>.
        \\
        \\- one
        \\    - two
        \\        1. three
        \\- [ ] todo
        \\- [x] done
        \\
        \\> quoted
        \\>
        \\> twice
        \\
        \\```
        \\const x = 1;
        \\```
        \\
        \\1\. not a list, \*not italic\*
        \\
    ;
    var d = md_in.parse(gpa, src);
    defer d.deinit();
    const out = write(gpa, &d);
    defer gpa.free(out);
    try testing.expectEqualStrings(src, out);
}
