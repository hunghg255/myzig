//! Icons drawn from SVG into the glyph atlas: the app's own (`app_icons`)
//! and, where there are no SF Symbols (Linux, Windows), Lucide's for an SF
//! Symbol's name (`lucide_symbols`). They stay icons (`ui.icon`, a node of
//! `.icon` content, colored as text is): only their mask changes, drawn
//! on the pixel grid (`svg.nudge`) so their strokes stay sharp.
const std = @import("std");
const builtin = @import("builtin");
const svg = @import("svg.zig");
const lucide = @import("lucide.zig");
const render_mod = @import("canvas_render.zig");
const path = @import("path.zig");
const types = @import("types.zig");

/// Icons an app draws itself, as SVG in `currentColor` (Lucide's, from
/// `ui.lucide.svg`, or its own), by name: asked first, for every icon
/// myzig draws, its menus' and controls' too, at the size asked for.
/// Null: none. Set it before the first frame.
pub var app_icons: ?*const fn (name: []const u8) ?[]const u8 = null;

/// Whether an SF Symbol's name draws Lucide's icon for it (`lucide.symbol`)
/// rather than myzig's own line icon, where there are no SF Symbols. On by
/// default; set it before the first frame.
pub var lucide_symbols: bool = builtin.os.tag != .macos;

/// An icon's document, and the side of its square in points.
pub const Source = struct { bytes: []const u8, side: f32 };

/// The SVG icon `name` draws at `point_size`, if any. Lucide's in place of
/// an SF Symbol is a fifth larger, as the symbols and myzig's line icons
/// are than their point size.
pub fn find(name: []const u8, point_size: f32) ?Source {
    if (app_icons) |f| if (f(name)) |b| return .{ .bytes = b, .side = point_size };
    if (lucide_symbols and builtin.os.tag != .macos) if (lucide.symbol(name)) |b| return .{ .bytes = b, .side = point_size * 1.2 };
    return null;
}

/// The coverage of `bytes` drawn `px` pixels square, on the pixel grid,
/// into `out` (`stride` bytes a row) at `x`, `y`.
pub fn mask(gpa: std.mem.Allocator, bytes: []const u8, px: u32, out: []u8, stride: usize, x: usize, y: usize) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const side: f32 = @floatFromInt(px);
    const cmds = try svg.record(a, bytes, .{ .w = side, .h = side }, types.Color.white);
    const shift = svg.nudge(a, bytes, side);
    const bgra = try a.alloc(u8, @as(usize, px) * px * 4);
    @memset(bgra, 0);
    try render_mod.render(gpa, cmds, bgra, px, px, path.Transform.translation(shift, shift));
    for (0..px) |row| for (0..px) |col| {
        out[(y + row) * stride + x + col] = bgra[(row * px + col) * 4 + 3];
    };
}

test "an icon's mask, sharp at 1x" {
    const gpa = std.testing.allocator;
    const plus = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\"><path d=\"M5 12h14\"/><path d=\"M12 5v14\"/></svg>";
    var out: [16 * 16]u8 = undefined;
    @memset(&out, 0);
    try mask(gpa, plus, 16, &out, 16, 0, 0);
    // The vertical line, moved half a pixel, covers column 8 whole: not
    // half of 7 and half of 8.
    try std.testing.expect(out[5 * 16 + 8] > 200);
    try std.testing.expect(out[5 * 16 + 7] < 100);
    try std.testing.expect(find("checkmark", 14) != null or builtin.os.tag == .macos);
    try std.testing.expect(find("no.such.icon", 14) == null);
}
