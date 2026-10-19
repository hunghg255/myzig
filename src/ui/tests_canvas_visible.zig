//! `Painter.visible`, after mygo's TestPainterVisibleTransformed: the part
//! of a canvas in view, in the coordinates it draws in, under its boxes'
//! transforms and the painter's own, and within scrolling boxes.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const types = @import("types.zig");
const Rect = types.Rect;

const Zoom = struct {
    big: Rect = .{},
    small: Rect = .{},
    drawn: Rect = .{},
    after: Rect = .{},

    fn view(s: *Zoom, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        zoomed(c, 2, s, drawBig);
        zoomed(c, 0.5, s, drawSmall);
    }

    fn zoomed(c: *ui.Context, k: f32, s: *Zoom, comptime draw: fn (*Zoom, *ui.Painter) void) void {
        _ = c.open(.{ .absolute = true, .width = .{ .px = 200 }, .height = .{ .px = 200 }, .transform = .scaling(k, k), .transform_origin = .{ .x = 0, .y = 0 } }, null);
        defer c.end();
        _ = ui.canvas(c, .{ .w = 200, .h = 200 }, .{}, s, draw);
    }

    fn drawBig(s: *Zoom, p: *ui.Painter) void {
        s.big = p.visible();
        p.fillRect(.{ .w = 10, .h = 10 }, .hex(0xff0000));
    }

    fn drawSmall(s: *Zoom, p: *ui.Painter) void {
        s.small = p.visible();
        p.save();
        p.scaleBy(4, 4);
        s.drawn = p.visible();
        p.restore();
        s.after = p.visible();
    }
};

fn expectRect(want: Rect, got: Rect) !void {
    errdefer std.debug.print("want {any}, got {any}\n", .{ want, got });
    inline for (.{ "x", "y", "w", "h" }) |f| try testing.expectApproxEqAbs(@field(want, f), @field(got, f), 0.01);
}

test "under a transform, a canvas sees the part of itself in view in the coordinates it draws in" {
    var s: Zoom = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Zoom.view), .{ .width = 200, .height = 200 });
    defer t.deinit();
    // The first frame, before any was painted: all of it.
    try expectRect(.{ .w = 200, .h = 200 }, s.big);
    t.frame();
    // Zoomed to twice its size in a window its size: its top left quarter.
    try expectRect(.{ .w = 100, .h = 100 }, s.big);
    // Zoomed to half: all of itself, and past it what the window shows.
    try expectRect(.{ .w = 400, .h = 400 }, s.small);
    // Then four times by the painter: a quarter again, until it restores.
    try expectRect(.{ .w = 100, .h = 100 }, s.drawn);
    try expectRect(.{ .w = 400, .h = 400 }, s.after);
}

const Scrolled = struct {
    seen: Rect = .{},
    lines: usize = 0,

    fn view(s: *Scrolled, c: *ui.Context) void {
        _ = c.open(.{ .width = .fill, .height = .{ .px = 200 }, .scroll = true }, "doc");
        defer c.end();
        _ = ui.canvas(c, .{ .w = 300, .h = 2000 }, .{}, s, draw);
    }

    /// A long document, drawn only where it shows.
    fn draw(s: *Scrolled, p: *ui.Painter) void {
        const v = p.visible();
        s.seen = v;
        s.lines = 0;
        var y: f32 = 0;
        while (y < p.size.h) : (y += 20) {
            if (y + 20 < v.y or y > v.y + v.h) continue;
            p.fillRect(.{ .x = 4, .y = y + 4, .w = 200, .h = 12 }, .hex(0x333333));
            s.lines += 1;
        }
    }
};

test "a canvas taller than the scrolling box it is in sees what shows, as it scrolls" {
    var s: Scrolled = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scrolled.view), .{ .width = 300, .height = 300 });
    defer t.deinit();
    t.frame();
    try expectRect(.{ .w = 300, .h = 200 }, s.seen);
    try testing.expect(s.lines <= 12);
    t.scroll(100, 100, -600);
    // The frame after the one that scrolled draws what came into view.
    t.settle(1);
    try testing.expect(s.seen.y > 0);
    try testing.expectApproxEqAbs(@as(f32, 200), s.seen.h, 0.01);
    try testing.expect(s.lines <= 12);
}
