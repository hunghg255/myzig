//! Tray icons and bringing the app forward on Windows, through an app
//! whose windows are never shown. The icons are the notification area's
//! own, removed as the app goes.
const std = @import("std");
const App = @import("app.zig").App;
const tray_mod = @import("tray.zig");
const app_extras = @import("app_extras.zig");
const ui = @import("../ui/ui.zig");

const t = std.testing;

fn testApp(env: *std.process.Environ.Map) !*App {
    return App.createHidden(t.allocator, t.io, env, .{ .name = "myzig-tray-tests", .quit_on_signal = false });
}

const Probe = struct {
    told: usize = 0,
    fn appearance(p: *Probe, _: *tray_mod.Tray) void {
        p.told += 1;
    }
    fn view(_: *Probe, _: *ui.Context) void {}
};

test "icons with an ID keep their numbers whatever order they come in; others are counted" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var numbers: [2][2]u32 = undefined;
    for ([_][2][]const u8{ .{ "app.cpu", "app.memory" }, .{ "app.memory", "app.cpu" } }, 0..) |ids, round| {
        const app = try testApp(&env);
        defer app.destroy();
        for (ids, 0..) |id, i| numbers[round][i] = (try app.newTray(.{ .id = id, .tooltip = id })).id;
        // Without an ID, or with one another icon has: counted.
        try t.expectEqual(@as(u32, 3), (try app.newTray(.{ .tooltip = "plain" })).id);
        try t.expectEqual(@as(u32, 4), (try app.newTray(.{ .id = ids[0], .tooltip = "again" })).id);
    }
    try t.expectEqual(numbers[0][0], numbers[1][1]);
    try t.expectEqual(numbers[0][1], numbers[1][0]);
    try t.expectEqual(tray_mod.number("app.cpu"), numbers[0][0]);
}

test "an icon hears once of its taskbar turning dark or light" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const app = try testApp(&env);
    defer app.destroy();
    var p: Probe = .{};
    const tray = try app.newTray(.{ .tooltip = "appearance", .on_appearance = .of(&p, Probe.appearance) });
    try t.expectEqual(tray_mod.taskbarDark(), tray.dark());
    // What the icon last saw differs from the taskbar: as after a change.
    tray.was_dark = !tray.dark();
    tray.appearanceChanged();
    try t.expectEqual(@as(usize, 1), p.told);
    tray.appearanceChanged();
    try t.expectEqual(@as(usize, 1), p.told);
}

test "focusing the app brings forward none of its windows while none shows" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const app = try testApp(&env);
    defer app.destroy();
    var p: Probe = .{};
    _ = try app.newWindow(.{ .title = "Hidden", .visible = false, .content = .{ .view = ui.View.init(&p, Probe.view) } });
    _ = try app.newFlyout(.{ .focusable = false, .anchor = .{ .x = 10, .y = 10 }, .content = .{ .view = ui.View.init(&p, Probe.view) } });
    try t.expect(app_extras.frontWindow(app) == null);
    app.focus();
}
