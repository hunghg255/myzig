//! Debug builds tell of a press lost because the box pressed changed its
//! id: a mark shown on hover before a button moves the button's place.
const std = @import("std");
const ui = @import("ui.zig");
const testing = std.testing;
const press_check = @import("press_check.zig");

const Bar = struct {
    keyed: bool,
    /// The button was hovered in the last build: a mark before it shows.
    hover: bool = false,
    clicks: u32 = 0,

    fn view(s: *Bar, c: *ui.Context) void {
        ui.row(c, .{ .padding = .all(20), .gap = 4 });
        defer ui.end(c);
        if (s.hover) _ = c.leaf(.{ .width = .{ .px = 3 }, .height = .{ .px = 20 } }, .none, null);
        if (s.keyed) c.keyed(@as(u32, 1));
        const it = ui.button(c, "Open", .{});
        s.hover = it.hovered;
        if (it.clicked) s.clicks += 1;
    }
};

test "a press on a box whose id changed is told of, once; a keyed box takes it" {
    if (comptime !press_check.on) return error.SkipZigTest;
    var s: Bar = .{ .keyed = false };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Bar.view), .{});
    defer t.deinit();
    try t.clickText("Open");
    try testing.expectEqual(@as(u32, 0), s.clicks);
    try testing.expect(t.ctx.press_check.lost >= 1);
    try testing.expect(t.ctx.press_check.warned);

    var k: Bar = .{ .keyed = true };
    var tk: ui.Tester = undefined;
    try tk.init(testing.allocator, .init(&k, Bar.view), .{});
    defer tk.deinit();
    try tk.clickText("Open");
    try testing.expectEqual(@as(u32, 1), k.clicks);
    try testing.expectEqual(@as(u32, 0), tk.ctx.press_check.lost);
}

test "a box that closes on a press is not a lost press" {
    if (comptime !press_check.on) return error.SkipZigTest;
    const Pop = struct {
        open: bool = true,
        fn view(s: *@This(), c: *ui.Context) void {
            ui.column(c, .{ .padding = .all(20) });
            defer ui.end(c);
            _ = ui.button(c, "Under", .{});
            if (!s.open) return;
            const i = c.openOverlay(.{ .absolute = true, .width = .{ .px = 400 }, .height = .{ .px = 300 } }, "veil");
            if (c.interact(i, .{}).hovered and c.input.pressed) {
                s.open = false;
                c.changed = true;
            }
            c.end();
        }
    };
    var s: Pop = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Pop.view), .{});
    defer t.deinit();
    const r = t.findText("Under").?;
    t.click(r.x + r.w / 2, r.y + r.h / 2);
    try testing.expect(!s.open);
    try testing.expectEqual(@as(u32, 0), t.ctx.press_check.lost);
}
