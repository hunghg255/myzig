//! Accessibility through the Tester: the tree of a frame's widgets, and
//! actions of assistive technology done through it.
const std = @import("std");
const ui = @import("ui.zig");
const access = @import("access.zig");
const Tree = @import("access_tree.zig").Tree;

const App = struct {
    saves: u32 = 0,
    remember: bool = false,
    wifi: bool = true,
    volume: f32 = 0.5,
    name: ui.TextBuffer = .{},
    mode: usize = 0,
    announce: bool = false,

    fn view(s: *App, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(12), .gap = 8 });
        defer ui.end(c);
        ui.heading(c, "Settings");
        if (ui.button(c, "Save", .{}).clicked) {
            s.saves += 1;
            c.announce("Saved");
        }
        _ = ui.button(c, "Delete", .{ .disabled = true });
        _ = ui.checkbox(c, "Remember me", &s.remember);
        _ = ui.toggle(c, "Wi-Fi", &s.wifi);
        _ = ui.slider(c, &s.volume, .{ .label = "Volume" });
        _ = ui.textField(c, &s.name, .{ .label = "Name", .placeholder = "Your name" });
        ui.progress(c, 0.25, .{ .px = 100 });
        _ = ui.segmented(c, &.{ "List", "Grid" }, &s.mode);
        ui.text(c, "Plain words", .{});
    }
};

fn setup(t: *ui.Tester, app: *App) !void {
    try t.init(std.testing.allocator, .init(app, App.view), .{ .height = 480 });
    t.ctx.access.enabled = true;
    t.frame();
}

test "widgets describe themselves: roles, names, values, states" {
    var app: App = .{};
    var t: ui.Tester = undefined;
    try setup(&t, &app);
    defer t.deinit();
    var tree: Tree = .init(std.testing.allocator);
    defer tree.deinit();
    tree.build(&t.ctx);

    const heading = tree.byName(.heading, "Settings") orelse return error.NoHeading;
    try std.testing.expectEqual(@as(u32, 1), heading.level);
    const save = tree.byName(.button, "Save") orelse return error.NoSave;
    try std.testing.expect(save.actions.press and save.actions.focus and save.states.focusable);
    // A button holds no text element of its own: its text names it.
    try std.testing.expectEqual(@as(u32, 0), save.child_count);
    const del = tree.byName(.button, "Delete") orelse return error.NoDelete;
    try std.testing.expect(del.states.disabled and !del.actions.press);
    const remember = tree.byName(.checkbox, "Remember me") orelse return error.NoCheckbox;
    try std.testing.expect(!remember.states.checked);
    const wifi = tree.byName(.switch_, "Wi-Fi") orelse return error.NoSwitch;
    try std.testing.expect(wifi.states.checked);
    const volume = tree.byName(.slider, "Volume") orelse return error.NoSlider;
    try std.testing.expectEqual(@as(f64, 0.5), volume.range.now);
    try std.testing.expect(volume.actions.increment and volume.actions.decrement);
    const name = tree.byName(.text_field, "Name") orelse return error.NoField;
    try std.testing.expectEqualStrings("Your name", name.placeholder);
    try std.testing.expect(name.actions.set_value);
    try std.testing.expectEqual(@as(usize, 1), tree.count(.progress));
    try std.testing.expectEqual(@as(usize, 1), tree.count(.radio_group));
    const list = tree.byName(.radio, "List") orelse return error.NoRadio;
    try std.testing.expect(list.states.checked and list.pos_in_set == 1 and list.set_size == 2);
    try std.testing.expect(tree.byName(.text, "Plain words") != null);
    // Every element is in the window, and the rows of the column are its
    // children in order.
    try std.testing.expect(save.rect.w > 0 and save.rect.h > 0);
    try std.testing.expect(tree.find(save.id) == save);
    try std.testing.expect(tree.at(.{ .x = save.rect.x + 2, .y = save.rect.y + 2 }).?.id == save.id);
}

test "actions of assistive technology change the app's state" {
    var app: App = .{};
    var t: ui.Tester = undefined;
    try setup(&t, &app);
    defer t.deinit();
    var tree: Tree = .init(std.testing.allocator);
    defer tree.deinit();
    tree.build(&t.ctx);

    const save = tree.byName(.button, "Save").?;
    access.perform(&t.ctx, save.id, save.role, .press);
    t.frame();
    try std.testing.expectEqual(@as(u32, 1), app.saves);
    tree.build(&t.ctx);
    try std.testing.expectEqual(@as(usize, 1), tree.announcements.len);
    try std.testing.expectEqualStrings("Saved", tree.announcements[0]);
    // Announced once.
    t.frame();
    tree.build(&t.ctx);
    try std.testing.expectEqual(@as(usize, 0), tree.announcements.len);

    const remember = tree.byName(.checkbox, "Remember me").?.id;
    access.perform(&t.ctx, remember, .checkbox, .press);
    t.frame();
    try std.testing.expect(app.remember);
    tree.build(&t.ctx);
    try std.testing.expect(tree.find(remember).?.states.checked);

    const volume = tree.byName(.slider, "Volume").?.id;
    access.perform(&t.ctx, volume, .slider, .increment);
    t.frame();
    try std.testing.expect(app.volume > 0.5);
    tree.build(&t.ctx);
    // Incrementing focused it, as the keyboard would.
    try std.testing.expectEqual(volume, tree.focus);
    try std.testing.expect(tree.find(volume).?.states.focused);

    const field = tree.byName(.text_field, "Name").?.id;
    access.perform(&t.ctx, field, .text_field, .{ .set_value = "Ada" });
    t.frame();
    try std.testing.expectEqualStrings("Ada", app.name.text());
    tree.build(&t.ctx);
    const f = tree.find(field).?;
    try std.testing.expectEqualStrings("Ada", f.value);
    try std.testing.expectEqual(field, tree.focus);

    const grid = tree.byName(.radio, "Grid").?.id;
    access.perform(&t.ctx, grid, .radio, .press);
    t.frame();
    try std.testing.expectEqual(@as(usize, 1), app.mode);

    access.perform(&t.ctx, tree.byName(.button, "Save").?.id, .button, .focus);
    t.frame();
    tree.build(&t.ctx);
    try std.testing.expectEqual(tree.byName(.button, "Save").?.id, tree.focus);
}

test "nothing is described while no assistive technology listens" {
    var app: App = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&app, App.view), .{ .height = 480 });
    defer t.deinit();
    try std.testing.expectEqual(@as(u32, 0), t.ctx.access.described.count());
    t.ctx.announce("unheard");
    try std.testing.expectEqual(@as(usize, 0), t.ctx.access.announcements.items.len);
    t.ctx.access.enabled = true;
    t.frame();
    try std.testing.expect(t.ctx.access.described.count() > 0);
}
