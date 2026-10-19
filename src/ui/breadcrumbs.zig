//! Breadcrumbs: a path of items separated by chevrons, as Finder's path
//! bar. The items but the last are links, which a click chooses, as Enter
//! does while one has the keyboard focus, setting `chosen.*` to its index;
//! the last is where the user is, which is no link.
//!
//!     const path: []const []const u8 = &.{ "Macintosh HD", "Users", "ada", "Documents" };
//!     if (ui.breadcrumbs(c, path, &s.chosen, .{})) open(path[0 .. s.chosen + 1]);
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const structure = @import("structure.zig");
const widgets = @import("widgets.zig");
const Context = ctx_mod.Context;

pub const Options = struct {
    size: f32 = 13,
    /// Each item at most this wide; longer ones are clipped.
    max_item_width: f32 = 200,
};

/// True when a link was chosen in this frame.
pub fn breadcrumbs(c: *Context, items: []const []const u8, chosen: *usize, opts: Options) bool {
    const th = c.theme;
    _ = c.open(.{ .direction = .row, .align_items = .center, .gap = 2 }, null);
    defer c.end();
    var picked = false;
    for (items, 0..) |name, i| {
        const last = i + 1 == items.len;
        if (i > 0) widgets.icon(c, "chevron.right", .{ .size = 10, .frame = 14, .color = th.muted });
        c.next_key_int = i;
        const box = c.open(.{ .direction = .row, .padding = .xy(5, 2), .radius = 5, .max_width = opts.max_item_width, .clip = true, .control = true }, null);
        defer c.end();
        if (last) {
            widgets.text(c, name, .{ .size = opts.size, .weight = .semibold });
            continue;
        }
        const it = c.interact(box, .{ .focusable = true });
        var go = it.clicked;
        if (it.focused) if (c.input.key) |k| if (k == .enter) {
            _ = structure.takeKey(c);
            go = true;
        };
        if (go) {
            chosen.* = i;
            picked = true;
            c.changed = true;
        }
        const hover = c.animate(it.id, 0, if (it.hovered) 1 else 0, 20);
        const n = c.node(box);
        n.style.background = th.text.alpha(0.06 * hover);
        if (it.focused) n.style.border = th.accent;
        widgets.text(c, name, .{ .size = opts.size, .color = th.muted.mix(th.accent, hover) });
    }
    return picked;
}
