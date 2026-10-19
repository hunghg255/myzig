//! Text typed through assistive technology (`Action.insert_text`): over
//! the selection, as typing it does, and at the caret without one.
const std = @import("std");
const ui = @import("ui.zig");
const access = @import("access.zig");
const Tree = @import("access_tree.zig").Tree;

const App = struct {
    name: ui.TextBuffer = .{},

    fn view(s: *App, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(12) });
        defer ui.end(c);
        _ = ui.textField(c, &s.name, .{ .label = "Name" });
    }
};

test "access: inserting text replaces the selection, then types at the caret" {
    var app: App = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&app, App.view), .{});
    defer t.deinit();
    t.ctx.access.enabled = true;
    t.frame();
    var tree: Tree = .init(std.testing.allocator);
    defer tree.deinit();
    tree.build(&t.ctx);
    const field = tree.byName(.text_field, "Name").?.id;
    access.perform(&t.ctx, field, .text_field, .{ .set_value = "Grace" });
    t.frame();
    access.perform(&t.ctx, field, .text_field, .{ .select_text = .{ 0, 5 } });
    t.frame();
    access.perform(&t.ctx, field, .text_field, .{ .insert_text = "Ada" });
    t.frame();
    try std.testing.expectEqualStrings("Ada", app.name.text());
    access.perform(&t.ctx, field, .text_field, .{ .insert_text = " L." });
    t.frame();
    try std.testing.expectEqualStrings("Ada L.", app.name.text());
    tree.build(&t.ctx);
    const f = tree.find(field).?;
    try std.testing.expectEqual(@as(u32, 6), f.sel_start);
    try std.testing.expectEqual(@as(u32, 6), f.sel_end);
    try std.testing.expectEqual(field, tree.focus);
}
