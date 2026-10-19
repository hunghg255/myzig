//! A game in a ui.Tester: steps follow the Tester's clock (never the
//! wall's), typed keys reach `update`, and draws land where the game put
//! them.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const game = @import("game");
const testing = std.testing;

const World = struct {
    x: f32 = 10,
    prev_x: f32 = 10,
    jumps: u32 = 0,
    steps: u32 = 0,
    size: ui.Size = .{},

    pub fn update(w: *World, in: *game.Input) void {
        w.steps += 1;
        w.prev_x = w.x;
        if (in.down(.d) or in.down(.right)) w.x += 4;
        if (in.pressed(.space)) w.jumps += 1;
    }

    pub fn draw(w: *World, c: *ui.Context, size: ui.Size, alpha: f32) void {
        w.size = size;
        const x = w.prev_x + (w.x - w.prev_x) * alpha;
        game.fill(c, .{ .x = x, .y = 20, .w = 16, .h = 16 }, .hex(0xff0000));
    }
};

const State = struct {
    world: World = .{},
    runner: game.Runner = .{},

    fn build(s: *State, c: *ui.Context) void {
        game.view(c, &s.world, &s.runner);
    }
};

test "steps run at 60 a second of the Tester's clock; keys reach update; the view fills" {
    var s: State = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, State.build), .{ .width = 320, .height = 200 });
    defer t.deinit();
    // Sixty frames of the Tester (each 1/60 s): sixty steps.
    const before = s.world.steps;
    for (0..60) |_| t.frame();
    try testing.expectEqual(before + 60, s.world.steps);
    try testing.expectEqual(@as(f32, 320), s.world.size.w);
    try testing.expectEqual(@as(f32, 200), s.world.size.h);
    try testing.expect(t.ctx.animating); // a game asks for every frame

    t.typeText("d");
    try testing.expectEqual(@as(f32, 14), s.world.x);
    t.frame();
    try testing.expectEqual(@as(f32, 14), s.world.x); // a tap holds for one step
    t.typeText(" ");
    try testing.expectEqual(@as(u32, 1), s.world.jumps);
    t.key(.right);
    try testing.expectEqual(@as(f32, 18), s.world.x);
}

test "held keys from the platform stay down between frames" {
    var s: State = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, State.build), .{ .width = 320, .height = 200 });
    defer t.deinit();
    s.runner.input.keyDown(.d);
    for (0..10) |_| t.frame();
    try testing.expectEqual(@as(f32, 50), s.world.x);
    s.runner.input.keyUp(.d);
    t.frame();
    try testing.expectEqual(@as(f32, 50), s.world.x);
}

test "keys going down and up from the ui hold between frames, and typed keys no longer tap" {
    var s: State = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, State.build), .{ .width = 320, .height = 200 });
    defer t.deinit();
    try testing.expect(t.ctx.wants_keys);
    t.keyEdge('d', true);
    for (0..9) |_| t.frame();
    try testing.expectEqual(@as(f32, 50), s.world.x);
    // The character the press types too is no second press.
    t.typeText("d");
    try testing.expectEqual(@as(f32, 54), s.world.x);
    t.keyEdge('d', false);
    t.frame();
    try testing.expectEqual(@as(f32, 54), s.world.x);
}

test "a slower game steps at its own rate" {
    const Slow = struct {
        pub const rate = 30;
        n: u32 = 0,
        pub fn update(g: *@This(), _: *game.Input) void {
            g.n += 1;
        }
        pub fn draw(_: *@This(), _: *ui.Context, _: ui.Size, _: f32) void {}
    };
    const S = struct {
        g: Slow = .{},
        r: game.Runner = .{},
        fn build(s: *@This(), c: *ui.Context) void {
            game.view(c, &s.g, &s.r);
        }
    };
    var s: S = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, S.build), .{});
    defer t.deinit();
    const before = s.g.n;
    for (0..60) |_| t.frame();
    try testing.expectEqual(before + 30, s.g.n);
}
