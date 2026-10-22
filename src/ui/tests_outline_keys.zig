//! An outline whose rows hold boxes of the app's that take presses, and
//! keys without a modifier (Delete) asked for as shortcuts, through `Tester`.
const std = @import("std");
const ui = @import("ui.zig");
const outline = @import("outline.zig");
const testing = std.testing;

const Files = struct {
    state: outline.OutlineState([]const u8) = .{},
    query: ui.TextBuffer = .{},
    deleted: u32 = 0,
    /// Backspaces a handler before the field took from it.
    stolen: u32 = 0,

    pub fn children(_: *Files, _: []const u8) []const []const u8 {
        return &.{};
    }

    fn view(s: *Files, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        if (c.shortcut(.{ .key = ui.Shortcut.backspace })) s.stolen += 1;
        _ = ui.textField(c, &s.query, .{});
        var rows = outline.outline([]const u8, c, &s.state, &.{ "one.txt", "two.txt" }, s, .{ .height = .{ .px = 200 } });
        while (rows.next()) |r| {
            // A cell of the app's own, as a file tree's: it takes the press.
            const cell = ui.div(c).row().grow();
            ui.text(c, r.item, .{});
            const ia = cell.interaction();
            cell.end();
            if (ia.clicked) s.state.selected = r.item;
        }
        if (rows.end().focused and c.shortcut(.{ .key = ui.Shortcut.delete })) s.deleted += 1;
    }
};

test "outline: a press on a box of the app's in a row focuses the tree, and Delete reaches it" {
    var s: Files = .{};
    defer s.state.deinit(testing.allocator);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Files.view), .{});
    defer t.deinit();
    try t.clickText("two.txt");
    try testing.expectEqualStrings("two.txt", s.state.selected.?);
    // Delete alone comes as a key, as every backend sends it.
    t.key(.delete);
    try testing.expectEqual(@as(u32, 1), s.deleted);
}

test "shortcuts: a key without a modifier stays a focused text field's" {
    var s: Files = .{};
    defer s.state.deinit(testing.allocator);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Files.view), .{});
    defer t.deinit();
    try t.clickText("one.txt");
    t.key(.backspace);
    try testing.expectEqual(@as(u32, 1), s.stolen);
    // In the field, Backspace edits its text: the handler above it never sees it.
    t.click(30, 32);
    try testing.expect(t.ctx.focused_text != null);
    t.typeText("ab");
    t.key(.backspace);
    try testing.expectEqualStrings("a", s.query.text());
    try testing.expectEqual(@as(u32, 1), s.stolen);
}
