//! Windows: an NSWindow showing either a web page (WKWebView) or native UI
//! drawn by myzig with Metal.
const std = @import("std");
const objc = @import("objc.zig");
const App = @import("app.zig").App;
const Page = @import("page.zig").Page;
const ui = @import("ui/ui.zig");
const Surface = @import("ui/surface.zig").Surface;
const extras = @import("window_extras_mac.zig");
const events = @import("window_mac_events.zig");
const fly = @import("flyout.zig");

const window_types = @import("window_types.zig");
pub const Asset = window_types.Asset;
pub const PageOptions = window_types.PageOptions;
pub const Content = window_types.Content;
pub const TitleBar = window_types.TitleBar;
pub const Callback = window_types.Callback(Window);
pub const Options = window_types.Options(Window);
pub const NativeView = window_types.NativeView;

pub const Window = struct {
    app: *App,
    nswindow: objc.Object,
    delegate: objc.Object,
    page: ?*Page = null,
    /// Pages inside its native UI (`ui.webView`).
    web_views: std.ArrayList(*Page) = .empty,
    surface: ?*Surface = null,
    title_bar: TitleBar = .default,
    hide_window_buttons: bool = false,
    on_close: ?Callback = null,
    closed: bool = false,
    on_drop: ?window_types.DropCallback(Window) = null,
    state: ?window_types.StateKey = null,
    on_close_request: ?window_types.CloseRequest(Window) = null,
    on_event: ?window_types.EventCallback(Window) = null,
    tracker: window_types.Tracker = .{},
    title_bar_height: f64 = 0,
    flyout: ?fly.State = null,
    flyout_size: [2]f64 = .{ 0, 0 },
    /// A flyout shown as the system's popover (`fly.State.popover`).
    popover: ?*@import("popover_mac.zig").Popover = null,
    /// A popover's panel, hidden, which made its content: `nswindow`
    /// while the popover does not show (it is the popover's window while
    /// it does).
    host: ?objc.Object = null,

    pub fn create(app: *App, requested: Options) !*Window {
        const restored = window_types.restore(app, requested);
        const options = restored[0];
        const pool = objc.Pool.push();
        defer pool.pop();
        const self = try app.gpa.create(Window);
        errdefer app.gpa.destroy(self);

        const style = events.styleMask(options);
        const rect: objc.CGRect = .{ .size = .{ .width = options.width, .height = options.height } };
        const alloced = if (options.flyout != null) objc.msg(objc.Object, events.flyoutClass(), "alloc", .{}) else objc.alloc("NSWindow");
        const nswindow = objc.msg(objc.Object, alloced, "initWithContentRect:styleMask:backing:defer:", .{
            rect, style, @as(objc.NSUInteger, 2), objc.NO,
        });
        objc.msg(void, nswindow, "setReleasedWhenClosed:", .{objc.NO});
        objc.msg(void, nswindow, "setTitle:", .{objc.nsString(options.title)});
        objc.msg(void, nswindow, "setContentMinSize:", .{objc.CGSize{ .width = options.min_width, .height = options.min_height }});
        events.setUp(nswindow, options);

        const delegate_class = objc.defineClass(.{
            .name = "MyZigWindowDelegate",
            .protocols = &.{"NSWindowDelegate"},
            .methods = &([_]objc.Method{
                .{ .name = "windowWillClose:", .imp = &windowWillClose, .types = "v@:@" },
                .{ .name = "windowDidChangeOcclusionState:", .imp = &occlusionChanged, .types = "v@:@" },
            } ++ comptime extras.dropMethods(&draggingEntered, &performDrag) ++ events.methods),
        });
        const delegate = objc.msg(objc.Object, delegate_class, "new", .{});
        objc.setZig(delegate, self);
        objc.msg(void, nswindow, "setDelegate:", .{delegate});

        self.* = .{ .app = app, .nswindow = nswindow, .delegate = delegate, .title_bar = options.title_bar, .hide_window_buttons = options.hide_window_buttons, .on_close = options.on_close, .on_drop = options.on_drop, .state = options.state, .on_close_request = options.on_close_request, .on_event = options.on_event, .title_bar_height = options.title_bar_height, .flyout = options.flyout, .flyout_size = .{ options.width, options.height } };

        switch (options.content) {
            .page => |p| self.page = try Page.create(self, p),
            .view => |v| self.surface = try Surface.create(self, v, options.theme),
        }

        if (options.flyout) |f| if (events.wantsPopover(f)) {
            errdefer self.close();
            try events.makePopover(self);
            if (!app.flags.hidden and options.visible) events.showPopover(self);
            return self;
        };
        if (options.flyout != null) {
            events.placeFlyout(self);
        } else if (options.x != null and options.y != null) self.setPosition(options.x.?, options.y.?) else objc.msg(void, nswindow, "center", .{});
        if (options.always_on_top) self.setAlwaysOnTop(true);
        if (options.on_drop != null) extras.acceptDrops(nswindow);
        if (options.material != .none) _ = extras.setMaterial(nswindow, options.material);
        if (options.flyout) |f| if (f.radius > 0) events.roundFlyout(nswindow, f.radius);
        if (restored[1] and !self.isMaximized()) self.zoom();
        if (!app.flags.hidden and options.visible) objc.msg(void, nswindow, "makeKeyAndOrderFront:", .{@as(?objc.Object, null)});
        if (app.debug) self.logFrame();
        return self;
    }

    /// Logs the window's number and frame in screen points, top left origin.
    pub fn logFrame(self: *Window) void {
        const f = objc.msg(objc.CGRect, self.nswindow, "frame", .{});
        const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
        const primary = objc.msg(objc.Object, screens, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
        const sh = objc.msg(objc.CGRect, primary, "frame", .{}).size.height;
        const num = objc.msg(objc.NSInteger, self.nswindow, "windowNumber", .{});
        std.debug.print("myzig: window id={d} frame={d:.0},{d:.0},{d:.0},{d:.0}\n", .{
            num, f.origin.x, sh - f.origin.y - f.size.height, f.size.width, f.size.height,
        });
    }

    /// Closes the window; it is freed once AppKit is done with it.
    pub fn close(self: *Window) void {
        if (self.closed) return;
        objc.msg(void, self.host orelse self.nswindow, "close", .{});
    }

    /// Closes the window as the user would, asking `on_close_request`.
    pub fn requestClose(self: *Window) void {
        if (self.closed or !events.mayClose(self)) return;
        if (self.flyout) |f| if (f.dismiss == .hide) return self.hide();
        self.close();
    }

    /// The room the traffic lights take over a hidden title bar's content.
    pub fn titleBar(self: *Window) window_types.TitleBarArea {
        return events.titleBar(self);
    }

    /// How far down native UI's empty space moves the window (the surface's).
    pub fn dragHeight(self: *Window, view: f32) f32 {
        return events.dragHeight(self, view);
    }

    /// Moves the window with the pointer, from a press on the content's
    /// own title bar (a drag region).
    pub fn startDrag(self: *Window) void {
        events.startDrag(self);
    }

    /// Windows 11's snap layouts: macOS has its own, on the green button.
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

    /// Shows a task's progress on the app's Dock icon (the Dock has one
    /// icon for the app: the last window's progress shows).
    pub fn setProgress(self: *Window, p: window_types.Progress) bool {
        return @import("dock_mac.zig").setProgress(self.app.nsapp, p);
    }

    /// Bounces the app's Dock icon while it is not active, or stops.
    pub fn flash(self: *Window, on: bool) void {
        events.requestAttention(self.app.nsapp, on);
    }

    /// A dot in the close button: the document has unsaved changes.
    pub fn setDocumentEdited(self: *Window, edited: bool) void {
        objc.msg(void, self.nswindow, "setDocumentEdited:", .{edited});
    }

    pub fn isDocumentEdited(self: *Window) bool {
        return objc.msg(objc.BOOL, self.nswindow, "isDocumentEdited", .{});
    }

    /// The file the window shows: its icon in the title bar, which the
    /// user can drag, and Command-click for the folders it is in.
    pub fn setRepresentedFile(self: *Window, path: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        objc.msg(void, self.nswindow, "setRepresentedFilename:", .{objc.nsString(path)});
    }

    pub fn isMinimized(self: *Window) bool {
        return objc.msg(objc.BOOL, self.nswindow, "isMiniaturized", .{});
    }

    pub fn minimize(self: *Window) void {
        objc.msg(void, self.nswindow, "miniaturize:", .{@as(?objc.Object, null)});
    }

    pub fn zoom(self: *Window) void {
        objc.msg(void, self.nswindow, "zoom:", .{@as(?objc.Object, null)});
    }

    pub const Frame = struct { x: f64, y: f64, width: f64, height: f64 };

    /// The window's frame in screen points from the primary screen's top left.
    pub fn frame(self: *Window) Frame {
        const f = objc.msg(objc.CGRect, self.nswindow, "frame", .{});
        return .{ .x = f.origin.x, .y = primaryHeight() - f.origin.y - f.size.height, .width = f.size.width, .height = f.size.height };
    }

    /// The size of the window's content, without its title bar.
    pub fn contentSize(self: *Window) [2]f64 {
        const v = objc.msg(objc.Object, self.nswindow, "contentView", .{});
        const b = objc.msg(objc.CGRect, v, "bounds", .{});
        return .{ b.size.width, b.size.height };
    }

    /// Resizes the content to `width` × `height` points, keeping the top left.
    pub fn setSize(self: *Window, width: f64, height: f64) void {
        if (self.flyout != null) {
            self.flyout_size = .{ width, height };
            return events.placeFlyout(self);
        }
        const f = objc.msg(objc.CGRect, self.nswindow, "frame", .{});
        const content = objc.msg(objc.CGRect, self.nswindow, "contentRectForFrameRect:", .{f});
        const want = objc.msg(objc.CGRect, self.nswindow, "frameRectForContentRect:", .{objc.CGRect{ .origin = content.origin, .size = .{ .width = width, .height = height } }});
        const top = f.origin.y + f.size.height;
        const r: objc.CGRect = .{ .origin = .{ .x = f.origin.x, .y = top - want.size.height }, .size = want.size };
        objc.msg(void, self.nswindow, "setFrame:display:animate:", .{ r, objc.YES, objc.NO });
    }

    /// Moves the window's top left to `x`, `y` (points from the primary screen's top left).
    pub fn setPosition(self: *Window, x: f64, y: f64) void {
        objc.msg(void, self.nswindow, "setFrameTopLeftPoint:", .{objc.CGPoint{ .x = x, .y = primaryHeight() - y }});
    }

    pub fn center(self: *Window) void {
        objc.msg(void, self.nswindow, "center", .{});
    }

    pub fn setMinSize(self: *Window, width: f64, height: f64) void {
        objc.msg(void, self.nswindow, "setContentMinSize:", .{objc.CGSize{ .width = width, .height = height }});
    }

    pub fn setResizable(self: *Window, on: bool) void {
        var mask = objc.msg(objc.NSUInteger, self.nswindow, "styleMask", .{});
        mask = if (on) mask | 8 else mask & ~@as(objc.NSUInteger, 8);
        objc.msg(void, self.nswindow, "setStyleMask:", .{mask});
    }

    /// Keeps the window above other apps' windows.
    pub fn setAlwaysOnTop(self: *Window, on: bool) void {
        objc.msg(void, self.nswindow, "setLevel:", .{@as(objc.NSInteger, if (on) 3 else 0)}); // NSFloatingWindowLevel
    }

    pub fn isMaximized(self: *Window) bool {
        return objc.msg(objc.BOOL, self.nswindow, "isZoomed", .{});
    }

    /// Puts the system's material (vibrancy) behind the window's content.
    pub fn setMaterial(self: *Window, material: window_types.Material) bool {
        return extras.setMaterial(self.nswindow, material);
    }

    /// Records the window's state under its key, before it goes.
    fn rememberState(self: *Window) void {
        const k = self.state orelse return;
        const f = self.frame();
        const c = self.contentSize();
        k.put(self.app, .{ .x = f.x, .y = f.y, .width = c[0], .height = c[1], .maximized = self.isMaximized() });
    }

    pub fn isFullScreen(self: *Window) bool {
        return objc.msg(objc.NSUInteger, self.nswindow, "styleMask", .{}) & (1 << 14) != 0;
    }

    pub fn setFullScreen(self: *Window, on: bool) void {
        if (on != self.isFullScreen()) objc.msg(void, self.nswindow, "toggleFullScreen:", .{@as(?objc.Object, null)});
    }

    pub fn show(self: *Window) void {
        if (self.popover != null) return events.showPopover(self);
        if (self.flyout) |f| {
            events.placeFlyout(self);
            // One that is not focusable never takes the keyboard.
            if (!f.focusable) return objc.msg(void, self.nswindow, "orderFrontRegardless", .{});
        }
        objc.msg(void, self.nswindow, "makeKeyAndOrderFront:", .{@as(?objc.Object, null)});
    }

    pub fn hide(self: *Window) void {
        if (self.popover != null) return events.hidePopover(self);
        objc.msg(void, self.nswindow, "orderOut:", .{@as(?objc.Object, null)});
    }

    pub fn isVisible(self: *Window) bool {
        if (self.popover) |p| return p.isShown();
        return objc.msg(objc.BOOL, self.nswindow, "isVisible", .{});
    }

    /// Brings the window and its app to the front.
    pub fn focus(self: *Window) void {
        objc.msg(void, self.app.nsapp, "activateIgnoringOtherApps:", .{objc.YES});
        self.show();
    }

    pub fn isFocused(self: *Window) bool {
        return objc.msg(objc.BOOL, self.nswindow, "isKeyWindow", .{});
    }

    /// Draws native UI again at the next refresh, for state changed from
    /// outside its events (a timer, a process's output). Main thread.
    /// What `--myzig-snapshot` draws of this window, if it shows native UI.
    pub fn nativeView(self: *Window) ?NativeView {
        const s = self.surface orelse return null;
        return .{ .view = s.view, .width = s.size.w, .height = s.size.h, .scale = s.scale, .theme = s.theme_override };
    }

    pub fn redraw(self: *Window) void {
        if (self.surface) |s| s.requestFrame();
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        objc.msg(void, self.nswindow, "setTitle:", .{objc.nsString(title)});
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

    /// Queues an encoded message for the page and takes ownership of it.
    /// Safe from any thread.
    pub fn sendOwned(self: *Window, msg: []u8) void {
        if (objc.isMainThread()) {
            defer self.app.gpa.free(msg);
            if (self.page) |p| p.enqueue(msg, true);
            for (self.web_views.items) |p| p.enqueue(msg, true);
            return;
        }
        const job = self.app.gpa.create(Job) catch return self.app.gpa.free(msg);
        job.* = .{ .window = self, .msg = msg };
        objc.dispatchMain(job, Job.run);
    }

    const Job = struct {
        window: *Window,
        msg: []u8,
        fn run(ctx: ?*anyopaque) callconv(.c) void {
            const job: *Job = @ptrCast(@alignCast(ctx));
            const w = job.window;
            const gpa = w.app.gpa;
            defer gpa.destroy(job);
            // The window may have closed meanwhile.
            for (w.app.windows.items) |live| if (live == w) return w.sendOwned(job.msg);
            gpa.free(job.msg);
        }
    };

    fn teardown(self: *Window) void {
        self.closed = true;
        if (self.on_close) |cb| cb.func(cb.ctx, self);
        events.destroyPopover(self);
        while (self.web_views.items.len > 0) self.web_views.items[self.web_views.items.len - 1].destroy();
        self.web_views.deinit(self.app.gpa);
        if (self.page) |p| p.destroy();
        if (self.surface) |s| s.destroy();
        self.page = null;
        self.surface = null;
        objc.setZig(self.delegate, null);
        objc.msg(void, self.nswindow, "setDelegate:", .{@as(?objc.Object, null)});
        // AppKit still uses both while closing.
        objc.autorelease(self.delegate);
        objc.autorelease(self.nswindow);
        const app = self.app;
        app.removeWindow(self);
        app.gpa.destroy(self);
    }
};

fn primaryHeight() f64 {
    const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    if (objc.msg(objc.NSUInteger, screens, "count", .{}) == 0) return 0;
    const primary = objc.msg(objc.Object, screens, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
    return objc.msg(objc.CGRect, primary, "frame", .{}).size.height;
}

fn occlusionChanged(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const w = objc.getZig(Window, self_obj) orelse return;
    if (w.surface) |s| s.occlusionChanged();
}

fn windowWillClose(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const w = objc.getZig(Window, self_obj) orelse return;
    w.rememberState();
    w.teardown();
}

fn draggingEntered(self_obj: objc.Object, _: objc.SEL, info: objc.Object) callconv(.c) objc.NSUInteger {
    const w = objc.getZig(Window, self_obj) orelse return 0;
    if (w.on_drop == null) return 0;
    return extras.dragOperation(info);
}

fn performDrag(self_obj: objc.Object, _: objc.SEL, info: objc.Object) callconv(.c) objc.BOOL {
    const w = objc.getZig(Window, self_obj) orelse return objc.NO;
    const cb = w.on_drop orelse return objc.NO;
    const paths = extras.droppedFiles(w.app.gpa, info) orelse return objc.NO;
    defer extras.freePaths(w.app.gpa, paths);
    cb.func(cb.ctx, w, @ptrCast(paths));
    return objc.YES;
}
