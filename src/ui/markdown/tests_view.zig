//! The Markdown view through `ui.Tester`: text shown, links clicked, code
//! blocks, tables laid out, selection and copy.
const std = @import("std");
const ui = @import("../ui.zig");
const md = @import("view.zig");
const testing = std.testing;

const Page = struct {
    src: []const u8,
    state: md.Markdown,
    opts: md.Options = .{},
    last: md.Result = .{},
    clicked: ?[]const u8 = null,
    copied: ?[]const u8 = null,

    fn view(p: *Page, c: *ui.Context) void {
        ui.scroll(c, .{ .width = .fill, .height = .fill, .padding = .all(16) });
        defer ui.end(c);
        var o = p.opts;
        o.state = &p.state;
        p.last = md.markdown(c, p.src, o);
        if (p.last.link) |l| p.clicked = l;
        if (p.last.copied) |s| p.copied = s;
    }
};

fn page(src: []const u8) Page {
    return .{ .src = src, .state = .init(testing.allocator) };
}

/// The rectangle of the text box containing `s`.
fn boxWith(t: *ui.Tester, s: []const u8) ?ui.Rect {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.indexOf(u8, tx.str, s) != null) return n.rect,
        else => {},
    };
    return null;
}

test "markdown shows headings, paragraphs, lists and quotes" {
    var p = page("# Title\n\nSome *emphasis* and **strong** text.\n\n- one\n- two\n  1. nested\n\n> quoted\n\n---\n\nend");
    defer p.state.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Page.view), .{ .width = 480, .height = 480 });
    defer t.deinit();
    try testing.expect(t.hasText("Title"));
    try testing.expect(t.hasText("Some emphasis and strong text."));
    try testing.expect(t.hasText("one"));
    try testing.expect(t.hasText("nested"));
    try testing.expect(t.hasText("•"));
    try testing.expect(t.hasText("1."));
    try testing.expect(t.hasText("quoted"));
    // In reading order, top to bottom.
    const title = t.findText("Title").?;
    const para = t.findText("Some emphasis and strong text.").?;
    const end = t.findText("end").?;
    try testing.expect(title.y < para.y and para.y < end.y);
    // The heading is larger than body text.
    try testing.expect(title.h > para.h);
    // The nested item is indented further than its parent.
    try testing.expect(t.findText("nested").?.x > t.findText("one").?.x);
}

test "markdown reports link clicks, not other clicks" {
    var p = page("Read [the docs](https://ziglang.org/doc) first, or <https://example.com>.");
    defer p.state.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Page.view), .{ .width = 600, .height = 200 });
    defer t.deinit();
    const r = boxWith(&t, "the docs").?;
    // "Read " is about five characters in: click the start of the text.
    t.click(r.x + 2, r.y + r.h / 2);
    try testing.expect(p.clicked == null);
    // The middle of "the docs".
    const lay = t.text.layout("Read the d", .{ .size = 14, .leading = 1.45, .wrap = true });
    t.click(r.x + lay.width, r.y + r.h / 2);
    try testing.expectEqualStrings("https://ziglang.org/doc", p.clicked.?);
    p.clicked = null;
    const before = t.text.layout("Read the docs first, or https://exa", .{ .size = 14, .leading = 1.45, .wrap = true });
    t.click(r.x + before.width, r.y + r.h / 2);
    try testing.expectEqualStrings("https://example.com", p.clicked.?);
    // Hovering a link reports it.
    t.moveTo(r.x + lay.width, r.y + r.h / 2);
    try testing.expectEqualStrings("https://ziglang.org/doc", p.last.hovered_link.?);
}

test "markdown code blocks: mono, highlighted, copied" {
    var p = page("Code:\n\n```zig\nconst x = 42;\n// done\n```\n");
    defer p.state.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Page.view), .{ .width = 480, .height = 300 });
    defer t.deinit();
    try testing.expect(t.hasText("zig"));
    var found = false;
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, "const x = 42;")) {
            found = true;
            try testing.expect(tx.style.mono);
            // const and 42 are colored.
            try testing.expect(tx.spans.len >= 2);
            try testing.expectEqual(@as(u32, 0), tx.spans[0].start);
            try testing.expectEqual(@as(u32, 5), tx.spans[0].end);
        },
        else => {},
    };
    try testing.expect(found);
    // A line of its own, indentation kept.
    try testing.expect(t.hasText("// done"));
    try t.clickText("Copy");
    try testing.expectEqualStrings("const x = 42;\n// done", p.copied.?);
    try testing.expectEqualStrings("const x = 42;\n// done", t.clipboard.items);
}

test "markdown tables lay out in columns" {
    var p = page("| Name | Size |\n|:-----|-----:|\n| a | 1 |\n| longer name | 22 |\n");
    defer p.state.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Page.view), .{ .width = 480, .height = 300 });
    defer t.deinit();
    const name = t.findText("Name").?;
    const size = t.findText("Size").?;
    const a = t.findText("a").?;
    const longer = t.findText("longer name").?;
    const one = t.findText("1").?;
    const two = t.findText("22").?;
    // Columns: cells of a column share their x, rows their y.
    try testing.expectEqual(name.x, a.x);
    try testing.expectEqual(a.x, longer.x);
    try testing.expectEqual(name.y, size.y);
    try testing.expectEqual(a.y, one.y);
    try testing.expect(longer.y > a.y);
    try testing.expect(size.x > longer.x + longer.w);
    // The second column is aligned right: its cells end together.
    try testing.expectApproxEqAbs(size.x + size.w, two.x + two.w, 0.5);
    try testing.expectApproxEqAbs(one.x + one.w, two.x + two.w, 0.5);
}

test "markdown text selects and copies across blocks" {
    var p = page("First paragraph.\n\nSecond paragraph.");
    defer p.state.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Page.view), .{ .width = 480, .height = 300 });
    defer t.deinit();
    const a = t.findText("First paragraph.").?;
    const b = t.findText("Second paragraph.").?;
    t.drag(a.x + 1, a.y + a.h / 2, b.x + b.w - 1, b.y + b.h / 2);
    try testing.expect(std.mem.indexOf(u8, t.ctx.selection.text.items, "First paragraph.") != null);
    try testing.expect(std.mem.indexOf(u8, t.ctx.selection.text.items, "Second") != null);
}

test "markdown task lists and images" {
    var p = page("- [x] done\n- [ ] todo\n\n![a cat](cat.png)");
    defer p.state.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Page.view), .{ .width = 480, .height = 300 });
    defer t.deinit();
    try testing.expect(t.hasText("done"));
    try testing.expect(t.hasText("todo"));
    try testing.expect(t.hasText("✓"));
    try testing.expect(!t.hasText("[x] done"));
    // Images show their description.
    try testing.expect(t.hasText("a cat"));
}

test "markdown without a state parses each frame" {
    const S = struct {
        fn view(_: *u8, c: *ui.Context) void {
            _ = md.markdown(c, "Hello **world**", .{});
        }
    };
    var x: u8 = 0;
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&x, S.view), .{});
    defer t.deinit();
    try testing.expect(t.hasText("Hello world"));
}
