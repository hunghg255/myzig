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

fn rgb(p: anytype, scale: usize, x: f32, y: f32) [3]u8 {
    const i = (@as(usize, @intFromFloat(y)) * scale * p.width + @as(usize, @intFromFloat(x)) * scale) * 4;
    return .{ p.bytes[i + 2], p.bytes[i + 1], p.bytes[i] }; // BGRA
}

fn apart(a: u8, b: u8) u8 {
    return @max(a, b) - @min(a, b);
}

test "themes: a switch that is on shows its knob, light and dark" {
    const App2 = struct {
        on: bool = true,
        fn view(s: *@This(), c: *ui.Context) void {
            _ = ui.toggle(c, "On", &s.on);
        }
    };
    for ([_]ui.Theme{ ui.Theme.light, ui.Theme.dark_theme }) |theme| {
        var s: App2 = .{};
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&s, App2.view), .{ .width = 200, .height = 60, .scale = 1, .theme = theme });
        defer t.deinit();
        t.settle(1);
        const px = try t.render(testing.allocator);
        defer px.deinit(testing.allocator);
        const track = rgb(px, 1, 5, 12);
        const knob = rgb(px, 1, 28, 12);
        // The track is the accent; the knob stands out from it.
        const accent = theme.accent;
        try testing.expect(apart(track[1], @intFromFloat(accent.g * 255)) < 8);
        try testing.expect(apart(track[1], knob[1]) > 150);
    }
}

test "themes: a danger button stays red under the pointer, light and dark" {
    const App2 = struct {
        fn view(_: *@This(), c: *ui.Context) void {
            _ = ui.button(c, "Delete", .{ .variant = .danger });
        }
    };
    for ([_]ui.Theme{ ui.Theme.light, ui.Theme.dark_theme }) |theme| {
        var s: App2 = .{};
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&s, App2.view), .{ .width = 200, .height = 60, .scale = 1, .theme = theme });
        defer t.deinit();
        t.frame();
        const label = t.findText("Delete").?;
        t.moveTo(label.x + 2, label.y + 2);
        t.settle(1);
        const px = try t.render(testing.allocator);
        defer px.deinit(testing.allocator);
        const fill = rgb(px, 1, label.x - 4, label.y + label.h / 2);
        try testing.expect(fill[0] > 2 * @as(u16, fill[1]) and fill[0] > 2 * @as(u16, fill[2]));
    }
}

test "themes: a checked Markdown task's mark shows on a near white accent" {
    const App2 = struct {
        fn view(_: *@This(), c: *ui.Context) void {
            _ = ui.markdown(c, "- [x] done", .{});
        }
    };
    var s: App2 = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App2.view), .{ .width = 200, .height = 80, .scale = 2, .theme = ui.Theme.dark_theme });
    defer t.deinit();
    t.settle(1);
    const mark = t.findText("✓").?;
    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    // Dark ink inside the light box.
    var dark: usize = 0;
    var y = mark.y;
    while (y < mark.y + mark.h) : (y += 0.5) {
        var x = mark.x;
        while (x < mark.x + mark.w) : (x += 0.5) {
            if (rgb(px, 1, x * 2, y * 2)[1] < 90) dark += 1;
        }
    }
    try testing.expect(dark > 0);
}

fn luminance(c: ui.Color) f32 {
    const f = struct {
        fn f(v: f32) f32 {
            return if (v <= 0.03928) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
        }
    }.f;
    return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
}

fn contrast(a: ui.Color, b: ui.Color) f32 {
    const x = luminance(a);
    const y = luminance(b);
    return (@max(x, y) + 0.05) / (@min(x, y) + 0.05);
}

test "themes: every palette reads, light and dark" {
    for (std.enums.values(themes.Base)) |base| {
        const accents = std.enums.values(themes.Accent);
        for (0..accents.len + 1) |i| {
            const accent: ?themes.Accent = if (i < accents.len) accents[i] else null;
            for ([_]bool{ false, true }) |dark| {
                const th = (ui.Palette{ .base = base, .accent = accent }).theme(dark);
                try testing.expectEqual(dark, th.dark);
                try testing.expect(contrast(th.text, th.background) > 7);
                try testing.expect(contrast(th.text, th.surface) > 7);
                try testing.expect(contrast(th.text, th.surface_hover) > 7);
                try testing.expect(contrast(th.muted, th.surface) > 3.5);
                try testing.expect(contrast(th.accent, th.accent_text) > 3.5);
                try testing.expect(contrast(th.accentInk(), th.surface) > 3);
                try testing.expect(contrast(th.accent_hover, th.accent_text) > 3);
                try testing.expect(contrast(th.surface_hover, th.surface) > 1.05);
                // The dark's translucent borders are flattened: colors mix.
                try testing.expectEqual(@as(f32, 1), th.border.a);
                try testing.expectEqual(@as(f32, 1), th.track.a);
            }
        }
    }
    try testing.expectEqual(ui.Theme.light, (ui.Palette{}).theme(false));
    try testing.expectEqual(ui.Theme.dark_theme, (ui.Palette{}).theme(true));
    try testing.expect(ui.Palette.parse("stone-nope") == null);
    try testing.expectEqual(themes.Accent.rose, ui.Palette.parse("rose").?.accent.?);
    try testing.expectEqual(themes.Base.olive, ui.Palette.parse("olive").?.base);
}

test "themes: a palette follows the window's appearance" {
    const App2 = struct {
        seen: ui.Theme = undefined,
        fn view(s: *@This(), c: *ui.Context) void {
            ui.themes.use(c, .{ .base = .stone, .accent = .blue });
            s.seen = c.theme;
            ui.text(c, "Hi", .{});
        }
    };
    for ([_]bool{ false, true }) |dark| {
        var s: App2 = .{};
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&s, App2.view), .{ .width = 100, .height = 40, .scale = 1, .dark = dark });
        defer t.deinit();
        t.frame();
        try testing.expectEqual((ui.Palette{ .base = .stone, .accent = .blue }).theme(dark), s.seen);
    }
}

test "themes: a chosen row is the gray, half of it hovered" {
    const structure = @import("structure.zig");
    const App2 = struct {
        chosen: ?ui.Color = null,
        hovered: ?ui.Color = null,
        none: ?ui.Color = ui.Color.white,
        th: ui.Theme = undefined,
        fn view(s: *@This(), c: *ui.Context) void {
            s.th = c.theme;
            s.chosen = structure.rowBackground(c, true, 0);
            s.hovered = structure.rowBackground(c, false, 1);
            s.none = structure.rowBackground(c, false, 0);
            ui.text(c, "x", .{});
        }
    };
    var s: App2 = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App2.view), .{ .width = 100, .height = 40 });
    defer t.deinit();
    t.frame();
    try testing.expectEqual(s.th.surface_hover, s.chosen.?);
    try testing.expectEqual(@as(f32, 0.5), s.hovered.?.a);
    try testing.expect(s.none == null);
}
