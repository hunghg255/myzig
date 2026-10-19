//! The glass's tests: its effect over pixels (frosting, toning, the lens,
//! the rim, the plain blur), and panes in a view through `ui.Tester`,
//! rendered offscreen by the CPU renderer, the effect drawn over them.
const std = @import("std");
const testing = std.testing;
const glass = @import("glass");
const ui = @import("myzig").ui;

/// A `w`×`h` frame filled by `color(x, y)` (RGB).
fn frame(w: usize, h: usize, comptime color: fn (usize, usize) [3]u8) !glass.Image {
    const bytes = try testing.allocator.alloc(u8, w * h * 4);
    for (0..h) |y| for (0..w) |x| {
        const c = color(x, y);
        bytes[4 * (y * w + x) ..][0..4].* = .{ c[2], c[1], c[0], 255 };
    };
    return .{ .bytes = bytes, .width = w, .height = h };
}

fn at(img: glass.Image, x: usize, y: usize) [3]u8 {
    const p = img.bytes[4 * (y * img.width + x) ..][0..4];
    return .{ p[2], p[1], p[0] };
}

fn stripes(x: usize, _: usize) [3]u8 {
    return if (x % 8 < 4) .{ 0, 0, 0 } else .{ 255, 255, 255 };
}

fn blue(_: usize, _: usize) [3]u8 {
    return .{ 20, 120, 220 };
}

fn black(_: usize, _: usize) [3]u8 {
    return .{ 0, 0, 0 };
}

fn halves(x: usize, _: usize) [3]u8 {
    return if (x < 20) .{ 0, 0, 0 } else .{ 255, 255, 255 };
}

/// How far apart the darkest and lightest pixels of row `y` are, from `x0` to `x1`.
fn contrast(img: glass.Image, y: usize, x0: usize, x1: usize) u8 {
    var lo: u8 = 255;
    var hi: u8 = 0;
    for (x0..x1) |x| {
        lo = @min(lo, at(img, x, y)[0]);
        hi = @max(hi, at(img, x, y)[0]);
    }
    return hi - lo;
}

test "a blur blurs what is under it, and nothing else" {
    const img = try frame(200, 100, stripes);
    defer testing.allocator.free(img.bytes);
    try glass.pixels.blur(testing.allocator, img, .{ 50, 20, 100, 60 }, @splat(0), 6);
    try testing.expect(contrast(img, 50, 70, 130) < 8);
    try testing.expectEqual(@as(u8, 255), contrast(img, 50, 0, 40));
    try testing.expectEqual(@as(u8, 255), contrast(img, 10, 70, 130));
    // Gray where black and white blur together.
    try testing.expect(@abs(@as(i32, at(img, 100, 50)[0]) - 128) < 8);
}

test "regular glass lightens, dark glass darkens, clear glass barely tones" {
    var light: [3]u8 = undefined;
    for ([_]bool{ false, true }) |dark| {
        const img = try frame(300, 100, blue);
        defer testing.allocator.free(img.bytes);
        const m = glass.material.of(.regular, null, 200, 44, 1, dark);
        try glass.pixels.glass(testing.allocator, img, .{ 50, 28, 200, 44 }, @splat(22), m);
        const c = at(img, 150, 50);
        if (!dark) {
            light = c;
            try testing.expect(c[0] >= 100 and c[2] >= c[0]);
        } else try testing.expect(c[0] < light[0] and c[2] < light[2]);
    }
    const img = try frame(300, 100, blue);
    defer testing.allocator.free(img.bytes);
    try glass.pixels.glass(testing.allocator, img, .{ 50, 28, 200, 44 }, @splat(22), glass.material.of(.clear, null, 200, 44, 1, false));
    try testing.expect(at(img, 150, 50)[0] < light[0]);
    // Outside the pane, the frame is as it was.
    try testing.expectEqual([3]u8{ 20, 120, 220 }, at(img, 20, 50));
}

test "light glass over black is mid gray, tinted glass takes its tint" {
    const img = try frame(200, 120, black);
    defer testing.allocator.free(img.bytes);
    try glass.pixels.glass(testing.allocator, img, .{ 20, 20, 100, 60 }, @splat(20), glass.material.of(.regular, null, 100, 60, 1, false));
    const g = at(img, 70, 50);
    try testing.expect(g[0] >= 100 and g[0] <= 180 and g[0] == g[1] and g[1] == g[2]);
    try glass.pixels.glass(testing.allocator, img, .{ 20, 20, 100, 60 }, @splat(20), glass.material.of(.regular, .{ 1, 0, 0, 1 }, 100, 60, 1, false));
    const t = at(img, 70, 50);
    try testing.expect(t[0] > 200 and t[1] < 80);
}

test "the bezel bends what is under it toward the middle, and the rim is lit" {
    // Black left of x = 20, white right of it; a pane from x = 10.
    const img = try frame(160, 100, halves);
    defer testing.allocator.free(img.bytes);
    var m = glass.material.of(.regular, null, 100, 60, 1, false);
    m.rim = 0;
    try glass.pixels.glass(testing.allocator, img, .{ 10, 20, 100, 60 }, @splat(0), m);
    // At x = 12 the lens reads the white well inside; a blur would be black there.
    try testing.expect(at(img, 12, 50)[0] > 200);
    const flat = try frame(160, 100, halves);
    defer testing.allocator.free(flat.bytes);
    try glass.pixels.blur(testing.allocator, flat, .{ 10, 20, 100, 60 }, @splat(0), 2);
    try testing.expect(at(flat, 12, 50)[0] < 40);
    // The rim, along the top, lit from above: lighter than just below it.
    const gray = try frame(160, 100, black);
    defer testing.allocator.free(gray.bytes);
    try glass.pixels.glass(testing.allocator, gray, .{ 10, 20, 100, 60 }, @splat(0), glass.material.of(.regular, null, 100, 60, 1, false));
    try testing.expect(at(gray, 60, 20)[0] > at(gray, 60, 24)[0]);
}

const View = struct {
    fn build(_: *View, c: *ui.Context) void {
        _ = c.open(.{ .width = .fill, .height = .fill, .background = .hex(0x1478dc) }, null);
        defer c.end();
        _ = glass.pane(c, .{ .radius = 22 }, .{ .absolute = true, .offset = .{ .x = 50, .y = 28 }, .width = .{ .px = 200 }, .height = .{ .px = 44 } });
        // On the pane, a white dot: drawn over the glass, not frosted.
        _ = c.open(.{ .width = .{ .px = 4 }, .height = .{ .px = 4 }, .background = .white, .offset = .{ .x = 20, .y = 20 } }, null);
        c.end();
        c.end();
    }
};

test "a pane in a view is drawn by the renderer, as the effect over pixels draws it, under its children" {
    var v: View = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&v, View.build), .{ .width = 300, .height = 100, .scale = 2 });
    defer t.deinit();
    t.frame();
    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    const img: glass.Image = .{ .bytes = px.bytes, .width = px.width, .height = px.height };
    // Lighter glass over the blue, the blue beside it, the dot white on it.
    const c = at(img, 300, 100);
    try testing.expect(c[0] >= 100 and c[2] >= c[0]);
    try testing.expectEqual([3]u8{ 0x14, 0x78, 0xdc }, at(img, 20, 100));
    try testing.expectEqual([3]u8{ 255, 255, 255 }, at(img, 141, 97));
    // The renderer's glass is the effect over the pixels without it.
    const bare = try frame(600, 200, blue);
    defer testing.allocator.free(bare.bytes);
    const m = glass.material.of(.regular, null, 200, 44, 2, false);
    try glass.pixels.glass(testing.allocator, bare, .{ 100, 56, 400, 88 }, @splat(44), m);
    var worst: u8 = 0;
    for (100..140) |y| for (100..500) |x| {
        if (x >= 139 and x < 149 and y >= 95 and y < 105) continue;
        const a = at(img, x, y);
        const b = at(bare, x, y);
        for (0..3) |k| worst = @max(worst, if (a[k] > b[k]) a[k] - b[k] else b[k] - a[k]);
    };
    try testing.expect(worst <= 2);
}
