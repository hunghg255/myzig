//! Debug builds tell of a scrolled box whose id changed: a sticky line
//! shown now and then before an editor moves the editor's place, and its
//! offset starts over. And an empty scrolling box scrolls nowhere.
const std = @import("std");
const ui = @import("ui.zig");
const testing = std.testing;
const scroll_check = @import("scroll_check.zig");

const Pane = struct {
    keyed: bool = false,
    /// A line shown before the scrolling box.
    sticky: bool = false,
    /// Which of two lists shows, keyed apart (tabs).
    tab: u8 = 0,
    rows: usize = 60,
    id: u64 = 0,

    fn view(s: *Pane, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        if (ui.button(c, "Other", .{}).clicked) s.tab +%= 1;
        if (s.sticky) ui.text(c, "fn main() void {", .{});
        if (s.keyed) c.keyed(@as(u32, 7) + s.tab);
        s.id = c.peekId(null);
        ui.scroll(c, .{ .width = .fill, .grow = 1 });
        defer ui.end(c);
        for (0..s.rows) |i| ui.textf(c, .{}, "line {d}", .{i});
    }
};

fn setup(t: *ui.Tester, s: *Pane) !void {
    try t.init(testing.allocator, .init(s, Pane.view), .{ .width = 300, .height = 300 });
    t.frame();
    t.scroll(150, 200, -200);
    try testing.expect((t.ctx.scroll.get(s.id) orelse 0) > 0);
}

test "a scrolled box whose id goes back and forth is told of" {
    if (comptime !scroll_check.on) return error.SkipZigTest;
    var s: Pane = .{};
    var t: ui.Tester = undefined;
    try setup(&t, &s);
    defer t.deinit();
    // Shown every other frame: the box's offset jumps.
    for (0..6) |_| {
        s.sticky = !s.sticky;
        t.frame();
    }
    try testing.expect(t.ctx.scroll_check.lost >= 3);
    try testing.expect(t.ctx.scroll_check.flapping >= 2);
}

test "a keyed box keeps its id, its offset and quiet" {
    if (comptime !scroll_check.on) return error.SkipZigTest;
    var s: Pane = .{ .keyed = true };
    var t: ui.Tester = undefined;
    try setup(&t, &s);
    defer t.deinit();
    const at = t.ctx.scroll.get(s.id).?;
    for (0..6) |_| {
        s.sticky = !s.sticky;
        t.frame();
        try testing.expectEqual(at, t.ctx.scroll.get(s.id).?);
    }
    try testing.expectEqual(@as(u32, 0), t.ctx.scroll_check.lost);
}

test "another box a click shows in the place is taken as meant" {
    if (comptime !scroll_check.on) return error.SkipZigTest;
    var s: Pane = .{ .keyed = true };
    var t: ui.Tester = undefined;
    try setup(&t, &s);
    defer t.deinit();
    try t.clickText("Other");
    t.frame();
    try testing.expectEqual(@as(u32, 0), t.ctx.scroll_check.lost);
}

test "an empty scrolling box scrolls nowhere" {
    var s: Pane = .{ .keyed = true };
    var t: ui.Tester = undefined;
    try setup(&t, &s);
    defer t.deinit();
    s.rows = 0;
    t.frame();
    try testing.expectEqual(@as(f32, 0), t.ctx.scroll.get(s.id).?);
    try testing.expectEqual(@as(f32, 0), t.ctx.scroll_limit.get(s.id).?);
}
