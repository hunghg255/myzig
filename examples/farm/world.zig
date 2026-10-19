//! The farm's world: its tiles, the farmer, the tools, crops that grow
//! when watered, and the day turning to night, advanced in fixed steps.
const std = @import("std");

/// The map, in tiles.
pub const map_w = 40;
pub const map_h = 30;

pub const Ground = enum(u8) { grass, path, soil, water };
pub const Object = enum(u8) { none, tree, bush, rock, fence };

/// A square of the map: its ground, what stands on it, and the crop
/// growing in its soil.
pub const Tile = struct {
    ground: Ground = .grass,
    /// Of grass: plain, tufts or flowers.
    variant: u8 = 0,
    object: Object = .none,
    /// Watered soil.
    wet: bool = false,
    /// The crop's stage, 0 to ripe, or -1.
    crop: i8 = -1,
    /// When the crop grows next, if wet.
    grows: f64 = 0,
};

pub const ripe = 3;
/// How long a watered crop takes to grow a stage, in seconds.
pub const grow_time = 4.0;
/// How fast the farmer walks, in tiles a second.
pub const speed = 4.5;
/// How long a day lasts, in seconds.
pub const day_length = 150.0;

pub const Dir = enum(u2) { down, up, left, right };
pub const Tool = enum(u2) { hoe, seeds, can };
pub const tool_names = [_][]const u8{ "Hoe", "Seeds", "Watering can" };

/// What happened in a step, for sounds.
pub const Event = enum(u8) { step, till, plant, water, harvest, nothing };

pub const World = struct {
    tiles: [map_h][map_w]Tile = @splat(@splat(.{})),
    /// The farmer, by the middle of their feet, in tiles, and where they
    /// were a step before.
    x: f64 = 20.5,
    y: f64 = 15.8,
    px: f64 = 20.5,
    py: f64 = 15.8,
    facing: Dir = .down,
    moving: bool = false,
    /// Distance walked, for the frames and the footsteps.
    walked: f64 = 0,
    tool: Tool = .hoe,
    coins: u32 = 0,
    /// The directions held, from the keys, and where a gamepad's stick
    /// leans, each from -1 to 1.
    held: [4]bool = @splat(false),
    stick: [2]f64 = .{ 0, 0 },
    /// Simulated time, in seconds.
    now: f64 = 0,
    events: [16]Event = undefined,
    event_count: usize = 0,

    /// A field of grass with a pond, a path, trees around it and some
    /// bushes and rocks, and the farmer by the middle.
    pub fn init() World {
        var w: World = .{};
        var prng: std.Random.DefaultPrng = .init(7);
        const r = prng.random();
        for (&w.tiles, 0..) |*row, y| for (row, 0..) |*t, x| {
            const v = r.uintLessThan(u8, 10);
            t.variant = if (v < 2) 1 else if (v < 3) 2 else 0;
            if (x < 2 or y < 2 or x >= map_w - 2 or y >= map_h - 2) t.object = .tree;
        };
        // A pond.
        for (5..10) |y| for (27..35) |x| {
            const dx = @as(f64, @floatFromInt(x)) - 30.5;
            const dy = @as(f64, @floatFromInt(y)) - 7;
            if (dx * dx / 16 + dy * dy / 6 < 1) w.tiles[y][x].ground = .water;
        };
        // A path from the south edge to the middle.
        for (16..map_h - 2) |y| {
            w.tiles[y][20].ground = .path;
            w.tiles[y][21].ground = .path;
        }
        // A fence along the field's north side, with a gap.
        for (8..18) |x| if (x != 12) {
            w.tiles[11][x].object = .fence;
        };
        for (0..25) |_| {
            const x = 2 + r.uintLessThan(usize, map_w - 4);
            const y = 2 + r.uintLessThan(usize, map_h - 4);
            const t = &w.tiles[y][x];
            if (t.ground == .grass and t.object == .none and (x < 18 or x > 23)) t.object = if (r.boolean()) .bush else .rock;
        }
        return w;
    }

    fn emit(w: *World, e: Event) void {
        if (w.event_count < w.events.len) {
            w.events[w.event_count] = e;
            w.event_count += 1;
        }
    }

    /// Whether the farmer can't stand on tile (x, y).
    fn solid(w: *const World, x: i64, y: i64) bool {
        if (x < 0 or y < 0 or x >= map_w or y >= map_h) return true;
        const t = w.tiles[@intCast(y)][@intCast(x)];
        return t.ground == .water or t.object != .none;
    }

    /// Whether the farmer's feet, a box 0.6 by 0.3 tiles, overlap a solid tile.
    fn blocked(w: *const World, x: f64, y: f64) bool {
        const hw = 0.3;
        const hh = 0.15;
        for ([4][2]f64{ .{ x - hw, y - hh }, .{ x + hw, y - hh }, .{ x - hw, y + hh }, .{ x + hw, y + hh } }) |p| {
            if (w.solid(@intFromFloat(@floor(p[0])), @intFromFloat(@floor(p[1])))) return true;
        }
        return false;
    }

    /// Advances the world by `dt` seconds.
    pub fn step(w: *World, dt: f64) void {
        w.now += dt;
        w.px = w.x;
        w.py = w.y;
        var dx: f64 = 0;
        var dy: f64 = 0;
        if (w.held[@intFromEnum(Dir.left)]) dx -= 1;
        if (w.held[@intFromEnum(Dir.right)]) dx += 1;
        if (w.held[@intFromEnum(Dir.up)]) dy -= 1;
        if (w.held[@intFromEnum(Dir.down)]) dy += 1;
        if (dx != 0 and dy != 0) {
            dx *= std.math.sqrt2 / 2.0;
            dy *= std.math.sqrt2 / 2.0;
        }
        // A gamepad's stick, as far as it leans.
        if (dx == 0 and dy == 0) {
            dx = w.stick[0];
            dy = w.stick[1];
        }
        w.moving = dx != 0 or dy != 0;
        if (w.moving) {
            w.facing = if (@abs(dy) >= @abs(dx)) (if (dy > 0) .down else .up) else if (dx < 0) .left else .right;
            // Each axis on its own, so that the farmer slides along walls.
            const before = w.walked;
            const nx = w.x + dx * speed * dt;
            if (!w.blocked(nx, w.y)) {
                w.walked += @abs(nx - w.x);
                w.x = nx;
            }
            const ny = w.y + dy * speed * dt;
            if (!w.blocked(w.x, ny)) {
                w.walked += @abs(ny - w.y);
                w.y = ny;
            }
            // A footstep every 0.6 tiles.
            if (@floor(w.walked / 0.6) != @floor(before / 0.6)) w.emit(.step);
        }
        for (&w.tiles) |*row| for (row) |*t| {
            if (t.crop >= 0 and t.crop < ripe and t.wet and w.now >= t.grows) {
                t.crop += 1;
                t.wet = false;
            }
        };
    }

    /// The tile in front of the farmer.
    pub fn target(w: *const World) [2]i64 {
        var x: i64 = @intFromFloat(@floor(w.x));
        var y: i64 = @intFromFloat(@floor(w.y));
        switch (w.facing) {
            .down => y += 1,
            .up => y -= 1,
            .left => x -= 1,
            .right => x += 1,
        }
        return .{ x, y };
    }

    /// Uses the tool on the tile in front of the farmer, or harvests a
    /// ripe crop there whatever the tool.
    pub fn use(w: *World) void {
        const xy = w.target();
        if (xy[0] < 0 or xy[1] < 0 or xy[0] >= map_w or xy[1] >= map_h) return w.emit(.nothing);
        const t = &w.tiles[@intCast(xy[1])][@intCast(xy[0])];
        if (t.crop == ripe) {
            t.crop = -1;
            w.coins += 15;
            w.emit(.harvest);
        } else if (w.tool == .hoe and t.ground == .grass and t.object == .none) {
            t.ground = .soil;
            w.emit(.till);
        } else if (w.tool == .seeds and t.ground == .soil and t.crop < 0) {
            t.crop = 0;
            if (t.wet) t.grows = w.now + grow_time;
            w.emit(.plant);
        } else if (w.tool == .can and t.ground == .soil) {
            if (!t.wet) {
                t.wet = true;
                t.grows = w.now + grow_time;
            }
            w.emit(.water);
        } else w.emit(.nothing);
    }

    /// How light it is, from 0 at midnight to 1 by day, and the hour.
    pub fn daylight(w: *const World) struct { f64, u32 } {
        // The game starts at 8 in the morning.
        const t = @mod(w.now / day_length + 8.0 / 24.0, 1);
        const h = t * 24;
        // Dark from 20 to 5, with an hour of dusk and of dawn.
        const light: f64 = if (h >= 21 or h < 5) 0 else if (h >= 20) 21 - h else if (h < 6) h - 5 else 1;
        return .{ light, @intFromFloat(h) };
    }
};

test "the hoe tills, seeds plant, water grows a crop to ripe, and it sells" {
    var w: World = .init();
    w.facing = .down;
    const xy = w.target();
    const t = &w.tiles[@intCast(xy[1])][@intCast(xy[0])];
    t.* = .{};
    w.use();
    try std.testing.expectEqual(Ground.soil, t.ground);
    w.tool = .seeds;
    w.use();
    w.tool = .can;
    w.use();
    for (0..ripe) |_| {
        for (0..@as(usize, @intFromFloat(grow_time * 60)) + 1) |_| w.step(1.0 / 60.0);
        // Watered again after each stage, until it is ripe.
        if (t.crop < ripe) w.use();
    }
    try std.testing.expectEqual(@as(i8, ripe), t.crop);
    w.use();
    try std.testing.expectEqual(@as(u32, 15), w.coins);
}
