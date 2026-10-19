//! Transforms, gradients, blurred layers and backdrop effects drawn by the
//! CPU renderer, through `ui.Tester`: what shows where, and the pointer
//! following boxes as they are drawn.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const Affine = types.Affine;

const red: types.Color = .{ .r = 1, .g = 0, .b = 0 };
const blue: types.Color = .{ .r = 0, .g = 0, .b = 1 };

/// One box of `style` at (40, 40), 80 × 40, over white; it reports clicks.
const One = struct {
    style: types.Style,
    clicks: u32 = 0,
    fn view(s: *One, c: *ui.Context) void {
        _ = c.open(.{ .width = .fill, .height = .fill, .background = .white, .padding = .all(40) }, null);
        defer c.end();
        var st = s.style;
        st.width = .{ .px = 80 };
        st.height = .{ .px = 40 };
        const box = c.open(st, "box");
        if (c.interact(box, .{}).clicked) s.clicks += 1;
        c.end();
    }
};

fn pixel(px: gpu.Pixels, x: usize, y: usize) [4]u8 {
    return px.bytes[(y * px.width + x) * 4 ..][0..4].*;
}

fn isRed(p: [4]u8) bool {
    return p[2] > 240 and p[1] < 15 and p[0] < 15;
}

fn isWhite(p: [4]u8) bool {
    return p[0] > 240 and p[1] > 240 and p[2] > 240;
}

fn tester(t: *ui.Tester, s: *One) !void {
    try t.init(testing.allocator, .init(s, One.view), .{ .width = 200, .height = 120, .scale = 1 });
}

test "a turned box draws turned about its center, and takes the pointer where it is drawn" {
    var s: One = .{ .style = .{ .background = red, .transform = .rotation(90) } };
    var t: ui.Tester = undefined;
    try tester(&t, &s);
    defer t.deinit();
    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    // Turned a quarter about (80, 60): 40 wide, 80 tall, from (60, 20) to (100, 100).
    try testing.expect(isRed(pixel(px, 80, 25)));
    try testing.expect(isRed(pixel(px, 80, 95)));
    try testing.expect(isWhite(pixel(px, 45, 60)));
    try testing.expect(isWhite(pixel(px, 115, 60)));
    // Its general path draws a quarter turn as the plain path draws the box it makes.
    var plain: One = .{ .style = .{ .background = red } };
    var tp: ui.Tester = undefined;
    try tester(&tp, &plain);
    defer tp.deinit();
    // Where the layout had it, the pointer finds nothing; where it shows, the box.
    t.click(45, 60);
    try testing.expectEqual(@as(u32, 0), s.clicks);
    t.click(80, 25);
    try testing.expectEqual(@as(u32, 1), s.clicks);
}

test "a quarter turn of a square draws what the square draws, on the general path" {
    const Sq = struct {
        turn: bool,
        fn view(s: *@This(), c: *ui.Context) void {
            _ = c.open(.{ .width = .fill, .height = .fill, .background = .white, .padding = .all(20) }, null);
            defer c.end();
            _ = c.open(.{ .width = .{ .px = 50 }, .height = .{ .px = 50 }, .radius = 9, .background = red, .border = blue, .border_width = 3, .shadow = .{ .blur = 8, .y = 0 }, .transform = if (s.turn) .rotation(90) else null }, null);
            c.end();
        }
    };
    var a: Sq = .{ .turn = true };
    var b: Sq = .{ .turn = false };
    var ta: ui.Tester = undefined;
    try ta.init(testing.allocator, .init(&a, Sq.view), .{ .width = 100, .height = 100, .scale = 2 });
    defer ta.deinit();
    var tb: ui.Tester = undefined;
    try tb.init(testing.allocator, .init(&b, Sq.view), .{ .width = 100, .height = 100, .scale = 2 });
    defer tb.deinit();
    try testing.expect(gpu.transformOf(ta.instances.items[2].kind) != null);
    const pa = try ta.render(testing.allocator);
    defer pa.deinit(testing.allocator);
    const pb = try tb.render(testing.allocator);
    defer pb.deinit(testing.allocator);
    var worst: u8 = 0;
    for (pa.bytes, pb.bytes) |x, y| worst = @max(worst, if (x > y) x - y else y - x);
    try testing.expect(worst <= 2);
}

test "a box moved and scaled alike both ways stays a plain box, drawn as the box it becomes" {
    var s: One = .{ .style = .{ .background = red, .radius = 4, .transform = Affine.scaling(0.5, 0.5).then(.translation(30, 0)) } };
    var t: ui.Tester = undefined;
    try tester(&t, &s);
    defer t.deinit();
    for (t.instances.items) |i| try testing.expect(gpu.transformOf(i.kind) == null);
    // 40 × 20 about the center (80, 60), then 30 right: (90, 50) to (130, 70).
    const box = t.instances.items[2];
    try testing.expectEqual([4]f32{ 90, 50, 40, 20 }, box.rect);
    try testing.expectEqual(@as(f32, 2), box.radius);
    t.click(125, 55);
    try testing.expectEqual(@as(u32, 1), s.clicks);
    t.click(45, 45);
    try testing.expectEqual(@as(u32, 1), s.clicks);
}

test "transforms nest: a child's acts first, then its parent's" {
    const Nest = struct {
        fn view(_: *@This(), c: *ui.Context) void {
            _ = c.open(.{ .width = .fill, .height = .fill, .background = .white }, null);
            defer c.end();
            _ = c.open(.{ .absolute = true, .offset = .{ .x = 40, .y = 40 }, .width = .{ .px = 40 }, .height = .{ .px = 40 }, .transform = .translation(50, 0) }, null);
            defer c.end();
            _ = c.open(.{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .background = red, .transform = .translation(0, 10) }, null);
            c.end();
        }
    };
    var n: Nest = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&n, Nest.view), .{ .width = 200, .height = 120, .scale = 1 });
    defer t.deinit();
    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    try testing.expect(isRed(pixel(px, 95, 55)));
    try testing.expect(isWhite(pixel(px, 45, 45)));
}

test "a box flattened to nothing shows nothing and takes no pointer" {
    var s: One = .{ .style = .{ .background = red, .transform = .scaling(0, 1) } };
    var t: ui.Tester = undefined;
    try tester(&t, &s);
    defer t.deinit();
    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    try testing.expect(isWhite(pixel(px, 80, 60)));
    t.click(80, 60);
    try testing.expectEqual(@as(u32, 0), s.clicks);
}

test "a slanted box's text and children are drawn slanted, and hit there" {
    var s: One = .{ .style = .{ .background = red, .transform = .skewing(45, 0) } };
    var t: ui.Tester = undefined;
    try tester(&t, &s);
    defer t.deinit();
    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    // Slanted 45° about its center (y 60): its top moves left 20, its bottom right 20.
    try testing.expect(isRed(pixel(px, 25, 42)));
    try testing.expect(isWhite(pixel(px, 115, 42)));
    try testing.expect(isRed(pixel(px, 135, 78)));
    t.click(135, 78);
    try testing.expectEqual(@as(u32, 1), s.clicks);
}

test "gradients fill a box: linear across, radial out, conic around, within its corners" {
    const stops = [_]types.Stop{ .{ .color = red, .at = 0 }, .{ .color = blue, .at = 1 } };
    var s: One = .{ .style = .{ .gradient = &.{ .stops = &stops, .angle = 90 } } };
    var t: ui.Tester = undefined;
    try tester(&t, &s);
    defer t.deinit();
    var px = try t.render(testing.allocator);
    try testing.expect(isRed(pixel(px, 40, 60)) or pixel(px, 40, 60)[2] > 235);
    try testing.expect(pixel(px, 119, 60)[0] > 235);
    const mid = pixel(px, 80, 60);
    try testing.expect(mid[0] > 110 and mid[0] < 145 and mid[2] > 110 and mid[2] < 145);
    px.deinit(testing.allocator);
    s.style.gradient = &.{ .kind = .radial, .stops = &stops, .radius = 20 };
    s.style.radius = 20;
    t.frame();
    px = try t.render(testing.allocator);
    try testing.expect(isRed(pixel(px, 80, 60)));
    try testing.expect(pixel(px, 105, 60)[0] > 235);
    // The rounded corner: white.
    try testing.expect(isWhite(pixel(px, 41, 41)));
    px.deinit(testing.allocator);
    s.style.gradient = &.{ .kind = .conic, .stops = &stops };
    s.style.radius = 0;
    t.frame();
    px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    // Just right of up, red; just left of it, nearly blue; down, the middle.
    try testing.expect(pixel(px, 82, 42)[2] > 230);
    try testing.expect(pixel(px, 78, 42)[0] > 230);
    const down = pixel(px, 80, 78);
    try testing.expect(down[0] > 100 and down[2] > 100);
}

test "a blurred box spreads past its edges, its middle its color" {
    var s: One = .{ .style = .{ .background = red, .blur = 3 } };
    var t: ui.Tester = undefined;
    try tester(&t, &s);
    defer t.deinit();
    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    try testing.expect(isRed(pixel(px, 80, 60)));
    // Just outside its edge, pink; well outside, white.
    const edge = pixel(px, 38, 60);
    try testing.expect(edge[2] > 240 and edge[1] < 230 and edge[1] > 40);
    try testing.expect(isWhite(pixel(px, 25, 60)));
    // Its edge's middle is half red.
    const half = pixel(px, 40, 60);
    try testing.expect(half[1] > 90 and half[1] < 170);
}

const Frosted = struct {
    e: types.Effect,
    fn view(s: *Frosted, c: *ui.Context) void {
        _ = c.open(.{ .width = .fill, .height = .fill, .background = .white, .direction = .row }, null);
        defer c.end();
        // Stripes, 4 points wide, black and white.
        for (0..50) |k| {
            _ = c.open(.{ .width = .{ .px = 4 }, .height = .fill, .background = if (k % 2 == 0) types.Color.black else types.Color.white }, null);
            c.end();
        }
        _ = c.open(.{ .absolute = true, .offset = .{ .x = 40, .y = 30 }, .width = .{ .px = 100 }, .height = .{ .px = 60 }, .radius = 12, .effect = &s.e }, null);
        // On the pane, a red dot: drawn after the effect, not frosted.
        _ = c.open(.{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .background = red }, null);
        c.end();
        c.end();
    }
};

test "a backdrop effect frosts what is under it, under its children" {
    var s: Frosted = .{ .e = .{ .blur = 4 } };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Frosted.view), .{ .width = 200, .height = 120, .scale = 1 });
    defer t.deinit();
    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    // Gray under the pane, stripes beside it.
    const g = pixel(px, 90, 60);
    try testing.expect(g[0] > 100 and g[0] < 155);
    try testing.expect(pixel(px, 20, 60)[0] < 10 or pixel(px, 20, 60)[0] > 245);
    try testing.expect(isRed(pixel(px, 45, 35)));
    // The pane's rounded corner leaves the stripes as they are.
    const corner = pixel(px, 40, 30);
    try testing.expect(corner[0] < 10 or corner[0] > 245);
}

test "an effect's shader colors the pane from the backdrop, on the CPU by its twin" {
    const Invert = struct {
        fn color(in: *const @import("effect.zig").Input) [3]f32 {
            const b = in.sample(in.p[0], in.p[1]);
            return .{ 1 - b[0], in.params[0][1], 1 - b[2] };
        }
        const shader: @import("effect.zig").Shader = .{ .name = "invert", .cpu = color };
    };
    var s: Frosted = .{ .e = .{ .blur = 0, .shader = &Invert.shader, .params = .{ .{ 0, 0.5, 0, 0 }, @splat(0), @splat(0), @splat(0) } } };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Frosted.view), .{ .width = 200, .height = 120, .scale = 1 });
    defer t.deinit();
    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    // Black stripe at x 80..84 inverted to white (green from the params).
    const p = pixel(px, 81, 60);
    try testing.expect(p[2] > 245 and p[0] > 245);
    try testing.expect(p[1] > 120 and p[1] < 135);
}
