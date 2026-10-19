//! What windows do beyond showing content on Windows: files dropped on
//! them, their remembered state, and Windows 11's backdrop materials.
const std = @import("std");
const w = @import("win32.zig");
const window_types = @import("../window_types.zig");

pub const WM_DROPFILES = 0x0233;

extern "shell32" fn DragAcceptFiles(hwnd: w.HWND, accept: w.BOOL) callconv(.winapi) void;
extern "shell32" fn DragQueryFileW(drop: *anyopaque, index: u32, file: ?[*]u16, size: u32) callconv(.winapi) u32;
extern "shell32" fn DragFinish(drop: *anyopaque) callconv(.winapi) void;
extern "dwmapi" fn DwmSetWindowAttribute(hwnd: w.HWND, attr: u32, value: *const anyopaque, size: u32) callconv(.winapi) i32;
extern "dwmapi" fn DwmExtendFrameIntoClientArea(hwnd: w.HWND, margins: *const [4]i32) callconv(.winapi) i32;
extern "user32" fn MonitorFromPoint(pt: w.POINT, flags: u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetWindowPlacement(hwnd: w.HWND, wp: *WINDOWPLACEMENT) callconv(.winapi) w.BOOL;

const WINDOWPLACEMENT = extern struct {
    length: u32 = @sizeOf(WINDOWPLACEMENT),
    flags: u32 = 0,
    showCmd: u32 = 0,
    ptMinPosition: w.POINT = .{},
    ptMaxPosition: w.POINT = .{},
    rcNormalPosition: w.RECT = .{},
};

/// Lets Explorer drop files on `hwnd` (WM_DROPFILES).
pub fn acceptDrops(hwnd: w.HWND) void {
    DragAcceptFiles(hwnd, 1);
}

/// The paths of a WM_DROPFILES's files, which it frees. Caller frees them
/// with `freePaths`.
pub fn droppedFiles(gpa: std.mem.Allocator, drop: *anyopaque) ![][]u8 {
    defer DragFinish(drop);
    const n = DragQueryFileW(drop, 0xFFFFFFFF, null, 0);
    var out: std.ArrayList([]u8) = .empty;
    errdefer freePaths(gpa, out.items);
    var buf: [32768]u16 = undefined;
    for (0..n) |i| {
        const len = DragQueryFileW(drop, @intCast(i), &buf, buf.len);
        if (len == 0) continue;
        try out.append(gpa, try std.unicode.utf16LeToUtf8Alloc(gpa, buf[0..len]));
    }
    return out.toOwnedSlice(gpa);
}

pub fn freePaths(gpa: std.mem.Allocator, paths: []const []u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}

/// Whether a window whose top left is at `x`, `y` (pixels) shows on a monitor.
pub fn onScreen(x: f64, y: f64) bool {
    // A title bar's height in: the part the user grabs.
    const pt: w.POINT = .{ .x = @intFromFloat(x + 40), .y = @intFromFloat(y + 10) };
    return MonitorFromPoint(pt, 0) != null; // MONITOR_DEFAULTTONULL
}

/// The window's state as `window-state.txt` keeps it: its position in
/// points, its content's size, and whether it is maximized (then the
/// frame it has when restored).
pub fn state(hwnd: w.HWND, style: u32, has_menu: bool, scale: f64) window_types.WindowState {
    var wp: WINDOWPLACEMENT = .{};
    _ = GetWindowPlacement(hwnd, &wp);
    const r = wp.rcNormalPosition;
    var border: w.RECT = .{};
    _ = w.AdjustWindowRectEx(&border, style, @intFromBool(has_menu), 0);
    const width = (r.right - r.left) - (border.right - border.left);
    const height = (r.bottom - r.top) - (border.bottom - border.top);
    return .{
        .x = @as(f64, @floatFromInt(r.left)) / scale,
        .y = @as(f64, @floatFromInt(r.top)) / scale,
        .width = @as(f64, @floatFromInt(width)) / scale,
        .height = @as(f64, @floatFromInt(height)) / scale,
        .maximized = w.IsZoomed(hwnd) != 0,
    };
}

/// Shows Windows 11's material behind the window (DWMWA_SYSTEMBACKDROP_TYPE);
/// false where the system has none (Windows 10). Content drawn opaque
/// covers it.
pub fn setMaterial(hwnd: w.HWND, material: window_types.Material) bool {
    const kind: u32 = switch (material) {
        .none => 1, // DWMSBT_NONE
        .sidebar => 2, // DWMSBT_MAINWINDOW (Mica)
        .under_window => 4, // DWMSBT_TABBEDWINDOW (Mica Alt)
        .popover => 3, // DWMSBT_TRANSIENTWINDOW (Acrylic)
    };
    if (material != .none) {
        const margins: [4]i32 = .{ -1, -1, -1, -1 };
        _ = DwmExtendFrameIntoClientArea(hwnd, &margins);
    }
    return DwmSetWindowAttribute(hwnd, 38, &kind, 4) >= 0;
}

/// Asks DWM for a dark title bar (DWMWA_USE_IMMERSIVE_DARK_MODE).
pub fn setDarkTitleBar(hwnd: w.HWND, dark: bool) void {
    const v: w.BOOL = @intFromBool(dark);
    _ = DwmSetWindowAttribute(hwnd, 20, &v, 4);
}

test "the primary monitor's origin is on screen, far away is not" {
    try std.testing.expect(onScreen(0, 0));
    try std.testing.expect(!onScreen(-100000, -100000));
    try std.testing.expectEqual(@as(usize, 44), @sizeOf(WINDOWPLACEMENT));
}
