//! Tabs, disclosures, accordions and split views through `Tester`: clicks,
//! keys, the content growing in and out, dividers dragged and moved.
const std = @import("std");
const ui = @import("ui.zig");
const tabs = @import("tabs.zig");
const collapsible = @import("collapsible.zig");
const split = @import("split.zig");
const testing = std.testing;

const Tabbed = struct {
    tab: usize = 0,
    changes: u32 = 0,
    fn view(s: *Tabbed, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(10), .gap = 10 });
        defer ui.end(c);
        if (tabs.tabs(c, &.{ "General", "Appearance", "Advanced" }, &s.tab, .{}).changed) s.changes += 1;
        switch (s.tab) {
            0 => ui.text(c, "General page", .{}),
            1 => ui.text(c, "Appearance page", .{}),
            else => ui.text(c, "Advanced page", .{}),
        }
        ui.text(c, "Elsewhere", .{});
    }
};

test "tabs: a click chooses a tab and the same frame shows its page" {
    var s: Tabbed = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Tabbed.view), .{});
    defer t.deinit();
    try testing.expect(t.hasText("General page"));
    try t.clickText("Advanced");
    try testing.expectEqual(@as(usize, 2), s.tab);
    try testing.expect(t.hasText("Advanced page"));
    try testing.expect(!t.hasText("General page"));
    try testing.expectEqual(@as(u32, 1), s.changes);
    // Clicking the tab chosen changes nothing.
    try t.clickText("Advanced");
    try testing.expectEqual(@as(u32, 1), s.changes);
}

test "tabs: the arrows, Home and End move the choice while the bar has the focus" {
    var s: Tabbed = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Tabbed.view), .{});
    defer t.deinit();
    // Without the focus, keys do nothing.
    t.key(.right);
    try testing.expectEqual(@as(usize, 0), s.tab);
    try t.clickText("General");
    t.key(.right);
    try testing.expectEqual(@as(usize, 1), s.tab);
    try testing.expect(t.hasText("Appearance page"));
    t.key(.right);
    t.key(.right);
    try testing.expectEqual(@as(usize, 2), s.tab);
    t.key(.home);
    try testing.expectEqual(@as(usize, 0), s.tab);
    t.key(.end);
    try testing.expectEqual(@as(usize, 2), s.tab);
    t.key(.left);
    try testing.expectEqual(@as(usize, 1), s.tab);
    try testing.expectEqual(@as(u32, 5), s.changes);
    // A press elsewhere takes the focus away.
    try t.clickText("Elsewhere");
    t.key(.left);
    try testing.expectEqual(@as(usize, 1), s.tab);
}

const Disclosed = struct {
    open: bool = false,
    clicks: u32 = 0,
    fn view(s: *Disclosed, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(10) });
        defer ui.end(c);
        const d = collapsible.collapsible(c, "Advanced", &s.open);
        if (d.changed) s.clicks += 1;
        if (d.shown) {
            ui.text(c, "Verbose logging", .{});
            ui.text(c, "Experimental", .{});
        }
        d.end();
        ui.text(c, "Below", .{});
    }
};

test "collapsible: a click opens it, the content grows in, and closing shrinks it away" {
    var s: Disclosed = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Disclosed.view), .{});
    defer t.deinit();
    try testing.expect(!t.hasText("Verbose logging"));
    const below_closed = t.findText("Below").?.y;
    try t.clickText("Advanced");
    try testing.expect(s.open);
    try testing.expectEqual(@as(u32, 1), s.clicks);
    // Animating: the content is built, and what is below moves down by degrees.
    try testing.expect(t.ctx.animating);
    try testing.expect(t.hasText("Verbose logging"));
    t.advance(0.05);
    const below_mid = t.findText("Below").?.y;
    t.settle(3);
    const below_open = t.findText("Below").?.y;
    try testing.expect(below_mid > below_closed and below_mid < below_open);
    try testing.expect(below_open - below_closed > 30);

    try t.clickText("Advanced");
    try testing.expect(!s.open);
    // Still shown while it closes, gone once it has.
    try testing.expect(t.hasText("Verbose logging"));
    t.settle(3);
    try testing.expect(!t.hasText("Verbose logging"));
    try testing.expectApproxEqAbs(below_closed, t.findText("Below").?.y, 0.5);
}

test "collapsible: Enter and Space open and close it while its header has the focus" {
    var s: Disclosed = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Disclosed.view), .{});
    defer t.deinit();
    try t.clickText("Advanced");
    try testing.expect(s.open);
    t.key(.enter);
    try testing.expect(!s.open);
    t.typeText(" ");
    try testing.expect(s.open);
    try testing.expectEqual(@as(u32, 3), s.clicks);
}

const Sections = struct {
    open: [3]bool = .{ false, false, false },
    fn view(s: *Sections, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(10) });
        defer ui.end(c);
        var acc = collapsible.accordion(c, .{});
        defer acc.end();
        const titles = [_][]const u8{ "General", "Privacy", "Advanced" };
        const bodies = [_][]const u8{ "General settings", "Privacy settings", "Advanced settings" };
        for (titles, 0..) |title, i| {
            const d = acc.item(title, &s.open[i]);
            defer d.end();
            if (d.shown) ui.text(c, bodies[i], .{});
        }
    }
};

/// Which title's header has the focus: the focused box holding its text.
fn focusedTitle(t: *ui.Tester, titles: []const []const u8) ?usize {
    for (titles, 0..) |title, i| {
        const r = t.findText(title).?;
        for (t.ctx.nodes.items) |n| if (n.id == t.ctx.focus and n.rect.contains(.{ .x = r.x + 1, .y = r.y + 1 })) return i;
    }
    return null;
}

test "accordion: sections open on their own, Up, Down, Home and End move the focus" {
    var s: Sections = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Sections.view), .{});
    defer t.deinit();
    const titles: []const []const u8 = &.{ "General", "Privacy", "Advanced" };
    try t.clickText("Privacy");
    try t.clickText("General");
    t.settle(2);
    try testing.expect(s.open[0] and s.open[1] and !s.open[2]);
    try testing.expect(t.hasText("General settings") and t.hasText("Privacy settings"));
    try testing.expectEqual(@as(?usize, 0), focusedTitle(&t, titles));
    t.key(.down);
    try testing.expectEqual(@as(?usize, 1), focusedTitle(&t, titles));
    t.key(.down);
    try testing.expectEqual(@as(?usize, 2), focusedTitle(&t, titles));
    // Down on the last stays there.
    t.key(.down);
    try testing.expectEqual(@as(?usize, 2), focusedTitle(&t, titles));
    t.key(.enter);
    try testing.expect(s.open[2]);
    t.key(.home);
    try testing.expectEqual(@as(?usize, 0), focusedTitle(&t, titles));
    t.key(.end);
    try testing.expectEqual(@as(?usize, 2), focusedTitle(&t, titles));
    t.key(.up);
    try testing.expectEqual(@as(?usize, 1), focusedTitle(&t, titles));
    t.key(.enter);
    try testing.expect(!s.open[1]);
}

const Panes = struct {
    size: f32 = 150,
    changes: u32 = 0,
    opts: split.Options = .{},
    fn view(s: *Panes, c: *ui.Context) void {
        var sp = split.split(c, &s.size, s.opts);
        ui.text(c, "Files", .{});
        sp.second();
        ui.text(c, "Editor", .{});
        if (sp.end().changed) s.changes += 1;
    }
};

test "split: the panes meet at the divider, which a drag moves" {
    var s: Panes = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Panes.view), .{ .width = 480, .height = 300 });
    defer t.deinit();
    t.frame();
    try testing.expectApproxEqAbs(@as(f32, 151), t.findText("Editor").?.x, 0.5);
    // The resize cursor over the divider, not beside it.
    t.moveTo(150, 100);
    try testing.expectEqual(@as(?ui.Cursor, .resize_left_right), t.ctx.cursor);
    t.moveTo(120, 100);
    try testing.expectEqual(@as(?ui.Cursor, null), t.ctx.cursor);
    // Grabbed beside its middle, the divider keeps the pointer where it was.
    t.drag(152, 100, 252, 100);
    try testing.expectApproxEqAbs(@as(f32, 250), s.size, 0.5);
    try testing.expect(s.changes > 0);
    try testing.expectApproxEqAbs(@as(f32, 251), t.findText("Editor").?.x, 0.5);
    // Kept 40 points from either edge.
    t.drag(250, 100, 470, 100);
    try testing.expectApproxEqAbs(@as(f32, 480 - 1 - 40), s.size, 0.5);
    t.drag(439, 100, 0, 100);
    try testing.expectApproxEqAbs(@as(f32, 40), s.size, 0.5);
}

test "split: the arrows move a focused divider; a small window makes the first pane give way" {
    var s: Panes = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Panes.view), .{ .width = 480, .height = 300 });
    defer t.deinit();
    t.frame();
    t.click(150, 100);
    try testing.expectEqual(@as(f32, 150), s.size);
    t.key(.right);
    try testing.expectEqual(@as(f32, 160), s.size);
    t.key(.left);
    t.key(.left);
    try testing.expectEqual(@as(f32, 140), s.size);
    // Narrower than the first pane needs: it gives way, the size is kept.
    t.resize(150, 300);
    t.frame();
    try testing.expectApproxEqAbs(@as(f32, 150 - 40), t.findText("Editor").?.x, 0.5);
    try testing.expectEqual(@as(f32, 140), s.size);
    t.resize(480, 300);
    t.frame();
    try testing.expectApproxEqAbs(@as(f32, 141), t.findText("Editor").?.x, 0.5);
}

test "split: vertical, in percent, grows with the window" {
    var s: Panes = .{ .size = 25, .opts = .{ .vertical = true, .percent = true } };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Panes.view), .{ .width = 300, .height = 401 });
    defer t.deinit();
    t.frame();
    try testing.expectApproxEqAbs(@as(f32, 101), t.findText("Editor").?.y, 0.5);
    t.moveTo(100, 100);
    try testing.expectEqual(@as(?ui.Cursor, .resize_up_down), t.ctx.cursor);
    t.drag(100, 100, 100, 200);
    try testing.expectApproxEqAbs(@as(f32, 50), s.size, 0.5);
    t.resize(300, 801);
    t.frame();
    try testing.expectApproxEqAbs(@as(f32, 401), t.findText("Editor").?.y, 0.5);
}
