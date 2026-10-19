//! Themes and preferences through `Tester`: a switch from light to dark
//! eased over frames, the app's overrides of contrast, accent and text
//! size, followed by the theme.
const std = @import("std");
const ui = @import("ui.zig");
const themes = @import("themes.zig");
const preferences = @import("preferences.zig");
const testing = std.testing;

const App = struct {
    theme: themes.Switcher = .{},
    follow: bool = false,
    prefs: preferences.Preferences = .{},
    background: ui.Color = .{},

    fn view(s: *App, c: *ui.Context) void {
        s.theme.apply(c);
        if (s.follow) s.prefs = preferences.apply(c);
        s.background = c.theme.background;
        ui.column(c, .{ .padding = .all(10) });
        defer ui.end(c);
        ui.text(c, "Hello", .{});
    }
};

test "themes: switching eases every color over frames" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{});
    defer t.deinit();
    // The window's theme until the first switch.
    try testing.expectEqual(ui.Theme.light.background, s.background);
    s.theme.switchTo(ui.Theme.light);
    t.frame();
    try testing.expectEqual(ui.Theme.light.background, s.background);
    try testing.expect(!s.theme.changing());
    s.theme.switchTo(ui.Theme.dark_theme);
    t.frame();
    try testing.expect(t.ctx.animating);
    const between = s.background;
    try testing.expect(between.r < ui.Theme.light.background.r and between.r > ui.Theme.dark_theme.background.r);
    // The root fills with it.
    try testing.expectEqual(between, t.ctx.nodes.items[0].style.background.?);
    t.advance(0.4);
    try testing.expectEqual(ui.Theme.dark_theme.background, s.background);
    try testing.expect(!s.theme.changing());
    // A change on the way starts from where it is.
    s.theme.switchTo(ui.Theme.light);
    t.advance(0.1);
    s.theme.switchTo(ui.Theme.dark_theme);
    t.frame();
    try testing.expect(s.background.r > ui.Theme.dark_theme.background.r);
    t.settle(2);
    try testing.expectEqual(ui.Theme.dark_theme.background, s.background);
}

test "preferences: the app's overrides, followed by the theme" {
    var s: App = .{ .follow = true };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), .{});
    defer t.deinit();
    // Tests never ask the desktop.
    try testing.expect(!s.prefs.high_contrast);
    try testing.expectEqual(@as(f32, 1), s.prefs.text_scale);
    try testing.expect(s.prefs.accent == null);
    const plain = t.findText("Hello").?;

    preferences.setHighContrast(&t.ctx, true);
    preferences.setAccent(&t.ctx, .hex(0xffd60a));
    preferences.setTextScale(&t.ctx, 2);
    t.frame();
    try testing.expect(s.prefs.high_contrast);
    try testing.expectEqual(@as(f32, 2), s.prefs.text_scale);
    try testing.expectEqual(ui.Color.hex(0xffd60a), s.prefs.accent.?);
    try testing.expectEqual(ui.Color.hex(0xffd60a), t.ctx.theme.accent);
    try testing.expect(preferences.lightness(t.ctx.theme.border) < preferences.lightness(ui.Theme.light.border));
    // Text twice as large.
    const big = t.findText("Hello").?;
    try testing.expect(big.w > plain.w * 1.8);

    preferences.setHighContrast(&t.ctx, null);
    preferences.setAccent(&t.ctx, null);
    preferences.setTextScale(&t.ctx, null);
    t.frame();
    try testing.expect(!s.prefs.high_contrast);
    try testing.expectEqual(ui.Theme.light.accent, t.ctx.theme.accent);
    try testing.expectEqual(plain.w, t.findText("Hello").?.w);
}
