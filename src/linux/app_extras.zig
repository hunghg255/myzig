//! What the app does on Linux beyond its windows and menus: flyouts,
//! global shortcuts (grabbed on X11, through the desktop portal on
//! Wayland), the network's status (GIO), its launcher entry's count, and
//! quitting on SIGINT and SIGTERM.
const std = @import("std");
const App = @import("app.zig").App;
const Window = @import("window.zig").Window;
const Tray = @import("tray.zig").Tray;
const fdwatch = @import("fdwatch.zig");
const hotkey = @import("hotkey.zig");
const hotkeys = @import("../hotkeys.zig");
const network = @import("network.zig");
const net = @import("../network.zig");
const signals = @import("../signal_unix.zig");
const launcher = @import("launcher_entry.zig");
const fly = @import("../flyout.zig");
const window_types = @import("../window_types.zig");
const ui = @import("../ui/ui.zig");
const app_types = @import("../app_types.zig");
const menu_types = @import("../menu_types.zig");
const hotkey_portal = @import("hotkey_portal.zig");
const dbus = @import("dbus.zig");
const gtk = @import("gtk.zig");

/// An entry's `native` when the portal binds it, not an X grab.
const portal_native: usize = std.math.maxInt(usize);

pub const FlyoutOptions = fly.Options(Window, Tray, window_types.Content, ui.Theme);

pub const State = struct {
    hotkeys: hotkeys.Registry = .{},
    net: net.Tracker = .{},
    watching_net: bool = false,
    signal_watch: ?fdwatch.Watch = null,
    /// The GlobalShortcuts portal (Wayland), opened at the first shortcut.
    portal: ?*hotkey_portal.Portal = null,
    portal_tried: bool = false,
};

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

pub fn registerHotkey(app: *App, keys: []const u8, handler: app_types.Handler(void)) hotkeys.Error!u32 {
    if (!app.gui) return error.Unsupported;
    const e = try app.extras.hotkeys.add(app.gpa, menu_types.parseAccelerator(keys), handler);
    const id = e.id;
    const grab = hotkey.register(e.accelerator) catch |err| {
        // Wayland grabs nothing for apps: the desktop binds it.
        if (err == error.Unsupported) if (portalOf(app)) |p| {
            const a = e.accelerator;
            p.add(id, a, keys) catch |perr| {
                _ = app.extras.hotkeys.remove(id);
                return perr;
            };
            app.extras.hotkeys.find(id).?.native = portal_native;
            return id;
        };
        _ = app.extras.hotkeys.remove(id);
        return err;
    };
    // `add` may have moved the entries: find it again.
    app.extras.hotkeys.find(id).?.native = @as(usize, grab.keycode) | @as(usize, grab.mods) << 8;
    hotkey.listen(app, pressed);
    return id;
}

fn grabOf(native: usize) hotkey.Grab {
    return .{ .keycode = @truncate(native), .mods = @truncate(native >> 8) };
}

pub fn unregisterHotkey(app: *App, id: u32) void {
    const e = app.extras.hotkeys.remove(id) orelse return;
    if (e.native == portal_native) {
        if (app.extras.portal) |p| p.remove(id);
    } else hotkey.unregister(grabOf(e.native));
}

fn portalOf(app: *App) ?*hotkey_portal.Portal {
    if (app.extras.portal) |p| return p;
    if (app.extras.portal_tried) return null;
    app.extras.portal_tried = true;
    const bus = app.sessionBus() orelse return null;
    app.extras.portal = hotkey_portal.Portal.open(app.gpa, bus, app.options.appId(), app, portalPressed, @import("dbus_portal.zig").name);
    return app.extras.portal;
}

/// A signal of the session bus: true when it was the portal's.
pub fn busSignal(app: *App, m: *dbus.Message) bool {
    const p = app.extras.portal orelse return false;
    return p.signal(m);
}

fn portalPressed(ctx: *anyopaque, id: u32, token: ?[]const u8) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    // The press's activation token lets the window it shows take the
    // focus on Wayland.
    const set = startupId();
    if (token != null and set != null) if (gtk.api.gdk_display_get_default()) |d| {
        var buf: [256]u8 = undefined;
        if (token.?.len < buf.len) {
            @memcpy(buf[0..token.?.len], token.?);
            buf[token.?.len] = 0;
            set.?(d, @ptrCast(&buf));
            defer set.?(d, null);
            return app.extras.hotkeys.fire(id);
        }
    };
    app.extras.hotkeys.fire(id);
}

const SetStartupId = *const fn (display: *anyopaque, id: ?[*:0]const u8) callconv(.c) void;
var startup_id: ?SetStartupId = null;
var startup_tried = false;

/// gdk_wayland_display_set_startup_notification_id, on Wayland only.
fn startupId() ?SetStartupId {
    if (startup_tried) return startup_id;
    startup_tried = true;
    const lib = std.c.dlopen("libgtk-3.so.0", .{ .NOW = true }) orelse return null;
    const get_type: *const fn () callconv(.c) usize = @ptrCast(@alignCast(std.c.dlsym(lib, "gdk_wayland_display_get_type") orelse return null));
    const is_a: *const fn (obj: *anyopaque, t: usize) callconv(.c) c_int = @ptrCast(@alignCast(std.c.dlsym(lib, "g_type_check_instance_is_a") orelse return null));
    const d = gtk.api.gdk_display_get_default() orelse return null;
    if (is_a(d, get_type()) == 0) return null;
    startup_id = @ptrCast(@alignCast(std.c.dlsym(lib, "gdk_wayland_display_set_startup_notification_id") orelse return null));
    return startup_id;
}

fn pressed(ctx: *anyopaque, keycode: u8, mods: u32) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    for (app.extras.hotkeys.list.items) |e| {
        const g = grabOf(e.native);
        if (g.keycode == keycode and g.mods == mods) return app.extras.hotkeys.fire(e.id);
    }
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
    for (app.extras.hotkeys.list.items) |e| if (e.native != portal_native) hotkey.unregister(grabOf(e.native));
    app.extras.hotkeys.deinit(app.gpa);
    if (app.extras.portal) |p| p.close();
    app.extras.portal = null;
}

fn onSignal(ctx: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    _ = signals.take();
    app.quit();
}

fn onNetwork(ctx: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    const s = app.extras.net.changed(network.status()) orelse return;
    if (app.options.on_network) |h| h.call(s);
}

pub fn setBadge(app: *App, text: []const u8) bool {
    return launcher.setBadge(app, text);
}
