//! Windows on Windows: a top-level window showing native UI drawn by
//! myzig, or a web page in WebView2.
const std = @import("std");
const w = @import("win32.zig");
extern "user32" fn LoadIconW(inst: ?w.HINSTANCE, name: usize) callconv(.winapi) ?*anyopaque;
const App = @import("app.zig").App;
const Surface = @import("surface.zig").Surface;
const page_mod = @import("page.zig");
const Page = page_mod.Page;
const window_types = @import("../window_types.zig");
const ui = @import("../ui/ui.zig");
const menubar = @import("menubar.zig");
const menu_mod = @import("../menu_accel.zig");
const appwnd = @import("appwnd.zig");
const extras = @import("window_extras.zig");
const gdi = @import("gdi.zig");
const frame_mod = @import("frame.zig");
const caption_mod = @import("caption.zig");
const flyout_mod = @import("flyout.zig");
const taskbar = @import("taskbar.zig");
const events = @import("window_events.zig");
const fly = @import("../flyout.zig");

pub const Asset = window_types.Asset;
pub const PageOptions = window_types.PageOptions;
pub const Content = window_types.Content;
pub const TitleBar = window_types.TitleBar;
pub const Callback = window_types.Callback(Window);
pub const Options = window_types.Options(Window);
pub const NativeView = window_types.NativeView;

pub const Frame = struct { x: f64, y: f64, width: f64, height: f64 };

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("MyZigWindow");
var registered = false;

/// A message for the page from another thread: lParam is a `Sent`.
// Not WM_APP + 2: that is surface_present's WM_PRESENT, posted to the same window.
const WM_SEND = w.WM_APP + 3;
const Sent = struct { msg: []u8 };
const WM_PARENTNOTIFY = 0x0210;
const WM_RAISE_CAPTION = w.WM_APP + 22;

pub const Window = struct {
    app: *App,
    /// Null when headless (snapshots).
    hwnd: ?w.HWND = null,
    surface: ?*Surface = null,
    page: ?*Page = null,
    /// Pages inside its native UI (`ui.webView`).
    web_views: std.ArrayList(*Page) = .empty,
    title_bar: TitleBar = .default,
    hide_window_buttons: bool = false,
    on_close: ?Callback = null,
    closed: bool = false,
    full_screen: bool = false,
    view: ?ui.View = null,
    width: f64 = 0,
    height: f64 = 0,
    theme: ?ui.Theme = null,
    min_width: f64 = 0,
    min_height: f64 = 0,
    style: u32 = w.WS_OVERLAPPEDWINDOW,
    on_drop: ?window_types.DropCallback(Window) = null,
    state: ?window_types.StateKey = null,
    on_close_request: ?window_types.CloseRequest(Window) = null,
    on_event: ?window_types.EventCallback(Window) = null,
    tracker: window_types.Tracker = .{},
    /// The caption buttons of a hidden title bar.
    caption: ?*caption_mod.Caption = null,
    title_bar_height: f64 = 0,
    /// Set for a flyout: where it goes, and its size in points.
    flyout: ?fly.State = null,
    /// The title as the app set it, and whether its document is edited.
    title: [256]u8 = undefined,
    title_len: usize = 0,
    edited: bool = false,
    /// Where native UI drew its maximize button, in points (snap layouts).
    snap: ?fly.Rect = null,

    pub fn create(app: *App, requested: Options) !*Window {
        const restored = window_types.restore(app, requested);
        var options = restored[0];
        // A remembered position off every monitor (one unplugged) is dropped.
        if (options.x != null and app.gui and !extras.onScreen(options.x.?, options.y.?)) {
            options.x = requested.x;
            options.y = requested.y;
        }
        const self = try app.gpa.create(Window);
        errdefer app.gpa.destroy(self);
        self.* = .{ .app = app, .title_bar = options.title_bar, .hide_window_buttons = options.hide_window_buttons, .on_close = options.on_close, .width = options.width, .height = options.height, .theme = options.theme, .min_width = options.min_width, .min_height = options.min_height, .on_drop = options.on_drop, .state = options.state, .on_close_request = options.on_close_request, .on_event = options.on_event, .title_bar_height = options.title_bar_height, .flyout = options.flyout };
        self.storeTitle(options.title);
        var page_options: ?PageOptions = null;
        switch (options.content) {
            .page => |p| page_options = p,
            .view => |v| self.view = v,
        }
        if (!app.gui) return self;
        const inst = w.GetModuleHandleW(null);
        if (!registered) {
            // The executable's icon (resource 1, which `myzig build` links) in the
            // title bar, the taskbar and Alt+Tab; the system's when it has none.
            const icon = LoadIconW(inst, 1);
            const wc: w.WNDCLASSEXW = .{ .style = w.CS_DBLCLKS, .lpfnWndProc = wndProc, .hInstance = inst, .hCursor = w.LoadCursorW(null, 32512), .lpszClassName = class_name, .hIcon = icon, .hIconSm = icon };
            if (w.RegisterClassExW(&wc) == 0) return error.RegisterClass;
            registered = true;
        }
        if (self.view) |v| self.surface = try Surface.create(self, v, options.theme);
        var title: [512]u16 = undefined;
        var style: u32 = w.WS_OVERLAPPEDWINDOW;
        var ex: u32 = 0;
        if (!options.resizable) style &= ~@as(u32, w.WS_THICKFRAME | w.WS_MAXIMIZEBOX);
        if (options.flyout) |f| {
            const s = flyout_mod.styles(f);
            style = s.style;
            ex = s.ex;
        }
        self.style = style;
        // An owned window has no taskbar button: a flyout's owner is its
        // parent, or the app's hidden window, as a window kept off the taskbar's.
        var owner: ?w.HWND = null;
        if (options.flyout) |f| {
            if (f.parent) |p| owner = @as(*Window, @ptrCast(@alignCast(p))).hwnd else owner = app.appWindow();
        } else if (options.skip_taskbar) owner = app.appWindow();
        // A window without a caption has no menu bar either.
        const bar: ?menubar.HMENU = if (app.main_menu != null and !self.captionless()) menubar.build(app.main_menu.?, true) else null;
        const hwnd = w.CreateWindowExW(ex, class_name, w.wide(&title, options.title), style, w.CW_USEDEFAULT, w.CW_USEDEFAULT, 100, 100, owner, bar, inst, null) orelse return error.CreateWindow;
        self.hwnd = hwnd;
        _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        if (self.captionless()) _ = w.SetWindowPos(hwnd, null, 0, 0, 0, 0, gdi.SWP_NOMOVE | gdi.SWP_NOSIZE | gdi.SWP_NOZORDER | gdi.SWP_FRAMECHANGED | gdi.SWP_NOACTIVATE);
        if (options.title_bar == .hidden and !options.hide_window_buttons and options.flyout == null) self.caption = caption_mod.Caption.create(app.gpa, .{
            .ctx = self,
            .hwnd = hwnd,
            .height = self.titleBarHeight(),
            .dark = isDark,
            .full_screen = isFull,
        }) catch null;
        if (options.flyout != null) {
            flyout_mod.round(hwnd);
            self.width = options.width;
            self.height = options.height;
            self.placeFlyout();
        } else {
            self.setSize(options.width, options.height);
            if (options.x != null and options.y != null) self.setPosition(options.x.?, options.y.?) else self.center();
        }
        if (options.on_drop != null) extras.acceptDrops(hwnd);
        if (options.material != .none) _ = extras.setMaterial(hwnd, options.material);
        if (app.dark) extras.setDarkTitleBar(hwnd, true);
        if (page_options) |p| self.page = try Page.create(self, p);
        if (self.caption) |c| c.layout();
        if (!app.flags.hidden and options.visible) {
            self.show();
            if (restored[1]) self.zoom();
        }
        return self;
    }

    fn captionless(self: *Window) bool {
        return self.title_bar != .default or self.flyout != null;
    }

    /// Whether the title bar is dark: the window's fixed theme's, else the
    /// one its native UI drew with last (a view may apply its own), else
    /// the system's.
    fn isDark(ctx: *anyopaque) bool {
        const self: *Window = @ptrCast(@alignCast(ctx));
        if (self.theme) |t| return t.dark;
        if (self.surface) |s| return s.ctx.theme.dark;
        return self.app.dark;
    }

    /// After each frame of its native UI: its accessibility, and the
    /// caption buttons in the theme it drew with.
    pub fn afterFrame(self: *Window, s: *Surface) void {
        @import("surface_access.zig").afterFrame(s);
        if (self.caption) |c| c.followTheme();
    }

    fn isFull(ctx: *anyopaque) bool {
        const self: *Window = @ptrCast(@alignCast(ctx));
        return self.full_screen;
    }

    /// The title bar's height a hidden one draws, in points.
    pub fn titleBarHeight(self: *Window) f64 {
        return if (self.title_bar_height > 0) self.title_bar_height else caption_mod.default_height;
    }

    /// The room the caption buttons take over the content of a window
    /// with a hidden title bar; none for others, and in full screen.
    pub fn titleBar(self: *Window) window_types.TitleBarArea {
        if (self.title_bar != .hidden or self.hide_window_buttons or self.full_screen or self.flyout != null) return .{};
        const right: f64 = if (self.caption) |c| c.width() else caption_mod.button_width * 3;
        return .{ .height = self.titleBarHeight(), .right = right };
    }

    /// Tells where native UI drew its own maximize button (points in the
    /// content), so Windows 11 shows its snap layouts over it; null when
    /// it has none. A window without a caption only.
    pub fn setSnapButton(self: *Window, r: ?fly.Rect) void {
        self.snap = r;
    }

    /// Moves the window with the pointer, as its title bar would: call it
    /// from a press on the content's own title bar (a drag region).
    pub fn startDrag(self: *Window) void {
        if (self.hwnd) |h| frame_mod.startDrag(h);
    }

    /// Closes the window as the user would, asking `on_close_request`.
    pub fn requestClose(self: *Window) void {
        if (self.hwnd) |h| {
            _ = w.SendMessageW(h, w.WM_CLOSE, 0, 0);
        } else if (events.mayClose(self)) self.close();
    }

    /// Places a flyout next to its anchor again (its parent moved, its
    /// tray icon did); `setAnchor` gives it another one.
    pub fn placeFlyout(self: *Window) void {
        const f = self.flyout orelse return;
        const h = self.hwnd orelse return;
        const parent: ?w.HWND = if (f.parent) |p| @as(*Window, @ptrCast(@alignCast(p))).hwnd else null;
        const r = flyout_mod.placement(f, parent, self.width, self.height);
        _ = w.SetWindowPos(h, null, r.left, r.top, r.right - r.left, r.bottom - r.top, gdi.SWP_NOZORDER | gdi.SWP_NOACTIVATE);
    }

    pub fn setAnchor(self: *Window, anchor: fly.Rect) void {
        if (self.flyout) |*f| f.anchor = anchor;
        self.placeFlyout();
    }

    pub fn isFlyout(self: *Window) bool {
        return self.flyout != null;
    }

    /// Shows a task's progress across the window's taskbar button.
    pub fn setProgress(self: *Window, p: window_types.Progress) bool {
        const h = self.hwnd orelse return false;
        return taskbar.setProgress(h, p);
    }

    /// Flashes the window's taskbar button until it is focused, or stops.
    pub fn flash(self: *Window, on: bool) void {
        if (self.hwnd) |h| taskbar.flash(h, on);
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

    /// The file the window shows: nothing on Windows. Its title bars have
    /// no proxy icon to drag or to show the file's folders from, and the
    /// title bar's icon is the taskbar button's and Alt+Tab's too: the
    /// file type's icon there would hide the app's. Put the file's name
    /// in the title, as Windows apps do ("Notes.md - Editor").
    pub fn setRepresentedFile(_: *Window, _: []const u8) void {}

    pub fn isMinimized(self: *Window) bool {
        const h = self.hwnd orelse return false;
        return gdi.IsIconic(h) != 0;
    }

    fn storeTitle(self: *Window, title: []const u8) void {
        self.title_len = @min(title.len, self.title.len);
        @memcpy(self.title[0..self.title_len], title[0..self.title_len]);
    }

    fn applyTitle(self: *Window) void {
        const h = self.hwnd orelse return;
        var marked: [257]u8 = undefined;
        var buf: [512]u16 = undefined;
        _ = w.SetWindowTextW(h, w.wide(&buf, window_types.editedTitle(&marked, self.title[0..self.title_len], self.edited)));
    }

    /// Replaces the window's menu bar with one of `m` (`App.setMenu`).
    pub fn setMenuBar(self: *Window, m: *menu_mod.Menu) void {
        const h = self.hwnd orelse return;
        const old = menubar.GetMenu(h);
        _ = menubar.SetMenu(h, menubar.build(m, true));
        if (old) |o| _ = menubar.DestroyMenu(o);
        _ = menubar.DrawMenuBar(h);
    }

    pub fn isMaximized(self: *Window) bool {
        const h = self.hwnd orelse return false;
        return w.IsZoomed(h) != 0;
    }

    /// Shows Windows 11's material behind the window; false on Windows 10.
    pub fn setMaterial(self: *Window, material: window_types.Material) bool {
        const h = self.hwnd orelse return false;
        return extras.setMaterial(h, material);
    }

    fn of(hwnd: w.HWND) ?*Window {
        const p = w.GetWindowLongPtrW(hwnd, w.GWLP_USERDATA);
        if (p == 0) return null;
        return @ptrFromInt(@as(usize, @bitCast(p)));
    }

    fn wndProc(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
        const self = of(hwnd) orelse return w.DefWindowProcW(hwnd, msg, wp, lp);
        if (msg == w.WM_DESTROY) {
            _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, 0);
            self.finish();
            return 0;
        }
        if (msg == w.WM_SHOWWINDOW or msg == w.WM_SIZE) {
            @import("page_memory.zig").windowChanged(self, if (msg == w.WM_SHOWWINDOW) wp != 0 else self.isVisible(), if (msg == w.WM_SIZE) wp == 1 else gdi.IsIconic(hwnd) != 0);
        }
        if (events.handle(self, hwnd, msg, wp, lp)) |r| return r;
        if (msg == WM_PARENTNOTIFY and wp & 0xFFFF == 1) if (self.caption != null) {
            // A child came (a page's view): the caption goes above it, once it is made.
            _ = w.PostMessageW(hwnd, WM_RAISE_CAPTION, 0, 0);
        };
        if (msg == WM_RAISE_CAPTION) {
            if (self.caption) |c| c.layout();
            return 0;
        }
        if (msg == w.WM_GETMINMAXINFO) {
            // MINMAXINFO: ptMinTrackSize is its fourth POINT.
            const pts: [*]w.POINT = @ptrFromInt(@as(usize, @bitCast(lp)));
            const s = self.dpiScale();
            pts[3] = .{ .x = @intFromFloat(self.min_width * s), .y = @intFromFloat(self.min_height * s) };
            return 0;
        }
        switch (msg) {
            // A menu bar's item (not an accelerator's, nor a control's).
            appwnd.WM_COMMAND => if (lp == 0 and (wp >> 16) & 0xFFFF == 0) {
                self.app.menuCommand(self, wp & 0xFFFF);
                return 0;
            },
            appwnd.WM_INITMENUPOPUP => if (self.app.main_menu) |m| {
                menubar.refresh(m, @ptrFromInt(wp));
                return 0;
            },
            extras.WM_DROPFILES => if (self.on_drop) |cb| {
                const paths = extras.droppedFiles(self.app.gpa, @ptrFromInt(wp)) catch return 0;
                defer extras.freePaths(self.app.gpa, paths);
                cb.func(cb.ctx, self, @ptrCast(paths));
                return 0;
            },
            w.WM_CLOSE => self.rememberState(),
            else => {},
        }
        if (msg == WM_SEND and lp != 0) {
            const sent: *Sent = @ptrFromInt(@as(usize, @bitCast(lp)));
            defer self.app.gpa.destroy(sent);
            defer self.app.gpa.free(sent.msg);
            if (self.page) |p| p.enqueue(sent.msg, true);
            for (self.web_views.items) |p| p.enqueue(sent.msg, true);
            return 0;
        }
        if (self.page) |p| switch (msg) {
            w.WM_SIZE => p.resize(),
            w.WM_SETFOCUS => p.focus(),
            page_mod.WM_FLUSH => {
                p.flush();
                return 0;
            },
            else => {},
        };
        if (self.surface) |s| if (s.handle(hwnd, msg, wp, lp)) |r| return r;
        return w.DefWindowProcW(hwnd, msg, wp, lp);
    }

    pub fn dpiScale(self: *Window) f64 {
        const h = self.hwnd orelse return 1;
        const dpi = w.GetDpiForWindow(h);
        return if (dpi > 0) @as(f64, @floatFromInt(dpi)) / 96 else 1;
    }

    /// Records the window's state under its key, before it goes.
    fn rememberState(self: *Window) void {
        const h = self.hwnd orelse return;
        const k = self.state orelse return;
        k.put(self.app, extras.state(h, self.style, menubar.GetMenu(h) != null, self.dpiScale()));
    }

    fn finish(self: *Window) void {
        if (self.closed) return;
        self.closed = true;
        if (self.on_close) |cb| cb.func(cb.ctx, self);
        if (self.caption) |c| c.destroy(self.app.gpa);
        self.caption = null;
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
        if (self.hwnd) |h| _ = w.DestroyWindow(h) else self.finish();
    }

    pub fn minimize(self: *Window) void {
        if (self.hwnd) |h| _ = w.ShowWindow(h, 6);
    }

    pub fn zoom(self: *Window) void {
        const h = self.hwnd orelse return;
        _ = w.ShowWindow(h, if (w.IsZoomed(h) != 0) 9 else 3);
    }

    pub fn frame(self: *Window) Frame {
        const h = self.hwnd orelse return .{ .x = 0, .y = 0, .width = self.width, .height = self.height };
        var r: w.RECT = .{};
        _ = w.GetWindowRect(h, &r);
        const s = self.dpiScale();
        return .{ .x = @as(f64, @floatFromInt(r.left)) / s, .y = @as(f64, @floatFromInt(r.top)) / s, .width = @as(f64, @floatFromInt(r.right - r.left)) / s, .height = @as(f64, @floatFromInt(r.bottom - r.top)) / s };
    }

    pub fn contentSize(self: *Window) [2]f64 {
        const s = self.surface orelse return .{ self.width, self.height };
        return .{ s.size.w, s.size.h };
    }

    /// Sizes the window so its client area is `width` × `height` points.
    pub fn setSize(self: *Window, width: f64, height: f64) void {
        const h = self.hwnd orelse return;
        const s = self.dpiScale();
        var r: w.RECT = .{ .right = @intFromFloat(width * s), .bottom = @intFromFloat(height * s) };
        if (self.flyout != null) {
            self.width = width;
            self.height = height;
            return self.placeFlyout();
        }
        if (self.captionless()) {
            // Its side and bottom borders, without the caption (frame.zig).
            if (self.style & w.WS_THICKFRAME != 0) {
                _ = w.AdjustWindowRectEx(&r, self.style & ~@as(u32, gdi.WS_CAPTION), 0, 0);
                r.top = if (self.title_bar == .hidden and gdi.windows11()) -1 else 0;
            }
        } else _ = w.AdjustWindowRectEx(&r, self.style, @intFromBool(menubar.GetMenu(h) != null), 0);
        _ = w.SetWindowPos(h, null, 0, 0, r.right - r.left, r.bottom - r.top, 0x0002 | 0x0004); // no move, no z-order
    }

    pub fn setPosition(self: *Window, x: f64, y: f64) void {
        const h = self.hwnd orelse return;
        const s = self.dpiScale();
        _ = w.SetWindowPos(h, null, @intFromFloat(x * s), @intFromFloat(y * s), 0, 0, 0x0001 | 0x0004); // no size, no z-order
    }

    pub fn center(self: *Window) void {
        const h = self.hwnd orelse return;
        var r: w.RECT = .{};
        _ = w.GetWindowRect(h, &r);
        const sw = w.GetSystemMetrics(0);
        const sh = w.GetSystemMetrics(1);
        _ = w.SetWindowPos(h, null, @divTrunc(sw - (r.right - r.left), 2), @divTrunc(sh - (r.bottom - r.top), 2), 0, 0, 0x0001 | 0x0004);
    }

    pub fn setMinSize(self: *Window, width: f64, height: f64) void {
        self.min_width = width;
        self.min_height = height;
    }

    pub fn setResizable(self: *Window, on: bool) void {
        _ = self;
        _ = on;
    }

    pub fn setAlwaysOnTop(self: *Window, on: bool) void {
        const h = self.hwnd orelse return;
        const topmost: isize = if (on) -1 else -2;
        _ = w.SetWindowPos(h, @ptrFromInt(@as(usize, @bitCast(topmost))), 0, 0, 0, 0, 0x0001 | 0x0002);
    }

    pub fn isFullScreen(self: *Window) bool {
        return self.full_screen;
    }

    pub fn setFullScreen(self: *Window, on: bool) void {
        self.full_screen = on;
        if (self.hwnd) |h| _ = w.ShowWindow(h, if (on) 3 else 9);
        if (self.caption) |c| c.layout();
    }

    pub fn show(self: *Window) void {
        const h = self.hwnd orelse return;
        if (self.flyout) |f| {
            self.placeFlyout();
            if (!f.focusable) {
                _ = w.ShowWindow(h, 8); // SW_SHOWNA
                return;
            }
        }
        _ = w.ShowWindow(h, 5);
        _ = w.SetForegroundWindow(h);
        _ = w.SetFocus(h);
    }

    pub fn hide(self: *Window) void {
        if (self.hwnd) |h| _ = w.ShowWindow(h, 0);
    }

    pub fn isVisible(self: *Window) bool {
        const h = self.hwnd orelse return false;
        return w.IsWindowVisible(h) != 0;
    }

    pub fn focus(self: *Window) void {
        if (self.hwnd) |h| _ = w.SetForegroundWindow(h);
    }

    pub fn isFocused(self: *Window) bool {
        const h = self.hwnd orelse return false;
        return w.GetForegroundWindow() == h;
    }

    pub fn redraw(self: *Window) void {
        if (self.surface) |s| s.requestFrame();
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        self.storeTitle(title);
        self.applyTitle();
    }

    /// Sends `msg` (allocated with the app's allocator, which this frees)
    /// to the page, from any thread: the window's thread enqueues it.
    pub fn sendOwned(self: *Window, msg: []u8) void {
        const gpa = self.app.gpa;
        const h = self.hwnd orelse return gpa.free(msg);
        const sent = gpa.create(Sent) catch return gpa.free(msg);
        sent.* = .{ .msg = msg };
        if (w.PostMessageW(h, WM_SEND, 0, @bitCast(@intFromPtr(sent))) == 0) {
            gpa.free(msg);
            gpa.destroy(sent);
        }
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
