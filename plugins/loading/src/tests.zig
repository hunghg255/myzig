const std = @import("std");
const ui = @import("myzig").ui;
const indicators = @import("indicators.zig");

const Stage = struct {
    frame: indicators.Frame,
    fn view(s: *Stage, c: *ui.Context) void {
        _ = ui.canvas(c, .{ .w = 64, .h = 64 }, .{}, &s.frame, indicators.Frame.draw);
    }
};

fn hash(t: *ui.Tester) !u64 {
    const pixels = try t.render(std.testing.allocator);
    defer pixels.deinit(std.testing.allocator);
    return std.hash.Wyhash.hash(0, pixels.bytes);
}

test "every design draws, animates, and has a stable reduced-motion pose" {
    for (indicators.names, 0..) |name, i| {
        var stage: Stage = .{ .frame = .{ .index = i, .seconds = 0, .options = .{ .color = .hex(0x4477ee) } } };
        var t: ui.Tester = undefined;
        try t.init(std.testing.allocator, .init(&stage, Stage.view), .{ .width = 64, .height = 64, .scale = 1 });
        defer t.deinit();
        const before = try hash(&t);
        stage.frame.seconds = 0.371;
        t.frame();
        if (before == try hash(&t)) {
            std.debug.print("unchanged indicator: {s}\n", .{name});
            return error.IndicatorDidNotMove;
        }
        stage.frame.options.still = true;
        t.frame();
        const resting = try hash(&t);
        stage.frame.seconds = 17.9;
        t.frame();
        try std.testing.expectEqual(resting, try hash(&t));
        // Color must affect every design, including its resting pose.
        stage.frame.options.color = .hex(0xee5544);
        t.frame();
        try std.testing.expect(resting != try hash(&t));
    }
}

test "arc caps and rotation easing affect the painted pixels" {
    var stage: Stage = .{ .frame = .{ .index = 0, .seconds = 0.17, .options = .{ .color = .hex(0x4477ee) } } };
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&stage, Stage.view), .{ .width = 64, .height = 64, .scale = 1 });
    defer t.deinit();
    const round = try hash(&t);
    stage.frame.options.cap = .flat;
    t.frame();
    const flat = try hash(&t);
    try std.testing.expect(round != flat);
    stage.frame.options.easing = .ease_in_out;
    t.frame();
    const eased = try hash(&t);
    try std.testing.expect(flat != eased);
    stage.frame.options.easing = .stacked;
    t.frame();
    try std.testing.expect(eased != try hash(&t));
}
