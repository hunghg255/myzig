//! A tour of the desktop integration: the menu bar and a menu of the
//! app's own, a tray icon, dialogs, notifications and the clipboard,
//! called from a page.
const std = @import("std");
const builtin = @import("builtin");
const myzig = @import("myzig");

/// Sent to the page for anything worth showing.
const Log = myzig.Event("log", []const u8);

var app: *myzig.App = undefined;
var window: ?*myzig.Window = null;

fn logf(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    if (window) |w| Log.emit(w, s);
}

/// Called from the page.
const Native = struct {
    pub const myzig_params = .{ .confirm = .{"question"}, .copy = .{"text"}, .notify = .{ "title", "body" } };

    /// Lets the user pick files; returns their paths.
    pub fn openFiles(_: *Native, call: *myzig.Call) ![]const []const u8 {
        const paths = try myzig.dialog.open(call.arena, .{ .title = "Pick some files", .multiple = true }) orelse return &.{};
        return @ptrCast(paths);
    }

    /// Asks a yes/no question.
    pub fn confirm(_: *Native, question: []const u8) bool {
        const r = myzig.dialog.message(.{ .title = question, .detail = "This dialog is native.", .buttons = &.{ "Yes", "No" } });
        return r.button == 0;
    }

    /// Puts text on the clipboard.
    pub fn copy(_: *Native, text: []const u8) void {
        myzig.clipboard.writeText(text);
    }

    /// The clipboard's text.
    pub fn paste(_: *Native, call: *myzig.Call) ![]const u8 {
        return (try myzig.clipboard.readText(call.arena)) orelse "";
    }

    /// Shows a desktop notification.
    pub fn notify(_: *Native, title: []const u8, body: []const u8) !void {
        try app.notify(.{ .title = title, .body = body });
    }

    pub fn about(_: *Native, call: *myzig.Call) ![]const u8 {
        return std.fmt.allocPrint(call.arena, "myzig {s} on {t}", .{ myzig.version, builtin.os.tag });
    }
};

const assets = [_]myzig.Asset{.{ .path = "/index.html", .data = @embedFile("frontend/index.html") }};

fn show() void {
    if (window) |w| return w.show();
    window = app.newWindow(.{
        .title = "Native",
        .width = 720,
        .height = 520,
        .on_close = .{ .ctx = app, .func = struct {
            fn f(_: *anyopaque, _: *myzig.Window) void {
                window = null;
            }
        }.f },
        .content = .{ .page = .{ .url = "/", .assets = &assets } },
    }) catch null;
}

/// What the menus do.
const Menus = struct {
    fn sayHi(_: *Menus, _: *myzig.menu.Item) void {
        logf("Hi from the menu!", .{});
    }
    fn onTop(_: *Menus, item: *myzig.menu.Item) void {
        if (window) |w| w.setAlwaysOnTop(item.checked);
    }
    fn small(_: *Menus, _: *myzig.menu.Item) void {
        if (window) |w| w.setSize(720, 520);
    }
    fn large(_: *Menus, _: *myzig.menu.Item) void {
        if (window) |w| w.setSize(1000, 720);
    }
    fn showWindow(_: *Menus, _: *myzig.menu.Item) void {
        show();
    }
    fn time(_: *Menus, _: *myzig.menu.Item) void {
        const now = std.Io.Timestamp.now(app.io, .real);
        const secs: u64 = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));
        const day = std.time.epoch.EpochSeconds{ .secs = secs };
        const ds = day.getDaySeconds();
        logf("It's {d:0>2}:{d:0>2} UTC", .{ ds.getHoursIntoDay(), ds.getMinutesIntoHour() });
    }
};

/// A 32×32 tray icon: a filled circle.
fn trayIcon(gpa: std.mem.Allocator) ![]u8 {
    const bytes = try gpa.alloc(u8, 32 * 32 * 4);
    defer gpa.free(bytes);
    for (0..32) |y| for (0..32) |x| {
        const dx = @as(i32, @intCast(x)) - 16;
        const dy = @as(i32, @intCast(y)) - 16;
        const a: u8 = if (dx * dx + dy * dy <= 12 * 12) 255 else 0;
        @memcpy(bytes[(y * 32 + x) * 4 ..][0..4], &[4]u8{ 0, 0, 0, a });
    };
    return myzig.ui.png.encode(gpa, .{ .bytes = bytes, .width = 32, .height = 32 });
}

pub fn main(init: std.process.Init) !void {
    // Keeps running in the tray after the window is closed.
    app = try myzig.App.create(init, .{ .name = "Native", .quit_on_last_window_closed = false });
    defer app.destroy();
    // Headless runs (--myzig-eval) end with their window.
    if (app.flags.hidden) app.options.quit_on_last_window_closed = true;
    var native: Native = .{};
    try app.bind(&native);
    try app.registerEvent(Log);

    var menus: Menus = .{};
    try app.setMenu(&.{
        .{ .role = .app_menu },
        .{ .role = .edit_menu },
        .{ .label = "Demo", .submenu = &.{
            .{ .label = "Say Hi", .accelerator = "CmdOrCtrl+Shift+H", .click = .of(&menus, Menus.sayHi) },
            .{ .label = "Always on Top", .id = "always-on-top", .kind = .checkbox, .click = .of(&menus, Menus.onTop) },
            .separator,
            .{ .label = "Small", .kind = .radio, .checked = true, .click = .of(&menus, Menus.small) },
            .{ .label = "Large", .kind = .radio, .click = .of(&menus, Menus.large) },
        } },
        .{ .role = .view_menu },
        .{ .role = .window_menu },
    });

    // Headless runs (--myzig-eval) add no icon to the notification area.
    if (!app.flags.hidden) {
        const icon = try trayIcon(init.gpa);
        defer init.gpa.free(icon);
        _ = app.newTray(.{
            .icon = icon,
            .symbol = "circle.fill",
            .tooltip = "myzig Native",
            .menu = &.{
                .{ .label = "Show Window", .click = .of(&menus, Menus.showWindow) },
                .{ .label = "What time is it?", .click = .of(&menus, Menus.time) },
                .separator,
                .{ .role = .quit },
            },
        }) catch |err| std.log.warn("tray: {t}", .{err});
    }
    show();
    try app.run();
}
