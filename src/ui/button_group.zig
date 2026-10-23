//! Joined actions and toggle buttons with one roving keyboard stop.
const std = @import("std");
const Context = @import("context.zig").Context;
const widgets = @import("widgets.zig");
const focus = @import("focusgroup.zig");

pub const Options = struct {
    vertical: bool = false,
    label: []const u8 = "",
    disabled: bool = false,
};

pub const Group = struct {
    group: focus.FocusGroup,
    opts: Options,
    count: usize = 0,

    pub fn button(g: *Group, title: []const u8, options: widgets.ButtonOptions) bool {
        const c = g.group.c;
        if (g.count != 0) _ = c.leaf(if (g.opts.vertical)
            .{ .width = .fill, .height = .{ .px = 1 }, .background = c.theme.border }
        else
            .{ .width = .{ .px = 1 }, .height = .fill, .background = c.theme.border }, .none, null);
        g.count += 1;
        var opts = options;
        opts.disabled = opts.disabled or g.opts.disabled;
        const i: u32 = @intCast(c.nodes.items.len);
        const it = widgets.button(c, title, opts);
        c.node(i).style.radius = 0;
        return it.clicked;
    }

    pub fn end(g: Group) void {
        _ = g.group.end();
    }
};

pub fn buttonGroup(c: *Context, opts: Options) Group {
    const g = focus.focusGroup(c, .{ .direction = if (opts.vertical) .column else .row, .radius = 8, .border = c.theme.border, .clip = true }, .{ .orientation = if (opts.vertical) .vertical else .horizontal });
    c.describe(c.node(g.index).id, .{ .role = .group, .label = opts.label, .disabled = opts.disabled });
    return .{ .group = g, .opts = opts };
}

pub const Item = struct {
    label: []const u8,
    icon: []const u8 = "",
    disabled: bool = false,
};

pub const ToggleOptions = struct {
    vertical: bool = false,
    label: []const u8 = "",
    disabled: bool = false,
    multiple: bool = false,
    allow_empty: bool = true,
};

/// `selected` is app-owned, one flag per item. In single mode callers
/// initialize at most one flag. Arrows move focus; Space/Enter toggle.
pub fn toggleGroup(c: *Context, items: []const Item, selected: []bool, opts: ToggleOptions) bool {
    std.debug.assert(items.len == selected.len);
    const g = focus.focusGroup(c, .{ .direction = if (opts.vertical) .column else .row, .gap = 3, .padding = .all(3), .radius = 8, .border = c.theme.border }, .{ .orientation = if (opts.vertical) .vertical else .horizontal });
    defer _ = g.end();
    c.describe(c.node(g.index).id, .{ .role = .group, .label = opts.label, .disabled = opts.disabled });
    var changed = false;
    for (items, 0..) |item, k| {
        c.next_key_int = k;
        const i: u32 = @intCast(c.nodes.items.len);
        const disabled = opts.disabled or item.disabled;
        const it = widgets.button(c, item.label, .{ .variant = if (selected[k]) .secondary else .ghost, .icon = item.icon, .disabled = disabled });
        c.describe(it.id, .{ .role = .toggle_button, .label = item.label, .checked = if (selected[k]) .on else .off, .disabled = disabled });
        if (selected[k]) c.node(i).style.background = c.theme.accent.alpha(0.15);
        if (!disabled and it.clicked) {
            const next = !selected[k];
            if (!next and !opts.allow_empty) {
                var count: usize = 0;
                for (selected) |on| if (on) {
                    count += 1;
                };
                if (count <= 1) continue;
            }
            if (next and !opts.multiple) @memset(selected, false);
            selected[k] = next;
            changed = true;
            c.changed = true;
        }
    }
    return changed;
}
