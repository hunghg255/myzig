const std = @import("std");
const ui = @import("ui.zig");
const buttons = @import("window_buttons.zig");

test "maximize marker follows layout, clears when removed, and ignores clipped buttons" {
    const S = struct {
        show: bool = true,
        fn view(s: *@This(), c: *ui.Context) void {
            const row = ui.div(c).row().size(200, 40);
            defer row.end();
            if (s.show) {
                const button = ui.div(c).size(40, 32).maximizeButton();
                button.end();
            }
        }
    };
    var s: S = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&s, S.view), .{});
    defer t.deinit();
    try std.testing.expectEqual(@as(f32, 40), buttons.rect(&t.ctx).?.w);
    s.show = false;
    t.frame();
    try std.testing.expect(buttons.rect(&t.ctx) == null);
    s.show = true;
    t.resize(10, 10);
    const r = buttons.rect(&t.ctx).?;
    try std.testing.expect(r.w <= 10 and r.h <= 10);
}

test "the Windows host receives and clears the maximize rectangle without a native window" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const Window = @import("../windows/window.zig").Window;
    const S = struct {
        show: bool = true,
        fn view(s: *@This(), c: *ui.Context) void {
            if (s.show) {
                const b = ui.div(c).size(40, 32).maximizeButton();
                b.end();
            }
        }
    };
    var s: S = .{};
    var window: Window = .{ .app = undefined, .title_bar = .hidden, .hide_window_buttons = true };
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&s, S.view), .{});
    defer t.deinit();
    t.ctx.host = &window;
    t.frame();
    try std.testing.expectEqual(@as(f64, 40), window.snap.?.width);
    try std.testing.expectEqual(@as(f64, 0), window.titleBar().right);
    // An ordinary title bar leaves a manually managed snap rectangle alone.
    window.hide_window_buttons = false;
    window.snap = .{ .x = 123, .y = 0, .width = 20, .height = 20 };
    t.frame();
    try std.testing.expectEqual(@as(f64, 123), window.snap.?.x);
    window.hide_window_buttons = true;
    window.title_bar = .default;
    t.frame();
    try std.testing.expectEqual(@as(f64, 123), window.snap.?.x);
    window.title_bar = .hidden;
    s.show = false;
    t.frame();
    try std.testing.expect(window.snap == null);
}

test "Snap chooses the first valid marker, follows movement and skips hidden rotated or clipped buttons" {
    const S = struct {
        x: f32 = 8,
        opacity: f32 = 1,
        rotated: bool = false,
        fn view(s: *@This(), c: *ui.Context) void {
            const first = ui.div(c).absolute().offset(s.x, 10).size(40, 32).opacity(s.opacity).maximizeButton();
            if (s.rotated) c.node(first.index).style.transform = ui.Affine.rotation(90);
            first.end();
            const second = ui.div(c).absolute().offset(100, 10).size(40, 32).maximizeButton();
            second.end();
        }
    };
    var s: S = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&s, S.view), .{});
    defer t.deinit();
    try std.testing.expectEqual(@as(f32, 8), buttons.rect(&t.ctx).?.x);
    s.x = 28;
    t.frame();
    try std.testing.expectEqual(@as(f32, 28), buttons.rect(&t.ctx).?.x);
    s.opacity = 0;
    t.frame();
    try std.testing.expectEqual(@as(f32, 100), buttons.rect(&t.ctx).?.x);
    s.opacity = 1;
    s.rotated = true;
    t.frame();
    try std.testing.expectEqual(@as(f32, 100), buttons.rect(&t.ctx).?.x);
    s.rotated = false;
    s.x = -1000;
    t.frame();
    try std.testing.expectEqual(@as(f32, 100), buttons.rect(&t.ctx).?.x);
}
