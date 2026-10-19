//! A select with more options than the window has room for keeps its
//! popup in the window, where its options scroll.
const std = @import("std");
const ui = @import("ui.zig");
const select = @import("select.zig");
const testing = std.testing;

const options = blk: {
    var out: [60][]const u8 = undefined;
    for (&out, 0..) |*o, i| o.* = std.fmt.comptimePrint("Option {d:0>2}", .{i});
    break :blk out;
};

const Form = struct {
    top: f32,
    value: usize = 30,
    box: select.SelectState = .{},

    fn view(s: *Form, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .{ .left = 20, .top = s.top } });
        defer ui.end(c);
        _ = select.select(c, &s.value, &options, &s.box, .{});
    }
};

test "select: a long list opening below or above stays in the window and scrolls" {
    for ([_]f32{ 20, 200 }) |top| {
        var s: Form = .{ .top = top };
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&s, Form.view), .{ .width = 400, .height = 300 });
        defer t.deinit();
        try t.clickText("Option 30");
        try testing.expect(s.box.isOpen());
        for ([_]struct { k: @import("context.zig").Key, option: []const u8 }{ .{ .k = .end, .option = "Option 59" }, .{ .k = .home, .option = "Option 00" } }) |e| {
            t.key(e.k);
            t.frame();
            const r = t.findText(e.option) orelse return error.NoOption;
            try testing.expect(r.h > 0 and r.y >= 0 and r.y + r.h <= 300);
        }
        try t.clickText("Option 00");
        try testing.expectEqual(@as(usize, 0), s.value);
    }
}
