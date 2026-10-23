//! Animated controls in a virtual list: forgotten rows must not build up
//! in the animation cache, and a sweep must preserve ongoing motion.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const Scrolling = struct {
    row: usize = 0,
    show: bool = true,
    target: f32 = 0,
    shown: f32 = 0,

    fn view(s: *Scrolling, c: *ui.Context) void {
        s.shown = c.animate(7, 0, s.target, 1);
        if (!s.show) return;
        var rows = ui.list(c, .{ .count = 100_000, .row_height = 40, .scroll_to = @as(f32, @floatFromInt(s.row)) * 40 });
        while (rows.next()) |_| {
            ui.row(c, .{ .width = .fill, .height = .{ .px = 40 } });
            _ = ui.button(c, "Open", .{});
            ui.end(c);
        }
        rows.end();
    }
};

test "animation cache: scrolling evicts all expired controls and preserves motion" {
    var s: Scrolling = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scrolling.view), .{});
    defer t.deinit();
    while (t.ctx.frame < 360) {
        s.row += 3;
        // Change just before each sweep: resetting this live animation
        // would jump to its target instead of continuing the transition.
        if (t.ctx.frame % 120 == 118) s.target = 1 - s.target;
        const before = s.shown;
        t.frame();
        try testing.expect(@abs(s.shown - before) < 0.02);
        if (t.ctx.frame % 120 == 0) {
            var it = t.ctx.anims.valueIterator();
            while (it.next()) |entry| try testing.expect(t.ctx.frame - entry.frame <= 120);
            try testing.expect(s.shown > 0 and s.shown < 1);
        }
    }
    // Once the rows are gone and their grace period has elapsed, only
    // the animation still requested by the view remains.
    s.show = false;
    for (0..240) |_| t.frame();
    try testing.expectEqual(@as(u32, 1), t.ctx.anims.count());
}

test "animation cache: the grace period preserves a briefly absent value" {
    var s: Scrolling = .{ .show = false };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scrolling.view), .{});
    defer t.deinit();
    // The next sweep sees this value exactly 120 frames after its use.
    t.ctx.frame = 120;
    try testing.expectEqual(@as(f32, 0), t.ctx.animate(42, 0, 0, 1));
    t.ctx.frame = 239;
    t.ctx.finish();
    try testing.expectEqual(@as(u32, 1), t.ctx.anims.count());
    const resumed = t.ctx.animate(42, 0, 1, 1);
    try testing.expect(resumed > 0 and resumed < 0.02);
    t.ctx.frame = 479;
    t.ctx.finish();
    try testing.expectEqual(@as(u32, 0), t.ctx.anims.count());
}

test "animation cache: scratch allocation failure still makes progress" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var s: Scrolling = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scrolling.view), .{});
    defer t.deinit();
    while (t.ctx.frame < 239) {
        s.row += 3;
        t.frame();
    }
    const before = t.ctx.anims.count();
    try testing.expect(before > 64);
    // finish only needs the frame arena for sweep scratch. No further
    // layout or painting reads the strings owned by the old arena.
    t.ctx.arena.deinit();
    t.ctx.arena = .init(failing.allocator());
    t.ctx.finish();
    try testing.expect(failing.has_induced_failure);
    try testing.expect(t.ctx.anims.count() < before);
    const resumed = t.ctx.animate(7, 0, 1, 1);
    try testing.expect(resumed > 0 and resumed < 0.02);
}
