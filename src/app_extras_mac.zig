//! What the app does on macOS beyond its windows and menus: flyouts,
//! global shortcuts (Carbon), the network's status (Network.framework),
//! the Dock icon's badge, and quitting on SIGINT and SIGTERM.
const std = @import("std");
const App = @import("app.zig").App;
const Window = @import("window.zig").Window;
const Tray = @import("tray.zig").Tray;
const fdwatch = @import("fdwatch.zig");
const hotkey = @import("hotkey_mac.zig");
const hotkeys = @import("hotkeys.zig");
const network = @import("network_mac.zig");
const net = @import("network.zig");
const signals = @import("signal_unix.zig");
const events = @import("window_mac_events.zig");
const fly = @import("flyout.zig");
const window_types = @import("window_types.zig");
const ui = @import("ui/ui.zig");
const app_types = @import("app_types.zig");
const menu_types = @import("menu_types.zig");

pub const FlyoutOptions = fly.Options(Window, Tray, window_types.Content, ui.Theme);

pub const State = struct {
    hotkeys: hotkeys.Registry = .{},
    net: net.Tracker = .{},
    watching_net: bool = false,
    signal_watch: ?fdwatch.Watch = null,
};

pub fn newFlyout(app: *App, opts: FlyoutOptions) !*Window {
    return app.newWindow(.{
        .width = opts.width,
        .height = opts.height,
        .resizable = false,
        .visible = !opts.hidden,
        .theme = opts.theme,
        .material = opts.material,
        .content = opts.content,
        .flyout = fly.State.of(opts),
    });
}

pub fn registerHotkey(app: *App, keys: []const u8, handler: app_types.Handler(void)) hotkeys.Error!u32 {
    const e = try app.extras.hotkeys.add(app.gpa, menu_types.parseAccelerator(keys), handler);
    const id = e.id;
    const ref = hotkey.register(id, e.accelerator) catch |err| {
        _ = app.extras.hotkeys.remove(id);
        return err;
    };
    app.extras.hotkeys.find(id).?.native = @intFromPtr(ref);
    hotkey.listen(app, pressed);
    return id;
}

pub fn unregisterHotkey(app: *App, id: u32) void {
    const e = app.extras.hotkeys.remove(id) orelse return;
    if (e.native != 0) hotkey.unregister(@ptrFromInt(e.native));
}

fn pressed(ctx: *anyopaque, id: u32) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.extras.hotkeys.fire(id);
}

pub fn start(app: *App) void {
    if (app.options.quit_on_signal and app.extras.signal_watch == null) {
        if (signals.install()) |fd| {
            app.extras.signal_watch = fdwatch.readable(fd, app, onSignal) catch null;
        } else |_| {}
    }
    if (app.options.on_network != null and !app.extras.watching_net) {
        _ = app.extras.net.changed(network.status());
        network.watch(app, onNetwork);
        app.extras.watching_net = true;
    }
}

pub fn stop(app: *App) void {
    if (app.extras.signal_watch) |wt| {
        wt.cancel();
        signals.uninstall();
    }
    app.extras.signal_watch = null;
    if (app.extras.watching_net) network.unwatch();
    for (app.extras.hotkeys.list.items) |e| if (e.native != 0) hotkey.unregister(@ptrFromInt(e.native));
    app.extras.hotkeys.deinit(app.gpa);
}

fn onSignal(ctx: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    _ = signals.take();
    app.quit();
}

fn onNetwork(ctx: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    const s = app.extras.net.changed(network.last()) orelse return;
    if (app.options.on_network) |h| h.call(s);
}

pub fn setBadge(app: *App, text: []const u8) bool {
    events.setBadge(app.nsapp, text);
    return true;
}

/// The app's appearance (`App.setAppearance`): AppKit's NSApp.appearance,
/// which every window, view and page follows.
pub fn setAppearance(app: *App, a: @import("appearance.zig").Appearance) void {
    const objc = @import("objc.zig");
    @import("appearance.zig").chosen = a;
    const pool = objc.Pool.push();
    defer pool.pop();
    const look: ?objc.Object = switch (a) {
        .system => null,
        .light => objc.msg(?objc.Object, objc.class("NSAppearance"), "appearanceNamed:", .{objc.nsString("NSAppearanceNameAqua")}),
        .dark => objc.msg(?objc.Object, objc.class("NSAppearance"), "appearanceNamed:", .{objc.nsString("NSAppearanceNameDarkAqua")}),
    };
    objc.msg(void, app.nsapp, "setAppearance:", .{look});
    for (app.windows.items) |w| w.redraw();
    const dark = @import("desktop.zig").isDark();
    if (dark == app.dark) return;
    app.dark = dark;
    if (app.options.on_appearance) |h| h.call(dark);
}
