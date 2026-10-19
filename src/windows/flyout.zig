//! Flyouts on Windows (after mygo): WS_POPUP windows owned by their parent
//! (or the app's hidden window, for a tray icon's), which keeps them above
//! it and out of the taskbar (WS_EX_TOOLWINDOW). One that is not
//! focusable is never activated (WS_EX_NOACTIVATE, MA_NOACTIVATE); one
//! that is is dismissed when another window is activated.
const std = @import("std");
const w = @import("win32.zig");
const gdi = @import("gdi.zig");
const com = @import("com.zig");
const fly = @import("../flyout.zig");
const Tray = @import("tray.zig").Tray;

const NOTIFYICONIDENTIFIER = extern struct {
    cbSize: u32 = @sizeOf(NOTIFYICONIDENTIFIER),
    hWnd: w.HWND,
    uID: u32,
    guidItem: com.GUID = .{ .a = 0, .b = 0, .c = 0, .d = @splat(0) },
};
extern "shell32" fn Shell_NotifyIconGetRect(id: *const NOTIFYICONIDENTIFIER, r: *w.RECT) callconv(.winapi) com.HRESULT;
extern "dwmapi" fn DwmSetWindowAttribute(hwnd: w.HWND, attr: u32, value: *const anyopaque, size: u32) callconv(.winapi) i32;

pub const MA_NOACTIVATE = 3;

/// The window styles of a flyout.
pub fn styles(f: fly.State) struct { style: u32, ex: u32 } {
    var ex: u32 = gdi.WS_EX_TOOLWINDOW;
    // Over other apps' windows, without a parent to stay above.
    if (f.tray != null or f.parent == null) ex |= gdi.WS_EX_TOPMOST;
    if (!f.focusable) ex |= gdi.WS_EX_NOACTIVATE;
    return .{ .style = gdi.WS_POPUP | gdi.WS_CLIPCHILDREN, .ex = ex };
}

/// Rounds the flyout's corners as Windows 11 rounds its menus, which
/// casts their shadow and outlines them too; Windows 10 keeps it square.
pub fn round(hwnd: w.HWND) void {
    const pref: u32 = 2; // DWMWCP_ROUND
    _ = DwmSetWindowAttribute(hwnd, 33, &pref, 4); // DWMWA_WINDOW_CORNER_PREFERENCE
}

/// Where a tray icon is on the screen (pixels), if the taskbar shows it.
pub fn trayRect(t: *Tray) ?w.RECT {
    const id: NOTIFYICONIDENTIFIER = .{ .hWnd = t.hwnd, .uID = t.id };
    var r: w.RECT = .{};
    if (com.failed(Shell_NotifyIconGetRect(&id, &r)) or r.right <= r.left) return null;
    return r;
}

fn rectOf(r: w.RECT) fly.Rect {
    return .{ .x = @floatFromInt(r.left), .y = @floatFromInt(r.top), .width = @floatFromInt(r.right - r.left), .height = @floatFromInt(r.bottom - r.top) };
}

/// Where the flyout goes, in pixels: against its tray icon, a rectangle
/// of its parent's content, or of the screen; in the work area of the
/// monitor with most of its anchor. `parent` is the parent's window.
pub fn placement(f: fly.State, parent: ?w.HWND, width: f64, height: f64) w.RECT {
    var anchor: w.RECT = undefined;
    var dpi: u32 = 96;
    var centered = false;
    if (f.tray) |p| {
        const t: *Tray = @ptrCast(@alignCast(p));
        if (trayRect(t)) |r| anchor = r else {
            // In the middle of the primary monitor's work area.
            anchor = .{};
            centered = true;
        }
        dpi = primaryDpi();
    } else if (parent) |ph| {
        dpi = w.GetDpiForWindow(ph);
        if (dpi == 0) dpi = 96;
        var origin: w.POINT = .{};
        _ = gdi.ClientToScreen(ph, &origin);
        const a = f.anchor.scaled(@as(f64, @floatFromInt(dpi)) / 96);
        anchor = .{ .left = origin.x + px(a.x), .top = origin.y + px(a.y), .right = origin.x + px(a.x + a.width), .bottom = origin.y + px(a.y + a.height) };
    } else {
        dpi = primaryDpi();
        const a = f.anchor.scaled(@as(f64, @floatFromInt(dpi)) / 96);
        anchor = .{ .left = px(a.x), .top = px(a.y), .right = px(a.x + a.width), .bottom = px(a.y + a.height) };
    }
    const s = @as(f64, @floatFromInt(dpi)) / 96;
    const search: w.RECT = .{ .left = anchor.left, .top = anchor.top, .right = @max(anchor.right, anchor.left + 1), .bottom = @max(anchor.bottom, anchor.top + 1) };
    const work = rectOf(gdi.workAreaOf(search));
    const r = if (centered) fly.centered(width * s, height * s, work) else fly.place(rectOf(anchor), width * s, height * s, f.placement, f.gap * s, work);
    return .{ .left = px(r.x), .top = px(r.y), .right = px(r.x + r.width), .bottom = px(r.y + r.height) };
}

fn px(v: f64) i32 {
    return @intFromFloat(@round(v));
}

fn primaryDpi() u32 {
    const screen = gdi.GetDC(null) orelse return 96;
    defer _ = gdi.ReleaseDC(null, screen);
    const d = GetDeviceCaps(screen, 88); // LOGPIXELSX
    return if (d > 0) @intCast(d) else 96;
}
extern "gdi32" fn GetDeviceCaps(dc: w.HDC, index: i32) callconv(.winapi) i32;

/// Whether the press that deactivated a tray icon's flyout was on its own
/// icon, whose click then toggles it (it should not close first, only to
/// open again).
pub fn onOwnIcon(f: fly.State) bool {
    const p = f.tray orelse return false;
    const r = trayRect(@ptrCast(@alignCast(p))) orelse return false;
    var pt: w.POINT = .{};
    _ = gdi.GetCursorPos(&pt);
    return pt.x >= r.left and pt.x < r.right and pt.y >= r.top and pt.y < r.bottom;
}

test "a flyout's styles, and where it goes against a point of the screen" {
    const t = std.testing;
    const s = styles(.{ .focusable = false });
    try t.expect(s.ex & gdi.WS_EX_NOACTIVATE != 0);
    try t.expect(s.ex & gdi.WS_EX_TOPMOST != 0);
    var dummy: u8 = 0;
    try t.expect(styles(.{ .parent = &dummy }).ex & gdi.WS_EX_TOPMOST == 0);
    // Below a point near the primary monitor's top left, at its DPI.
    const r = placement(.{ .anchor = .{ .x = 20, .y = 20 }, .gap = 0 }, null, 100, 50);
    const scale = @as(f64, @floatFromInt(primaryDpi())) / 96;
    try t.expectEqual(@as(i32, @intFromFloat(@round(100 * scale))), r.right - r.left);
    try t.expect(r.top >= 0);
}
