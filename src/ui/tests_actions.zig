//! Actions through `Tester`: one action chosen by its key combination, its
//! menu item or its button, disabled everywhere at once, checked in menus.
const std = @import("std");
const ui = @import("ui.zig");
const actions = @import("actions.zig");
const testing = std.testing;

const Cmd = enum { new, save, wrap };

const Editor = struct {
    acts: actions.Actions(Cmd) = .init(.{
        .new = .{ .title = "New", .shortcut = .{ .key = 'n', .cmd = true } },
        .save = .{ .title = "Save", .shortcut = .{ .key = 's', .cmd = true, .shift = true } },
        .wrap = .{ .title = "Wrap Lines", .checked = false },
    }),
    menu: ui.Menu = .{},
    dirty: bool = false,
    news: u32 = 0,
    saves: u32 = 0,
    wrap: bool = false,

    fn run(s: *Editor, cmd: Cmd) void {
        switch (cmd) {
            .new => s.news += 1,
            .save => s.saves += 1,
            .wrap => s.wrap = !s.wrap,
        }
    }

    fn view(s: *Editor, c: *ui.Context) void {
        s.acts.setEnabled(.save, s.dirty);
        s.acts.setChecked(.wrap, s.wrap);
        ui.column(c, .{ .padding = .all(10), .gap = 10 });
        defer ui.end(c);
        if (s.acts.button(c, .save, .{})) s.run(.save);
        if (ui.menu(c, &s.menu)) |m| {
            defer m.end();
            inline for (.{ Cmd.new, Cmd.save, Cmd.wrap }) |cmd| if (s.acts.menuItem(m, cmd)) s.run(cmd);
        }
        if (s.acts.shortcuts(c)) |cmd| s.run(cmd);
    }
};

test "actions: a key combination, a menu item and a button choose the same action" {
    var s: Editor = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Editor.view), .{});
    defer t.deinit();
    try testing.expect(t.shortcut(.{ .key = 'n', .cmd = true }));
    try testing.expectEqual(@as(u32, 1), s.news);
    try testing.expectEqual(@as(?Cmd, .new), s.acts.last);
    // Disabled: neither its key combination nor its button.
    try testing.expect(!t.shortcut(.{ .key = 's', .cmd = true, .shift = true }));
    try t.clickText("Save");
    try testing.expectEqual(@as(u32, 0), s.saves);
    s.dirty = true;
    t.frame();
    try testing.expect(t.shortcut(.{ .key = 's', .cmd = true, .shift = true }));
    try t.clickText("Save");
    try testing.expectEqual(@as(u32, 2), s.saves);
    // In a menu, with its key combination shown and its check mark.
    s.menu.openAt(.{ .x = 200, .y = 100 });
    t.frame();
    const shown = if (@import("keys.zig").mac) "⇧⌘S" else "Ctrl+Shift+S";
    try testing.expect(t.hasText(shown));
    try t.clickText("Wrap Lines");
    try testing.expect(s.wrap);
    try testing.expect(!s.menu.isOpen());
    try testing.expect(s.acts.get(.wrap).checked.?);
}
