//! The application: lifecycle, the menu bar, tray icons, bound services, timers.
const std = @import("std");
const objc = @import("objc.zig");
const ipc = @import("ipc.zig");
const Bindings = @import("bindings.zig").Bindings;
const dev = @import("dev.zig");
const window_mod = @import("window.zig");
const menu_mod = @import("menu.zig");
const tray_mod = @import("tray.zig");
const fdwatch = @import("fdwatch.zig");
const instance = @import("instance_unix.zig");
const notify_mac = @import("notify_mac.zig");
const app_types = @import("app_types.zig");
const app_common = @import("app_common.zig");
const launch = @import("launch.zig");
const window_types = @import("window_types.zig");
const Window = window_mod.Window;
const app_extras = @import("app_extras_mac.zig");
const relaunch_mod = @import("relaunch.zig");

pub const Options = app_types.Options;

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    nsapp: objc.Object,
    delegate: objc.Object,
    windows: std.ArrayList(*Window) = .empty,
    bindings: Bindings = .{},
    main_menu: ?*menu_mod.Menu = null,
    trays: std.ArrayList(*tray_mod.Tray) = .empty,
    flags: dev.Flags = .{},
    running: bool = false,
    stopping: bool = false,
    /// `MYZIG_DEBUG=1`: log windows' ids and frames, for tools and tests.
    debug: bool = false,
    /// Global shortcuts, the network's watch, signals (`app_extras_mac.zig`).
    extras: app_extras.State = .{},
    launch: app_common.Launch = .{},
    /// Started by the system at login (`setOpenAtLogin`).
    opened_at_login: bool = false,
    lock: ?instance.Listener = null,
    lock_watch: ?fdwatch.Watch = null,
    dark: bool = false,
    /// Set by `relaunch`: starts the app again once `destroy` freed it.
    restart: ?relaunch_mod.Restart = null,

    pub const FlyoutOptions = app_extras.FlyoutOptions;

    /// A flyout: a borderless panel next to a rectangle of its parent, a
    /// point of the screen or a tray icon (below its menu bar button),
    /// dismissed as another window takes the keyboard.
    pub fn newFlyout(self: *App, opts: FlyoutOptions) !*Window {
        return app_extras.newFlyout(self, opts);
    }

    /// Registers a global shortcut ("Alt+Shift+Space"): `handler` runs
    /// on the main thread when it is pressed, whatever app is in front.
    pub fn registerHotkey(self: *App, keys: []const u8, handler: app_types.Handler(void)) !u32 {
        return app_extras.registerHotkey(self, keys, handler);
    }

    pub fn unregisterHotkey(self: *App, id: u32) void {
        app_extras.unregisterHotkey(self, id);
    }

    /// Whether the computer is online, and its connection metered.
    pub fn networkStatus(_: *App) app_types.NetworkStatus {
        return @import("network_mac.zig").status();
    }

    /// A badge on the app's Dock icon; empty removes it.
    pub fn setBadge(self: *App, text: []const u8) bool {
        return app_extras.setBadge(self, text);
    }

    /// Shows the app light or dark whatever the system shows, or as the
    /// system again (`.system`).
    pub fn setAppearance(self: *App, a: @import("appearance.zig").Appearance) void {
        app_extras.setAppearance(self, a);
    }

    /// Creates the app. Call from `main`, on the main thread.
    pub fn create(init: std.process.Init, options: Options) !*App {
        if (!objc.isMainThread()) return error.NotMainThread;
        const gpa = init.gpa;
        const self = try gpa.create(App);
        errdefer gpa.destroy(self);

        const flags = try dev.Flags.parse(init);
        if (flags.headless()) @import("headless.zig").request();

        const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
        const delegate_class = objc.defineClass(.{
            .name = "MyZigAppDelegate",
            .protocols = &.{"NSApplicationDelegate"},
            .methods = &.{
                .{ .name = "applicationDidFinishLaunching:", .imp = &didFinishLaunching, .types = "v@:@" },
                .{ .name = "applicationShouldTerminate:", .imp = &shouldTerminate, .types = "Q@:@" },
                .{ .name = "applicationShouldHandleReopen:hasVisibleWindows:", .imp = &shouldReopen, .types = "c@:@c" },
                .{ .name = "application:openURLs:", .imp = &openURLs, .types = "v@:@@" },
                .{ .name = "themeChanged:", .imp = &themeChanged, .types = "v@:@" },
            },
        });
        const delegate = objc.msg(objc.Object, delegate_class, "new", .{});
        objc.setZig(delegate, self);

        self.* = .{
            .gpa = gpa,
            .io = init.io,
            .options = options,
            .nsapp = nsapp,
            .delegate = delegate,
            .flags = flags,
            .debug = init.environ_map.get("MYZIG_DEBUG") != null,
            .launch = app_common.Launch.of(init),
            .opened_at_login = app_common.Launch.atLogin(init),
        };
        notify_mac.setHandler(options.on_notification);
        if (options.on_appearance != null) {
            self.dark = systemDark();
            const dnc = objc.msg(objc.Object, objc.class("NSDistributedNotificationCenter"), "defaultCenter", .{});
            objc.msg(void, dnc, "addObserver:selector:name:object:", .{ delegate, objc.sel("themeChanged:"), objc.nsString("AppleInterfaceThemeChangedNotification"), @as(?objc.Object, null) });
        }
        // A plain binary (not an .app bundle) still gets a Dock icon and
        // menus; hidden runs (tests, snapshots) get neither, nor focus.
        const policy: objc.NSInteger = if (flags.hidden) 2 else 0;
        _ = objc.msg(objc.BOOL, nsapp, "setActivationPolicy:", .{policy});
        objc.msg(void, nsapp, "setDelegate:", .{delegate});
        try self.setMenu(&default_menu);
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
        defer @import("headless.zig").end(io);
        while (self.windows.items.len > 0) {
            const w = self.windows.items[self.windows.items.len - 1];
            w.close();
        }
        self.windows.deinit(self.gpa);
        self.bindings.deinit(self.gpa);
        for (self.trays.items) |t| t.destroy();
        self.trays.deinit(self.gpa);
        if (self.main_menu) |m| m.destroy();
        app_extras.stop(self);
        if (self.lock_watch) |wt| wt.cancel();
        if (self.lock) |*l| l.release();
        if (window_types.free_states) |f| f();
        notify_mac.setHandler(null);
        const dnc = objc.msg(objc.Object, objc.class("NSDistributedNotificationCenter"), "defaultCenter", .{});
        objc.msg(void, dnc, "removeObserver:", .{self.delegate});
        objc.setZig(self.delegate, null);
        objc.msg(void, self.nsapp, "setDelegate:", .{@as(?objc.Object, null)});
        objc.release(self.delegate);
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

    pub fn newWindow(self: *App, options: window_mod.Options) !*Window {
        const w = try Window.create(self, options);
        errdefer w.close();
        try self.windows.append(self.gpa, w);
        return w;
    }

    pub fn removeWindow(self: *App, w: *Window) void {
        for (self.windows.items, 0..) |item, i| {
            if (item == w) {
                _ = self.windows.orderedRemove(i);
                break;
            }
        }
        if (self.windows.items.len == 0 and self.options.quit_on_last_window_closed and self.running) self.quit();
    }

    /// Runs the event loop until the app quits. With
    /// `--myzig-generate=<dir>` it writes the client instead and returns.
    pub fn run(self: *App) !void {
        if (self.flags.generate_dir) |dir| return self.bindings.writeClient(self.gpa, self.io, dir);
        if (self.flags.snapshot) |path| return dev.snapshot(self, path);
        // Quit before the loop started: nothing to run.
        if (self.stopping) return;
        self.running = true;
        app_extras.start(self);
        app_common.deliver(self.gpa, self.io, self.options, self.launch.args, self.launch.cwd);
        objc.msg(void, self.nsapp, "run", .{});
        self.running = false;
    }

    /// Stops the event loop; `run` returns once the current event is handled.
    pub fn quit(self: *App) void {
        if (self.stopping) return;
        self.stopping = true;
        if (!self.running) return;
        objc.msg(void, self.nsapp, "stop:", .{@as(?objc.Object, null)});
        // `stop:` takes effect after the next event: post one.
        const ev = objc.msg(objc.Object, objc.class("NSEvent"), "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:", .{
            @as(objc.NSUInteger, 15), objc.CGPoint{}, @as(objc.NSUInteger, 0), @as(f64, 0), @as(objc.NSInteger, 0), @as(?objc.Object, null), @as(i16, 0), @as(objc.NSInteger, 0), @as(objc.NSInteger, 0),
        });
        objc.msg(void, self.nsapp, "postEvent:atStart:", .{ ev, objc.YES });
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

    /// The generated JavaScript client, served to pages at `/myzig.js`.
    pub fn clientJs(self: *App) ![]const u8 {
        return self.bindings.clientJs(self.gpa);
    }

    /// The generated declarations of the client (`myzig.d.ts`).
    pub fn clientDts(self: *App, gpa: std.mem.Allocator) ![]u8 {
        return self.bindings.clientDts(gpa);
    }

    /// Calls `func(ctx)` on the main thread after `ms` milliseconds.
    pub fn after(ms: u64, ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void) void {
        objc.dispatchAfter(ms * std.time.ns_per_ms, ctx, func);
    }

    /// Replaces the menu bar with one built from `template`.
    pub fn setMenu(self: *App, template: []const menu_mod.MenuItem) !void {
        const m = try menu_mod.Menu.create(self.gpa, self.options.name, template);
        objc.msg(void, self.nsapp, "setMainMenu:", .{m.ns});
        if (m.windows_menu) |w| objc.msg(void, self.nsapp, "setWindowsMenu:", .{w});
        if (self.main_menu) |old| old.destroy();
        self.main_menu = m;
    }

    /// The menu bar's item whose template had `id`.
    pub fn menuItem(self: *App, id: []const u8) ?*menu_mod.Item {
        const m = self.main_menu orelse return null;
        return m.item(id);
    }

    /// Brings the app forward, its windows in their order (the one the
    /// user had last in front), as a tray icon's click opens its settings.
    pub fn focus(self: *App) void {
        objc.msg(void, self.nsapp, "activateIgnoringOtherApps:", .{objc.YES});
    }

    /// Adds an icon to the menu bar's status area; it lives until removed
    /// with `Tray.destroy` or the app ends.
    pub fn newTray(self: *App, opts: tray_mod.Options) !*tray_mod.Tray {
        const t = try tray_mod.Tray.create(self.gpa, self.options.name, opts);
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
    /// gets later ones' command lines (`on_second_instance`); false in a
    /// later one, after it handed its command line over: it should exit.
    /// (A bundle opened again in Finder is activated by macOS instead.)
    pub fn requestSingleInstanceLock(self: *App) bool {
        if (self.lock != null or self.flags.generate_dir != null) return true;
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

    /// Shows a notification (UNUserNotificationCenter: the app must be a
    /// bundle). A click reaches `on_notification`.
    pub fn notify(_: *App, n: app_types.Notification) !void {
        try notify_mac.notify(n);
    }

    pub fn removeNotification(_: *App, id: []const u8) void {
        notify_mac.remove(id);
    }

    /// The menu every app starts with: the app menu, Edit, View, Window.
    pub const default_menu = [_]menu_mod.MenuItem{
        .{ .role = .app_menu },
        .{ .role = .edit_menu },
        .{ .role = .view_menu },
        .{ .role = .window_menu },
    };
};

fn didFinishLaunching(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    if (objc.getZig(App, self_obj)) |app| if (app.flags.hidden) return;
    const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    objc.msg(void, nsapp, "activateIgnoringOtherApps:", .{objc.YES});
}

fn shouldTerminate(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) objc.NSUInteger {
    // AppKit would call exit(); stop the loop instead so `App.run` returns.
    if (objc.getZig(App, self_obj)) |app| app.quit();
    return 0; // NSTerminateCancel
}

fn openURLs(self_obj: objc.Object, _: objc.SEL, _: objc.Object, urls: objc.Object) callconv(.c) void {
    const app = objc.getZig(App, self_obj) orelse return;
    const n = objc.msg(objc.NSUInteger, urls, "count", .{});
    for (0..n) |i| {
        const url = objc.msg(objc.Object, urls, "objectAtIndex:", .{i});
        if (objc.msg(objc.BOOL, url, "isFileURL", .{})) {
            if (app.options.on_open_file) |h| h.call(objc.fromNSString(objc.msg(?objc.Object, url, "path", .{})));
        } else if (app.options.on_open_url) |h| h.call(objc.fromNSString(objc.msg(?objc.Object, url, "absoluteString", .{})));
    }
}

/// Dark mode as the user chose it (AppleInterfaceStyle is "Dark").
fn systemDark() bool {
    const defaults = objc.msg(objc.Object, objc.class("NSUserDefaults"), "standardUserDefaults", .{});
    const style = objc.msg(?objc.Object, defaults, "stringForKey:", .{objc.nsString("AppleInterfaceStyle")}) orelse return false;
    return std.mem.eql(u8, objc.fromNSString(style), "Dark");
}

fn themeChanged(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const app = objc.getZig(App, self_obj) orelse return;
    const dark = @import("appearance.zig").dark(systemDark());
    if (dark == app.dark) return;
    app.dark = dark;
    if (app.options.on_appearance) |h| h.call(dark);
}

fn shouldReopen(self_obj: objc.Object, _: objc.SEL, _: objc.Object, visible: objc.BOOL) callconv(.c) objc.BOOL {
    _ = self_obj;
    return !visible;
}
