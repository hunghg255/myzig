const std = @import("std");
const ui = @import("ui.zig");
const Tree = @import("access_tree.zig").Tree;
const testing = std.testing;

const App = struct {
    created: usize = 0,
    retries: usize = 0,
    animated: bool = false,
    kind: ui.AlertKind = .info,

    fn view(s: *App, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .gap = 8, .padding = .all(12) });
        defer ui.end(c);
        {
            const e = ui.empty(c, "No projects", "Create a project to get started.", .{ .icon = "folder", .outline = true });
            defer e.end();
            if (ui.button(c, "Create project", .{}).clicked) s.created += 1;
        }
        {
            const a = ui.alert(c, "Connection interrupted", "Your changes are stored locally.", .{ .kind = s.kind });
            defer a.end();
            if (ui.button(c, "Retry", .{}).clicked) s.retries += 1;
        }
        ui.skeleton(c, .{ .width = .{ .px = 200 }, .animated = s.animated });
        ui.skeleton(c, .{ .width = .{ .px = 40 }, .height = 40, .radius = 20, .animated = s.animated });
    }
};

test "feedback: empty and alert preserve independent actions and accessibility" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 640, .height = 600 });
    defer t.deinit();
    try testing.expectEqual(2, t.ctx.focus_order.items.len);
    try t.clickText("Create project");
    t.key(.enter);
    try testing.expectEqual(2, s.created);
    try t.clickText("Retry");
    try testing.expectEqual(1, s.retries);
    t.ctx.access.enabled = true;
    t.frame();
    var tree: Tree = .init(testing.allocator);
    defer tree.deinit();
    tree.build(&t.ctx);
    try testing.expect(tree.byName(.group, "No projects") != null);
    try testing.expect(tree.byName(.status, "Connection interrupted") != null);
    try testing.expect(tree.byName(.button, "Retry") != null);
    ui.direction.set(&t.ctx, .rtl);
    for ([_]ui.AlertKind{ .info, .success, .warning, .danger }) |kind| {
        s.kind = kind;
        t.frame();
        const pixels = try t.render(testing.allocator);
        pixels.deinit(testing.allocator);
    }
    t.theme = ui.Theme.dark_theme;
    t.frame();
    const dark = try t.render(testing.allocator);
    defer dark.deinit(testing.allocator);
}

test "feedback: skeleton pulses only while requested and respects reduced motion" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .height = 600 });
    defer t.deinit();
    t.settle(1);
    try testing.expect(t.ctx.frame_in == null and !t.ctx.animating);
    s.animated = true;
    t.frame();
    try testing.expect(t.ctx.frame_in != null);
    const before = t.ctx.nodes.items[t.ctx.nodes.items.len - 1].style.background.?.a;
    t.advance(0.7);
    const after = t.ctx.nodes.items[t.ctx.nodes.items.len - 1].style.background.?.a;
    try testing.expect(@abs(before - after) > 0.1);
    ui.motion.setReducedMotion(&t.ctx, true);
    t.frame();
    try testing.expect(t.ctx.frame_in == null and !t.ctx.animating);
    try testing.expectEqual(2, t.ctx.focus_order.items.len);
}
