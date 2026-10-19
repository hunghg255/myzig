//! Tables choosing a set of rows (`TableState.selection`), row headers
//! and the cell menu, after mygo's table_test.go and cellselect_test.go
//! (87d400a): Cmd-clicks add rows and take them out, a right-click
//! outside the choice chooses what it is on, a row header chooses whole
//! rows, and the cells' menu knows its cell.
const std = @import("std");
const ui = @import("ui.zig");
const table = @import("table.zig");
const testing = std.testing;

const cols: []const table.Column = &.{
    .{ .title = "#", .width = 48, .row_header = true },
    .{ .title = "Name" },
    .{ .title = "Size", .width = 90 },
};

const Sheet = struct {
    state: table.TableState = .{},
    opts: table.Options = .{},
    menu_at: ?[2]usize = null,
    items: bool = true,
    copied: ?[2]usize = null,

    fn view(s: *Sheet, c: *ui.Context) void {
        var o = s.opts;
        o.cell_menu = .{ .ctx = s, .build = build };
        var t = table.table(c, &s.state, cols, 30, o);
        while (t.next()) |row| {
            while (t.cell()) |col| ui.text(c, c.print("r{d}c{d}", .{ row, col }), .{ .color = t.textColor() });
        }
        _ = t.end();
    }

    fn build(ctx: *anyopaque, m: *ui.MenuPanel, row: usize, col: usize) void {
        const s: *Sheet = @ptrCast(@alignCast(ctx));
        s.menu_at = .{ row, col };
        if (!s.items) return;
        if (m.item("Copy", .{})) s.copied = .{ row, col };
    }
};

fn at(t: *ui.Tester, row: usize, col: usize) [2]f32 {
    var buf: [16]u8 = undefined;
    const r = t.findText(std.fmt.bufPrint(&buf, "r{d}c{d}", .{ row, col }) catch unreachable).?;
    return .{ r.x + 2, r.y + r.h / 2 };
}

fn click(t: *ui.Tester, row: usize, col: usize, shift: bool, adding: bool) void {
    const p = at(t, row, col);
    t.ctx.input.shift = shift;
    t.ctx.input.cmd = adding;
    t.ctx.input.ctrl = adding;
    t.click(p[0], p[1]);
    t.ctx.input.shift = false;
    t.ctx.input.cmd = false;
    t.ctx.input.ctrl = false;
}

test "a set of rows: Cmd-clicks add and take out, Shift extends, Cmd+A chooses all" {
    var sel: ui.Selection = .init(testing.allocator);
    defer sel.deinit();
    var s: Sheet = .{};
    s.state.selection = &sel;
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Sheet.view), .{ .width = 480, .height = 400 });
    defer t.deinit();
    click(&t, 2, 1, false, false);
    click(&t, 5, 1, false, true);
    click(&t, 7, 1, false, true);
    try testing.expect(s.state.rowChosen(2) and s.state.rowChosen(5) and s.state.rowChosen(7));
    try testing.expect(!s.state.rowChosen(3) and !s.state.rowChosen(6));
    click(&t, 5, 1, false, true);
    try testing.expect(!s.state.rowChosen(5) and sel.count() == 2);
    // Shift extends from the row the last click was on (the one taken out).
    click(&t, 9, 1, true, false);
    try testing.expectEqual(@as(usize, 5), sel.count());
    try testing.expect(s.state.rowChosen(5) and s.state.rowChosen(9) and !s.state.rowChosen(2));
    _ = t.shortcut(.{ .key = 'a', .cmd = true });
    try testing.expectEqual(@as(usize, 30), sel.count());
}

test "a right-click outside the choice chooses what it is on before the menu opens" {
    var sel: ui.Selection = .init(testing.allocator);
    defer sel.deinit();
    var s: Sheet = .{};
    s.state.selection = &sel;
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Sheet.view), .{ .width = 480, .height = 400 });
    defer t.deinit();
    click(&t, 1, 1, false, false);
    click(&t, 3, 1, true, false);
    var p = at(&t, 2, 1);
    t.rightClick(p[0], p[1]);
    try testing.expectEqual(@as(usize, 3), sel.count());
    try testing.expectEqual(@as(?[2]usize, .{ 2, 1 }), s.menu_at);
    try testing.expect(s.state.cell_menu.isOpen());
    s.state.cell_menu.close();
    t.frame();
    p = at(&t, 6, 2);
    t.rightClick(p[0], p[1]);
    try testing.expect(sel.count() == 1 and s.state.rowChosen(6));
    try testing.expectEqual(@as(?[2]usize, .{ 6, 2 }), s.menu_at);
    s.state.cell_menu.close();
    t.frame();
    // A menu without items does not open.
    s.items = false;
    p = at(&t, 8, 1);
    t.rightClick(p[0], p[1]);
    t.frame();
    try testing.expect(!s.state.cell_menu.isOpen());
}

test "the cell menu acts on its cell" {
    var s: Sheet = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Sheet.view), .{ .width = 480, .height = 400 });
    defer t.deinit();
    const p = at(&t, 4, 2);
    t.rightClick(p[0], p[1]);
    try testing.expect(s.state.cell_menu.isOpen());
    try t.clickText("Copy");
    try testing.expectEqual(@as(?[2]usize, .{ 4, 2 }), s.copied);
    try testing.expect(!s.state.cell_menu.isOpen());
}

test "a row header chooses whole rows, and its header every row" {
    var s: Sheet = .{ .opts = .{ .cells = true } };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Sheet.view), .{ .width = 480, .height = 400 });
    defer t.deinit();
    click(&t, 3, 1, false, false);
    try testing.expectEqual(@as(?[2]usize, .{ 1, 1 }), s.state.cols);
    click(&t, 4, 0, false, false);
    try testing.expectEqual(@as(?[2]usize, .{ 0, 2 }), s.state.cols);
    try testing.expectEqual(@as(?[2]usize, .{ 4, 4 }), s.state.rows());
    // A drag down the row headers: whole rows.
    const a = at(&t, 5, 0);
    const b = at(&t, 8, 0);
    t.drag(a[0], a[1], b[0], b[1]);
    try testing.expectEqual(@as(?[2]usize, .{ 5, 8 }), s.state.rows());
    try testing.expectEqual(@as(?[2]usize, .{ 0, 2 }), s.state.cols);
    try testing.expect(s.state.cellChosen(6, 0) and s.state.cellChosen(6, 2));
    // Its header: every row and column; it does not sort.
    try t.clickText("#");
    try testing.expectEqual(@as(?[2]usize, .{ 0, 29 }), s.state.rows());
    try testing.expectEqual(@as(?[2]usize, .{ 0, 2 }), s.state.cols);
    try testing.expectEqual(@as(?table.Sort, null), s.state.sort);
}
