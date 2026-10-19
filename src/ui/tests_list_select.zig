//! Lists whose rows are chosen (`ListOptions.choice`), after mygo's
//! list_test.go and rowclick_test.go (87d400a, a6937a0): clicks and keys,
//! a selection of several with Shift, Cmd and Cmd+A, the right-click rule,
//! the choice following its items by their keys, the app's own choice at
//! the same index kept, and a double click read by a part of a row.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const row_h: f32 = 24;

const Files = struct {
    ids: []const u64,
    choice: ui.ListChoice = .{},
    /// Submitted in a pass of the frames since the test looked.
    submitted: bool = false,
    renamed: ?usize = null,
    menu_row: ?usize = null,

    fn keyOf(s: *const Files, row: usize) u64 {
        return s.ids[row];
    }

    fn view(s: *Files, c: *ui.Context) void {
        var rows = ui.list(c, .{ .count = s.ids.len, .row_height = row_h, .choice = &s.choice });
        while (rows.next()) |i| {
            const name = c.leaf(.{ .width = .{ .px = 80 }, .height = .fill }, .{ .text = .{ .str = c.print("file {d}", .{s.ids[i]}), .style = .{}, .color = rows.textColor() } }, null);
            if (ui.rowDoubleClicked(c, name)) s.renamed = i;
        }
        rows.end();
        // An app acts in the pass the key or the click comes in.
        if (rows.result.submitted) s.submitted = true;
        if (rows.result.menu_row) |r| s.menu_row = r;
    }
};

fn y(i: usize) f32 {
    return @as(f32, @floatFromInt(i)) * row_h + row_h / 2;
}

fn setup(t: *ui.Tester, s: *Files) !void {
    try t.init(testing.allocator, .init(s, Files.view), .{ .width = 300, .height = 300 });
}

fn clickWith(t: *ui.Tester, x: f32, i: usize, shift: bool, adding: bool) void {
    t.ctx.input.shift = shift;
    t.ctx.input.cmd = adding;
    t.ctx.input.ctrl = adding;
    t.click(x, y(i));
    t.ctx.input.shift = false;
    t.ctx.input.cmd = false;
    t.ctx.input.ctrl = false;
}

test "a click chooses a row, the keys move it, Enter and a double click submit it" {
    var s: Files = .{ .ids = &.{ 1, 2, 3, 4, 5 } };
    var t: ui.Tester = undefined;
    try setup(&t, &s);
    defer t.deinit();
    t.click(200, y(2));
    try testing.expectEqual(@as(?usize, 2), s.choice.selected);
    t.key(.down);
    try testing.expectEqual(@as(?usize, 3), s.choice.selected);
    t.key(.home);
    try testing.expectEqual(@as(?usize, 0), s.choice.selected);
    t.key(.enter);
    try testing.expect(s.submitted);
    s.submitted = false;
    t.doubleClick(200, y(4));
    try testing.expect(s.submitted);
    try testing.expectEqual(@as(?usize, 4), s.choice.selected);
    // Without a selection, a right-click never chooses.
    t.rightClick(200, y(1));
    try testing.expectEqual(@as(?usize, 4), s.choice.selected);
    try testing.expectEqual(@as(?usize, 1), s.menu_row);
}

test "with a selection, Shift extends, Cmd adds and takes out, Cmd+A chooses all" {
    var sel: ui.Selection = .init(testing.allocator);
    defer sel.deinit();
    var s: Files = .{ .ids = &.{ 10, 20, 30, 40, 50, 60 } };
    s.choice = .{ .selection = &sel, .key = .of(@as(*const Files, &s), Files.keyOf) };
    var t: ui.Tester = undefined;
    try setup(&t, &s);
    defer t.deinit();
    t.click(200, y(1));
    clickWith(&t, 200, 3, true, false);
    try testing.expectEqual(@as(usize, 3), sel.count());
    try testing.expect(sel.has(20) and sel.has(30) and sel.has(40));
    clickWith(&t, 200, 5, false, true);
    try testing.expect(sel.has(60) and sel.count() == 4);
    clickWith(&t, 200, 2, false, true);
    try testing.expect(!sel.has(30) and sel.count() == 3);
    // A plain click on a row chosen chooses it alone, at the release.
    t.click(200, y(1));
    try testing.expect(sel.count() == 1 and sel.has(20));
    // Shift with the arrows extends.
    t.ctx.input.shift = true;
    t.key(.down);
    t.key(.down);
    t.ctx.input.shift = false;
    try testing.expect(sel.count() == 3 and sel.has(40));
    _ = t.shortcut(.{ .key = 'a', .cmd = true });
    try testing.expectEqual(@as(usize, 6), sel.count());
}

test "a right-click on a row not chosen chooses it before its menu opens; on one chosen the choice stays" {
    var sel: ui.Selection = .init(testing.allocator);
    defer sel.deinit();
    var s: Files = .{ .ids = &.{ 1, 2, 3, 4 } };
    s.choice = .{ .selection = &sel };
    var t: ui.Tester = undefined;
    try setup(&t, &s);
    defer t.deinit();
    t.click(200, y(0));
    clickWith(&t, 200, 1, true, false);
    try testing.expectEqual(@as(usize, 2), sel.count());
    t.rightClick(200, y(1));
    try testing.expectEqual(@as(usize, 2), sel.count());
    try testing.expectEqual(@as(?usize, 1), s.menu_row);
    t.rightClick(200, y(3));
    try testing.expect(sel.count() == 1 and sel.has(3));
    try testing.expectEqual(@as(?usize, 3), s.choice.selected);
    // Keeping the choice: the menu acts on the row clicked alone.
    s.choice.menu_keeps_selection = true;
    t.rightClick(200, y(0));
    try testing.expect(sel.count() == 1 and sel.has(3));
    try testing.expectEqual(@as(?usize, 0), s.menu_row);
}

test "the choice follows its item as rows come, and the app's choice at the same index stays" {
    var sel: ui.Selection = .init(testing.allocator);
    defer sel.deinit();
    var ids = [_]u64{ 100, 200, 0, 0, 0 };
    var s: Files = .{ .ids = ids[0..2] };
    s.choice = .{ .selected = 0, .selection = &sel, .key = .of(@as(*const Files, &s), Files.keyOf) };
    sel.add(100);
    var t: ui.Tester = undefined;
    try setup(&t, &s);
    defer t.deinit();
    // A paste brings 50, which sorts first: the app chooses it, at the row
    // 100 had.
    ids = .{ 50, 100, 200, 0, 0 };
    s.ids = ids[0..3];
    sel.clear();
    sel.add(50);
    s.choice.selected = 0;
    t.frame();
    try testing.expectEqual(@as(?usize, 0), s.choice.selected);
    try testing.expect(sel.has(50) and sel.count() == 1);
    // 100, chosen, renamed 150 in its place: the app chooses it by its new
    // key, and the cursor stays.
    sel.clear();
    sel.add(100);
    s.choice.selected = 1;
    t.frame();
    ids[1] = 150;
    sel.clear();
    sel.add(150);
    t.frame();
    try testing.expectEqual(@as(?usize, 1), s.choice.selected);
    // Rows coming above a choice the app keeps move the cursor with it.
    ids = .{ 1, 2, 50, 150, 200 };
    s.ids = ids[0..5];
    t.frame();
    try testing.expectEqual(@as(?usize, 3), s.choice.selected);
}

test "a part of a row reads its double click, and the row still chooses" {
    var s: Files = .{ .ids = &.{ 1, 2, 3 } };
    var t: ui.Tester = undefined;
    try setup(&t, &s);
    defer t.deinit();
    // Over the name: it renames; past it, the row alone.
    t.doubleClick(20, y(2));
    try testing.expectEqual(@as(?usize, 2), s.renamed);
    try testing.expectEqual(@as(?usize, 2), s.choice.selected);
    s.renamed = null;
    t.doubleClick(250, y(1));
    try testing.expectEqual(@as(?usize, null), s.renamed);
    try testing.expectEqual(@as(?usize, 1), s.choice.selected);
}
