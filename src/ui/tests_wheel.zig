//! A mouse wheel's notches glide (`wheel.zig`): through a short ease out,
//! adding up, stopping at the end, giving way to the app and to a
//! touchpad, at once with less motion, and passing to the box around
//! one at its end.
const std = @import("std");
const ui = @import("ui.zig");
const motion = ui.motion;
const testing = std.testing;

const One = struct {
    id: u64 = 0,

    fn view(s: *One, c: *ui.Context) void {
        s.id = c.peekId(null);
        _ = c.open(.{ .width = .fill, .height = .fill, .scroll = true }, null);
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1000 } }, .none, null);
        c.end();
    }
};

fn offset(t: *ui.Tester, id: u64) f32 {
    return t.ctx.scroll.get(id) orelse 0;
}

fn tester(t: *ui.Tester, s: anytype) !void {
    try t.init(testing.allocator, .init(s, @TypeOf(s.*).view), .{ .width = 200, .height = 200 });
    t.moveTo(100, 100);
}

test "wheel: a notch glides, notches add up and stop at the end" {
    var s: One = .{};
    var t: ui.Tester = undefined;
    try tester(&t, &s);
    defer t.deinit();
    // A notch down (-100: up is positive) glides there.
    t.wheel(100, 100, -100);
    try testing.expectEqual(@as(f32, 0), offset(&t, s.id));
    t.advance(0.05);
    const mid = offset(&t, s.id);
    try testing.expect(mid > 0 and mid < 100);
    // Notches on the way add up.
    t.wheel(100, 100, -100);
    t.advance(1);
    try testing.expectApproxEqAbs(@as(f32, 200), offset(&t, s.id), 0.01);
    try testing.expect(!t.ctx.animating);
    try testing.expectEqual(@as(u32, 0), t.ctx.wheel.count());
    // Past the end, they stop there.
    for (0..10) |_| t.wheel(100, 100, -100);
    t.advance(1);
    try testing.expectEqual(@as(f32, 800), offset(&t, s.id));
    try testing.expectEqual(@as(u32, 0), t.ctx.wheel.count());
}

test "wheel: glideBy glides a box from elsewhere, as a notch over it" {
    var s: One = .{};
    var t: ui.Tester = undefined;
    try tester(&t, &s);
    defer t.deinit();
    // The pointer off the box: as a minimap beside it scrolls it.
    t.moveTo(-50, -50);
    t.ctx.glideBy(s.id, -100);
    t.advance(0.05);
    const mid = offset(&t, s.id);
    try testing.expect(mid > 0 and mid < 100);
    t.advance(1);
    try testing.expectApproxEqAbs(@as(f32, 100), offset(&t, s.id), 0.01);
}

test "wheel: the app or a touchpad moving the offset takes over" {
    var s: One = .{};
    var t: ui.Tester = undefined;
    try tester(&t, &s);
    defer t.deinit();
    t.wheel(100, 100, -100);
    t.advance(0.05);
    try t.ctx.scroll.put(t.gpa, s.id, 10);
    t.advance(1);
    try testing.expectEqual(@as(f32, 10), offset(&t, s.id));
    // A touchpad scrolls at once.
    t.scroll(100, 100, -30);
    try testing.expectEqual(@as(f32, 40), offset(&t, s.id));
}

test "wheel: with less motion, a notch scrolls at once" {
    var s: One = .{};
    var t: ui.Tester = undefined;
    try tester(&t, &s);
    defer t.deinit();
    motion.setReducedMotion(&t.ctx, true);
    t.wheel(100, 100, -100);
    try testing.expectEqual(@as(f32, 100), offset(&t, s.id));
}

const Nested = struct {
    outer: u64 = 0,
    inner: u64 = 0,

    fn view(s: *Nested, c: *ui.Context) void {
        s.outer = c.peekId(null);
        _ = c.open(.{ .width = .fill, .height = .fill, .scroll = true }, null);
        s.inner = c.peekId(null);
        _ = c.open(.{ .width = .fill, .height = .{ .px = 100 }, .scroll = true }, null);
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 150 } }, .none, null);
        c.end();
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1000 } }, .none, null);
        c.end();
    }
};

test "wheel: an inner box takes the notches it has room for, the outer the next" {
    var s: Nested = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Nested.view), .{ .width = 200, .height = 200 });
    defer t.deinit();
    t.moveTo(100, 50);
    t.wheel(100, 50, -40);
    t.wheel(100, 50, -40);
    t.advance(1);
    try testing.expectEqual(@as(f32, 50), offset(&t, s.inner));
    try testing.expectEqual(@as(f32, 0), offset(&t, s.outer));
    t.wheel(100, 50, -40);
    t.advance(1);
    try testing.expectEqual(@as(f32, 50), offset(&t, s.inner));
    try testing.expectApproxEqAbs(@as(f32, 40), offset(&t, s.outer), 0.01);
}

const Strip = struct {
    fn view(_: *Strip, c: *ui.Context) void {
        _ = c.open(.{ .direction = .row, .width = .{ .px = 200 }, .height = .{ .px = 30 }, .scroll = true }, null);
        for (0..20) |i| ui.textf(c, .{}, "Tab {d}", .{i});
        c.end();
    }
};

test "a scrolling row is as wide as it is given and scrolls sideways" {
    var s: Strip = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Strip.view), .{ .width = 400, .height = 100 });
    defer t.deinit();
    const before = t.findText("Tab 3").?.x;
    t.scroll(50, 10, -40);
    for (0..30) |_| t.frame();
    try testing.expect(t.findText("Tab 3").?.x < before - 1);
    // Scrolled to its end, the last tab ends at the row's right edge.
    t.scroll(50, 10, -100000);
    for (0..60) |_| t.frame();
    const last = t.findText("Tab 19").?;
    try testing.expectApproxEqAbs(@as(f32, 200), last.x + last.w, 1);
}
