//! A pane of characters stirred by the wind, after mygo's examples/wind:
//! one shader (`wind.zsl`) finds the wind at every cell of a grid and draws
//! its character along the way the air blows. Move the pointer to warm the
//! air, click to blow a ripple, Ctrl+R (⌘R) for another wind.
//!
//!     zig build run-wind
//!     zig-out/bin/wind --myzig-snapshot=/tmp/wind.png
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

pub const shader = ui.shader.compile("wind", @embedFile("wind.zsl"));

/// A visit's wind, picked from its seed.
pub const Wind = struct {
    seed: u32,
    heading: f32,
    speed: f32,
    gust_length: f32,
    gust_width: f32,
    bend: f32,
    bend_scale: f32,

    pub fn of(seed: u32) Wind {
        var prng: std.Random.DefaultPrng = .init(seed);
        const r = prng.random();
        const between = struct {
            fn f(x: std.Random, lo: f32, hi: f32) f32 {
                return lo + (hi - lo) * x.float(f32);
            }
        }.f;
        // Mostly across, a little down, either way.
        const e = r.float(f32);
        const lo = std.math.pi / 10.0;
        const a = lo + (std.math.pi / 4.3 - lo) * @mod(e * 2, 1);
        return .{
            .seed = seed,
            .heading = if (e < 0.5) a else std.math.pi - a,
            .speed = between(r, 42, 64),
            .gust_length = between(r, 380, 560),
            .gust_width = between(r, 120, 190),
            .bend = between(r, 60, 110),
            .bend_scale = between(r, 300, 440),
        };
    }
};

pub const Pane = struct {
    wind: Wind = .of(0x5eed),
    draft: ui.TextBuffer = .{},
    /// When the wind began, on the context's clock.
    start: ?f64 = null,
    /// The last click: where, and when on the wind's clock.
    tap: [3]f32 = .{ 0, 0, 0 },
    /// Frozen at this time (tests), else live.
    frozen: ?f32 = null,

    pub fn view(s: *Pane, c: *ui.Context) void {
        if (c.shortcut(.{ .key = 'r', .cmd = true })) {
            s.wind = .of(s.wind.seed *% 2654435761 +% 1);
            s.start = null;
        }
        const start = s.start orelse c.time;
        s.start = start;
        const t: f32 = s.frozen orelse @floatCast(c.time - start);
        if (s.frozen == null) c.animationFrame();
        c.wants_moves = true;
        const w = s.wind;
        const root = ui.shaderBox(c, &shader, .{
            .seed = w.seed,
            .time = t,
            .reveal = std.math.clamp(t / 1.5, 0, 1),
            .heading = [2]f32{ @cos(w.heading), @sin(w.heading) },
            .carried = w.speed * t,
            .gust_length = w.gust_length,
            .gust_width = w.gust_width,
            .bend = w.bend,
            .bend_scale = w.bend_scale,
            .tap = s.tap,
        }, .{ .width = .fill, .height = .fill, .align_items = .center });
        defer c.end();
        const it = c.interact(root, .{});
        if (it.clicked) {
            const r = it.rect orelse ui.Rect{};
            s.tap = .{ c.input.mouse.x - r.x, c.input.mouse.y - r.y, t };
        }
        _ = c.leaf(.{ .grow = 45 }, .none, null);
        {
            ui.column(c, .{ .width = .{ .px = @min(640, c.size.w - 48) }, .gap = 12, .align_items = .center });
            defer ui.end(c);
            _ = c.open(.{ .width = .fill, .padding = .xy(16, 10), .radius = 14, .background = c.theme.surface, .shadow = .{ .blur = 18, .y = 4, .color = .{ .r = 0, .g = 0, .b = 0, .a = 0.06 } } }, null);
            _ = ui.textField(c, &s.draft, .{ .placeholder = "Describe a task or ask a question", .width = .fill, .bare = true, .size = 15, .label = "Task" });
            c.end();
            ui.text(c, "Move the pointer to warm the air, click to blow a ripple, Ctrl+R for another wind.", .{ .size = 12, .color = c.theme.muted });
        }
        _ = c.leaf(.{ .grow = 55 }, .none, null);
        ui.row(c, .{ .width = .fill, .justify = .end, .padding = .{ .right = 14, .bottom = 10 } });
        defer ui.end(c);
        ui.textf(c, .{ .size = 11, .mono = true, .color = c.theme.muted }, "wind/{x:0>8}", .{w.seed});
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Wind" });
    defer app.destroy();
    var state: Pane = .{};
    _ = try app.newWindow(.{
        .title = "Wind",
        .width = 820,
        .height = 560,
        .content = .{ .view = .init(&state, Pane.view) },
    });
    try app.run();
}

test "a wind is its seed's" {
    const a = Wind.of(7);
    const b = Wind.of(7);
    try std.testing.expectEqual(a.heading, b.heading);
    try std.testing.expect(a.gust_width >= 120 and a.gust_width <= 190);
    try std.testing.expect(Wind.of(8).heading != a.heading);
}

/// How many pixels of the frame are ink: away from the background.
fn inked(px: anytype, bg: [3]u8) usize {
    var n: usize = 0;
    for (0..px.width * px.height) |i| {
        const p = px.bytes[i * 4 ..][0..4];
        const d = @abs(@as(i32, p[2]) - bg[0]) + @abs(@as(i32, p[1]) - bg[1]) + @abs(@as(i32, p[0]) - bg[2]);
        if (d > 60) n += 1;
    }
    return n;
}

test "the wind draws strokes over the pane, and a click's blow changes them" {
    const gpa = std.testing.allocator;
    var s: Pane = .{ .frozen = 4 };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Pane.view), .{ .width = 240, .height = 160, .scale = 1 });
    defer t.deinit();
    t.settle(1);
    try std.testing.expect(t.hasText("wind/00005eed"));
    const bg = t.theme.background;
    const bg8 = [3]u8{ @intFromFloat(bg.r * 255), @intFromFloat(bg.g * 255), @intFromFloat(bg.b * 255) };
    const calm = try t.render(gpa);
    defer calm.deinit(gpa);
    const before = inked(calm, bg8);
    try std.testing.expect(before > 100);
    // A blow from the corner, a second after it.
    t.click(30, 140);
    s.frozen = 4.6;
    t.frame();
    try std.testing.expectEqual(@as(f32, 4), s.tap[2]);
    const blown = try t.render(gpa);
    defer blown.deinit(gpa);
    try std.testing.expect(inked(blown, bg8) != before);
}
