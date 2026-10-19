//! Siblings leaving together: their copies go, and paint, in the order the
//! boxes had, not in the order of the map that keeps them.
const std = @import("std");
const ui = @import("ui.zig");
const motion = ui.motion;
const testing = std.testing;

const colors = [_]ui.Color{ .hex(0xff0000), .hex(0x00ff00), .hex(0x0000ff), .hex(0xffff00), .hex(0x00ffff), .hex(0xff00ff), .hex(0x808080), .hex(0x804000) };

const Row = struct {
    shown: bool = true,

    fn view(s: *Row, c: *ui.Context) void {
        _ = c.open(.{ .direction = .row, .width = .{ .px = 200 }, .height = .{ .px = 40 } }, null);
        defer c.end();
        if (!s.shown) return;
        for (colors, 0..) |bg, i| {
            c.keyed(i);
            const box = c.open(.{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .background = bg }, null);
            motion.transition(c, box, .{ .duration = 0.1, .ease = .linear, .exit = .{ .x = 15, .opacity = 1 } });
            c.end();
        }
    }
};

fn colorAt(i: @import("gpu.zig").Instance) ?usize {
    for (colors, 0..) |bg, k| if (@abs(i.color[0] - bg.r) < 0.01 and @abs(i.color[1] - bg.g) < 0.01 and @abs(i.color[2] - bg.b) < 0.01) return k;
    return null;
}

test "transitions: siblings leaving together paint in the order they had" {
    var s: Row = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Row.view), .{ .width = 200, .height = 40 });
    defer t.deinit();
    t.frame();
    s.shown = false;
    t.frame();
    t.advance(0.05);
    var order: [colors.len]usize = undefined;
    var n: usize = 0;
    for (t.instances.items) |i| if (colorAt(i)) |k| {
        if (n == 0 or order[n - 1] != k) {
            try testing.expect(n < order.len);
            order[n] = k;
            n += 1;
        }
    };
    try testing.expectEqual(colors.len, n);
    for (order[0..n], 0..) |k, i| try testing.expectEqual(i, k);
}
