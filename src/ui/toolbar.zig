//! A toolbar: a row of controls along the top of a window, which take no
//! face of their own until hovered, and a spacer pushing those after it to
//! the end.
//!
//!     var tb = ui.toolbar(c, .{});
//!     if (tb.button("Back", .{ .icon = "arrow.right" })) back(s);
//!     _ = tb.toggle("Bold", &s.bold);
//!     tb.spacer();
//!     if (tb.button("Share", .{})) share(s);
//!     tb.end();
//!
//! A toolbar is one stop of the keyboard: a click on a control gives it
//! the focus, Left and Right then move among its controls, Home and End to
//! the first and the last, and Enter or Space presses the one shown.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const structure = @import("structure.zig");
const widgets = @import("widgets.zig");
const Context = ctx_mod.Context;

pub const Options = struct {
    width: types.Length = .fill,
    height: f32 = 40,
    /// A line under the toolbar.
    border: bool = true,
};

pub const ButtonOptions = struct {
    /// An SF Symbol before the title (alone if the title is empty).
    icon: []const u8 = "",
    disabled: bool = false,
};

pub const Toolbar = struct {
    c: *Context,
    id: u64,
    focused: bool,
    /// The control the keys are on, kept across frames.
    current: *f32,
    /// The control Enter or Space pressed in this event.
    activate: ?usize,
    count: usize = 0,
    border: bool = true,

    fn control(tb: *Toolbar, title: []const u8, icon: []const u8, on: bool, disabled: bool) bool {
        const c = tb.c;
        const th = c.theme;
        const index = tb.count;
        tb.count += 1;
        c.next_key_int = index;
        const box = c.open(.{ .direction = .row, .align_items = .center, .gap = 5, .padding = .xy(8, 5), .radius = 6, .control = true, .opacity = if (disabled) 0.45 else 1 }, null);
        defer c.end();
        var it = c.interact(box, .{});
        c.describe(it.id, .{ .role = if (on) .toggle_button else .button, .label = if (title.len > 0) title else icon, .disabled = disabled, .checked = if (on) .on else null });
        if (disabled) it = .{ .id = it.id, .rect = it.rect, .hovered = false, .pressed = false, .clicked = false, .focused = false };
        if (it.pressed and c.input.pressed) {
            tb.current.* = @floatFromInt(index);
            if (c.focus != tb.id) {
                c.focus = tb.id;
                tb.focused = true;
            }
            c.changed = true;
        }
        const keyed = !disabled and tb.activate == index;
        const hover = c.animate(it.id, 0, if (it.hovered) 1 else 0, 20);
        const n = c.node(box);
        n.style.background = if (on) th.text.alpha(0.12) else th.text.alpha(0.07 * hover);
        if (tb.focused and @as(usize, @intFromFloat(tb.current.*)) == index) n.style.border = th.accent;
        const fg = if (on) th.accent else th.text;
        if (icon.len > 0) widgets.icon(c, icon, .{ .size = 14, .weight = .medium, .color = fg });
        if (title.len > 0) widgets.text(c, title, .{ .size = 13, .weight = .medium, .color = fg });
        const clicked = it.clicked or keyed;
        if (clicked) c.changed = true;
        return clicked;
    }

    /// A button; true when clicked (or pressed with the keys).
    pub fn button(tb: *Toolbar, title: []const u8, opts: ButtonOptions) bool {
        return tb.control(title, opts.icon, false, opts.disabled);
    }

    /// A button that stays down while `value.*` is true; true when toggled.
    pub fn toggle(tb: *Toolbar, title: []const u8, value: *bool) bool {
        return tb.toggleIcon(title, "", value);
    }

    pub fn toggleIcon(tb: *Toolbar, title: []const u8, icon: []const u8, value: *bool) bool {
        if (!tb.control(title, icon, value.*, false)) return false;
        value.* = !value.*;
        return true;
    }

    /// Pushes the controls after it to the end.
    pub fn spacer(tb: *Toolbar) void {
        widgets.spacer(tb.c);
    }

    /// A thin vertical line between groups of controls.
    pub fn separator(tb: *Toolbar) void {
        _ = tb.c.leaf(.{ .width = .{ .px = 1 }, .height = .{ .px = 18 }, .background = tb.c.theme.border }, .none, null);
    }

    pub fn end(tb: *Toolbar) void {
        const c = tb.c;
        if (tb.focused and tb.count > 0) if (c.input.key) |k| {
            const cur: usize = @min(tb.count - 1, @as(usize, @intFromFloat(tb.current.*)));
            if (structure.step(k, cur, tb.count, .left, .right, 1)) |to| {
                _ = structure.takeKey(c);
                tb.current.* = @floatFromInt(to);
                c.changed = true;
            }
        };
        c.end();
        if (tb.border) widgets.divider(c);
        c.end();
    }
};

pub fn toolbar(c: *Context, opts: Options) Toolbar {
    _ = c.open(.{ .direction = .column, .width = opts.width }, null);
    const bar = c.open(.{ .direction = .row, .width = .fill, .height = .{ .px = opts.height }, .align_items = .center, .gap = 4, .padding = .xy(8, 0) }, null);
    const it = c.interact(bar, .{ .focusable = true });
    c.describe(it.id, .{ .role = .toolbar });
    const focused = c.focus == it.id;
    const current = structure.slot(c, it.id, 0, 0);
    var activate: ?usize = null;
    if (focused) {
        if (c.input.key) |k| if (k == .enter) {
            _ = structure.takeKey(c);
            activate = @intFromFloat(current.*);
        };
        if (structure.typedSpace(c)) {
            c.input.chars = "";
            activate = @intFromFloat(current.*);
        }
    }
    return .{ .c = c, .id = it.id, .focused = focused, .current = current, .activate = activate, .border = opts.border };
}
