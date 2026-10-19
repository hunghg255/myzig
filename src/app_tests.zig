//! The tests of the app's features (trays, menus, instances, launches,
//! window states, the system's services), per platform.
const std = @import("std");
const builtin = @import("builtin");

test {
    _ = @import("app_types.zig");
    _ = @import("launch.zig");
    _ = @import("app_common.zig");
    _ = @import("window_state.zig");
    _ = @import("menu_accel.zig");
    switch (builtin.os.tag) {
        .windows => {
            _ = @import("windows/registry.zig");
            _ = @import("windows/appwnd.zig");
            _ = @import("windows/instance.zig");
            _ = @import("windows/menubar.zig");
            _ = @import("windows/tray.zig");
            _ = @import("windows/window_extras.zig");
            _ = @import("windows/protocols.zig");
            _ = @import("windows/system.zig");
            _ = @import("windows/secrets.zig");
            _ = @import("windows/clipboard.zig");
            _ = @import("windows/jumplist.zig");
            _ = @import("windows/uia_api.zig");
            _ = @import("windows/uia_test.zig");
            std.testing.refAllDecls(@import("windows/tray.zig").Tray);
            std.testing.refAllDecls(@import("windows/app.zig").App);
            std.testing.refAllDecls(@import("windows/window.zig").Window);
        },
        .linux => {
            _ = @import("linux/dbus.zig");
            _ = @import("linux/dbus_conn.zig");
            _ = @import("linux/services.zig");
            _ = @import("linux/gtkmenu.zig");
            _ = @import("instance_unix.zig");
            _ = @import("linux/xdg.zig");
            _ = @import("linux/system.zig");
            _ = @import("linux/secrets.zig");
            _ = @import("linux/clipboard.zig");
            _ = @import("linux/atspi_test.zig");
            std.testing.refAllDecls(@import("linux/tray.zig").Tray);
            std.testing.refAllDecls(@import("linux/app.zig").App);
            std.testing.refAllDecls(@import("linux/window.zig").Window);
        },
        .macos => {
            _ = @import("instance_unix.zig");
            std.testing.refAllDecls(@import("notify_mac.zig"));
            std.testing.refAllDecls(@import("window_extras_mac.zig"));
            std.testing.refAllDecls(@import("system_mac.zig"));
            std.testing.refAllDecls(@import("secrets_mac.zig"));
            std.testing.refAllDecls(@import("ui/access_mac.zig"));
        },
        else => {},
    }
}

/// Calls of the system's services with each platform's App, compiled
/// (never run: they would touch the user's settings).
fn useServices(app: *@import("myzig.zig").App) !void {
    const system = @import("system.zig");
    const secrets = @import("secrets.zig");
    try system.addRecentDocument(app, "/tmp/a.md");
    system.freeList(app.gpa, try system.recentDocuments(app));
    system.clearRecentDocuments(app);
    try system.setOpenAtLogin(app, true);
    _ = system.openAtLogin(app);
    _ = system.wasOpenedAtLogin(app);
    try system.registerUrlScheme(app, "notes");
    try system.unregisterUrlScheme(app, "notes");
    _ = system.isUrlSchemeRegistered(app, "notes");
    try system.registerFileType(app, "md", "Markdown");
    try system.unregisterFileType(app, "md");
    const b = try system.preventSleep(app, "test", .display);
    b.release();
    app.gpa.free(try system.locale(app.gpa));
    app.gpa.free(try system.region(app.gpa));
    system.freeList(app.gpa, try system.languages(app.gpa));
    try secrets.set(app.gpa, "s", "a", "x");
    if (try secrets.get(app.gpa, "s", "a")) |s| app.gpa.free(s);
    _ = try secrets.delete("s", "a");
    try app.notify(.{ .title = "t" });
    app.removeNotification("t");
    _ = app.requestSingleInstanceLock();
    try system.setJumpList(app, &.{.{ .title = "New", .args = "notes://new" }});
}

test {
    _ = &useServices;
    _ = @import("recent.zig");
}
