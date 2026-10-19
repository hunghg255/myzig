//! The router through `Tester`: pages matched by their paths, links and
//! history buttons going through them, the keys back and forward, pages
//! sliding in and out, the page going away inert, the state of a page kept.
const std = @import("std");
const ui = @import("ui.zig");
const router = @import("router.zig");
const direction = @import("direction.zig");
const testing = std.testing;
const S = ui.Shortcut;

const Notes = struct {
    router: router.Router = .init("/notes"),
    opened: u32 = 0,
    titles: u32 = 0,
    leaving_built: u32 = 0,

    fn view(s: *Notes, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        ui.row(c, .{ .gap = 8, .padding = .all(4) });
        _ = s.router.historyButtons(c);
        ui.text(c, c.print("Title: {s}", .{s.router.title()}), .{});
        ui.end(c);
        var pages = s.router.pages(c, .{});
        while (pages.next()) |r| {
            defer r.end();
            if (r.leaving) s.leaving_built += 1;
            if (r.match("/notes")) {
                r.title("Notes");
                if (ui.button(c, "Open 42", .{}).clicked) s.router.push("/notes/42");
            } else if (r.match("/notes/{id}")) {
                r.title("Note");
                ui.text(c, c.print("Note {s}", .{r.param("id")}), .{});
                if (ui.button(c, "Edit", .{}).clicked) s.opened += 1;
            } else if (r.match("/settings/{section...}")) {
                var inner = r.nested();
                if (inner.match("/fonts")) ui.text(c, "Fonts", .{}) else ui.text(c, "General", .{});
            } else ui.text(c, "Not found", .{});
        }
        pages.end();
    }
};

test "router: pages by path, links, history buttons and keys" {
    var s: Notes = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Notes.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    t.frame();
    try testing.expect(t.hasText("Title: Notes"));
    try t.clickText("Open 42");
    try testing.expectEqualStrings("/notes/42", s.router.path());
    t.settle(1);
    try testing.expect(t.hasText("Note 42"));
    try testing.expect(t.hasText("Title: Note"));
    try testing.expect(!t.hasText("Open 42"));
    // Back with the keys, forward with the button.
    const mac = @import("builtin").os.tag == .macos;
    try testing.expect(t.shortcut(if (mac) .{ .key = '[', .cmd = true } else .{ .key = S.left, .alt = true }));
    t.settle(1);
    try testing.expect(t.hasText("Open 42"));
    try testing.expect(s.router.canGoForward());
    // The forward button: the second of the history buttons.
    const title = t.findText("Title: Notes").?;
    t.click(title.x - 8 - 14, title.y + title.h / 2);
    t.settle(1);
    try testing.expect(t.hasText("Note 42"));
    // Layouts: the rest of the path.
    s.router.push("/settings/fonts");
    t.settle(1);
    try testing.expect(t.hasText("Fonts"));
    s.router.push("/nowhere");
    t.settle(1);
    try testing.expect(t.hasText("Not found"));
}

test "router: a deeper page slides in from the end, the page going away is inert" {
    var s: Notes = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Notes.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    t.frame();
    s.router.push("/notes/7");
    t.frame();
    // Both pages are built while they change; the new one starts at the right.
    try testing.expect(s.leaving_built > 0);
    try testing.expect(t.hasText("Open 42"));
    try testing.expect(t.ctx.animating);
    t.advance(0.1);
    const note = t.findText("Note 7").?;
    _ = note;
    // Halfway: what is drawn sits between its start and its place.
    var moved = false;
    for (t.ctx.nodes.items) |n| if (n.style.transform) |m| {
        if (m.x > 0 and m.x < 400) moved = true;
    };
    try testing.expect(moved);
    // Clicks on the page going away do nothing.
    const leaving_open = t.findText("Open 42").?;
    t.click(leaving_open.x + 2, leaving_open.y + 2);
    try testing.expectEqualStrings("/notes/7", s.router.path());
    t.settle(1);
    try testing.expect(!t.hasText("Open 42"));
    try testing.expect(!t.ctx.animating);
    const built = s.leaving_built;
    t.frame();
    try testing.expectEqual(built, s.leaving_built);

    // Right to left, it comes from the left.
    s.router.back();
    t.settle(1);
    direction.set(&t.ctx, .rtl);
    s.router.push("/notes/8");
    t.frame();
    t.advance(0.05);
    var from_left = false;
    for (t.ctx.nodes.items) |n| if (n.style.transform) |m| {
        if (m.x < 0) from_left = true;
    };
    try testing.expect(from_left);
}

test "router: no transition shows the page at once" {
    var s: Notes = .{};
    s.router.transition = .none;
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Notes.view), .{});
    defer t.deinit();
    s.router.push("/notes/1");
    t.frame();
    try testing.expect(!t.hasText("Open 42"));
    try testing.expect(t.hasText("Note 1"));
}
