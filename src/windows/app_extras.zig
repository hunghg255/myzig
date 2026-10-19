//! What the app does on Windows beyond its windows and menus: flyouts,
//! global shortcuts, the network's status, toasts' activations and
//! quitting on Ctrl+C, all through the app's hidden window; the badge on
//! the taskbar buttons.
const std = @import("std");
const w = @import("win32.zig");
const App = @import("app.zig").App;
const Window = @import("window.zig").Window;
const Tray = @import("tray.zig").Tray;
const hotkey = @import("hotkey.zig");
const hotkeys = @import("../hotkeys.zig");
const network = @import("network.zig");
const net = @import("../network.zig");
const signal = @import("signal.zig");
const fly = @import("../flyout.zig");
const window_types = @import("../window_types.zig");
const ui = @import("../ui/ui.zig");
const app_types = @import("../app_types.zig");
const menu_types = @import("../menu_types.zig");
const notify = @import("notify.zig");
const badge = @import("badge.zig");
const taskbar = @import("taskbar.zig");

pub const FlyoutOptions = fly.Options(Window, Tray, window_types.Content, ui.Theme);

/// What the app keeps for them.
pub const State = struct {
    hotkeys: hotkeys.Registry = .{},
    net_watch: ?network.Watch = null,
    net: net.Tracker = .{},
    signals: bool = false,
    /// Toasts (`notify.zig`).
    toasts: notify.State = .{},
    /// The badge's icon, over every window's taskbar button.
    badge: ?*anyopaque = null,
};

/// A flyout: a borderless window next to `opts.anchor` (or its tray icon).
pub fn newFlyout(app: *App, opts: FlyoutOptions) !*Window {
    return app.newWindow(.{
        .width = opts.width,
        .height = opts.height,
        .resizable = false,
        .visible = !opts.hidden,
        .skip_taskbar = true,
        .theme = opts.theme,
        .material = opts.material,
        .content = opts.content,
        .flyout = fly.State.of(opts),
    });
}

pub fn registerHotkey(app: *App, accelerator: []const u8, handler: app_types.Handler(void)) hotkeys.Error!u32 {
    const hwnd = app.appWindow() orelse return error.Unsupported;
    const e = try app.extras.hotkeys.add(app.gpa, menu_types.parseAccelerator(accelerator), handler);
    const id = e.id;
    hotkey.register(hwnd, id, e.accelerator) catch |err| {
        _ = app.extras.hotkeys.remove(id);
        return err;
    };
    return id;
}

pub fn unregisterHotkey(app: *App, id: u32) void {
    _ = app.extras.hotkeys.remove(id) orelse return;
    if (app.hidden) |h| hotkey.unregister(h, id);
}

/// Starts what `run` needs: signals, network changes.
pub fn start(app: *App) void {
    const hwnd = app.appWindow() orelse return;
    // Clicks on toasts, from COM, before the first event.
    notify.serve(app, app.launch_by_toast);
    if (app.options.quit_on_signal) {
        signal.install(hwnd);
        app.extras.signals = true;
    }
    if (app.options.on_network != null and app.extras.net_watch == null) {
        _ = app.extras.net.changed(network.status());
        app.extras.net_watch = network.Watch.start(hwnd);
    }
}

pub fn stop(app: *App) void {
    if (app.extras.net_watch) |*wt| wt.stop();
    app.extras.net_watch = null;
    if (app.extras.signals) signal.uninstall();
    app.extras.signals = false;
    if (app.hidden) |h| for (app.extras.hotkeys.list.items) |e| hotkey.unregister(h, e.id);
    app.extras.hotkeys.deinit(app.gpa);
    notify.stop(app);
    if (app.extras.badge) |i| badge.destroy(@ptrCast(i));
    app.extras.badge = null;
    // What the app copied lazily is rendered before its window goes.
    @import("clipboard_lazy.zig").shutdown();
}

/// Shows `text` (a count) as a red badge over the taskbar buttons of
/// the app's windows; empty removes it. False without a taskbar.
pub fn setBadge(app: *App, text: []const u8) bool {
    const icon: ?*anyopaque = if (text.len == 0) null else @ptrCast(badge.icon(app.gpa, badge.iconSize(), text) catch return false);
    var ok = true;
    for (app.windows.items) |win| if (win.hwnd) |h| {
        if (!taskbar.setOverlay(h, icon, text)) ok = false;
    };
    if (app.extras.badge) |old| badge.destroy(@ptrCast(old));
    app.extras.badge = icon;
    return ok;
}

extern "user32" fn AllowSetForegroundWindow(pid: u32) callconv(.winapi) w.BOOL;

/// How many times the app passed the foreground on (for tests).
pub var foreground_allowed: usize = 0;

/// Passes the app's right to the foreground on to the next process to
/// ask (ASFW_ANY): only the process in front has it, so the app passes
/// it before its windows close (`App.relaunch`).
pub fn allowForeground() void {
    foreground_allowed += 1;
    _ = AllowSetForegroundWindow(std.math.maxInt(u32));
}

extern "user32" fn GetTopWindow(hwnd: ?w.HWND) callconv(.winapi) ?w.HWND;
extern "user32" fn GetWindow(hwnd: w.HWND, cmd: u32) callconv(.winapi) ?w.HWND;

/// Brings the app forward as macOS activates an app, its windows in their
/// order: a window of the app already in front stays there, else the one
/// the user had last, the highest of them in the z-order, comes forward.
/// Flyouts that never take the keyboard bring nothing forward.
pub fn focus(app: *App) void {
    if (frontWindow(app)) |win| win.focus();
}

/// The window `focus` brings forward, or null (one is in front already,
/// or none shows).
pub fn frontWindow(app: *App) ?*Window {
    const fg = w.GetForegroundWindow();
    if (fg) |f| for (app.windows.items) |win| if (win.hwnd) |h| if (h == f) return null;
    var next = GetTopWindow(null);
    while (next) |cur| : (next = GetWindow(cur, 2)) { // GW_HWNDNEXT
        for (app.windows.items) |win| if (win.hwnd) |h| if (h == cur and mayFront(win)) return win;
    }
    return null;
}

fn mayFront(win: *Window) bool {
    if (!win.isVisible()) return false;
    if (win.flyout) |f| if (!f.focusable) return false;
    return true;
}

/// The hidden window's other messages.
pub fn message(app: *App, msg: u32, wp: w.WPARAM, lp: w.LPARAM) ?w.LRESULT {
    switch (msg) {
        hotkey.WM_HOTKEY => app.extras.hotkeys.fire(@truncate(wp)),
        network.WM_NETWORK => if (app.extras.net.changed(network.status())) |s| {
            if (app.options.on_network) |h| h.call(s);
        },
        signal.WM_QUIT_SIGNAL => app.quit(),
        notify.WM_TOAST => notify.activated(app, lp),
        else => return null,
    }
    return 0;
}

test "a flyout's options become a window's" {
    var dummy: u8 = 0;
    const o: FlyoutOptions = .{ .anchor = .{ .x = 4, .y = 5 }, .placement = .top_end, .content = .{ .view = .{ .ptr = &dummy, .build = undefined } } };
    const s = fly.State.of(o);
    try std.testing.expectEqual(fly.Placement.top_end, s.placement);
    try std.testing.expectEqual(@as(f64, 5), s.anchor.y);
    try std.testing.expect(s.focusable);
}
