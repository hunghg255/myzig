//! A check box over a group of check boxes, after mygo's
//! `CheckboxGroup`, as a list of permissions: checked when they all are,
//! mixed (a dash) when some are; a click, or Space while it has the
//! focus, checks them all, or none when they all are.
//!
//!     _ = ui.checkboxGroup(c, "Notifications", &s.notify, &.{ "Mail", "Calendar", "Reminders" });
const std = @import("std");
const ctx_mod = @import("context.zig");
const widgets = @import("widgets.zig");
const Context = ctx_mod.Context;

/// The group's check box over one for each of `values`, named by
/// `labels`, indented below it; true when any changed.
pub fn checkboxGroup(c: *Context, title: []const u8, values: []bool, labels: []const []const u8) bool {
    std.debug.assert(values.len == labels.len);
    const th = c.theme;
    _ = c.open(.{ .gap = 8 }, null);
    defer c.end();
    var on: usize = 0;
    for (values) |v| on += @intFromBool(v);
    const all = on == values.len and on > 0;
    const mixed = on > 0 and !all;

    var changed = false;
    const it = widgets.pressable(c, .{ .direction = .row, .gap = 8, .align_items = .center, .control = true }, null);
    if (it.clicked) {
        for (values) |*v| v.* = !all;
        changed = true;
        c.changed = true;
    }
    const t = c.animate(it.id, 0, if (all or mixed) 1 else 0, 22);
    const hover = c.animate(it.id, 1, if (it.hovered) 1 else 0, 20);
    _ = c.open(.{
        .width = .{ .px = 18 },
        .height = .{ .px = 18 },
        .radius = 5,
        .background = th.surface.mix(th.surface_hover, hover * (1 - t)).mix(th.accent, t),
        .border = th.border.mix(th.accent, t),
        .align_items = .center,
        .justify = .center,
    }, null);
    if (mixed) {
        _ = c.leaf(.{ .width = .{ .px = 9 }, .height = .{ .px = 2 }, .radius = 1, .background = th.accent_text }, .none, null);
    } else if (t > 0.01) _ = c.leaf(.{ .opacity = t, .offset = .{ .y = -0.5 } }, .{ .text = .{
        .str = "✓",
        .style = .{ .size = 12, .weight = .bold },
        .color = th.accent_text,
    } }, null);
    c.end();
    widgets.text(c, title, .{});
    c.end();

    _ = c.open(.{ .gap = 8, .padding = .{ .left = 26 } }, null);
    for (values, labels) |*v, l| {
        if (widgets.checkbox(c, l, v)) changed = true;
    }
    c.end();
    return changed;
}

test "the group's box checks all, none, and shows when some are" {
    const ui = @import("ui.zig");
    const App = struct {
        v: [3]bool = .{ false, false, false },
        fn view(s: *@This(), c: *Context) void {
            _ = checkboxGroup(c, "Notifications", &s.v, &.{ "Mail", "Calendar", "Reminders" });
        }
    };
    var s: App = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&s, App.view), .{});
    defer t.deinit();
    try t.clickText("Notifications");
    try std.testing.expectEqual([3]bool{ true, true, true }, s.v);
    try t.clickText("Notifications");
    try std.testing.expectEqual([3]bool{ false, false, false }, s.v);
    try t.clickText("Calendar");
    try std.testing.expectEqual([3]bool{ false, true, false }, s.v);
    // Mixed: the click checks them all.
    try t.clickText("Notifications");
    try std.testing.expectEqual([3]bool{ true, true, true }, s.v);
}
