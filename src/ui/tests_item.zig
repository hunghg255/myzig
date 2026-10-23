const std = @import("std");
const ui = @import("ui.zig");
const Tree = @import("access_tree.zig").Tree;
const testing = std.testing;

const App = struct {
    opens: usize = 0,
    removes: usize = 0,
    variant: @FieldType(ui.ItemOptions, "variant") = .outline,
    small: bool = false,

    fn view(s: *App, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .padding = .all(12), .gap = 8 });
        defer ui.end(c);
        const item = ui.item(c, .{ .label = "Report", .variant = s.variant, .size = if (s.small) .small else .normal });
        item.icon("doc.text");
        item.content("Annual report", "A longer description wraps within the available space beside the actions.");
        if (ui.button(c, "Open", .{}).clicked) s.opens += 1;
        if (ui.button(c, "Remove", .{ .disabled = true }).clicked) s.removes += 1;
        item.end();
        const person = ui.item(c, .{ .variant = .plain });
        person.avatar("Ada Lovelace", .{});
        person.content("Ada Lovelace", "");
        person.end();
    }
};

test "item: content, media and independent keyboard actions" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 540 });
    defer t.deinit();
    try testing.expect(t.hasText("Annual report") and t.hasText("AL"));
    try testing.expectEqual(1, t.ctx.focus_order.items.len);
    try t.clickText("Annual report");
    try testing.expectEqual(0, s.opens);
    try t.clickText("Open");
    try testing.expectEqual(1, s.opens);
    t.key(.enter);
    try testing.expectEqual(2, s.opens);
    try t.clickText("Remove");
    try testing.expectEqual(0, s.removes);
    _ = t.shortcut(.{ .key = ui.Shortcut.tab });
    t.typeText(" ");
    try testing.expectEqual(3, s.opens);
}

test "item: variants, wrapped content, RTL and accessibility preserve actions" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 500 });
    defer t.deinit();
    t.ctx.access.enabled = true;
    var tree: Tree = .init(testing.allocator);
    defer tree.deinit();
    for ([_]@FieldType(ui.ItemOptions, "variant"){ .plain, .outline, .muted }) |variant| {
        s.variant = variant;
        s.small = variant == .muted;
        t.frame();
        tree.build(&t.ctx);
        try testing.expect(tree.byName(.group, "Report") != null);
        try testing.expect(tree.byName(.button, "Open") != null);
        try testing.expect(tree.byName(.button, "Remove").?.states.disabled);
        const title = t.findText("Annual report").?;
        const action = t.findText("Open").?;
        try testing.expect(title.x + title.w <= action.x);
    }
    ui.direction.set(&t.ctx, .rtl);
    t.frame();
    const title = t.findText("Annual report").?;
    const action = t.findText("Open").?;
    try testing.expect(action.x + action.w <= title.x);
    try t.clickText("Open");
    try testing.expectEqual(1, s.opens);
    // Both themes exercise the shared render path without a window.
    const light = try t.render(testing.allocator);
    defer light.deinit(testing.allocator);
    t.theme = ui.Theme.dark_theme;
    t.frame();
    const dark = try t.render(testing.allocator);
    defer dark.deinit(testing.allocator);
}
