//! The grid through `Tester`: fixed, fitting and shared tracks, spans,
//! cells given a place, alignment in cells, and right to left.
const std = @import("std");
const ui = @import("ui.zig");
const grid = @import("grid.zig");
const direction = @import("direction.zig");
const testing = std.testing;

fn block(c: *ui.Context, name: []const u8, w: f32, h: f32) void {
    _ = c.leaf(.{ .width = .{ .px = w }, .height = .{ .px = h } }, .{ .text = .{ .str = name, .style = .{}, .color = c.theme.text } }, null);
}

const Photos = struct {
    fn view(_: *Photos, c: *ui.Context) void {
        var g = grid.grid(c, .{ .columns = &.{ .{ .fr = 1 }, .{ .fr = 1 }, .{ .fr = 1 } }, .gap_x = 10, .gap_y = 5, .style = .{ .width = .fill, .padding = .all(10) } });
        // Fixed sizes keep theirs; auto ones stretch over their cells.
        for ([_][]const u8{ "a", "b", "c", "d" }) |n| {
            g.cell(.{});
            block(c, n, 20, 20);
            ui.end(c);
        }
        g.end();
        ui.text(c, "after", .{});
    }
};

test "grid: equal shares fill the width, children fill cells row by row" {
    var s: Photos = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Photos.view), .{ .width = 340, .height = 300 });
    defer t.deinit();
    // (340 - 20 padding - 20 gaps) / 3 = 100 a column.
    const a = t.findText("a").?;
    const b = t.findText("b").?;
    const cc = t.findText("c").?;
    const d = t.findText("d").?;
    try testing.expectEqual(@as(f32, 10), a.x);
    try testing.expectEqual(@as(f32, 120), b.x);
    try testing.expectEqual(@as(f32, 230), cc.x);
    try testing.expectEqual(@as(f32, 10), d.x);
    try testing.expectEqual(@as(f32, 10 + 20 + 5), d.y);
    // The grid is as tall as its rows: what follows comes after.
    const after = t.findText("after").?;
    try testing.expectEqual(@as(f32, 10 + 20 + 5 + 20 + 10), after.y);
}

const Form = struct {
    fn view(_: *Form, c: *ui.Context) void {
        var g = grid.grid(c, .{ .columns = &.{ .fit, .{ .px = 50 }, .{ .fr = 1 } }, .gap_x = 4 });
        // Across every column.
        g.cell(.{ .col_span = -1 });
        block(c, "header", 30, 10);
        ui.end(c);
        // Children outside cells take the next one.
        block(c, "label", 70, 10);
        block(c, "short", 20, 10);
        g.cell(.{ .justify = .end, .@"align" = .center });
        block(c, "end", 20, 10);
        ui.end(c);
        // Given a place, spanning two rows.
        g.cell(.{ .col = 3, .row = 3, .row_span = 2 });
        block(c, "tall", 20, 50);
        ui.end(c);
        block(c, "x", 10, 10);
        g.end();
    }
};

test "grid: fitting, fixed and shared tracks, spans and given places" {
    var s: Form = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Form.view), .{ .width = 300, .height = 300 });
    defer t.deinit();
    const header = t.findText("header").?;
    try testing.expectEqual(@as(f32, 0), header.x);
    try testing.expectEqual(@as(f32, 0), header.y);
    // The first column fits "label" (70), the second is 50 wide, the third the rest.
    const label = t.findText("label").?;
    const short = t.findText("short").?;
    const end_ = t.findText("end").?;
    try testing.expectEqual(@as(f32, 0), label.x);
    try testing.expectEqual(@as(f32, 10), label.y);
    try testing.expectEqual(@as(f32, 74), short.x);
    // At the end of the last column, centered in its row.
    try testing.expectEqual(@as(f32, 300 - 20), end_.x);
    try testing.expectEqual(@as(f32, 10), end_.y);
    // Row 3, column 3; "x" takes the first free cell of row 3.
    const tall = t.findText("tall").?;
    try testing.expectEqual(@as(f32, 128), tall.x);
    try testing.expectEqual(@as(f32, 20), tall.y);
    const x = t.findText("x").?;
    try testing.expectEqual(@as(f32, 0), x.x);
    try testing.expectEqual(@as(f32, 20), x.y);
    // The spanned rows hold the tall cell: the grid is 20 + 50 high.
    try testing.expectEqual(@as(f32, 70), t.ctx.nodes.items[1].rect.h);
}

test "grid: right to left, columns go from the right" {
    var s: Photos = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Photos.view), .{ .width = 340, .height = 300 });
    defer t.deinit();
    direction.set(&t.ctx, .rtl);
    t.frame();
    const a = t.findText("a").?;
    const cc = t.findText("c").?;
    try testing.expectEqual(@as(f32, 330), a.x + a.w);
    try testing.expectEqual(@as(f32, 110), cc.x + cc.w);
}

test "grid: placement" {
    // Unit test of placement through the registry.
    var s: Form = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Form.view), .{});
    defer t.deinit();
    t.ctx.begin();
    Form.view(&s, &t.ctx);
    const spec = grid.lookup(&t.ctx, 1).?;
    const cells = spec.cells();
    try testing.expectEqual(@as(usize, 6), cells.len);
    try testing.expectEqual(@as(u16, 3), cells[0].col_span);
    try testing.expectEqual(@as(u16, 1), cells[1].row);
    try testing.expectEqual(@as(u16, 2), cells[4].col);
    try testing.expectEqual(@as(u16, 2), cells[4].row);
    try testing.expectEqual(@as(u16, 2), cells[4].row_span);
    try testing.expectEqual(@as(u16, 4), spec.n_rows);
    t.ctx.finish();
}
