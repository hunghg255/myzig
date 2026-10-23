const std = @import("std");
const ui = @import("ui.zig");
const Tree = @import("access_tree.zig").Tree;
const testing = std.testing;

const App = struct {
    open: ui.OverlayState = .{},
    side: ui.SheetSide = .right,
    dismissible: bool = true,
    saves: usize = 0,
    value: ui.TextBuffer = .{},

    fn view(s: *App, c: *ui.Context) void {
        if (ui.button(c, "Open sheet", .{}).clicked) s.open.show();
        if (ui.sheet(c, &s.open, .{ .side = s.side, .label = "Project details", .size = 180, .dismissible = s.dismissible })) |p| {
            defer p.end();
            ui.heading(c, "Details");
            _ = ui.textField(c, &s.value, .{ .width = .fill, .label = "Name" });
            if (ui.button(c, "Save details", .{}).clicked) {
                s.saves += 1;
                s.open.close();
                c.changed = true;
            }
        }
    }
};

test "sheet: four edges, small windows, accessible name and reduced motion" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 600, .height = 420 });
    defer t.deinit();
    ui.motion.setReducedMotion(&t.ctx, true);
    t.ctx.access.enabled = true;
    var tree: Tree = .init(testing.allocator);
    defer tree.deinit();
    for ([_]ui.SheetSide{ .left, .right, .top, .bottom }) |side| {
        s.side = side;
        s.open.show();
        t.frame();
        tree.build(&t.ctx);
        const node = tree.byName(.dialog, "Project details").?;
        try testing.expect(node.states.modal);
        try testing.expect(node.rect.x >= 0 and node.rect.y >= 0);
        if (side == .right or side == .left) {
            try testing.expectApproxEqAbs(@as(f32, 180), node.rect.w, 0.1);
            try testing.expectApproxEqAbs(@as(f32, 420), node.rect.h, 0.1);
            try testing.expectApproxEqAbs(if (side == .left) @as(f32, 0) else 420, node.rect.x, 0.1);
        } else {
            try testing.expectApproxEqAbs(@as(f32, 600), node.rect.w, 0.1);
            try testing.expectApproxEqAbs(if (side == .top) @as(f32, 0) else 240, node.rect.y, 0.1);
        }
        try testing.expect(!t.ctx.animating);
        const physical = node.rect;
        ui.direction.set(&t.ctx, .rtl);
        t.frame();
        tree.build(&t.ctx);
        const rtl = tree.byName(.dialog, "Project details").?.rect;
        try testing.expectApproxEqAbs(physical.x, rtl.x, 0.1);
        try testing.expectApproxEqAbs(physical.y, rtl.y, 0.1);
        try testing.expectApproxEqAbs(physical.w, rtl.w, 0.1);
        ui.direction.set(&t.ctx, .ltr);
        t.key(.escape);
        try testing.expect(!s.open.open);
    }
    s.open.show();
    t.resize(140, 120);
    tree.build(&t.ctx);
    const rect = tree.byName(.dialog, "Project details").?.rect;
    try testing.expect(rect.w <= 140 and rect.h <= 120);
}

test "sheet: keyboard editing, actions, dismissal and focus restoration" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 600, .height = 420 });
    defer t.deinit();
    try t.clickText("Open sheet");
    const trigger = s.open.return_focus;
    t.settle(0.5);
    _ = t.shortcut(.{ .key = ui.Shortcut.tab });
    const input_focus = t.ctx.focus;
    t.typeText("Project");
    try testing.expectEqualStrings("Project", s.value.text());
    t.textOps(&.{.{ .command = .insert_tab }});
    try testing.expect(t.ctx.focus != input_focus);
    t.textOps(&.{.{ .command = .insert_backtab }});
    try testing.expectEqual(input_focus, t.ctx.focus);
    _ = t.shortcut(.{ .key = ui.Shortcut.tab });
    try testing.expect(t.ctx.focus != input_focus);
    _ = t.shortcut(.{ .key = ui.Shortcut.tab });
    try testing.expectEqual(input_focus, t.ctx.focus);
    _ = t.shortcut(.{ .key = ui.Shortcut.tab, .shift = true });
    try testing.expect(t.ctx.focus != input_focus);
    try t.clickText("Save details");
    try testing.expectEqual(1, s.saves);
    try testing.expectEqual(trigger, t.ctx.focus);
    try t.clickText("Open sheet");
    t.settle(0.5);
    t.click(200, 300);
    try testing.expect(!s.open.open);
    s.dismissible = false;
    try t.clickText("Open sheet");
    t.settle(0.5);
    t.click(200, 300);
    try testing.expect(s.open.open);
    t.key(.escape);
    try testing.expect(!s.open.open);
}
