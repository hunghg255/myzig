//! A form lines each label up with the first line of its control's text,
//! or with the middle of a control without text that comes first, a
//! description below it or not, and in a row with the text beside a dot.
const std = @import("std");
const ui = @import("ui.zig");
const form = @import("controls_form.zig");
const lb = @import("layout_baseline.zig");
const testing = std.testing;

const App = struct {
    name: ui.TextBuffer = .{},
    express: u32 = 0,

    fn view(s: *App, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20) });
        defer ui.end(c);
        var fm = form.form(c, .{});
        defer fm.end();
        const n = fm.field("Name", .{});
        _ = ui.textField(c, &s.name, .{ .placeholder = "Your name" });
        n.end();
        const e = fm.field("Express", .{ .description = "Ships the next day." });
        // A control without text, as a switch.
        const sw = c.open(.{ .width = .{ .px = 40 }, .height = .{ .px = 24 }, .radius = 12, .background = c.theme.track, .control = true }, "switch");
        if (c.interact(sw, .{ .focusable = true }).clicked) s.express += 1;
        c.end();
        e.end();
        const st = fm.field("Status", .{});
        ui.row(c, .{ .gap = 6 });
        _ = c.leaf(.{ .width = .{ .px = 8 }, .height = .{ .px = 8 }, .background = c.theme.success }, .none, null);
        ui.text(c, "Online", .{});
        ui.end(c);
        st.end();
    }
};

fn nodeOf(t: *ui.Tester, s: []const u8) u32 {
    for (t.ctx.nodes.items, 0..) |n, i| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, s)) return @intCast(i),
        else => {},
    };
    @panic("no such text");
}

fn baselineOf(t: *ui.Tester, i: u32) f32 {
    const n = t.ctx.node(i);
    return n.rect.y + n.style.padding.top + lb.ofText(&t.ctx, n.content.text.style);
}

test "form: labels line up with their control's text, or its middle without" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 480, .height = 360 });
    defer t.deinit();
    t.frame();
    try testing.expectApproxEqAbs(baselineOf(&t, nodeOf(&t, "Your name")), baselineOf(&t, nodeOf(&t, "Name")), 0.5);
    // Level with the switch, not with the description under it.
    const label = t.findText("Express").?;
    var sw: ?ui.Rect = null;
    for (t.ctx.nodes.items) |n| if (n.style.control and n.style.width == .px and n.style.width.px == 40) {
        sw = n.rect;
    };
    try testing.expectApproxEqAbs(sw.?.y + sw.?.h / 2, label.y + label.h / 2, 1.5);
    try testing.expect(t.findText("Ships the next day.").?.y > sw.?.y + sw.?.h);
    // Beside a dot, the text of a row lines up with its label.
    try testing.expectApproxEqAbs(baselineOf(&t, nodeOf(&t, "Online")), baselineOf(&t, nodeOf(&t, "Status")), 0.5);
}
