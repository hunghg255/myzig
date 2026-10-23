const std = @import("std");
const ui = @import("ui.zig");
const access = @import("access.zig");
const Tree = @import("access_tree.zig").Tree;
const testing = std.testing;

const App = struct {
    value: ui.TextBuffer = .{},
    disabled: bool = false,
    invalid: bool = false,
    submitted: usize = 0,
    actions: usize = 0,
    edits: usize = 0,
    prefix: bool = true,
    label: bool = false,
    leading_button: bool = false,

    fn view(s: *App, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .padding = .all(12), .gap = 8 });
        defer ui.end(c);
        const field: ?ui.Field = if (s.label) ui.field(c, "Website", .{ .err = if (s.invalid) "Invalid URL" else "" }) else null;
        var g = ui.inputGroup(c, .{ .width = .{ .px = 400 }, .disabled = s.disabled, .invalid = s.invalid });
        if (s.leading_button) _ = g.button("Prefix action", .{ .size = 10 });
        if (s.prefix) g.text("https://");
        const result = g.input(&s.value, .{ .label = if (s.label) "" else "Address", .placeholder = "example.com" });
        if (result.changed) s.edits += 1;
        if (result.submitted) s.submitted += 1;
        g.text(".org");
        if (g.button("Clear", .{ .variant = .ghost, .size = 12 })) {
            s.value.set("");
            s.actions += 1;
        }
        g.end();
        if (field) |f| f.end();
        _ = ui.button(c, "After", .{});
    }
};

test "input group: affix focuses input, editing, submit and independent action" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{});
    defer t.deinit();
    try t.clickText("https://");
    t.typeText("myzig");
    try testing.expectEqualStrings("myzig", s.value.text());
    try testing.expectEqual(1, s.edits);
    t.key(.enter);
    try testing.expectEqual(1, s.submitted);
    // Removing a decorative prefix keeps the keyed input and its caret.
    s.prefix = false;
    t.frame();
    t.typeText(".dev");
    try testing.expectEqualStrings("myzig.dev", s.value.text());
    _ = t.shortcut(.{ .key = ui.Shortcut.tab });
    t.key(.enter);
    try testing.expectEqualStrings("", s.value.text());
    try testing.expectEqual(1, s.actions);
    try testing.expectEqual(1, s.submitted);
}

test "input group: disabled editing, buttons and accessibility" {
    var s: App = .{};
    s.value.set("kept");
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{});
    defer t.deinit();
    try t.clickText("kept");
    t.key(.home);
    t.key(.right);
    t.key(.right);
    s.disabled = true;
    t.ctx.access.enabled = true;
    t.frame();
    t.typeText("ignored");
    try t.clickText("https://");
    t.typeText("ignored");
    try t.clickText("Clear");
    try testing.expectEqualStrings("kept", s.value.text());
    try testing.expectEqual(0, s.actions);
    try testing.expectEqual(1, t.ctx.focus_order.items.len);
    var tree: Tree = .init(testing.allocator);
    defer tree.deinit();
    tree.build(&t.ctx);
    try testing.expect(tree.byName(.text_field, "Address").?.states.disabled);
    try testing.expect(tree.byName(.button, "Clear").?.states.disabled);
    s.disabled = false;
    t.frame();
    try t.clickText(".org");
    t.typeText("!");
    // Clicking an affix restores focus without moving the existing caret.
    try testing.expectEqualStrings("ke!pt", s.value.text());
    try t.clickText("Clear");
    s.disabled = true;
    t.frame();
    try testing.expectEqual(0, t.ctx.focus);
}

test "input group: form label, error, assistive editing and RTL" {
    var s: App = .{ .label = true, .invalid = true, .leading_button = true };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{});
    defer t.deinit();
    t.ctx.access.enabled = true;
    t.frame();
    var tree: Tree = .init(testing.allocator);
    defer tree.deinit();
    tree.build(&t.ctx);
    const input = tree.byName(.text_field, "Website").?;
    try testing.expect(input.states.invalid);
    try testing.expectEqualStrings("Invalid URL", input.description);
    try t.clickText("Website");
    t.typeText("zig");
    try testing.expectEqualStrings("zig", s.value.text());
    access.perform(&t.ctx, input.id, .text_field, .{ .set_value = "native" });
    t.frame();
    try testing.expectEqualStrings("native", s.value.text());
    s.disabled = true;
    t.frame();
    tree.build(&t.ctx);
    try testing.expect(tree.byName(.text_field, "Website").?.states.disabled);
    try t.clickText("Website");
    t.typeText("ignored");
    try testing.expectEqualStrings("native", s.value.text());
    s.disabled = false;
    ui.direction.set(&t.ctx, .rtl);
    t.frame();
    try testing.expect(t.findText("Clear").?.x < t.findText("https://").?.x);
    try t.clickText("Clear");
    try testing.expectEqualStrings("", s.value.text());
    const pixels = try t.render(testing.allocator);
    defer pixels.deinit(testing.allocator);
}
