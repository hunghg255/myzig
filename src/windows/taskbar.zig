//! A window's taskbar button on Windows: the progress of a task across
//! it, an overlay icon in its corner (the app's badge, `badge.zig`), and
//! flashing it for attention (ITaskbarList3, FlashWindowEx).
const std = @import("std");
const w = @import("win32.zig");
const com = @import("com.zig");
const gdi = @import("gdi.zig");
const Progress = @import("../window_types.zig").Progress;

extern "ole32" fn CoCreateInstance(clsid: *const com.GUID, outer: ?*anyopaque, ctx: u32, iid: *const com.GUID, out: *?com.Object) callconv(.winapi) com.HRESULT;

const clsid_taskbar_list = com.GUID.parse("56FDF344-FD6D-11d0-958A-006097C9A090");
const iid_taskbar_list3 = com.GUID.parse("ea1afb91-9e28-4b86-90e9-9e9f8a5eefaf");

// ITaskbarList3's methods, after IUnknown's three.
const hr_init = 3;
const delete_tab = 5;
const set_progress_value = 9;
const set_progress_state = 10;
const set_overlay_icon = 18;

/// The taskbar's list, made once; null where there is none (Server Core,
/// a session without Explorer).
var list: ?com.Object = null;
var tried = false;

fn taskbar() ?com.Object {
    if (tried) return list;
    tried = true;
    var out: ?com.Object = null;
    if (com.failed(CoCreateInstance(&clsid_taskbar_list, null, 1, &iid_taskbar_list3, &out))) return null; // CLSCTX_INPROC_SERVER
    const l = out orelse return null;
    if (com.failed(com.call(l, hr_init, .{}))) {
        com.release(l);
        return null;
    }
    list = l;
    return l;
}

/// TBPF_* of a progress state.
pub fn flags(state: Progress.State) u32 {
    return switch (state) {
        .none => 0,
        .indeterminate => 1,
        .normal => 2,
        .failed => 4,
        .paused => 8,
    };
}

/// The progress value ITaskbarList3 takes: out of 10000.
pub fn completed(value: f64) u64 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 10000));
}

/// Shows `p` across the window's taskbar button; false where it cannot.
pub fn setProgress(hwnd: w.HWND, p: Progress) bool {
    const l = taskbar() orelse return false;
    if (com.failed(com.call(l, set_progress_state, .{ hwnd, flags(p.state) }))) return false;
    if (p.state == .normal or p.state == .paused or p.state == .failed)
        _ = com.call(l, set_progress_value, .{ hwnd, completed(p.value), @as(u64, 10000) });
    return true;
}

/// Shows `icon` in the corner of the window's taskbar button, described
/// to screen readers as `description`; null removes it.
pub fn setOverlay(hwnd: w.HWND, icon: ?*anyopaque, description: []const u8) bool {
    const l = taskbar() orelse return false;
    var buf: [128]u16 = undefined;
    return !com.failed(com.call(l, set_overlay_icon, .{ hwnd, icon, w.wide(&buf, description) }));
}

/// Takes the window's button off the taskbar (its window still shows).
pub fn removeButton(hwnd: w.HWND) void {
    const l = taskbar() orelse return;
    _ = com.call(l, delete_tab, .{hwnd});
}

/// Flashes the window's taskbar button until the window is focused, or
/// stops.
pub fn flash(hwnd: w.HWND, on: bool) void {
    // FLASHW_TRAY | FLASHW_TIMERNOFG, or FLASHW_STOP.
    const info: gdi.FLASHWINFO = .{ .hwnd = hwnd, .dwFlags = if (on) 0x2 | 0xC else 0 };
    _ = gdi.FlashWindowEx(&info);
}

test "taskbar progress in ITaskbarList3's terms" {
    try std.testing.expectEqual(@as(u32, 2), flags(.normal));
    try std.testing.expectEqual(@as(u32, 8), flags(.paused));
    try std.testing.expectEqual(@as(u64, 5000), completed(0.5));
    try std.testing.expectEqual(@as(u64, 10000), completed(3));
}
