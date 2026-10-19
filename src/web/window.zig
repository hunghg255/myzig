//! Windows in a browser: each is a canvas the host puts on the page (in
//! the element with the ID `myzig`, else the body), filling it; a window
//! opened later covers the earlier ones. The page sets its size, so the
//! size, position and title bar options do nothing; the title of the
//! window shown last is the page's. Windows of web pages have nothing in
//! a browser to stand for them: `.page` content is unsupported.
const std = @import("std");
const js = @import("js.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Surface = @import("surface.zig").Surface;
const window_types = @import("../window_types.zig");
const ui = @import("../ui/ui.zig");
const menu_mod = @import("../menu_accel.zig");

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
    surface: ?*Surface = null,
    on_close: ?Callback = null,
    closed: bool = false,
    visible: bool = false,
    full_screen: bool = false,
    view: ?ui.View = null,
    width: f64 = 0,
    height: f64 = 0,
    theme: ?ui.Theme = null,
    on_drop: ?window_types.DropCallback(Window) = null,

    pub fn create(app: *App, options: Options) !*Window {
        const view = switch (options.content) {
            .view => |v| v,
            // No web view inside a web page.
            .page => return error.Unsupported,
        };
        const self = try app.gpa.create(Window);
        errdefer app.gpa.destroy(self);
        self.* = .{ .app = app, .on_close = options.on_close, .view = view, .width = options.width, .height = options.height, .theme = options.theme, .on_drop = options.on_drop };
        // The page's canvas only when the app runs live (not `--myzig-snapshot`).
        if (!app.gui) return self;
        self.surface = try Surface.create(self, view, options.theme);
        js.window_open(self.id(), options.title.ptr, options.title.len);
        self.visible = true;
        return self;
    }

    /// The window as the host knows it: its address.
    pub fn id(self: *Window) u32 {
        return @intCast(@intFromPtr(self));
    }

    pub fn of(window_id: u32) *Window {
        return @ptrFromInt(window_id);
    }

    pub fn setMenuBar(_: *Window, _: *menu_mod.Menu) void {}

    pub fn isMaximized(_: *Window) bool {
        return true;
    }

    pub fn setMaterial(_: *Window, _: window_types.Material) bool {
        return false;
    }

    pub fn close(self: *Window) void {
        if (self.closed) return;
        self.closed = true;
        if (self.on_close) |cb| cb.func(cb.ctx, self);
        if (self.surface) |s| {
            app_mod.cancelFrames(s);
            js.window_close(self.id());
            s.destroy();
        }
        self.surface = null;
        const app = self.app;
        app.removeWindow(self);
        app.gpa.destroy(self);
    }

    pub fn minimize(_: *Window) void {}
    pub fn zoom(_: *Window) void {}

    pub fn frame(self: *Window) Frame {
        const size = self.contentSize();
        return .{ .x = 0, .y = 0, .width = size[0], .height = size[1] };
    }

    pub fn contentSize(self: *Window) [2]f64 {
        const s = self.surface orelse return .{ self.width, self.height };
        if (s.size.w <= 0) return .{ self.width, self.height };
        return .{ s.size.w, s.size.h };
    }

    /// The page sizes the canvas: these do nothing.
    pub fn setSize(_: *Window, _: f64, _: f64) void {}
    pub fn setPosition(_: *Window, _: f64, _: f64) void {}
    pub fn center(_: *Window) void {}
    pub fn setMinSize(_: *Window, _: f64, _: f64) void {}
    pub fn setResizable(_: *Window, _: bool) void {}
    pub fn setAlwaysOnTop(_: *Window, _: bool) void {}

    pub fn isFullScreen(self: *Window) bool {
        return self.full_screen;
    }

    pub fn setFullScreen(self: *Window, on: bool) void {
        self.full_screen = on;
    }

    pub fn show(self: *Window) void {
        self.visible = true;
    }

    pub fn hide(self: *Window) void {
        self.visible = false;
    }

    pub fn isVisible(self: *Window) bool {
        return self.visible;
    }

    pub fn focus(_: *Window) void {}

    pub fn isFocused(self: *Window) bool {
        const s = self.surface orelse return false;
        return s.focused;
    }

    pub fn redraw(self: *Window) void {
        if (self.surface) |s| s.requestFrame();
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        if (self.surface != null) js.window_title(self.id(), title.ptr, title.len);
    }

    /// No page to send to.
    pub fn sendOwned(self: *Window, msg: []u8) void {
        self.app.gpa.free(msg);
    }

    pub fn loadUrl(_: *Window, _: []const u8) void {}

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
