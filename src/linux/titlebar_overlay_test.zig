//! A hidden title bar over native UI, on the display the tests run with
//! (Xvfb in the container), the window realized but never shown: the
//! content goes under a header bar of title buttons, which
//! `Window.titleBar` reports.
const std = @import("std");
const gtk = @import("gtk.zig");
const more = @import("gtk_more.zig");
const App = @import("app.zig").App;
const ui = @import("../ui/ui.zig");

const t = std.testing;

const Probe = struct {
    fn view(_: *Probe, _: *ui.Context) void {}
};

test "a hidden title bar: title buttons over the content's top right corner" {
    const app = App.createHidden(t.allocator, t.io, .{ .name = "myzig-titlebar-tests", .quit_on_signal = false }) catch return error.SkipZigTest;
    defer app.destroy();
    if (!more.load()) return error.SkipZigTest;
    var p: Probe = .{};
    const win = try app.newWindow(.{ .title = "Notes", .title_bar = .hidden, .content = .{ .view = ui.View.init(&p, Probe.view) } });
    defer win.close();
    more.api.gtk_widget_realize(win.gtkwindow.?);
    const bar = win.header orelse return error.NoHeaderBar;
    _ = bar;
    const area = win.titleBar();
    try t.expect(area.height > 10);
    try t.expect(area.right > 10);
    try t.expectEqual(@as(f64, 0), area.left);
    // The window keeps its client-side frame, without a title bar of its own.
    try t.expectEqual(@as(c_int, 1), more.api.gtk_window_get_decorated(win.gtkwindow.?));

    // A default title bar: none over the content.
    const plain = try app.newWindow(.{ .title = "Plain", .content = .{ .view = ui.View.init(&p, Probe.view) } });
    defer plain.close();
    try t.expect(plain.header == null);
    try t.expectEqual(@as(f64, 0), plain.titleBar().height);
}
