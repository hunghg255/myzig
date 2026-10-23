//! The application on Windows: the message loop, windows, the menu bar
//! and its accelerators, tray icons and notifications, a single instance,
//! timers, and the services pages call. Headless runs
//! (`--myzig-snapshot`, `--myzig-generate`) open no window.
const std = @import("std");
const w = @import("win32.zig");
const dev = @import("../dev.zig");
const window_mod = @import("window.zig");
const menu_mod = @import("../menu_accel.zig");
const menubar = @import("menubar.zig");
const tray_mod = @import("tray.zig");
const appwnd = @import("appwnd.zig");
const instance = @import("instance.zig");
const desktop = @import("desktop.zig");
const ui = @import("../ui/ui.zig");
const com = @import("com.zig");
const app_types = @import("../app_types.zig");
const app_common = @import("../app_common.zig");
const launch = @import("../launch.zig");
const window_types = @import("../window_types.zig");
const Bindings = @import("../bindings.zig").Bindings;
const Window = window_mod.Window;
const app_extras = @import("app_extras.zig");
const relaunch_mod = @import("../relaunch.zig");

pub const Options = app_types.Options;

const Timer = struct { id: usize, ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void };
var timers: [64]?Timer = @splat(null);

fn onTimer(_: ?w.HWND, _: u32, id: usize, _: u32) callconv(.winapi) void {
    _ = w.KillTimer(null, id);
    for (&timers) |*slot| if (slot.*) |t| if (t.id == id) {
        slot.* = null;
        t.func(t.ctx);
        return;
    };
}

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    /// The process's environment (WebView2's runtime and profile).
    environ: *const std.process.Environ.Map,
    bindings: Bindings = .{},
    windows: std.ArrayList(*Window) = .empty,
    main_menu: ?*menu_mod.Menu = null,
    trays: std.ArrayList(*tray_mod.Tray) = .empty,
    next_tray: u32 = 0,
    flags: dev.Flags = .{},
    launch: app_common.Launch = .{},
    /// Started by the system at login (`setOpenAtLogin`).
    opened_at_login: bool = false,
    /// Started by COM for a click on one of its toasts (`toast_activator.zig`).
    launch_by_toast: bool = false,
    /// The app's hidden window (trays, later instances, settings), made when needed.
    hidden: ?w.HWND = null,
    hooks: appwnd.Hooks = undefined,
    lock: ?instance.Lock = null,
    instance_name: [24]u8 = undefined,
    dark: bool = false,
    gui: bool = false,
    running: bool = false,
    stopping: bool = false,
    debug: bool = false,
    /// Global shortcuts, the network's watch, signals (`app_extras.zig`).
    extras: app_extras.State = .{},
    /// Set by `relaunch`: starts the app again once `destroy` freed it.
    restart: ?relaunch_mod.Restart = null,

    pub const FlyoutOptions = app_extras.FlyoutOptions;

    /// Brings the app forward with its windows in their order: one of its
    /// windows already in front stays there, else the one the user had
    /// last comes forward (as a tray icon's click opens its settings).
    pub fn focus(self: *App) void {
        app_extras.focus(self);
    }

    /// A flyout: a borderless window without a taskbar button, next to a
    /// rectangle of its parent, a point of the screen or a tray icon,
    /// dismissed as another window takes the keyboard (`flyout.zig`).
    pub fn newFlyout(self: *App, opts: FlyoutOptions) !*Window {
        return app_extras.newFlyout(self, opts);
    }

    /// Registers a global shortcut ("Alt+Shift+Space"): `handler` runs
    /// on the main thread when it is pressed, whatever app is in front.
    /// Its id unregisters it.
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

    /// A count or short text on the app's icon: a red badge drawn as the
    /// overlay icon of its windows' taskbar buttons; empty removes it.
    pub fn setBadge(self: *App, text: []const u8) bool {
        return app_extras.setBadge(self, text);
    }

    /// Shows the app light or dark whatever the system shows, or as the
    /// system again (`.system`): native UI's theme and the title bars.
    pub fn setAppearance(self: *App, a: @import("../appearance.zig").Appearance) void {
        @import("../appearance.zig").chosen = a;
        const dark = desktop.isDark();
        for (self.windows.items) |win| if (win.hwnd) |h| @import("window_extras.zig").setDarkTitleBar(h, dark);
        appearanceChanged(self);
    }

    pub fn create(init: std.process.Init, options: Options) !*App {
        const gpa = init.gpa;
        const self = try gpa.create(App);
        errdefer gpa.destroy(self);
        const flags = try dev.Flags.parse(init);
        if (flags.headless()) @import("../headless.zig").request();
        self.* = .{ .gpa = gpa, .io = init.io, .options = options, .environ = init.environ_map, .flags = flags, .debug = init.environ_map.get("MYZIG_DEBUG") != null };
        self.launch = app_common.Launch.of(init);
        self.opened_at_login = app_common.Launch.atLogin(init);
        if (init.minimal.args.toSlice(init.arena.allocator())) |all| {
            self.launch_by_toast = @import("toast_activator.zig").launchedByToast(all);
        } else |_| {}
        self.hooks = .{ .ctx = self, .tray = onTray, .copy_data = onCopyData, .setting = onSetting, .taskbar_created = onTaskbarCreated, .other = onOther };
        self.gui = flags.snapshot == null and flags.generate_dir == null;
        // Pixels, not stretched bitmaps: myzig draws at the monitor's DPI.
        if (self.gui) _ = w.SetProcessDPIAware();
        // The app's identity to the shell, before a window shows.
        if (self.gui and options.id.len > 0) _ = @import("aumid.zig").setForProcess(options.id);
        // WebView2 wants a single-threaded apartment on its window's thread.
        if (self.gui) _ = com.CoInitializeEx(null, 0x2);
        self.dark = desktop.isDark();
        return self;
    }

    /// An app whose windows are made but never shown, as `--myzig-hidden`
    /// makes them, without a command line: for tests of windows' behavior.
    pub fn createHidden(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, options: Options) !*App {
        const self = try gpa.create(App);
        self.* = .{ .gpa = gpa, .io = io, .options = options, .environ = environ, .flags = .{ .hidden = true }, .gui = true };
        self.hooks = .{ .ctx = self, .tray = onTray, .copy_data = onCopyData, .setting = onSetting, .taskbar_created = onTaskbarCreated, .other = onOther };
        _ = com.CoInitializeEx(null, 0x2);
        return self;
    }

    /// Whether the app runs headless (`--myzig-hidden`, `--myzig-snapshot`,
    /// `--myzig-eval`, `--myzig-generate`): no window shows, and its directories
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
        if (self.hidden) |h| appwnd.destroy(h);
        if (self.lock) |l| l.release();
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
        const win = try Window.create(self, options);
        errdefer win.close();
        try self.windows.append(self.gpa, win);
        return win;
    }

    pub fn removeWindow(self: *App, win: *Window) void {
        for (self.windows.items, 0..) |item, i| if (item == win) {
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
        // Theme changes reach the hidden window.
        if (self.options.on_appearance != null) _ = self.appWindow();
        app_extras.start(self);
        app_common.deliver(self.gpa, self.io, self.options, self.launch.args, self.launch.cwd);
        var msg: w.MSG = undefined;
        while (w.GetMessageW(&msg, null, 0, 0) > 0) {
            _ = w.TranslateMessage(&msg);
            _ = w.DispatchMessageW(&msg);
        }
        self.running = false;
    }

    pub fn quit(self: *App) void {
        if (self.stopping) return;
        self.stopping = true;
        if (self.running) w.PostQuitMessage(0);
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
        // Windows only lets the process in front bring a window forward,
        // and the app gives that up as its windows close: the app it
        // starts would open behind the window in front, its taskbar
        // button flashing. It passes the right on while it has it.
        app_extras.allowForeground();
        self.quit();
    }

    pub fn after(ms: u64, ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void) void {
        const id = w.SetTimer(null, 0, @intCast(@max(1, ms)), onTimer);
        if (id == 0) return;
        for (&timers) |*slot| if (slot.* == null) {
            slot.* = .{ .id = id, .ctx = ctx, .func = func };
            return;
        };
    }

    /// The hidden window, made on first use; null when headless.
    pub fn appWindow(self: *App) ?w.HWND {
        if (self.hidden) |h| return h;
        if (!self.gui) return null;
        const title = if (self.lock != null) self.instanceName() else "myzig";
        self.hidden = appwnd.create(title, &self.hooks) catch null;
        return self.hidden;
    }

    fn instanceName(self: *App) []const u8 {
        return launch.instanceName(&self.instance_name, self.options.appId());
    }

    /// Makes sure one instance of the app runs: true in the first, which
    /// gets later ones' command lines (`on_second_instance`, and their
    /// URLs and files); false in a later one, after it handed its command
    /// line over: it should exit.
    pub fn requestSingleInstanceLock(self: *App) bool {
        if (self.lock != null or !self.gui) return true;
        const message = launch.encodeMessage(self.gpa, self.launch.cwd, self.launch.args) catch return true;
        defer self.gpa.free(message);
        switch (instance.request(self.instanceName(), message)) {
            .forwarded => return false,
            .first => |l| {
                self.lock = l;
                // Later instances find the hidden window by the lock's name.
                if (self.hidden) |h| {
                    var buf: [32]u16 = undefined;
                    _ = w.SetWindowTextW(h, w.wide(&buf, self.instanceName()));
                } else _ = self.appWindow();
                return true;
            },
        }
    }

    /// Replaces the menu bar, shown at the top of every window.
    pub fn setMenu(self: *App, template: []const menu_mod.MenuItem) !void {
        const m = try menu_mod.Menu.create(self.gpa, template);
        if (self.main_menu) |old| old.destroy();
        self.main_menu = m;
        for (self.windows.items) |win| win.setMenuBar(m);
    }

    pub fn menuItem(self: *App, id: []const u8) ?*menu_mod.Item {
        const m = self.main_menu orelse return null;
        return m.item(id);
    }

    /// A menu bar's item was chosen (WM_COMMAND) in `win`.
    pub fn menuCommand(self: *App, win: *Window, id: usize) void {
        const m = self.main_menu orelse return;
        const it = menubar.command(m, id) orelse return;
        _ = self.perform(it, win);
    }

    /// Adds an icon to the notification area; it lives until removed with
    /// `removeTray` or the app ends.
    pub fn newTray(self: *App, opts: tray_mod.Options) !*tray_mod.Tray {
        const hwnd = self.appWindow() orelse return error.Headless;
        self.next_tray += 1;
        const t = try tray_mod.Tray.create(self.gpa, hwnd, self.trayNumber(opts.id), opts);
        errdefer t.destroy();
        // Its menu's roles (`.quit`, ...) run as the menu bar's do.
        t.setPerform(.{ .ctx = self, .func = trayPerform });
        try self.trays.append(self.gpa, t);
        return t;
    }

    /// The number of a new icon: its ID's (`tray.number`), unless another
    /// icon has it, else the next counted one.
    pub fn trayNumber(self: *App, id: []const u8) u32 {
        if (id.len == 0) return self.next_tray;
        const n = tray_mod.number(id);
        for (self.trays.items) |t| if (t.id == n) return self.next_tray;
        return n;
    }

    pub fn removeTray(self: *App, t: *tray_mod.Tray) void {
        for (self.trays.items, 0..) |item, i| if (item == t) {
            _ = self.trays.orderedRemove(i);
            t.destroy();
            return;
        };
    }

    /// Shows a notification: a toast on Windows 10 and later (with its
    /// actions and replies; the Start menu shortcut it needs made for an
    /// unpackaged app), else the balloon of the first tray icon, or of an
    /// icon added for it. A click reaches `on_notification`.
    pub fn notify(self: *App, n: app_types.Notification) !void {
        if (@import("notify.zig").show(self, n)) return;
        var target: ?*tray_mod.Tray = null;
        for (self.trays.items) |t| if (!t.temporary) {
            target = t;
            break;
        };
        if (target == null) {
            for (self.trays.items) |t| if (t.temporary) {
                target = t;
            };
        }
        const t = target orelse blk: {
            const t = try self.newTray(.{});
            t.temporary = true;
            break :blk t;
        };
        var body_buf: [512]u8 = undefined;
        const body = if (n.subtitle.len > 0) std.fmt.bufPrint(&body_buf, "{s}\n{s}", .{ n.subtitle, n.body }) catch n.body else n.body;
        try t.notify(n.id, n.title, body, n.silent);
    }

    /// Hides the notification `id` if it still shows.
    pub fn removeNotification(self: *App, id: []const u8) void {
        @import("notify.zig").remove(self, id);
        for (self.trays.items) |t| if (t.notification) |cur| if (std.mem.eql(u8, cur, id)) {
            t.endNotification();
            if (t.temporary) self.removeTray(t);
            return;
        };
    }

    /// The window in front, else the first.
    pub fn keyWindow(self: *App) ?*Window {
        for (self.windows.items) |win| if (win.isFocused()) return win;
        return if (self.windows.items.len > 0) self.windows.items[0] else null;
    }

    /// Runs a menu item: its role, else its click. False when it is an
    /// editing role, which the focused view handles.
    fn perform(self: *App, it: *menu_mod.Item, win: ?*Window) bool {
        if (it.role) |role| {
            const target = win orelse self.keyWindow();
            switch (role) {
                .quit => self.quit(),
                .close => if (target) |t| t.close(),
                .minimize => if (target) |t| t.minimize(),
                .zoom => if (target) |t| t.zoom(),
                .toggle_full_screen => if (target) |t| t.setFullScreen(!t.isFullScreen()),
                .copy, .cut, .paste, .select_all, .undo, .redo, .delete => if (it.click == null) return false,
                else => {},
            }
            if (it.click == null) return true;
        }
        menu_mod.Menu.activate(it);
        return true;
    }

    pub fn accelerator(self: *App, sc: ui.Shortcut) bool {
        const m = self.main_menu orelse return false;
        const it = m.match(sc) orelse return false;
        return self.perform(it, null);
    }
};

fn appOf(ctx: *anyopaque) *App {
    return @ptrCast(@alignCast(ctx));
}

fn trayPerform(ctx: *anyopaque, it: *menu_mod.Item) void {
    _ = appOf(ctx).perform(it, null);
}

fn onTray(ctx: *anyopaque, id: u32, event: u32) void {
    const app = appOf(ctx);
    for (app.trays.items) |t| if (t.id == id) {
        const clicked = t.event(event);
        if (clicked) |n| {
            defer app.gpa.free(n);
            if (app.options.on_notification) |h| h.call(.{ .id = n });
        }
        if (t.temporary and t.notification == null and (clicked != null or event == tray_mod.NIN_BALLOONTIMEOUT)) app.removeTray(t);
        return;
    };
}

fn onCopyData(ctx: *anyopaque, kind: usize, bytes: []const u8) void {
    if (kind != instance.copy_kind) return;
    const app = appOf(ctx);
    app_common.secondInstance(app.gpa, app.io, app.options, bytes);
}

fn onSetting(ctx: *anyopaque, name: []const u16) void {
    const app = appOf(ctx);
    if (!std.mem.eql(u16, name, std.unicode.utf8ToUtf16LeStringLiteral("ImmersiveColorSet"))) return;
    // The taskbar follows the system's mode, which may change alone.
    for (app.trays.items) |t| t.appearanceChanged();
    appearanceChanged(app);
}

fn appearanceChanged(app: *App) void {
    const dark = desktop.isDark();
    if (dark == app.dark) return;
    app.dark = dark;
    for (app.windows.items) |win| win.redraw();
    if (app.options.on_appearance) |h| h.call(dark);
}

fn onTaskbarCreated(ctx: *anyopaque) void {
    for (appOf(ctx).trays.items) |t| t.add();
}

fn onOther(ctx: *anyopaque, msg: u32, wp: w.WPARAM, lp: w.LPARAM) ?w.LRESULT {
    return app_extras.message(appOf(ctx), msg, wp, lp);
}
