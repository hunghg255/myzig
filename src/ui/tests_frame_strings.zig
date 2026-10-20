//! A frame's texts are read after the view returns: layout measures them
//! and paint draws them. `c.leaf` copies them into the frame's memory, so
//! a view may free or change a string right after showing it, as two
//! panes rebuilding one list of names in turn do.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const access = @import("access.zig");

const Freeing = struct {
    gpa: std.mem.Allocator,
    id: u64 = 0,

    fn view(s: *Freeing, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(10), .gap = 4 });
        defer ui.end(c);
        // Freed at once, as the first pane's names when the second
        // rebuilds the list they share.
        const name = std.fmt.allocPrint(s.gpa, "parseHeader", .{}) catch return;
        ui.text(c, name, .{});
        s.gpa.free(name);
        // Changed in place, spans and all.
        var buf = "renderFrame".*;
        var spans = [_]ui.Span{.{ .start = 0, .end = 6, .weight = .bold }};
        ui.richText(c, &buf, &spans, .{});
        @memset(&buf, 'x');
        spans[0] = .{ .start = 0, .end = 11, .italic = true };
        // What assistive technology reads, too.
        const p = ui.pressable(c, .{ .padding = .all(4) }, null);
        ui.text(c, "Go", .{});
        ui.end(c);
        s.id = p.id;
        const label = std.fmt.allocPrint(s.gpa, "Go to symbol", .{}) catch return;
        access.describe(c, p.id, .{ .label = label });
        s.gpa.free(label);
    }
};

test "a view may free or change a string right after showing it" {
    var s: Freeing = .{ .gpa = testing.allocator };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Freeing.view), .{ .width = 300, .height = 200 });
    defer t.deinit();
    t.ctx.access.enabled = true;
    t.frame();
    t.frame();
    try testing.expect(t.hasText("parseHeader"));
    try testing.expect(t.hasText("renderFrame"));
    try testing.expect(!t.containsText("xxxx"));
    const d = t.ctx.access.described.get(s.id) orelse return error.NotDescribed;
    try testing.expectEqualStrings("Go to symbol", d.label.?);
}
