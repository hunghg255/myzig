const std = @import("std");
const text = @import("ui/text_tt.zig");
test "probe" {
    var ts = text.TextSystem.init(std.testing.allocator);
    defer ts.deinit();
    const st: @import("ui/types.zig").TextStyle = .{ .size = 16 };
    var buf: [64]u8 = undefined;
    for (0..10) |i| for (0..10) |j| {
        _ = ts.layout(std.fmt.bufPrint(&buf, "Row {d}{d} \xe2\x80\x94 a line", .{ i, j }) catch unreachable, st);
    };
    for ([_][]const u8{ "Row 100 \xe2\x80\x94 a line", "Row 8019 \xe2\x80\x94 a line", "Row 801 \xe2\x80\x94 a line", "Row 801" }) |s| {
        const b = ts.engine_lines;
        const l = ts.layout(s, st);
        std.debug.print("{s}: engine {d} glyphs {d} clusters {d}\n", .{ s, ts.engine_lines - b, l.glyphs.len, l.clusters.len });
    }
}
