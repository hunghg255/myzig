//! The application in a browser, compiled to WebAssembly (wasm32-wasi):
//! `main` makes the app and its windows, and `run` hands the app to the
//! browser's events, which reach it through the functions the host calls
//! (`exports.zig`); timers are the browser's. Menus, trays, notifications
//! and a single instance have nothing in a browser to stand for them:
//! they do nothing, or report so. Headless runs (`--myzig-snapshot`,
//! `--myzig-generate`) work as on desktops, for tests under a WASI runtime.
const std = @import("std");
const js = @import("js.zig");
const dev = @import("../dev.zig");
const window_mod = @import("window.zig");
const menu_mod = @import("../menu_accel.zig");
const tray_mod = @import("../tray_none.zig");
const ui = @import("../ui/ui.zig");
const app_types = @import("../app_types.zig");
const app_common = @import("../app_common.zig");
const window_types = @import("../window_types.zig");
const Bindings = @import("../bindings.zig").Bindings;
const Surface = @import("surface.zig").Surface;
const Window = window_mod.Window;

comptime {
    // The functions the host calls.
    _ = @import("exports.zig");
}

pub const Options = app_types.Options;

/// What a timer runs: an app's callback, or a window's frame asked for later.
const Timer = union(enum) {
    free,
    call: struct { ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void },
    frame: *Surface,
};
var timers: [64]Timer = @splat(.free);

/// The one app of the page, for the host's events.
pub var current: ?*App = null;

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    bindings: Bindings = .{},
    windows: std.ArrayList(*Window) = .empty,
    main_menu: ?*menu_mod.Menu = null,
    flags: dev.Flags = .{},
    launch: app_common.Launch = .{},
    opened_at_login: bool = false,
    /// The browser's dark appearance (or the page's `data-myzig-theme`).
    dark: bool = false,
    /// Windows show on the page (not a headless run).
    gui: bool = false,
    running: bool = false,
    stopping: bool = false,

    pub fn create(init: std.process.Init, options: Options) !*App {
        const gpa = init.gpa;
        const self = try gpa.create(App);
        errdefer gpa.destroy(self);
        const flags = try dev.Flags.parse(init);
        if (flags.headless()) @import("../headless.zig").request();
        self.* = .{ .gpa = gpa, .io = init.io, .options = options, .flags = flags, .launch = app_common.Launch.of(init) };
        self.gui = flags.snapshot == null and flags.generate_dir == null;
        if (self.gui) self.dark = js.is_dark();
        current = self;
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
        if (self.main_menu) |m| m.destroy();
        if (window_types.free_states) |f| f();
        self.bindings.deinit(self.gpa);
        if (current == self) current = null;
        self.gpa.destroy(self);
    }

    /// Binds a service, for the generated client (`--myzig-generate`): no
    /// page calls it in a browser.
    pub fn bind(self: *App, service: anytype) !void {
        try self.bindings.bind(self.gpa, service);
    }

    pub fn registerEvent(self: *App, comptime E: type) !void {
        try self.bindings.registerEvent(self.gpa, E);
    }

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

    /// Hands the app to the browser: `main` ends here without returning,
    /// its stack kept for the state it made (`js.run`). Headless runs
    /// return as on desktops.
    pub fn run(self: *App) !void {
        if (self.flags.generate_dir) |dir| return self.bindings.writeClient(self.gpa, self.io, dir);
        if (self.flags.snapshot) |path| return dev.snapshot(self, path);
        if (self.stopping or !self.gui) return;
        self.running = true;
        app_common.deliver(self.gpa, self.io, self.options, self.launch.args, self.launch.cwd);
        js.run();
    }

    /// Closes the windows; the page stays, empty.
    pub fn quit(self: *App) void {
        if (self.stopping) return;
        self.stopping = true;
        const running = self.running;
        self.running = false;
        while (self.windows.items.len > 0) self.windows.items[self.windows.items.len - 1].close();
        if (running) js.quit();
    }

    /// Quits like `quit`: a page has no process to start again (reloading
    /// it is the page's business).
    pub fn relaunch(self: *App) void {
        self.quit();
    }

    pub fn after(ms: u64, ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void) void {
        schedule(@floatFromInt(@max(1, ms)), .{ .call = .{ .ctx = ctx, .func = func } });
    }

    /// A frame of `s` in `ms` milliseconds (`Context.frame_in`).
    pub fn later(_: *App, ms: f32, s: *Surface) void {
        schedule(ms, .{ .frame = s });
    }

    /// One page, one instance: always the first.
    pub fn requestSingleInstanceLock(_: *App) bool {
        return true;
    }

    /// Kept for its accelerators (key combinations reach them); no menu
    /// bar shows.
    pub fn setMenu(self: *App, template: []const menu_mod.MenuItem) !void {
        const m = try menu_mod.Menu.create(self.gpa, template);
        if (self.main_menu) |old| old.destroy();
        self.main_menu = m;
    }

    pub fn menuItem(self: *App, id: []const u8) ?*menu_mod.Item {
        const m = self.main_menu orelse return null;
        return m.item(id);
    }

    /// The page is the app's only window: nothing to bring forward.
    pub fn focus(_: *App) void {}

    pub fn newTray(_: *App, _: tray_mod.Options) !*tray_mod.Tray {
        return error.Unsupported;
    }

    pub fn removeTray(_: *App, _: *tray_mod.Tray) void {}

    pub fn notify(_: *App, _: app_types.Notification) !void {
        return error.Unsupported;
    }

    pub fn removeNotification(_: *App, _: []const u8) void {}

    /// The window in front: the last opened.
    pub fn keyWindow(self: *App) ?*Window {
        for (self.windows.items) |win| if (win.isFocused()) return win;
        const n = self.windows.items.len;
        return if (n > 0) self.windows.items[n - 1] else null;
    }

    /// A key combination: the menus' accelerator first. True if taken.
    pub fn accelerator(self: *App, sc: ui.Shortcut) bool {
        const m = self.main_menu orelse return false;
        const it = m.match(sc) orelse return false;
        if (it.role) |role| {
            const target = self.keyWindow();
            switch (role) {
                .quit => self.quit(),
                .close => if (target) |t| t.close(),
                .copy, .cut, .paste, .select_all, .undo, .redo, .delete => if (it.click == null) return false,
                else => {},
            }
            if (it.click == null) return true;
        }
        menu_mod.Menu.activate(it);
        return true;
    }

    /// Shows the app light or dark whatever the browser shows, or as the
    /// browser again (`.system`).
    pub fn setAppearance(self: *App, a: @import("../appearance.zig").Appearance) void {
        @import("../appearance.zig").chosen = a;
        self.setDark(@import("desktop.zig").isDark());
    }

    /// The browser's appearance changed.
    pub fn setDark(self: *App, shown: bool) void {
        const dark = @import("../appearance.zig").dark(shown);
        if (dark == self.dark) return;
        self.dark = dark;
        for (self.windows.items) |win| win.redraw();
        if (self.options.on_appearance) |h| h.call(dark);
    }
};

fn schedule(ms: f64, t: Timer) void {
    for (&timers, 0..) |*slot, i| if (slot.* == .free) {
        slot.* = t;
        js.set_timeout(ms, @intCast(i + 1));
        return;
    };
}

/// Drops the timers of a window that closes.
pub fn cancelFrames(s: *Surface) void {
    for (&timers) |*slot| if (slot.* == .frame and slot.frame == s) {
        // The slot stays taken until its timeout runs, then does nothing.
        slot.* = .{ .call = .{ .ctx = null, .func = nothing } };
    };
}

fn nothing(_: ?*anyopaque) callconv(.c) void {}

/// The browser's timeout `token` ran.
pub fn fire(token: u32) void {
    if (token == 0 or token > timers.len) return;
    const t = timers[token - 1];
    timers[token - 1] = .free;
    switch (t) {
        .free => {},
        .call => |c| c.func(c.ctx),
        .frame => |s| s.onLater(),
    }
}
