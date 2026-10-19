//! A document as HTML, as cmark writes it: what the CommonMark spec's
//! examples are checked against, and a way to copy Markdown as HTML.
const std = @import("std");
const doc = @import("document.zig");
const inl = @import("inlines.zig");
const Document = doc.Document;

const W = struct {
    d: *Document,
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),

    fn put(w: *W, s: []const u8) void {
        w.out.appendSlice(w.gpa, s) catch @panic("OOM");
    }

    fn cr(w: *W) void {
        if (w.out.items.len > 0 and w.out.items[w.out.items.len - 1] != '\n') w.put("\n");
    }

    fn esc(w: *W, s: []const u8) void {
        for (s) |c| switch (c) {
            '&' => w.put("&amp;"),
            '<' => w.put("&lt;"),
            '>' => w.put("&gt;"),
            '"' => w.put("&quot;"),
            else => w.out.append(w.gpa, c) catch @panic("OOM"),
        };
    }

    fn href(w: *W, s: []const u8) void {
        const hex = "0123456789ABCDEF";
        for (s) |c| {
            if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_.!~*();/?:@=+$,%#", c) != null) {
                w.out.append(w.gpa, c) catch @panic("OOM");
            } else if (c == '&') {
                w.put("&amp;");
            } else if (c == '\'') {
                w.put("&#x27;");
            } else {
                w.put(&.{ '%', hex[c >> 4], hex[c & 15] });
            }
        }
    }

    fn block(w: *W, i: u32, tight: bool) void {
        const d = w.d;
        const b = d.block(i).*;
        switch (b.kind) {
            .root => w.children(i, false),
            .paragraph => {
                if (!tight) {
                    w.cr();
                    w.put("<p>");
                }
                w.inlines(i);
                if (!tight) w.put("</p>\n");
            },
            .heading => {
                w.cr();
                w.put(&.{ '<', 'h', '0' + b.level, '>' });
                w.inlines(i);
                w.put(&.{ '<', '/', 'h', '0' + b.level, '>', '\n' });
            },
            .thematic_break => {
                w.cr();
                w.put("<hr />\n");
            },
            .code_block => {
                w.cr();
                w.put("<pre><code");
                const lang = d.language(i);
                if (lang.len > 0) {
                    w.put(" class=\"language-");
                    w.esc(lang);
                    w.put("\"");
                }
                w.put(">");
                w.lines(i, true);
                w.put("</code></pre>\n");
            },
            .html_block => {
                w.cr();
                w.lines(i, false);
                w.cr();
            },
            .quote => {
                w.cr();
                w.put("<blockquote>\n");
                w.children(i, false);
                w.cr();
                w.put("</blockquote>\n");
            },
            .list => {
                w.cr();
                if (!b.ordered) {
                    w.put("<ul>\n");
                } else if (b.number == 1) {
                    w.put("<ol>\n");
                } else {
                    var nb: [32]u8 = undefined;
                    w.put(std.fmt.bufPrint(&nb, "<ol start=\"{d}\">\n", .{b.number}) catch "<ol>\n");
                }
                w.children(i, b.tight);
                w.put(if (b.ordered) "</ol>\n" else "</ul>\n");
            },
            .item => {
                w.cr();
                w.put("<li>");
                switch (b.task) {
                    .none => {},
                    .unchecked => w.put("<input disabled=\"\" type=\"checkbox\"> "),
                    .checked => w.put("<input checked=\"\" disabled=\"\" type=\"checkbox\"> "),
                }
                w.children(i, tight);
                w.put("</li>\n");
            },
            .table => w.table(i),
            .table_row, .table_cell => {},
        }
    }

    fn children(w: *W, i: u32, tight: bool) void {
        var it = w.d.children(i);
        while (it.next()) |j| w.block(j, tight);
    }

    fn lines(w: *W, i: u32, escape: bool) void {
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(w.gpa);
        w.d.contentInto(i, &content, w.gpa) catch @panic("OOM");
        if (escape) w.esc(content.items) else w.put(content.items);
        if (content.items.len > 0 or w.d.block(i).seg_b > w.d.block(i).seg_a) w.put("\n");
    }

    fn table(w: *W, i: u32) void {
        const aligns = w.d.alignments(i);
        w.cr();
        w.put("<table>\n");
        var rows = w.d.children(i);
        var body = false;
        while (rows.next()) |r| {
            const header = w.d.block(r).header;
            if (header) w.put("<thead>\n") else if (!body) {
                w.put("<tbody>\n");
                body = true;
            }
            w.put("<tr>\n");
            var cells = w.d.children(r);
            var k: usize = 0;
            while (cells.next()) |c| : (k += 1) {
                const tag = if (header) "th" else "td";
                w.put("<");
                w.put(tag);
                switch (if (k < aligns.len) aligns[k] else .none) {
                    .none => {},
                    .left => w.put(" align=\"left\""),
                    .center => w.put(" align=\"center\""),
                    .right => w.put(" align=\"right\""),
                }
                w.put(">");
                w.inlines(c);
                w.put("</");
                w.put(tag);
                w.put(">\n");
            }
            w.put("</tr>\n");
            if (header) w.put("</thead>\n");
        }
        if (body) w.put("</tbody>\n");
        w.put("</table>\n");
    }

    fn inlines(w: *W, i: u32) void {
        const x = w.d.inlines(i);
        w.span(x, 0, @intCast(x.nodes.len), false);
    }

    fn span(w: *W, x: *const inl.Inlines, from: u32, to: u32, plain: bool) void {
        var j = from;
        while (j < to) {
            const n = x.nodes[j];
            switch (n.kind) {
                .text => w.esc(x.text(j)),
                .softbreak => w.put("\n"),
                .hardbreak => w.put(if (plain) "\n" else "<br />\n"),
                .code => if (plain) w.esc(x.text(j)) else {
                    w.put("<code>");
                    w.esc(x.text(j));
                    w.put("</code>");
                },
                .html => if (plain) w.esc(x.text(j)) else w.put(x.text(j)),
                .emph, .strong, .strike => {
                    const tag = switch (n.kind) {
                        .emph => "em",
                        .strong => "strong",
                        else => "del",
                    };
                    if (!plain) {
                        w.put("<");
                        w.put(tag);
                        w.put(">");
                    }
                    w.span(x, j + 1, n.next, plain);
                    if (!plain) {
                        w.put("</");
                        w.put(tag);
                        w.put(">");
                    }
                },
                .link => if (plain) w.span(x, j + 1, n.next, true) else {
                    w.put("<a href=\"");
                    w.href(x.text(j));
                    w.put("\"");
                    if (n.tb > n.ta) {
                        w.put(" title=\"");
                        w.esc(x.title(j));
                        w.put("\"");
                    }
                    w.put(">");
                    w.span(x, j + 1, n.next, false);
                    w.put("</a>");
                },
                .image => if (plain) w.span(x, j + 1, n.next, true) else {
                    w.put("<img src=\"");
                    w.href(x.text(j));
                    w.put("\" alt=\"");
                    w.span(x, j + 1, n.next, true);
                    w.put("\"");
                    if (n.tb > n.ta) {
                        w.put(" title=\"");
                        w.esc(x.title(j));
                        w.put("\"");
                    }
                    w.put(" />");
                },
            }
            j = n.next;
        }
    }
};

/// The document as HTML, appended to `out`.
pub fn render(d: *Document, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) void {
    var w: W = .{ .d = d, .gpa = gpa, .out = out };
    w.block(0, false);
}

/// Markdown to HTML, for tests: the caller frees the result.
pub fn toHtml(gpa: std.mem.Allocator, src: []const u8, ext: doc.Extensions) []u8 {
    var d = Document.parse(gpa, src, ext);
    defer d.deinit();
    var out: std.ArrayList(u8) = .empty;
    render(&d, gpa, &out);
    return out.toOwnedSlice(gpa) catch @panic("OOM");
}
