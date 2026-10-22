//! Win32 wheel and precision touchpad zoom.
const w = @import("win32.zig");
const Surface = @import("surface.zig").Surface;
const gesture = @import("../ui/gesture.zig");

/// Win32 wheel data, independent of a window or renderer. Positive vertical
/// deltas scroll up; positive horizontal deltas scroll right.
pub fn wheelEvent(wp: w.WPARAM, horizontal: bool) gesture.InputEvent {
    const raw: u16 = @truncate(wp >> 16);
    const ticks: i16 = @bitCast(raw);
    const notches: f32 = @as(f32, @floatFromInt(ticks)) / 120;
    const delta = notches * 48;
    const notch = notches == @round(notches);
    var ev: gesture.InputEvent = if (!horizontal and !notch and wp & 8 != 0)
        .{ .kind = .zoom, .scale = @exp(delta / 300) }
    else
        .{ .kind = .scroll, .dx = if (horizontal) delta else 0, .dy = if (horizontal) 0 else -delta, .precise = !notch };
    ev.ctrl = wp & 8 != 0;
    ev.shift = wp & 4 != 0;
    return ev;
}

pub fn wheel(self: *Surface, h: w.HWND, wp: w.WPARAM, lp: w.LPARAM, horizontal: bool) void {
    var p: w.POINT = .{ .x = @as(i16, @truncate(lp)), .y = @as(i16, @truncate(lp >> 16)) };
    _ = w.ScreenToClient(h, &p);
    self.ctx.input.mouse = .{ .x = @as(f32, @floatFromInt(p.x)) / self.scale, .y = @as(f32, @floatFromInt(p.y)) / self.scale };
    const ev = wheelEvent(wp, horizontal);
    self.ctx.input.ctrl = ev.ctrl;
    self.ctx.input.shift = ev.shift;
    if (gesture.deliver(&self.ctx, ev)) {
        self.frame();
        return;
    }
    if (ev.kind == .zoom) return;
    if (horizontal) {
        if (self.ctx.wants_wheel) {
            self.ctx.input.scroll = .{ .x = ev.dx };
            self.frame();
        }
        return;
    }
    const delta = -ev.dy;
    if (if (ev.precise) self.ctx.applyScroll(delta) else self.ctx.applyWheel(delta)) {
        self.frame();
        self.ctx.updateHot();
    } else if (self.ctx.wants_wheel) {
        self.ctx.input.scroll = .{ .y = delta };
        self.frame();
    }
}

test "Win32 wheel translation distinguishes pinch, notches and horizontal pan" {
    const std = @import("std");
    const expect = std.testing;
    const Pack = struct {
        fn wheel(delta: i16, mods: u16) w.WPARAM {
            return (@as(w.WPARAM, @as(u16, @bitCast(delta))) << 16) | mods;
        }
    };
    for ([_]i16{ 120, -120 }) |delta| {
        const e = wheelEvent(Pack.wheel(delta, 12), false);
        try expect.expect(e.kind == .scroll);
        try expect.expect(!e.precise and e.ctrl and e.shift);
        try expect.expectEqual(@as(f32, if (delta > 0) -48 else 48), e.dy);
    }
    const pinch_in = wheelEvent(Pack.wheel(30, 8), false);
    const pinch_out = wheelEvent(Pack.wheel(-30, 8), false);
    try expect.expect(pinch_in.kind == .zoom and pinch_out.kind == .zoom);
    try expect.expect(pinch_in.scale > 1 and pinch_out.scale < 1);
    try expect.expectApproxEqAbs(@as(f32, 1), pinch_in.scale * pinch_out.scale, 0.00001);
    const precise = wheelEvent(Pack.wheel(30, 0), false);
    try expect.expect(precise.kind == .scroll and precise.precise and !precise.ctrl);
    try expect.expectEqual(@as(f32, -12), precise.dy);
    for ([_]i16{ 120, -120, 30, -30 }) |delta| {
        const e = wheelEvent(Pack.wheel(delta, 8), true);
        try expect.expect(e.kind == .scroll and e.ctrl);
        try expect.expectEqual(@as(f32, @floatFromInt(delta)) * 0.4, e.dx);
        try expect.expectEqual(@as(f32, 0), e.dy);
    }
}

test "the hidden Windows surface routes horizontal wheel and pinch payloads to its handler" {
    const std = @import("std");
    const ui = @import("../ui/ui.zig");
    const App = @import("app.zig").App;
    const S = struct {
        count: usize = 0,
        last: ui.InputEvent = .{ .kind = .scroll },
        fn input(s: *@This(), e: ui.InputEvent) bool {
            s.count += 1;
            s.last = e;
            return true;
        }
        fn view(s: *@This(), c: *ui.Context) void {
            const box = ui.div(c).size(100, 100).handleInput(s, input);
            box.end();
        }
    };
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const app = try App.createHidden(std.testing.allocator, std.testing.io, &env, .{ .name = "gesture-tests", .quit_on_signal = false });
    defer app.destroy();
    var state: S = .{};
    const win = try app.newWindow(.{
        .width = 200,
        .height = 200,
        .title_bar = .hidden,
        .hide_window_buttons = true,
        .content = .{ .view = .init(&state, S.view) },
    });
    const h = win.hwnd.?;
    const surface = win.surface.?;
    surface.frame();
    try std.testing.expect(w.IsWindowVisible(h) == 0);
    try std.testing.expect(win.caption == null);
    try std.testing.expectEqual(@as(f64, 0), win.titleBar().right);
    var point: w.POINT = .{ .x = @intFromFloat(50 * surface.scale), .y = @intFromFloat(50 * surface.scale) };
    _ = @import("gdi.zig").ClientToScreen(h, &point);
    const x: u16 = @bitCast(@as(i16, @truncate(point.x)));
    const y: u16 = @bitCast(@as(i16, @truncate(point.y)));
    const lp: w.LPARAM = @bitCast(@as(usize, x) | @as(usize, y) << 16);
    // Call the adapter directly: no OS input messages are sent or posted.
    _ = surface.handle(h, w.WM_MOUSEHWHEEL, (@as(w.WPARAM, 120) << 16) | 12, lp);
    try std.testing.expectEqual(@as(usize, 1), state.count);
    try std.testing.expect(state.last.kind == .scroll and state.last.ctrl and state.last.shift);
    try std.testing.expectEqual(@as(f32, 48), state.last.dx);
    try std.testing.expectEqual(@as(f32, 0), state.last.dy);
    try std.testing.expectApproxEqAbs(@as(f32, 50), state.last.x, 0.01);
    _ = surface.handle(h, w.WM_MOUSEWHEEL, (@as(w.WPARAM, 30) << 16) | 8, lp);
    try std.testing.expectEqual(@as(usize, 2), state.count);
    try std.testing.expect(state.last.kind == .zoom and state.last.scale > 1);
    try std.testing.expect(w.IsWindowVisible(h) == 0);
}
