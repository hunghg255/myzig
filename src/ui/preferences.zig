//! The desktop's settings that the system's own controls follow, after
//! mygo's `Preferences`: less motion (`motion.reduced`), more contrast,
//! larger text and the accent color the user chose. A theme follows them
//! with `follow` (`ui.themes` builds on it); views that draw their own
//! read them with `get`. An app may override any of them (its own setting
//! of contrast, a text size slider); tests never ask the desktop.
//!
//!     ui.themes.apply(c, ui.preferences.follow(c.theme, ui.preferences.get(c)));
const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const Theme = @import("theme.zig").Theme;
const Context = @import("context.zig").Context;
const motion = @import("motion.zig");
const sys = @import("preferences_system.zig");
const Color = types.Color;

pub const Preferences = struct {
    /// The accent color the user chose, null where the desktop has none.
    accent: ?Color = null,
    /// Less motion: values go to their targets at once (`motion.reduced`).
    reduce_motion: bool = false,
    /// More contrast: borders and secondary text nearer the text's color.
    high_contrast: bool = false,
    /// How many times larger than usual text should be, 1 for usual.
    text_scale: f32 = 1,
};

/// The desktop's, asked once per process (`refresh` asks again).
var system: ?sys.System = null;

/// Forgets what the desktop said, to ask again: when it says its settings
/// changed.
pub fn refresh() void {
    system = null;
}

fn desktop() sys.System {
    if (system == null) system = if (builtin.is_test) .{} else sys.ask();
    return system.?;
}

// The app's overrides, kept in the context's values while it reads them.
fn slot(c: *Context, comptime name: []const u8, default: f32) *f32 {
    var h = std.hash.Wyhash.init(0x7072_6566); // "pref"
    h.update(name);
    const gop = c.anims.getOrPut(c.gpa, h.final()) catch @panic("OOM");
    if (!gop.found_existing) gop.value_ptr.* = .{ .value = default, .frame = c.frame };
    gop.value_ptr.frame = c.frame;
    return &gop.value_ptr.value;
}

/// Overrides the desktop's contrast (null: follow it again).
pub fn setHighContrast(c: *Context, on: ?bool) void {
    slot(c, "contrast", -1).* = if (on) |v| (if (v) 1 else 0) else -1;
    c.changed = true;
}

/// Overrides the desktop's text size (null: follow it again).
pub fn setTextScale(c: *Context, scale: ?f32) void {
    slot(c, "text scale", 0).* = if (scale) |s| std.math.clamp(s, 0.5, 3) else 0;
    c.changed = true;
}

/// Overrides the desktop's accent color (null: follow it again).
pub fn setAccent(c: *Context, accent: ?Color) void {
    const a = accent orelse Color{ .a = -1 };
    slot(c, "accent r", 0).* = a.r;
    slot(c, "accent g", 0).* = a.g;
    slot(c, "accent b", 0).* = a.b;
    slot(c, "accent a", -1).* = a.a;
    c.changed = true;
}

/// The settings views follow now: the app's, else the desktop's.
pub fn get(c: *Context) Preferences {
    const d = desktop();
    var p: Preferences = .{
        .reduce_motion = motion.reduced(c),
        .high_contrast = d.high_contrast,
        .text_scale = d.text_scale,
    };
    if (d.accent) |a| p.accent = .{ .r = a[0], .g = a[1], .b = a[2] };
    const contrast = slot(c, "contrast", -1).*;
    if (contrast >= 0) p.high_contrast = contrast == 1;
    const scale = slot(c, "text scale", 0).*;
    if (scale > 0) p.text_scale = scale;
    if (slot(c, "accent a", -1).* >= 0) p.accent = .{
        .r = slot(c, "accent r", 0).*,
        .g = slot(c, "accent g", 0).*,
        .b = slot(c, "accent b", 0).*,
    };
    return p;
}

/// The perceived lightness of `c`, from 0 to 1.
pub fn lightness(c: Color) f32 {
    return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
}

/// `t` in the accent color `a`: its hover a little lighter in the dark
/// (darker in the light), its text black where white would not stand out,
/// as on yellow.
pub fn withAccent(t: Theme, a: Color) Theme {
    var out = t;
    const solid = Color{ .r = a.r, .g = a.g, .b = a.b };
    out.accent = solid;
    out.accent_hover = if (t.dark) solid.mix(.white, 0.2) else solid.mix(.black, 0.12);
    out.accent_text = if (lightness(solid) > 0.65) .hex(0x18181b) else .white;
    return out;
}

/// `t` with more contrast: borders and secondary text nearer the text.
pub fn highContrast(t: Theme) Theme {
    var out = t;
    out.border = t.border.mix(t.text, 0.45);
    out.muted = t.muted.mix(t.text, 0.4);
    out.track = t.track.mix(t.text, 0.3);
    return out;
}

/// `t` following `p`: its accent and contrast. The text's size is the
/// context's zoom (`Context.setZoom(p.text_scale)`), which `apply` sets.
pub fn follow(t: Theme, p: Preferences) Theme {
    var out = t;
    if (p.accent) |a| out = withAccent(out, a);
    if (p.high_contrast) out = highContrast(out);
    return out;
}

/// Makes the frame follow the settings: the theme as `follow` makes it,
/// the text at its scale. Call it first in the view.
pub fn apply(c: *Context) Preferences {
    const p = get(c);
    c.theme = follow(c.theme, p);
    c.node(0).style.background = c.theme.background;
    const zoom = slot(c, "applied zoom", 1);
    if (zoom.* != p.text_scale) {
        zoom.* = p.text_scale;
        c.setZoom(p.text_scale);
    }
    return p;
}

test "accents and contrast" {
    const light = Theme.light;
    const yellow = withAccent(light, .hex(0xffd60a));
    try std.testing.expect(yellow.accent_text.r < 0.2);
    const blue = withAccent(Theme.dark_theme, .hex(0x0a84ff));
    try std.testing.expectEqual(@as(f32, 1), blue.accent_text.r);
    try std.testing.expect(blue.accent_hover.g > blue.accent.g);
    const hc = highContrast(light);
    try std.testing.expect(lightness(hc.border) < lightness(light.border));
    try std.testing.expect(lightness(hc.muted) < lightness(light.muted));
}
