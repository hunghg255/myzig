const std = @import("std");
const ui = @import("ui.zig");
const access = @import("access.zig");
const Tree = @import("access_tree.zig").Tree;
const testing = std.testing;

const App = struct {
    page: usize = 1,
    opts: ui.PaginationOptions = .{ .page_count = 20 },
    changes: usize = 0,

    fn view(s: *App, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(12), .gap = 8 });
        defer ui.end(c);
        _ = ui.button(c, "Before", .{});
        if (ui.pagination(c, &s.page, s.opts)) s.changes += 1;
        _ = ui.button(c, "After", .{});
    }
};

fn focused(t: *ui.Tester, title: []const u8) bool {
    const r = t.findText(title) orelse return false;
    for (t.ctx.nodes.items) |n| if (n.id == t.ctx.focus) return n.rect.contains(.{ .x = r.x + 1, .y = r.y + 1 });
    return false;
}

test "pagination: numbered navigation, ellipses, boundaries and clamp" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 850 });
    defer t.deinit();
    try testing.expect(t.hasText("…") and t.hasText("20"));
    try t.clickText("Previous");
    try testing.expectEqual(1, s.page);
    try testing.expectEqual(0, s.changes);
    try t.clickText("Next");
    try testing.expectEqual(2, s.page);
    try testing.expectEqual(1, s.changes);
    try t.clickText("20");
    try t.clickText("Next");
    try testing.expectEqual(20, s.page);
    try testing.expectEqual(2, s.changes);
    try t.clickText("Previous");
    try testing.expectEqual(19, s.page);
    s.opts.page_count = 3;
    t.frame();
    try testing.expectEqual(3, s.page);
    try testing.expectEqual(4, s.changes);
    try testing.expect(!t.hasText("…"));
    s.page = 0;
    t.frame();
    try testing.expectEqual(1, s.page);
}

test "pagination: roving keyboard focus, activation and RTL" {
    var s: App = .{ .page = 5, .opts = .{ .page_count = 9 } };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 850 });
    defer t.deinit();
    try testing.expectEqual(3, t.ctx.focus_order.items.len);
    _ = t.shortcut(.{ .key = ui.Shortcut.tab });
    _ = t.shortcut(.{ .key = ui.Shortcut.tab });
    try testing.expect(focused(&t, "5"));
    t.key(.right);
    try testing.expect(focused(&t, "6"));
    try testing.expectEqual(5, s.page);
    t.key(.enter);
    try testing.expectEqual(6, s.page);
    t.key(.home);
    try testing.expect(focused(&t, "Previous"));
    t.key(.end);
    try testing.expect(focused(&t, "Next"));
    t.typeText(" ");
    try testing.expectEqual(7, s.page);
    _ = t.shortcut(.{ .key = ui.Shortcut.tab });
    try testing.expect(focused(&t, "After"));
    ui.direction.set(&t.ctx, .rtl);
    t.frame();
    try t.clickText("7");
    t.key(.left);
    try testing.expect(focused(&t, "8"));
    t.key(.enter);
    try testing.expectEqual(8, s.page);
}

test "pagination: empty, one page, unknown total, disabled and overflow" {
    var s: App = .{ .opts = .{ .page_count = 0 } };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 850 });
    defer t.deinit();
    try testing.expectEqual(0, s.page);
    try testing.expectEqual(2, t.ctx.focus_order.items.len);
    try t.clickText("Next");
    try testing.expectEqual(0, s.page);
    s.opts.page_count = 1;
    t.frame();
    try testing.expectEqual(1, s.page);
    try t.clickText("Previous");
    try t.clickText("Next");
    try testing.expectEqual(1, s.page);
    s.opts = .{ .has_next = true };
    t.frame();
    try t.clickText("Next");
    try testing.expectEqual(2, s.page);
    try testing.expect(t.hasText("Page 2"));
    s.opts.has_next = false;
    t.frame();
    try t.clickText("Next");
    try testing.expectEqual(2, s.page);
    try t.clickText("Previous");
    try testing.expectEqual(1, s.page);
    s.opts = .{ .page_count = 12, .disabled = true };
    t.frame();
    try t.clickText("12");
    try testing.expectEqual(1, s.page);
    try testing.expectEqual(2, t.ctx.focus_order.items.len);
    s.page = std.math.maxInt(usize);
    s.opts = .{ .has_next = true };
    t.frame();
    try t.clickText("Next");
    try testing.expectEqual(std.math.maxInt(usize), s.page);
}

test "pagination: keyboard focus survives reaching a boundary" {
    var s: App = .{ .page = 2, .opts = .{ .page_count = 3 } };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 850 });
    defer t.deinit();
    try t.clickText("2");
    t.key(.end);
    t.key(.enter);
    try testing.expectEqual(3, s.page);
    try testing.expect(focused(&t, "3"));
    t.key(.left);
    try testing.expect(focused(&t, "2"));
    t.key(.home);
    t.key(.enter);
    t.key(.enter);
    try testing.expectEqual(1, s.page);
    try testing.expect(focused(&t, "1"));
    s.opts.disabled = true;
    t.frame();
    try testing.expectEqual(0, t.ctx.focus);
}

test "pagination: focused page is replaced when the total shrinks or disappears" {
    var s: App = .{ .page = 12 };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 850 });
    defer t.deinit();
    try t.clickText("12");
    s.opts.page_count = 3;
    t.frame();
    try testing.expectEqual(3, s.page);
    try testing.expect(focused(&t, "3"));
    t.key(.left);
    t.key(.enter);
    try testing.expectEqual(2, s.page);
    s.opts = .{ .has_next = true };
    t.frame();
    try testing.expect(focused(&t, "Previous"));
    t.key(.right);
    t.key(.enter);
    try testing.expectEqual(3, s.page);
    s.opts.page_count = 0;
    t.frame();
    try testing.expectEqual(0, s.page);
    try testing.expectEqual(0, t.ctx.focus);
    _ = t.shortcut(.{ .key = ui.Shortcut.tab });
    try testing.expect(focused(&t, "Before"));
}

test "pagination: shrinking neighbors restores focus without taking it from outside" {
    var s: App = .{ .page = 6, .opts = .{ .page_count = 20, .siblings = 2 } };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 850 });
    defer t.deinit();
    try t.clickText("6");
    t.key(.left);
    s.opts.siblings = 0;
    t.frame();
    try testing.expect(!t.hasText("5"));
    try testing.expect(focused(&t, "6"));
    _ = t.shortcut(.{ .key = ui.Shortcut.tab });
    try testing.expect(focused(&t, "After"));
    s.opts.disabled = true;
    t.frame();
    try testing.expect(focused(&t, "After"));
}

test "pagination: changing one pager leaves another pager focused" {
    const Pair = struct {
        pages: [2]usize = .{ 12, 2 },
        count: usize = 20,

        fn view(s: *@This(), c: *ui.Context) void {
            ui.column(c, .{ .gap = 8 });
            defer ui.end(c);
            for (&s.pages, 0..) |*page, i| {
                c.keyed(i);
                _ = ui.pagination(c, page, .{ .page_count = if (i == 0) s.count else 3 });
            }
        }
    };
    var s: Pair = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Pair.view), .{ .width = 850 });
    defer t.deinit();
    try t.clickText("2");
    const focus = t.ctx.focus;
    s.count = 3;
    t.frame();
    try testing.expectEqual(focus, t.ctx.focus);
    t.key(.right);
    t.key(.enter);
    try testing.expectEqual(3, s.pages[0]);
    try testing.expectEqual(3, s.pages[1]);
}

test "pagination: accessible names, selected page, disabled buttons and localized labels" {
    var s: App = .{ .opts = .{ .page_count = 3, .label = "Results", .previous_label = "Trước", .next_label = "Sau", .page_label = "Trang" } };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 850 });
    defer t.deinit();
    t.ctx.access.enabled = true;
    t.frame();
    var tree: Tree = .init(testing.allocator);
    defer tree.deinit();
    tree.build(&t.ctx);
    try testing.expect(tree.byName(.group, "Results") != null);
    try testing.expect(tree.byName(.button, "Trước").?.states.disabled);
    try testing.expect(tree.byName(.button, "Trang 1").?.states.selected);
    const next = tree.byName(.button, "Sau").?;
    access.perform(&t.ctx, next.id, next.role, .press);
    t.frame();
    try testing.expectEqual(2, s.page);
    tree.build(&t.ctx);
    try testing.expect(tree.byName(.button, "Trang 2").?.states.selected);
    try testing.expect(!tree.byName(.button, "Trước").?.states.disabled);
    const pixels = try t.render(testing.allocator);
    defer pixels.deinit(testing.allocator);
}
