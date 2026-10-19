//! Overlays (`Context.openOverlay`): over everything else, wherever the
//! view opens them, and first to take the pointer.
const std = @import("std");
const ui = @import("ui.zig");
const testing = std.testing;

const Covered = struct {
    open: bool = true,
    clicks: u32 = 0,
    overlay_clicks: u32 = 0,
    outside: u32 = 0,

    fn view(s: *Covered, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        // Opened inside the column, before the button: still drawn over it.
        if (s.open) {
            const o = c.openOverlay(.{ .absolute = true, .offset = .{ .x = 10, .y = 10 }, .width = .{ .px = 200 }, .height = .{ .px = 60 }, .background = ui.Color.hex(0xff0000) }, "menu");
            const it = c.interact(o, .{});
            if (it.clicked) s.overlay_clicks += 1;
            if (c.pressedOutside(it.id)) {
                s.outside += 1;
                s.open = false;
                c.changed = true;
            }
            ui.text(c, "In the overlay", .{});
            ui.end(c);
        }
        if (ui.button(c, "Under", .{}).clicked) s.clicks += 1;
        ui.text(c, "Below", .{});
    }
};

test "an overlay is drawn over what follows it and takes the click" {
    var s: Covered = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Covered.view), .{});
    defer t.deinit();
    try testing.expect(t.hasText("In the overlay"));
    // The button lies under the overlay: clicking there clicks the overlay.
    const under = t.findText("Under").?;
    t.click(under.x + 4, under.y + under.h / 2);
    try testing.expectEqual(@as(u32, 1), s.overlay_clicks);
    try testing.expectEqual(@as(u32, 0), s.clicks);
    try testing.expectEqual(@as(u32, 0), s.outside);
    // Its pixels are the overlay's red, not the button's.
    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    const at = (@as(usize, @intFromFloat(under.y * 2 + under.h)) * px.width + @as(usize, @intFromFloat(under.x * 2 + 4))) * 4;
    try testing.expect(px.bytes[at + 2] > 200 and px.bytes[at + 1] < 60); // BGRA: red
}

test "a press outside an overlay closes it, and the view under it works again" {
    var s: Covered = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Covered.view), .{});
    defer t.deinit();
    const below = t.findText("Below").?;
    t.click(below.x + 2, below.y + below.h / 2);
    try testing.expectEqual(@as(u32, 1), s.outside);
    try testing.expect(!s.open);
    try testing.expect(!t.hasText("In the overlay"));
    try t.clickText("Under");
    try testing.expectEqual(@as(u32, 1), s.clicks);
}
