//! Motion through `ui.Tester`, whose clock the tests advance: springs and
//! curves, colors, keyframes, timelines, poses, and transitions of boxes
//! as the layout moves them, as they come and as they go, with less motion
//! too, and the pointer following what moves.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const motion = @import("motion.zig");

const red: types.Color = .hex(0xe0401a);
const blue: types.Color = .hex(0x1a4ce0);

/// A box at x = `s.x`, animated as `s.anim` says; `s.shown` what it showed.
const Slide = struct {
    target: f32 = 0,
    anim: motion.Animation = .snappy,
    shown: f32 = 0,
    arrived: u32 = 0,
    fn view(s: *Slide, c: *ui.Context) void {
        _ = c.open(.{ .width = .fill, .height = .fill }, null);
        defer c.end();
        const id = c.peekId("card");
        s.shown = motion.animateTo(c, id, "x", s.target, s.anim);
        if (motion.arrived(c, id, "x")) s.arrived += 1;
        _ = c.open(.{ .width = .{ .px = 40 }, .height = .{ .px = 40 }, .background = red, .transform = .translation(s.shown, 0) }, "card");
        c.end();
    }
};

fn tester(t: *ui.Tester, state: anytype, comptime view: anytype) !void {
    try t.init(testing.allocator, .init(state, view), .{ .width = 300, .height = 200, .scale = 1 });
}

test "a spring goes to its target over frames, arrives once, and draws no frame at rest" {
    var s: Slide = .{};
    var t: ui.Tester = undefined;
    try tester(&t, &s, Slide.view);
    defer t.deinit();
    try testing.expect(!t.ctx.animating);
    s.target = 200;
    t.frame();
    try testing.expect(t.ctx.animating);
    t.advance(0.1);
    try testing.expect(s.shown > 20 and s.shown < 200);
    t.settle(3);
    try testing.expectEqual(@as(f32, 200), s.shown);
    try testing.expectEqual(@as(u32, 1), s.arrived);
    try testing.expect(!t.ctx.animating);
    // Turned around mid-way, it keeps going for a while.
    s.target = 0;
    t.advance(0.05);
    const v = s.shown;
    s.target = 200;
    t.advance(0.05);
    try testing.expect(s.shown < v + 1);
}

test "a curve follows its easing over its duration; less motion goes at once" {
    var s: Slide = .{ .anim = .curve(1, .linear) };
    var t: ui.Tester = undefined;
    try tester(&t, &s, Slide.view);
    defer t.deinit();
    t.dt = 0.25;
    s.target = 100;
    t.frame();
    t.frame();
    t.frame();
    // Two steps of a quarter second since it set off: half way.
    try testing.expectApproxEqAbs(@as(f32, 50), s.shown, 0.01);
    t.settle(2);
    try testing.expectEqual(@as(f32, 100), s.shown);
    motion.setReducedMotion(&t.ctx, true);
    s.target = 0;
    t.frame();
    try testing.expectEqual(@as(f32, 0), s.shown);
    try testing.expect(!t.ctx.animating);
}

test "colors mix premultiplied: one fading in from transparent keeps its hue" {
    const Fade = struct {
        to: types.Color = types.Color.transparent,
        shown: types.Color = .{},
        fn view(s: *@This(), c: *ui.Context) void {
            s.shown = motion.animateColor(c, 7, "bg", s.to, .curve(1, .linear));
        }
    };
    var s: Fade = .{};
    var t: ui.Tester = undefined;
    try tester(&t, &s, Fade.view);
    defer t.deinit();
    s.to = red;
    t.dt = 0.5;
    t.frame();
    t.frame();
    try testing.expectApproxEqAbs(red.r, s.shown.r, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.5), s.shown.a, 1e-4);
}

test "keyframes play in turn, hold the last, and play again from the value shown" {
    const Shake = struct {
        on: bool = false,
        run: u64 = 0,
        shown: f32 = 0,
        fn view(s: *@This(), c: *ui.Context) void {
            if (!s.on) return;
            s.shown = motion.keyframes(c, 1, "shake", &.{
                .{ .value = 0 },
                .{ .at = 0.2, .value = 100 },
                .{ .at = 0.6, .value = 20, .ease = .ease_in },
            }, .{ .run = s.run });
        }
    };
    var s: Shake = .{};
    var t: ui.Tester = undefined;
    try tester(&t, &s, Shake.view);
    defer t.deinit();
    t.dt = 0.1;
    s.on = true;
    t.frame();
    try testing.expectEqual(@as(f32, 0), s.shown);
    t.frame();
    try testing.expectApproxEqAbs(@as(f32, 50), s.shown, 0.01);
    t.advance(0.3);
    try testing.expect(s.shown < 100 and s.shown > 20);
    t.settle(2);
    try testing.expectEqual(@as(f32, 20), s.shown);
    s.run = 1;
    t.frame();
    // From 20, where it was, toward 100.
    try testing.expectApproxEqAbs(@as(f32, 20), s.shown, 0.01);
    t.frame();
    try testing.expectApproxEqAbs(@as(f32, 60), s.shown, 0.01);
}

test "a timeline places tweens after, with and at labels; pauses, reverses and seeks" {
    const Intro = struct {
        o: motion.TimelineOptions = .{},
        x: f32 = 0,
        fade: f32 = 0,
        row: f32 = 0,
        duration: f32 = 0,
        settled: bool = false,
        arrived: u32 = 0,
        on: bool = false,
        fn view(s: *@This(), c: *ui.Context) void {
            if (!s.on) return;
            var tl = motion.timeline(c, 1, "intro", s.o);
            s.x = tl.tween(.{ .from = -200, .to = 0, .duration = 0.4, .ease = .linear }, .{});
            s.fade = tl.tween(.{ .from = 0, .to = 1, .duration = 0.3, .ease = .linear }, .after(-0.2));
            tl.label("rows", .at(0.1));
            s.row = tl.tween(.{ .from = 0, .to = 1, .duration = 0.2, .ease = .linear }, .atLabel("rows", 0.1));
            s.duration = tl.duration();
            s.settled = tl.settled();
            if (tl.arrived()) s.arrived += 1;
        }
    };
    var s: Intro = .{};
    var t: ui.Tester = undefined;
    try tester(&t, &s, Intro.view);
    defer t.deinit();
    t.dt = 0.1;
    s.on = true;
    t.frame();
    t.advance(0.3);
    // Three frames on: 0.3 s in. The fade started at 0.2, the row at 0.2.
    try testing.expectApproxEqAbs(@as(f32, -50), s.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), s.fade, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.5), s.row, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.5), s.duration, 1e-4);
    // Paused, the playhead holds however long it waits.
    s.o.paused = true;
    t.frame();
    const held = s.fade;
    t.advance(1);
    try testing.expectEqual(held, s.fade);
    try testing.expect(held < 1);
    s.o.paused = false;
    t.settle(2);
    try testing.expect(s.settled);
    try testing.expectEqual(@as(u32, 1), s.arrived);
    try testing.expectEqual(@as(f32, 1), s.fade);
    // Back to the start, the way it came.
    s.o.reverse = true;
    t.advance(0.2);
    try testing.expect(s.fade < 1 and s.fade > 0);
    t.settle(2);
    try testing.expectEqual(@as(f32, -200), s.x);
    // A scrubber puts the playhead where it asks.
    s.o.progress = 0.5;
    t.frame();
    try testing.expectApproxEqAbs(@as(f32, -75), s.x, 0.01);
}

/// Rows of boxes in `s.order`, each with a transition.
const Rows = struct {
    order: []const u8 = "abc",
    t: motion.Transition = .{ .position = true },
    fn view(s: *Rows, c: *ui.Context) void {
        _ = c.open(.{ .width = .fill, .height = .fill, .gap = 10, .padding = .all(10) }, null);
        defer c.end();
        for (s.order) |ch| {
            const box = c.open(.{ .width = .{ .px = 60 }, .height = .{ .px = 20 }, .background = if (ch == 'b') red else blue }, (&[_]u8{ch})[0..1]);
            motion.transition(c, box, s.t);
            c.end();
        }
    }
};

fn redBox(t: *ui.Tester) ?[4]f32 {
    for (t.instances.items) |i| if (@abs(i.color[0] - red.r) < 0.01 and @abs(i.color[2] - red.b) < 0.01) return i.rect;
    return null;
}

test "a box the layout moves slides from where it was, and the pointer follows it" {
    var s: Rows = .{};
    var t: ui.Tester = undefined;
    try tester(&t, &s, Rows.view);
    defer t.deinit();
    t.frame();
    // b is second, at y = 40; moved first, its layout puts it at y = 10.
    try testing.expectEqual(@as(f32, 40), redBox(&t).?[1]);
    s.order = "bac";
    t.frame();
    try testing.expectApproxEqAbs(@as(f32, 40), redBox(&t).?[1], 0.5);
    t.advance(0.1);
    const mid = redBox(&t).?[1];
    try testing.expect(mid > 10 and mid < 40);
    t.settle(1);
    try testing.expectEqual(@as(f32, 10), redBox(&t).?[1]);
    try testing.expect(!t.ctx.animating);
}

test "a box comes in from its enter, in a parent already there, and goes to its exit taking no room" {
    var s: Rows = .{ .order = "ac", .t = .{ .enter = .{ .y = 10 }, .exit = .{ .opacity = 0 } } };
    var t: ui.Tester = undefined;
    try tester(&t, &s, Rows.view);
    defer t.deinit();
    t.frame();
    s.order = "abc";
    t.frame();
    // It starts transparent (not drawn), 10 lower; on its way, half there.
    try testing.expect(redBox(&t) == null);
    t.advance(0.05);
    const mid = redBox(&t) orelse return error.NoBox;
    try testing.expect(mid[1] > 40 and mid[1] < 50);
    var alpha: f32 = 1;
    for (t.instances.items) |i| if (@abs(i.color[0] - red.r) < 0.01 and @abs(i.color[2] - red.b) < 0.01) {
        alpha = i.color[3];
    };
    try testing.expect(alpha > 0 and alpha < 1);
    t.settle(1);
    try testing.expectEqual(@as(f32, 40), redBox(&t).?[1]);
    // Gone: its copy fades where it was, and c moves up at once.
    s.order = "ac";
    t.frame();
    try testing.expect(redBox(&t) != null);
    var c_y: f32 = 0;
    for (t.ctx.nodes.items) |n| if (n.style.background) |bg| if (n.id != 0 and std.meta.eql(bg, blue) and n.rect.y > 20) {
        c_y = n.rect.y;
    };
    try testing.expectEqual(@as(f32, 40), c_y);
    t.settle(1);
    try testing.expect(redBox(&t) == null);
    try testing.expect(!t.ctx.animating);
    try testing.expectEqual(@as(usize, 0), t.ctx.motion.exiting);
}

test "a page showing all at once does not animate its boxes in; less motion fades in place" {
    const Page = struct {
        shown: bool = false,
        fn view(s: *@This(), c: *ui.Context) void {
            _ = c.open(.{ .width = .fill, .height = .fill }, null);
            defer c.end();
            if (!s.shown) return;
            _ = c.open(.{ .padding = .all(10) }, "page");
            defer c.end();
            const box = c.open(.{ .width = .{ .px = 60 }, .height = .{ .px = 20 }, .background = red }, "b");
            motion.transition(c, box, .{ .enter = .{ .x = 30 } });
            c.end();
        }
    };
    var s: Page = .{};
    var t: ui.Tester = undefined;
    try tester(&t, &s, Page.view);
    defer t.deinit();
    s.shown = true;
    t.frame();
    try testing.expectEqual(@as(f32, 10), redBox(&t).?[0]);
    try testing.expect(!t.ctx.animating);
}

test "a pose moves, scales and fades a box after its own transform" {
    const Lift = struct {
        up: bool = false,
        fn view(s: *@This(), c: *ui.Context) void {
            _ = c.open(.{ .width = .fill, .height = .fill, .padding = .all(20) }, null);
            defer c.end();
            const box = c.open(.{ .width = .{ .px = 40 }, .height = .{ .px = 40 }, .background = red }, "card");
            motion.pose(c, box, if (s.up) .{ .y = -10, .scale = 2 } else .{}, .curve(0.2, .linear));
            c.end();
        }
    };
    var s: Lift = .{};
    var t: ui.Tester = undefined;
    try tester(&t, &s, Lift.view);
    defer t.deinit();
    s.up = true;
    t.settle(1);
    // Twice as large about its center (40, 40), then 10 up.
    try testing.expectEqual([4]f32{ 0, -10, 80, 80 }, redBox(&t).?);
}

test "the pointer finds a box where its animation draws it" {
    const Card = struct {
        target: f32 = 0,
        clicks: u32 = 0,
        fn view(s: *@This(), c: *ui.Context) void {
            _ = c.open(.{ .width = .fill, .height = .fill }, null);
            defer c.end();
            const id = c.peekId("card");
            const x = motion.animateTo(c, id, "x", s.target, .curve(1, .linear));
            const card = c.open(.{ .width = .{ .px = 40 }, .height = .{ .px = 40 }, .background = red, .transform = .translation(x, 0) }, "card");
            if (c.interact(card, .{}).clicked) s.clicks += 1;
            c.end();
        }
    };
    var s: Card = .{};
    var t: ui.Tester = undefined;
    try tester(&t, &s, Card.view);
    defer t.deinit();
    s.target = 200;
    t.frame();
    t.advance(0.5);
    // About 100 along now (still going): where it was is empty.
    const at = redBox(&t).?[0];
    try testing.expect(at > 80 and at < 120);
    t.ctx.input.mouse = .{ .x = 20, .y = 20 };
    t.ctx.updateHot();
    try testing.expect(t.ctx.hot == 0);
    t.ctx.input.mouse = .{ .x = at + 20, .y = 20 };
    t.ctx.updateHot();
    try testing.expect(t.ctx.hot != 0);
}

test "with less motion a moved box is at once where the layout puts it; its colors still fade" {
    var s: Rows = .{ .t = .{} };
    var t: ui.Tester = undefined;
    try tester(&t, &s, Rows.view);
    defer t.deinit();
    motion.setReducedMotion(&t.ctx, true);
    t.frame();
    s.order = "bac";
    t.frame();
    try testing.expectEqual(@as(f32, 10), redBox(&t).?[1]);
    try testing.expect(!t.ctx.animating);
}
