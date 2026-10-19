//! The inspector through `Tester`: opened by its keys beside a narrower
//! content, picking a box by the pointer without the click reaching it,
//! choosing one in the tree, its details, the frames' costs, and its RTL
//! toggle.
const std = @import("std");
const ui = @import("ui.zig");
const insp = @import("inspector.zig");
const direction = @import("direction.zig");
const testing = std.testing;

const App = struct {
    inspector: insp.Inspector = .{},
    saves: u32 = 0,

    fn view(s: *App, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(10), .gap = 8 });
        ui.text(c, "Hello", .{});
        if (ui.button(c, "Save", .{}).clicked) s.saves += 1;
        ui.end(c);
        insp.inspector(c, &s.inspector);
    }
};

fn pickKeys() ui.Shortcut {
    return if (@import("builtin").os.tag == .macos) .{ .key = 'c', .cmd = true, .shift = true } else .{ .key = 'c', .ctrl = true, .shift = true };
}

test "inspector: F12 opens it beside the content, picking chooses without clicking" {
    if (!insp.enabled) return error.SkipZigTest;
    var s: App = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 800, .height = 500 });
    defer t.deinit();
    try testing.expect(!t.hasText("Inspector"));
    t.key(.f12);
    t.frame();
    try testing.expect(s.inspector.open);
    try testing.expect(t.hasText("Inspector"));
    // The content is narrower by the panel.
    try testing.expectEqual(@as(f32, 800 - 340), t.ctx.nodes.items[1].rect.w);
    try testing.expect(t.containsText("boxes"));

    // Pick the button: the click goes to the inspector.
    try testing.expect(t.shortcut(pickKeys()));
    try testing.expect(s.inspector.picking);
    const save = t.findText("Save").?;
    t.click(save.x + 2, save.y + 2);
    try testing.expectEqual(@as(u32, 0), s.saves);
    try testing.expect(!s.inspector.picking);
    try testing.expect(s.inspector.selected != 0);
    t.moveTo(5, 480);
    try testing.expect(t.hasText("Text \"Save\""));
    try testing.expect(t.containsText("x "));
    // Outlined, with its size.
    try testing.expect(t.containsText(" × "));
    // The frames' costs are noted, once a frame.
    try testing.expect(s.inspector.stats_count > 0);

    // Escape stops picking.
    try testing.expect(t.shortcut(pickKeys()));
    t.key(.escape);
    try testing.expect(!s.inspector.picking);
    t.key(.f12);
    try testing.expect(!s.inspector.open);
    try testing.expect(!t.hasText("Inspector"));
    try t.clickText("Save");
    try testing.expectEqual(@as(u32, 1), s.saves);
}

test "inspector: the tree chooses a box, the RTL toggle mirrors the content only" {
    if (!insp.enabled) return error.SkipZigTest;
    var s: App = .{};
    s.inspector.open = true;
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 800, .height = 500 });
    defer t.deinit();
    t.frame();
    try testing.expect(t.hasText("Text \"Hello\""));
    try t.clickText("Text \"Hello\"");
    const hello_id = blk: {
        for (t.ctx.nodes.items) |n| if (n.content == .text and std.mem.eql(u8, n.content.text.str, "Hello")) break :blk n.id;
        unreachable;
    };
    try testing.expectEqual(hello_id, s.inspector.selected);
    const before = t.findText("Hello").?;
    try t.clickText("RTL");
    t.frame();
    try testing.expectEqual(direction.Direction.rtl, direction.window(&t.ctx));
    const after = t.findText("Hello").?;
    // The content goes right to left, beside the panel, which stays.
    try testing.expect(after.x > before.x);
    try testing.expect(after.x >= 340);
    // The panel docks at the left, and reads left to right.
    try testing.expectEqual(@as(f32, 8), t.findText("Inspector").?.x);
}
