//! A drop-down choosing one of a list of strings.
//!
//!     if (ui.select(c, &s.plan, &.{ "Free", "Pro", "Team" }, &s.plan_select, .{}).changed) save();
//!
//! A click on it, or Enter, Space, Up or Down while it has the focus (a
//! click gives it), opens its options below it (above where there is no
//! room); the arrows, Home and End move among them, Enter, Space or a click
//! chooses one, and Escape or a press outside closes them, which the popup
//! takes, as the system's pop-up menus do. The focus comes back to it.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const base = @import("overlay_base.zig");
const listbox = @import("listbox.zig");
const widgets = @import("widgets.zig");
const Context = ctx_mod.Context;

/// A select's state, kept by the app.
pub const SelectState = struct {
    list: listbox.ListState = .{},

    pub fn isOpen(s: *const SelectState) bool {
        return s.list.state.open;
    }
};

pub const SelectOptions = struct {
    width: types.Length = .{ .px = 200 },
    size: f32 = 14,
    /// Shown when `selected` is past the options.
    placeholder: []const u8 = "Choose…",
    disabled: bool = false,
    /// Names it for assistive technology.
    label: []const u8 = "",
};

pub const SelectResult = struct {
    /// A new option was chosen in this frame.
    changed: bool = false,
    open: bool = false,
    focused: bool = false,
};

pub fn select(c: *Context, selected: *usize, options: []const []const u8, s: *SelectState, opts: SelectOptions) SelectResult {
    const th = c.theme;
    const l = &s.list;
    const box = c.open(.{
        .direction = .row,
        .width = opts.width,
        .padding = .xy(10, opts.size * 0.45),
        .gap = 8,
        .radius = 8,
        .align_items = .center,
        .background = th.surface,
        .border = th.border,
        .opacity = if (opts.disabled) 0.45 else 1,
        .control = true,
    }, null);
    var it = c.interact(box, .{ .focusable = !opts.disabled });
    if (opts.disabled) {
        it.clicked = false;
        it.hovered = false;
    }
    const hover = c.animate(it.id, 0, if (it.hovered or l.state.open) 1 else 0, 20);
    const focus = c.animate(it.id, 1, if (it.focused) 1 else 0, 20);
    const n = c.node(box);
    n.style.background = th.surface.mix(th.surface_hover, hover * 0.6);
    n.style.border = th.border.mix(th.accent, focus);
    n.style.shadow = if (focus > 0.01) .{ .color = th.accent.alpha(0.25 * focus), .blur = 6, .y = 0 } else .{ .color = th.shadow.alpha(0.5), .blur = 2, .y = 1 };
    _ = c.open(.{ .grow = 1, .clip = true }, null);
    if (selected.* < options.len)
        widgets.text(c, options[selected.*], .{ .size = opts.size })
    else
        widgets.text(c, opts.placeholder, .{ .size = opts.size, .color = th.muted });
    c.end();
    widgets.icon(c, "chevron.up.chevron.down", .{ .size = opts.size * 0.8, .color = th.muted });
    c.end();

    var result: SelectResult = .{ .focused = it.focused };
    c.describe(it.id, .{ .role = .popup_button, .label = opts.label, .value = if (selected.* < options.len) options[selected.*] else "", .disabled = opts.disabled, .expanded = l.state.open });
    if (opts.disabled) return result;
    const current: i32 = if (selected.* < options.len) @intCast(selected.*) else -1;
    if (!l.state.open) {
        const by_key = it.focused and (base.takeKey(c, .down) or base.takeKey(c, .up) or base.takeKey(c, .enter) or base.takeSpace(c));
        if (it.clicked or by_key) {
            l.openWith(if (current >= 0) current else 0);
            c.changed = true;
        }
    }
    var chosen = listbox.navigate(c, l, options.len, true);
    if (it.rect) |r| {
        if (listbox.popup(c, l, r, options, .{ .selected = selected.*, .catcher = true })) |i| chosen = i;
    } else if (l.state.open) c.animationFrame();
    if (chosen) |i| {
        if (l.state.open) {
            l.state.open = false;
            _ = l.state.sync(c);
        }
        c.changed = true;
        if (i != selected.*) {
            selected.* = i;
            result.changed = true;
        }
    }
    // Back on the select as its popup closes.
    if (!l.state.open and l.state.shown) _ = l.state.sync(c);
    result.open = l.state.open;
    c.describe(it.id, .{ .expanded = l.state.open, .active_descendant = if (l.state.open) l.highlight_id else 0 });
    return result;
}
