//! Painting skips boxes clipped out of view (`paint.zig`'s ink), and
//! paints the very instances it paints without skipping them: pages
//! scrolled, with shadows, blurs, text running out of its box, icons,
//! boxes placed outside their parents, turned boxes and selectable text.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const paint = @import("paint.zig");
const gpu = @import("gpu.zig");

const Page = struct {
    offset: f32 = 0,
    fn view(s: *Page, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(8) });
        defer ui.end(c);
        ui.column(c, .{ .width = .fill, .height = .fill, .clip = true, .radius = 10 });
        defer ui.end(c);
        ui.column(c, .{ .width = .fill, .offset = .{ .y = -s.offset }, .gap = 6 });
        defer ui.end(c);
        for (0..120) |i| {
            const k: f32 = @floatFromInt(i);
            ui.row(c, .{ .width = .fill, .height = .{ .px = 30 }, .gap = 8, .padding = .xy(8, 0), .align_items = .center, .radius = 6, .background = .white, .shadow = .{ .blur = 12, .y = 4 }, .blur = if (i % 17 == 0) 2 else 0, .selectable = i % 23 == 0 });
            defer ui.end(c);
            // A label wider than its box, which runs out of it.
            ui.column(c, .{ .width = .{ .px = 30 } });
            ui.textf(c, .{ .size = 13 }, "Row {d} with a long label", .{i});
            ui.end(c);
            ui.icon(c, "star.fill", .{ .size = 14 });
            if (i % 9 == 0) _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 200, .y = -40 }, .width = .{ .px = 20 }, .height = .{ .px = 20 }, .background = .hex(0xe0401a) }, .none, null);
            if (i % 13 == 0) _ = c.leaf(.{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .background = .hex(0x1a4ce0), .transform = .rotation(30 + k) }, .none, null);
        }
    }
};

test "painting skips what its clip leaves out, and paints what it painted" {
    const gpa = testing.allocator;
    var s: Page = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Page.view), .{ .width = 320, .height = 240 });
    defer t.deinit();
    defer paint.cull = true;
    var all: std.ArrayList(gpu.Instance) = .empty;
    defer all.deinit(gpa);
    var culled: usize = 0;
    for ([_]f32{ 0, 13, 200, 777.5, 1500, 3600, 4400 }) |offset| {
        s.offset = offset;
        paint.cull = false;
        t.frame();
        all.clearRetainingCapacity();
        try all.appendSlice(gpa, t.instances.items);
        paint.cull = true;
        const before = paint.skipped;
        t.frame();
        if (paint.skipped > before) culled += 1;
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(all.items), std.mem.sliceAsBytes(t.instances.items));
    }
    // Rows out of view were skipped, at every offset.
    try testing.expectEqual(@as(usize, 7), culled);
}
