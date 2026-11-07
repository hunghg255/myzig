//! The colors of native UI, light and dark, following the system appearance.
const types = @import("types.zig");
const palettes = @import("palettes.zig");
const Color = types.Color;

pub const Theme = struct {
    dark: bool,
    background: Color,
    surface: Color,
    surface_hover: Color,
    text: Color,
    muted: Color,
    border: Color,
    accent: Color,
    accent_hover: Color,
    accent_text: Color,
    track: Color,
    knob: Color,
    danger: Color,
    success: Color,
    shadow: Color,
    /// What calls for attention without being an error (mygo's Warning):
    /// amber. Themes made before it had it get the light one's.
    warning: Color = .hex(0xd97706),
    /// The border and glow of what has the keyboard's focus. A theme made
    /// from another keeps its gray when given another accent.
    ring: Color = .hex(0xa1a1aa),
    /// Font families: text, and monospaced text (null: the system's, SF
    /// Pro and SF Mono). A family that is not installed falls back.
    font: ?[]const u8 = null,
    mono_font: ?[]const u8 = null,
    /// How long, in seconds, the pointer rests on an element before its
    /// tooltip shows (`tooltip`, `tooltipBase`): 0 is 0.6 seconds, and a
    /// negative delay shows it at once. Within two thirds of it after
    /// another tip goes, as the pointer moves along a toolbar, the next
    /// one shows at once: 0.4 seconds by default. A view that sets it for
    /// part of the window gives those elements' tips a delay of their own.
    tooltip_delay: f32 = 0,

    /// shadcn/ui's zinc (`palettes.zig` has the others).
    pub const light: Theme = (palettes.Palette{}).theme(false);
    pub const dark_theme: Theme = (palettes.Palette{}).theme(true);

    /// The accent for text, icons and a caret on a surface: nearer the text's
    /// color where it is too near the surface's lightness to read, as a
    /// colored primary is in the dark and yellow is in the light.
    pub fn accentInk(t: Theme) Color {
        const a = lightness(t.accent);
        const s = lightness(t.surface);
        return if (@abs(a - s) < 0.45) t.accent.mix(t.text, 0.55) else t.accent;
    }

    fn lightness(c: Color) f32 {
        return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
    }
};
