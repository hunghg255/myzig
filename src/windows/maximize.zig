//! Windows maximizes a top-level window into the work area of its monitor
//! only when it has a maximize box (WS_MAXIMIZEBOX), and over the whole
//! monitor otherwise (Wine's WINPOS_GetMinMaxInfo spells the rule out): a
//! window that is not resizable, which has none, that the app maximizes
//! anyway (`Window.zoom`) would cover the taskbar. Its rectangle is fixed
//! as it is about to apply (WM_WINDOWPOSCHANGING), in screen coordinates,
//! and once it is maximized, where it was not zoomed yet as it moved. Full
//! screen covers the monitor on purpose.
const std = @import("std");
const w = @import("win32.zig");
const gdi = @import("gdi.zig");

extern "user32" fn MonitorFromWindow(hwnd: w.HWND, flags: u32) callconv(.winapi) ?*anyopaque;
extern "dwmapi" fn DwmGetWindowAttribute(hwnd: w.HWND, attr: u32, value: *anyopaque, size: u32) callconv(.winapi) i32;

pub const WM_WINDOWPOSCHANGING = 0x0046;

const WINDOWPOS = extern struct {
    hwnd: ?w.HWND,
    after: ?w.HWND,
    x: i32,
    y: i32,
    cx: i32,
    cy: i32,
    flags: u32,
};

fn applies(hwnd: w.HWND, full_screen: bool) bool {
    if (full_screen or w.IsZoomed(hwnd) == 0) return false;
    const style: u32 = @truncate(@as(usize, @bitCast(w.GetWindowLongPtrW(hwnd, gdi.GWL_STYLE))));
    return style & w.WS_MAXIMIZEBOX == 0;
}

/// WM_WINDOWPOSCHANGING: a maximized window without a maximize box goes
/// into the work area.
pub fn changing(hwnd: w.HWND, lp: w.LPARAM, full_screen: bool) void {
    const pos: *WINDOWPOS = @ptrFromInt(@as(usize, @bitCast(lp)));
    if (pos.flags & (gdi.SWP_NOMOVE | gdi.SWP_NOSIZE) != 0 or !applies(hwnd, full_screen)) return;
    const r: w.RECT = .{ .left = pos.x, .top = pos.y, .right = pos.x + pos.cx, .bottom = pos.y + pos.cy };
    const mon = gdi.MonitorFromRect(&r, 0) orelse return; // MONITOR_DEFAULTTONULL
    var info: gdi.MONITORINFO = .{};
    if (gdi.GetMonitorInfoW(mon, &info) == 0) return;
    const fit = workAreaMaximized(r, info.rcMonitor, info.rcWork) orelse return;
    pos.x, pos.y, pos.cx, pos.cy = .{ fit.left, fit.top, fit.right - fit.left, fit.bottom - fit.top };
}

/// After WM_SIZE's SIZE_MAXIMIZED: one `changing` did not fit. It overhangs
/// the work area by its invisible borders, the window's rectangle beyond
/// what DWM shows (DWMWA_EXTENDED_FRAME_BOUNDS).
pub fn maximized(hwnd: w.HWND, full_screen: bool) void {
    if (!applies(hwnd, full_screen)) return;
    var r: w.RECT = .{};
    _ = w.GetWindowRect(hwnd, &r);
    var shown: w.RECT = .{};
    if (DwmGetWindowAttribute(hwnd, 9, &shown, @sizeOf(w.RECT)) < 0 or shown.right <= shown.left) shown = r;
    const mon = MonitorFromWindow(hwnd, 2) orelse return; // MONITOR_DEFAULTTONEAREST
    var info: gdi.MONITORINFO = .{};
    if (gdi.GetMonitorInfoW(mon, &info) == 0 or std.meta.eql(info.rcWork, info.rcMonitor)) return;
    const work = info.rcWork;
    const fit: w.RECT = .{
        .left = work.left - (shown.left - r.left),
        .top = work.top - (shown.top - r.top),
        .right = work.right + (r.right - shown.right),
        .bottom = work.bottom + (r.bottom - shown.bottom),
    };
    if (!std.meta.eql(fit, r)) _ = w.SetWindowPos(hwnd, null, fit.left, fit.top, fit.right - fit.left, fit.bottom - fit.top, gdi.SWP_NOZORDER | gdi.SWP_NOACTIVATE);
}

/// The rectangle of a window maximized in the work area, for `r`, one
/// maximized over the whole monitor: it overhangs the work area as `r`
/// overhangs the monitor. Null when `r` does not cover the monitor, or the
/// work area is the whole monitor (no taskbar, or one that hides).
pub fn workAreaMaximized(r: w.RECT, monitor: w.RECT, work: w.RECT) ?w.RECT {
    if (std.meta.eql(work, monitor) or r.left > monitor.left or r.top > monitor.top or r.right < monitor.right or r.bottom < monitor.bottom) return null;
    return .{
        .left = work.left - (monitor.left - r.left),
        .top = work.top - (monitor.top - r.top),
        .right = work.right + (r.right - monitor.right),
        .bottom = work.bottom + (r.bottom - monitor.bottom),
    };
}

test "a window maximized over the monitor fits its work area, overhanging it alike" {
    const mon: w.RECT = .{ .right = 1920, .bottom = 1080 };
    const work: w.RECT = .{ .right = 1920, .bottom = 1032 };
    const fit = workAreaMaximized(.{ .left = -8, .top = -8, .right = 1928, .bottom = 1088 }, mon, work).?;
    try std.testing.expectEqual(w.RECT{ .left = -8, .top = -8, .right = 1928, .bottom = 1040 }, fit);
    try std.testing.expect(workAreaMaximized(.{ .right = 800, .bottom = 600 }, mon, work) == null);
    try std.testing.expect(workAreaMaximized(mon, mon, mon) == null);
    try std.testing.expectEqual(@as(usize, if (@sizeOf(usize) == 8) 40 else 28), @sizeOf(WINDOWPOS));
}
