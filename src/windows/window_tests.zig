//! Windows' behavior on Windows, through windows that are made but never
//! shown: the messages a user's actions bring are sent to their window
//! procedures (closing, activating, sizing, the caption buttons' hit
//! tests and clicks, global shortcuts).
const std = @import("std");
const w = @import("win32.zig");
const gdi = @import("gdi.zig");
const caption = @import("caption.zig");
const frame = @import("frame.zig");
const hotkey = @import("hotkey.zig");
const App = @import("app.zig").App;
const Window = @import("window.zig").Window;
const ui = @import("../ui/ui.zig");
const window_types = @import("../window_types.zig");
const app_types = @import("../app_types.zig");

const t = std.testing;

const Probe = struct {
    allow: bool = false,
    asked: usize = 0,
    closed: usize = 0,
    events: std.ArrayList(window_types.Event) = .empty,
    hotkeys: usize = 0,

    fn view(_: *Probe, c: *ui.Context) void {
        _ = c;
    }
    fn request(p: *Probe, _: *Window) bool {
        p.asked += 1;
        return p.allow;
    }
    fn close(p: *Probe, _: *Window) void {
        p.closed += 1;
    }
    fn event(p: *Probe, _: *Window, e: window_types.Event) void {
        p.events.append(t.allocator, e) catch {};
    }
    fn hotkey(p: *Probe, _: void) void {
        p.hotkeys += 1;
    }
};

fn testApp(env: *std.process.Environ.Map) !*App {
    return App.createHidden(t.allocator, t.io, env, .{ .name = "myzig-window-tests", .quit_on_signal = false });
}

fn pump() void {
    var msg: w.MSG = undefined;
    while (w.PeekMessageW(&msg, null, 0, 0, 1) != 0) _ = w.DispatchMessageW(&msg);
}

fn screenParam(x: i32, y: i32) w.LPARAM {
    const ux: u16 = @bitCast(@as(i16, @truncate(x)));
    const uy: u16 = @bitCast(@as(i16, @truncate(y)));
    return @bitCast(@as(usize, ux) | @as(usize, uy) << 16);
}

fn options(p: *Probe, title_bar: window_types.TitleBar) @import("window.zig").Options {
    return .{
        .title = "Notes",
        .title_bar = title_bar,
        .on_close_request = .of(p, Probe.request),
        .on_close = .{ .ctx = p, .func = @ptrCast(&Probe.close) },
        .on_event = .of(p, Probe.event),
        .content = .{ .view = ui.View.init(p, Probe.view) },
    };
}

test "closing asks first, and a refusal keeps the window" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const app = try testApp(&env);
    defer app.destroy();
    var p: Probe = .{};
    defer p.events.deinit(t.allocator);
    const win = try app.newWindow(options(&p, .default));
    const h = win.hwnd.?;
    try t.expect(w.IsWindowVisible(h) == 0);
    win.requestClose();
    try t.expectEqual(@as(usize, 1), p.asked);
    try t.expectEqual(@as(usize, 1), app.windows.items.len);
    // The close button's Close: WM_SYSCOMMAND, then WM_CLOSE.
    _ = w.SendMessageW(h, caption.WM_SYSCOMMAND, caption.SC_CLOSE, 0);
    try t.expectEqual(@as(usize, 2), p.asked);
    try t.expectEqual(@as(usize, 0), p.closed);
    p.allow = true;
    win.requestClose();
    try t.expectEqual(@as(usize, 1), p.closed);
    try t.expectEqual(@as(usize, 0), app.windows.items.len);
}

test "focus, sizes and states reach the app once each" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const app = try testApp(&env);
    defer app.destroy();
    var p: Probe = .{ .allow = true };
    defer p.events.deinit(t.allocator);
    const win = try app.newWindow(options(&p, .default));
    const h = win.hwnd.?;
    // Whatever the system did as it was made, from inactive.
    _ = w.SendMessageW(h, frame.WM_ACTIVATE, 0, 0);
    p.events.clearRetainingCapacity();
    const s = win.dpiScale();
    const size = screenParam(@intFromFloat(300 * s), @intFromFloat(200 * s));
    _ = w.SendMessageW(h, frame.WM_ACTIVATE, 1, 0);
    _ = w.SendMessageW(h, frame.WM_ACTIVATE, 1, 0);
    _ = w.SendMessageW(h, w.WM_SIZE, 1, 0); // minimized
    _ = w.SendMessageW(h, w.WM_SIZE, 0, size);
    _ = w.SendMessageW(h, frame.WM_ACTIVATE, 0, 0);
    const want = [_]std.meta.Tag(window_types.Event){ .focus, .minimized, .restored, .blur };
    try t.expectEqual(want.len, p.events.items.len);
    for (want, p.events.items) |k, e| try t.expectEqual(k, std.meta.activeTag(e));
    // A move to where it is tells nothing new.
    _ = w.SendMessageW(h, frame.WM_MOVE, 0, 0);
    const n = p.events.items.len;
    _ = w.SendMessageW(h, frame.WM_MOVE, 0, 0);
    try t.expectEqual(n, p.events.items.len);
    win.close();
}

test "an edited document's title is marked" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const app = try testApp(&env);
    defer app.destroy();
    var p: Probe = .{ .allow = true };
    defer p.events.deinit(t.allocator);
    const win = try app.newWindow(options(&p, .default));
    win.setDocumentEdited(true);
    var buf: [64]u16 = undefined;
    const n = GetWindowTextW(win.hwnd.?, &buf, buf.len);
    try t.expect(std.mem.eql(u16, std.unicode.utf8ToUtf16LeStringLiteral("*Notes"), buf[0..@intCast(n)]));
    win.setDocumentEdited(false);
    win.setTitle("Plans");
    const m = GetWindowTextW(win.hwnd.?, &buf, buf.len);
    try t.expect(std.mem.eql(u16, std.unicode.utf8ToUtf16LeStringLiteral("Plans"), buf[0..@intCast(m)]));
    win.close();
}
extern "user32" fn GetWindowTextW(hwnd: w.HWND, buf: [*]u16, n: i32) callconv(.winapi) i32;

test "a hidden title bar: caption buttons, their hit tests and clicks, the empty top moving the window" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const app = try testApp(&env);
    defer app.destroy();
    var p: Probe = .{};
    defer p.events.deinit(t.allocator);
    const win = try app.newWindow(options(&p, .hidden));
    const h = win.hwnd.?;
    try t.expectEqual(@as(f64, 32), win.titleBar().height);
    try t.expectEqual(@as(f64, 46 * 3), win.titleBar().right);
    try t.expect(GetMenu(h) == null);
    const c = win.caption orelse return error.NoCaption;
    var r: w.RECT = .{};
    _ = w.GetWindowRect(c.hwnd, &r);
    const bw = @divTrunc(r.right - r.left, 3);
    const mid = r.top + @divTrunc(r.bottom - r.top, 2);
    // Over the middle button: maximize, for snap layouts.
    const over_max = screenParam(r.left + bw + @divTrunc(bw, 2), mid);
    try t.expectEqual(@as(w.LRESULT, caption.HTMAXBUTTON), w.SendMessageW(c.hwnd, caption.WM_NCHITTEST, 0, over_max));
    try t.expectEqual(@as(w.LRESULT, caption.HTCLOSE), w.SendMessageW(c.hwnd, caption.WM_NCHITTEST, 0, screenParam(r.left + 2 * bw + 3, mid)));
    // Pressing and releasing close asks the app, which refuses.
    const over_close = screenParam(r.left + 2 * bw + @divTrunc(bw, 2), mid);
    _ = w.SendMessageW(c.hwnd, caption.WM_NCLBUTTONDOWN, caption.HTCLOSE, over_close);
    _ = w.SendMessageW(c.hwnd, caption.WM_NCLBUTTONUP, caption.HTCLOSE, over_close);
    try t.expectEqual(@as(usize, caption.SC_CLOSE), c.last_command);
    try t.expectEqual(@as(usize, 1), p.asked);
    try t.expectEqual(@as(usize, 1), app.windows.items.len);
    // A release elsewhere than the press clicks nothing.
    c.last_command = 0;
    _ = w.SendMessageW(c.hwnd, caption.WM_NCLBUTTONDOWN, caption.HTMAXBUTTON, over_max);
    _ = w.SendMessageW(c.hwnd, caption.WM_NCLBUTTONUP, caption.HTCLOSE, over_close);
    try t.expectEqual(@as(usize, 0), c.last_command);
    // The empty top of native UI moves the window; below it is content.
    var origin: w.POINT = .{};
    _ = gdi.ClientToScreen(h, &origin);
    const s = win.dpiScale();
    const top = screenParam(origin.x + @as(i32, @intFromFloat(100 * s)), origin.y + @as(i32, @intFromFloat(20 * s)));
    try t.expectEqual(@as(w.LRESULT, caption.HTCAPTION), w.SendMessageW(h, caption.WM_NCHITTEST, 0, top));
    const below = screenParam(origin.x + @as(i32, @intFromFloat(100 * s)), origin.y + @as(i32, @intFromFloat(100 * s)));
    try t.expectEqual(@as(w.LRESULT, caption.HTCLIENT), w.SendMessageW(h, caption.WM_NCHITTEST, 0, below));
    // A maximize button native UI draws itself gets the snap layouts.
    win.setSnapButton(.{ .x = 90, .y = 0, .width = 40, .height = 32 });
    try t.expectEqual(@as(w.LRESULT, caption.HTMAXBUTTON), w.SendMessageW(h, caption.WM_NCHITTEST, 0, top));
    p.allow = true;
    win.close();
}
extern "user32" fn GetMenu(hwnd: w.HWND) callconv(.winapi) ?*anyopaque;

test "a flyout: a popup owned by the app's window, kept when a close is refused, hidden when dismissed so" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const app = try testApp(&env);
    defer app.destroy();
    var p: Probe = .{ .allow = true };
    defer p.events.deinit(t.allocator);
    const f = try app.newFlyout(.{ .anchor = .{ .x = 40, .y = 40 }, .width = 120, .height = 80, .dismiss = .hide, .content = .{ .view = ui.View.init(&p, Probe.view) } });
    const h = f.hwnd.?;
    try t.expect(f.isFlyout());
    try t.expect(frame.style(h) & gdi.WS_POPUP != 0);
    const ex: u32 = @truncate(@as(usize, @bitCast(w.GetWindowLongPtrW(h, gdi.GWL_EXSTYLE))));
    try t.expect(ex & gdi.WS_EX_TOOLWINDOW != 0);
    try t.expectEqual(app.hidden.?, GetWindow(h, 4).?); // GW_OWNER
    var r: w.RECT = .{};
    _ = w.GetWindowRect(h, &r);
    const s = f.dpiScale();
    try t.expectEqual(@as(i32, @intFromFloat(@round(120 * s))), r.right - r.left);
    // Dismissed so, a close hides it: the app shows it again.
    f.requestClose();
    try t.expectEqual(@as(usize, 1), app.windows.items.len);
    try t.expect(!f.isVisible());
    f.close();
}
extern "user32" fn GetWindow(hwnd: w.HWND, cmd: u32) callconv(.winapi) ?w.HWND;

test "a global shortcut's press reaches its handler" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const app = try testApp(&env);
    defer app.destroy();
    var p: Probe = .{};
    const id = try app.registerHotkey("Ctrl+Alt+Shift+F20", .of(&p, Probe.hotkey));
    defer app.unregisterHotkey(id);
    // What Windows sends when it is pressed.
    _ = w.SendMessageW(app.hidden.?, hotkey.WM_HOTKEY, id, 0);
    _ = w.SendMessageW(app.hidden.?, hotkey.WM_HOTKEY, id + 100, 0);
    try t.expectEqual(@as(usize, 1), p.hotkeys);
    try t.expectError(error.UnsupportedKey, app.registerHotkey("Ctrl", .of(&p, Probe.hotkey)));
}
