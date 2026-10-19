//! Windows' behavior on Linux, through windows that are made (realized)
//! but never shown, on the display the tests run with (Xvfb in the
//! container): closing asks first, edited titles, frames and flyouts.
const std = @import("std");
const gtk = @import("gtk.zig");
const more = @import("gtk_more.zig");
const App = @import("app.zig").App;
const Window = @import("window.zig").Window;
const ui = @import("../ui/ui.zig");
const window_types = @import("../window_types.zig");

const t = std.testing;

const Probe = struct {
    allow: bool = false,
    asked: usize = 0,

    fn view(_: *Probe, _: *ui.Context) void {}
    fn request(p: *Probe, _: *Window) bool {
        p.asked += 1;
        return p.allow;
    }
};

fn testApp() !*App {
    const app = App.createHidden(t.allocator, t.io, .{ .name = "myzig-window-tests", .quit_on_signal = false }) catch return error.SkipZigTest;
    if (!more.load()) {
        app.destroy();
        return error.SkipZigTest;
    }
    return app;
}

/// Runs the main loop until `done` holds, or a bounded number of turns
/// (the idle that sends a delete event comes in the first few).
fn spinUntil(done: *const fn (ctx: *anyopaque) bool, ctx: *anyopaque) bool {
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        if (done(ctx)) return true;
        _ = gtk.api.g_main_context_iteration(null, 0);
    }
    return done(ctx);
}

test "closing asks first, and a refusal keeps the window" {
    const app = try testApp();
    defer app.destroy();
    var p: Probe = .{};
    const win = try app.newWindow(.{ .title = "Notes", .on_close_request = .of(&p, Probe.request), .content = .{ .view = ui.View.init(&p, Probe.view) } });
    more.api.gtk_widget_realize(win.gtkwindow.?);
    try t.expect(!win.isVisible());
    win.requestClose();
    const asked = struct {
        fn f(ctx: *anyopaque) bool {
            return @as(*Probe, @ptrCast(@alignCast(ctx))).asked > 0;
        }
    }.f;
    try t.expect(spinUntil(asked, &p));
    try t.expectEqual(@as(usize, 1), app.windows.items.len);
    win.close();
}

test "an edited document's title is marked, frames and taskbars as asked" {
    const app = try testApp();
    defer app.destroy();
    var p: Probe = .{ .allow = true };
    const win = try app.newWindow(.{ .title = "Notes", .title_bar = .frameless, .skip_taskbar = true, .content = .{ .view = ui.View.init(&p, Probe.view) } });
    defer win.close();
    const g = win.gtkwindow.?;
    win.setDocumentEdited(true);
    try t.expectEqualStrings("*Notes", std.mem.span(more.api.gtk_window_get_title(g).?));
    win.setDocumentEdited(false);
    win.setTitle("Plans");
    try t.expectEqualStrings("Plans", std.mem.span(more.api.gtk_window_get_title(g).?));
    try t.expectEqual(@as(c_int, 0), more.api.gtk_window_get_decorated(g));
    try t.expectEqual(@as(c_int, 1), more.api.gtk_window_get_skip_taskbar_hint(g));
    try t.expectEqual(@as(f64, 0), win.titleBar().height);
}

test "a flyout: undecorated, off the taskbar, hidden when dismissed so" {
    const app = try testApp();
    defer app.destroy();
    var p: Probe = .{ .allow = true };
    const f = try app.newFlyout(.{ .anchor = .{ .x = 40, .y = 40 }, .width = 120, .height = 80, .dismiss = .hide, .content = .{ .view = ui.View.init(&p, Probe.view) } });
    const g = f.gtkwindow.?;
    try t.expect(f.isFlyout());
    try t.expectEqual(@as(c_int, 0), more.api.gtk_window_get_decorated(g));
    try t.expectEqual(@as(c_int, 1), more.api.gtk_window_get_skip_taskbar_hint(g));
    // Dismissed so, the delete event hides it: the app shows it again.
    try t.expectEqual(@as(c_int, 1), @import("window_events.zig").onDelete(f));
    try t.expectEqual(@as(usize, 1), app.windows.items.len);
    f.close();
}
