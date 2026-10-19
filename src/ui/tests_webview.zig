//! Web views in native UI through the Tester: where frames place them as
//! layout, scrolling and clips change, hidden when cut away or not built,
//! and Tab moving into and out of them. A Tester has no window: no page
//! is made, the placements are what a window would get.
const std = @import("std");
const ui = @import("ui.zig");
const webview = @import("webview.zig");
const testing = std.testing;

const App = struct {
    side: f32 = 100,
    spacer: f32 = 0,
    show: bool = true,
    second: bool = false,
    a: webview.WebView = .{},
    b: webview.WebView = .{},

    fn view(s: *App, c: *ui.Context) void {
        ui.row(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        ui.column(c, .{ .width = .{ .px = s.side }, .height = .fill, .gap = 4 });
        _ = ui.button(c, "Before", .{});
        ui.end(c);
        ui.scroll(c, .{ .grow = 1, .height = .{ .px = 200 } });
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = s.spacer } }, .none, null);
        if (s.show) _ = webview.webView(c, &s.a, .{ .height = .{ .px = 120 }, .padding = .all(8) });
        if (s.second) _ = webview.webView(c, &s.b, .{ .height = .{ .px = 60 } });
        _ = ui.button(c, "After", .{});
        ui.end(c);
    }
};

fn expectRect(want: ui.Rect, got: ui.Rect) !void {
    try testing.expectApproxEqAbs(want.x, got.x, 0.01);
    try testing.expectApproxEqAbs(want.y, got.y, 0.01);
    try testing.expectApproxEqAbs(want.w, got.w, 0.01);
    try testing.expectApproxEqAbs(want.h, got.h, 0.01);
}

test "a web view goes where layout puts its content box, and follows it" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    const p = s.a.shown.?;
    try expectRect(.{ .x = 108, .y = 8, .w = 284, .h = 104 }, p.frame);
    try expectRect(p.frame, p.clip);
    try testing.expectEqual(@as(f32, 2), p.scale);
    try testing.expect(s.a.page == null); // no window
    s.side = 150;
    t.frame();
    try expectRect(.{ .x = 158, .y = 8, .w = 234, .h = 104 }, s.a.shown.?.frame);
    t.resize(500, 300);
    try testing.expectApproxEqAbs(@as(f32, 334), s.a.shown.?.frame.w, 0.01);
}

test "scroll containers cut a web view, which hides once cut away" {
    var s: App = .{ .spacer = 150 };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    // Its page starts 158 down a box 200 tall: 42 of it shows.
    var p = s.a.shown.?;
    try testing.expectApproxEqAbs(@as(f32, 158), p.frame.y, 0.01);
    try expectRect(.{ .x = 108, .y = 158, .w = 284, .h = 42 }, p.clip);
    t.scroll(200, 100, -100);
    t.frame();
    p = s.a.shown.?;
    try testing.expect(p.frame.y < 158);
    try testing.expect(p.clip.h > 42);
    s.spacer = 400;
    t.scroll(200, 100, 1000);
    t.frame();
    try testing.expect(s.a.shown == null);
}

test "a web view the view does not build hides; several show at once" {
    var s: App = .{ .second = true };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    try testing.expect(s.a.shown != null and s.b.shown != null);
    try testing.expectApproxEqAbs(s.a.shown.?.frame.y + 104 + 8, s.b.shown.?.frame.y, 0.01);
    s.show = false;
    t.frame();
    try testing.expect(s.a.shown == null);
    try testing.expectApproxEqAbs(@as(f32, 0), s.b.shown.?.frame.y, 0.01);
    s.show = true;
    t.frame();
    try testing.expect(s.a.shown != null);
}

test "Tab stops at a web view, and its page's Tab goes on past it" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    t.key(.tab); // Before
    t.key(.tab); // the web view
    try testing.expectEqual(s.a.id, t.ctx.focus);
    try testing.expect(s.a.focused);
    // Its page's Tab went past its last element: on to After.
    s.a.tabOut(false);
    t.frame();
    try testing.expect(!s.a.focused);
    try testing.expect(t.ctx.focus != s.a.id and t.ctx.focus != 0);
    s.a.tabOut(true);
    t.frame();
    try testing.expect(t.ctx.focus != s.a.id);
    // Clicked, the page takes native UI's focus.
    s.a.tookFocus();
    t.frame();
    try testing.expectEqual(s.a.id, t.ctx.focus);
}
