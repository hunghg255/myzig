//! The colors of a terminal, which programs may change (OSC 4, 10, 11,
//! 12) until it resets: Visual Studio Code's palettes on myzig's window
//! colors by default, the hundreds of themes Ghostty ships by name
//! (`ghostty`), and theme files in Ghostty's format (`parse`).
const std = @import("std");
const vt = @import("vt.zig");
const themes_a = @import("themes_a.zig");
const themes_b = @import("themes_b.zig");

pub const Theme = struct {
    foreground: u24,
    background: u24,
    /// The cursor: the foreground when null. `cursor_text` colors the text
    /// under a block cursor: the background when null.
    cursor: ?u24 = null,
    cursor_text: ?u24 = null,
    /// The selection's highlight: the foreground at a third when null.
    /// `selection_text` colors selected text: its own colors when null.
    selection: ?u24 = null,
    selection_text: ?u24 = null,
    /// Black, red, green, yellow, blue, magenta, cyan, white, then their
    /// bright kinds.
    palette: [16]u24,

    /// The colors of terminals in dark windows: myzig's dark background
    /// and text, with Visual Studio Code's palette.
    pub const dark: Theme = .{
        .foreground = 0xf5f5f7,
        .background = 0x1c1c1e,
        .palette = .{ 0x000000, 0xcd3131, 0x0dbc79, 0xe5e510, 0x2472c8, 0xbc3fbc, 0x11a8cd, 0xe5e5e5, 0x666666, 0xf14c4c, 0x23d18b, 0xf5f543, 0x3b8eea, 0xd670d6, 0x29b8db, 0xffffff },
    };

    /// The colors of terminals in light windows.
    pub const light: Theme = .{
        .foreground = 0x1d1d1f,
        .background = 0xf5f5f7,
        .palette = .{ 0x000000, 0xcd3131, 0x00bc00, 0x949800, 0x0451a5, 0xbc05bc, 0x0598bc, 0x555555, 0x666666, 0xcd3131, 0x14ce14, 0xb5ba00, 0x0451a5, 0xbc05bc, 0x0598bc, 0xa5a5a5 },
    };

    /// Whether the background is dark.
    pub fn isDark(t: Theme) bool {
        const b = t.background;
        const r: u32 = b >> 16;
        const g: u32 = (b >> 8) & 0xff;
        const bl: u32 = b & 0xff;
        return 299 * r + 587 * g + 114 * bl < 128 * 1000;
    }

    /// The 256 colors: the theme's 16, xterm's 6×6×6 cube and 24 grays.
    pub fn palette256(t: Theme) [256]vt.Rgb {
        var p: [256]vt.Rgb = undefined;
        for (t.palette, 0..) |c, i| p[i] = rgb(c);
        const levels = [6]u8{ 0, 95, 135, 175, 215, 255 };
        for (0..216) |i| p[16 + i] = .{ .r = levels[i / 36], .g = levels[i / 6 % 6], .b = levels[i % 6] };
        for (0..24) |i| {
            const v: u8 = @intCast(8 + 10 * i);
            p[232 + i] = .{ .r = v, .g = v, .b = v };
        }
        return p;
    }

    /// Makes the theme the terminal's default colors.
    pub fn apply(t: Theme, term: vt.Vt) void {
        const p = t.palette256();
        term.setColors(rgb(t.foreground), rgb(t.background), if (t.cursor) |c| rgb(c) else null, &p);
    }

    /// A theme in Ghostty's format: `palette = N=#rrggbb`, `background`,
    /// `foreground`, `cursor-color`, `cursor-text`, `selection-background`,
    /// `selection-foreground`; other lines and comments are skipped. What
    /// it leaves out is `base`'s.
    pub fn parse(text: []const u8, base: Theme) !Theme {
        var t = base;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const k = std.mem.trim(u8, line[0..eq], " \t");
            const v = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (std.mem.eql(u8, k, "palette")) {
                const e = std.mem.indexOfScalar(u8, v, '=') orelse return error.BadTheme;
                const i = std.fmt.parseInt(u8, std.mem.trim(u8, v[0..e], " "), 10) catch return error.BadTheme;
                if (i < 16) t.palette[i] = try hex(std.mem.trim(u8, v[e + 1 ..], " "));
            } else if (std.mem.eql(u8, k, "background")) {
                t.background = try hex(v);
            } else if (std.mem.eql(u8, k, "foreground")) {
                t.foreground = try hex(v);
            } else if (std.mem.eql(u8, k, "cursor-color")) {
                t.cursor = try hex(v);
            } else if (std.mem.eql(u8, k, "cursor-text")) {
                t.cursor_text = try hex(v);
            } else if (std.mem.eql(u8, k, "selection-background")) {
                t.selection = try hex(v);
            } else if (std.mem.eql(u8, k, "selection-foreground")) {
                t.selection_text = try hex(v);
            }
        }
        return t;
    }
};

/// A color as `#rrggbb` (or `rrggbb`).
pub fn hex(s: []const u8) !u24 {
    const h = if (s.len > 0 and s[0] == '#') s[1..] else s;
    if (h.len != 6) return error.BadTheme;
    return std.fmt.parseInt(u24, h, 16) catch error.BadTheme;
}

pub fn rgb(c: u24) vt.Rgb {
    return .{ .r = @intCast(c >> 16), .g = @intCast((c >> 8) & 0xff), .b = @intCast(c & 0xff) };
}

/// A theme Ghostty ships: its palette's 16 colors, then the background,
/// the foreground, the cursor's color and text, and the selection's
/// background and text.
pub const Packed = struct { []const u8, [22]u24 };

fn unpack(p: Packed) Theme {
    const c = p[1];
    var t: Theme = .{ .background = c[16], .foreground = c[17], .cursor = c[18], .cursor_text = c[19], .selection = c[20], .selection_text = c[21], .palette = undefined };
    @memcpy(&t.palette, c[0..16]);
    return t;
}

/// The theme Ghostty ships named `name` (its case aside), as Ghostty's
/// `theme` option takes it: "Catppuccin Mocha", "Dracula"…
pub fn ghostty(name: []const u8) ?Theme {
    inline for (.{ themes_a.list, themes_b.list }) |list| {
        for (list) |p| if (std.mem.eql(u8, p[0], name)) return unpack(p);
    }
    inline for (.{ themes_a.list, themes_b.list }) |list| {
        for (list) |p| if (std.ascii.eqlIgnoreCase(p[0], name)) return unpack(p);
    }
    return null;
}

/// How many themes Ghostty ships, and the name of the `i`th, sorted.
pub fn ghosttyCount() usize {
    return themes_a.list.len + themes_b.list.len;
}

pub fn ghosttyName(i: usize) []const u8 {
    return if (i < themes_a.list.len) themes_a.list[i][0] else themes_b.list[i - themes_a.list.len][0];
}

test "Ghostty's themes by name" {
    try std.testing.expect(ghosttyCount() > 500);
    const mocha = ghostty("Catppuccin Mocha").?;
    try std.testing.expectEqual(@as(u24, 0x1e1e2e), mocha.background);
    try std.testing.expectEqual(@as(u24, 0xcdd6f4), mocha.foreground);
    try std.testing.expectEqual(@as(u24, 0xf38ba8), mocha.palette[1]);
    try std.testing.expect(mocha.isDark());
    try std.testing.expect(ghostty("catppuccin mocha") != null);
    try std.testing.expect(ghostty("No Such Theme") == null);
}

test "a theme in Ghostty's format" {
    const t = try Theme.parse("# mine\npalette = 1=#f38ba8\nbackground = #102030\nforeground=#ffffff\ncursor-color = #aabbcc\n", Theme.dark);
    try std.testing.expectEqual(@as(u24, 0x102030), t.background);
    try std.testing.expectEqual(@as(u24, 0xf38ba8), t.palette[1]);
    try std.testing.expectEqual(@as(?u24, 0xaabbcc), t.cursor);
    try std.testing.expectEqual(Theme.dark.palette[2], t.palette[2]);
    try std.testing.expectError(error.BadTheme, Theme.parse("background = nope", Theme.dark));
    const p = Theme.light.palette256();
    try std.testing.expectEqual(vt.Rgb{ .r = 95, .g = 0, .b = 0 }, p[16 + 36]);
}
