//! Boundary, focus and input routing cases for tab bars whose contents
//! change while they are in use. All input stays inside the Tester.
const std = @import("std");
const ui = @import("ui.zig");
const access = @import("access.zig");
const Tree = @import("access_tree.zig").Tree;
const testing = std.testing;
const Key = @import("context.zig").Key;
const S = ui.Shortcut;

const names = [_][]const u8{ "First", "Second", "Third" };
const App = struct {
    labels: []const []const u8 = &names,
    selected: usize = 0,
    changes: usize = 0,
    other: usize = 0,
    other_changes: usize = 0,
    two: bool = false,
    rtl: bool = false,
    ltr_scope: bool = false,
    bar_id: u64 = 0,
    other_id: u64 = 0,
    before_id: u64 = 0,
    after_id: u64 = 0,

    fn view(s: *App, c: *ui.Context) void {
        ui.direction.set(c, if (s.rtl) .rtl else .ltr);
        const box = c.open(.{ .width = .fill, .padding = .all(12), .gap = 8 }, "content");
        defer c.end();
        if (s.ltr_scope) ui.direction.scope(c, box, .ltr);
        s.before_id = ui.button(c, "Before", .{}).id;
        // A correction made by tabs must also refresh preceding content.
        ui.textf(c, .{}, "Selected: {d}", .{s.selected});
        c.next_key = "primary";
        s.bar_id = c.peekId(null);
        if (ui.tabs(c, s.labels, &s.selected, .{}).changed) s.changes += 1;
        if (s.two) {
            c.next_key = "secondary";
            s.other_id = c.peekId(null);
            if (ui.tabs(c, &names, &s.other, .{}).changed) s.other_changes += 1;
        }
        s.after_id = ui.button(c, "After", .{}).id;
    }
};

fn init(t: *ui.Tester, s: *App) !void {
    try t.init(testing.allocator, .init(s, App.view), .{});
    t.ctx.access.enabled = true;
    t.frame();
}

test "tabs edges: an empty list does not take a keyboard stop" {
    var s: App = .{ .labels = &.{} };
    var t: ui.Tester = undefined;
    try init(&t, &s);
    defer t.deinit();
    try testing.expectEqual(2, t.ctx.focus_order.items.len);
    t.key(.tab);
    try testing.expectEqual(s.before_id, t.ctx.focus);
    t.key(.tab);
    try testing.expectEqual(s.after_id, t.ctx.focus);
    try testing.expectEqual(0, s.changes);
}

test "tabs edges: removing all tabs releases focus and permits reopening" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try init(&t, &s);
    defer t.deinit();
    try t.clickText("Second");
    try testing.expectEqual(s.bar_id, t.ctx.focus);
    s.labels = &.{};
    t.frame();
    try testing.expect(t.ctx.focus != s.bar_id);
    var tree: Tree = .init(testing.allocator);
    defer tree.deinit();
    tree.build(&t.ctx);
    try testing.expectEqual(0, tree.count(.tab));
    s.labels = &names;
    t.frame();
    try t.clickText("Third");
    try testing.expectEqual(2, s.selected);
    try testing.expectEqual(s.bar_id, t.ctx.focus);
}

test "tabs edges: invalid selection is corrected once and refreshes preceding content" {
    var s: App = .{ .selected = std.math.maxInt(usize) };
    var t: ui.Tester = undefined;
    try init(&t, &s);
    defer t.deinit();
    try testing.expectEqual(2, s.selected);
    try testing.expectEqual(1, s.changes);
    try testing.expect(t.hasText("Selected: 2"));
    t.frame();
    try testing.expectEqual(1, s.changes);
}

test "tabs edges: shrinking and growing the list preserves a valid choice" {
    var s: App = .{ .selected = 2 };
    var t: ui.Tester = undefined;
    try init(&t, &s);
    defer t.deinit();
    s.labels = names[0..1];
    t.frame();
    try testing.expectEqual(0, s.selected);
    try testing.expectEqual(1, s.changes);
    try testing.expect(t.hasText("Selected: 0"));
    try testing.expect(!t.hasText("Third"));
    s.labels = &names;
    t.frame();
    try testing.expectEqual(0, s.selected);
    try testing.expectEqual(1, s.changes);
}

test "tabs edges: one tab and boundary keys never report a spurious change" {
    var s: App = .{ .labels = names[0..1] };
    var t: ui.Tester = undefined;
    try init(&t, &s);
    defer t.deinit();
    try t.clickText("First");
    for ([_]Key{ .left, .right, .home, .end, .up, .down, .enter, .escape }) |key| t.key(key);
    try testing.expectEqual(0, s.selected);
    try testing.expectEqual(0, s.changes);
    t.settle(2);
    try testing.expect(!t.ctx.animating);
}

test "tabs edges: two bars have independent choices and one Tab stop each" {
    var s: App = .{ .two = true, .selected = 1 };
    var t: ui.Tester = undefined;
    try init(&t, &s);
    defer t.deinit();
    try testing.expectEqual(4, t.ctx.focus_order.items.len);
    t.key(.tab);
    t.key(.tab);
    try testing.expectEqual(s.bar_id, t.ctx.focus);
    t.key(.right);
    try testing.expectEqual(2, s.selected);
    try testing.expectEqual(0, s.other);
    t.key(.tab);
    try testing.expectEqual(s.other_id, t.ctx.focus);
    t.key(.right);
    try testing.expectEqual(1, s.other);
    try testing.expectEqual(1, s.changes);
    try testing.expectEqual(1, s.other_changes);
    t.key(.tab);
    try testing.expectEqual(s.after_id, t.ctx.focus);
    _ = t.shortcut(.{ .key = S.tab, .shift = true });
    try testing.expectEqual(s.other_id, t.ctx.focus);
    try testing.expectEqual(1, s.other);
}

test "tabs edges: shortcut events navigate once and ignore modifiers" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try init(&t, &s);
    defer t.deinit();
    try t.clickText("First");
    try testing.expect(t.shortcut(.{ .key = S.right }));
    try testing.expectEqual(1, s.selected);
    try testing.expect(t.shortcut(.{ .key = S.end }));
    try testing.expectEqual(2, s.selected);
    try testing.expect(t.shortcut(.{ .key = S.home }));
    try testing.expectEqual(0, s.selected);
    for ([_]S{
        .{ .key = S.right, .ctrl = true },
        .{ .key = S.right, .cmd = true },
        .{ .key = S.right, .alt = true },
        .{ .key = S.right, .shift = true },
    }) |shortcut| try testing.expect(!t.shortcut(shortcut));
    try testing.expectEqual(0, s.selected);
    try testing.expectEqual(3, s.changes);
}

test "tabs edges: modified plain keys leave app shortcuts alone" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try init(&t, &s);
    defer t.deinit();
    try t.clickText("First");
    t.ctx.input.ctrl = true;
    t.key(.right);
    t.ctx.input.ctrl = false;
    t.ctx.input.cmd = true;
    t.key(.end);
    t.ctx.input.cmd = false;
    t.ctx.input.shift = true;
    t.key(.right);
    t.ctx.input.shift = false;
    try testing.expectEqual(0, s.selected);
    try testing.expectEqual(0, s.changes);
}

test "tabs edges: native command events navigate and leave selection commands alone" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try init(&t, &s);
    defer t.deinit();
    try t.clickText("First");
    t.textOps(&.{.{ .command = .move_right }});
    try testing.expectEqual(1, s.selected);
    t.textOps(&.{.{ .command = .move_doc_end }});
    try testing.expectEqual(2, s.selected);
    t.textOps(&.{.{ .command = .move_doc_start }});
    try testing.expectEqual(0, s.selected);
    t.textOps(&.{.{ .command = .select_right }});
    try testing.expectEqual(0, s.selected);
    try testing.expectEqual(3, s.changes);
}

test "tabs edges: arrows follow RTL and a local LTR scope" {
    var s: App = .{ .rtl = true };
    var t: ui.Tester = undefined;
    try init(&t, &s);
    defer t.deinit();
    try testing.expect(t.findText("First").?.x > t.findText("Second").?.x);
    try t.clickText("First");
    t.key(.left);
    try testing.expectEqual(1, s.selected);
    t.key(.right);
    try testing.expectEqual(0, s.selected);
    s.ltr_scope = true;
    t.frame();
    try testing.expect(t.findText("First").?.x < t.findText("Second").?.x);
    t.key(.right);
    try testing.expectEqual(1, s.selected);
}

test "tabs edges: duplicate labels retain distinct accessible choices" {
    var s: App = .{ .labels = &.{ "Same", "Same", "Khac" } };
    var t: ui.Tester = undefined;
    try init(&t, &s);
    defer t.deinit();
    var tree: Tree = .init(testing.allocator);
    defer tree.deinit();
    tree.build(&t.ctx);
    var ids: [3]u64 = undefined;
    var count: usize = 0;
    for (tree.nodes.items) |n| if (n.role == .tab) {
        ids[count] = n.id;
        count += 1;
    };
    try testing.expectEqual(3, count);
    try testing.expect(ids[0] != ids[1]);
    access.perform(&t.ctx, ids[1], .tab, .press);
    t.frame();
    tree.build(&t.ctx);
    try testing.expectEqual(1, s.selected);
    try testing.expectEqual(1, s.changes);
    try testing.expectEqual(ids[1], tree.focus);
    for (ids, 0..) |id, i| try testing.expectEqual(i == 1, tree.find(id).?.states.selected);
    t.key(.right);
    try testing.expectEqual(2, s.selected);
}
