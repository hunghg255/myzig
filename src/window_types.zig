//! What windows are made of, the same on every platform: their options,
//! a page's or a native view's content, and the files pages are served.
const std = @import("std");
const ui = @import("ui/ui.zig");
const page_types = @import("page_types.zig");

/// A file served to pages at `myzig://localhost<path>`.
pub const Asset = struct {
    path: []const u8,
    data: []const u8,
    mime: ?[]const u8 = null,
};

pub const PageOptions = struct {
    /// Relative URLs resolve against `myzig://localhost/`, served from
    /// `assets`; absolute URLs (`http://localhost:5173`) load as is.
    url: []const u8 = "/",
    assets: []const Asset = &.{},
    /// A directory whose files `myzig://localhost/` serves before
    /// `assets`: a built frontend on disk, or one being worked on. The
    /// MYZIG_ASSETS_DIR environment variable overrides it.
    assets_dir: ?[]const u8 = null,
    /// A dev server (`http://localhost:5173`) loaded instead of the
    /// frontend's paths, and trusted. MYZIG_DEV_URL overrides it.
    dev_url: ?[]const u8 = null,
    /// Origins besides the app's own whose pages may call bound services
    /// and get permissions ("https://example.com"; "*" trusts every one).
    /// The app's schemes, file: and about: pages and the dev server
    /// always may.
    trusted_origins: []const []const u8 = &.{},
    /// Schemes the app serves pages, besides `myzig://` (`page_types.Scheme`).
    schemes: []const page_types.Scheme = &.{},
    /// Scripts every document runs, after the bridge.
    user_scripts: []const page_types.UserScript = &.{},
    zoom: f64 = 1,
    user_agent: ?[]const u8 = null,
    /// Appended to the user agent after a space, instead of replacing it
    /// as `user_agent` does: the app's name and version ("MyApp/1.2"),
    /// for the sites that read them. It appends to `user_agent` too, and
    /// `Page.setUserAgent` keeps it; spaces around it are trimmed. Some
    /// sites serve a bare web view, whose user agent names no browser,
    /// older pages: "Version/17.0 Safari/605.1.15" makes it look like Safari.
    user_agent_suffix: []const u8 = "",
    /// Tab moves only between text fields and elements with a tabindex,
    /// as in Safari while the system's keyboard navigation is off (macOS).
    /// By default Tab reaches links, buttons, checkboxes and selects too,
    /// as it does in Chrome, Edge, WebKitGTK and WebView2.
    safari_tab_focus: bool = false,
    /// Web Inspector (right click > Inspect Element).
    inspectable: bool = true,
    /// Hears the page's events and answers its questions (`PageEvent`).
    on_event: ?page_types.PageListener = null,
};

pub const Content = union(enum) {
    page: PageOptions,
    view: ui.View,
};

pub const TitleBar = enum {
    default,
    /// The content fills the window, under the system's window controls:
    /// macOS's traffic lights, Windows 11's caption buttons over the top
    /// right corner (with snap layouts on maximize), GTK's title buttons.
    /// Native UI keeps clear of them with `Window.titleBar`, and the
    /// window moves by the empty space of its top `title_bar_height`.
    hidden,
    /// No title bar and no controls: the content draws all of it, and
    /// moves the window by its drag regions (`Window.startDrag`). The
    /// window still resizes from its edges, and keeps its shadow.
    frameless,
};

/// The room the system's window controls take over the content of a
/// window with a hidden title bar, in points: its height, and the widths
/// they cover on the left (macOS) and on the right (Windows, GTK).
pub const TitleBarArea = struct { height: f64 = 0, left: f64 = 0, right: f64 = 0 };

pub const Point = struct { x: f64, y: f64 };
pub const Size = struct { width: f64, height: f64 };

/// What happens to a window (`Options.on_event`), on the main thread.
pub const Event = union(enum) {
    /// It took the keyboard, or lost it.
    focus,
    blur,
    /// Its top left moved, in screen points.
    moved: Point,
    /// Its content changed size, in points.
    resized: Size,
    minimized,
    maximized,
    /// Back from minimized or maximized.
    restored,
};

/// Follows a window's state, and tells what changed: the systems repeat
/// sizes and activations that change nothing.
pub const Tracker = struct {
    shown: enum { normal, minimized, maximized } = .normal,
    focused: bool = false,
    size: Size = .{ .width = -1, .height = -1 },
    pos: Point = .{ .x = -1e9, .y = -1e9 },

    /// The event of the window's new state, if it is one.
    pub fn sized(t: *Tracker, minimized: bool, maximized: bool, size: Size) ?Event {
        const now: @TypeOf(t.shown) = if (minimized) .minimized else if (maximized) .maximized else .normal;
        if (now != t.shown) {
            const was = t.shown;
            t.shown = now;
            if (now != .minimized) t.size = size;
            return switch (now) {
                .minimized => .minimized,
                .maximized => .maximized,
                .normal => if (was == .normal) null else .restored,
            };
        }
        if (minimized or (size.width == t.size.width and size.height == t.size.height)) return null;
        t.size = size;
        return .{ .resized = size };
    }

    pub fn moved(t: *Tracker, p: Point) ?Event {
        if (p.x == t.pos.x and p.y == t.pos.y) return null;
        t.pos = p;
        return .{ .moved = p };
    }

    pub fn focus(t: *Tracker, on: bool) ?Event {
        if (on == t.focused) return null;
        t.focused = on;
        return if (on) .focus else .blur;
    }
};

/// A progress shown on the window's taskbar button (Windows), the app's
/// Dock icon (macOS) or its launcher entry (Linux docks with the Unity
/// launcher API).
pub const Progress = struct {
    state: State = .none,
    /// From 0 to 1.
    value: f64 = 0,

    pub const State = enum { none, normal, indeterminate, paused, failed };
};

/// Asked before the window closes as the user closes it (its close
/// button, Alt+F4, the Dock's or taskbar's Close, `Window.requestClose`):
/// false keeps it open. `Window.close` does not ask.
pub fn CloseRequest(comptime Window: type) type {
    return struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, window: *Window) bool,

        pub fn of(ptr: anytype, comptime func: fn (@TypeOf(ptr), *Window) bool) @This() {
            const P = @TypeOf(ptr);
            return .{ .ctx = @ptrCast(ptr), .func = struct {
                fn call(c: *anyopaque, win: *Window) bool {
                    return func(@as(P, @ptrCast(@alignCast(c))), win);
                }
            }.call };
        }
    };
}

pub fn EventCallback(comptime Window: type) type {
    return struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, window: *Window, event: Event) void,

        pub fn of(ptr: anytype, comptime func: fn (@TypeOf(ptr), *Window, Event) void) @This() {
            const P = @TypeOf(ptr);
            return .{ .ctx = @ptrCast(ptr), .func = struct {
                fn call(c: *anyopaque, win: *Window, e: Event) void {
                    func(@as(P, @ptrCast(@alignCast(c))), win, e);
                }
            }.call };
        }
    };
}

/// The title a window shows for an edited document where the title bar
/// has no mark of its own (Linux, Windows): "*" before it, as Notepad
/// and gedit show it.
pub fn editedTitle(buf: []u8, title: []const u8, edited: bool) []const u8 {
    if (!edited or buf.len == 0) return title[0..@min(title.len, buf.len)];
    const n = @min(title.len, buf.len - 1);
    buf[0] = '*';
    @memcpy(buf[1 .. 1 + n], title[0..n]);
    return buf[0 .. 1 + n];
}

test "an edited document's title" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("Notes", editedTitle(&buf, "Notes", false));
    try std.testing.expectEqualStrings("*Notes", editedTitle(&buf, "Notes", true));
    try std.testing.expectEqualStrings("*Untitle", editedTitle(&buf, "Untitled 1", true));
}

test "a window's state changes become events once" {
    var t: Tracker = .{};
    const s: Size = .{ .width = 800, .height = 600 };
    try std.testing.expectEqual(Event{ .resized = s }, t.sized(false, false, s).?);
    try std.testing.expect(t.sized(false, false, s) == null);
    try std.testing.expectEqual(Event.minimized, t.sized(true, false, .{ .width = 0, .height = 0 }).?);
    try std.testing.expectEqual(Event.restored, t.sized(false, false, s).?);
    try std.testing.expectEqual(Event.maximized, t.sized(false, true, .{ .width = 1920, .height = 1000 }).?);
    try std.testing.expectEqual(Event.restored, t.sized(false, false, s).?);
    try std.testing.expectEqual(Event.focus, t.focus(true).?);
    try std.testing.expect(t.focus(true) == null);
    try std.testing.expectEqual(Event{ .moved = .{ .x = 3, .y = 4 } }, t.moved(.{ .x = 3, .y = 4 }).?);
    try std.testing.expect(t.moved(.{ .x = 3, .y = 4 }) == null);
}

pub fn Callback(comptime Window: type) type {
    return struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, window: *Window) void,
    };
}

pub fn Options(comptime Window: type) type {
    return struct {
        title: []const u8 = "",
        width: f64 = 800,
        height: f64 = 600,
        min_width: f64 = 200,
        min_height: f64 = 150,
        resizable: bool = true,
        title_bar: TitleBar = .default,
        /// With a hidden title bar, the view draws its own window controls.
        /// Keeps the window's resizing edges. Ignored by browsers.
        hide_window_buttons: bool = false,
        /// The height of the title bar a window with a hidden one draws:
        /// Windows' caption buttons fill it, the empty space in it moves
        /// the window. 0 is the system's (32 on Windows, 28 elsewhere).
        title_bar_height: f64 = 0,
        /// Out of the taskbar and the app switcher (Linux, Windows).
        skip_taskbar: bool = false,
        /// Native UI's colors, fixed; the system's light or dark when null.
        theme: ?ui.Theme = null,
        /// Where the window opens, in screen points from the primary screen's
        /// top left; centered when null.
        x: ?f64 = null,
        y: ?f64 = null,
        always_on_top: bool = false,
        /// Shown at once; otherwise call `show`.
        visible: bool = true,
        /// Called as the window closes, before it is freed.
        on_close: ?Callback(Window) = null,
        /// Asked whether the window closes as the user closes it.
        on_close_request: ?CloseRequest(Window) = null,
        /// Focus, moves, resizes, minimizing and maximizing.
        on_event: ?EventCallback(Window) = null,
        /// Set by `App.newFlyout`: the window is a flyout placed so.
        flyout: ?@import("flyout.zig").State = null,
        /// Files dropped on the window (from Explorer, Finder, a file manager).
        on_drop: ?DropCallback(Window) = null,
        /// Remembers where the window was, its size and whether it was
        /// maximized, under a key (`.state = myzig.windowState("main")`,
        /// kept in `window-state.txt` in the app's data directory), for the
        /// next window with the key; they override `x`, `y`, `width`,
        /// `height`. Give each kind of window its own key.
        state: ?StateKey = null,
        /// What shows through the window's background where the system has
        /// materials: macOS's vibrancy, Windows 11's Mica and Acrylic.
        material: Material = .none,
        content: Content,
    };
}

pub const WindowState = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    maximized: bool = false,
};

/// A window's key in the remembered states, and how they are kept (only
/// apps that remember windows link the store).
pub const StateKey = struct {
    key: []const u8,
    load: *const fn (gpa: std.mem.Allocator, io: std.Io, app_name: []const u8, key: []const u8) ?WindowState,
    save: *const fn (gpa: std.mem.Allocator, io: std.Io, app_name: []const u8, key: []const u8, state: WindowState) void,

    /// The remembered state under the key, if there is a usable one.
    pub fn get(k: StateKey, app: anytype) ?WindowState {
        const st = k.load(app.gpa, app.io, app.options.name, k.key) orelse return null;
        if (st.width < 50 or st.height < 50) return null;
        return st;
    }

    pub fn put(k: StateKey, app: anytype, state: WindowState) void {
        k.save(app.gpa, app.io, app.options.name, k.key, state);
    }
};

/// Frees the remembered states (set once they are loaded); `App.destroy` calls it.
pub var free_states: ?*const fn () void = null;

/// `options` with the window's remembered frame, and whether it was maximized.
pub fn restore(app: anytype, options: anytype) struct { @TypeOf(options), bool } {
    var o = options;
    const k = o.state orelse return .{ o, false };
    const st = k.get(app) orelse return .{ o, false };
    o.x = st.x;
    o.y = st.y;
    o.width = st.width;
    o.height = st.height;
    return .{ o, st.maximized };
}

pub fn DropCallback(comptime Window: type) type {
    return struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, window: *Window, paths: []const []const u8) void,

        pub fn of(ptr: anytype, comptime func: fn (@TypeOf(ptr), *Window, []const []const u8) void) @This() {
            const P = @TypeOf(ptr);
            return .{ .ctx = @ptrCast(ptr), .func = struct {
                fn call(c: *anyopaque, win: *Window, paths: []const []const u8) void {
                    func(@as(P, @ptrCast(@alignCast(c))), win, paths);
                }
            }.call };
        }
    };
}

pub const Material = enum {
    none,
    /// macOS: the sidebar's; Windows 11: Mica.
    sidebar,
    /// macOS: under the window's content; Windows 11: Mica Alt (tabbed).
    under_window,
    /// macOS: a popover's or HUD's; Windows 11: Acrylic.
    popover,
};

/// A window's native UI as `--myzig-snapshot` draws it.
pub const NativeView = struct {
    view: ui.View,
    width: f32,
    height: f32,
    scale: f32,
    theme: ?ui.Theme,
};

/// The Content-Type of a served file, by its extension.
pub fn mimeType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const table = .{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".woff2", "font/woff2" },
        .{ ".wasm", "application/wasm" },
    };
    inline for (table) |e| if (std.ascii.eqlIgnoreCase(ext, e[0])) return e[1];
    return "application/octet-stream";
}
