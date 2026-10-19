//! The "galaxy brain effort slider", after mygo's examples/effort-slider
//! (itself after ozzy's demo): a card whose slider steps from Low to Max
//! with a brain for a thumb, and past Max into Galaxy, where the brain
//! bursts, the card shakes, the track fills with twinkling pixels and
//! dotted rays stream out of the brain. The track and the brain are
//! shaders (`track.zsl`, `brain.zsl`) drawn by any renderer.
//!
//!     zig build run-effort-slider
//!     zig-out/bin/effort-slider --myzig-snapshot=/tmp/effort.png --myzig-script="key:right;key:right;key:right;key:right;key:right;wait:1"
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

const common = @embedFile("common.zsl");
pub const track_shader = ui.shader.compile("effort-track", common ++ @embedFile("track.zsl"));
pub const brain_shader = ui.shader.compile("effort-brain", common ++ @embedFile("brain.zsl"));

pub const levels = [_][]const u8{ "Low", "Medium", "High", "Extra", "Max", "Galaxy" };
pub const galaxy = 5;

const card_w = 220;
const card_h = 129.5;
const track_x = 12;
const track_y = 75;
const track_w = 196;
const track_h = 20;
const stop_x = 20;
const stop_gap = 36;
const brain_y = 85.5;
const brain_box = 100;
const move_time = 0.5;
const galaxy_in = 0.16;
const galaxy_out = 0.25;
const burst_time = 0.65;

fn hex(v: u24) ui.Color {
    return .hex(v);
}

/// How far the card jumps in the frames after Galaxy starts, a 60th of a
/// second apart, as the demo's card does, in points.
const shake = [_][2]f32{
    .{ 0.75, 1 },     .{ -0.78, 0.3 }, .{ 0.9, -1.03 },  .{ 0.4, 0.37 },  .{ 0.25, 0 },      .{ 0.15, -0.2 },   .{ 0.15, 0.32 },
    .{ -0.5, -0.22 }, .{ -0.22, 0 },   .{ 0.15, -0.25 }, .{ -0.3, 0.35 }, .{ -0.22, -0.15 }, .{ -0.15, -0.08 }, .{ -0.05, -0.02 },
};

/// CSS's ease of the thumb's moves: cubic-bezier(0.19, 1, 0.22, 1),
/// nearly an exponential ease out.
fn moveEase(k: f32) f32 {
    return 1 - std.math.pow(f32, 1 - k, 4);
}

pub const Slider = struct {
    level: usize = 1,
    /// Where the thumb was when it set off, and when (on `now`).
    from: f32 = 1,
    moved_at: f64 = -10,
    galaxy_at: ?f64 = null,
    galaxy_left: ?f64 = null,
    now: f64 = 0,
    last: ?f64 = null,
    /// Held by the pointer, where.
    held: ?f32 = null,

    pub fn setLevel(s: *Slider, l: usize) void {
        if (l == s.level) return;
        s.from = s.thumb();
        if (l == galaxy) {
            s.galaxy_at = s.now;
            s.galaxy_left = null;
        } else if (s.level == galaxy) s.galaxy_left = s.now;
        s.level = l;
        s.moved_at = s.now;
    }

    /// Where the thumb is, in levels.
    pub fn thumb(s: *const Slider) f32 {
        if (s.held) |h| return h;
        const k: f32 = @floatCast((s.now - s.moved_at) / move_time);
        if (k >= 1) return @floatFromInt(s.level);
        return s.from + (@as(f32, @floatFromInt(s.level)) - s.from) * moveEase(@max(k, 0));
    }

    /// How far Galaxy has come in (or gone), from 0 to 1.
    pub fn galaxyLevel(s: *const Slider) f32 {
        const at = s.galaxy_at orelse return 0;
        if (s.galaxy_left) |left| return @max(0, 1 - @as(f32, @floatCast((s.now - left) / galaxy_out)));
        return @min(1, @as(f32, @floatCast((s.now - at) / galaxy_in)));
    }

    fn shakeAt(s: *const Slider) [2]f32 {
        const at = s.galaxy_at orelse return .{ 0, 0 };
        if (s.galaxy_left != null) return .{ 0, 0 };
        const f: f32 = @floatCast((s.now - at) * 60);
        if (f < 0 or f >= shake.len) return .{ 0, 0 };
        const i: usize = @intFromFloat(f);
        const a = shake[i];
        const b = if (i + 1 < shake.len) shake[i + 1] else [2]f32{ 0, 0 };
        const k = f - @as(f32, @floatFromInt(i));
        return .{ a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k };
    }

    fn animating(s: *const Slider) bool {
        return s.now - s.moved_at < move_time or s.galaxyLevel() > 0;
    }

    pub fn view(s: *Slider, c: *ui.Context) void {
        const dt: f64 = if (s.last) |l| @max(c.time - l, 0) else 0;
        s.last = c.time;
        s.now += dt;
        if (c.input.key == .right and s.level < galaxy) s.setLevel(s.level + 1);
        if (c.input.key == .left and s.level > 0) s.setLevel(s.level - 1);
        if (s.animating()) c.animationFrame();

        ui.column(c, .{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .background = hex(0x101010) });
        defer ui.end(c);
        const jolt = s.shakeAt();
        _ = c.open(.{ .width = .{ .px = card_w }, .height = .{ .px = card_h }, .radius = 8, .background = hex(0x171717), .border = hex(0x262626), .offset = .{ .x = jolt[0], .y = jolt[1] } }, null);
        defer c.end();
        const g = s.galaxyLevel();
        // The title and the level.
        place(c, 12.2, 26 - 13.25, "Effort", .{ .size = 13.25, .color = hex(0x767676) });
        const value_color: ui.Color = if (s.level == galaxy) hex(0x8fd0f6) else hex(0xe5e5e5);
        place(c, 54.6, 26 - 13.25, levels[s.level], .{ .size = 13.25, .color = value_color, .weight = .medium });
        place(c, 12.1, 60.4 - 12, "Faster", .{ .size = 12, .color = hex(0x6f6f6f) });
        place(c, 208.1 - 44, 60.4 - 12, "Smarter", .{ .size = 12, .color = hex(0x6f6f6f) });
        place(c, 24.6 - 4, 114 - 12, "Recommended", .{ .size = 10.5, .color = hex(0x777777) });

        // The track, its stops, and in Galaxy its pixels.
        const thumb_x = stop_x + s.thumb() * stop_gap;
        const tr = c.open(.{ .absolute = true, .offset = .{ .x = track_x, .y = track_y }, .width = .{ .px = track_w }, .height = .{ .px = track_h }, .radius = 5, .background = hex(0x262626) }, null);
        c.end();
        // Under the track's pixels, the fill toward the brain.
        _ = c.open(.{ .absolute = true, .offset = .{ .x = track_x, .y = track_y }, .width = .{ .px = @max(thumb_x - track_x, 0) }, .height = .{ .px = track_h }, .radius = 5, .background = hex(0x9f5a7a).alpha(0.12 * (1 - g)) }, null);
        c.end();
        for (0..levels.len) |i| {
            const x = 23 + @as(f32, @floatFromInt(i)) * 34.8;
            _ = c.open(.{ .absolute = true, .offset = .{ .x = x - 1.5, .y = track_y + track_h / 2 - 1.5 }, .width = .{ .px = 3 }, .height = .{ .px = 3 }, .radius = 1.5, .background = hex(0x525252) }, null);
            c.end();
        }
        if (g > 0) {
            _ = ui.shaderBox(c, &track_shader, .{ .time = @as(f32, @floatCast(s.now)), .galaxy = g, .thumb = thumb_x - track_x }, .{ .absolute = true, .offset = .{ .x = track_x, .y = track_y }, .width = .{ .px = track_w }, .height = .{ .px = track_h }, .radius = 5 });
            c.end();
        }
        const track_rect = c.rects.get(c.node(tr).id);
        s.press(c, tr, track_rect);

        // The brain, and what streams out of it.
        const burst: f32 = if (s.galaxy_at) |at| @floatCast((s.now - at) / burst_time) else 0;
        const size: f32 = 24 + 8 * g;
        const b = ui.shaderBox(c, &brain_shader, .{ .time = @as(f32, @floatCast(s.now)), .galaxy = g, .burst = if (s.galaxy_left == null) burst else 0, .brain = size }, .{ .absolute = true, .offset = .{ .x = thumb_x - brain_box / 2, .y = brain_y - brain_box / 2 }, .width = .{ .px = brain_box }, .height = .{ .px = brain_box } });
        c.end();
        s.press(c, b, track_rect);
    }

    /// The track and the brain take presses: the level nearest the pointer.
    fn press(s: *Slider, c: *ui.Context, box: u32, track: ?ui.Rect) void {
        const it = c.interact(box, .{});
        const r = track orelse return;
        if (it.pressed) {
            const x = c.input.mouse.x - r.x + track_x;
            const at = std.math.clamp((x - stop_x) / stop_gap, 0, galaxy);
            s.held = at;
            c.changed = true;
        } else if (s.held) |h| {
            if (!c.input.down) {
                s.held = null;
                s.from = h;
                s.moved_at = s.now;
                s.setLevel(@intFromFloat(@round(h)));
            }
        }
    }
};

/// Text at (x, y) in the card.
fn place(c: *ui.Context, x: f32, y: f32, s: []const u8, style: ui.TextStyle) void {
    _ = c.open(.{ .absolute = true, .offset = .{ .x = x, .y = y } }, null);
    ui.text(c, s, style);
    c.end();
}

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Effort" });
    defer app.destroy();
    var state: Slider = .{};
    _ = try app.newWindow(.{
        .title = "Effort",
        .width = 472,
        .height = 258,
        .content = .{ .view = .init(&state, Slider.view) },
    });
    try app.run();
}

test "arrows step the levels, and past Max the slider goes Galaxy" {
    var s: Slider = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&s, Slider.view), .{ .width = 472, .height = 258, .scale = 1 });
    defer t.deinit();
    t.settle(1);
    try std.testing.expect(t.hasText("Medium"));
    for (0..4) |_| {
        t.key(.right);
        t.advance(0.1);
    }
    try std.testing.expect(t.hasText("Galaxy"));
    t.advance(1);
    try std.testing.expectEqual(@as(f32, 1), s.galaxyLevel());
    try std.testing.expectEqual(@as(f32, galaxy), s.thumb());
    // The track's pixels twinkle: two moments differ.
    const a = try t.render(std.testing.allocator);
    defer a.deinit(std.testing.allocator);
    t.advance(0.3);
    const b = try t.render(std.testing.allocator);
    defer b.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, a.bytes, b.bytes));
    t.key(.left);
    t.advance(1);
    try std.testing.expect(t.hasText("Max"));
    try std.testing.expectEqual(@as(f32, 0), s.galaxyLevel());
}

test "a click on the track picks the nearest level" {
    var s: Slider = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&s, Slider.view), .{ .width = 472, .height = 258, .scale = 1 });
    defer t.deinit();
    t.settle(1);
    const card_x = (472 - card_w) / 2.0;
    const card_y = (258 - card_h) / 2.0;
    t.click(card_x + stop_x + 3 * stop_gap + 4, card_y + track_y + 10);
    t.advance(1);
    try std.testing.expectEqual(@as(usize, 3), s.level);
    try std.testing.expect(t.hasText("Extra"));
}
