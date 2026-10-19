//! A little game in native UI: walk with D/A or the arrows (or a gamepad's
//! left stick and d-pad), pick up the coins; the camera follows. Steps are
//! fixed, 60 a second; drawing places the player between its last two
//! positions. Keys typed come as taps (myzig's ui reports presses, not
//! releases), so each press moves a step's worth; a gamepad's stick moves
//! smoothly.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const game = @import("game");
const gamepad = @import("gamepad");

const World = struct {
    x: f32 = 0,
    y: f32 = 0,
    px: f32 = 0,
    py: f32 = 0,
    coins: [6][2]f32 = .{ .{ 60, 0 }, .{ 120, -40 }, .{ 180, 30 }, .{ -80, 20 }, .{ 240, 0 }, .{ 300, -30 } },
    taken: [6]bool = @splat(false),
    score: u32 = 0,
    steps: u64 = 0,
    pads: gamepad.Pads = .{},
    cam: game.Camera = .{ .zoom = 2 },

    pub fn update(w: *World, in: *game.Input) void {
        w.steps += 1;
        w.px = w.x;
        w.py = w.y;
        const speed: f32 = 12;
        if (in.down(.d) or in.down(.right)) w.x += speed;
        if (in.down(.a) or in.down(.left)) w.x -= speed;
        if (in.down(.w) or in.down(.up)) w.y -= speed;
        if (in.down(.s) or in.down(.down)) w.y += speed;
        // Gamepads, looked for at most once a second of game time.
        w.pads.update(@as(f64, @floatFromInt(w.steps)) / game.default_rate);
        for (w.pads.list()) |p| {
            const sx, const sy = p.state.leftStick();
            w.x += sx * 3;
            w.y += sy * 3;
            if (p.state.pressed(.right)) w.x += 3;
            if (p.state.pressed(.left)) w.x -= 3;
        }
        for (w.coins, &w.taken) |c, *t| {
            if (!t.* and @abs(c[0] - w.x) < 12 and @abs(c[1] - w.y) < 12) {
                t.* = true;
                w.score += 1;
            }
        }
        // The camera eases toward the player.
        w.cam.x += (w.x - w.cam.x) * 0.1;
        w.cam.y += (w.y - w.cam.y) * 0.1;
    }

    pub fn draw(w: *World, c: *ui.Context, size: ui.Size, alpha: f32) void {
        const view: ui.Rect = .{ .w = size.w, .h = size.h };
        game.fill(c, view, .hex(0x1d2b3a));
        // The ground's tiles, only those in view.
        const vis = w.cam.visible(view, c.scale);
        var tx = @floor(vis.x / 40) * 40;
        while (tx < vis.x + vis.w) : (tx += 40) {
            var ty = @floor(vis.y / 40) * 40;
            while (ty < vis.y + vis.h) : (ty += 40) {
                const dark = @mod(@as(i64, @intFromFloat(tx / 40)) + @as(i64, @intFromFloat(ty / 40)), 2) == 0;
                if (w.cam.rect(view, c.scale, .{ .x = tx, .y = ty, .w = 40, .h = 40 })) |r| game.fill(c, r, if (dark) .hex(0x22364a) else .hex(0x26405a));
            }
        }
        for (w.coins, w.taken) |coin, t| if (!t) {
            if (w.cam.rect(view, c.scale, .{ .x = coin[0] - 4, .y = coin[1] - 4, .w = 8, .h = 8 })) |r| game.rounded(c, r, .hex(0xffd54f), r.w / 2);
        };
        const x = w.px + (w.x - w.px) * alpha;
        const y = w.py + (w.y - w.py) * alpha;
        if (w.cam.rect(view, c.scale, .{ .x = x - 6, .y = y - 6, .w = 12, .h = 12 })) |r| game.rounded(c, r, .hex(0x80cbc4), 3);
    }
};

const State = struct {
    world: World = .{},
    runner: game.Runner = .{},

    fn build(s: *State, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill });
        game.view(c, &s.world, &s.runner);
        ui.textf(c, .{}, "Coins: {d} of 6   pads: {d}", .{ s.world.score, s.world.pads.list().len });
        ui.end(c);
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Game" });
    defer app.destroy();
    var state: State = .{};
    defer state.world.pads.deinit();
    _ = try app.newWindow(.{
        .title = "Game",
        .width = 640,
        .height = 400,
        .content = .{ .view = .init(&state, State.build) },
    });
    try app.run();
}
