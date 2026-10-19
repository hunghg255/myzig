//! Focus groups through `Tester`: one stop of Tab, arrows among the
//! controls, Home and End, the control focused last, right to left.
const std = @import("std");
const ui = @import("ui.zig");
const fg = @import("focusgroup.zig");
const direction = @import("direction.zig");
const testing = std.testing;
const S = ui.Shortcut;

const Bar = struct {
    orientation: fg.Orientation = .horizontal,
    entry: ?usize = null,
    clicks: [3]u32 = @splat(0),
    after: u32 = 0,
    result: fg.Result = .{},

    fn view(s: *Bar, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(10), .gap = 10 });
        defer ui.end(c);
        if (ui.button(c, "Before", .{}).clicked) {}
        const g = fg.focusGroup(c, .{ .direction = .row, .gap = 4 }, .{ .orientation = s.orientation, .entry = s.entry });
        for ([_][]const u8{ "Bold", "Italic", "Underline" }, 0..) |name, i| {
            if (ui.button(c, name, .{}).clicked) s.clicks[i] += 1;
        }
        s.result = g.end();
        if (ui.button(c, "After", .{}).clicked) s.after += 1;
    }
};

fn tab(t: *ui.Tester, back: bool) void {
    _ = t.shortcut(.{ .key = S.tab, .shift = back });
}

fn focusedText(t: *ui.Tester, name: []const u8) bool {
    const r = t.findText(name) orelse return false;
    for (t.ctx.nodes.items) |n| if (n.id == t.ctx.focus) return n.rect.contains(.{ .x = r.x + 1, .y = r.y + 1 });
    return false;
}

test "focus group: one stop of Tab, the arrows move among its controls" {
    var s: Bar = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Bar.view), .{});
    defer t.deinit();
    try testing.expectEqual(@as(usize, 3), t.ctx.focus_order.items.len);
    try testing.expectEqual(@as(usize, 3), s.result.count);
    tab(&t, false);
    try testing.expect(focusedText(&t, "Before"));
    tab(&t, false);
    try testing.expect(focusedText(&t, "Bold"));
    tab(&t, false);
    try testing.expect(focusedText(&t, "After"));
    tab(&t, true);
    try testing.expect(focusedText(&t, "Bold"));
    t.key(.right);
    try testing.expect(focusedText(&t, "Italic"));
    try testing.expect(t.ctx.focus_visible);
    t.key(.right);
    t.key(.right);
    // Around from the last to the first.
    try testing.expect(focusedText(&t, "Bold"));
    t.key(.end);
    try testing.expect(focusedText(&t, "Underline"));
    try testing.expectEqual(@as(?usize, 2), s.result.focused);
    t.key(.home);
    t.key(.right);
    // Out and back in: to the control focused last.
    tab(&t, false);
    try testing.expect(focusedText(&t, "After"));
    tab(&t, true);
    try testing.expect(focusedText(&t, "Italic"));
    // Enter still clicks the focused control.
    t.key(.enter);
    try testing.expectEqual(@as(u32, 1), s.clicks[1]);
}

test "focus group: the entry, a vertical orientation, right to left" {
    var s: Bar = .{ .entry = 2, .orientation = .vertical };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Bar.view), .{});
    defer t.deinit();
    tab(&t, false);
    tab(&t, false);
    try testing.expect(focusedText(&t, "Underline"));
    // Left and Right are not its arrows.
    t.key(.right);
    try testing.expect(focusedText(&t, "Underline"));
    t.key(.up);
    try testing.expect(focusedText(&t, "Italic"));

    s.orientation = .horizontal;
    direction.set(&t.ctx, .rtl);
    t.frame();
    t.key(.left);
    try testing.expect(focusedText(&t, "Underline"));
    t.key(.right);
    try testing.expect(focusedText(&t, "Italic"));
}
