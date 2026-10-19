//! Accessibility of the structures and overlays through the Tester: tabs,
//! menus, selects, trees, tables, dialogs, toasts and forms, read and
//! acted on through the tree.
const std = @import("std");
const ui = @import("ui.zig");
const access = @import("access.zig");
const Tree = @import("access_tree.zig").Tree;
const tree_mod = @import("tree.zig");
const table_mod = @import("table.zig");
const testing = std.testing;

const App = struct {
    tab: usize = 0,
    sort: ui.Menu = .{},
    sort_by: usize = 0,
    size: usize = 0,
    size_state: ui.SelectState = .{},
    chosen: []const u8 = "",
    src: bool = false,
    rows: ui.TableState = .{},
    email: ui.TextBuffer = .{},
    toasts: ui.Toasts = .{},
    confirm: ui.OverlayState = .{},

    const sorts = [_][]const u8{ "Name", "Date" };
    const cols: []const table_mod.Column = &.{.{ .title = "Name" }};

    fn view(s: *App, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(8), .gap = 6 });
        defer ui.end(c);
        _ = ui.tabs(c, &.{ "General", "Advanced" }, &s.tab, .{});
        ui.row(c, .{ .gap = 6 });
        if (ui.menuButton(c, "Sort by", &s.sort, .{})) |m| {
            defer m.end();
            for (sorts, 0..) |by, i| if (m.item(by, .{ .checked = s.sort_by == i })) {
                s.sort_by = i;
            };
        }
        _ = ui.select(c, &s.size, &.{ "Small", "Large" }, &s.size_state, .{ .label = "Size" });
        ui.end(c);
        const f = ui.field(c, "Email", .{ .err = if (s.email.len == 0) "Required" else "" });
        _ = ui.textField(c, &s.email, .{});
        f.end();
        var tr = tree_mod.tree(c, &s.chosen, .{ .height = .{ .px = 90 } });
        if (tr.item("src", "src", &s.src)) {
            defer tr.endChildren();
            _ = tr.item("src/main.zig", "main.zig", null);
        }
        _ = tr.item("build.zig", "build.zig", null);
        _ = tr.end();
        var tb = table_mod.table(c, &s.rows, cols, 1000, .{ .height = .{ .px = 120 } });
        while (tb.next()) |row| {
            while (tb.cell()) |_| ui.text(c, c.print("Person {d}", .{row}), .{});
        }
        _ = tb.end();
        _ = ui.toasts(c, &s.toasts);
        switch (ui.alertDialog(c, &s.confirm, "Delete?", "It cannot be undone.", &.{ "Cancel", "Delete" })) {
            else => {},
        }
    }
};

fn fixture(t: *ui.Tester, app: *App) !void {
    try t.init(testing.allocator, .init(app, App.view), .{ .width = 520, .height = 640 });
    t.ctx.access.enabled = true;
    t.frame();
}

fn act(t: *ui.Tester, tree: *Tree, role: access.Role, name: []const u8, action: access.Action) !void {
    const n = tree.byName(role, name) orelse return error.NotFound;
    access.perform(&t.ctx, n.id, n.role, action);
    t.frame();
    t.frame();
    tree.build(&t.ctx);
}

test "tabs, menus and selects through the tree" {
    var app: App = .{};
    var t: ui.Tester = undefined;
    try fixture(&t, &app);
    defer t.deinit();
    var tree: Tree = .init(testing.allocator);
    defer tree.deinit();
    tree.build(&t.ctx);

    try testing.expectEqual(@as(usize, 1), tree.count(.tab_list));
    const general = tree.byName(.tab, "General").?;
    try testing.expect(general.states.selected and general.pos_in_set == 1 and general.set_size == 2);
    try act(&t, &tree, .tab, "Advanced", .press);
    try testing.expectEqual(@as(usize, 1), app.tab);
    try testing.expect(tree.byName(.tab, "Advanced").?.states.selected);

    const sort = tree.byName(.menu_button, "Sort by").?;
    try testing.expect(!sort.states.expanded and sort.states.has_popup);
    try act(&t, &tree, .menu_button, "Sort by", .press);
    try testing.expect(app.sort.isOpen());
    try testing.expect(tree.byName(.menu_button, "Sort by").?.states.expanded);
    try testing.expectEqual(@as(usize, 1), tree.count(.menu));
    const name = tree.byName(.menu_item_checkbox, "Name").?;
    try testing.expect(name.states.checked);
    try act(&t, &tree, .menu_item_checkbox, "Date", .press);
    try testing.expectEqual(@as(usize, 1), app.sort_by);
    try testing.expect(!app.sort.isOpen());
    try testing.expectEqual(@as(usize, 0), tree.count(.menu));

    const size = tree.byName(.popup_button, "Size").?;
    try testing.expectEqualStrings("Small", size.value);
    try act(&t, &tree, .popup_button, "Size", .expand);
    try testing.expect(tree.byName(.popup_button, "Size").?.states.expanded);
    try testing.expect(tree.byName(.list_item, "Large") != null);
    try act(&t, &tree, .list_item, "Large", .press);
    try testing.expectEqual(@as(usize, 1), app.size);
    try testing.expectEqualStrings("Large", tree.byName(.popup_button, "Size").?.value);
}

test "trees, tables and forms through the tree" {
    var app: App = .{};
    var t: ui.Tester = undefined;
    try fixture(&t, &app);
    defer t.deinit();
    var tree: Tree = .init(testing.allocator);
    defer tree.deinit();
    tree.build(&t.ctx);

    // A field names its control, and tells its error.
    const email = tree.byName(.text_field, "Email").?;
    try testing.expectEqualStrings("Required", email.description);
    try testing.expect(email.states.invalid);

    const src = tree.byName(.tree_item, "src").?;
    try testing.expect(src.states.expandable and !src.states.expanded and src.level == 1);
    try testing.expect(tree.byName(.tree_item, "main.zig") == null);
    try act(&t, &tree, .tree_item, "src", .expand);
    try testing.expect(app.src);
    // Opening is not choosing.
    try testing.expectEqualStrings("", app.chosen);
    const main = tree.byName(.tree_item, "main.zig").?;
    try testing.expectEqual(@as(u32, 2), main.level);
    try act(&t, &tree, .tree_item, "main.zig", .press);
    try testing.expectEqualStrings("src/main.zig", app.chosen);
    try testing.expect(tree.byName(.tree_item, "main.zig").?.states.selected);

    // Rows say which of all they are, though a screenful is built.
    try testing.expectEqual(@as(usize, 1), tree.count(.table));
    const row = tree.byName(.row, "Person 2").?;
    try testing.expectEqual(@as(u32, 3), row.pos_in_set);
    try testing.expectEqual(@as(u32, 1000), row.set_size);
    try testing.expect(tree.count(.row) < 50);
    try testing.expectEqual(@as(usize, 1), tree.count(.column_header));
    try act(&t, &tree, .row, "Person 2", .press);
    try testing.expectEqual(@as(?usize, 2), app.rows.selected);
    try testing.expect(tree.byName(.row, "Person 2").?.states.selected);
}

test "a dialog makes what is behind it inert; toasts are announced" {
    var app: App = .{};
    var t: ui.Tester = undefined;
    try fixture(&t, &app);
    defer t.deinit();
    var tree: Tree = .init(testing.allocator);
    defer tree.deinit();

    _ = app.toasts.show("Saved");
    t.frame();
    tree.build(&t.ctx);
    try testing.expectEqual(@as(usize, 1), tree.announcements.len);
    try testing.expectEqualStrings("Saved", tree.announcements[0]);
    try testing.expect(tree.byName(.status, "Saved") != null);
    try testing.expect(tree.byName(.button, "Close") != null);

    app.confirm.show();
    t.settle(1);
    tree.build(&t.ctx);
    const alert = tree.byName(.alert_dialog, "Delete?").?;
    try testing.expectEqualStrings("It cannot be undone.", alert.description);
    try testing.expect(tree.byName(.button, "Delete") != null);
    try testing.expect(tree.byName(.tab, "General") == null);
    try act(&t, &tree, .button, "Cancel", .press);
    try testing.expect(!app.confirm.open);
    try testing.expect(tree.byName(.tab, "General") != null);
}
