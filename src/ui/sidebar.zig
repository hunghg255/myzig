//! A sidebar: a source list, as Finder's and Mail's, of items with icons in
//! sections whose titles hide and show them, choosing one item's id. It
//! scrolls when they do not fit.
//!
//!     var sb = ui.sidebar(c, &s.mailbox, .{});
//!     if (sb.section("Mailboxes", &s.mailboxes_shown)) {
//!         sb.item("inbox", "Inbox", .{ .icon = "doc.text", .badge = "3" });
//!         sb.item("sent", "Sent", .{});
//!     }
//!     if (sb.section("Tags", null)) sb.item("work", "Work", .{});
//!     if (sb.end().changed) show(s);
//!
//! A click chooses an item; while the sidebar has the focus, Up, Down,
//! Home, End and the first letters of an item choose among them. The item
//! chosen shows in the accent color while the sidebar has the focus, in
//! gray otherwise.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const structure = @import("structure.zig");
const widgets = @import("widgets.zig");
const Context = ctx_mod.Context;

pub const Options = struct {
    width: types.Length = .{ .px = 220 },
    height: types.Length = .fill,
    background: ?types.Color = null,
};

pub const ItemOptions = struct {
    /// An SF Symbol before the label.
    icon: []const u8 = "",
    /// A count or a word at the end of the row.
    badge: ?[]const u8 = null,
};

pub const Result = struct {
    /// A click or a key chose another item in this frame.
    changed: bool = false,
    focused: bool = false,
};

pub const Sidebar = struct {
    c: *Context,
    id: u64,
    selected: *[]const u8,
    focused: bool,
    changed: bool = false,
    /// The items built, in order, for the keys.
    ids: std.ArrayList([]const u8) = .empty,
    labels: std.ArrayList([]const u8) = .empty,

    /// A section's title, a click on which hides and shows its items: true
    /// while they show (always with a null `open`).
    pub fn section(sb: *Sidebar, title: []const u8, open: ?*bool) bool {
        const c = sb.c;
        const th = c.theme;
        const head = c.open(.{ .direction = .row, .width = .fill, .align_items = .center, .padding = .{ .left = 8, .right = 6, .top = 10, .bottom = 4 }, .control = true }, title);
        defer c.end();
        const it = c.interact(head, .{});
        c.describe(it.id, .{ .role = if (open != null) .disclosure else .heading, .label = title, .expanded = if (open) |o| o.* else null, .level = if (open == null) 2 else 0 });
        if (it.pressed and c.input.pressed) sb.takeFocus();
        if (it.clicked) if (open) |o| {
            o.* = !o.*;
            c.changed = true;
        };
        widgets.text(c, title, .{ .size = 11, .weight = .semibold, .color = th.muted });
        widgets.spacer(c);
        if (open) |o| {
            // The arrow shows as the pointer rests on the title.
            const hover = c.animate(it.id, 0, if (it.hovered) 1 else 0, 20);
            if (hover > 0.01) widgets.icon(c, if (o.*) "chevron.down" else "chevron.right", .{ .size = 11, .frame = 14, .color = th.muted.alpha(hover) });
            return o.*;
        }
        return true;
    }

    /// An item choosing `id` (kept by the app while it shows).
    pub fn item(sb: *Sidebar, id: []const u8, label: []const u8, opts: ItemOptions) void {
        const c = sb.c;
        const chosen = std.mem.eql(u8, sb.selected.*, id);
        const row = c.open(.{ .direction = .row, .width = .fill, .height = .{ .px = 28 }, .align_items = .center, .gap = 7, .padding = .xy(8, 0), .radius = 6, .control = true }, id);
        defer c.end();
        const it = c.interact(row, .{});
        c.describe(it.id, .{ .role = .list_item, .label = label, .selected = chosen });
        if (chosen) c.describe(sb.id, .{ .active_descendant = it.id });
        if (it.pressed and c.input.pressed) sb.takeFocus();
        if (it.clicked and !chosen) {
            sb.selected.* = id;
            sb.changed = true;
            c.changed = true;
        }
        sb.ids.append(c.alloc(), id) catch {};
        sb.labels.append(c.alloc(), label) catch {};
        const hover = c.animate(it.id, 0, if (it.hovered) 1 else 0, 20);
        c.node(row).style.background = structure.rowBackground(c, chosen, sb.focused, hover);
        const fg = structure.rowText(c, chosen, sb.focused);
        if (opts.icon.len > 0) widgets.icon(c, opts.icon, .{ .size = 14, .frame = 16, .color = if (chosen and sb.focused) fg else c.theme.accent });
        widgets.text(c, label, .{ .size = 13, .color = fg });
        if (opts.badge) |b| {
            widgets.spacer(c);
            widgets.text(c, b, .{ .size = 11, .weight = .medium, .color = if (chosen and sb.focused) fg else c.theme.muted });
        }
    }

    fn takeFocus(sb: *Sidebar) void {
        if (sb.c.focus == sb.id) return;
        sb.c.focus = sb.id;
        sb.focused = true;
        sb.c.changed = true;
    }

    /// Closes the sidebar, after the keys of this frame chose among its items.
    pub fn end(sb: *Sidebar) Result {
        const c = sb.c;
        c.end();
        if (sb.focused and sb.ids.items.len > 0) {
            const ids = sb.ids.items;
            var at: ?usize = null;
            for (ids, 0..) |v, i| if (std.mem.eql(u8, v, sb.selected.*)) {
                at = i;
                break;
            };
            var to: ?usize = null;
            if (c.input.key) |k| if (structure.step(k, at, ids.len, .up, .down, 10)) |n| {
                _ = structure.takeKey(c);
                to = n;
            };
            if (c.input.chars.len > 0) if (structure.matchPrefix(sb.labels.items, at, c.input.chars)) |n| {
                c.input.chars = "";
                to = n;
            };
            if (to) |n| if (at != n) {
                sb.selected.* = ids[n];
                sb.changed = true;
                c.changed = true;
            };
        }
        return .{ .changed = sb.changed, .focused = sb.focused };
    }
};

/// Opens a sidebar choosing an item's id into `selected`: add `section`s and
/// `item`s, then `end`.
pub fn sidebar(c: *Context, selected: *[]const u8, opts: Options) Sidebar {
    const box = c.open(.{
        .direction = .column,
        .width = opts.width,
        .height = opts.height,
        .padding = .all(8),
        .gap = 1,
        .scroll = true,
        .background = opts.background,
    }, null);
    const it = c.interact(box, .{ .focusable = true });
    c.describe(it.id, .{ .role = .list });
    return .{ .c = c, .id = it.id, .selected = selected, .focused = c.focus == it.id };
}
