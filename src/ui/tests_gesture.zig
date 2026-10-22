const std = @import("std");
const ui = @import("ui.zig");

test "pinches target the visible inner handler, bubble, and use local coordinates" {
    const S = struct {
        inner: usize = 0,
        outer: usize = 0,
        take: bool = true,
        last: ui.InputEvent = .{ .kind = .zoom },
        fn inside(s: *@This(), e: ui.InputEvent) bool {
            s.inner += 1;
            s.last = e;
            return s.take;
        }
        fn outside(s: *@This(), _: ui.InputEvent) bool {
            s.outer += 1;
            return true;
        }
        fn view(s: *@This(), c: *ui.Context) void {
            const outer = ui.div(c).size(200, 200).p(20).handleInput(s, outside);
            defer outer.end();
            const inner = ui.div(c).size(100, 80).handleInput(s, inside);
            inner.end();
        }
    };
    var s: S = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&s, S.view), .{});
    defer t.deinit();
    try std.testing.expect(t.pinch(30, 40, 2));
    try std.testing.expectEqual(@as(usize, 1), s.inner);
    try std.testing.expectEqual(@as(usize, 0), s.outer);
    try std.testing.expectEqual(@as(f32, 10), s.last.x);
    try std.testing.expectEqual(@as(f32, 20), s.last.y);
    try std.testing.expectEqual(@as(f32, 2), s.last.scale);
    t.ctx.input.ctrl = true;
    t.ctx.input.shift = true;
    t.ctx.input.cmd = true;
    try std.testing.expect(t.pinch(30, 40, 2));
    try std.testing.expect(s.last.ctrl and s.last.shift and s.last.cmd);
    t.ctx.input.ctrl = false;
    t.ctx.input.shift = false;
    t.ctx.input.cmd = false;
    s.take = false;
    try std.testing.expect(t.pinch(30, 40, 0.5));
    try std.testing.expectEqual(@as(usize, 1), s.outer);
    try std.testing.expect(!t.pinch(300, 300, 2));
    for ([_]f32{ 0, -1, 1, std.math.nan(f32), std.math.inf(f32) }) |scale| {
        try std.testing.expect(!t.pinch(30, 40, scale));
    }
    const before = s.inner;
    t.scroll(30, 40, -20);
    try std.testing.expectEqual(before + 1, s.inner);
    try std.testing.expectEqual(@as(f32, 20), s.last.dy);
    try std.testing.expect(s.last.precise);
    t.wheel(30, 40, 48);
    try std.testing.expect(!s.last.precise);
}

test "an unhandled scroll still moves its parent scroll container" {
    const S = struct {
        take: bool = true,
        fn input(s: *@This(), _: ui.InputEvent) bool {
            return s.take;
        }
        fn view(s: *@This(), c: *ui.Context) void {
            const parent = ui.div(c).size(100, 100).scrollY();
            defer parent.end();
            const child = ui.div(c).size(100, 400).handleInput(s, input);
            child.end();
        }
    };
    var s: S = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&s, S.view), .{});
    defer t.deinit();
    t.scroll(30, 40, -20);
    try std.testing.expectEqual(@as(usize, 0), t.ctx.scroll.count());
    s.take = false;
    t.scroll(30, 40, -20);
    try std.testing.expect(t.ctx.scroll.count() > 0);
}

test "gesture coordinates follow a scaled and translated handler and respect clipping" {
    const S = struct {
        point: ui.Point = .{},
        fn input(s: *@This(), e: ui.InputEvent) bool {
            s.point = .{ .x = e.x, .y = e.y };
            return true;
        }
        fn view(s: *@This(), c: *ui.Context) void {
            const parent = ui.div(c).size(60, 60).clip();
            defer parent.end();
            const child = ui.div(c).size(40, 40).handleInput(s, input);
            c.node(child.index).style.transform = ui.Affine.scaling(2, 2).translate(20, 20);
            c.node(child.index).style.transform_origin = .{};
            child.end();
        }
    };
    var s: S = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&s, S.view), .{});
    defer t.deinit();
    try std.testing.expect(t.pinch(40, 40, 2));
    try std.testing.expectApproxEqAbs(@as(f32, 10), s.point.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 10), s.point.y, 0.01);
    try std.testing.expect(!t.pinch(80, 80, 2));
}
