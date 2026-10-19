//! Tabs: a row of labels of which one is chosen, over the page the view
//! builds for it. A click chooses a tab, as do the arrows, Home and End
//! while the tab bar has the keyboard focus, which a click gives it.
//!
//!     if (ui.tabs(c, &.{ "General", "Appearance", "Advanced" }, &s.tab).changed) save(s);
//!     switch (s.tab) {
//!         0 => general(s, c),
//!         1 => appearance(s, c),
//!         else => advanced(s, c),
//!     }
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const structure = @import("structure.zig");
const widgets = @import("widgets.zig");
const Context = ctx_mod.Context;

pub const Options = struct {
    width: types.Length = .fill,
    size: f32 = 13,
};

pub const Result = struct {
    /// A click or a key chose another tab.
    changed: bool = false,
    focused: bool = false,
};

pub fn tabs(c: *Context, labels: []const []const u8, selected: *usize, opts: Options) Result {
    const th = c.theme;
    const bar = c.open(.{ .direction = .row, .width = opts.width, .gap = 4, .padding = .{ .left = 4, .right = 4 }, .control = true }, null);
    defer c.end();
    // The bar is one stop of the keyboard: it takes the focus, the tabs don't.
    const bar_it = c.interact(bar, .{ .focusable = true });
    c.describe(bar_it.id, .{ .role = .tab_list });
    var result: Result = .{ .focused = c.focus == bar_it.id };
    if (labels.len == 0) return result;
    if (selected.* >= labels.len) selected.* = labels.len - 1;

    if (result.focused) if (c.input.key) |k| {
        if (structure.step(k, selected.*, labels.len, .left, .right, 1)) |to| {
            _ = structure.takeKey(c);
            if (to != selected.*) {
                selected.* = to;
                result.changed = true;
            }
            c.changed = true;
        }
    };

    for (labels, 0..) |lab, i| {
        c.next_key_int = i;
        const tab = c.open(.{ .direction = .column, .align_items = .center, .gap = 5, .padding = .{ .left = 10, .right = 10, .top = 7 }, .radius = 6 }, null);
        defer c.end();
        const it = c.interact(tab, .{});
        if (it.pressed or it.clicked) {
            if (c.focus != bar_it.id) {
                c.focus = bar_it.id;
                result.focused = true;
                c.changed = true;
            }
        }
        if (it.clicked and selected.* != i) {
            selected.* = i;
            result.changed = true;
            c.changed = true;
        }
        // The bar keeps the focus for the tab chosen.
        c.describe(it.id, .{ .role = .tab, .label = lab, .selected = selected.* == i, .pos_in_set = @intCast(i + 1), .set_size = @intCast(labels.len) });
        if (selected.* == i) c.describe(bar_it.id, .{ .active_descendant = it.id });
        const on = c.animate(it.id, 0, if (selected.* == i) 1 else 0, 20);
        const hover = c.animate(it.id, 1, if (it.hovered) 1 else 0, 20);
        c.node(tab).style.background = th.text.alpha(0.05 * hover * (1 - on));
        widgets.text(c, lab, .{
            .size = opts.size,
            .weight = if (selected.* == i) .semibold else .regular,
            .color = th.muted.mix(th.text, on),
        });
        // The underline of the tab chosen, which fades from tab to tab.
        _ = c.leaf(.{
            .width = .fill,
            .height = .{ .px = 2 },
            .radius = 1,
            .background = (if (result.focused) th.accent else th.text).alpha(on),
        }, .none, "underline");
    }
    return result;
}
