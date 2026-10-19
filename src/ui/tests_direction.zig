//! Right to left through `Tester`: rows from the right, alignment and
//! padding mirrored, a box kept left to right inside, overlays in place,
//! the direction from a locale, and the arrows widgets read.
const std = @import("std");
const ui = @import("ui.zig");
const direction = @import("direction.zig");
const testing = std.testing;
const Key = @import("context.zig").Key;

const Page = struct {
    ltr_inside: bool = false,
    seen: direction.Direction = .ltr,
    inner_seen: direction.Direction = .rtl,
    arrow_forth: Key = .right,
    along: f32 = 0,

    fn view(s: *Page, c: *ui.Context) void {
        s.seen = direction.current(c);
        s.arrow_forth = direction.arrows(c).forth;
        s.along = direction.alongLine(c, 0.75);
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .{ .left = 20 }, .gap = 8 });
        defer ui.end(c);
        ui.row(c, .{ .gap = 10 });
        ui.text(c, "Back", .{});
        ui.text(c, "Title", .{});
        ui.end(c);
        const i = c.open(.{ .direction = .row, .gap = 10 }, "player");
        if (s.ltr_inside) direction.scope(c, i, .ltr);
        s.inner_seen = direction.current(c);
        ui.text(c, "Play", .{});
        ui.text(c, "Next", .{});
        c.end();
        // A box offset from the start.
        ui.column(c, .{ .width = .fill, .height = .{ .px = 30 } });
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 10 }, .width = .{ .px = 40 }, .height = .{ .px = 10 } }, .{ .text = .{ .str = "Pin", .style = .{}, .color = c.theme.text } }, null);
        ui.end(c);
        // An overlay placed in the window's coordinates.
        _ = c.openOverlay(.{ .absolute = true, .offset = .{ .x = 30, .y = 200 }, .direction = .row, .gap = 4 }, "tip");
        ui.text(c, "One", .{});
        ui.text(c, "Two", .{});
        c.end();
    }
};

test "direction: left to right by default" {
    var s: Page = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Page.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    try testing.expectEqual(direction.Direction.ltr, s.seen);
    const back = t.findText("Back").?;
    const title = t.findText("Title").?;
    try testing.expectEqual(@as(f32, 20), back.x);
    try testing.expect(title.x > back.x);
}

test "direction: right to left mirrors rows, alignment, padding and offsets" {
    var s: Page = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Page.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    direction.set(&t.ctx, .rtl);
    t.frame();
    try testing.expectEqual(direction.Direction.rtl, s.seen);
    try testing.expectEqual(Key.left, s.arrow_forth);
    const back = t.findText("Back").?;
    const title = t.findText("Title").?;
    // The padding on the left is on the right; the row starts at the right.
    try testing.expectEqual(@as(f32, 400 - 20), back.x + back.w);
    try testing.expect(title.x + title.w < back.x);
    try testing.expectEqual(@as(f32, 10), back.x - (title.x + title.w));
    // Offset from the right.
    const pin = t.findText("Pin").?;
    try testing.expectEqual(@as(f32, 400 - 20 - 10 - 40), pin.x);
    // The overlay keeps its place, its row inside goes from the right.
    const one = t.findText("One").?;
    const two = t.findText("Two").?;
    try testing.expect(two.x < one.x);
    try testing.expectEqual(@as(f32, 30), two.x);
    // Clicks follow what is drawn.
    try testing.expect(t.ctx.rects.get(t.ctx.nodes.items[1].id) != null);
}

test "direction: a box of its own stays left to right inside a right-to-left window" {
    var s: Page = .{ .ltr_inside = true };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Page.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    direction.set(&t.ctx, .rtl);
    t.frame();
    try testing.expectEqual(direction.Direction.ltr, s.inner_seen);
    const play = t.findText("Play").?;
    const next = t.findText("Next").?;
    // Left to right inside, the box itself at the right.
    try testing.expect(next.x > play.x);
    try testing.expectEqual(@as(f32, 380), next.x + next.w);
}

test "direction: from the locale" {
    var s: Page = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Page.view), .{});
    defer t.deinit();
    direction.fromLocale(&t.ctx, "ar-EG");
    t.frame();
    try testing.expectEqual(direction.Direction.rtl, direction.window(&t.ctx));
    direction.fromLocale(&t.ctx, "fr-FR");
    t.frame();
    try testing.expectEqual(direction.Direction.ltr, s.seen);
    direction.set(&t.ctx, .rtl);
    t.frame();
    try testing.expectEqual(@as(f32, 0.25), s.along);
}
