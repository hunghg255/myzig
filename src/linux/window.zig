//! Windows on Linux: a GtkWindow showing native UI drawn by myzig, or a
//! web page in WebKitGTK.
const std = @import("std");
const gtk = @import("gtk.zig");
const App = @import("app.zig").App;
const Surface = @import("surface.zig").Surface;
const Page = @import("page.zig").Page;
const window_types = @import("../window_types.zig");
const ui = @import("../ui/ui.zig");
const extras = @import("window_extras.zig");
const events = @import("window_events.zig");
const more = @import("gtk_more.zig");
const launcher = @import("launcher_entry.zig");
const fly = @import("../flyout.zig");

pub const Asset = window_types.Asset;
pub const PageOptions = window_types.PageOptions;
pub const Content = window_types.Content;
pub const TitleBar = window_types.TitleBar;
pub const Callback = window_types.Callback(Window);
pub const Options = window_types.Options(Window);

pub const NativeView = window_types.NativeView;

pub const Frame = struct { x: f64, y: f64, width: f64, height: f64 };

pub const Window = struct {
    app: *App,
    /// Null when headless (snapshots without a display).
    gtkwindow: ?*gtk.Widget,
    surface: ?*Surface = null,
    /// The header bar of a hidden title bar over native UI (`titlebar_overlay.zig`).
    header: ?*gtk.Widget = null,
    page: ?*Page = null,
    /// Pages inside its native UI (`ui.webView`), over its drawing area
    /// in an overlay made for them.
    web_views: std.ArrayList(*Page) = .empty,
    web_overlay: ?*anyopaque = null,
    /// What a snapshot draws: the view, the window's size, its colors.
    view: ?ui.View = null,
    width: f64 = 0,
    height: f64 = 0,
    theme: ?ui.Theme = null,
    title_bar: TitleBar = .default,
    hide_window_buttons: bool = false,
    on_close: ?Callback = null,
    closed: bool = false,
    full_screen: bool = false,
    title: [256:0]u8 = @splat(0),
    on_drop: ?window_types.DropCallback(Window) = null,
    state: ?window_types.StateKey = null,
    on_close_request: ?window_types.CloseRequest(Window) = null,
    on_event: ?window_types.EventCallback(Window) = null,
    tracker: window_types.Tracker = .{},
    title_bar_height: f64 = 0,
    flyout: ?fly.State = null,
    edited: bool = false,
    /// The title shown: marked when the document is edited.
    shown_title: [258:0]u8 = @splat(0),

    pub const FlyoutState = fly.State;

    pub fn create(app: *App, requested: Options) !*Window {
        const g = &gtk.api;
        const restored = window_types.restore(app, requested);
        const options = restored[0];
        const self = try app.gpa.create(Window);
        errdefer app.gpa.destroy(self);
        self.* = .{ .app = app, .gtkwindow = null, .title_bar = options.title_bar, .hide_window_buttons = options.hide_window_buttons, .on_close = options.on_close, .width = options.width, .height = options.height, .theme = options.theme, .on_drop = options.on_drop, .state = options.state, .on_close_request = options.on_close_request, .on_event = options.on_event, .title_bar_height = options.title_bar_height, .flyout = options.flyout };
        var page_options: ?PageOptions = null;
        switch (options.content) {
            .page => |p| page_options = p,
            .view => |v| self.view = v,
        }
        if (!app.gui) return self;
        const win = g.gtk_window_new(0);
        self.gtkwindow = win;
        self.setTitle(options.title);
        g.gtk_window_set_default_size(win, @intFromFloat(options.width), @intFromFloat(options.height));
        g.gtk_window_set_resizable(win, @intFromBool(options.resizable));
        gtk.connect(win, "destroy", @ptrCast(&onDestroy), self);
        gtk.connect(win, "delete-event", @ptrCast(&onDelete), self);
        events.setUp(self, win, options);
        if (options.on_drop != null) extras.acceptDrops(win, self, onDrop);
        if (restored[1]) g.gtk_window_maximize(win);
        if (self.view) |v| self.surface = try Surface.create(self, v, options.theme);
        if (options.title_bar == .hidden and !options.hide_window_buttons and options.flyout == null) if (self.surface) |s| {
            if (@import("titlebar_overlay.zig").install(win, s.area)) |o| self.header = o.bar;
        };
        if (page_options) |p| self.page = try Page.create(self, p);
        if (options.flyout != null) {
            events.placeFlyout(self);
        } else if (options.x != null and options.y != null) self.setPosition(options.x.?, options.y.?) else g.gtk_window_set_position(win, 1);
        if (options.always_on_top) self.setAlwaysOnTop(true);
        if (!app.flags.hidden and options.visible) self.show();
        return self;
    }

    fn onDelete(_: *gtk.Widget, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Window = @ptrCast(@alignCast(data));
        if (events.onDelete(self) != 0) return 1;
        self.rememberState();
        return 0;
    }

    /// Closes the window as the user would, asking `on_close_request`.
    pub fn requestClose(self: *Window) void {
        if (self.gtkwindow) |win| if (more.load()) return more.api.gtk_window_close(win);
        if (events.mayClose(self)) self.close();
    }

    /// Native UI's press (the surface's): true when it moved the window.
    pub fn pressAt(self: *Window, e: *gtk.Event, x: f32, y: f32, count: c_uint) bool {
        return events.press(self, e, x, y, count);
    }

    /// Moves the window with the pointer, from a press on the content's
    /// own title bar (a drag region).
    pub fn startDrag(self: *Window) void {
        events.startDrag(self);
    }

    /// The room the system's controls take over the content: with a
    /// hidden title bar over native UI, the header bar of title buttons
    /// in its top right corner; else none (GTK's header bar sits above
    /// a page).
    pub fn titleBar(self: *Window) window_types.TitleBarArea {
        const bar = self.header orelse return .{};
        const a = @import("titlebar_overlay.zig").area(bar);
        return .{ .height = a.height, .right = a.right };
    }

    /// Windows 11's snap layouts: Linux has none.
    pub fn setSnapButton(_: *Window, _: ?fly.Rect) void {}

    pub fn placeFlyout(self: *Window) void {
        events.placeFlyout(self);
    }

    pub fn setAnchor(self: *Window, anchor: fly.Rect) void {
        if (self.flyout) |*f| f.anchor = anchor;
        events.placeFlyout(self);
    }

    pub fn isFlyout(self: *Window) bool {
        return self.flyout != null;
    }

    /// The app's progress on its launcher entry (docks with the Unity API).
    pub fn setProgress(self: *Window, p: window_types.Progress) bool {
        return launcher.setProgress(self.app, p);
    }

    /// Marks the window urgent, or no longer.
    pub fn flash(self: *Window, on: bool) void {
        const win = self.gtkwindow orelse return;
        if (more.load()) more.api.gtk_window_set_urgency_hint(win, @intFromBool(on));
    }

    /// Marks the window's document as edited: "*" before its title.
    pub fn setDocumentEdited(self: *Window, edited: bool) void {
        if (self.edited == edited) return;
        self.edited = edited;
        self.applyTitle();
    }

    pub fn isDocumentEdited(self: *Window) bool {
        return self.edited;
    }

    /// GTK's title bars show nothing of the file a window shows.
    pub fn setRepresentedFile(_: *Window, _: []const u8) void {}

    pub fn isMinimized(self: *Window) bool {
        return self.tracker.shown == .minimized;
    }

    fn applyTitle(self: *Window) void {
        const t = window_types.editedTitle(self.shown_title[0 .. self.shown_title.len - 1], std.mem.sliceTo(&self.title, 0), self.edited);
        // Unmarked, it is the title itself: copied.
        if (t.ptr != &self.shown_title) std.mem.copyForwards(u8, self.shown_title[0..t.len], t);
        self.shown_title[t.len] = 0;
        const win = self.gtkwindow orelse return;
        gtk.api.gtk_window_set_title(win, self.shown_title[0..t.len :0]);
    }

    fn onDrop(ctx: *anyopaque, paths: []const []const u8) void {
        const self: *Window = @ptrCast(@alignCast(ctx));
        if (self.on_drop) |cb| cb.func(cb.ctx, self, paths);
    }

    /// Records the window's state under its key, before it goes.
    fn rememberState(self: *Window) void {
        const k = self.state orelse return;
        if (self.gtkwindow == null) return;
        const f = self.frame();
        const max = self.isMaximized();
        // A maximized window keeps the frame it had before.
        if (max) if (k.get(self.app)) |old| {
            k.put(self.app, .{ .x = old.x, .y = old.y, .width = old.width, .height = old.height, .maximized = true });
            return;
        };
        k.put(self.app, .{ .x = f.x, .y = f.y, .width = f.width, .height = f.height, .maximized = max });
    }

    pub fn isMaximized(self: *Window) bool {
        const win = self.gtkwindow orelse return false;
        return gtk.api.gtk_window_is_maximized(win) != 0;
    }

    /// GTK has no materials: false.
    pub fn setMaterial(_: *Window, _: window_types.Material) bool {
        return false;
    }

    fn onDestroy(_: *gtk.Widget, data: ?*anyopaque) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data));
        self.finish();
    }

    /// The window is gone: tell its owner, free what it showed.
    fn finish(self: *Window) void {
        if (self.closed) return;
        self.closed = true;
        if (self.on_close) |cb| cb.func(cb.ctx, self);
        while (self.web_views.items.len > 0) self.web_views.items[self.web_views.items.len - 1].destroy();
        self.web_views.deinit(self.app.gpa);
        if (self.surface) |s| s.destroy();
        self.surface = null;
        if (self.page) |p| p.destroy();
        self.page = null;
        const app = self.app;
        app.removeWindow(self);
        app.gpa.destroy(self);
    }

    pub fn close(self: *Window) void {
        self.rememberState();
        // Destroying it calls `finish`, which frees it.
        if (self.gtkwindow) |win| gtk.api.gtk_widget_destroy(win) else self.finish();
    }

    pub fn minimize(self: *Window) void {
        const win = self.gtkwindow orelse return;
        gtk.api.gtk_window_iconify(win);
    }

    pub fn zoom(self: *Window) void {
        const g = &gtk.api;
        const win = self.gtkwindow orelse return;
        if (g.gtk_window_is_maximized(win) != 0) g.gtk_window_unmaximize(win) else g.gtk_window_maximize(win);
    }

    pub fn frame(self: *Window) Frame {
        var x: c_int = 0;
        var y: c_int = 0;
        var w: c_int = 0;
        var h: c_int = 0;
        const win = self.gtkwindow orelse return .{ .x = 0, .y = 0, .width = self.width, .height = self.height };
        gtk.api.gtk_window_get_position(win, &x, &y);
        gtk.api.gtk_window_get_size(win, &w, &h);
        return .{ .x = @floatFromInt(x), .y = @floatFromInt(y), .width = @floatFromInt(w), .height = @floatFromInt(h) };
    }

    pub fn contentSize(self: *Window) [2]f64 {
        const f = self.frame();
        return .{ f.width, f.height };
    }

    pub fn setSize(self: *Window, width: f64, height: f64) void {
        const win = self.gtkwindow orelse return;
        gtk.api.gtk_window_resize(win, @intFromFloat(width), @intFromFloat(height));
    }

    pub fn setPosition(self: *Window, x: f64, y: f64) void {
        const win = self.gtkwindow orelse return;
        gtk.api.gtk_window_move(win, @intFromFloat(x), @intFromFloat(y));
    }

    pub fn center(self: *Window) void {
        const win = self.gtkwindow orelse return;
        gtk.api.gtk_window_set_position(win, 1);
    }

    pub fn setMinSize(self: *Window, width: f64, height: f64) void {
        const win = self.gtkwindow orelse return;
        gtk.api.gtk_widget_set_size_request(win, @intFromFloat(width), @intFromFloat(height));
    }

    pub fn setResizable(self: *Window, on: bool) void {
        const win = self.gtkwindow orelse return;
        gtk.api.gtk_window_set_resizable(win, @intFromBool(on));
    }

    pub fn setAlwaysOnTop(self: *Window, on: bool) void {
        const win = self.gtkwindow orelse return;
        gtk.api.gtk_window_set_keep_above(win, @intFromBool(on));
    }

    pub fn isFullScreen(self: *Window) bool {
        return self.full_screen;
    }

    pub fn setFullScreen(self: *Window, on: bool) void {
        self.full_screen = on;
        const win = self.gtkwindow orelse return;
        if (on) gtk.api.gtk_window_fullscreen(win) else gtk.api.gtk_window_unfullscreen(win);
    }

    pub fn show(self: *Window) void {
        const win = self.gtkwindow orelse return;
        if (self.flyout != null) events.placeFlyout(self);
        gtk.api.gtk_widget_show_all(win);
        gtk.api.gtk_window_present(win);
        if (self.surface) |s| gtk.api.gtk_widget_grab_focus(s.area);
    }

    pub fn hide(self: *Window) void {
        const win = self.gtkwindow orelse return;
        gtk.api.gtk_widget_hide(win);
    }

    pub fn isVisible(self: *Window) bool {
        const win = self.gtkwindow orelse return false;
        return gtk.api.gtk_widget_is_visible(win) != 0;
    }

    pub fn focus(self: *Window) void {
        const win = self.gtkwindow orelse return;
        gtk.api.gtk_window_present(win);
    }

    pub fn isFocused(self: *Window) bool {
        const win = self.gtkwindow orelse return false;
        return gtk.api.gtk_window_is_active(win) != 0;
    }

    pub fn redraw(self: *Window) void {
        if (self.surface) |s| s.requestFrame();
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        const n = @min(title.len, self.title.len - 1);
        @memcpy(self.title[0..n], title[0..n]);
        self.title[n] = 0;
        self.applyTitle();
    }

    /// Sends `msg` (allocated with the app's allocator, which this frees)
    /// to the page, from any thread: the main loop enqueues it.
    pub fn sendOwned(self: *Window, msg: []u8) void {
        const Job = struct {
            window: *Window,
            msg: []u8,
            fn run(data: ?*anyopaque) callconv(.c) c_int {
                const job: *@This() = @ptrCast(@alignCast(data));
                const w = job.window;
                const gpa = w.app.gpa;
                defer gpa.destroy(job);
                defer gpa.free(job.msg);
                // The window may have closed meanwhile.
                for (w.app.windows.items) |live| if (live == w) {
                    if (w.page) |p| p.enqueue(job.msg, true);
                    for (w.web_views.items) |p| p.enqueue(job.msg, true);
                };
                return 0;
            }
        };
        const gpa = self.app.gpa;
        const job = gpa.create(Job) catch return gpa.free(msg);
        job.* = .{ .window = self, .msg = msg };
        _ = gtk.api.g_idle_add(Job.run, job);
    }

    /// Loads `url` in the window's page.
    pub fn loadUrl(self: *Window, url: []const u8) void {
        if (self.page) |p| p.load(url);
    }

    /// Runs `js` in the window's page, not waiting for it.
    pub fn eval(self: *Window, js: []const u8) void {
        if (self.page) |p| p.eval(js);
    }

    /// Evaluates the expression `js` in the window's page and passes its
    /// value as JSON, or its error, to `cb` (a `myzig.EvalCallback`).
    pub fn evalResult(self: *Window, js: []const u8, cb: anytype) void {
        const p = self.page orelse return cb.func(cb.ctx, .{ .err = "the window shows no page" });
        p.evalResult(js, cb);
    }

    /// What `--myzig-snapshot` draws of this window, if it shows native UI.
    pub fn nativeView(self: *Window) ?NativeView {
        const v = self.view orelse return null;
        if (self.surface) |s| if (s.size.w > 0) return .{ .view = v, .width = s.size.w, .height = s.size.h, .scale = @max(2, s.scale), .theme = self.theme };
        return .{ .view = v, .width = @floatCast(self.width), .height = @floatCast(self.height), .scale = 2, .theme = self.theme };
    }

    pub fn logFrame(self: *Window) void {
        const f = self.frame();
        std.debug.print("myzig: window {x} frame {d} {d} {d} {d}\n", .{ @intFromPtr(self), f.x, f.y, f.width, f.height });
    }
};
