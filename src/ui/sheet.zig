//! An edge panel using the dialog's modal behavior and focus restoration.
const dialog_mod = @import("dialog.zig");
const Context = @import("context.zig").Context;
const OverlayState = @import("overlay_base.zig").OverlayState;
const motion = @import("motion.zig");
const direction = @import("direction.zig");

pub const Side = enum { left, right, top, bottom };

pub const Options = struct {
    side: Side = .right,
    /// Width for left/right panels, height for top/bottom panels.
    size: f32 = 360,
    label: []const u8 = "Sheet",
    dismissible: bool = true,
    escape: bool = true,
};

pub const Sheet = struct {
    panel: dialog_mod.Dialog,

    pub fn end(s: Sheet) void {
        s.panel.end();
    }
};

pub fn sheet(c: *Context, state: *OverlayState, opts: Options) ?Sheet {
    const content_direction = direction.current(c);
    const d = dialog_mod.dialog(c, state, .{ .dismissible = opts.dismissible, .escape = opts.escape, .animated = !motion.reduced(c) }) orelse return null;
    // Edge placement is physical; only the contents follow text direction.
    direction.scope(c, d.backdrop, .ltr);
    direction.scope(c, d.panel, content_direction);
    const horizontal = opts.side == .left or opts.side == .right;
    const at_start = opts.side == .left or opts.side == .top;
    const backdrop = d.backdropStyle();
    backdrop.direction = if (horizontal) .row else .column;
    backdrop.align_items = .stretch;
    backdrop.justify = if (at_start) .start else .end;
    const panel = d.panelStyle();
    panel.width = if (horizontal) .{ .px = @max(0, @min(opts.size, c.size.w)) } else .fill;
    panel.height = if (horizontal) .fill else .{ .px = @max(0, @min(opts.size, c.size.h)) };
    panel.max_width = c.size.w;
    panel.max_height = c.size.h;
    panel.radius = 0;
    panel.scroll = true;
    panel.clip = true;
    const shift = (1 - panel.opacity) * (if (at_start) @as(f32, -24) else 24);
    panel.offset = if (horizontal) .{ .x = shift } else .{ .y = shift };
    c.describe(c.node(d.panel).id, .{ .label = opts.label });
    return .{ .panel = d };
}
