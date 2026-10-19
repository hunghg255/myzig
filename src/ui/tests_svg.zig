//! SVG documents: what they draw, pixel by pixel, and `ui.svg` through `Tester`.
const std = @import("std");
const ui = @import("ui.zig");
const svg = @import("svg.zig");
const testing = std.testing;

fn at(px: []const u8, w: usize, x: usize, y: usize) [4]u8 {
    return px[(y * w + x) * 4 ..][0..4].*;
}

fn draw(doc: []const u8, w: usize, h: usize) ![]u8 {
    return svg.rasterize(testing.allocator, doc, w, h, .{ .g = 0.5 });
}

test "the viewBox fits the pixels; shapes fill and stroke in place" {
    const px = try draw(
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
        \\  <rect x="0" y="0" width="5" height="5" fill="#f00"/>
        \\  <circle cx="7.5" cy="7.5" r="2" fill="blue" stroke="black" stroke-width="1"/>
        \\  <line x1="0" y1="9" x2="4" y2="9" stroke="lime"/>
        \\</svg>
    , 20, 20);
    defer testing.allocator.free(px);
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(px, 20, 4, 4));
    try testing.expectEqual(@as(u8, 0), at(px, 20, 12, 4)[3]);
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, at(px, 20, 15, 15));
    // The stroke on the circle's edge, 4 units out from its center.
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, at(px, 20, 15, 11));
    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, at(px, 20, 3, 18));
}

test "groups: transforms, inherited paint, opacity in a layer, classes, use" {
    const px = try draw(
        \\<svg viewBox="0 0 40 20" width="40" height="20">
        \\  <style>.half { fill-opacity: .5 } #big { fill: blue }</style>
        \\  <g fill="red" transform="translate(20 0)">
        \\    <rect id="sq" width="10" height="10"/>
        \\    <rect class="half" y="10" width="10" height="10"/>
        \\  </g>
        \\  <g opacity="0.5" fill="black"><rect width="8" height="8"/><rect x="4" width="8" height="8"/></g>
        \\  <use href="#sq" y="10" style="fill:currentColor"/>
        \\  <rect id="big" x="32" width="8" height="8" fill="red"/>
        \\</svg>
    , 40, 20);
    defer testing.allocator.free(px);
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(px, 40, 25, 5));
    try testing.expectEqual(@as(u8, 128), at(px, 40, 25, 15)[3]);
    // The layer's overlap is no darker than the rest.
    try testing.expectEqual(at(px, 40, 2, 2), at(px, 40, 6, 2));
    try testing.expectEqual(@as(u8, 128), at(px, 40, 6, 2)[3]);
    // `use` draws the square again, 10 lower, in the inherited currentColor
    // (the rect's own fill is the group's red, not inherited by the use).
    try testing.expectEqual(@as(u8, 255), at(px, 40, 5, 15)[3]);
    // The style sheet's #id outranks the attribute.
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, at(px, 40, 35, 4));
}

test "gradients by reference, in the box's units and the user's" {
    const px = try draw(
        \\<svg viewBox="0 0 100 20">
        \\  <defs>
        \\    <linearGradient id="a"><stop offset="0" stop-color="#f00"/><stop offset="100%" style="stop-color:#00f"/></linearGradient>
        \\    <linearGradient id="b" href="#a" gradientUnits="userSpaceOnUse" x1="0" x2="200"/>
        \\  </defs>
        \\  <rect width="100" height="10" fill="url(#a)"/>
        \\  <rect y="10" width="100" height="10" fill="url(#b)"/>
        \\</svg>
    , 100, 20);
    defer testing.allocator.free(px);
    try testing.expect(at(px, 100, 0, 5)[2] > 245);
    try testing.expect(at(px, 100, 99, 5)[0] > 245);
    // In user units it runs to 200: halfway at the right edge.
    try testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(at(px, 100, 99, 15)[0])), 4);
}

test "fill rules, clip paths and path data" {
    const px = try draw(
        \\<svg viewBox="0 0 30 10">
        \\  <path fill-rule="evenodd" d="M0 0h10v10H0z M3 3h4v4H3z"/>
        \\  <clipPath id="c"><circle cx="15" cy="5" r="4"/></clipPath>
        \\  <rect x="10" width="10" height="10" fill="red" clip-path="url(#c)"/>
        \\  <path d="M20 0 l10 10 h-10 z" fill="blue"/>
        \\</svg>
    , 30, 10);
    defer testing.allocator.free(px);
    try testing.expectEqual(@as(u8, 255), at(px, 30, 1, 1)[3]);
    try testing.expectEqual(@as(u8, 0), at(px, 30, 5, 5)[3]);
    try testing.expectEqual(@as(u8, 255), at(px, 30, 15, 5)[3]);
    try testing.expectEqual(@as(u8, 0), at(px, 30, 10, 0)[3]);
    try testing.expectEqual(@as(u8, 255), at(px, 30, 21, 8)[3]);
    try testing.expectEqual(@as(u8, 0), at(px, 30, 28, 1)[3]);
}

test "a document's own size, and sizes asked for" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(ui.Size{ .w = 24, .h = 12 }, svg.rootSize(a, "<!-- <svg width='1'> --><svg viewBox='0 0 24 12'></svg>").?);
    try testing.expectEqual(ui.Size{ .w = 48, .h = 24 }, svg.rootSize(a, "<svg width='48' viewBox='0 0 24 12'/>").?);
    try testing.expectEqual(ui.Size{ .w = 10, .h = 5 }, svg.fitSize(.{ .w = 24, .h = 12 }, 10, 0));
    try testing.expect(svg.rootSize(a, "<html></html>") == null);
}

const icon =
    \\<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="8" fill="currentColor"/></svg>
;

const Icons = struct {
    shown: bool = false,
    fn view(s: *Icons, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(10) });
        defer ui.end(c);
        s.shown = svg.svg(c, icon, .{ .width = 32, .color = .{ .r = 1 } });
        _ = svg.svg(c, "not svg", .{});
    }
};

test "ui.svg sizes itself from the document and draws in currentColor" {
    var s: Icons = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Icons.view), .{});
    defer t.deinit();
    try testing.expect(s.shown);
    var rect: ?ui.Rect = null;
    for (t.ctx.nodes.items) |n| if (n.content == .image) {
        rect = n.rect;
    };
    try testing.expectEqual(ui.Rect{ .x = 10, .y = 10, .w = 32, .h = 32 }, rect.?);
    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    const center = px.bytes[((26 * 2) * px.width + 26 * 2) * 4 ..][0..4];
    try testing.expect(center[2] > 250 and center[1] < 5);
    const gen = t.text.images.generation;
    t.frame();
    try testing.expectEqual(gen, t.text.images.generation);
}
