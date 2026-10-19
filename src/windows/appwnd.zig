//! The app's own hidden window on Windows, never shown: it receives what
//! is the app's rather than a window's (tray icons' clicks, later
//! instances' command lines, settings and theme changes, Explorer's
//! restarts) and passes it to its `Hooks`.
const std = @import("std");
const w = @import("win32.zig");

pub const WM_TRAY = w.WM_APP + 10;
pub const WM_COPYDATA = 0x004A;
pub const WM_SETTINGCHANGE = 0x001A;
pub const WM_COMMAND = 0x0111;
pub const WM_INITMENUPOPUP = 0x0117;
pub const WM_ENDSESSION = 0x0016;

pub const COPYDATASTRUCT = extern struct { dwData: usize, cbData: u32, lpData: ?*const anyopaque };

pub extern "user32" fn FindWindowW(class: ?[*:0]const u16, title: ?[*:0]const u16) callconv(.winapi) ?w.HWND;
pub extern "user32" fn SendMessageTimeoutW(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM, flags: u32, ms: u32, result: ?*usize) callconv(.winapi) w.LRESULT;
extern "user32" fn RegisterWindowMessageW(name: [*:0]const u16) callconv(.winapi) u32;

/// Where the window's messages go; each hook is optional.
pub const Hooks = struct {
    ctx: *anyopaque,
    /// A tray icon's callback message: its id, and the mouse or balloon event.
    tray: ?*const fn (ctx: *anyopaque, id: u32, event: u32) void = null,
    /// WM_COPYDATA: what another process sent (a later instance).
    copy_data: ?*const fn (ctx: *anyopaque, kind: usize, bytes: []const u8) void = null,
    /// WM_SETTINGCHANGE with the setting's name ("ImmersiveColorSet": the theme).
    setting: ?*const fn (ctx: *anyopaque, name: []const u16) void = null,
    /// Explorer started again: tray icons must be added again.
    taskbar_created: ?*const fn (ctx: *anyopaque) void = null,
    /// Any other message (global shortcuts, network changes, signals);
    /// null leaves it to DefWindowProc.
    other: ?*const fn (ctx: *anyopaque, msg: u32, wp: w.WPARAM, lp: w.LPARAM) ?w.LRESULT = null,
};

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("MyZigApp");
var registered = false;
var taskbar_created_msg: u32 = 0;

/// Creates the hidden window titled `title` (others find it by its title).
pub fn create(title: []const u8, hooks: *const Hooks) !w.HWND {
    const inst = w.GetModuleHandleW(null);
    if (!registered) {
        const wc: w.WNDCLASSEXW = .{ .lpfnWndProc = wndProc, .hInstance = inst, .lpszClassName = class_name };
        if (w.RegisterClassExW(&wc) == 0) return error.RegisterClass;
        registered = true;
        taskbar_created_msg = RegisterWindowMessageW(std.unicode.utf8ToUtf16LeStringLiteral("TaskbarCreated"));
    }
    var buf: [128]u16 = undefined;
    // A top-level window (not message-only) gets broadcasts: settings, TaskbarCreated.
    const hwnd = w.CreateWindowExW(0, class_name, w.wide(&buf, title), 0x80000000, 0, 0, 0, 0, null, null, inst, null) orelse return error.CreateWindow;
    _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, @bitCast(@intFromPtr(hooks)));
    return hwnd;
}

pub fn destroy(hwnd: w.HWND) void {
    _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, 0);
    _ = w.DestroyWindow(hwnd);
}

/// The hidden window titled `title` of another instance (class "MyZigApp").
pub fn find(title: []const u8) ?w.HWND {
    var buf: [128]u16 = undefined;
    return FindWindowW(class_name, w.wide(&buf, title));
}

fn wndProc(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    const p = w.GetWindowLongPtrW(hwnd, w.GWLP_USERDATA);
    if (p == 0) return w.DefWindowProcW(hwnd, msg, wp, lp);
    const hooks: *const Hooks = @ptrFromInt(@as(usize, @bitCast(p)));
    switch (msg) {
        WM_TRAY => if (hooks.tray) |f| {
            // NOTIFYICON_VERSION 0: wParam is the icon's id, lParam the event.
            f(hooks.ctx, @truncate(wp), @truncate(@as(usize, @bitCast(lp))));
            return 0;
        },
        WM_COPYDATA => if (hooks.copy_data) |f| {
            const cds: *const COPYDATASTRUCT = @ptrFromInt(@as(usize, @bitCast(lp)));
            const bytes: []const u8 = if (cds.lpData) |d| @as([*]const u8, @ptrCast(d))[0..cds.cbData] else "";
            f(hooks.ctx, cds.dwData, bytes);
            return 1;
        },
        WM_SETTINGCHANGE => if (hooks.setting) |f| {
            if (lp != 0) {
                const name: [*:0]const u16 = @ptrFromInt(@as(usize, @bitCast(lp)));
                f(hooks.ctx, std.mem.span(name));
            }
        },
        else => if (msg == taskbar_created_msg and taskbar_created_msg != 0) {
            if (hooks.taskbar_created) |f| f(hooks.ctx);
        } else if (hooks.other) |f| if (f(hooks.ctx, msg, wp, lp)) |r| return r,
    }
    return w.DefWindowProcW(hwnd, msg, wp, lp);
}

test "a hidden window passes what other processes send to its hooks" {
    const S = struct {
        got: [64]u8 = undefined,
        len: usize = 0,
        kind: usize = 0,
        fn copy(ctx: *anyopaque, kind: usize, bytes: []const u8) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.kind = kind;
            @memcpy(s.got[0..bytes.len], bytes);
            s.len = bytes.len;
        }
    };
    var s: S = .{};
    const hooks: Hooks = .{ .ctx = &s, .copy_data = S.copy };
    const hwnd = try create("myzig-test-appwnd", &hooks);
    defer destroy(hwnd);
    const found = find("myzig-test-appwnd") orelse return error.NotFound;
    try std.testing.expectEqual(hwnd, found);
    const data = "hello";
    var cds: COPYDATASTRUCT = .{ .dwData = 7, .cbData = data.len, .lpData = data.ptr };
    _ = SendMessageTimeoutW(found, WM_COPYDATA, 0, @bitCast(@intFromPtr(&cds)), 0x0002, 2000, null);
    try std.testing.expectEqualStrings("hello", s.got[0..s.len]);
    try std.testing.expectEqual(@as(usize, 7), s.kind);
    try std.testing.expect(w.IsWindowVisible(hwnd) == 0);
}
