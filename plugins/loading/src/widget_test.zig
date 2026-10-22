const std = @import("std");
const ui = @import("myzig").ui;
const loading = @import("loading.zig");

test "public indicator owns its clock, pauses, exposes accessibility and changes options" {
    const S = struct {
        indicator: loading.Indicator = .{},
        options: loading.Options = .{ .size = 32, .duration = 2, .label = "Saving" },
        fn view(s: *@This(), c: *ui.Context) void {
            _ = s.indicator.show(c, .ripple, s.options);
        }
    };
    var s: S = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&s, S.view), .{ .width = 100, .height = 100, .scale = 1 });
    defer t.deinit();
    t.ctx.access.enabled = true;
    t.advance(0.2);
    try std.testing.expect(s.indicator.seconds > 0);
    var tree: ui.AccessTree = .init(std.testing.allocator);
    defer tree.deinit();
    tree.build(&t.ctx);
    try std.testing.expect(tree.byName(.progress, "Saving") != null);
    s.options.paused = true;
    t.frame();
    const paused = s.indicator.seconds;
    t.advance(0.2);
    try std.testing.expectEqual(paused, s.indicator.seconds);
    s.options.paused = false;
    t.advance(0.2);
    try std.testing.expect(s.indicator.seconds > paused);
}

test "direction origin and sweep change their indicators pixels" {
    const I = loading.indicators;
    const S = struct {
        frame: I.Frame = .{ .index = 23, .seconds = 0.371, .options = .{ .color = .hex(0x4477ee) } },
        fn view(s: *@This(), c: *ui.Context) void {
            _ = ui.canvas(c, .{ .w = 48, .h = 48 }, .{}, &s.frame, I.Frame.draw);
        }
        fn hash(t: *ui.Tester) !u64 {
            const p = try t.render(std.testing.allocator);
            defer p.deinit(std.testing.allocator);
            return std.hash.Wyhash.hash(0, p.bytes);
        }
    };
    var s: S = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&s, S.view), .{ .width = 48, .height = 48, .scale = 1 });
    defer t.deinit();
    const ripple = try S.hash(&t);
    s.frame.options.direction = .in;
    t.frame();
    try std.testing.expect(ripple != try S.hash(&t));
    s.frame.index = 28;
    t.frame();
    const wave = try S.hash(&t);
    s.frame.options.origin = .bottom;
    t.frame();
    try std.testing.expect(wave != try S.hash(&t));
    s.frame.index = 2;
    t.frame();
    const blocks = try S.hash(&t);
    s.frame.options.sweep = .columns;
    t.frame();
    try std.testing.expect(blocks != try S.hash(&t));
}

test "offscreen, reduced motion and temporarily absent indicators stop their clocks" {
    const S = struct {
        busy: loading.Indicator = .{},
        show: bool = true,
        y: f32 = 0,
        fn view(s: *@This(), c: *ui.Context) void {
            const box = ui.div(c).size(40, 40).clip().absolute().offset(0, s.y);
            defer box.end();
            if (s.show) _ = s.busy.show(c, .ring, .{});
        }
    };
    var s: S = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&s, S.view), .{ .width = 100, .height = 100, .scale = 1 });
    defer t.deinit();
    t.advance(0.1);
    ui.motion.setReducedMotion(&t.ctx, true);
    t.settle(1);
    try std.testing.expect(!t.ctx.animating);
    const reduced = s.busy.seconds;
    t.advance(0.1);
    try std.testing.expectEqual(reduced, s.busy.seconds);
    ui.motion.setReducedMotion(&t.ctx, false);
    s.y = 200;
    t.settle(1);
    try std.testing.expect(!t.ctx.animating);
    const hidden = s.busy.seconds;
    t.advance(0.1);
    try std.testing.expectEqual(hidden, s.busy.seconds);
    s.show = false;
    t.advance(0.1);
    s.show = true;
    s.y = 0;
    t.frame();
    try std.testing.expectEqual(hidden, s.busy.seconds);
    t.advance(0.1);
    try std.testing.expect(s.busy.seconds > hidden);
}
