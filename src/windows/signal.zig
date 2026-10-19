//! Ctrl+C, Ctrl+Break and the console closing on Windows: the console's
//! handler runs on a thread of its own, and asks the app's hidden window
//! to quit on the main thread (`WM_QUIT_SIGNAL`).
const w = @import("win32.zig");

pub const WM_QUIT_SIGNAL = w.WM_APP + 31;

const HandlerFn = *const fn (kind: u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn SetConsoleCtrlHandler(handler: ?HandlerFn, add: w.BOOL) callconv(.winapi) w.BOOL;

var target: ?w.HWND = null;
var seen: u32 = 0;
extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;

/// Quits the app on the console's Ctrl+C, Ctrl+Break and close, through `hwnd`.
pub fn install(hwnd: w.HWND) void {
    if (target == null) _ = SetConsoleCtrlHandler(handler, 1);
    target = hwnd;
}

pub fn uninstall() void {
    if (target == null) return;
    _ = SetConsoleCtrlHandler(handler, 0);
    target = null;
}

fn handler(kind: u32) callconv(.winapi) w.BOOL {
    // CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT; logoff and shutdown
    // reach the windows as WM_ENDSESSION.
    if (kind > 2) return 0;
    const h = target orelse return 0;
    // A second one exits at once: the main thread may be what hangs.
    if (@atomicRmw(u32, &seen, .Add, 1, .monotonic) > 0) ExitProcess(130);
    _ = w.PostMessageW(h, WM_QUIT_SIGNAL, kind, 0);
    return 1;
}

test "the console's Ctrl+C becomes a message to the app's window" {
    const std = @import("std");
    const appwnd = @import("appwnd.zig");
    const S = struct {
        var got: u32 = 0;
        fn other(_: *anyopaque, msg: u32, wp: w.WPARAM, _: w.LPARAM) ?w.LRESULT {
            if (msg != WM_QUIT_SIGNAL) return null;
            got = @intCast(wp + 1);
            return 0;
        }
    };
    var dummy: u8 = 0;
    const hooks: appwnd.Hooks = .{ .ctx = &dummy, .other = S.other };
    const hwnd = try appwnd.create("myzig-test-signal", &hooks);
    defer appwnd.destroy(hwnd);
    install(hwnd);
    defer uninstall();
    // What the console's thread does on Ctrl+C, called here.
    try std.testing.expectEqual(@as(w.BOOL, 1), handler(0));
    seen = 0;
    try std.testing.expectEqual(@as(w.BOOL, 0), handler(5));
    var msg: w.MSG = undefined;
    while (w.PeekMessageW(&msg, hwnd, 0, 0, 1) != 0) _ = w.DispatchMessageW(&msg);
    try std.testing.expectEqual(@as(u32, 1), S.got);
}
