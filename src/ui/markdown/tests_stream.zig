//! A reply streaming into the view through `ui.Tester`: the boxes before
//! the end keep their ids, the boxes are as many as for the reply shown
//! whole, half-written syntax shows healed, and the done reply is exact.
const std = @import("std");
const ui = @import("../ui.zig");
const md = @import("view.zig");
const testing = std.testing;

const reply =
    \\# Plan
    \\
    \\First, a paragraph with **bold** and a [link](https://example.com).
    \\
    \\```go
    \\func main() {
    \\    fmt.Println("hi")
    \\}
    \\```
    \\
    \\| a | b |
    \\|---|---|
    \\| 1 | 2 |
    \\
    \\- one
    \\- two
    \\
    \\Last words, written slowly.
;

const Chat = struct {
    state: md.Markdown,
    len: usize = 0,
    done: bool = false,

    fn view(s: *Chat, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(12) });
        defer ui.end(c);
        _ = md.markdown(c, reply[0..s.len], .{ .state = &s.state, .streaming = !s.done });
    }
};

fn idOf(t: *ui.Tester, s: []const u8) ?u64 {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, s)) return n.id,
        else => {},
    };
    return null;
}

test "streaming keeps the boxes before the end, and as many boxes as the whole" {
    var s: Chat = .{ .state = .init(testing.allocator) };
    defer s.state.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Chat.view), .{ .width = 520, .height = 700 });
    defer t.deinit();
    var heading: ?u64 = null;
    var para: ?u64 = null;
    var cell: ?u64 = null;
    var i: usize = 0;
    while (i < reply.len) {
        i = @min(reply.len, i + 3);
        s.len = i;
        t.frame();
        // Once shown, a finished block's box keeps its id.
        if (idOf(&t, "Plan")) |id| {
            if (heading) |h| if (i > 10) try testing.expectEqual(h, id);
            if (i > 10) heading = id;
        }
        if (std.mem.indexOf(u8, reply[0..i], "```go") != null) {
            const id = idOf(&t, "First, a paragraph with bold and a link.").?;
            if (para) |p| try testing.expectEqual(p, id);
            para = id;
        }
        if (std.mem.indexOf(u8, reply[0..i], "- one") != null) {
            const id = idOf(&t, "2").?;
            if (cell) |p| try testing.expectEqual(p, id);
            cell = id;
        }
    }
    s.done = true;
    t.frame();
    try testing.expect(t.hasText("Last words, written slowly."));
    const streamed = t.ctx.nodes.items.len;
    // The same reply shown whole, fresh: as many boxes.
    var w: Chat = .{ .state = .init(testing.allocator), .len = reply.len, .done = true };
    defer w.state.deinit();
    var t2: ui.Tester = undefined;
    try t2.init(testing.allocator, .init(&w, Chat.view), .{ .width = 520, .height = 700 });
    defer t2.deinit();
    try testing.expectEqual(t2.ctx.nodes.items.len, streamed);
    try testing.expectEqual(w.state.doc.len(), s.state.doc.len());
}

test "streaming shows half-written syntax as it will be" {
    var s: Chat = .{ .state = .init(testing.allocator) };
    defer s.state.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Chat.view), .{ .width = 520, .height = 700 });
    defer t.deinit();
    // "**bo" is bold already, without its asterisks.
    s.len = std.mem.indexOf(u8, reply, "ld** and").?;
    t.frame();
    var bold = false;
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.endsWith(u8, tx.str, "with bo")) {
            for (tx.spans) |sp| if (sp.weight == .bold and std.mem.eql(u8, tx.str[sp.start..sp.end], "bo")) {
                bold = true;
            };
        },
        else => {},
    };
    try testing.expect(bold);
    // An open fence is code, without its Copy button until it closes.
    s.len = std.mem.indexOf(u8, reply, "fmt.").?;
    t.frame();
    try testing.expect(t.hasText("func main() {"));
    try testing.expect(!t.hasText("Copy"));
    s.len = std.mem.indexOf(u8, reply, "| a |").?;
    t.frame();
    try testing.expect(t.hasText("Copy"));
    // A table's header waits for its delimiter row.
    s.len = std.mem.indexOf(u8, reply, "|---").?;
    t.frame();
    try testing.expect(!t.containsText("| a |"));
    try testing.expect(!t.hasText("a"));
    s.len = std.mem.indexOf(u8, reply, "| 1 |").?;
    t.frame();
    try testing.expect(t.hasText("a"));
    try testing.expect(t.hasText("b"));
}

test "a link being written does not click until it is complete" {
    var s: Chat = .{ .state = .init(testing.allocator) };
    defer s.state.deinit();
    const Page = struct {
        chat: *Chat,
        clicked: ?[]const u8 = null,
        fn view(p: *@This(), c: *ui.Context) void {
            ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(12) });
            defer ui.end(c);
            if (md.markdown(c, reply[0..p.chat.len], .{ .state = &p.chat.state, .streaming = !p.chat.done }).link) |l| p.clicked = l;
        }
    };
    var p: Page = .{ .chat = &s };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Page.view), .{ .width = 520, .height = 700 });
    defer t.deinit();
    s.len = std.mem.indexOf(u8, reply, "ple.com").?;
    t.frame();
    var r: ?ui.Rect = null;
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.endsWith(u8, tx.str, "and a link")) {
            r = n.rect;
        },
        else => {},
    };
    const lay = t.text.layout("First, a paragraph with bold and a lin", .{ .size = 14, .leading = 1.45, .wrap = true });
    const x = r.?.x + lay.width - 2;
    const y = r.?.y + 8;
    t.click(x, y);
    try testing.expect(p.clicked == null);
    s.len = std.mem.indexOf(u8, reply, "\n\n```go").?;
    t.frame();
    t.click(x, y);
    try testing.expectEqualStrings("https://example.com", p.clicked.?);
}
