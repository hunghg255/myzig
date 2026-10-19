//! Choosing blocks of cells and dragging over rows in tables
//! (`table_cells.zig`), after mygo's cell selection and drag select tests.
const std = @import("std");
const ui = @import("ui.zig");
const table = @import("table.zig");
const testing = std.testing;
const S = ui.Shortcut;

const cols: []const table.Column = &.{
    .{ .title = "#", .width = 48 },
    .{ .title = "Name" },
    .{ .title = "Size", .width = 90 },
};

const Sheet = struct {
    state: table.TableState = .{},
    opts: table.Options = .{ .cells = true },
    selecting: bool = false,
    changes: u32 = 0,

    fn view(s: *Sheet, c: *ui.Context) void {
        var t = table.table(c, &s.state, cols, 40, s.opts);
        while (t.next()) |row| {
            while (t.cell()) |col| ui.text(c, c.print("r{d}c{d}", .{ row, col }), .{ .color = t.textColor() });
        }
        const r = t.end();
        s.selecting = r.drag_selecting;
        if (r.changed) s.changes += 1;
    }
};

fn at(t: *ui.Tester, row: usize, col: usize) [2]f32 {
    var buf: [16]u8 = undefined;
    const r = t.findText(std.fmt.bufPrint(&buf, "r{d}c{d}", .{ row, col }) catch unreachable).?;
    return .{ r.x + 2, r.y + r.h / 2 };
}

fn click(t: *ui.Tester, row: usize, col: usize, shift: bool) void {
    const p = at(t, row, col);
    t.ctx.input.shift = shift;
    t.click(p[0], p[1]);
    t.ctx.input.shift = false;
}

test "cells: a click chooses a cell, Shift extends the rows and columns" {
    var s: Sheet = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Sheet.view), .{ .width = 480, .height = 400 });
    defer t.deinit();
    click(&t, 2, 1, false);
    try testing.expectEqual(@as(?usize, 2), s.state.selected);
    try testing.expectEqual(@as(?[2]usize, .{ 1, 1 }), s.state.cols);
    try testing.expect(s.state.cellChosen(2, 1) and !s.state.cellChosen(2, 0));
    click(&t, 4, 2, true);
    try testing.expectEqual(@as(?[2]usize, .{ 2, 4 }), s.state.rows());
    try testing.expectEqual(@as(?[2]usize, .{ 1, 2 }), s.state.cols);
    try testing.expect(s.state.cellChosen(3, 2) and !s.state.cellChosen(3, 0) and !s.state.cellChosen(5, 1));
    // The block's cells show in the accent color, the others not.
    t.frame();
    var accent: usize = 0;
    for (t.ctx.nodes.items) |n| if (n.style.background) |bg| {
        if (std.meta.eql(bg, t.ctx.theme.accent)) accent += 1;
    };
    try testing.expectEqual(@as(usize, 6), accent);
}

test "cells: a drag chooses the cells it goes over, and says so while it goes" {
    var s: Sheet = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Sheet.view), .{ .width = 480, .height = 400 });
    defer t.deinit();
    const a = at(&t, 1, 0);
    const b = at(&t, 3, 1);
    t.moveTo(a[0], a[1]);
    t.ctx.pointerDown();
    t.frame();
    // Chosen as the pointer goes down.
    try testing.expectEqual(@as(?usize, 1), s.state.selected);
    t.ctx.input.mouse = .{ .x = b[0], .y = b[1] };
    t.frame();
    try testing.expect(s.selecting);
    try testing.expectEqual(@as(?[2]usize, .{ 1, 3 }), s.state.rows());
    try testing.expectEqual(@as(?[2]usize, .{ 0, 1 }), s.state.cols);
    t.ctx.pointerUp();
    t.frame();
    t.frame();
    try testing.expect(!s.selecting);
    // The release keeps what the drag chose.
    try testing.expectEqual(@as(?[2]usize, .{ 1, 3 }), s.state.rows());
    try testing.expectEqual(@as(?[2]usize, .{ 0, 1 }), s.state.cols);
}

test "cells: Left and Right move the column, Shift extends; Cmd+A chooses all" {
    var s: Sheet = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Sheet.view), .{ .width = 480, .height = 400 });
    defer t.deinit();
    click(&t, 2, 0, false);
    t.key(.right);
    try testing.expectEqual(@as(?[2]usize, .{ 1, 1 }), s.state.cols);
    t.ctx.input.shift = true;
    t.key(.right);
    t.key(.down);
    t.ctx.input.shift = false;
    try testing.expectEqual(@as(?[2]usize, .{ 1, 2 }), s.state.cols);
    try testing.expectEqual(@as(?[2]usize, .{ 2, 3 }), s.state.rows());
    // Without Shift, the keys that move the rows leave one row and column.
    t.key(.down);
    try testing.expectEqual(@as(?[2]usize, .{ 4, 4 }), s.state.rows());
    try testing.expectEqual(@as(?[2]usize, .{ 2, 2 }), s.state.cols);
    try testing.expect(t.shortcut(.{ .key = 'a', .cmd = true }));
    try testing.expectEqual(@as(?[2]usize, .{ 0, 39 }), s.state.rows());
    try testing.expectEqual(@as(?[2]usize, .{ 0, 2 }), s.state.cols);
}

test "drag select: a drag over rows chooses them, scrolling past the bottom" {
    var s: Sheet = .{ .opts = .{ .drag_select = true } };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Sheet.view), .{ .width = 480, .height = 400 });
    defer t.deinit();
    const a = at(&t, 1, 1);
    const b = at(&t, 4, 1);
    t.drag(a[0], a[1], b[0], b[1]);
    try testing.expectEqual(@as(?[2]usize, .{ 1, 4 }), s.state.rows());
    try testing.expectEqual(@as(?[2]usize, null), s.state.cols);
    // A click on a row chosen chooses it alone, at the release.
    click(&t, 3, 1, false);
    try testing.expectEqual(@as(?[2]usize, .{ 3, 3 }), s.state.rows());
    // Held below the rows, the table scrolls and chooses on.
    const p = at(&t, 3, 1);
    t.moveTo(p[0], p[1]);
    t.ctx.pointerDown();
    t.frame();
    t.ctx.input.mouse = .{ .x = p[0], .y = 395 };
    for (0..60) |_| t.frame();
    try testing.expect(s.state.selected.? > 12);
    t.ctx.pointerUp();
    t.frame();
    try testing.expectEqual(@as(usize, 3), s.state.rows().?[0]);
}
