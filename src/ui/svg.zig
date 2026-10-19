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
};

/// Draws an SVG document; false (and nothing drawn) if it isn't one.
pub fn svg(c: *Context, bytes: []const u8, opts: SvgOptions) bool {
    const own = rootSize(c.alloc(), bytes) orelse return false;
    const size = fitSize(own, opts.width, opts.height);
    if (!(size.w > 0 and size.h > 0)) return false;
    const id = c.peekId(opts.key);
    const color = opts.color orelse c.theme.text;
    var h = std.hash.Wyhash.init(0x737667);
    h.update(bytes);
    h.update(std.mem.asBytes(&[_]f32{ color.r, color.g, color.b, color.a }));
    const Source = struct {
        bytes: []const u8,
        color: Color,
        size: types.Size,
        pub fn render(s: @This(), gpa: std.mem.Allocator, out: []u8, w: usize, hh: usize, base: path.Transform) !void {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const cmds = try record(arena.allocator(), s.bytes, s.size, s.color);
            try render_mod.render(gpa, cmds, out, w, hh, base);
        }
    };
    _ = canvas.picture(c, id, size, size, .{ .key = opts.key, .opacity = opts.opacity }, h.final(), Source{ .bytes = bytes, .color = color, .size = size });
    return true;
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
