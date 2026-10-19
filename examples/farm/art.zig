//! The farm's art: each tile, crop, the farmer and the toolbar's icons as
//! a few rectangles in a 16-unit cell, drawn through the camera and tinted
//! by the hour. (mygo's farm draws pixel art from a sprite sheet; myzig
//! has no image regions yet, so the cells are drawn as boxes.)
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const game = @import("game");

pub const cell = 16;

/// A rectangle of a cell, in its units, and its color; `round` rounds it
/// into a pill or a disc.
const R = struct { x: u8, y: u8, w: u8, h: u8, color: u24, round: bool = false };

pub const Kind = enum {
    grass,
    grass2,
    flowers,
    path,
    soil,
    wet_soil,
    water0,
    water1,
    seed,
    sprout,
    growing,
    ripe,
    tree_trunk,
    tree_top,
    bush,
    rock,
    fence,
    frame,
    hoe,
    seeds,
    can,
    coin,
};

fn sprite(k: Kind) []const R {
    return switch (k) {
        .grass => &.{.{ .x = 0, .y = 0, .w = 16, .h = 16, .color = 0x5fa83a }},
        .grass2 => &.{ .{ .x = 0, .y = 0, .w = 16, .h = 16, .color = 0x5fa83a }, .{ .x = 3, .y = 4, .w = 1, .h = 3, .color = 0x4b8f2c }, .{ .x = 5, .y = 5, .w = 1, .h = 2, .color = 0x4b8f2c }, .{ .x = 11, .y = 10, .w = 1, .h = 3, .color = 0x4b8f2c }, .{ .x = 13, .y = 11, .w = 1, .h = 2, .color = 0x4b8f2c } },
        .flowers => &.{ .{ .x = 0, .y = 0, .w = 16, .h = 16, .color = 0x5fa83a }, .{ .x = 4, .y = 4, .w = 2, .h = 2, .color = 0xffe066 }, .{ .x = 11, .y = 6, .w = 2, .h = 2, .color = 0xff7aa2 }, .{ .x = 7, .y = 11, .w = 2, .h = 2, .color = 0xffffff } },
        .path => &.{ .{ .x = 0, .y = 0, .w = 16, .h = 16, .color = 0xc9a46a }, .{ .x = 3, .y = 3, .w = 2, .h = 1, .color = 0xb08950 }, .{ .x = 10, .y = 8, .w = 2, .h = 1, .color = 0xb08950 }, .{ .x = 6, .y = 13, .w = 2, .h = 1, .color = 0xb08950 } },
        .soil => &.{ .{ .x = 0, .y = 0, .w = 16, .h = 16, .color = 0x8a5a33 }, .{ .x = 1, .y = 3, .w = 14, .h = 1, .color = 0x744a29 }, .{ .x = 1, .y = 8, .w = 14, .h = 1, .color = 0x744a29 }, .{ .x = 1, .y = 13, .w = 14, .h = 1, .color = 0x744a29 } },
        .wet_soil => &.{ .{ .x = 0, .y = 0, .w = 16, .h = 16, .color = 0x5e3b22 }, .{ .x = 1, .y = 3, .w = 14, .h = 1, .color = 0x4c2f1b }, .{ .x = 1, .y = 8, .w = 14, .h = 1, .color = 0x4c2f1b }, .{ .x = 1, .y = 13, .w = 14, .h = 1, .color = 0x4c2f1b } },
        .water0 => &.{ .{ .x = 0, .y = 0, .w = 16, .h = 16, .color = 0x3a8fd6 }, .{ .x = 2, .y = 4, .w = 5, .h = 1, .color = 0x6fb5ec }, .{ .x = 9, .y = 10, .w = 5, .h = 1, .color = 0x6fb5ec } },
        .water1 => &.{ .{ .x = 0, .y = 0, .w = 16, .h = 16, .color = 0x3a8fd6 }, .{ .x = 4, .y = 5, .w = 5, .h = 1, .color = 0x6fb5ec }, .{ .x = 7, .y = 11, .w = 5, .h = 1, .color = 0x6fb5ec } },
        .seed => &.{ .{ .x = 5, .y = 7, .w = 2, .h = 2, .color = 0xe8d27a, .round = true }, .{ .x = 9, .y = 9, .w = 2, .h = 2, .color = 0xe8d27a, .round = true } },
        .sprout => &.{ .{ .x = 7, .y = 8, .w = 2, .h = 5, .color = 0x7ccf4a }, .{ .x = 5, .y = 7, .w = 3, .h = 2, .color = 0x9be36a, .round = true }, .{ .x = 8, .y = 6, .w = 3, .h = 2, .color = 0x9be36a, .round = true } },
        .growing => &.{ .{ .x = 7, .y = 4, .w = 2, .h = 10, .color = 0x4fae34 }, .{ .x = 3, .y = 6, .w = 5, .h = 3, .color = 0x6cc94a, .round = true }, .{ .x = 8, .y = 3, .w = 5, .h = 3, .color = 0x6cc94a, .round = true }, .{ .x = 8, .y = 9, .w = 5, .h = 3, .color = 0x6cc94a, .round = true } },
        .ripe => &.{ .{ .x = 7, .y = 4, .w = 2, .h = 10, .color = 0x4fae34 }, .{ .x = 3, .y = 6, .w = 5, .h = 3, .color = 0x6cc94a, .round = true }, .{ .x = 8, .y = 8, .w = 5, .h = 3, .color = 0x6cc94a, .round = true }, .{ .x = 5, .y = 2, .w = 6, .h = 6, .color = 0xff6b35, .round = true }, .{ .x = 7, .y = 3, .w = 2, .h = 1, .color = 0xffb38a } },
        .tree_trunk => &.{.{ .x = 6, .y = 6, .w = 4, .h = 10, .color = 0x7a4e2b }},
        .tree_top => &.{ .{ .x = 1, .y = 1, .w = 14, .h = 14, .color = 0x2f7d32, .round = true }, .{ .x = 4, .y = 3, .w = 5, .h = 4, .color = 0x43a047, .round = true } },
        .bush => &.{ .{ .x = 2, .y = 5, .w = 12, .h = 10, .color = 0x3f9b3f, .round = true }, .{ .x = 5, .y = 7, .w = 3, .h = 3, .color = 0x55b555, .round = true } },
        .rock => &.{ .{ .x = 3, .y = 7, .w = 10, .h = 8, .color = 0x8d8d95, .round = true }, .{ .x = 5, .y = 8, .w = 4, .h = 2, .color = 0xb5b5bd, .round = true } },
        .fence => &.{ .{ .x = 2, .y = 4, .w = 2, .h = 12, .color = 0xb88a56 }, .{ .x = 12, .y = 4, .w = 2, .h = 12, .color = 0xb88a56 }, .{ .x = 0, .y = 6, .w = 16, .h = 2, .color = 0xd2a66e }, .{ .x = 0, .y = 11, .w = 16, .h = 2, .color = 0xd2a66e } },
        .frame => &.{ .{ .x = 0, .y = 0, .w = 16, .h = 1, .color = 0xfff36a }, .{ .x = 0, .y = 15, .w = 16, .h = 1, .color = 0xfff36a }, .{ .x = 0, .y = 0, .w = 1, .h = 16, .color = 0xfff36a }, .{ .x = 15, .y = 0, .w = 1, .h = 16, .color = 0xfff36a } },
        .hoe => &.{ .{ .x = 7, .y = 3, .w = 2, .h = 12, .color = 0xb88a56 }, .{ .x = 4, .y = 2, .w = 8, .h = 3, .color = 0x9aa3ad } },
        .seeds => &.{ .{ .x = 3, .y = 4, .w = 10, .h = 11, .color = 0xd9b77a, .round = true }, .{ .x = 6, .y = 2, .w = 4, .h = 3, .color = 0xb88a56 }, .{ .x = 6, .y = 8, .w = 4, .h = 4, .color = 0x7ccf4a, .round = true } },
        .can => &.{ .{ .x = 3, .y = 6, .w = 9, .h = 8, .color = 0x5aa0d8, .round = true }, .{ .x = 11, .y = 5, .w = 4, .h = 2, .color = 0x5aa0d8 }, .{ .x = 5, .y = 3, .w = 5, .h = 2, .color = 0x3f7fb5 } },
        .coin => &.{ .{ .x = 2, .y = 2, .w = 12, .h = 12, .color = 0xffc83d, .round = true }, .{ .x = 5, .y = 5, .w = 6, .h = 6, .color = 0xffe08a, .round = true } },
    };
}

fn tinted(color: u24, tint: ui.Color) ui.Color {
    const c = ui.Color.hex(color);
    return .{ .r = c.r * tint.r, .g = c.g * tint.g, .b = c.b * tint.b };
}

/// Draws `k` in the world's cell at (x, y) (world units), through `cam`.
pub fn draw(c: *ui.Context, cam: game.Camera, view: ui.Rect, k: Kind, x: f32, y: f32, tint: ui.Color) void {
    for (sprite(k)) |r| {
        const world: ui.Rect = .{ .x = x + @as(f32, @floatFromInt(r.x)), .y = y + @as(f32, @floatFromInt(r.y)), .w = @floatFromInt(r.w), .h = @floatFromInt(r.h) };
        const s = cam.rect(view, c.scale, world) orelse continue;
        if (r.round) game.rounded(c, s, tinted(r.color, tint), @min(s.w, s.h) / 2) else game.fill(c, s, tinted(r.color, tint));
    }
}

/// Draws `k` at a rect of the screen (the HUD's icons).
pub fn drawAt(c: *ui.Context, k: Kind, at: ui.Rect) void {
    const u = at.w / cell;
    for (sprite(k)) |r| {
        const s: ui.Rect = .{ .x = at.x + @as(f32, @floatFromInt(r.x)) * u, .y = at.y + @as(f32, @floatFromInt(r.y)) * u, .w = @as(f32, @floatFromInt(r.w)) * u, .h = @as(f32, @floatFromInt(r.h)) * u };
        if (r.round) game.rounded(c, s, .hex(r.color), @min(s.w, s.h) / 2) else game.fill(c, s, .hex(r.color));
    }
}

/// The farmer at `x, y` (the cell's top left), facing `dir` (0 down, 1 up,
/// 2 left, 3 right), in walking frame `frame` (0 standing, 1 and 2 steps).
pub fn farmer(c: *ui.Context, cam: game.Camera, view: ui.Rect, x: f32, y: f32, dir: u2, frame: u2, tint: ui.Color) void {
    const lift: [3][2]u8 = .{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 } };
    const l = lift[frame];
    const side = dir >= 2;
    const parts = [_]R{
        // Legs, one up a step as they walk.
        .{ .x = 5, .y = 12 - l[0], .w = 2, .h = 3, .color = 0x5a3d2b },
        .{ .x = 9, .y = 12 - l[1], .w = 2, .h = 3, .color = 0x5a3d2b },
        // The shirt, the head and the hat.
        .{ .x = 4, .y = 7, .w = 8, .h = 6, .color = 0x3d6fd1, .round = true },
        .{ .x = 5, .y = 2, .w = 6, .h = 6, .color = 0xf2c9a0, .round = true },
        .{ .x = 3, .y = 1, .w = 10, .h = 2, .color = 0xd8b04a },
        .{ .x = 5, .y = 0, .w = 6, .h = 2, .color = 0xd8b04a },
    };
    for (parts) |r| draw1(c, cam, view, x, y, r, tint, false);
    // The eyes: two facing the viewer, one to the side, none from behind.
    switch (dir) {
        0 => {
            draw1(c, cam, view, x, y, .{ .x = 6, .y = 4, .w = 1, .h = 1, .color = 0x2b1d14 }, tint, false);
            draw1(c, cam, view, x, y, .{ .x = 9, .y = 4, .w = 1, .h = 1, .color = 0x2b1d14 }, tint, false);
        },
        1 => {},
        else => draw1(c, cam, view, x, y, .{ .x = 10, .y = 4, .w = 1, .h = 1, .color = 0x2b1d14 }, tint, side and dir == 2),
    }
}

fn draw1(c: *ui.Context, cam: game.Camera, view: ui.Rect, x: f32, y: f32, r: R, tint: ui.Color, flip: bool) void {
    const rx: f32 = if (flip) @floatFromInt(cell - @as(u16, r.x) - r.w) else @floatFromInt(r.x);
    const world: ui.Rect = .{ .x = x + rx, .y = y + @as(f32, @floatFromInt(r.y)), .w = @floatFromInt(r.w), .h = @floatFromInt(r.h) };
    const s = cam.rect(view, c.scale, world) orelse return;
    if (r.round) game.rounded(c, s, tinted(r.color, tint), @min(s.w, s.h) / 2) else game.fill(c, s, tinted(r.color, tint));
}
