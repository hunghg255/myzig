//! Native gallery of loading.dev's 29 indicators, after mygo/examples/loading.
//! Run with `zig build run-loading`; tests use only ui.Tester.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const loading = @import("loading");
const indicators = loading.indicators;
const drawing = loading.drawing;
const sizes = [_]f32{ 16, 24, 32, 48 };

/// An elapsed clock, held on pause and continued without a jump on resume.
const Clock = struct {
    seconds: f64 = 0,
    last: ?f64 = null,
    paused: bool = false,

    fn update(s: *Clock, now: f64, paused: bool) void {
        if (s.last) |last| if (!s.paused) {
            s.seconds += @max(0, now - last);
        };
        s.last = now;
        s.paused = paused;
    }
};

const Gallery = struct {
    size: usize = 1,
    color: usize = 0,
    easing: usize = 0,
    cap: usize = 0,
    paused: bool = false,
    clock: Clock = .{},
    widgets: [indicators.names.len]loading.Indicator = @splat(.{}),
    // Recorded for tests and reusable across the view's passes.
    frames: [indicators.names.len]indicators.Frame = undefined,

    fn view(s: *Gallery, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        {
            ui.column(c, .{ .gap = 12, .padding = .all(16) });
            defer ui.end(c);
            {
                ui.row(c, .{ .gap = 12, .align_items = .center });
                defer ui.end(c);
                option(c, "Size", &.{ "16", "24", "32", "48" }, &s.size);
                option(c, "Color", &.{ "Text", "Accent", "Muted" }, &s.color);
            }
            {
                ui.row(c, .{ .gap = 12, .align_items = .center });
                defer ui.end(c);
                option(c, "Easing", &.{ "Linear", "Ease in out", "Stacked" }, &s.easing);
                option(c, "Cap", &.{ "Round", "Flat" }, &s.cap);
                _ = ui.checkbox(c, "Paused", &s.paused);
            }
        }
        s.clock.update(c.time, s.paused);
        const still = ui.preferences.get(c).reduce_motion;
        ui.scroll(c, .{ .grow = 1, .width = .fill });
        defer ui.end(c);
        var tracks: [64]ui.GridTrack = undefined;
        const columns: usize = @intFromFloat(std.math.clamp(@floor((c.size.w - 20) / 144), 1, @as(f32, @floatFromInt(tracks.len))));
        @memset(tracks[0..columns], .{ .px = 132 });
        var grid = ui.grid(c, .{ .columns = tracks[0..columns], .gap_x = 12, .gap_y = 12, .style = .{ .width = .fill, .padding = .{ .left = 16, .right = 16, .bottom = 16 } } });
        defer grid.end();
        const colors = [_]ui.Color{ c.theme.text, c.theme.accent, c.theme.muted };
        for (indicators.names, 0..) |name, i| {
            ui.key(c, name);
            ui.column(c, .{ .width = .{ .px = 132 }, .height = .{ .px = 116 }, .justify = .center, .align_items = .center, .gap = 14, .radius = 8, .background = c.theme.surface, .border = c.theme.border });
            defer ui.end(c);
            {
                ui.column(c, .{ .height = .{ .px = 48 }, .justify = .center, .align_items = .center });
                defer ui.end(c);
                s.frames[i] = .{ .index = i, .seconds = s.clock.seconds, .options = .{
                    .color = colors[s.color],
                    .easing = @fromBackingInt(@intCast(s.easing)),
                    .cap = @fromBackingInt(@intCast(s.cap)),
                    .still = still,
                } };
                _ = s.widgets[i].show(c, @fromBackingInt(@intCast(i)), .{
                    .size = sizes[s.size],
                    .color = colors[s.color],
                    .paused = s.paused,
                    .easing = @fromBackingInt(@intCast(s.easing)),
                    .cap = @fromBackingInt(@intCast(s.cap)),
                    .label = name,
                });
            }
            ui.text(c, name, .{ .size = 12, .color = c.theme.muted });
        }
    }
};

fn option(c: *ui.Context, label: []const u8, labels: []const []const u8, value: *usize) void {
    ui.column(c, .{ .gap = 4 });
    defer ui.end(c);
    ui.text(c, label, .{ .size = 11, .color = c.theme.muted });
    _ = ui.segmented(c, labels, value);
}

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Loading" });
    defer app.destroy();
    var state: Gallery = .{};
    _ = try app.newWindow(.{ .title = "Loading", .width = 780, .height = 640, .min_width = 680, .min_height = 320, .content = .{ .view = .init(&state, Gallery.view) } });
    try app.run();
}

test "gallery lists all 29 indicators and controls their size and options" {
    var state: Gallery = .{ .paused = true };
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&state, Gallery.view), .{ .width = 780, .height = 2000, .scale = 1 });
    defer t.deinit();
    t.ctx.access.enabled = true;
    t.frame();
    for (indicators.names) |name| try std.testing.expect(t.hasText(name));
    try t.clickText("48");
    try t.clickText("Accent");
    try t.clickText("Stacked");
    try t.clickText("Flat");
    t.settle(1);
    try std.testing.expectEqual(@as(usize, 3), state.size);
    for (state.frames) |frame| {
        try std.testing.expectEqual(t.theme.accent, frame.options.color);
        try std.testing.expectEqual(drawing.Easing.stacked, frame.options.easing);
        try std.testing.expectEqual(drawing.Cap.flat, frame.options.cap);
    }
    var count: usize = 0;
    for (t.ctx.nodes.items) |node| if (if (t.ctx.access.described.get(node.id)) |desc| desc.role == .progress else false) {
        try std.testing.expectEqual(@as(f32, 48), node.rect.h);
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, 29), count);
    try std.testing.expect(!t.ctx.animating);
}

test "pause holds elapsed time, resume continues, reduced motion rests" {
    var state: Gallery = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&state, Gallery.view), .{ .width = 780, .height = 640, .scale = 1 });
    defer t.deinit();
    t.time += 0.37;
    t.frame();
    try std.testing.expect(state.clock.seconds > 0.36);
    try t.clickText("Paused");
    t.settle(1);
    const held = state.clock.seconds;
    try std.testing.expect(!t.ctx.animating);
    t.time += 10;
    t.frame();
    try std.testing.expectEqual(held, state.clock.seconds);
    try t.clickText("Paused");
    try std.testing.expect(state.clock.seconds < held + 0.1);
    t.time += 0.2;
    t.frame();
    try std.testing.expect(state.clock.seconds > held + 0.19);
    ui.motion.setReducedMotion(&t.ctx, true);
    t.settle(1);
    try std.testing.expect(!t.ctx.animating);
    for (state.frames) |frame| try std.testing.expect(frame.options.still);
}

test {
    _ = loading;
    _ = drawing;
    _ = @import("tests.zig");
}
