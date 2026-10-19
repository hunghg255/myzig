//! Menus drawn in the window: context menus, menu buttons and menus of any
//! button, with items, check marks, shortcuts shown, separators and
//! submenus.
//!
//!     const row = ui.pressable(c, .{ ... }, null);
//!     ...children...
//!     ui.end(c);
//!     if (ui.contextMenu(c, &s.menu, row)) |m| {
//!         defer m.end();
//!         if (m.item("Rename", .{ .shortcut = "F2" })) s.renaming = true;
//!         if (m.item("Pinned", .{ .checked = s.pinned })) s.pinned = !s.pinned;
//!         if (m.submenu("Move to")) |sub| {
//!             defer sub.end();
//!             for (s.folders, 0..) |f, i| if (sub.item(f, .{})) s.move(i);
//!         }
//!         m.separator();
//!         if (m.item("Delete", .{ .disabled = s.locked })) s.delete();
//!     }
//!
//! The items are built while the menu is open; `item` is true in the frame
//! it is chosen (clicked, or Enter or Space on it), which closes the menu.
//! Up and Down move among the items, Right and Left open and close
//! submenus, Escape closes the innermost menu. As the system's menus, an
//! open menu takes the press outside it, which closes it.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const base = @import("overlay_base.zig");
const widgets = @import("widgets.zig");
const Context = ctx_mod.Context;
const Interaction = ctx_mod.Interaction;

/// How deep submenus go.
pub const max_depth = 4;
/// Items in one menu the keyboard moves among (more are drawn, but skipped).
pub const max_items = 64;

/// A menu's state, kept by the app.
pub const Menu = struct {
    state: base.OverlayState = .{},
    /// Where it opens: below this rectangle (a point for a context menu).
    at: types.Rect = .{},
    /// The item highlighted in each level, -1 for none.
    highlight: [max_depth]i32 = @splat(-1),
    /// Submenus open: level `depth` takes the keyboard.
    depth: u8 = 0,
    /// The pointer as last seen: it highlights only when it moves.
    mouse: types.Point = .{ .x = -1e6, .y = -1e6 },

    pub fn isOpen(m: *const Menu) bool {
        return m.state.open;
    }

    /// Opens the menu with its top left corner at `p` (in window points).
    pub fn openAt(m: *Menu, p: types.Point) void {
        m.openBelow(.{ .x = p.x, .y = p.y });
    }

    /// Opens the menu below `r` (or above it, where there is no room).
    pub fn openBelow(m: *Menu, r: types.Rect) void {
        m.state.open = true;
        m.at = r;
        m.highlight = @splat(-1);
        m.depth = 0;
        m.mouse = .{ .x = -1e6, .y = -1e6 };
    }

    pub fn close(m: *Menu) void {
        m.state.open = false;
    }
};

pub const ItemOptions = struct {
    /// A key combination shown by it, as the shortcut that does the same
    /// (`ui.keys.label("⌘R")`): it only shows it.
    shortcut: []const u8 = "",
    /// Shows a check mark by it when true (and room for one when false).
    checked: ?bool = null,
    /// Grayed out: it cannot be chosen.
    disabled: bool = false,
    /// An SF Symbol (or line icon) before the label.
    icon: []const u8 = "",
};

/// One open menu (or submenu): its items follow, then `end`.
pub const MenuPanel = struct {
    c: *Context,
    menu: *Menu,
    level: u8,
    index: u32,
    anchor: types.Rect,
    count: u16 = 0,
    enabled: [max_items]bool = undefined,
    /// A submenu of this level was built (open) in this frame.
    sub_open: bool = false,

    fn takesKeys(p: *const MenuPanel) bool {
        return p.menu.state.open and p.menu.depth == p.level;
    }

    /// Adds an item: true in the frame it is chosen, which closes the menu.
    pub fn item(p: *MenuPanel, label: []const u8, opts: ItemOptions) bool {
        const c = p.c;
        const i = p.next(!opts.disabled);
        const it = p.row(i, label, opts, false);
        if (opts.disabled) return false;
        const highlighted = p.menu.highlight[p.level] == i;
        const by_key = highlighted and p.takesKeys() and (base.takeKey(c, .enter) or base.takeSpace(c));
        if (!(it.clicked or by_key) or !p.menu.state.open) return false;
        p.menu.state.open = false;
        c.changed = true;
        return true;
    }

    /// A line between groups of items.
    pub fn separator(p: *MenuPanel) void {
        const c = p.c;
        _ = c.open(.{ .width = .fill, .padding = .xy(8, 4) }, null);
        widgets.divider(c);
        c.end();
    }

    /// An item opening a submenu as the pointer rests on it, or for Right
    /// or Enter: its items follow, then `end`, while it is open.
    pub fn submenu(p: *MenuPanel, label: []const u8) ?*MenuPanel {
        const c = p.c;
        const i = p.next(true);
        const it = p.row(i, label, .{}, true);
        const m = p.menu;
        if (p.level + 1 >= max_depth) return null;
        // Pressed (by assistive technology), it opens as for the keyboard.
        if (it.clicked and !(m.highlight[p.level] == i and m.depth > p.level)) {
            m.highlight[p.level] = i;
            m.depth = p.level;
            c.changed = true;
        }
        const highlighted = m.highlight[p.level] == i;
        if (highlighted and (it.clicked or p.takesKeys() and (base.takeKey(c, .right) or base.takeKey(c, .enter) or base.takeSpace(c)))) {
            m.depth = p.level + 1;
            m.highlight[p.level + 1] = -1;
            p.subHighlightFirst();
        }
        if (!(highlighted and m.depth > p.level)) return null;
        const rect = it.rect orelse {
            c.animationFrame();
            return null;
        };
        p.sub_open = true;
        const sub = newPanel(c, m, p.level + 1, .{ .x = rect.x - 4, .y = rect.y - 4, .w = rect.w + 8, .h = rect.h });
        return sub;
    }

    /// The submenu opened by the keyboard highlights its first item, once
    /// built: marked here, resolved as it ends.
    fn subHighlightFirst(p: *MenuPanel) void {
        p.menu.highlight[p.level + 1] = -2;
    }

    fn next(p: *MenuPanel, enabled: bool) i32 {
        const i = p.count;
        if (i < max_items) p.enabled[i] = enabled;
        p.count +|= 1;
        return i;
    }

    fn row(p: *MenuPanel, i: i32, label: []const u8, opts: ItemOptions, sub: bool) Interaction {
        const c = p.c;
        const th = c.theme;
        const m = p.menu;
        c.next_key_int = @intCast(i);
        const box = c.open(.{
            .direction = .row,
            .width = .fill,
            .padding = .xy(8, 4),
            .radius = 5,
            .gap = 8,
            .align_items = .center,
            .opacity = if (opts.disabled) 0.4 else 1,
            .control = true,
        }, null);
        defer c.end();
        const it = c.interact(box, .{});
        c.describe(it.id, .{
            .role = if (opts.checked != null) .menu_item_checkbox else .menu_item,
            .label = label,
            .checked = if (opts.checked) |on| (if (on) .on else .off) else null,
            .disabled = opts.disabled,
            .has_popup = sub,
            .expanded = if (sub) m.highlight[p.level] == i and m.depth > p.level else null,
        });
        const moved = c.input.mouse.x != m.mouse.x or c.input.mouse.y != m.mouse.y;
        if (it.hovered and moved and !opts.disabled and m.highlight[p.level] != i) {
            m.highlight[p.level] = i;
            // Onto an item: what it does not open closes.
            m.depth = if (sub) p.level + 1 else p.level;
            if (sub) m.highlight[p.level + 1] = -1;
            c.changed = true;
        }
        const on = m.highlight[p.level] == i and !opts.disabled;
        if (on) c.node(box).style.background = th.accent;
        const fg = if (on) th.accent_text else th.text;
        const muted = if (on) th.accent_text.alpha(0.8) else th.muted;
        if (opts.checked) |checked| {
            _ = c.open(.{ .width = .{ .px = 14 }, .align_items = .center }, null);
            if (checked) widgets.icon(c, "checkmark", .{ .size = 12, .weight = .semibold, .color = fg });
            c.end();
        }
        if (opts.icon.len > 0) widgets.icon(c, opts.icon, .{ .size = 14, .frame = 16, .color = fg });
        _ = c.open(.{ .grow = 1 }, null);
        widgets.text(c, label, .{ .size = 13, .color = fg });
        c.end();
        if (opts.shortcut.len > 0) widgets.text(c, opts.shortcut, .{ .size = 12, .color = muted });
        if (sub) widgets.icon(c, "chevron.right", .{ .size = 11, .color = muted });
        return it;
    }

    fn move(p: *MenuPanel, step: i32) void {
        const n: i32 = @min(p.count, max_items);
        if (n == 0) return;
        const h = &p.menu.highlight[p.level];
        var at = h.*;
        var tries: i32 = 0;
        while (tries < n) : (tries += 1) {
            at = if (at < 0) (if (step > 0) 0 else n - 1) else @mod(at + step, n);
            if (p.enabled[@intCast(at)]) {
                h.* = at;
                return;
            }
        }
    }

    fn edge(p: *MenuPanel, last: bool) void {
        p.menu.highlight[p.level] = -1;
        p.move(if (last) -1 else 1);
    }

    /// Closes the menu: the keyboard (for the innermost menu), then it is
    /// placed beside what opened it.
    pub fn end(p: *MenuPanel) void {
        const c = p.c;
        const m = p.menu;
        // A submenu the highlight left is closed.
        if (m.depth > p.level and !p.sub_open) m.depth = p.level;
        if (m.highlight[p.level] == -2) p.edge(false);
        if (p.takesKeys()) {
            if (base.takeKey(c, .down)) p.move(1) //
            else if (base.takeKey(c, .up)) p.move(-1) //
            else if (c.input.key == .home) {
                c.input.key = null;
                c.changed = true;
                p.edge(false);
            } else if (c.input.key == .end) {
                c.input.key = null;
                c.changed = true;
                p.edge(true);
            } else if (base.takeKey(c, .escape) or (p.level > 0 and base.takeKey(c, .left))) {
                if (p.level == 0) m.state.dismiss(c) else {
                    m.depth = p.level - 1;
                    c.changed = true;
                }
            }
            // The menu keeps the keyboard while it is open.
            else if (p.level == 0) _ = base.takeKey(c, .enter) or base.takeSpace(c) or base.takeKey(c, .tab);
        }
        std.debug.assert(c.stack.items[c.stack.items.len - 1] == p.index);
        if (p.level == 0) {
            _ = base.place(c, p.index, p.anchor, .below, .start, if (p.anchor.h > 0) 4 else 0);
        } else {
            _ = base.place(c, p.index, p.anchor, .right, .start, 0);
        }
        c.end();
        if (p.level == 0) m.mouse = c.input.mouse;
    }
};

fn newPanel(c: *Context, m: *Menu, level: u8, anchor: types.Rect) *MenuPanel {
    const th = c.theme;
    const index = base.overlay(c, .{
        .absolute = true,
        .padding = .all(4),
        .min_width = 180,
        .max_width = 360,
        .radius = 8,
        .background = th.surface,
        .border = th.border,
        .shadow = .{ .color = th.shadow.alpha(1.5), .blur = 20, .y = 6 },
    }, base.seedOf(m) +% 2 +% level);
    _ = c.interact(index, .{});
    c.describe(c.node(index).id, .{ .role = .menu });
    const p = c.alloc().create(MenuPanel) catch @panic("OOM");
    p.* = .{ .c = c, .menu = m, .level = level, .index = index, .anchor = anchor };
    return p;
}

/// Builds the open menu `m` (from `at`): null while it is closed. What a
/// context menu, a menu button and `buttonMenu` show.
pub fn menu(c: *Context, m: *Menu) ?*MenuPanel {
    if (!m.state.sync(c)) return null;
    // As the system's menus: a press outside (left or right) only closes it.
    const catcher = base.overlay(c, .{ .absolute = true, .width = .fill, .height = .fill }, base.seedOf(m) +% 1);
    const cid = c.node(catcher).id;
    _ = c.interact(catcher, .{});
    c.end();
    if ((c.input.pressed or base.rightPressed(c)) and c.hot == cid and !m.state.justOpened(c)) {
        m.state.dismiss(c);
        // The press is taken: the right button's too.
        if (comptime @hasField(ctx_mod.Input, "right_pressed")) c.input.right_pressed = false;
    }
    return newPanel(c, m, 0, m.at);
}

/// Gives the element `target` (an interaction of the box, built with its
/// children) a menu, which opens where it is right-clicked, or below it
/// for Shift+F10 while it has the focus. Call it after the elements inside
/// `target`, so that the innermost element with a menu takes the click.
pub fn contextMenu(c: *Context, m: *Menu, target: Interaction) ?*MenuPanel {
    if (base.rightPressed(c) and target.hovered and !m.state.open) {
        if (comptime @hasField(ctx_mod.Input, "right_pressed")) c.input.right_pressed = false;
        m.openAt(c.input.mouse);
        c.changed = true;
    } else if (target.focused and c.input.key == .f10 and c.input.shift and !m.state.open) {
        c.input.key = null;
        m.openBelow(target.rect orelse .{});
        m.highlight[0] = -2;
        c.changed = true;
    }
    return menu(c, m);
}

/// Gives a button a menu, which opens below it as the pointer goes down on
/// it (as the system's pop-up buttons do), and closes for a second press.
pub fn buttonMenu(c: *Context, m: *Menu, button: Interaction) ?*MenuPanel {
    if (button.hovered and c.input.pressed and !m.state.open) {
        m.openBelow(button.rect orelse .{});
        c.changed = true;
    } else if (button.clicked and !m.state.open) {
        // Pressed without the pointer: by assistive technology.
        m.openBelow(button.rect orelse .{});
        m.highlight[0] = -2;
        c.changed = true;
    } else if (button.focused and !m.state.open and (base.takeKey(c, .down) or base.takeKey(c, .enter) or base.takeSpace(c))) {
        m.openBelow(button.rect orelse .{});
        m.highlight[0] = -2;
        c.changed = true;
    }
    return menu(c, m);
}

pub const MenuButtonOptions = struct {
    size: f32 = 14,
    disabled: bool = false,
    width: types.Length = .auto,
};

/// A button showing `title` and an arrow, opening the menu `m` below it:
/// as the pointer goes down on it, or for Enter, Space or Down while it
/// has the focus (after a click).
pub fn menuButton(c: *Context, title: []const u8, m: *Menu, opts: MenuButtonOptions) ?*MenuPanel {
    const th = c.theme;
    const box = c.open(.{
        .direction = .row,
        .width = opts.width,
        .padding = .xy(opts.size * 0.8, opts.size * 0.5),
        .gap = opts.size * 0.4,
        .radius = 8,
        .align_items = .center,
        .border = th.border,
        .opacity = if (opts.disabled) 0.45 else 1,
        .control = true,
    }, null);
    const it = c.interact(box, .{ .focusable = !opts.disabled });
    c.describe(it.id, .{ .role = .menu_button, .label = title, .expanded = m.state.open, .disabled = opts.disabled });
    const hover = c.animate(it.id, 0, if (it.hovered and !opts.disabled) 1 else 0, 20);
    c.node(box).style.background = th.surface.mix(th.surface_hover, if (m.state.open) 1 else hover);
    c.node(box).style.shadow = .{ .color = th.shadow.alpha(0.5), .blur = 2, .y = 1 };
    _ = c.open(.{ .grow = 1 }, null);
    widgets.text(c, title, .{ .size = opts.size, .weight = .medium });
    c.end();
    widgets.icon(c, "chevron.down", .{ .size = opts.size * 0.75, .weight = .semibold, .color = th.muted });
    c.end();
    if (opts.disabled) return null;
    return buttonMenu(c, m, it);
}
