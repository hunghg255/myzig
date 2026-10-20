//! Context menus, menu buttons and menus of any button through the Tester.
const std = @import("std");
const ui = @import("ui.zig");
const base = @import("overlay_base.zig");
const menu = @import("menu.zig");
const testing = std.testing;
const S = ui.Shortcut;

const Notes = struct {
    ctx: menu.Menu = .{},
    sort: menu.Menu = .{},
    more: menu.Menu = .{},
    renamed: u32 = 0,
    deleted: u32 = 0,
    pinned: bool = false,
    locked: bool = true,
    moved_to: ?usize = null,
    sort_by: usize = 0,
    under: u32 = 0,
    more_clicked: u32 = 0,

    const folders = [_][]const u8{ "Inbox", "Archive", "Trash" };
    const sorts = [_][]const u8{ "Name", "Date", "Size" };

    fn view(s: *Notes, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        ui.row(c, .{ .gap = 8 });
        if (menu.menuButton(c, "Sort by", &s.sort, .{})) |m| {
            defer m.end();
            for (sorts, 0..) |by, i| if (m.item(by, .{ .checked = s.sort_by == i })) {
                s.sort_by = i;
            };
        }
        const more = ui.button(c, "More", .{});
        if (more.clicked) s.more_clicked += 1;
        if (menu.buttonMenu(c, &s.more, more)) |m| {
            defer m.end();
            _ = m.item("Duplicate", .{});
        }
        ui.end(c);
        const row = ui.pressable(c, .{ .width = .fill, .padding = .all(10), .background = c.theme.surface }, null);
        ui.text(c, "A note", .{});
        ui.end(c);
        if (menu.contextMenu(c, &s.ctx, row)) |m| {
            defer m.end();
            if (m.item("Rename", .{ .shortcut = "F2" })) s.renamed += 1;
            if (m.item("Pinned", .{ .checked = s.pinned })) s.pinned = !s.pinned;
            if (m.submenu("Move to")) |sub| {
                defer sub.end();
                for (folders, 0..) |f, i| if (sub.item(f, .{})) {
                    s.moved_to = i;
                };
            }
            m.separator();
            if (m.item("Delete", .{ .disabled = s.locked })) s.deleted += 1;
        }
        if (ui.button(c, "Under", .{}).clicked) s.under += 1;
    }
};

fn open(t: *ui.Tester, s: *Notes, x: f32, y: f32) void {
    // As a right click would (until input has the right button).
    s.ctx.openAt(.{ .x = x, .y = y });
    t.frame();
}

test "a context menu opens at the pointer; a click chooses an item and closes it" {
    var s: Notes = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Notes.view), .{});
    defer t.deinit();
    const note = t.findText("A note").?;
    open(&t, &s, note.x + 10, note.y + 4);
    try testing.expect(t.hasText("Rename"));
    try testing.expect(t.hasText("F2"));
    const rename = t.findText("Rename").?;
    try testing.expect(rename.y >= note.y + 4 and rename.y < note.y + 30);
    try testing.expect(rename.x >= note.x + 10);
    try t.clickText("Rename");
    try testing.expectEqual(@as(u32, 1), s.renamed);
    try testing.expect(!s.ctx.isOpen());
    t.frame();
    try testing.expect(!t.hasText("Rename"));
    // A checked item toggles.
    open(&t, &s, note.x + 10, note.y + 4);
    try t.clickText("Pinned");
    try testing.expect(s.pinned);
}

test "a disabled item cannot be chosen, and separators take no clicks" {
    var s: Notes = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Notes.view), .{});
    defer t.deinit();
    open(&t, &s, 30, 30);
    try t.clickText("Delete");
    try testing.expectEqual(@as(u32, 0), s.deleted);
    try testing.expect(s.ctx.isOpen());
    s.locked = false;
    t.frame();
    try t.clickText("Delete");
    try testing.expectEqual(@as(u32, 1), s.deleted);
}

test "a press outside an open menu only closes it" {
    var s: Notes = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Notes.view), .{});
    defer t.deinit();
    open(&t, &s, 300, 20);
    try t.clickText("Under");
    try testing.expect(!s.ctx.isOpen());
    try testing.expectEqual(@as(u32, 0), s.under);
    try t.clickText("Under");
    try testing.expectEqual(@as(u32, 1), s.under);
}

test "the keyboard moves among items, skipping disabled ones, and Enter chooses" {
    var s: Notes = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Notes.view), .{});
    defer t.deinit();
    open(&t, &s, 30, 30);
    try testing.expect(t.shortcut(.{ .key = S.down }));
    try testing.expectEqual(@as(i32, 0), s.ctx.highlight[0]);
    try testing.expect(t.shortcut(.{ .key = S.down }));
    try testing.expectEqual(@as(i32, 1), s.ctx.highlight[0]);
    // Up from the first wraps to the last enabled: "Move to" (Delete is disabled).
    try testing.expect(t.shortcut(.{ .key = S.up }));
    try testing.expect(t.shortcut(.{ .key = S.up }));
    try testing.expectEqual(@as(i32, 2), s.ctx.highlight[0]);
    try testing.expect(t.shortcut(.{ .key = S.down }));
    try testing.expectEqual(@as(i32, 0), s.ctx.highlight[0]);
    t.key(.enter);
    try testing.expectEqual(@as(u32, 1), s.renamed);
    try testing.expect(!s.ctx.isOpen());
}

test "submenus open with Right or the pointer, close with Left or Escape" {
    var s: Notes = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Notes.view), .{});
    defer t.deinit();
    open(&t, &s, 30, 30);
    t.key(.end);
    try testing.expectEqual(@as(i32, 2), s.ctx.highlight[0]);
    try testing.expect(!t.hasText("Archive"));
    try testing.expect(t.shortcut(.{ .key = S.right }));
    t.frame();
    try testing.expect(t.hasText("Archive"));
    try testing.expectEqual(@as(i32, 0), s.ctx.highlight[1]);
    // The submenu is to the right of its item.
    const move = t.findText("Move to").?;
    const inbox = t.findText("Inbox").?;
    try testing.expect(inbox.x > move.x + move.w);
    try testing.expect(t.shortcut(.{ .key = S.left }));
    t.frame();
    try testing.expect(!t.hasText("Archive"));
    try testing.expect(s.ctx.isOpen());
    try testing.expect(t.shortcut(.{ .key = S.right }));
    try testing.expect(t.shortcut(.{ .key = S.escape }));
    t.frame();
    try testing.expect(!t.hasText("Archive"));
    try testing.expect(s.ctx.isOpen());
    try testing.expect(t.shortcut(.{ .key = S.escape }));
    try testing.expect(!s.ctx.isOpen());

    // By the pointer: resting on "Move to" opens it; a click in it chooses.
    open(&t, &s, 30, 30);
    const mv = t.findText("Move to").?;
    t.moveTo(mv.x + 2, mv.y + 2);
    t.frame();
    try testing.expect(t.hasText("Archive"));
    try t.clickText("Archive");
    try testing.expectEqual(@as(?usize, 1), s.moved_to);
    try testing.expect(!s.ctx.isOpen());
    // Onto another item: the submenu closes.
    open(&t, &s, 30, 30);
    t.moveTo(mv.x + 2, mv.y + 2);
    t.frame();
    const ren = t.findText("Rename").?;
    t.moveTo(ren.x + 2, ren.y + 2);
    t.frame();
    try testing.expect(!t.hasText("Archive"));
}

test "a menu near the window's edges opens to the left of and above the pointer" {
    var s: Notes = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Notes.view), .{ .width = 480, .height = 360 });
    defer t.deinit();
    open(&t, &s, 470, 350);
    const rename = t.findText("Rename").?;
    const delete = t.findText("Delete").?;
    try testing.expect(rename.x < 470 - 100);
    try testing.expect(delete.y + delete.h < 350);
    // Its submenu flips to the left where there is no room on the right.
    try testing.expect(t.shortcut(.{ .key = S.up }));
    try testing.expect(t.shortcut(.{ .key = S.right }));
    t.frame();
    const move = t.findText("Move to").?;
    const inbox = t.findText("Inbox").?;
    try testing.expect(inbox.x + inbox.w < move.x);
    try testing.expect(inbox.x >= base.window_margin);
}

test "a menu button opens its menu below it as the pointer goes down" {
    var s: Notes = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Notes.view), .{});
    defer t.deinit();
    const b = t.findText("Sort by").?;
    t.moveTo(b.x + 2, b.y + 2);
    t.ctx.pointerDown();
    t.frame();
    try testing.expect(s.sort.isOpen());
    t.ctx.pointerUp();
    t.frame();
    try testing.expect(s.sort.isOpen());
    const date = t.findText("Date").?;
    try testing.expect(date.y > b.y + b.h);
    try t.clickText("Date");
    try testing.expectEqual(@as(usize, 1), s.sort_by);
    try testing.expect(!s.sort.isOpen());
    // A second press on the button closes it.
    t.click(b.x + 2, b.y + 2);
    try testing.expect(s.sort.isOpen());
    t.click(b.x + 2, b.y + 2);
    try testing.expect(!s.sort.isOpen());
    // With the focus (after a click), Down opens it with its first item highlighted.
    try testing.expect(t.shortcut(.{ .key = S.down }));
    t.frame();
    try testing.expect(s.sort.isOpen());
    try testing.expectEqual(@as(i32, 0), s.sort.highlight[0]);
    try testing.expect(t.shortcut(.{ .key = S.down }));
    t.key(.enter);
    try testing.expectEqual(@as(usize, 1), s.sort_by);
}

test "any button gives a menu, and its click still counts" {
    var s: Notes = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Notes.view), .{});
    defer t.deinit();
    try t.clickText("More");
    try testing.expect(s.more.isOpen());
    try testing.expect(t.hasText("Duplicate"));
    t.key(.escape);
    try testing.expect(!s.more.isOpen());
}

const has_right = @hasField(@import("input.zig").Input, "right_pressed");

test "a right click opens the context menu at the pointer, and one outside closes it" {
    if (comptime !has_right) return error.SkipZigTest;
    var s: Notes = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Notes.view), .{});
    defer t.deinit();
    if (comptime has_right) {
        const note = t.findText("A note").?;
        t.moveTo(note.x + 5, note.y + 5);
        t.ctx.input.right_pressed = true;
        t.frame();
        try testing.expect(s.ctx.isOpen());
        const rename = t.findText("Rename").?;
        try testing.expect(@abs(rename.y - (note.y + 5)) < 20);
        t.moveTo(400, 340);
        t.ctx.input.right_pressed = true;
        t.frame();
        try testing.expect(!s.ctx.isOpen());
    }
}

const Rows = struct {
    menu: menu.Menu = .{},
    /// The rows that built the menu in the last frame, and the row an item
    /// ran for.
    built: u32 = 0,
    chosen: ?usize = null,
    count: usize = 3,

    const names = [_][]const u8{ "first row", "second row", "third row" };

    fn view(s: *Rows, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(20), .gap = 4 });
        defer ui.end(c);
        s.built = 0;
        for (names[0..s.count], 0..) |n, i| {
            const row = ui.pressable(c, .{ .width = .fill, .padding = .all(6) }, null);
            ui.text(c, n, .{});
            ui.end(c);
            if (menu.contextMenu(c, &s.menu, row)) |m| {
                defer m.end();
                s.built += 1;
                if (m.item("Open Row", .{})) s.chosen = i;
            }
        }
    }
};

test "rows sharing a context menu show it for the row right-clicked alone" {
    var s: Rows = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Rows.view), .{});
    defer t.deinit();
    const second = t.findText("second row").?;
    t.rightClick(second.x + 4, second.y + 4);
    t.frame();
    try testing.expect(s.menu.isOpen());
    try testing.expectEqual(@as(u32, 1), s.built);
    try t.clickText("Open Row");
    try testing.expectEqual(@as(?usize, 1), s.chosen);
    // The row gone, the menu closes, and another row opens it.
    const third = t.findText("third row").?;
    t.rightClick(second.x + 4, second.y + 4);
    t.frame();
    try testing.expect(s.menu.isOpen());
    s.count = 1;
    t.frame();
    t.frame();
    try testing.expect(!s.menu.isOpen());
    s.count = 3;
    t.frame();
    t.rightClick(third.x + 4, third.y + 4);
    t.frame();
    try testing.expectEqual(@as(u32, 1), s.built);
    try t.clickText("Open Row");
    try testing.expectEqual(@as(?usize, 2), s.chosen);
}
