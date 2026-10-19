//! Global shortcuts on Windows: RegisterHotKey on the app's hidden window,
//! whose WM_HOTKEY carries the shortcut's id.
const std = @import("std");
const w = @import("win32.zig");
const hotkeys = @import("../hotkeys.zig");

pub const WM_HOTKEY = 0x0312;

extern "user32" fn RegisterHotKey(hwnd: ?w.HWND, id: i32, mods: u32, vk: u32) callconv(.winapi) w.BOOL;
extern "user32" fn UnregisterHotKey(hwnd: ?w.HWND, id: i32) callconv(.winapi) w.BOOL;

pub fn register(hwnd: w.HWND, id: u32, a: hotkeys.Accelerator) hotkeys.Error!void {
    const vk = hotkeys.windowsKey(a.key) orelse return error.UnsupportedKey;
    if (RegisterHotKey(hwnd, @intCast(id), hotkeys.windowsMods(a), vk) == 0) return error.Unavailable;
}

pub fn unregister(hwnd: w.HWND, id: u32) void {
    _ = UnregisterHotKey(hwnd, @intCast(id));
}

test "a global shortcut registers on a hidden window, and goes again" {
    const appwnd = @import("appwnd.zig");
    var dummy: u8 = 0;
    const hooks: appwnd.Hooks = .{ .ctx = &dummy };
    const hwnd = try appwnd.create("myzig-test-hotkey", &hooks);
    defer appwnd.destroy(hwnd);
    // A combination nobody uses; another app holding it fails the test honestly.
    const a = @import("../menu_types.zig").parseAccelerator("Ctrl+Alt+Shift+F19");
    try register(hwnd, 41, a);
    defer unregister(hwnd, 41);
    // The same combination twice is refused, as another app's would be.
    try std.testing.expectError(error.Unavailable, register(hwnd, 42, a));
    unregister(hwnd, 41);
    try register(hwnd, 43, a);
    defer unregister(hwnd, 43);
    try std.testing.expectError(error.UnsupportedKey, register(hwnd, 44, .{ .key = 0x1F600 }));
}
