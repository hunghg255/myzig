//! shadcn/ui's themes as `ui.Theme`s: seven bases of grays, each with a primary
//! of near black (near white in the dark), and seventeen accents that give
//! any base a colored primary. Values from shadcn/ui's `registry/themes.ts`
//! at commit 42f3bb6 (MIT License, see THIRD_PARTY_NOTICES.md), its oklch()
//! converted to sRGB as `oklch.zig` does; dark borders, translucent there, are
//! flattened over the theme's card.
//!
//!     // First in the view, following the system's light or dark:
//!     ui.themes.use(c, .{ .base = .stone, .accent = .blue });
//!
//!     // A window fixed in one appearance:
//!     .theme = ui.Palette.theme(.{ .accent = .rose }, true),
const std = @import("std");
const Color = @import("types.zig").Color;
const Theme = @import("theme.zig").Theme;

pub const Base = enum { neutral, stone, zinc, mauve, olive, mist, taupe };

/// A base and an accent; the zinc base, its own primary, by default.
pub const Palette = struct {
    base: Base = .zinc,
    /// The primary color, or the base's own when null.
    accent: ?Accent = null,

    /// The palette's light or dark theme.
    pub fn theme(p: Palette, dark: bool) Theme {
        const r = base_rows[@intFromEnum(p.base)][@intFromBool(dark)];
        var primary = r[primary_at];
        var on_primary = r[on_primary_at];
        if (p.accent) |a| {
            const row = accent_rows[@intFromEnum(a)];
            const at: usize = if (dark) 2 else 0;
            primary = row[at];
            on_primary = row[at + 1];
        }
        const card = Color.hex(r[card_at]);
        return .{
            .dark = dark,
            .background = .hex(r[background_at]),
            .surface = card,
            .surface_hover = .hex(r[hover_at]),
            .text = .hex(r[text_at]),
            .muted = .hex(r[muted_at]),
            .border = .hex(r[border_at]),
            .ring = .hex(r[ring_at]),
            .accent = .hex(primary),
            // A button shows 60% of it under the pointer: shadcn's primary/90.
            .accent_hover = Color.hex(primary).mix(card, 1.0 / 6.0),
            .accent_text = .hex(on_primary),
            .track = .hex(r[input_at]),
            .knob = if (dark) .hex(r[text_at]) else .white,
            .danger = .hex(r[danger_at]),
            // shadcn has neither; Tailwind's green and amber, of one depth.
            .success = if (dark) .hex(0x22c55e) else .hex(0x16a34a),
            .warning = if (dark) .hex(0xf59e0b) else .hex(0xd97706),
            .shadow = .{ .a = if (dark) 0.4 else 0.1 },
        };
    }

    /// The palette of `"stone"`, `"blue"` or `"stone-blue"`, null when there
    /// is none of that name. An accent alone is on the zinc base.
    pub fn parse(name: []const u8) ?Palette {
        if (std.mem.indexOfScalar(u8, name, '-')) |dash| return .{
            .base = std.meta.stringToEnum(Base, name[0..dash]) orelse return null,
            .accent = std.meta.stringToEnum(Accent, name[dash + 1 ..]) orelse return null,
        };
        if (std.meta.stringToEnum(Base, name)) |b| return .{ .base = b };
        if (std.meta.stringToEnum(Accent, name)) |a| return .{ .accent = a };
        return null;
    }
};

const Row = [11]u24;
const background_at = 0;
const text_at = 1;
const card_at = 2;
const hover_at = 3;
const muted_at = 4;
const border_at = 5;
const input_at = 6;
const ring_at = 7;
const primary_at = 8;
const on_primary_at = 9;
const danger_at = 10;

/// Each base, light then dark, in the order above.
const base_rows = [_][2]Row{
    // neutral
    .{ .{ 0xffffff, 0x0a0a0a, 0xffffff, 0xf5f5f5, 0x737373, 0xe5e5e5, 0xe5e5e5, 0xa1a1a1, 0x171717, 0xfafafa, 0xe40016 }, .{ 0x0a0a0a, 0xfafafa, 0x171717, 0x262626, 0xa1a1a1, 0x2e2e2e, 0x3a3a3a, 0x737373, 0xe5e5e5, 0x171717, 0xff6568 } },
    // stone
    .{ .{ 0xffffff, 0x0c0a09, 0xffffff, 0xf5f5f4, 0x79716b, 0xe7e5e4, 0xe7e5e4, 0xa6a09b, 0x1c1917, 0xfafaf9, 0xe40016 }, .{ 0x0c0a09, 0xfafaf9, 0x1c1917, 0x292524, 0xa6a09b, 0x33302e, 0x3e3b3a, 0x79716b, 0xe7e5e4, 0x1c1917, 0xff6568 } },
    // zinc
    .{ .{ 0xffffff, 0x09090b, 0xffffff, 0xf4f4f5, 0x71717b, 0xe4e4e7, 0xe4e4e7, 0x9f9fa9, 0x18181b, 0xfafafa, 0xe40016 }, .{ 0x09090b, 0xfafafa, 0x18181b, 0x27272a, 0x9f9fa9, 0x2f2f32, 0x3b3b3d, 0x71717b, 0xe4e4e7, 0x18181b, 0xff6568 } },
    // mauve
    .{ .{ 0xffffff, 0x0c090c, 0xffffff, 0xf3f1f3, 0x79697b, 0xe7e4e7, 0xe7e4e7, 0xa89ea9, 0x1d161e, 0xfafafa, 0xe40016 }, .{ 0x0c090c, 0xfafafa, 0x1d161e, 0x2a212c, 0xa89ea9, 0x342d34, 0x3f3940, 0x79697b, 0xe7e4e7, 0x1d161e, 0xff6568 } },
    // olive
    .{ .{ 0xffffff, 0x0c0c09, 0xffffff, 0xf4f4f0, 0x7c7c67, 0xe8e8e3, 0xe8e8e3, 0xabab9c, 0x1d1d16, 0xfbfbf9, 0xe40016 }, .{ 0x0c0c09, 0xfbfbf9, 0x1d1d16, 0x2b2b22, 0xabab9c, 0x34342d, 0x3f3f39, 0x7c7c67, 0xe8e8e3, 0x1d1d16, 0xff6568 } },
    // mist
    .{ .{ 0xffffff, 0x090b0c, 0xffffff, 0xf1f3f3, 0x67787c, 0xe3e7e8, 0xe3e7e8, 0x9ca8ab, 0x161b1d, 0xf9fbfb, 0xe40016 }, .{ 0x090b0c, 0xf9fbfb, 0x161b1d, 0x22292b, 0x9ca8ab, 0x2e3233, 0x393d3f, 0x67787c, 0xe3e7e8, 0x161b1d, 0xff6568 } },
    // taupe
    .{ .{ 0xffffff, 0x0c0a09, 0xffffff, 0xf3f1f1, 0x7c6d67, 0xe8e4e3, 0xe8e4e3, 0xaba09c, 0x1d1816, 0xfbfaf9, 0xe40016 }, .{ 0x0c0a09, 0xfbfaf9, 0x1d1816, 0x2b2422, 0xaba09c, 0x342f2d, 0x3f3b39, 0x7c6d67, 0xe8e4e3, 0x1d1816, 0xff6568 } },
};

pub const Accent = enum { amber, blue, cyan, emerald, fuchsia, green, indigo, lime, orange, pink, purple, red, rose, sky, teal, violet, yellow };

/// Each accent's primary and the text on it: light, then dark.
const accent_rows = [_][4]u24{
    .{ 0xb55200, 0xfffbeb, 0x953d00, 0xfffbeb }, // amber
    .{ 0x1447e6, 0xeff6ff, 0x193cb8, 0xeff6ff }, // blue
    .{ 0x007491, 0xecfeff, 0x005f78, 0xecfeff }, // cyan
    .{ 0x007857, 0xecfdf5, 0x005f46, 0xecfdf5 }, // emerald
    .{ 0xa600b4, 0xfdf4ff, 0x8a0194, 0xfdf4ff }, // fuchsia
    .{ 0x00813a, 0xf0fdf4, 0x016630, 0xf0fdf4 }, // green
    .{ 0x432dd7, 0xeef2ff, 0x372aac, 0xeef2ff }, // indigo
    .{ 0x9de500, 0x35530e, 0x83cc00, 0x35530e }, // lime
    .{ 0xc43e00, 0xfff7ed, 0x9f2d00, 0xfff7ed }, // orange
    .{ 0xc2005c, 0xfdf2f8, 0xa2004c, 0xfdf2f8 }, // pink
    .{ 0x8200d9, 0xfaf5ff, 0x6e11b0, 0xfaf5ff }, // purple
    .{ 0xbf000f, 0xfef2f2, 0x9f0712, 0xfef2f2 }, // red
    .{ 0xc1003a, 0xfff1f2, 0xa30037, 0xfff1f2 }, // rose
    .{ 0x0069a2, 0xf0f9ff, 0x005986, 0xf0f9ff }, // sky
    .{ 0x00776e, 0xf0fdfa, 0x005f5a, 0xf0fdfa }, // teal
    .{ 0x7008e7, 0xf5f3ff, 0x5d0ec0, 0xf5f3ff }, // violet
    .{ 0xf7c900, 0x733e0a, 0xeab300, 0x733e0a }, // yellow
};
