//! Themes by name, accent colors, and switching between themes (light to
//! dark, one app's theme to another) animated: every color of the theme
//! eases from the old to the new, as the system's appearance changes.
//!
//!     // In the app's state:
//!     theme: ui.themes.Switcher = .{},
//!
//!     // First in the view:
//!     if (s.dark_toggled) s.theme.switchTo(if (s.dark) ui.Theme.dark_theme else ui.Theme.light);
//!     s.theme.apply(c);
//!
//! Colors move nothing: themes change smoothly even with less motion.
const std = @import("std");
const types = @import("types.zig");
const Theme = @import("theme.zig").Theme;
const Context = @import("context.zig").Context;
const motion = @import("motion.zig");
const preferences = @import("preferences.zig");
const Color = types.Color;

pub const Named = struct {
    name: []const u8,
    theme: Theme,
};

/// The themes myzig has: light and dark, and both with more contrast.
pub const builtins = [_]Named{
    .{ .name = "light", .theme = Theme.light },
    .{ .name = "dark", .theme = Theme.dark_theme },
    .{ .name = "light-high-contrast", .theme = preferences.highContrast(Theme.light) },
    .{ .name = "dark-high-contrast", .theme = preferences.highContrast(Theme.dark_theme) },
};

/// The theme named `name` among `list` (an app's own), else among myzig's.
pub fn find(list: []const Named, name: []const u8) ?Theme {
    for (list) |n| if (std.mem.eql(u8, n.name, name)) return n.theme;
    for (builtins) |n| if (std.mem.eql(u8, n.name, name)) return n.theme;
    return null;
}

/// The light or the dark theme of a pair, as the appearance is.
pub fn forAppearance(dark: bool, light_theme: Theme, dark_theme: Theme) Theme {
    return if (dark) dark_theme else light_theme;
}

/// `t` with the accent color `a` (and its hover and text from it).
pub const withAccent = preferences.withAccent;

/// Every color of `a` mixed toward `b` by `t` (0 is `a`); the rest (dark,
/// fonts) from `b` past halfway.
pub fn mix(a: Theme, b: Theme, t: f32) Theme {
    if (t <= 0) return a;
    if (t >= 1) return b;
    var out = if (t < 0.5) a else b;
    const info = @typeInfo(Theme).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        if (T == Color) @field(out, name) = motion.mixPremultiplied(@field(a, name), @field(b, name), t);
    }
    return out;
}

/// Makes `t` the frame's theme: what widgets built after read, and the
/// window's background. Call it first in the view.
pub fn apply(c: *Context, t: Theme) void {
    c.theme = t;
    c.node(0).style.background = t.background;
}

/// A theme that changes animated, kept in the app's state.
pub const Switcher = struct {
    from: ?Theme = null,
    to: ?Theme = null,
    /// How far from `from` to `to`, 0 to 1.
    progress: f32 = 1,
    /// Seconds a change takes.
    duration: f32 = 0.3,

    /// Changes to `t`, from the theme shown now.
    pub fn switchTo(s: *Switcher, t: Theme) void {
        s.from = s.current();
        s.to = t;
        s.progress = if (s.from == null) 1 else 0;
    }

    /// The theme shown now (null before the first `switchTo`).
    pub fn current(s: *const Switcher) ?Theme {
        const to = s.to orelse return null;
        const from = s.from orelse return to;
        return mix(from, to, ease(s.progress));
    }

    /// Whether a change is under way.
    pub fn changing(s: *const Switcher) bool {
        return s.to != null and s.progress < 1;
    }

    /// Advances the change by the frame's time and makes the theme shown
    /// the frame's; the window's own until the first `switchTo`.
    pub fn apply(s: *Switcher, c: *Context) void {
        if (s.to == null) return;
        if (s.progress < 1) {
            s.progress = if (s.duration <= 0) 1 else @min(1, s.progress + c.dt / s.duration);
            if (s.progress < 1) c.animationFrame();
        }
        themesApply(c, s.current().?);
    }
};

const themesApply = apply;

fn ease(t: f32) f32 {
    // Ease in and out: slow at both ends.
    return t * t * (3 - 2 * t);
}

test "find and mix" {
    try std.testing.expect(find(&.{}, "dark").?.dark);
    const mine = [_]Named{.{ .name = "dark", .theme = Theme.light }};
    try std.testing.expect(!find(&mine, "dark").?.dark);
    try std.testing.expect(find(&.{}, "nope") == null);
    const half = mix(Theme.light, Theme.dark_theme, 0.5);
    try std.testing.expect(half.background.r < Theme.light.background.r);
    try std.testing.expect(half.background.r > Theme.dark_theme.background.r);
    try std.testing.expectEqual(Theme.light.text, mix(Theme.light, Theme.dark_theme, 0).text);
}
