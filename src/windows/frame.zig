//! The frame of a window without a caption on Windows (a hidden title bar,
//! a frameless window, a flyout): its non-client area taken away, the
//! hit tests that still resize it from its edges and move it by its title
//! bar, and moving it from the content (`Window.startDrag`).
const std = @import("std");
const w = @import("win32.zig");
const gdi = @import("gdi.zig");
const caption = @import("caption.zig");

pub const WM_NCCALCSIZE = 0x0083;
pub const WM_MOVE = 0x0003;
pub const WM_ACTIVATE = 0x0006;
pub const WM_MOUSEACTIVATE = 0x0021;
/// Asks the window to move with the pointer, out of the press that asked.
pub const WM_START_DRAG = w.WM_APP + 20;
/// A flyout was dismissed: another window took the keyboard.
pub const WM_DISMISS = w.WM_APP + 21;
const SC_DRAGMOVE = 0xF012;
/// How far from the left and right corners the top edge resizes the corner.
const corner = 16;

const NCCALCSIZE_PARAMS = extern struct { rgrc: [3]w.RECT, lppos: ?*anyopaque };

/// WM_NCCALCSIZE of a captionless window: no title bar. A resizable one
/// keeps its left, right and bottom borders, which Windows 10 and later
/// draw invisible outside the window, so it still resizes from them. A
/// maximized one would overflow the screen by its borders: it fits the
/// work area. A hidden title bar on Windows 11 keeps a pixel of its top,
/// which the border covers: without any, Windows 11 opens no snap layouts
/// over the maximize button of a window that is not maximized.
pub fn calcSize(hwnd: w.HWND, wp: w.WPARAM, lp: w.LPARAM, hidden: bool, popup: bool) w.LRESULT {
    const params: *NCCALCSIZE_PARAMS = @ptrFromInt(@as(usize, @bitCast(lp)));
    if (popup) return 0; // all of a flyout is client area
    if (w.IsZoomed(hwnd) != 0) {
        // The monitor of the proposed rectangle: a window coming back from
        // minimized is still parked off screen.
        if (gdi.MonitorFromRect(&params.rgrc[0], 0)) |mon| {
            var info: gdi.MONITORINFO = .{};
            if (gdi.GetMonitorInfoW(mon, &info) != 0) params.rgrc[0] = info.rcWork;
        }
        return 0;
    }
    if (style(hwnd) & w.WS_THICKFRAME != 0) {
        const top = params.rgrc[0].top;
        _ = w.DefWindowProcW(hwnd, WM_NCCALCSIZE, wp, lp);
        params.rgrc[0].top = top;
        if (hidden and gdi.windows11()) params.rgrc[0].top += 1;
    }
    return 0;
}

pub fn style(hwnd: w.HWND) u32 {
    return @truncate(@as(usize, @bitCast(w.GetWindowLongPtrW(hwnd, gdi.GWL_STYLE))));
}

/// The thickness of the band along the top edge that resizes the window,
/// in pixels: its sizing frame's, as above a caption.
pub fn resizeBorder(dpi: u32) i32 {
    const f = gdi.GetSystemMetricsForDpi(33, dpi) + gdi.GetSystemMetricsForDpi(92, dpi); // SM_CYFRAME, SM_CXPADDEDBORDER
    return if (f > 0) f else @intCast(8 * dpi / 96);
}

/// What the window asks of the hit test, in pixels of its client area.
pub const Probe = struct {
    /// The top band resizes it.
    resizes: bool,
    /// Where the app drew its maximize button (snap layouts over it).
    snap: ?w.RECT = null,
    /// Whether a press there moves the window (its title bar).
    drag: ?struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque, x: i32, y: i32) bool } = null,
};

/// WM_NCHITTEST of a captionless window: its borders as DefWindowProc
/// finds them, the top band resizing, the app's maximize button, and its
/// title bar moving it.
pub fn hitTest(hwnd: w.HWND, wp: w.WPARAM, lp: w.LPARAM, probe: Probe) w.LRESULT {
    const def = w.DefWindowProcW(hwnd, caption.WM_NCHITTEST, wp, lp);
    if (def != caption.HTCLIENT) return def;
    var pt: w.POINT = .{ .x = @as(i16, @truncate(lp)), .y = @as(i16, @truncate(lp >> 16)) };
    _ = w.ScreenToClient(hwnd, &pt);
    return classify(hwnd, pt, probe);
}

/// The hit test of a point of the client area (pixels).
pub fn classify(hwnd: w.HWND, pt: w.POINT, probe: Probe) w.LRESULT {
    const dpi = w.GetDpiForWindow(hwnd);
    if (probe.resizes and w.IsZoomed(hwnd) == 0 and pt.y >= 0 and pt.y < resizeBorder(if (dpi == 0) 96 else dpi)) {
        var r: w.RECT = .{};
        _ = w.GetClientRect(hwnd, &r);
        const c: i32 = @intCast(corner * (if (dpi == 0) 96 else dpi) / 96);
        if (pt.x < c) return caption.HTTOPLEFT;
        if (pt.x >= r.right - c) return caption.HTTOPRIGHT;
        return caption.HTTOP;
    }
    if (probe.snap) |s| if (pt.x >= s.left and pt.x < s.right and pt.y >= s.top and pt.y < s.bottom) return caption.HTMAXBUTTON;
    if (probe.drag) |d| if (d.func(d.ctx, pt.x, pt.y)) return caption.HTCAPTION;
    return caption.HTCLIENT;
}

/// Moves the window with the pointer, as its title bar would: the press
/// that asked has the mouse captured, so this runs once it is over.
pub fn startDrag(hwnd: w.HWND) void {
    _ = w.PostMessageW(hwnd, WM_START_DRAG, 0, 0);
}

/// The window's part of `WM_START_DRAG`: the system's move loop, which
/// returns once the button is up.
pub fn runDrag(hwnd: w.HWND) void {
    _ = w.ReleaseCapture();
    _ = w.SendMessageW(hwnd, caption.WM_SYSCOMMAND, SC_DRAGMOVE, 0);
}

/// A non-client mouse message's position as a client one's lParam.
pub fn clientParam(hwnd: w.HWND, lp: w.LPARAM) w.LPARAM {
    var pt: w.POINT = .{ .x = @as(i16, @truncate(lp)), .y = @as(i16, @truncate(lp >> 16)) };
    _ = w.ScreenToClient(hwnd, &pt);
    const x: u16 = @bitCast(@as(i16, @truncate(pt.x)));
    const y: u16 = @bitCast(@as(i16, @truncate(pt.y)));
    return @bitCast(@as(usize, x) | @as(usize, y) << 16);
}

test "a captionless window's hit test: its top edge, the app's maximize button, its title bar" {
    const class = std.unicode.utf8ToUtf16LeStringLiteral("MyZigFrameTest");
    const wc: w.WNDCLASSEXW = .{ .lpfnWndProc = w.DefWindowProcW, .hInstance = w.GetModuleHandleW(null), .lpszClassName = class };
    _ = w.RegisterClassExW(&wc);
    // Hidden: never shown.
    const hwnd = w.CreateWindowExW(0, class, class, w.WS_OVERLAPPEDWINDOW, 0, 0, 400, 300, null, null, w.GetModuleHandleW(null), null) orelse return error.CreateWindow;
    defer _ = w.DestroyWindow(hwnd);
    const S = struct {
        fn drag(_: *anyopaque, x: i32, y: i32) bool {
            return y < 32 and x < 200;
        }
    };
    var dummy: u8 = 0;
    const probe: Probe = .{ .resizes = true, .snap = .{ .left = 250, .top = 0, .right = 300, .bottom = 32 }, .drag = .{ .ctx = &dummy, .func = S.drag } };
    try std.testing.expectEqual(@as(w.LRESULT, caption.HTTOPLEFT), classify(hwnd, .{ .x = 2, .y = 1 }, probe));
    try std.testing.expectEqual(@as(w.LRESULT, caption.HTTOP), classify(hwnd, .{ .x = 100, .y = 1 }, probe));
    try std.testing.expectEqual(@as(w.LRESULT, caption.HTCAPTION), classify(hwnd, .{ .x = 100, .y = 20 }, probe));
    try std.testing.expectEqual(@as(w.LRESULT, caption.HTMAXBUTTON), classify(hwnd, .{ .x = 260, .y = 20 }, probe));
    try std.testing.expectEqual(@as(w.LRESULT, caption.HTCLIENT), classify(hwnd, .{ .x = 100, .y = 100 }, probe));
    try std.testing.expectEqual(@as(w.LRESULT, caption.HTCAPTION), classify(hwnd, .{ .x = 100, .y = 1 }, .{ .resizes = false, .drag = probe.drag }));
    try std.testing.expect(w.IsWindowVisible(hwnd) == 0);
}
