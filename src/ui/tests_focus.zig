//! The keyboard's focus: Tab goes through the controls in the order they
//! are built (Shift+Tab back), and a focused control answers its keys.
const std = @import("std");
const ui = @import("ui.zig");
const testing = std.testing;
const S = ui.Shortcut;

const Panel = struct {
    name: ui.TextBuffer = .{},
    saves: u32 = 0,
    agree: bool = false,
    volume: f32 = 0.5,

    fn view(s: *Panel, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        _ = ui.textField(c, &s.name, .{ .placeholder = "Name" });
        if (ui.button(c, "Save", .{}).clicked) s.saves += 1;
        _ = ui.checkbox(c, "Agree", &s.agree);
        _ = ui.slider(c, &s.volume, .{});
    }
};

fn tab(t: *ui.Tester, back: bool) void {
    _ = t.shortcut(.{ .key = S.tab, .shift = back });
}

test "Tab goes through the controls in order, around the end, and back with Shift" {
    var s: Panel = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Panel.view), .{});
    defer t.deinit();
    const order = try testing.allocator.dupe(u64, t.ctx.focus_order.items);
    defer testing.allocator.free(order);
    try testing.expectEqual(@as(usize, 4), order.len);
    try testing.expectEqual(@as(u64, 0), t.ctx.focus);
    for (order) |want| {
        tab(&t, false);
        try testing.expectEqual(want, t.ctx.focus);
        try testing.expect(t.ctx.focus_visible);
    }
    tab(&t, false);
    try testing.expectEqual(order[0], t.ctx.focus);
    tab(&t, true);
    try testing.expectEqual(order[3], t.ctx.focus);
    // A press puts the focus where it is, without the ring.
    try t.clickText("Save");
    try testing.expectEqual(order[1], t.ctx.focus);
    try testing.expect(!t.ctx.focus_visible);
}

test "a focused control takes its keys: Enter and Space click, arrows move a slider" {
    var s: Panel = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Panel.view), .{});
    defer t.deinit();
    // The field first: typing goes there.
    tab(&t, false);
    t.typeText("Ada");
    try testing.expectEqualStrings("Ada", s.name.text());
    tab(&t, false);
    try testing.expect(t.shortcut(.{ .key = S.enter }));
    try testing.expectEqual(@as(u32, 1), s.saves);
    tab(&t, false);
    try testing.expect(t.shortcut(.{ .key = ' ' }));
    try testing.expect(s.agree);
    tab(&t, false);
    t.key(.right);
    try testing.expect(s.volume > 0.5);
    t.key(.left);
    t.key(.left);
    try testing.expect(s.volume < 0.5);
    // Keys don't reach controls without the focus.
    try testing.expect(!t.shortcut(.{ .key = S.enter }));
    try testing.expectEqual(@as(u32, 1), s.saves);
}

const Held = struct {
    keys: [4]u21 = @splat(0),

    fn view(s: *Held, c: *ui.Context) void {
        c.wants_keys = true;
        if (c.input.key_down) |k| {
            if (std.mem.indexOfScalar(u21, &s.keys, 0)) |i| s.keys[i] = k;
        }
        if (c.input.key_up) |k| {
            if (std.mem.indexOfScalar(u21, &s.keys, k)) |i| s.keys[i] = 0;
        }
        ui.text(c, if (std.mem.indexOfScalar(u21, &s.keys, 'w') != null) "forward" else "still", .{});
    }
};

test "a view that follows keys sees them go down and up" {
    var s: Held = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Held.view), .{});
    defer t.deinit();
    try testing.expect(t.hasText("still"));
    t.keyEdge('w', true);
    t.keyEdge(S.up, true);
    try testing.expect(t.hasText("forward"));
    t.keyEdge('w', false);
    try testing.expect(t.hasText("still"));
    try testing.expect(std.mem.indexOfScalar(u21, &s.keys, S.up) != null);
}
