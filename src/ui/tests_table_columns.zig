const std = @import("std");
const ui = @import("ui.zig");
const Tree = @import("access_tree.zig").Tree;
const testing = std.testing;

const App = struct {
    state: ui.TableState = .{},
    widths: [3]f32 = .{ 180, 100, 100 },
    hide: bool = false,
    rtl: bool = false,
    resized: usize = 0,
    emitted: [3]bool = .{ false, false, false },

    fn view(s: *App, c: *ui.Context) void {
        ui.direction.set(c, if (s.rtl) .rtl else .ltr);
        _ = c.open(.{ .width = .fill, .height = .fill, .padding = .all(12) }, null);
        defer c.end();
        const cols = [_]ui.TableColumn{
            .{ .title = "Name", .sortable = true, .min_width = 120, .max_width = 240 },
            .{ .title = "Status", .hidden = s.hide },
            .{ .title = "Amount", .sortable = true },
        };
        var table = ui.table(c, &s.state, &cols, 2, .{ .column_widths = &s.widths, .cells = true });
        s.emitted = .{ false, false, false };
        while (table.next()) |_| while (table.cell()) |col| {
            s.emitted[col] = true;
            ui.text(c, switch (col) {
                0 => "Ada",
                1 => "Paid",
                else => "$240",
            }, .{});
        };
        if (table.end().resized) s.resized += 1;
    }
};

fn grip(t: *ui.Tester, name: []const u8) !struct { id: u64, rect: ui.Rect } {
    var tree: Tree = .init(testing.allocator);
    defer tree.deinit();
    tree.build(&t.ctx);
    const node = tree.byName(.splitter, name) orelse return error.NoGrip;
    return .{ .id = node.id, .rect = t.ctx.rects.get(node.id).? };
}

test "table columns: hidden cells retain original indices and sorting" {
    var s: App = .{ .hide = true };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{});
    defer t.deinit();
    try testing.expect(s.emitted[0] and !s.emitted[1] and s.emitted[2]);
    try testing.expect(!t.hasText("Status") and !t.hasText("Paid"));
    try t.clickText("Amount");
    try testing.expectEqual(2, s.state.sort.?.column);
    try t.clickText("Ada");
    t.key(.right);
    try testing.expectEqual(2, s.state.cols.?[1]);
    s.hide = false;
    t.frame();
    try testing.expect(t.hasText("Paid") and s.emitted[1]);
}

test "table columns: keyboard resize clamps and does not sort" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{});
    defer t.deinit();
    t.ctx.access.enabled = true;
    t.frame();
    const handle = try grip(&t, "Resize Name");
    t.click(handle.rect.x + handle.rect.w / 2, handle.rect.y + handle.rect.h / 2);
    t.key(.right);
    try testing.expectEqual(@as(f32, 190), s.widths[0]);
    t.key(.home);
    try testing.expectEqual(@as(f32, 120), s.widths[0]);
    t.key(.left);
    try testing.expectEqual(@as(f32, 120), s.widths[0]);
    t.key(.end);
    try testing.expectEqual(@as(f32, 240), s.widths[0]);
    try testing.expect(s.state.sort == null and s.resized > 0);
}

test "table columns: pointer resize and RTL keyboard direction" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{});
    defer t.deinit();
    t.ctx.access.enabled = true;
    t.frame();
    const handle = try grip(&t, "Resize Name");
    const x = handle.rect.x + handle.rect.w / 2;
    const y = handle.rect.y + handle.rect.h / 2;
    t.moveTo(x, y);
    t.ctx.pointerDown();
    t.frame();
    t.moveTo(x + 30, y);
    t.ctx.pointerUp();
    t.frame();
    try testing.expectEqual(@as(f32, 210), s.widths[0]);
    try testing.expect(s.state.sort == null);
    s.rtl = true;
    t.frame();
    t.ctx.focus = (try grip(&t, "Resize Name")).id;
    t.key(.left);
    try testing.expectEqual(@as(f32, 220), s.widths[0]);
}
