//! A window whose content stopped changing asks for nothing more, after
//! mygo's: no frame, no frame later, nothing animating, and a frame built
//! anyway draws nothing (`damage.zig`), whatever settled it. A window left
//! open all day otherwise spends battery on frames that draw what shows.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const popover = @import("popover.zig");
const damage = @import("damage.zig");
const Theme = @import("theme.zig").Theme;

const Counter = struct {
    n: i32 = 0,
    on: bool = false,
    name: ui.TextBuffer = .{},
    fn view(s: *Counter, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .gap = 16 });
        defer ui.end(c);
        ui.textf(c, .{ .size = 56, .weight = .bold }, "{d}", .{s.n});
        {
            ui.row(c, .{ .gap = 8 });
            defer ui.end(c);
            if (ui.button(c, "Decrement", .{}).clicked) s.n -= 1;
            const inc = ui.button(c, "Increment", .{ .variant = .primary });
            popover.tooltip(c, inc, "Count up");
            if (inc.clicked) s.n += 1;
        }
        _ = ui.toggle(c, "Switch", &s.on);
        _ = ui.textField(c, &s.name, .{ .placeholder = "Name" });
    }
};

/// Settled: nothing animates or asks for a frame, and a frame drawn
/// again draws nothing.
fn expectAsleep(t: *ui.Tester, what: []const u8) !void {
    // Transitions and the tooltip's delay end within ten seconds.
    t.advance(10);
    const px = t.pixelSize();
    var d: damage.Differ = .init(testing.allocator);
    defer d.deinit();
    const f = struct {
        fn f(x: *ui.Tester, w: usize, h: usize) damage.Frame {
            return .{ .instances = x.instances.items, .width = @intCast(w), .height = @intCast(h), .scale = x.scale, .clear = x.theme.background, .atlas = damage.atlasKey(&x.text.atlas), .images = x.text.images.generation };
        }
    }.f;
    _ = d.diff(f(t, px[0], px[1]));
    d.remember(f(t, px[0], px[1]));
    t.frame();
    const again = d.diff(f(t, px[0], px[1]));
    if (t.ctx.animating or t.ctx.frame_in != null or again == null or again.?.len != 0) {
        std.debug.print("{s}, then settled: animating {}, a frame in {?d} s, drawing again {?d} rectangles\n", .{ what, t.ctx.animating, t.ctx.frame_in, if (again) |a| a.len else null });
        return error.TestUnexpectedResult;
    }
}

test "a settled window asks for nothing more, whatever settled it" {
    const gpa = testing.allocator;
    var s: Counter = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Counter.view), .{ .width = 360, .height = 300 });
    defer t.deinit();
    try expectAsleep(&t, "opened");
    const inc = t.findText("Increment").?;
    t.moveTo(inc.x + inc.w / 2, inc.y + inc.h / 2);
    try expectAsleep(&t, "pointed at a button with a tooltip");
    try testing.expect(t.hasText("Count up"));
    try t.clickText("Increment");
    try expectAsleep(&t, "clicked");
    try testing.expectEqual(@as(i32, 1), s.n);
    try t.clickText("Switch");
    try expectAsleep(&t, "toggled a switch");
    try testing.expect(s.on);
    try t.clickText("Name");
    t.typeText("hi");
    try expectAsleep(&t, "typed into a text field");
    t.key(.escape);
    t.moveTo(5, 5);
    try expectAsleep(&t, "left the field");
    t.theme = Theme.dark_theme;
    t.frame();
    try expectAsleep(&t, "switched to dark");
    t.resize(400, 320);
    try expectAsleep(&t, "resized");
}
