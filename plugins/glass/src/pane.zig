//! Panes of glass in native UI: boxes whose children draw on glass. A pane
//! is a box with a backdrop effect (`ui.Style.effect`, `shader.zig`): every
//! renderer (Metal, Direct3D 11, OpenGL, WebGL 2 and the CPU) reads what it
//! drew under the pane, blurs it, and draws the glass from it before the
//! pane's children, which draw on it unfrosted.
//!
//!     fn view(s: *State, c: *ui.Context) void {
//!         // ... content ...
//!         _ = glass.pane(c, .{}, .{ .padding = .all(12), .absolute = true, .offset = .{ .x = 20, .y = 20 } });
//!         ui.text(c, "On glass", .{});
//!         c.end();
//!     }
const std = @import("std");
const ui = @import("myzig").ui;
const material = @import("material.zig");
const shader = @import("shader.zig");

pub const Glass = struct {
    style: material.Style = .regular,
    /// Colors the glass toward a color, by its alpha, as a prominent button.
    tint: ?ui.Color = null,
    radius: f32 = 16,
};

/// What a pane is made of: glass, or a plain backdrop blur of `radius` DIPs.
pub const Kind = union(enum) {
    glass: Glass,
    blur: struct { radius: f32, corner: f32 = 0 },
};

/// Opens a pane of `kind` styled by `style` (its size, padding, place…);
/// its children follow until `c.end()`. Returns its box. The material
/// follows the pane's size as the last frame laid it out.
pub fn paneOf(c: *ui.Context, kind: Kind, style_in: ui.Style) u32 {
    var style = style_in;
    const e = c.alloc().create(shader.Effect) catch return c.open(style, null);
    switch (kind) {
        .glass => |g| {
            style.radius = g.radius;
            const last = c.rects.get(c.peekId(null));
            const w = if (last) |r| r.w else if (style.width == .px) style.width.px else 200;
            const h = if (last) |r| r.h else if (style.height == .px) style.height.px else 44;
            const m = material.of(g.style, if (g.tint) |t| .{ t.r, t.g, t.b, t.a } else null, w, h, c.scale, c.theme.dark);
            e.* = shader.effectOf(m, c.scale);
        },
        .blur => |b| {
            style.radius = b.corner;
            e.* = shader.blurOf(b.radius);
        },
    }
    style.effect = e;
    return c.open(style, null);
}

/// Opens a pane of glass; its children follow until `c.end()`.
pub fn pane(c: *ui.Context, g: Glass, style: ui.Style) u32 {
    return paneOf(c, .{ .glass = g }, style);
}
