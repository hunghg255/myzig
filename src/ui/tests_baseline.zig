//! Rows and grids lining up their children's first lines of text
//! (`Align.baseline`), after mygo's baseline tests; the boxes without text
//! line up their bottoms, as Chrome lays them out.
const std = @import("std");
const ui = @import("ui.zig");
const grid = @import("grid.zig");
const lb = @import("layout_baseline.zig");
const testing = std.testing;

fn textBox(c: *ui.Context, s: []const u8, size: f32, style: ui.Style) u32 {
    return c.leaf(style, .{ .text = .{ .str = s, .style = .{ .size = size }, .color = c.theme.text } }, null);
}

fn box(c: *ui.Context, w: f32, h: f32) u32 {
    return c.leaf(.{ .width = .{ .px = w }, .height = .{ .px = h } }, .none, null);
}

/// The baseline of text box `i` in the window.
fn baselineOf(t: *ui.Tester, i: u32) f32 {
    const n = t.ctx.node(i);
    return n.rect.y + n.style.padding.top + lb.ofText(&t.ctx, n.content.text.style);
}

fn rel(t: *ui.Tester, i: u32) ui.Rect {
    const n = t.ctx.node(i);
    const p = t.ctx.node(n.parent).rect;
    return .{ .x = n.rect.x - p.x, .y = n.rect.y - p.y, .w = n.rect.w, .h = n.rect.h };
}

fn want(t: *ui.Tester, i: u32, r: ui.Rect) !void {
    const got = rel(t, i);
    inline for (.{ "x", "y", "w", "h" }) |f| try testing.expectApproxEqAbs(@field(r, f), @field(got, f), 0.05);
}

const Price = struct {
    at: [4]u32 = undefined,
    fn view(s: *Price, c: *ui.Context) void {
        s.at[0] = c.open(.{ .direction = .row, .align_items = .baseline, .gap = 4 }, null);
        s.at[1] = textBox(c, "$42", 40, .{});
        s.at[2] = textBox(c, "/month", 13, .{ .padding = .{ .top = 3 } });
        s.at[3] = box(c, 6, 6);
        c.end();
    }
};

test "baseline: text of different sizes sits on one line, a box without text on it" {
    var s: Price = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Price.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    const price = t.ctx.node(s.at[1]).rect;
    const unit = t.ctx.node(s.at[2]).rect;
    const row = t.ctx.node(s.at[0]).rect;
    try testing.expectApproxEqAbs(baselineOf(&t, s.at[1]), baselineOf(&t, s.at[2]), 0.01);
    // The large text starts the row, which is as high as both take.
    try testing.expectEqual(row.y, price.y);
    try testing.expectApproxEqAbs(@max(price.h, unit.y - row.y + unit.h), row.h, 0.01);
    // The box puts its bottom on the line.
    const dot = t.ctx.node(s.at[3]).rect;
    try testing.expectApproxEqAbs(baselineOf(&t, s.at[1]), dot.y + dot.h, 0.01);
}

const Grids = struct {
    at: [8]u32 = undefined,
    fn view(s: *Grids, c: *ui.Context) void {
        _ = c.open(.{}, null);
        defer c.end();
        var g = grid.grid(c, .{ .columns = &.{ .{ .px = 100 }, .{ .px = 100 } }, .align_items = .baseline, .style = .{} });
        s.at[0] = g.index;
        s.at[1] = box(c, 100, 20);
        s.at[2] = box(c, 100, 50);
        s.at[3] = box(c, 100, 10);
        g.cell(.{ .@"align" = .start });
        s.at[4] = box(c, 100, 30);
        ui.end(c);
        g.end();
        var f = grid.grid(c, .{ .columns = &.{ .{ .px = 100 }, .{ .px = 100 } }, .rows = &.{.{ .px = 200 }}, .align_items = .baseline, .style = .{} });
        s.at[5] = f.index;
        s.at[6] = box(c, 100, 20);
        s.at[7] = box(c, 100, 50);
        f.end();
    }
};

test "baseline: a grid's row lines up its items' baselines, and is as high as that takes" {
    var s: Grids = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Grids.view), .{ .width = 400, .height = 600 });
    defer t.deinit();
    try want(&t, s.at[0], .{ .x = 0, .y = 0, .w = 200, .h = 80 });
    try want(&t, s.at[1], .{ .x = 0, .y = 30, .w = 100, .h = 20 });
    try want(&t, s.at[2], .{ .x = 100, .y = 0, .w = 100, .h = 50 });
    try want(&t, s.at[3], .{ .x = 0, .y = 50, .w = 100, .h = 10 });
    // Aligned to the start of its cell (the cell is its parent).
    const d = t.ctx.node(s.at[4]).rect;
    try testing.expectEqual(@as(f32, 50), d.y);
    try want(&t, s.at[5], .{ .x = 0, .y = 80, .w = 200, .h = 200 });
    try want(&t, s.at[6], .{ .x = 0, .y = 30, .w = 100, .h = 20 });
    try want(&t, s.at[7], .{ .x = 100, .y = 0, .w = 100, .h = 50 });
}

const Nested = struct {
    at: [4]u32 = undefined,
    fn view(s: *Nested, c: *ui.Context) void {
        s.at[0] = c.open(.{ .direction = .row, .width = .{ .px = 300 }, .align_items = .baseline }, null);
        s.at[1] = box(c, 10, 40);
        s.at[2] = c.open(.{ .padding = .{ .top = 7 } }, null);
        _ = box(c, 10, 10);
        _ = box(c, 10, 20);
        c.end();
        s.at[3] = c.open(.{ .direction = .row, .align_items = .baseline }, null);
        _ = box(c, 10, 5);
        _ = box(c, 10, 15);
        c.end();
        c.end();
    }
};

test "baseline: a column's is its first child's, a row's that of its line" {
    var s: Nested = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Nested.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    // The box: 40 to its line; the column 7 + 10; the inner row 15.
    try want(&t, s.at[0], .{ .x = 0, .y = 0, .w = 300, .h = 60 });
    try want(&t, s.at[1], .{ .x = 0, .y = 0, .w = 10, .h = 40 });
    try want(&t, s.at[2], .{ .x = 10, .y = 23, .w = 10, .h = 37 });
    try want(&t, s.at[3], .{ .x = 20, .y = 25, .w = 20, .h = 15 });
}

const Across = struct {
    at: [2]u32 = undefined,
    fn view(s: *Across, c: *ui.Context) void {
        _ = c.open(.{ .width = .{ .px = 300 }, .height = .{ .px = 100 }, .align_items = .baseline }, null);
        s.at[0] = box(c, 50, 10);
        s.at[1] = box(c, 100, 10);
        c.end();
    }
};

test "baseline: across a column, the children start at its start" {
    var s: Across = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Across.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    try want(&t, s.at[0], .{ .x = 0, .y = 0, .w = 50, .h = 10 });
    try want(&t, s.at[1], .{ .x = 0, .y = 10, .w = 100, .h = 10 });
}
