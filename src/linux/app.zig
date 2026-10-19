//! The application on Linux: GTK's main loop, windows, menus' accelerators,
//! tray icons, notifications and the desktop's appearance over the session
//! bus, a single instance, and timers. Headless runs (`--myzig-snapshot`,
//! `--myzig-generate`) need no display and never start GTK.
const std = @import("std");
const gtk = @import("gtk.zig");
const dev = @import("../dev.zig");
const window_mod = @import("window.zig");
const menu_mod = @import("../menu_accel.zig");
const tray_mod = @import("tray.zig");
const fdwatch = @import("fdwatch.zig");
const services = @import("services.zig");
const Bus = @import("dbus_conn.zig").Bus;
const dbus = @import("dbus.zig");
const instance = @import("../instance_unix.zig");
const ui = @import("../ui/ui.zig");
const app_types = @import("../app_types.zig");
const app_common = @import("../app_common.zig");
const launch = @import("../launch.zig");
const window_types = @import("../window_types.zig");
const Bindings = @import("../bindings.zig").Bindings;
const Window = window_mod.Window;
const app_extras = @import("app_extras.zig");
const relaunch_mod = @import("../relaunch.zig");

pub const Options = app_types.Options;

/// A notification shown: the app's id and the server's.
const Shown = struct { id: []u8, server: u32 };

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    bindings: Bindings = .{},
    windows: std.ArrayList(*Window) = .empty,
    main_menu: ?*menu_mod.Menu = null,
    trays: std.ArrayList(*tray_mod.Tray) = .empty,
    flags: dev.Flags = .{},
    launch: app_common.Launch = .{},
    opened_at_login: bool = false,
    /// The session bus, opened when first needed, and its watch.
    bus: ?*Bus = null,
    bus_watch: ?fdwatch.Watch = null,
    bus_failed: bool = false,
    shown: std.ArrayList(Shown) = .empty,
    lock: ?instance.Listener = null,
    lock_watch: ?fdwatch.Watch = null,
    /// GTK runs: windows show on a display.
    gui: bool = false,
    running: bool = false,
    stopping: bool = false,
    debug: bool = false,
    /// Global shortcuts, the network's watch, signals (`app_extras.zig`).
    extras: app_extras.State = .{},
    /// Set by `relaunch`: starts the app again once `destroy` freed it.
    restart: ?relaunch_mod.Restart = null,

    pub const FlyoutOptions = app_extras.FlyoutOptions;

    /// A flyout: a window without decorations or a taskbar entry, next to
    /// a rectangle of its parent or the screen (a tray icon's goes in the
    /// middle of the work area: GTK tells nobody where icons are).
    pub fn newFlyout(self: *App, opts: FlyoutOptions) !*Window {
        return app_extras.newFlyout(self, opts);
    }

    /// Registers a global shortcut ("Alt+Shift+Space"): grabbed on the X
    /// server; on Wayland bound by the desktop through its GlobalShortcuts
    /// portal (which may ask the user, and remembers the keys they pick);
    /// `error.Unsupported` without either.
    pub fn registerHotkey(self: *App, keys: []const u8, handler: app_types.Handler(void)) !u32 {
        return app_extras.registerHotkey(self, keys, handler);
    }

    pub fn unregisterHotkey(self: *App, id: u32) void {
        app_extras.unregisterHotkey(self, id);
    }

    /// Whether the computer is online, and its connection metered.
    pub fn networkStatus(_: *App) app_types.NetworkStatus {
        return @import("network.zig").status();
    }

    /// A count on the app's launcher entry (docks with the Unity API);
    /// empty removes it.
    pub fn setBadge(self: *App, text: []const u8) bool {
        return app_extras.setBadge(self, text);
    }

    /// Shows the app light or dark whatever the desktop shows, or as the
    /// desktop again (`.system`): native UI's theme and GTK's widgets.
    pub fn setAppearance(self: *App, a: @import("../appearance.zig").Appearance) void {
        const was = @import("desktop.zig").isDark();
        @import("../appearance.zig").chosen = a;
        const dark = @import("desktop.zig").isDark();
        @import("desktop.zig").preferDark(if (a == .system) null else dark);
        for (self.windows.items) |w| w.redraw();
        if (dark != was) if (self.options.on_appearance) |h| h.call(dark);
    }

    pub fn create(init: std.process.Init, options: Options) !*App {
        const gpa = init.gpa;
        const self = try gpa.create(App);
        errdefer gpa.destroy(self);
        const flags = try dev.Flags.parse(init);
        if (flags.headless()) @import("../headless.zig").request();
        self.* = .{
            .gpa = gpa,
            .io = init.io,
            .options = options,
            .flags = flags,
            .launch = app_common.Launch.of(init),
            .opened_at_login = app_common.Launch.atLogin(init),
            .debug = init.environ_map.get("MYZIG_DEBUG") != null,
        };
        const no_display = flags.snapshot != null or flags.generate_dir != null;
        if (!no_display) {
            if (!gtk.load()) return error.GtkMissing;
            if (gtk.api.gtk_init_check(null, null) == 0) return error.NoDisplay;
            self.gui = true;
        }
        return self;
    }

    /// An app whose windows are made but never shown, as `--myzig-hidden`
    /// makes them, without a command line: for tests of windows' behavior.
    pub fn createHidden(gpa: std.mem.Allocator, io: std.Io, options: Options) !*App {
        if (!gtk.load()) return error.GtkMissing;
        if (gtk.api.gtk_init_check(null, null) == 0) return error.NoDisplay;
        const self = try gpa.create(App);
        self.* = .{ .gpa = gpa, .io = io, .options = options, .flags = .{ .hidden = true }, .gui = true };
        return self;
    }

    /// Whether the app runs headless (`--myzig-snapshot`, `--myzig-eval`,
    /// `--myzig-generate`): no window shows, and its directories
    /// (`myzig.path`'s data and cache, `myzig.appPath`) are a temporary
    /// one's, removed when it is destroyed, so the user's state is untouched.
    pub fn headless(self: *const App) bool {
        return self.flags.headless();
    }

    pub fn destroy(self: *App) void {
        const io = self.io;
        defer @import("../headless.zig").end(io);
        while (self.windows.items.len > 0) self.windows.items[self.windows.items.len - 1].close();
        self.windows.deinit(self.gpa);
        for (self.trays.items) |t| t.destroy();
        self.trays.deinit(self.gpa);
        if (self.main_menu) |m| m.destroy();
        app_extras.stop(self);
        for (self.shown.items) |s| self.gpa.free(s.id);
        self.shown.deinit(self.gpa);
        if (self.bus_watch) |wt| wt.cancel();
        if (self.bus) |b| b.close();
        if (self.lock_watch) |wt| wt.cancel();
        if (self.lock) |*l| l.release();
        if (window_types.free_states) |f| f();
        self.bindings.deinit(self.gpa);
        const restart, const gpa, const l = .{ self.restart, self.gpa, self.launch };
        gpa.destroy(self);
        if (restart) |f| f(gpa, io, l);
    }

    /// Binds a service: pages call its methods as `Name.method(...)`
    /// through the generated client (`myzig.js`).
    pub fn bind(self: *App, service: anytype) !void {
        try self.bindings.bind(self.gpa, service);
    }

    /// Declares a typed event (`myzig.Event(...)`) for the generated client.
    pub fn registerEvent(self: *App, comptime E: type) !void {
        try self.bindings.registerEvent(self.gpa, E);
    }

    /// The generated JavaScript client, served to pages at `/myzig.js`.
    pub fn clientJs(self: *App) ![]const u8 {
        return self.bindings.clientJs(self.gpa);
    }

    pub fn clientDts(self: *App, gpa: std.mem.Allocator) ![]u8 {
        return self.bindings.clientDts(gpa);
    }

    pub fn newWindow(self: *App, options: window_mod.Options) !*Window {
        const w = try Window.create(self, options);
        errdefer w.close();
        try self.windows.append(self.gpa, w);
        return w;
    }

    pub fn removeWindow(self: *App, w: *Window) void {
        for (self.windows.items, 0..) |item, i| if (item == w) {
            _ = self.windows.orderedRemove(i);
            break;
        };
        if (self.windows.items.len == 0 and self.options.quit_on_last_window_closed and self.running) self.quit();
    }

    pub fn run(self: *App) !void {
        if (self.flags.generate_dir) |dir| return self.bindings.writeClient(self.gpa, self.io, dir);
        if (self.flags.snapshot) |path| return dev.snapshot(self, path);
        if (self.stopping or !self.gui) return;
        self.running = true;
        // The portal's appearance changes arrive on the bus.
        if (self.options.on_appearance != null) _ = self.sessionBus();
        app_extras.start(self);
        app_common.deliver(self.gpa, self.io, self.options, self.launch.args, self.launch.cwd);
        gtk.api.gtk_main();
        self.running = false;
    }

    pub fn quit(self: *App) void {
        if (self.stopping) return;
        self.stopping = true;
        if (self.running) gtk.api.gtk_main_quit();
    }

    /// Quits like `quit`, then starts the app again with the launch's
    /// arguments, in its working directory, once `destroy` freed it (its
    /// windows closed, its single instance lock released): after
    /// changing a setting that needs a restart, or installing an update.
    /// Hidden and headless runs only quit. Under `myzig dev` the build
    /// exits and `myzig dev` starts it again.
    pub fn relaunch(self: *App) void {
        if (self.stopping) return;
        if (!self.flags.hidden) self.restart = relaunch_mod.start;
        self.quit();
    }

    /// Calls `func(ctx)` on the main thread after `ms` milliseconds.
    pub fn after(ms: u64, ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void) void {
        const Timer = struct {
            ctx: ?*anyopaque,
            func: *const fn (?*anyopaque) callconv(.c) void,
            fn fire(data: ?*anyopaque) callconv(.c) c_int {
                const t: *@This() = @ptrCast(@alignCast(data));
                t.func(t.ctx);
                std.heap.c_allocator.destroy(t);
                return 0;
            }
        };
        if (!gtk.load()) return;
        const t = std.heap.c_allocator.create(Timer) catch return;
        t.* = .{ .ctx = ctx, .func = func };
        _ = gtk.api.g_timeout_add(@intCast(ms), Timer.fire, t);
    }

    pub fn setMenu(self: *App, template: []const menu_mod.MenuItem) !void {
        const m = try menu_mod.Menu.create(self.gpa, template);
        if (self.main_menu) |old| old.destroy();
        self.main_menu = m;
    }

    pub fn menuItem(self: *App, id: []const u8) ?*menu_mod.Item {
        const m = self.main_menu orelse return null;
        return m.item(id);
    }

    /// Brings the app forward: its first window that shows, unless a
    /// window of the app is in front already. Flyouts that never take
    /// the keyboard bring nothing forward.
    pub fn focus(self: *App) void {
        for (self.windows.items) |win| if (win.isFocused()) return;
        for (self.windows.items) |win| {
            if (!win.isVisible()) continue;
            if (win.flyout) |f| if (!f.focusable) continue;
            return win.focus();
        }
    }

    /// Adds a tray icon (a StatusNotifierItem, or a GtkStatusIcon); it
    /// lives until removed with `removeTray` or the app ends.
    pub fn newTray(self: *App, opts: tray_mod.Options) !*tray_mod.Tray {
        if (!self.gui) return error.Headless;
        const t = try tray_mod.Tray.create(self.gpa, self.io, self.options.appId(), opts);
        errdefer t.destroy();
        try self.trays.append(self.gpa, t);
        return t;
    }

    pub fn removeTray(self: *App, t: *tray_mod.Tray) void {
        for (self.trays.items, 0..) |item, i| if (item == t) {
            _ = self.trays.orderedRemove(i);
            t.destroy();
            return;
        };
    }

    /// Makes sure one instance of the app runs: true in the first, which
    /// gets later ones' command lines (`on_second_instance`, and their
    /// URLs and files); false in a later one, after it handed its command
    /// line over: it should exit.
    pub fn requestSingleInstanceLock(self: *App) bool {
        if (self.lock != null or !self.gui) return true;
        const message = launch.encodeMessage(self.gpa, self.launch.cwd, self.launch.args) catch return true;
        defer self.gpa.free(message);
        var name_buf: [24]u8 = undefined;
        switch (instance.request(launch.instanceName(&name_buf, self.options.appId()), message)) {
            .forwarded => return false,
            .first => |l| {
                self.lock = l;
                if (l.fd >= 0) self.lock_watch = fdwatch.readable(l.fd, self, onInstance) catch null;
                return true;
            },
        }
    }

    fn onInstance(ctx: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const l = if (self.lock) |*l| l else return;
        const msg = (l.accept(self.gpa) catch return) orelse return;
        defer self.gpa.free(msg);
        app_common.secondInstance(self.gpa, self.io, self.options, msg);
    }

    /// The session bus, connected on first use and watched for signals;
    /// null when there is none.
    pub fn sessionBus(self: *App) ?*Bus {
        if (self.bus) |b| return b;
        if (self.bus_failed or !self.gui) return null;
        const b = Bus.session(self.gpa) catch {
            self.bus_failed = true;
            return null;
        };
        b.on_signal = onSignal;
        b.signal_ctx = self;
        services.watchSignals(b);
        self.bus = b;
        self.bus_watch = fdwatch.readable(b.fd, self, onBus) catch null;
        return b;
    }

    fn onBus(ctx: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (self.bus) |b| b.dispatch();
    }

    fn onSignal(ctx: ?*anyopaque, m: *dbus.Message) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (app_extras.busSignal(self, m)) return;
        switch (services.event(m)) {
            .action => |a| for (self.shown.items) |s| if (s.server == a.id) {
                if (self.options.on_notification) |h| h.call(.{ .id = s.id, .action = if (std.mem.eql(u8, a.key, "default")) "" else a.key });
                break;
            },
            .closed => |id| for (self.shown.items, 0..) |s, i| if (s.server == id) {
                self.gpa.free(s.id);
                _ = self.shown.swapRemove(i);
                break;
            },
            .appearance => |dark| {
                // The app's own choice outlasts the system's changes.
                if (@import("../appearance.zig").chosen != .system) return;
                for (self.windows.items) |w| w.redraw();
                if (self.options.on_appearance) |h| h.call(dark);
            },
            .other => {},
        }
    }

    /// Shows a notification through the desktop's notification server; a
    /// click reaches `on_notification`. One with the id of one showing
    /// replaces it.
    pub fn notify(self: *App, n: app_types.Notification) !void {
        const b = self.sessionBus() orelse return error.NoSessionBus;
        var replaces: u32 = 0;
        for (self.shown.items) |s| if (n.id.len > 0 and std.mem.eql(u8, s.id, n.id)) {
            replaces = s.server;
        };
        var body_buf: [1024]u8 = undefined;
        const body = if (n.subtitle.len > 0) std.fmt.bufPrint(&body_buf, "{s}\n{s}", .{ n.subtitle, n.body }) catch n.body else n.body;
        const server = try services.notify(b, self.options.name, n.title, body, n.silent, replaces);
        if (replaces != 0) return;
        const id = try self.gpa.dupe(u8, n.id);
        errdefer self.gpa.free(id);
        try self.shown.append(self.gpa, .{ .id = id, .server = server });
    }

    pub fn removeNotification(self: *App, id: []const u8) void {
        const b = self.bus orelse return;
        for (self.shown.items) |s| if (std.mem.eql(u8, s.id, id)) services.closeNotification(b, s.server);
    }

    /// Runs the menu item whose accelerator `sc` is; true if one was.
    pub fn accelerator(self: *App, sc: ui.Shortcut) bool {
        const m = self.main_menu orelse return false;
        const it = m.match(sc) orelse return false;
        if (it.role) |role| {
            const target = self.keyWindow();
            switch (role) {
                .quit => self.quit(),
                .close => if (target) |t| t.close(),
                .minimize => if (target) |t| t.minimize(),
                .zoom => if (target) |t| t.zoom(),
                .toggle_full_screen => if (target) |t| t.setFullScreen(!t.isFullScreen()),
                // Text editing goes to the focused field.
                .copy, .cut, .paste, .select_all, .undo, .redo, .delete => if (it.click == null) return false,
                else => {},
            }
            if (it.click == null) return true;
        }
        menu_mod.Menu.activate(it);
        return true;
    }

    /// The window in front, else the first.
    pub fn keyWindow(self: *App) ?*Window {
        for (self.windows.items) |w| if (w.isFocused()) return w;
        return if (self.windows.items.len > 0) self.windows.items[0] else null;
    }
};
