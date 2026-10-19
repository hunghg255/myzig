//! Confetti in native UI, as canvas-confetti throws it on a web page.
//! Pick one of canvas-confetti's demos, or click the stage to throw a
//! burst of your own from the pointer.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const confetti = @import("confetti.zig");
const Options = confetti.Options;
const Burst = confetti.Burst;

/// How many pieces can be in the air: a demo pressed again and again lets
/// the oldest, most faded go first.
const max_pieces = 1500;

/// A demo that throws confetti for a while: `fire(i, n)` n times, every so often.
const Emitter = struct {
    next: f64,
    every: f64,
    i: u32,
    n: u32,
    fire: *const fn (s: *App, i: u32, n: u32) void,
};

const Preset = struct {
    name: []const u8,
    about: []const u8,
    run: *const fn (s: *App) void,
};

const App = struct {
    gpa: std.mem.Allocator,
    prng: std.Random.DefaultPrng,
    bursts: std.ArrayList(Burst) = .empty,
    emitters: std.ArrayList(Emitter) = .empty,
    next_id: u64 = 1,
    now: f64 = 0,
    /// The window's size and theme as the view last ran.
    w: f32 = 980,
    h: f32 = 700,
    dark: bool = false,
    skew: f32 = 1,
    // The stage's options, as its sliders set them.
    count: f32 = 150,
    angle: f32 = 90,
    spread: f32 = 360,
    velocity: f32 = 30,
    decay: f32 = 0.9,
    gravity: f32 = 1,
    drift: f32 = 0,
    scalar: f32 = 1,

    fn rand(s: *App) std.Random {
        return s.prng.random();
    }

    fn resetOptions(s: *App) void {
        s.count = 150;
        s.angle = 90;
        s.spread = 360;
        s.velocity = 30;
        s.decay = 0.9;
        s.gravity = 1;
        s.drift = 0;
        s.scalar = 1;
    }

    fn deinit(s: *App) void {
        for (s.bursts.items) |*b| b.deinit(s.gpa);
        s.bursts.deinit(s.gpa);
        s.emitters.deinit(s.gpa);
    }

    fn inAir(s: *const App) usize {
        var n: usize = 0;
        for (s.bursts.items) |b| n += b.pieces.len;
        return n;
    }

    fn burst(s: *App, o: Options) void {
        const b = Burst.init(s.gpa, s.rand(), o, o.x * s.w, o.y * s.h, s.next_id, s.now) catch return;
        s.next_id += 1;
        s.bursts.append(s.gpa, b) catch return;
        var over = @as(isize, @intCast(s.inAir())) - max_pieces;
        while (over > 0 and s.bursts.items.len > 0) {
            const first = &s.bursts.items[0];
            if (first.pieces.len > over) {
                // The oldest pieces go: what's left of the burst stays.
                const keep = s.gpa.dupe(confetti.Piece, first.pieces[@intCast(over)..]) catch return;
                s.gpa.free(first.pieces);
                first.pieces = keep;
                break;
            }
            over -= @intCast(first.pieces.len);
            first.deinit(s.gpa);
            _ = s.bursts.orderedRemove(0);
        }
    }

    fn repeat(s: *App, every: f64, n: u32, fire: *const fn (*App, u32, u32) void) void {
        fire(s, 0, n);
        if (n > 1) s.emitters.append(s.gpa, .{ .next = s.now + every, .every = every, .i = 1, .n = n, .fire = fire }) catch {};
    }

    fn view(s: *App, c: *ui.Context) void {
        const th = c.theme;
        s.now = c.time;
        s.w = c.size.w;
        s.h = c.size.h;
        s.dark = th.dark;
        // While the desktop asks for less motion, nothing flies.
        const still = ui.motion.reduced(c);

        var i: usize = 0;
        while (i < s.emitters.items.len) {
            const e = &s.emitters.items[i];
            while (e.i < e.n and s.now >= e.next) {
                if (!still) e.fire(s, e.i, e.n);
                e.i += 1;
                e.next += e.every;
            }
            if (e.i >= e.n) _ = s.emitters.orderedRemove(i) else i += 1;
        }

        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        s.content(c, still);

        // The pieces fly over everything; bursts that faded away go.
        i = 0;
        while (i < s.bursts.items.len) {
            if (s.bursts.items[i].done(s.now)) {
                s.bursts.items[i].deinit(s.gpa);
                _ = s.bursts.orderedRemove(i);
            } else i += 1;
        }
        _ = c.open(.{ .absolute = true, .width = .fill, .height = .fill }, "confetti");
        for (s.bursts.items) |*b| b.build(c, s.now);
        c.end();
        if (s.bursts.items.len > 0) c.animationFrame();
        // And when a demo throws more.
        for (s.emitters.items) |e| c.frameIn(@floatCast(@max(0, e.next - s.now)));
    }

    fn content(s: *App, c: *ui.Context, still: bool) void {
        const th = c.theme;
        ui.column(c, .{ .width = .fill, .grow = 1, .padding = .all(24), .gap = 20 });
        defer ui.end(c);
        {
            ui.row(c, .{ .width = .fill, .align_items = .end, .gap = 12 });
            defer ui.end(c);
            ui.column(c, .{ .grow = 1, .gap = 4 });
            ui.text(c, "Confetti", .{ .size = 28, .weight = .bold });
            ui.text(c, "canvas-confetti's demos in native UI.", .{ .color = th.muted });
            ui.end(c);
            ui.text(c, c.print("{d} in the air", .{s.inAir()}), .{ .size = 12, .color = th.muted });
        }
        if (still) ui.text(c, "Confetti rests while the desktop asks for less motion.", .{ .color = .hex(0xff9f0a) });
        ui.row(c, .{ .width = .fill, .grow = 1, .gap = 16, .align_items = .stretch });
        defer ui.end(c);
        {
            ui.column(c, .{ .grow = 1, .gap = 16 });
            defer ui.end(c);
            s.presetTiles(c, still);
            const stage = c.open(.{ .width = .fill, .grow = 1, .align_items = .center, .justify = .center, .gap = 6, .radius = 12, .border = th.border }, "stage");
            const it = c.interact(stage, .{});
            ui.text(c, "Click anywhere here", .{ .weight = .bold });
            ui.text(c, "to throw your burst from the pointer", .{ .size = 12, .color = th.muted });
            c.end();
            if (it.clicked and !still) s.burst(s.custom(c.input.mouse.x, c.input.mouse.y));
        }
        s.controls(c);
    }

    /// A tile for each of canvas-confetti's demos, three to a row.
    fn presetTiles(s: *App, c: *ui.Context, still: bool) void {
        const th = c.theme;
        ui.column(c, .{ .width = .fill, .gap = 12 });
        defer ui.end(c);
        var row: usize = 0;
        while (row * 3 < presets.len) : (row += 1) {
            ui.row(c, .{ .width = .fill, .gap = 12 });
            defer ui.end(c);
            for (presets[row * 3 .. @min(presets.len, row * 3 + 3)]) |p| {
                ui.key(c, p.name);
                const tile = c.open(.{ .grow = 1, .width = .fill, .gap = 4, .padding = .xy(14, 12), .radius = 10, .border = th.border, .background = th.surface }, null);
                const it = c.interact(tile, .{ .focusable = true, .keys = true });
                const lift: ui.motion.Pose = if (it.pressed) .{ .scale = 0.97 } else if (it.hovered) .{ .y = -2 } else .{};
                if (it.hovered) c.node(tile).style.background = th.surface_hover;
                ui.motion.pose(c, tile, lift, .snappy);
                ui.text(c, p.name, .{ .weight = .bold });
                ui.text(c, p.about, .{ .size = 12, .color = th.muted });
                c.end();
                if (it.clicked and !still) p.run(s);
            }
        }
    }

    fn controls(s: *App, c: *ui.Context) void {
        const th = c.theme;
        ui.column(c, .{ .width = .{ .px = 280 }, .gap = 10, .padding = .all(16), .radius = 12, .background = th.surface, .border = th.border });
        defer ui.end(c);
        ui.text(c, "Your burst", .{ .weight = .bold });
        const sliders = .{
            .{ "Count", "count", 1, 400, "{d:.0}" },
            .{ "Angle", "angle", 0, 360, "{d:.0}°" },
            .{ "Spread", "spread", 0, 360, "{d:.0}°" },
            .{ "Velocity", "velocity", 0, 90, "{d:.0}" },
            .{ "Decay", "decay", 0.8, 0.99, "{d:.2}" },
            .{ "Gravity", "gravity", -1, 3, "{d:.1}" },
            .{ "Drift", "drift", -2, 2, "{d:.1}" },
            .{ "Size", "scalar", 0.4, 3, "{d:.1}×" },
        };
        inline for (sliders) |sl| {
            ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
            defer ui.end(c);
            _ = c.leaf(.{ .width = .{ .px = 62 } }, .{ .text = .{ .str = sl[0], .style = .{ .size = 12 }, .color = th.text } }, null);
            ui.key(c, sl[0]);
            _ = ui.slider(c, &@field(s, sl[1]), .{ .min = sl[2], .max = sl[3], .width = .fill, .label = sl[0] });
            _ = c.leaf(.{ .width = .{ .px = 40 } }, .{ .text = .{ .str = c.print(sl[4], .{@field(s, sl[1])}), .style = .{ .size = 12 }, .color = th.muted } }, null);
        }
        ui.spacer(c);
        if (ui.button(c, "Reset", .{}).clicked) s.resetOptions();
    }

    /// The stage's options, for a burst from (x, y) in the window.
    fn custom(s: *App, x: f32, y: f32) Options {
        return .{
            .count = @intFromFloat(s.count),
            .angle = s.angle,
            .spread = s.spread,
            .start_velocity = s.velocity,
            .decay = s.decay,
            .gravity = s.gravity,
            .drift = s.drift,
            .scalar = s.scalar,
            .x = x / s.w,
            .y = y / s.h,
        };
    }
};

const presets = [_]Preset{
    .{ .name = "Basic Cannon", .about = "One burst, up from below", .run = struct {
        fn f(s: *App) void {
            s.burst(.{ .count = 100, .spread = 70, .y = 0.6 });
        }
    }.f },
    .{ .name = "Random Direction", .about = "Another angle every time", .run = struct {
        fn f(s: *App) void {
            const r = s.rand();
            s.burst(.{ .angle = 55 + r.float(f32) * 70, .spread = 50 + r.float(f32) * 20, .count = 50 + r.uintLessThan(usize, 50), .y = 0.6 });
        }
    }.f },
    .{ .name = "Realistic Look", .about = "Five bursts, fast to slow", .run = struct {
        fn f(s: *App) void {
            s.burst(.{ .count = 50, .y = 0.7, .spread = 26, .start_velocity = 55 });
            s.burst(.{ .count = 40, .y = 0.7, .spread = 60 });
            s.burst(.{ .count = 70, .y = 0.7, .spread = 100, .decay = 0.91, .scalar = 0.8 });
            s.burst(.{ .count = 20, .y = 0.7, .spread = 120, .start_velocity = 25, .decay = 0.92, .scalar = 1.2 });
            s.burst(.{ .count = 20, .y = 0.7, .spread = 120, .start_velocity = 45 });
        }
    }.f },
    .{ .name = "Fireworks", .about = "Bursts all around for 5 s", .run = struct {
        fn f(s: *App) void {
            s.repeat(0.25, 20, fire);
        }
        fn fire(s: *App, i: u32, n: u32) void {
            const r = s.rand();
            for ([_][2]f32{ .{ 0.1, 0.3 }, .{ 0.7, 0.9 } }) |x| {
                s.burst(.{ .count = 50 * (n - i) / n, .start_velocity = 30, .spread = 360, .ticks = 60, .x = x[0] + r.float(f32) * (x[1] - x[0]), .y = r.float(f32) - 0.2 });
            }
        }
    }.f },
    .{ .name = "Stars", .about = "Golden stars floating out", .run = struct {
        const gold = [_]ui.Color{ .hex(0xffe400), .hex(0xffbd00), .hex(0xe89400), .hex(0xffca6c), .hex(0xfdffb8) };
        fn f(s: *App) void {
            s.repeat(0.1, 3, fire);
        }
        fn fire(s: *App, _: u32, _: u32) void {
            const o: Options = .{ .spread = 360, .ticks = 50, .gravity = 0, .decay = 0.94, .start_velocity = 30, .colors = &gold, .count = 40, .scalar = 1.2, .shapes = &.{.star} };
            s.burst(o);
            var small = o;
            small.count = 10;
            small.scalar = 0.75;
            small.shapes = &.{.circle};
            s.burst(small);
        }
    }.f },
    .{ .name = "Snow", .about = "Flakes drifting down for 8 s", .run = struct {
        fn f(s: *App) void {
            s.skew = 1;
            s.repeat(0.03, 270, fire);
        }
        fn fire(s: *App, i: u32, n: u32) void {
            const r = s.rand();
            const left = @as(f32, @floatFromInt(n - i)) / @as(f32, @floatFromInt(n));
            s.skew = @max(0.8, s.skew - 0.001);
            const night = [_]ui.Color{ .hex(0xffffff), .hex(0xdbeafe), .hex(0xbfdbfe) };
            const day = [_]ui.Color{ .hex(0x93c5fd), .hex(0xbfdbfe), .hex(0xcbd5e1) };
            s.burst(.{
                .count = 1,
                .start_velocity = 0,
                .shapes = &.{.circle},
                .ticks = @intFromFloat(@max(200, 500 * left)),
                .x = r.float(f32),
                .y = r.float(f32) * s.skew - 0.2,
                .colors = if (s.dark) &night else &day,
                .gravity = 0.4 + r.float(f32) * 0.2,
                .scalar = 0.4 + r.float(f32) * 0.6,
                .drift = -0.4 + r.float(f32) * 0.8,
            });
        }
    }.f },
    .{ .name = "School Pride", .about = "Cannons from both sides", .run = struct {
        fn f(s: *App) void {
            s.repeat(0.025, 160, fire);
        }
        fn fire(s: *App, _: u32, _: u32) void {
            const night = [_]ui.Color{ .hex(0xbb0000), .hex(0xffffff) };
            const day = [_]ui.Color{ .hex(0xbb0000), .hex(0x1e293b) };
            for ([_][2]f32{ .{ 60, 0 }, .{ 120, 1 } }) |side| {
                s.burst(.{ .count = 2, .angle = side[0], .spread = 55, .x = side[1], .colors = if (s.dark) &night else &day });
            }
        }
    }.f },
    .{ .name = "Emoji", .about = "Unicorns and rainbows", .run = struct {
        fn f(s: *App) void {
            s.repeat(0.1, 3, fire);
        }
        fn fire(s: *App, _: u32, _: u32) void {
            var o: Options = .{ .spread = 360, .ticks = 60, .gravity = 0, .decay = 0.96, .start_velocity = 20, .shapes = &.{ .{ .text = "🦄" }, .{ .text = "🌈" } }, .scalar = 2, .count = 30 };
            s.burst(o);
            o.count = 5;
            o.flat = true;
            s.burst(o);
            o.count = 15;
            o.flat = false;
            o.scalar = 1;
            o.shapes = &.{.circle};
            s.burst(o);
        }
    }.f },
    .{ .name = "Hearts", .about = "A shape drawn as a path", .run = struct {
        const pink = [_]ui.Color{ .hex(0xff4d6d), .hex(0xff758f), .hex(0xc9184a), .hex(0xffb3c1) };
        fn f(s: *App) void {
            s.repeat(0.1, 3, fire);
        }
        fn fire(s: *App, _: u32, _: u32) void {
            s.burst(.{ .spread = 360, .ticks = 70, .gravity = 0.3, .decay = 0.95, .start_velocity = 25, .count = 25, .scalar = 1.5, .shapes = &.{.heart}, .flat = true, .colors = &pink });
        }
    }.f },
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Confetti" });
    defer app.destroy();
    const seed: u64 = @bitCast(@as(i64, @truncate(std.Io.Timestamp.now(init.io, .real).nanoseconds)));
    var s: App = .{ .gpa = init.gpa, .prng = .init(seed) };
    defer s.deinit();
    _ = try app.newWindow(.{
        .title = "Confetti",
        .width = 980,
        .height = 700,
        .content = .{ .view = .init(&s, App.view) },
    });
    try app.run();
}
