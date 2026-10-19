//! The parser's trees, healing while streaming, and appending: the same
//! result as parsing whole, the blocks before the end kept as they were,
//! and work bounded by what the end holds.
const std = @import("std");
const doc = @import("document.zig");
const html = @import("html.zig");
const inl = @import("inlines.zig");
const testing = std.testing;
const Document = doc.Document;

/// The blocks as an indented outline: kind and what describes it.
fn tree(d: *Document, out: *std.ArrayList(u8)) void {
    const gpa = testing.allocator;
    for (1..d.len()) |k| {
        const i: u32 = @intCast(k);
        const b = d.block(i).*;
        var depth: usize = 0;
        var p = b.parent;
        while (p != 0 and p != doc.none) : (p = d.block(p).parent) depth += 1;
        out.appendNTimes(gpa, ' ', depth * 2) catch unreachable;
        out.appendSlice(gpa, @tagName(b.kind)) catch unreachable;
        var buf: [64]u8 = undefined;
        const extra: []const u8 = switch (b.kind) {
            .heading => std.fmt.bufPrint(&buf, " {d}", .{b.level}) catch "",
            .list => std.fmt.bufPrint(&buf, "{s}{s}", .{ if (b.ordered) " ordered" else "", if (b.tight) " tight" else " loose" }) catch "",
            .item => if (b.task == .none) "" else std.fmt.bufPrint(&buf, " {s}", .{@tagName(b.task)}) catch "",
            .code_block => std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ if (d.language(i).len > 0) " " else "", d.language(i), if (b.open) " open" else "" }) catch "",
            .table => std.fmt.bufPrint(&buf, " {d}", .{b.columns}) catch "",
            .table_row => if (b.header) " header" else "",
            else => "",
        };
        out.appendSlice(gpa, extra) catch unreachable;
        out.append(gpa, '\n') catch unreachable;
    }
}

fn expectTree(src: []const u8, want: []const u8) !void {
    var d = Document.parse(testing.allocator, src, .{});
    defer d.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    tree(&d, &out);
    try testing.expectEqualStrings(want, out.items);
}

/// Inlines as s-expressions: (strong "b") (link "url" "text").
fn inlines(x: *const inl.Inlines, from: u32, to: u32, out: *std.ArrayList(u8)) void {
    const gpa = testing.allocator;
    var j = from;
    while (j < to) : (j = x.nodes[j].next) {
        const n = x.nodes[j];
        if (out.items.len > 0 and out.items[out.items.len - 1] != '(') out.append(gpa, ' ') catch unreachable;
        switch (n.kind) {
            .text => out.print(gpa, "\"{s}\"", .{x.text(j)}) catch unreachable,
            .softbreak, .hardbreak => out.appendSlice(gpa, @tagName(n.kind)) catch unreachable,
            .code, .html => out.print(gpa, "({s} \"{s}\")", .{ @tagName(n.kind), x.text(j) }) catch unreachable,
            else => {
                out.print(gpa, "({s}", .{@tagName(n.kind)}) catch unreachable;
                if (n.kind == .link or n.kind == .image) out.print(gpa, " <{s}>{s}", .{ x.text(j), if (n.pending) " pending" else "" }) catch unreachable;
                inlines(x, j + 1, n.next, out);
                out.append(gpa, ')') catch unreachable;
            },
        }
    }
}

fn expectInlines(d: *Document, block: u32, want: []const u8) !void {
    const x = d.inlines(block);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    inlines(x, 0, @intCast(x.nodes.len), &out);
    try testing.expectEqualStrings(want, out.items);
}

test "block trees" {
    try expectTree("# Title\n\nText\nmore\n\n- a\n- [x] b\n\n  c\n\n1. one\n\n> quote\n> > deeper\n\n```zig\ncode\n```\n\n    indented\n\n***\n\n| a | b |\n|---|:-:|\n| 1 | 2 |\n\n<div>\nhi\n</div>\n",
        \\heading 1
        \\paragraph
        \\list loose
        \\  item
        \\    paragraph
        \\  item checked
        \\    paragraph
        \\    paragraph
        \\list ordered tight
        \\  item
        \\    paragraph
        \\quote
        \\  paragraph
        \\  quote
        \\    paragraph
        \\code_block zig
        \\code_block
        \\thematic_break
        \\table 2
        \\  table_row header
        \\    table_cell
        \\    table_cell
        \\  table_row
        \\    table_cell
        \\    table_cell
        \\html_block
        \\
    );
    // A setext heading, a paragraph of only a definition, lazy continuation.
    try expectTree("Title\n===\n\n[x]: /u\n\n> a\nb\n",
        \\heading 1
        \\quote
        \\  paragraph
        \\
    );
}

test "inline trees" {
    var d = Document.parse(testing.allocator, "a *b **c** d* `e` [f](/g \"t\") ![h](i) ~~j~~ <k@l.m>\\\nwww.n.org end\n\n[ref]: /r\n\n[ref] _x_", .{});
    defer d.deinit();
    try expectInlines(&d, 1, "\"a \" (emph \"b \" (strong \"c\") \" d\") \" \" (code \"e\") \" \" (link </g> \"f\") \" \" (image <i> \"h\") \" \" (strike \"j\") \" \" (link <mailto:k@l.m> \"k@l.m\") hardbreak (link <http://www.n.org> \"www.n.org\") \" end\"");
    try expectInlines(&d, 2, "(link </r> \"ref\") \" \" (emph \"x\")");
}

test "a definition after its use resolves it" {
    var d = Document.init(testing.allocator, .{});
    defer d.deinit();
    d.set("see [docs]\n\n");
    try expectInlines(&d, 1, "\"see \" \"[\" \"docs\" \"]\"");
    d.append("[docs]: https://ziglang.org\n");
    try expectInlines(&d, 1, "\"see \" (link <https://ziglang.org> \"docs\")");
}

test "streaming heals the end, and reads it exactly once done" {
    var d = Document.init(testing.allocator, .{});
    defer d.deinit();
    d.setStreaming(true);
    d.set("Some **bol");
    try expectInlines(&d, 1, "\"Some \" (strong \"bol\")");
    d.set("Some **bold** and `co");
    try expectInlines(&d, 1, "\"Some \" (strong \"bold\") \" and \" (code \"co\")");
    d.set("Read [the docs](https://ex");
    try expectInlines(&d, 1, "\"Read \" (link <https://ex> pending \"the docs\")");
    d.set("Read [the do");
    try expectInlines(&d, 1, "\"Read \" \"the do\"");
    d.set("Not 2*3 or ~20 and *");
    try expectInlines(&d, 1, "\"Not 2\" \"*\" \"3 or \" \"~\" \"20 and\"");
    d.setStreaming(false);
    try expectInlines(&d, 1, "\"Not 2\" \"*\" \"3 or \" \"~\" \"20 and \" \"*\"");
}

test "streaming holds back lines that could still change what they follow" {
    var d = Document.init(testing.allocator, .{});
    defer d.deinit();
    d.setStreaming(true);
    // A line of a few markers might make the paragraph a heading.
    d.set("Title\n-");
    try testing.expectEqual(@as(u32, 2), d.len());
    try testing.expectEqual(doc.Kind.paragraph, d.block(1).kind);
    try expectInlines(&d, 1, "\"Title\"");
    d.append("--\n");
    try testing.expectEqual(doc.Kind.heading, d.block(1).kind);
    // A table's header waits for its delimiter row.
    d.set("Intro\n\n| a | b |\n");
    try testing.expectEqual(@as(u32, 2), d.len());
    d.append("|---|---|\n| 1 | 2 |");
    try testing.expectEqual(doc.Kind.table, d.block(2).kind);
    // An open fence is code, open.
    d.set("```zig\nconst x");
    try testing.expectEqual(doc.Kind.code_block, d.block(1).kind);
    try testing.expect(d.block(1).open);
}

const reply =
    \\## Comparing the options
    \\
    \\Here is a minimal **LRU cache**, with [the docs](https://ziglang.org/documentation/master/) for reference.
    \\
    \\```zig
    \\const Lru = struct {
    \\    cap: usize,
    \\    items: std.StringHashMap(*Node),
    \\};
    \\```
    \\
    \\| Strategy | Latency | Staleness |
    \\|---|--:|:-:|
    \\| No cache | ~41 ms | none |
    \\| Cache-aside | ~0.2 ms | medium |
    \\
    \\> **Tip:** start with *cache-aside*.
    \\
    \\1. `container/list` keeps the order of use.
    \\2. The mutex makes `get` a writer too.
    \\   - nested, with ~~strikes~~
    \\
    \\- [x] Measure
    \\- [ ] Multiply
    \\
    \\That's all.
    \\
;

test "appended in chunks, a reply parses as it does whole, after every chunk" {
    const gpa = testing.allocator;
    for ([_]usize{ 1, 2, 7, 16 }) |step| {
        var d = Document.init(gpa, .{});
        defer d.deinit();
        var i: usize = 0;
        while (i < reply.len) {
            const e = @min(reply.len, i + step);
            d.append(reply[i..e]);
            i = e;
            const want = html.toHtml(gpa, reply[0..e], .{});
            defer gpa.free(want);
            var got: std.ArrayList(u8) = .empty;
            defer got.deinit(gpa);
            html.render(&d, gpa, &got);
            try testing.expectEqualStrings(want, got.items);
        }
    }
}

test "appending keeps the blocks before the end, and parses only the end" {
    const gpa = testing.allocator;
    var d = Document.init(gpa, .{});
    defer d.deinit();
    d.setStreaming(true);
    // The reply, then a last line continuing its last paragraph, token by
    // token. (A list stays open, and is parsed again, until a complete
    // line after it closes it.)
    const text = reply ++ "And a last line, streamed a byte at a time, to its very end.";
    const cut = reply.len;
    d.set(text[0..cut]);
    const n = d.len();
    var kept: std.ArrayList(doc.Block) = .empty;
    defer kept.deinit(gpa);
    var caches: std.ArrayList(?*doc.Cache) = .empty;
    defer caches.deinit(gpa);
    for (1..n - 1) |k| {
        const b = d.block(@intCast(k));
        if (b.kind == .paragraph or b.kind == .heading or b.kind == .table_cell) _ = d.inlines(@intCast(k));
        kept.append(gpa, b.*) catch unreachable;
        caches.append(gpa, b.cache) catch unreachable;
    }
    const parses = d.stats.inline_parses;
    const bytes = d.stats.parsed_bytes;
    var i = cut;
    while (i < text.len) : (i += 1) {
        d.append(text[i .. i + 1]);
        // The blocks before it: the same, with the same inlines.
        for (kept.items, caches.items, 1..) |b, cache, k| {
            const now = d.block(@intCast(k));
            try testing.expectEqual(b.kind, now.kind);
            try testing.expectEqual(b.start, now.start);
            try testing.expectEqual(b.next, now.next);
            try testing.expectEqual(cache, now.cache);
        }
        try testing.expectEqual(n, d.len());
        _ = d.inlines(d.len() - 1);
    }
    // Each token parsed the last paragraph alone, and only its inlines.
    const appended = text.len - cut;
    const paragraph = text.len - std.mem.lastIndexOf(u8, text, "That's").?;
    try testing.expect(d.stats.parsed_bytes - bytes <= appended * paragraph);
    try testing.expect(d.stats.inline_parses - parses <= appended);
    // Parsed whole, the same blocks.
    var whole = Document.parse(gpa, text, .{});
    defer whole.deinit();
    try testing.expectEqual(whole.len(), d.len());
}
