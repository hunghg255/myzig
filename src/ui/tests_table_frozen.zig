const std = @import("std");
const ui = @import("ui.zig");
const testing = std.testing;

const App = struct {
    state: ui.TableState = .{},
    frozen: usize = 2,
    sideways: bool = false,
    rtl: bool = false,
    hide_first: bool = false,
    widths: ?[]f32 = null,
    menu_cell: ?[2]usize = null,
    scroller: u64 = 0,

    const titles = [_][]const u8{ "#", "Name", "A", "B", "C", "D", "E", "F" };

    fn menu(ctx: *anyopaque, m: *ui.MenuPanel, row: usize, col: usize) void {
        const s: *App = @ptrCast(@alignCast(ctx));
        s.menu_cell = .{ row, col };
        _ = m;
    }

    fn view(s: *App, c: *ui.Context) void {
        ui.direction.set(c, if (s.rtl) .rtl else .ltr);
        var cols: [titles.len]ui.TableColumn = undefined;
        for (&cols, titles, 0..) |*col, title, i| col.* = .{ .title = title, .width = if (i == 0) 40 else 160, .hidden = i == 0 and s.hide_first };
        var t = ui.table(c, &s.state, &cols, 3, .{
            .frozen = s.frozen,
            .sideways = s.sideways,
            .cells = true,
            .column_widths = s.widths,
            .cell_menu = .{ .ctx = s, .build = menu },
        });
        s.scroller = t.side.id;
        while (t.next()) |row| while (t.cell()) |col| ui.text(c, c.print("r{d}c{d}", .{ row, col }), .{});
        _ = t.end();
    }
};

fn start(t: *ui.Tester, s: *App) !void {
    try t.init(testing.allocator, .init(s, App.view), .{ .width = 500, .height = 300 });
    t.frame();
}

fn scrollTo(t: *ui.Tester, id: u64, x: f32) void {
    t.ctx.scroll.put(t.ctx.gpa, id, x) catch unreachable;
    t.frame();
}

fn left(t: *ui.Tester, text: []const u8) !f32 {
    return (t.findText(text) orelse return error.NotFound).x;
}

test "frozen columns stay as the others scroll under the table's own scrolling" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    const name = try left(&t, "r0c1");
    const header = try left(&t, "Name");
    const other = try left(&t, "r0c2");
    scrollTo(&t, s.scroller, 120);
    try testing.expectEqual(name, try left(&t, "r0c1"));
    try testing.expectEqual(header, try left(&t, "Name"));
    try testing.expectApproxEqAbs(other - 120, try left(&t, "r0c2"), 0.5);
    try testing.expectApproxEqAbs(other - 120, try left(&t, "A"), 0.5);
}

test "frozen columns: a click finds the cell shown, frozen or scrolled under them" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    scrollTo(&t, s.scroller, 400);
    // In the frozen column, over where a scrolled column is laid out.
    const name = t.findText("r1c1").?;
    t.click(name.x + 2, name.y + 2);
    try testing.expectEqual(1, s.state.cols.?[1]);
    try testing.expectEqual(1, s.state.selected.?);
    // Past the frozen columns: the column scrolled there.
    const shown = t.findText("r2c5").?;
    t.click(shown.x + 2, shown.y + 2);
    try testing.expectEqual(5, s.state.cols.?[1]);
    try testing.expectEqual(2, s.state.selected.?);
}

test "frozen columns: a right-click gives the menu of the frozen cell over a scrolled one" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    scrollTo(&t, s.scroller, 400);
    const name = t.findText("r1c1").?;
    t.rightClick(name.x + 2, name.y + 2);
    t.frame();
    try testing.expectEqual([2]usize{ 1, 1 }, s.menu_cell.?);
}

test "frozen columns: Right brings a cell out from under the edge and back" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    const first = t.findText("r0c2").?;
    t.click(first.x + 2, first.y + 2);
    for (0..5) |_| t.key(.right);
    try testing.expectEqual(7, s.state.cols.?[1]);
    t.frame();
    const shown = t.findText("r0c7").?;
    try testing.expect(shown.x > 200 and shown.x + shown.w <= 500);
    for (0..5) |_| t.key(.left);
    t.frame();
    try testing.expectApproxEqAbs(first.x, (t.findText("r0c2").?).x, 0.5);
}

test "frozen columns: a drag past the end scrolls toward the cells beyond" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    const a = t.findText("r0c2").?;
    t.moveTo(a.x + 2, a.y + 2);
    t.ctx.pointerDown();
    t.frame();
    t.moveTo(498, a.y + 2);
    const before = (t.findText("r0c2").?).x;
    for (0..4) |_| t.advance(0.1);
    try testing.expect((t.findText("r0c2") orelse return error.Unscrolled).x < before);
    t.ctx.pointerUp();
    t.frame();
}

test "frozen columns too wide for the table scroll with the others" {
    var s: App = .{ .frozen = 3 };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 300, .height = 200 });
    defer t.deinit();
    t.frame();
    const name = t.findText("r0c1").?;
    scrollTo(&t, s.scroller, 100);
    try testing.expectApproxEqAbs(name.x - 100, (t.findText("r0c1").?).x, 0.5);
}

test "frozen columns: hidden ones count, and right to left they stay on the right" {
    var s: App = .{ .rtl = true, .hide_first = true };
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    t.frame();
    const name = t.findText("r0c1").?;
    try testing.expect(name.x > 300);
    const other = t.findText("r0c2").?;
    scrollTo(&t, s.scroller, 120);
    try testing.expectEqual(name.x, (t.findText("r0c1").?).x);
    try testing.expectApproxEqAbs(other.x + 120, (t.findText("r0c2").?).x, 0.5);
    try testing.expect(!t.hasText("r0c0"));
}

test "a table scrolling sideways without frozen columns, and columns that share the room" {
    const Share = struct {
        state: ui.TableState = .{},
        scroller: u64 = 0,
        fn view(s: *@This(), c: *ui.Context) void {
            const cols = [_]ui.TableColumn{ .{ .title = "Grows", .min_width = 120 }, .{ .title = "Fixed", .width = 100 } };
            var t = ui.table(c, &s.state, &cols, 1, .{ .sideways = true });
            s.scroller = t.side.id;
            while (t.next()) |_| while (t.cell()) |col| ui.text(c, if (col == 0) "grows" else "fixed", .{});
            _ = t.end();
        }
    };
    var s: Share = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Share.view), .{ .width = 500, .height = 200 });
    defer t.deinit();
    t.frame();
    // It fits: the shared column takes what is left.
    try testing.expect((t.findText("fixed").?).x > 390);
    t.resize(150, 200);
    t.frame();
    t.frame();
    const at = (t.findText("fixed").?).x;
    try testing.expectApproxEqAbs(@as(f32, 128), at, 1);
    scrollTo(&t, s.scroller, 40);
    try testing.expectApproxEqAbs(at - 40, (t.findText("fixed").?).x, 0.5);
}

test "frozen columns: a grip resizes a frozen column, and what scrolls moves over" {
    const Tree = @import("access_tree.zig").Tree;
    var widths = [_]f32{ 40, 160, 160, 160, 160, 160, 160, 160 };
    var s: App = .{ .widths = &widths };
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    t.ctx.access.enabled = true;
    t.frame();
    const other = try left(&t, "r0c2");
    var tree: Tree = .init(testing.allocator);
    defer tree.deinit();
    tree.build(&t.ctx);
    t.ctx.focus = (tree.byName(.splitter, "Resize Name") orelse return error.NoGrip).id;
    t.key(.right);
    t.frame();
    try testing.expectEqual(@as(f32, 170), widths[1]);
    try testing.expectApproxEqAbs(other + 10, try left(&t, "r0c2"), 0.5);
}

test "frozen columns: a right-click beside the table opens no cell scrolled out there" {
    const Beside = struct {
        table: App = .{},
        fn view(s: *@This(), c: *ui.Context) void {
            ui.row(c, .{ .width = .fill, .height = .fill, .align_items = .stretch });
            defer ui.end(c);
            ui.column(c, .{ .width = .{ .px = 150 }, .height = .fill });
            ui.end(c);
            ui.column(c, .{ .grow = 1, .height = .fill });
            App.view(&s.table, c);
            ui.end(c);
        }
    };
    var s: Beside = .{};
    s.table.frozen = 0;
    s.table.sideways = true;
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Beside.view), .{ .width = 500, .height = 300 });
    defer t.deinit();
    t.frame();
    scrollTo(&t, s.table.scroller, 400);
    t.frame();
    // The cell's place reaches left of the table, under the pointer.
    const out = t.findText("r0c2").?;
    try testing.expect(out.x < 150);
    t.rightClick(100, out.y + 2);
    t.frame();
    try testing.expect(s.table.menu_cell == null);
}
