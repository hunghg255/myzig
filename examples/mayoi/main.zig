//! Mayoi's street, after mygo's examples/mayoi (a survivor game after the
//! anime BanG Dream! It's MyGO!!!!!): Tomori, lost on a street at night,
//! holds out against stage fright. Here the street, Tomori, the beat of
//! her song and the fright's static are one shader (`street.zsl`), drawn
//! by any renderer, in the world's pixels; arrows or WASD walk, Space
//! sings, which pushes the static back. (The whole game, its enemies, its
//! band and its sound, is mygo's; this is its look, in a shader.)
//!
//!     zig build run-mayoi
//!     zig-out/bin/mayoi --myzig-snapshot=/tmp/mayoi.png --myzig-script="wait:3"
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

pub const street = ui.shader.compile("mayoi-street", @embedFile("street.zsl"));

const white: ui.Color = .{ .r = 1, .g = 0.97, .b = 0.92 };
const muted: ui.Color = .{ .r = 0.8, .g = 0.78, .b = 0.9, .a = 0.75 };

/// Walking speed, in the world's pixels a second; how fast the fright
/// grows, and how much a song takes back.
const speed = 60.0;
const dread = 0.04;
const relief = 0.18;

pub const Street = struct {
    x: f32 = 0,
    y: f32 = 0,
    facing: f32 = 1,
    step: f32 = 0,
    fright: f32 = 0.25,
    /// When she last sang, on the game's clock.
    sang: f64 = -10,
    now: f64 = 0,
    last: ?f64 = null,
    /// The keys held: left, right, up, down.
    held: [4]bool = @splat(false),
    zoom: f32 = 3,

    pub fn view(s: *Street, c: *ui.Context) void {
        const dt: f64 = if (s.last) |l| @min(@max(c.time - l, 0), 0.1) else 0;
        s.last = c.time;
        c.wants_keys = true;
        s.keys(c);
        s.update(@floatCast(dt));
        c.animationFrame();

        const beat: f32 = @floatCast(s.now - s.sang);
        _ = ui.shaderBox(c, &street, .{
            .time = @as(f32, @floatCast(s.now)),
            .cam = [2]f32{ s.x, s.y },
            .zoom = s.zoom,
            .fright = s.fright,
            .beat = beat,
            .facing = s.facing,
            .step = s.step,
        }, .{ .width = .fill, .height = .fill, .padding = .all(20), .gap = 4 });
        defer c.end();
        ui.text(c, "Mayoi", .{ .size = 26, .weight = .bold, .color = white });
        ui.textf(c, .{ .size = 13, .color = muted }, "Fright {d:.0}%", .{s.fright * 100});
        ui.spacer(c);
        ui.text(c, "Arrows or WASD walk · Space sings", .{ .size = 12, .color = muted });
    }

    fn keys(s: *Street, c: *ui.Context) void {
        const S = ui.Shortcut;
        inline for (.{ .{ c.input.key_down, true }, .{ c.input.key_up, false } }) |e| {
            if (e[0]) |k| {
                const i: ?usize = switch (k) {
                    'a', S.left => 0,
                    'd', S.right => 1,
                    'w', S.up => 2,
                    's', S.down => 3,
                    else => null,
                };
                if (i) |n| s.held[n] = e[1];
                if (e[1] and k == ' ') s.sing();
            }
        }
    }

    pub fn sing(s: *Street) void {
        s.sang = s.now;
        s.fright = @max(0, s.fright - relief);
    }

    /// A step of the game: she walks where the keys say, and the fright grows.
    pub fn update(s: *Street, dt: f32) void {
        s.now += dt;
        var dx: f32 = 0;
        var dy: f32 = 0;
        if (s.held[0]) dx -= 1;
        if (s.held[1]) dx += 1;
        if (s.held[2]) dy -= 1;
        if (s.held[3]) dy += 1;
        if (dx != 0 or dy != 0) {
            const len = @sqrt(dx * dx + dy * dy);
            s.x += dx / len * speed * dt;
            s.y += dy / len * speed * dt;
            if (dx != 0) s.facing = std.math.sign(dx);
            s.step = @mod(s.step + dt * 4, 1);
        } else s.step = 0;
        s.fright = @min(1, s.fright + dread * dt);
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Mayoi" });
    defer app.destroy();
    var state: Street = .{};
    _ = try app.newWindow(.{
        .title = "Mayoi",
        .width = 800,
        .height = 500,
        .content = .{ .view = .init(&state, Street.view) },
    });
    try app.run();
}

test "she walks, the fright grows, a song pushes it back" {
    var s: Street = .{};
    s.held[1] = true;
    for (0..60) |_| s.update(1.0 / 60.0);
    try std.testing.expectApproxEqAbs(@as(f32, 60), s.x, 0.01);
    try std.testing.expect(s.fright > 0.25);
    const f = s.fright;
    s.sing();
    try std.testing.expectApproxEqAbs(f - relief, s.fright, 1e-6);
}

test "the street draws: her lamp's light, the static at the edges" {
    const gpa = std.testing.allocator;
    var s: Street = .{ .fright = 0.8 };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Street.view), .{ .width = 200, .height = 120, .scale = 1 });
    defer t.deinit();
    t.frame();
    try std.testing.expect(t.hasText("Mayoi"));
    const px = try t.render(gpa);
    defer px.deinit(gpa);
    const luma = struct {
        fn f(p: anytype, x: usize, y: usize) u32 {
            const b = p.bytes[(y * p.width + x) * 4 ..][0..4];
            return @as(u32, b[0]) + b[1] + b[2];
        }
    }.f;
    // Static grays at the edge, brighter than the night; lit near her.
    var edge: u32 = 0;
    for (0..120) |y| edge = @max(edge, luma(px, 1, y));
    try std.testing.expect(edge > 300);
    try std.testing.expect(luma(px, 100, 52) > luma(px, 60, 100));
}
