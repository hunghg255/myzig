//! Canvases: the rasterizer's pixels, and `ui.canvas` through `Tester`.
const std = @import("std");
const ui = @import("ui.zig");
const canvas = @import("canvas.zig");
const render = @import("canvas_render.zig").render;
const path = @import("path.zig");
const testing = std.testing;

const red: ui.Color = .{ .r = 1 };
const blue: ui.Color = .{ .b = 1 };

/// Draws what `draw` records into a w × h picture at scale 1.
fn pixels(w: usize, h: usize, draw: fn (*canvas.Painter) void) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p: canvas.Painter = .{ .arena = arena.allocator(), .size = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) }, .scale = 1 };
    draw(&p);
    const out = try testing.allocator.alloc(u8, w * h * 4);
    @memset(out, 0);
    try render(testing.allocator, p.cmds.items, out, w, h, .identity);
    return out;
}

fn at(px: []const u8, w: usize, x: usize, y: usize) [4]u8 {
    return px[(y * w + x) * 4 ..][0..4].*;
}

test "a filled rectangle, in BGRA premultiplied" {
    const px = try pixels(20, 20, struct {
        fn f(p: *canvas.Painter) void {
            p.fillRect(.{ .x = 4, .y = 4, .w = 10, .h = 10 }, red);
            p.fillRect(.{ .x = 10, .y = 10, .w = 10, .h = 10 }, blue.alpha(0.5));
        }
    }.f);
    defer testing.allocator.free(px);
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(px, 20, 6, 6));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, at(px, 20, 2, 2));
    // Half blue over red, and half blue alone.
    try testing.expectEqual([4]u8{ 128, 0, 128, 255 }, at(px, 20, 12, 12));
    try testing.expectEqual([4]u8{ 128, 0, 0, 128 }, at(px, 20, 17, 17));
}

test "clips, transforms and layers" {
    const px = try pixels(40, 40, struct {
        fn f(p: *canvas.Painter) void {
            // A square clipped by a circle: its corners are cut.
            p.save();
            var circle = p.path();
            circle.circle(10, 10, 8);
            p.clip(&circle, .nonzero);
            p.fillRect(.{ .x = 2, .y = 2, .w = 16, .h = 16 }, red);
            p.restore();
            // A square turned 45° around its center: a diamond.
            p.save();
            p.rotate(std.math.pi / 4.0, 30, 10);
            p.fillRect(.{ .x = 24, .y = 4, .w = 12, .h = 12 }, red);
            p.restore();
            // Two overlapping squares in a layer at half: the overlap is no darker.
            p.beginLayer(0.5);
            p.fillRect(.{ .x = 2, .y = 24, .w = 10, .h = 10 }, blue);
            p.fillRect(.{ .x = 8, .y = 24, .w = 10, .h = 10 }, blue);
            p.endLayer();
        }
    }.f);
    defer testing.allocator.free(px);
    try testing.expectEqual(@as(u8, 255), at(px, 40, 10, 10)[3]);
    try testing.expectEqual(@as(u8, 0), at(px, 40, 3, 3)[3]);
    try testing.expectEqual(@as(u8, 255), at(px, 40, 30, 3)[3]);
    try testing.expectEqual(@as(u8, 0), at(px, 40, 24, 4)[3]);
    try testing.expectEqual(at(px, 40, 4, 28), at(px, 40, 10, 28));
    try testing.expectEqual(@as(u8, 128), at(px, 40, 10, 28)[3]);
}

test "gradients and strokes" {
    const px = try pixels(100, 20, struct {
        fn f(p: *canvas.Painter) void {
            var r = p.path();
            r.rect(0, 0, 100, 10);
            p.fill(&r, .{ .linear = .{ .from = .{ 0, 0 }, .to = .{ 100, 0 }, .stops = &.{
                .{ .offset = 0, .color = red },
                .{ .offset = 1, .color = blue },
            } } });
            var l = p.path();
            l.moveTo(10, 15);
            l.lineTo(90, 15);
            p.stroke(&l, .color(.black), .{ .width = 2, .dash = &.{ 10, 10 } });
        }
    }.f);
    defer testing.allocator.free(px);
    const left = at(px, 100, 1, 5);
    const right = at(px, 100, 98, 5);
    try testing.expect(left[2] > 245 and left[0] < 10);
    try testing.expect(right[0] > 245 and right[2] < 10);
    try testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(at(px, 100, 50, 5)[0])), 3);
    try testing.expectEqual(@as(u8, 255), at(px, 100, 15, 14)[3]);
    try testing.expectEqual(@as(u8, 0), at(px, 100, 25, 14)[3]);
}

test "the same drawing hashes the same; any change changes it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var hashes: [3]u64 = undefined;
    for (&hashes, 0..) |*h, i| {
        var p: canvas.Painter = .{ .arena = arena.allocator(), .size = .{ .w = 10, .h = 10 } };
        p.fillRect(.{ .x = 1, .y = 1, .w = if (i == 2) 5 else 4, .h = 4 }, red);
        h.* = p.hash();
    }
    try testing.expectEqual(hashes[0], hashes[1]);
    try testing.expect(hashes[0] != hashes[2]);
}

const Scene = struct {
    x: f32 = 20,
    color: ui.Color = red,
    draws: u32 = 0,
    fn draw(s: *Scene, p: *canvas.Painter) void {
        s.draws += 1;
        p.fillCircle(s.x, 30, 15, .color(s.color));
    }
    fn view(s: *Scene, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(10) });
        defer ui.end(c);
        _ = canvas.canvas(c, .{ .w = 100, .h = 60 }, .{}, s, draw);
    }
};

fn windowPixel(t: *ui.Tester, x: f32, y: f32) ![4]u8 {
    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    const ix: usize = @intFromFloat(x * t.scale);
    const iy: usize = @intFromFloat(y * t.scale);
    return px.bytes[(iy * px.width + ix) * 4 ..][0..4].*;
}

test "ui.canvas draws through the image atlas, rasterized again only when it changes" {
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{});
    defer t.deinit();
    t.frame();
    const im = &t.text.images;
    try testing.expectEqual(@as(usize, 1), im.decoded.count());
    // The circle's center (10 + 20, 10 + 30) is red; outside it, the window.
    const inside = try windowPixel(&t, 30, 40);
    try testing.expect(inside[2] > 250 and inside[1] < 5);
    const outside = try windowPixel(&t, 100, 40);
    try testing.expectEqual(@as(u8, 0xf5), outside[2]);
    const gen = im.generation;
    t.frame();
    t.frame();
    try testing.expectEqual(gen, im.generation);
    // Moved: drawn again, and the old picture let go.
    s.x = 70;
    t.frame();
    try testing.expectEqual(@as(usize, 1), im.decoded.count());
    const moved = try windowPixel(&t, 80, 40);
    try testing.expect(moved[2] > 250);
    const left = try windowPixel(&t, 30, 40);
    try testing.expectEqual(@as(u8, 0xf5), left[2]);
}
