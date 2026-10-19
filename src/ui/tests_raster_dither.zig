//! The CPU renderer's dithering of gradients and shadows, and pictures
//! drawn from a part of a sheet, pixelated.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const raster = @import("raster.zig");
const lanes = @import("raster_lanes.zig");

const dark = [_]ui.Stop{ .{ .color = ui.Color.hex(0x202020), .at = 0 }, .{ .color = ui.Color.hex(0x404040), .at = 1 } };
const subtle: ui.Gradient = .{ .stops = &dark, .angle = 90 };

const Ramp = struct {
    fn view(_: *Ramp, c: *ui.Context) void {
        _ = c.open(.{ .width = .{ .px = 400 }, .height = .{ .px = 40 }, .gradient = &subtle }, null);
        c.end();
    }
};

test "the dither is the 64 levels of an 8×8 ordered pattern, lane by lane as pixel by pixel" {
    var seen: [64]bool = @splat(false);
    for (0..8) |y| for (0..8) |x| {
        const n = raster.ditherAt(x, y);
        try testing.expect(@abs(n) < 0.5 / 255.0);
        const level: usize = @intFromFloat(@round((n * 255 + 0.5) * 64 - 0.5));
        try testing.expect(!seen[level]);
        seen[level] = true;
    };
    for ([_]usize{ 0, 3, 13, 800 }) |x| for ([_]usize{ 0, 5, 9 }) |y| {
        const v: [lanes.lanes]f32 = lanes.dither(x, y);
        for (v, 0..) |n, l| try testing.expectEqual(raster.ditherAt(x + l, y), n);
    };
}

test "a subtle gradient is dithered: its average follows the ramp, its ends are its stops" {
    var s: Ramp = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Ramp.view), .{ .width = 400, .height = 40, .scale = 2 });
    defer t.deinit();
    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    // Over each 8×8 block the levels average to the gradient's value there,
    // well within a level: rounding alone would be off by up to half.
    var worst: f32 = 0;
    var block: usize = 0;
    while (block < 100) : (block += 1) {
        var sum: f32 = 0;
        for (0..8) |y| for (0..8) |x| {
            sum += @floatFromInt(px.bytes[((8 + y) * px.width + block * 8 + x) * 4]);
        };
        const mid = (@as(f32, @floatFromInt(block)) * 8 + 4) / 800;
        const want = 0x20 + mid * 0x20;
        worst = @max(worst, @abs(sum / 64 - want));
    }
    try testing.expect(worst < 0.2);
    // Its ends are its stops' colors, within the dither.
    try testing.expect(px.bytes[(10 * px.width) * 4] -% 0x20 <= 1);
    try testing.expect(0x40 -% px.bytes[(10 * px.width + 799) * 4] <= 1);
}

const Sheet = struct {
    picture: []const u8,
    fn view(s: *Sheet, c: *ui.Context) void {
        // The second 2×2 sprite of a 4×2 sheet, drawn 40 points across.
        _ = ui.image(c, .{ .key = "sheet", .bytes = s.picture, .source = .{ .x = 2, .y = 0, .w = 2, .h = 2 }, .pixelated = true, .size = .{ .w = 40, .h = 40 }, .radius = 0 });
    }
};

test "a sprite of a sheet, pixelated, is drawn in squares of its texels" {
    const gpa = testing.allocator;
    // Four columns: red, green, then blue over white, and white over blue.
    var px: [4 * 2 * 4]u8 = undefined;
    const colors = [_][4]u8{ .{ 0, 0, 255, 255 }, .{ 0, 255, 0, 255 }, .{ 255, 0, 0, 255 }, .{ 255, 255, 255, 255 } };
    for (0..2) |y| for (0..4) |x| {
        const k = if (x < 2) x else if (y == 0) 2 + (x - 2) else 3 - (x - 2);
        px[(y * 4 + x) * 4 ..][0..4].* = colors[k];
    };
    const picture = try @import("png.zig").encode(gpa, .{ .bytes = &px, .width = 4, .height = 2 });
    defer gpa.free(picture);
    var s: Sheet = .{ .picture = picture };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Sheet.view), .{ .width = 40, .height = 40, .scale = 2 });
    defer t.deinit();
    const out = try t.render(gpa);
    defer out.deinit(gpa);
    const at = struct {
        fn f(o: @TypeOf(out), x: usize, y: usize) [4]u8 {
            return o.bytes[(y * o.width + x) * 4 ..][0..4].*;
        }
    }.f;
    // Each texel is a 40×40 pixel square of one color, right to its edges.
    try testing.expectEqual(colors[2], at(out, 1, 1));
    try testing.expectEqual(colors[2], at(out, 39, 39));
    try testing.expectEqual(colors[3], at(out, 40, 0));
    try testing.expectEqual(colors[3], at(out, 79, 39));
    try testing.expectEqual(colors[3], at(out, 0, 40));
    try testing.expectEqual(colors[2], at(out, 79, 79));
}
