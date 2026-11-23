//! SVG pictures in native UI: `ui.svg(c, bytes, .{ .width = 24 })` draws
//! an SVG file (`svg_draw.zig` says what of it) as a canvas does, at the
//! window's scale, and keeps the picture: a frame showing the same bytes
//! at the same size hashes them and draws the kept picture, without
//! parsing them again.
//!
//!     const logo = @embedFile("logo.svg");
//!     _ = ui.svg(c, logo, .{ .height = 32 });
//!     _ = ui.svg(c, icon, .{ .width = 16, .color = c.theme.accent }); // currentColor
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const canvas = @import("canvas.zig");
const xml = @import("svg_xml.zig");
const draw_mod = @import("svg_draw.zig");
const render_mod = @import("canvas_render.zig");
const path = @import("path.zig");
const Context = ctx_mod.Context;
const Color = types.Color;

pub const SvgOptions = struct {
    /// Its size in points; a side of 0 keeps the document's proportions to
    /// the other, and both 0 take its own size.
    width: f32 = 0,
    height: f32 = 0,
    /// What `currentColor` is; null: the theme's text color.
    color: ?Color = null,
    opacity: f32 = 1,
    key: ?[]const u8 = null,
    /// An icon of strokes (Lucide's, Feather's): drawn on the pixel grid
    /// (`nudge`), so a line a pixel or so wide covers a pixel, not half of
    /// two. Icons myzig draws (`ui.icon`) are.
    crisp: bool = false,
};

/// Draws an SVG document; false (and nothing drawn) if it isn't one.
pub fn svg(c: *Context, bytes: []const u8, opts: SvgOptions) bool {
    const own = rootSize(c.alloc(), bytes) orelse return false;
    const size = fitSize(own, opts.width, opts.height);
    if (!(size.w > 0 and size.h > 0)) return false;
    const id = c.peekId(opts.key);
    const color = opts.color orelse c.theme.text;
    const shift: f32 = if (opts.crisp) nudge(c.alloc(), bytes, size.w * c.scale) else 0;
    var h = std.hash.Wyhash.init(0x737667);
    h.update(bytes);
    h.update(std.mem.asBytes(&[_]f32{ color.r, color.g, color.b, color.a, shift }));
    const Source = struct {
        bytes: []const u8,
        color: Color,
        size: types.Size,
        shift: f32,
        pub fn render(s: @This(), gpa: std.mem.Allocator, out: []u8, w: usize, hh: usize, base: path.Transform) !void {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const cmds = try record(arena.allocator(), s.bytes, s.size, s.color);
            try render_mod.render(gpa, cmds, out, w, hh, base.then(.translation(s.shift, s.shift)));
        }
    };
    _ = canvas.picture(c, id, size, size, .{ .key = opts.key, .opacity = opts.opacity }, h.final(), Source{ .bytes = bytes, .color = color, .size = size, .shift = shift });
    return true;
}

/// How far (in pixels, both ways) to move an icon `px` pixels wide so its
/// strokes fall on the pixel grid. An icon's lines are mostly on whole
/// units of its grid, its middle line among them: a stroke an odd number
/// of pixels wide (one, at 1x) is sharp with its middle on a pixel's
/// middle, an even one (two, at 2x) with it between pixels. Its stroke
/// width is the root's `stroke-width` over its viewBox; no stroke, no move.
pub fn nudge(arena: std.mem.Allocator, bytes: []const u8, px: f32) f32 {
    const at = std.mem.indexOf(u8, bytes, "<svg") orelse return 0;
    const end = std.mem.indexOfScalarPos(u8, bytes, at, '>') orelse return 0;
    const doc = xml.parse(arena, bytes[at .. end + 1]) catch return 0;
    if (doc.elements.len == 0 or !(px > 0)) return 0;
    const root = doc.elements[0];
    const sw = std.fmt.parseFloat(f32, std.mem.trim(u8, root.attr("stroke-width") orelse return 0, " ")) catch return 0;
    const vb = draw_mod.viewBox(root) orelse return 0;
    if (!(vb[2] > 0) or !(sw > 0)) return 0;
    const stroke = @round(sw * px / vb[2]);
    const want: f32 = if (@mod(stroke, 2) == 1) 0.5 else 0;
    const middle = px / 2;
    var d = want - (middle - @floor(middle));
    if (d > 0.5) d -= 1;
    if (d <= -0.5) d += 1;
    return d;
}

test "an icon's strokes moved onto the pixel grid" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const icon = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"><path d=\"M5 12h14\"/></svg>";
    // 14 or 16 pixels (1x): a stroke of one pixel, its middle between two: half a pixel over.
    try std.testing.expectEqual(@as(f32, 0.5), nudge(arena.allocator(), icon, 14));
    try std.testing.expectEqual(@as(f32, 0.5), nudge(arena.allocator(), icon, 16));
    // 28 pixels (2x): two pixels wide, between two already.
    try std.testing.expectEqual(@as(f32, 0), nudge(arena.allocator(), icon, 28));
    // 15 pixels: its middle on a pixel's middle already.
    try std.testing.expectEqual(@as(f32, 0), nudge(arena.allocator(), icon, 15));
    try std.testing.expectEqual(@as(f32, 0), nudge(arena.allocator(), "<svg viewBox=\"0 0 24 24\"><rect/></svg>", 14));
}

/// A size from the document's own and what is asked for.
pub fn fitSize(own: types.Size, w: f32, h: f32) types.Size {
    if (w > 0 and h > 0) return .{ .w = w, .h = h };
    if (!(own.w > 0 and own.h > 0)) return .{ .w = w, .h = h };
    if (w > 0) return .{ .w = w, .h = w * own.h / own.w };
    if (h > 0) return .{ .w = h * own.w / own.h, .h = h };
    return own;
}

/// The document's own size, from its root element alone.
pub fn rootSize(arena: std.mem.Allocator, bytes: []const u8) ?types.Size {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, at, "<svg")) |i| {
        // Past comments that mention it.
        const comment = std.mem.lastIndexOf(u8, bytes[0..i], "<!--");
        if (comment) |cm| if (std.mem.indexOfPos(u8, bytes, cm, "-->")) |ce| if (ce > i) {
            at = ce;
            continue;
        };
        const end = std.mem.indexOfScalarPos(u8, bytes, i, '>') orelse return null;
        const doc = xml.parse(arena, bytes[i .. end + 1]) catch return null;
        if (doc.elements.len == 0) return null;
        return draw_mod.intrinsic(doc);
    }
    return null;
}

/// The drawing of an SVG document `size` points large.
pub fn record(arena: std.mem.Allocator, bytes: []const u8, size: types.Size, current_color: Color) ![]const render_mod.Cmd {
    const doc = try xml.parse(arena, bytes);
    var p: canvas.Painter = .{ .arena = arena, .size = size };
    try draw_mod.draw(arena, doc, &p, current_color);
    return p.cmds.items;
}

/// An SVG document drawn into premultiplied BGRA pixels, `w` × `h` (its
/// viewBox fitted to them): for icons made ahead, and tests. Free with `gpa`.
pub fn rasterize(gpa: std.mem.Allocator, bytes: []const u8, w: usize, h: usize, current_color: Color) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const size: types.Size = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
    const cmds = try record(arena.allocator(), bytes, size, current_color);
    const out = try gpa.alloc(u8, w * h * 4);
    errdefer gpa.free(out);
    @memset(out, 0);
    try render_mod.render(gpa, cmds, out, w, h, .identity);
    return out;
}
