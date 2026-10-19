//! A little farming game in native UI: walk a farm with the keyboard,
//! till the grass, plant seeds, water them and harvest what grows,
//! through a camera that follows you, as days turn to night, with sound
//! and music. The game plugin runs it in fixed steps (`game.view`), and
//! its camera follows the farmer (`game.Camera`). Everything it draws and
//! plays is made by its code.
//!
//! Arrows or WASD walk, Space or E uses the tool (or harvests what is
//! ripe), 1 2 3 or Q choose the tool, Z and X zoom, and M plays or stops
//! the music. With a gamepad: the left stick or the d-pad walks, A uses
//! the tool, the shoulder buttons choose it, and Start plays or stops the
//! music.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const game = @import("game");
const gamepad = @import("gamepad");
const world_mod = @import("world.zig");
const art = @import("art.zig");
const Sounds = @import("sound.zig").Sounds;
const World = world_mod.World;

const cell = art.cell;
/// Pixels of the screen per unit of art, in points.
const zooms = [_]f32{ 2, 2.5, 3, 4, 5 };

const Farm = struct {
    w: World,
    snd: ?*Sounds = null,
    zoom: usize = 1,
    music: bool = true,
    pads: gamepad.Pads = .{},
    /// The first pad's last state, to tell the buttons pressed since.
    pad: gamepad.State = .{},

    fn setMusic(g: *Farm, on: bool) void {
        g.music = on;
        if (g.snd) |s| s.setMusic(on);
    }

    /// Steps the world: the keys and the gamepad walk and act, then what
    /// happened sounds.
    pub fn update(g: *Farm, in: *game.Input) void {
        const w = &g.w;
        w.held = .{
            in.down(.down) or in.down(.s),
            in.down(.up) or in.down(.w),
            in.down(.left) or in.down(.a),
            in.down(.right) or in.down(.d),
        };
        if (in.pressed(.space) or in.pressed(.e) or in.pressed(.enter)) w.use();
        if (in.pressed(.@"1")) w.tool = .hoe;
        if (in.pressed(.@"2")) w.tool = .seeds;
        if (in.pressed(.@"3")) w.tool = .can;
        if (in.pressed(.q) or in.pressed(.tab)) w.tool = @enumFromInt((@intFromEnum(w.tool) + 1) % 3);
        if (in.pressed(.x)) g.zoom = @min(g.zoom + 1, zooms.len - 1);
        if (in.pressed(.z)) g.zoom -|= 1;
        if (in.pressed(.m)) g.setMusic(!g.music);
        g.readPad();
        w.step(1.0 / @as(f64, game.default_rate));
        if (g.snd) |s| s.play(w.events[0..w.event_count]);
        w.event_count = 0;
    }

    /// The first gamepad: its stick or d-pad walks, and its buttons act as
    /// the keys do when just pressed.
    fn readPad(g: *Farm) void {
        g.pads.update(g.w.now);
        const pads = g.pads.list();
        if (pads.len == 0) {
            g.w.stick = .{ 0, 0 };
            g.pad = .{};
            return;
        }
        const s = pads[0].state;
        var xy = s.leftStick();
        if (s.pressed(.left)) xy[0] = -1 else if (s.pressed(.right)) xy[0] = 1;
        if (s.pressed(.up)) xy[1] = -1 else if (s.pressed(.down)) xy[1] = 1;
        const m = @sqrt(xy[0] * xy[0] + xy[1] * xy[1]);
        if (m > 1) xy = .{ xy[0] / m, xy[1] / m };
        g.w.stick = .{ xy[0], xy[1] };
        if (s.justPressed(g.pad, .south)) g.w.use();
        if (s.justPressed(g.pad, .right_shoulder)) g.w.tool = @enumFromInt((@intFromEnum(g.w.tool) + 1) % 3);
        if (s.justPressed(g.pad, .left_shoulder)) g.w.tool = @enumFromInt((@intFromEnum(g.w.tool) + 2) % 3);
        if (s.justPressed(g.pad, .start)) g.setMusic(!g.music);
        g.pad = s;
    }

    /// The color the world takes at the light of the hour: the night is blue.
    fn tint(g: *const Farm) ui.Color {
        const light: f32 = @floatCast(g.w.daylight()[0]);
        return .{ .r = (80 + 175 * light) / 255, .g = (95 + 160 * light) / 255, .b = (160 + 95 * light) / 255 };
    }

    /// Draws the world through a camera that follows the farmer, within
    /// the map, and the HUD over it; `alpha` places the farmer between
    /// their last two steps.
    pub fn draw(g: *Farm, c: *ui.Context, size: ui.Size, alpha: f32) void {
        const w = &g.w;
        const view: ui.Rect = .{ .w = size.w, .h = size.h };
        game.fill(c, view, .hex(0x4b9a2a));
        const a: f64 = alpha;
        const fx: f32 = @floatCast(w.px + (w.x - w.px) * a);
        const fy: f32 = @floatCast(w.py + (w.y - w.py) * a);
        var cam: game.Camera = .{ .zoom = zooms[g.zoom] };
        cam.x = follow(fx * cell, world_mod.map_w * cell, size.w / cam.zoom);
        cam.y = follow(fy * cell, world_mod.map_h * cell, size.h / cam.zoom);
        g.drawWorld(c, cam, view, fx, fy);
        g.drawHud(c, view);
    }

    fn drawWorld(g: *Farm, c: *ui.Context, cam: game.Camera, view: ui.Rect, fx: f32, fy: f32) void {
        const w = &g.w;
        const tint_ = g.tint();
        // Only the tiles in view (and a row below, for what stands tall).
        const vis = cam.visible(view, c.scale);
        const x0: usize = @intFromFloat(std.math.clamp(@floor(vis.x / cell), 0, world_mod.map_w));
        const x1: usize = @intFromFloat(std.math.clamp(@ceil((vis.x + vis.w) / cell), 0, world_mod.map_w));
        const y0: usize = @intFromFloat(std.math.clamp(@floor(vis.y / cell), 0, world_mod.map_h));
        const y1: usize = @intFromFloat(std.math.clamp(@ceil((vis.y + vis.h) / cell) + 1, 0, world_mod.map_h));
        const water: art.Kind = if (@mod(@as(i64, @intFromFloat(w.now * 2)), 2) == 1) .water1 else .water0;
        for (y0..y1) |y| for (x0..x1) |x| {
            const t = w.tiles[y][x];
            const tx: f32 = @floatFromInt(x * cell);
            const ty: f32 = @floatFromInt(y * cell);
            const k: art.Kind = switch (t.ground) {
                .grass => switch (t.variant) {
                    0 => .grass,
                    1 => .grass2,
                    else => .flowers,
                },
                .path => .path,
                .soil => if (t.wet) .wet_soil else .soil,
                .water => water,
            };
            art.draw(c, cam, view, k, tx, ty, tint_);
            if (t.crop >= 0) art.draw(c, cam, view, @enumFromInt(@intFromEnum(art.Kind.seed) + @as(u8, @intCast(t.crop))), tx, ty, tint_);
        };
        // The tile the tool would act on.
        const tg = w.target();
        if (tg[0] >= 0 and tg[1] >= 0 and tg[0] < world_mod.map_w and tg[1] < world_mod.map_h)
            art.draw(c, cam, view, .frame, @floatFromInt(tg[0] * cell), @floatFromInt(tg[1] * cell), .white);
        // What stands, row by row, the farmer among them: what stands
        // south of another covers it.
        const feet: usize = @intFromFloat(@max(0, @floor(fy)));
        for (y0..y1) |y| {
            for (x0..x1) |x| {
                const tx: f32 = @floatFromInt(x * cell);
                const ty: f32 = @floatFromInt(y * cell);
                switch (w.tiles[y][x].object) {
                    .none => {},
                    .tree => {
                        art.draw(c, cam, view, .tree_trunk, tx, ty, tint_);
                        art.draw(c, cam, view, .tree_top, tx, ty - cell + 4, tint_);
                    },
                    .bush => art.draw(c, cam, view, .bush, tx, ty, tint_),
                    .rock => art.draw(c, cam, view, .rock, tx, ty, tint_),
                    .fence => art.draw(c, cam, view, .fence, tx, ty, tint_),
                }
            }
            if (y == feet) {
                const frame: u2 = if (w.moving) 1 + @as(u2, @intCast(@mod(@as(i64, @intFromFloat(w.walked / 0.35)), 2))) else 0;
                art.farmer(c, cam, view, fx * cell - cell / 2, fy * cell - cell + 2, @intFromEnum(w.facing), frame, tint_);
            }
        }
    }

    /// The coins and the hour, and the toolbar, over the world.
    fn drawHud(g: *Farm, c: *ui.Context, r: ui.Rect) void {
        const w = &g.w;
        const panel: ui.Color = .{ .r = 20.0 / 255.0, .g = 18.0 / 255.0, .b = 30.0 / 255.0, .a = 0.75 };
        const muted: ui.Color = .hex(0xc8c8d7);
        game.rounded(c, .{ .x = 12, .y = 12, .w = 168, .h = 40 }, panel, 10);
        art.drawAt(c, .coin, .{ .x = 18, .y = 16, .w = 32, .h = 32 });
        label(c, 54, 21, c.print("{d}", .{w.coins}), .{ .size = 18, .weight = .semibold, .color = .white });
        label(c, 110, 23, c.print("{d:0>2}:00", .{w.daylight()[1]}), .{ .size = 15, .color = muted });
        // The toolbar, at the bottom, the tool in use framed.
        const slot: f32 = 52;
        const gap: f32 = 8;
        const bw = 3 * slot + 2 * gap + 16;
        const bx = (r.w - bw) / 2;
        const by = r.h - slot - 50;
        game.rounded(c, .{ .x = bx, .y = by, .w = bw, .h = slot + 16 }, panel, 12);
        for ([_]art.Kind{ .hoe, .seeds, .can }, 0..) |icon, i| {
            const x = bx + 8 + @as(f32, @floatFromInt(i)) * (slot + gap);
            if (@intFromEnum(w.tool) == i) {
                _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = by + 8 }, .width = .{ .px = slot }, .height = .{ .px = slot }, .radius = 8, .background = ui.Color.white.alpha(0.15), .border = .hex(0xfbf236), .border_width = 2 }, .none, null);
            }
            art.drawAt(c, icon, .{ .x = x + 4, .y = by + 12, .w = slot - 8, .h = slot - 8 });
            label(c, x + 4, by + 10, c.print("{d}", .{i + 1}), .{ .size = 11, .color = muted });
        }
        const hint = c.print("{s} · Space uses it · 1 2 3 or Q switch · Z X zoom · M music", .{world_mod.tool_names[@intFromEnum(w.tool)]});
        const ts: ui.TextStyle = .{ .size = 12 };
        const tw = c.text.width(hint, ts);
        const th = c.text.lineHeight(ts);
        game.rounded(c, .{ .x = (r.w - tw) / 2 - 10, .y = r.h - 30, .w = tw + 20, .h = th + 10 }, panel, (th + 10) / 2);
        label(c, (r.w - tw) / 2, r.h - 25, hint, .{ .size = 12, .color = muted });
    }
};

/// A text at (x, y) in the game's box.
fn label(c: *ui.Context, x: f32, y: f32, s: []const u8, style: ui.TextStyle) void {
    _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y } }, .{ .text = .{ .str = s, .style = style, .color = style.color orelse .white } }, null);
}

/// Where the camera looks along an axis to follow a point at `at`, in a
/// world `world` long, through a view `view` long.
fn follow(at: f32, world: f32, view: f32) f32 {
    if (world <= view) return world / 2;
    return @min(@max(at, view / 2), world - view / 2);
}

const State = struct {
    farm: Farm,
    runner: game.Runner = .{},

    fn build(s: *State, c: *ui.Context) void {
        game.view(c, &s.farm, &s.runner);
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Farm" });
    defer app.destroy();
    // Headless runs (snapshots, scripts) play into no device.
    const engine = try myzig.audio.Engine.create(init.gpa, init.io, .{ .device = if (app.flags.hidden) .manual else .system });
    defer engine.destroy();
    var sounds: Sounds = .init(engine);
    defer sounds.deinit();
    const s = try init.gpa.create(State);
    defer init.gpa.destroy(s);
    s.* = .{ .farm = .{ .w = .init() } };
    defer s.farm.pads.deinit();
    s.farm.snd = &sounds;
    s.farm.setMusic(true);
    _ = try app.newWindow(.{
        .title = "Farm",
        .width = 960,
        .height = 640,
        .content = .{ .view = .init(s, State.build) },
    });
    try app.run();
}

test {
    _ = world_mod;
}
