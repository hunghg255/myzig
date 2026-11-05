//! Dragging a scrolling box's thumb: it moves the box, views don't see the
//! press, a box wider than the window keeps its bar in view, and what is
//! painted over a bar keeps the pointer.
const std = @import("std");
const ui = @import("ui.zig");
const testing = std.testing;

fn offset(t: *ui.Tester, id: u64) f32 {
    return t.ctx.scroll.get(id) orelse 0;
}

const Tall = struct {
    id: u64 = 0,
    clicks: usize = 0,
    bar: bool = true,

    fn view(s: *Tall, c: *ui.Context) void {
        s.id = c.peekId(null);
        _ = c.open(.{ .width = .fill, .height = .fill, .scroll = true, .scrollbar = s.bar }, null);
        const row = c.open(.{ .width = .fill, .height = .{ .px = 1000 } }, null);
        if (c.interact(row, .{}).clicked) s.clicks += 1;
        c.end();
        c.end();
    }
};

test "scrollbar: dragging the thumb scrolls, and the box under it sees no press" {
    var s: Tall = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Tall.view), .{ .width = 200, .height = 200 });
    defer t.deinit();
    t.frame();
    // A thumb of 40 travels 160, which stands for an offset of 800.
    t.drag(196, 10, 196, 90);
    try testing.expectApproxEqAbs(@as(f32, 400), offset(&t, s.id), 1);
    try testing.expectEqual(@as(usize, 0), s.clicks);

    // It stops at the end, and comes back from wherever the pointer goes.
    t.drag(196, 90, 196, 900);
    try testing.expectApproxEqAbs(@as(f32, 800), offset(&t, s.id), 1);
    t.frame();
    t.drag(196, 180, 500, -500);
    try testing.expectApproxEqAbs(@as(f32, 0), offset(&t, s.id), 1);

    // After the drag, presses reach the box again.
    t.click(100, 100);
    try testing.expectEqual(@as(usize, 1), s.clicks);
    // Beside the thumb nothing moves.
    t.drag(100, 100, 100, 150);
    try testing.expectEqual(@as(f32, 0), offset(&t, s.id));
}

test "scrollbar: a press on the track brings the thumb there" {
    var s: Tall = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Tall.view), .{ .width = 200, .height = 200 });
    defer t.deinit();
    t.frame();
    // The thumb's middle at 120: its start at 100 of 160, an offset of 500.
    t.click(197, 120);
    try testing.expectApproxEqAbs(@as(f32, 500), offset(&t, s.id), 1);
    try testing.expectEqual(@as(usize, 0), s.clicks);
    // Off the track, the box has the press.
    t.click(185, 20);
    try testing.expectEqual(@as(usize, 1), s.clicks);
}

test "scrollbar: no bar, no drag" {
    var s: Tall = .{ .bar = false };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Tall.view), .{ .width = 200, .height = 200 });
    defer t.deinit();
    t.frame();
    t.drag(196, 10, 196, 90);
    try testing.expectEqual(@as(f32, 0), offset(&t, s.id));
}

/// A tall list inside a row that scrolls sideways, as a wide data grid is.
const Wide = struct {
    outer: u64 = 0,
    inner: u64 = 0,

    fn view(s: *Wide, c: *ui.Context) void {
        s.outer = c.peekId(null);
        _ = c.open(.{ .width = .fill, .height = .fill, .direction = .row, .scroll = true, .align_items = .stretch }, null);
        s.inner = c.peekId(null);
        _ = c.open(.{ .width = .{ .px = 1000 }, .height = .fill, .scroll = true }, null);
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1000 } }, .none, null);
        c.end();
        c.end();
    }
};

test "scrollbar: a box wider than the window keeps its bars in view" {
    var s: Wide = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Wide.view), .{ .width = 200, .height = 200 });
    defer t.deinit();
    t.frame();
    // The tall list's bar is at the window's edge, not at its own far one.
    t.drag(196, 10, 196, 90);
    try testing.expect(offset(&t, s.inner) > 300);
    try testing.expectEqual(@as(f32, 0), offset(&t, s.outer));
    // The row's bar runs along the bottom.
    t.drag(10, 196, 90, 196);
    try testing.expect(offset(&t, s.outer) > 300);
}

const Covered = struct {
    id: u64 = 0,
    clicks: usize = 0,

    fn view(s: *Covered, c: *ui.Context) void {
        s.id = c.peekId(null);
        _ = c.open(.{ .width = .fill, .height = .fill, .scroll = true }, null);
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1000 } }, .none, null);
        c.end();
        // A box over the bar, as a dialog's would be.
        _ = c.open(.{ .absolute = true, .width = .fill, .height = .fill, .align_items = .end }, null);
        const over = c.open(.{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, null);
        if (c.interact(over, .{}).clicked) s.clicks += 1;
        c.end();
        c.end();
    }
};

test "scrollbar: what is painted over a bar keeps the pointer" {
    var s: Covered = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Covered.view), .{ .width = 200, .height = 200 });
    defer t.deinit();
    t.frame();
    t.click(196, 10);
    try testing.expectEqual(@as(usize, 1), s.clicks);
    t.drag(196, 10, 196, 90);
    try testing.expectEqual(@as(f32, 0), offset(&t, s.id));
}
