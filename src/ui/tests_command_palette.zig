const std = @import("std");
const ui = @import("ui.zig");
const access = @import("access.zig");
const Tree = @import("access_tree.zig").Tree;
const testing = std.testing;

const entries: []const ui.CommandItem = &.{
    .{ .title = "New document", .group = "Files", .keywords = "create", .icon = "doc.text", .shortcut = "Ctrl+N" },
    .{ .title = "Save document", .group = "Files", .disabled = true },
    .{ .title = "Settings", .group = "Application", .keywords = "preferences" },
    .{ .title = "Quit application", .group = "Application" },
};

const App = struct {
    state: ui.CommandState = .{},
    chosen: ?usize = null,
    items: []const ui.CommandItem = entries,

    fn view(s: *App, c: *ui.Context) void {
        if (ui.button(c, "Open commands", .{}).clicked) s.state.show();
        if (c.shortcut(.{ .key = 'k', .cmd = true })) s.state.toggle();
        if (ui.commandPalette(c, &s.state, s.items, .{})) |index| s.chosen = index;
    }
};

test "command palette: filters keywords, activates and restores focus" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 680, .height = 600 });
    defer t.deinit();
    try t.clickText("Open commands");
    const trigger = s.state.overlay.return_focus;
    try testing.expectEqual(@as(?usize, 0), s.state.selected);
    t.key(.down);
    try testing.expectEqual(@as(?usize, 2), s.state.selected);
    t.typeText("PREFERENCES");
    try testing.expect(t.hasText("Settings") and !t.hasText("New document"));
    t.key(.enter);
    try testing.expectEqual(@as(?usize, 2), s.chosen);
    try testing.expect(!s.state.overlay.open);
    try testing.expectEqual(trigger, t.ctx.focus);
    try t.clickText("Open commands");
    try testing.expectEqualStrings("", s.state.query.text());
    try testing.expect(t.hasText("New document"));
    try t.clickText("New document");
    try testing.expectEqual(@as(?usize, 0), s.chosen);
}

test "command palette: empty results, disabled items, accessible selection and escape" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 680, .height = 600 });
    defer t.deinit();
    _ = t.shortcut(.{ .key = 'k', .cmd = true });
    t.ctx.access.enabled = true;
    t.frame();
    var tree: Tree = .init(testing.allocator);
    defer tree.deinit();
    tree.build(&t.ctx);
    try testing.expect(tree.byName(.dialog, "Commands").?.states.modal);
    try testing.expect(tree.byName(.combo_box, "Search commands") != null);
    try testing.expect(tree.byName(.list_item, "New document").?.states.selected);
    const disabled = tree.byName(.list_item, "Save document").?;
    try testing.expect(disabled.states.disabled);
    access.perform(&t.ctx, disabled.id, disabled.role, .press);
    t.frame();
    try testing.expect(s.chosen == null and s.state.overlay.open);
    t.typeText("nothing matches");
    try testing.expect(t.hasText("No commands found."));
    t.key(.enter);
    try testing.expect(s.chosen == null and s.state.overlay.open);
    t.key(.escape);
    try testing.expect(!s.state.overlay.open);
}

test "command palette: long lists reveal keyboard selection and skip all disabled results" {
    var items: [40]ui.CommandItem = undefined;
    var names: [40][32]u8 = undefined;
    for (&items, &names, 0..) |*item, *name, i| item.* = .{ .title = try std.fmt.bufPrint(name, "Command {d}", .{i}), .disabled = i == 39 };
    var s: App = .{ .items = &items };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 680, .height = 600 });
    defer t.deinit();
    try t.clickText("Open commands");
    t.key(.end);
    try testing.expectEqual(@as(?usize, 38), s.state.selected);
    try t.runScript("visible:Command 38");
    t.key(.down);
    try testing.expectEqual(@as(?usize, 0), s.state.selected);
    try t.runScript("visible:Command 0");
    for (&items) |*item| item.disabled = true;
    t.frame();
    t.key(.down);
    t.key(.enter);
    try testing.expect(s.state.selected == null and s.chosen == null);
}

test "command palette: Actions shares enabled state and returns its typed action" {
    const Cmd = enum { new, save };
    const AppActions = struct {
        actions: ui.Actions(Cmd) = .init(.{
            .new = .{ .title = "New file", .shortcut = .{ .key = 'n', .cmd = true } },
            .save = .{ .title = "Save file", .enabled = false },
        }),
        state: ui.CommandState = .{ .overlay = .{ .open = true } },
        chosen: ?Cmd = null,

        fn view(s: *@This(), c: *ui.Context) void {
            if (s.actions.commandPalette(c, &s.state, .{})) |cmd| s.chosen = cmd;
        }
    };
    var s: AppActions = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, AppActions.view), .{ .width = 680, .height = 600 });
    defer t.deinit();
    t.key(.enter);
    try testing.expectEqual(@as(?Cmd, .new), s.chosen);
    try testing.expectEqual(@as(?Cmd, .new), s.actions.last);
    s.actions.setEnabled(.save, true);
    s.state.show();
    t.frame();
    t.typeText("Save");
    t.key(.enter);
    try testing.expectEqual(@as(?Cmd, .save), s.chosen);
}

test "command palette: navigation through native text input commands" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 680, .height = 600 });
    defer t.deinit();
    try t.clickText("Open commands");
    t.textOps(&.{.{ .command = .move_down }});
    try testing.expectEqual(@as(?usize, 2), s.state.selected);
    t.textOps(&.{.{ .command = .move_doc_end }});
    try testing.expectEqual(@as(?usize, 3), s.state.selected);
    t.textOps(&.{.{ .command = .move_doc_start }});
    try testing.expectEqual(@as(?usize, 0), s.state.selected);
    _ = t.shortcut(.{ .key = ui.Shortcut.end });
    try testing.expectEqual(@as(?usize, 3), s.state.selected);
    t.textOps(&.{.{ .command = .move_up }});
    t.textOps(&.{.{ .command = .insert_newline }});
    try testing.expectEqual(@as(?usize, 2), s.chosen);
}
