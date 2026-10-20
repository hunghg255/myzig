//! myzig: desktop apps in Zig, with native UI drawn on the GPU or a web
//! frontend in the system webview, after mygo.
//!
//!     pub fn main(init: std.process.Init) !void {
//!         const app = try myzig.App.create(init, .{ .name = "Hello" });
//!         defer app.destroy();
//!         _ = try app.newWindow(.{ .title = "Hello", .content = .{ .page = .{ .url = "/", .assets = &assets } } });
//!         try app.run();
//!     }
const std = @import("std");
const builtin = @import("builtin");

/// The platform's implementations, chosen at compile time.
const mac = builtin.os.tag == .macos;
const plat = switch (builtin.os.tag) {
    .macos => struct {
        pub const app = @import("app.zig");
        pub const window = @import("window.zig");
        pub const menu = @import("menu.zig");
        pub const tray = @import("tray.zig");
        pub const dialog = @import("dialog.zig");
        pub const desktop = @import("desktop.zig");
        pub const fdwatch = @import("fdwatch.zig");
    },
    .linux => struct {
        pub const app = @import("linux/app.zig");
        pub const window = @import("linux/window.zig");
        pub const menu = @import("menu_accel.zig");
        pub const tray = @import("linux/tray.zig");
        pub const dialog = @import("linux/dialog.zig");
        pub const desktop = @import("linux/desktop.zig");
        pub const fdwatch = @import("linux/fdwatch.zig");
    },
    .windows => struct {
        pub const app = @import("windows/app.zig");
        pub const window = @import("windows/window.zig");
        pub const menu = @import("menu_accel.zig");
        pub const tray = @import("windows/tray.zig");
        pub const dialog = @import("windows/dialog.zig");
        pub const desktop = @import("windows/desktop.zig");
        pub const fdwatch = @import("windows/fdwatch.zig");
    },
    .wasi => struct {
        pub const app = @import("web/app.zig");
        pub const window = @import("web/window.zig");
        pub const menu = @import("menu_accel.zig");
        pub const tray = @import("tray_none.zig");
        pub const dialog = @import("web/dialog.zig");
        pub const desktop = @import("web/desktop.zig");
        pub const fdwatch = @import("web/fdwatch.zig");
    },
    else => @compileError("myzig runs on macOS, Linux, Windows and in browsers (wasm32-wasi)"),
};

/// The Objective-C runtime (macOS only).
pub const objc = if (mac) @import("objc.zig") else struct {};
pub const ui = @import("ui/ui.zig");
pub const i18n = @import("i18n/i18n.zig");
pub const l10n = @import("l10n/l10n.zig");
pub const tsgen = @import("tsgen.zig");
const app_types = @import("app_types.zig");
const window_types = @import("window_types.zig");

pub const App = plat.app.App;
pub const AppOptions = plat.app.Options;
pub const Window = plat.window.Window;
pub const WindowOptions = plat.window.Options;
pub const PageOptions = plat.window.PageOptions;
pub const Asset = plat.window.Asset;
/// Typed IPC for pages.
pub const Call = @import("ipc.zig").Call;
pub const Event = @import("ipc.zig").Event;
pub const NotificationAction = @import("app_types.zig").NotificationAction;
pub const NotificationSender = @import("app_types.zig").NotificationSender;
/// Typed streams between Zig and pages, opened by either side.
pub const Channel = @import("channel.zig").Channel;
pub const ChannelKind = @import("channel.zig").ChannelKind;
pub const ChannelCloseReason = @import("channel.zig").CloseReason;
/// What pages tell the app and ask it, the schemes it serves them, their
/// cookies, finding and printing (`page.PageEvent`, `page.Scheme`, ...).
pub const page = @import("page_types.zig");
pub const PageEvent = page.PageEvent;
pub const PageListener = page.PageListener;
pub const EvalResult = page.EvalResult;
pub const EvalCallback = page.EvalCallback;
pub const Scheme = page.Scheme;
pub const SchemeRequest = page.SchemeRequest;

pub const menu = plat.menu;
pub const MenuItem = plat.menu.MenuItem;
pub const MenuRole = plat.menu.Role;
pub const Menu = plat.menu.Menu;
pub const MenuClick = plat.menu.Click;
pub const Tray = plat.tray.Tray;
pub const TrayOptions = plat.tray.Options;
pub const TrayClick = plat.tray.Click;
/// What the app's handlers take (`AppOptions.on_open_url`, ...).
pub const Handler = app_types.Handler;
pub const SecondInstance = app_types.SecondInstance;
pub const Notification = app_types.Notification;
pub const NotificationResponse = app_types.NotificationResponse;
/// What windows tell (`WindowOptions.on_event`), and ask before closing
/// (`on_close_request`); their title bars, taskbar progress.
pub const WindowEvent = window_types.Event;
pub const CloseRequest = window_types.CloseRequest(Window);
pub const WindowEventCallback = window_types.EventCallback(Window);
pub const TitleBar = window_types.TitleBar;
pub const TitleBarArea = window_types.TitleBarArea;
pub const Progress = window_types.Progress;
/// Flyouts (`App.newFlyout`): where they go, and how they are dismissed.
pub const flyout = @import("flyout.zig");
pub const FlyoutOptions = if (@hasDecl(App, "FlyoutOptions")) App.FlyoutOptions else void;
/// Whether the computer is online (`App.networkStatus`, `AppOptions.on_network`).
pub const NetworkStatus = app_types.NetworkStatus;
/// The app's own directories: data, settings, caches, logs.
pub const AppDir = @import("paths.zig").AppDir;
pub const appPath = @import("paths.zig").appPath;
pub const DropCallback = window_types.DropCallback(Window);
pub const Material = window_types.Material;
/// A window's key in the remembered states: `.state = myzig.windowState("main")`.
pub const windowState = @import("window_state.zig").key;
pub const WindowState = window_types.WindowState;
/// Locale, recent documents, open at login, URL schemes, file types, power.
pub const system = @import("system.zig");
/// The Keychain, the Credential Manager, the keyring.
pub const secrets = @import("secrets.zig");
pub const dialog = plat.dialog;
pub const fdwatch = plat.fdwatch;
pub const clipboard = plat.desktop.clipboard;
pub const shell = plat.desktop.shell;
pub const Directory = plat.desktop.Directory;
pub const path = plat.desktop.path;
pub const isDark = plat.desktop.isDark;
pub const accentColor = plat.desktop.accentColor;
/// Runs the event loop for a while (headless tests: replies, processes, timers).
pub const runFor = @import("platform.zig").runFor;

/// Document-based apps: a window per document, saving, autosave, recovery
/// copies, files changed by other apps, the File menu (`documents.zig`).
pub fn Documents(comptime T: type) type {
    return @import("documents.zig").Documents(T, Window);
}
pub const DocumentType = @import("documents.zig").DocumentType;
pub const DocumentState = @import("documents.zig").State;
pub const DocumentStrings = @import("documents.zig").Strings;
pub const Autosave = @import("documents.zig").Autosave;
/// The app as documents see it: `var h: myzig.DocumentHost = .{ .app = app };`
pub const DocumentHost = @import("document_app.zig").AppHost(App, Window, plat.dialog, plat.menu);
/// Watching a file for other apps' changes.
pub const file_watch = @import("file_watch.zig");
/// Sound: WAV decoded or streamed, players, mixing, the system's output.
pub const audio = @import("audio/audio.zig");
/// Data that drags carry: items in typed formats, effects.
pub const transfer = @import("transfer.zig");
/// The system's drag and drop for drags leaving `win`'s native UI
/// (`ui.DragDrop.external`): OLE on Windows, GTK's on Linux, an AppKit
/// dragging session on macOS; null without native UI (or in browsers).
pub fn systemDrag(win: *Window) ?@import("ui/dragdrop.zig").External {
    switch (builtin.os.tag) {
        .windows => return @import("windows/oledrag.zig").external(win),
        .linux => if (win.surface) |s| return @import("linux/dnd.zig").external(s.area, win, redrawOf),
        .macos => if (win.surface) |s| return @import("dnd_mac.zig").external(s.nsview, win, redrawOf),
        else => {},
    }
    return null;
}

/// Lets drags from other apps (text, URLs, HTML, images, files, MIME
/// types of their own) drop on `dd`'s targets in `win`'s native UI, for
/// as long as the window lives; `dd` is the app's, as `win`'s view uses
/// it. Files no target takes still reach the window's `on_drop`
/// (Windows). macOS takes the common formats and `extra` (MIME types).
pub fn systemDrop(win: *Window, dd: *ui.DragDrop, extra: []const []const u8) !void {
    switch (builtin.os.tag) {
        .windows => try @import("windows/droptarget.zig").register(win, dd),
        .linux => if (win.surface) |s| @import("linux/dnd.zig").accept(s.area, dd, win, redrawOf),
        .macos => if (win.surface) |s| @import("dnd_mac.zig").accept(s.nsview, dd, extra, win, redrawOf),
        else => {},
    }
}

fn redrawOf(win: *anyopaque) void {
    @as(*Window, @ptrCast(@alignCast(win))).redraw();
}

/// The app's light or dark appearance (`App.setAppearance`).
pub const Appearance = @import("appearance.zig").Appearance;

pub const version = "0.1.5";

test {
    _ = tsgen;
    _ = ui;
    _ = i18n;
    _ = l10n;
    _ = @import("l10n/tests_l10n.zig");
    _ = @import("menu_types.zig");
    _ = @import("app_tests.zig");
    _ = @import("relaunch.zig");
    _ = @import("ui/metal_present_test.zig");
    _ = @import("notify_types.zig");
    switch (builtin.os.tag) {
        .windows => {
            _ = @import("windows/winrt.zig");
            _ = @import("windows/toast_xml.zig");
            _ = @import("windows/toast_test.zig");
            _ = @import("windows/aumid.zig");
            _ = @import("windows/notify.zig");
            _ = @import("windows/badge.zig");
            _ = @import("windows/clipboard_lazy_test.zig");
            _ = @import("windows/tray_tests.zig");
            _ = @import("windows/trash.zig");
            _ = @import("windows/relaunch_test.zig");
        },
        .linux => {
            _ = @import("linux/dbus_portal.zig");
            _ = @import("linux/hotkey_portal_test.zig");
            _ = @import("linux/titlebar_overlay_test.zig");
        },
        .macos => {
            std.testing.refAllDecls(@import("notify_mac.zig"));
            std.testing.refAllDecls(@import("dock_mac.zig"));
            std.testing.refAllDecls(@import("popover_mac.zig"));
            std.testing.refAllDecls(@import("pasteboard_lazy_mac.zig"));
            std.testing.refAllDecls(@import("notify_sender_mac.zig"));
            _ = @import("tray.zig");
        },
        else => {},
    }
    _ = @import("window_features_tests.zig");
    _ = @import("documents.zig");
    _ = @import("document_tests.zig");
    _ = @import("document_app_tests.zig");
    _ = @import("file_watch.zig");
    _ = @import("transfer.zig");
    _ = @import("transfer_native.zig");
    _ = @import("appearance.zig");
    _ = @import("headless.zig");
    switch (builtin.os.tag) {
        .windows => _ = .{ @import("windows/transfer_win.zig"), @import("windows/droptarget.zig") },
        .linux => _ = .{ @import("linux/transfer_gtk.zig"), @import("linux/dnd.zig") },
        .macos => _ = .{ @import("transfer_mac.zig"), @import("dnd_mac.zig") },
        else => {},
    }
    _ = @import("audio/audio.zig");
    if (builtin.os.tag == .windows) _ = @import("windows/oledrag.zig");
    if (builtin.os.tag == .wasi) _ = @import("web/input.zig");
    _ = .{ @import("page_types.zig"), @import("page_core.zig"), @import("page_channel.zig"), @import("page_serve.zig"), @import("page_find.zig") };
    // Every page method, used by an example or not.
    switch (builtin.os.tag) {
        .windows => std.testing.refAllDecls(@import("windows/page.zig").Page),
        .linux => std.testing.refAllDecls(@import("linux/page.zig").Page),
        .macos => std.testing.refAllDecls(@import("page.zig").Page),
        else => {},
    }
    if (!mac) {
        inline for (.{ plat.app, plat.window, plat.menu, plat.dialog, plat.desktop, plat.fdwatch, }) |m| std.testing.refAllDecls(m);
        return;
    }
    // Analyze every declaration, used by an example or not.
    inline for (.{ @import("menu.zig"), @import("dialog.zig"), @import("desktop.zig"), @import("tray.zig"), @import("window.zig"), @import("app.zig"), @import("ui/textinput.zig"), @import("fdwatch.zig") }) |m| {
        std.testing.refAllDecls(m);
    }
    std.testing.refAllDecls(@import("desktop.zig").clipboard);
    std.testing.refAllDecls(@import("desktop.zig").shell);
    std.testing.refAllDecls(@import("window.zig").Window);
    std.testing.refAllDecls(@import("app.zig").App);
    std.testing.refAllDecls(@import("menu.zig").Menu);
    std.testing.refAllDecls(@import("menu.zig").Item);
    std.testing.refAllDecls(@import("tray.zig").Tray);
}
