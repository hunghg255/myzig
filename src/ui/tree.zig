//! A tree of items, each built inside the item it belongs to, its children
//! showing while it is open. It builds every item it shows: for trees of
//! thousands of items, use an outline (`outline.zig`), which builds only
//! the rows in view.
//!
//!     var tr = ui.tree(c, &s.chosen, .{});
//!     if (tr.item("src", "src", &s.src_open)) {
//!         defer tr.endChildren();
//!         _ = tr.item("src/main.zig", "main.zig", null);
//!     }
//!     _ = tr.item("build.zig", "build.zig", null);
//!     if (tr.end().submitted) open(s.chosen);
//!
//! Items are named by keys the app keeps (paths); `chosen.*` is the key of
//! the item chosen. A click on an item's arrow opens or closes it; a click
//! elsewhere on it chooses it. While the tree has the keyboard focus, Up
//! and Down choose the items around, Right opens the item or goes to its
//! first child, Left closes it or goes to its parent, and Enter (or a
//! double click) submits the choice.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const structure = @import("structure.zig");
const widgets = @import("widgets.zig");
const Context = ctx_mod.Context;

pub const Options = struct {
    width: types.Length = .fill,
    height: types.Length = .auto,
    row_height: f32 = 26,
    /// What each level adds before an item's arrow.
    indent: f32 = 16,
};

pub const Result = struct {
    /// A click or a key chose another item, or opened or closed one.
    changed: bool = false,
    /// Enter or a double click on the item chosen.
    submitted: bool = false,
    focused: bool = false,
};

const Shown = struct {
    key: []const u8,
    depth: u32,
    open: ?*bool,
    parent: ?usize,
};

pub const Tree = struct {
    c: *Context,
    id: u64,
    chosen: *[]const u8,
    opts: Options,
    focused: bool,
    result: Result = .{},
    depth: u32 = 0,
    /// The items shown, in order, for the keys.
    shown: std.ArrayList(Shown) = .empty,
    /// The items whose children are being built.
    parents: std.ArrayList(usize) = .empty,

    /// An item named `key` showing `label`; a null `open` makes a leaf.
    /// True while its children show: build them, then `endChildren`.
    pub fn item(tr: *Tree, key: []const u8, label: []const u8, open: ?*bool) bool {
        const c = tr.c;
        const chosen = std.mem.eql(u8, tr.chosen.*, key);
        const indent = tr.opts.indent * @as(f32, @floatFromInt(tr.depth));
        const row = c.open(.{
            .direction = .row,
            .width = .fill,
            .height = .{ .px = tr.opts.row_height },
            .align_items = .center,
            .gap = 4,
            .padding = .{ .left = 4 + indent, .right = 8 },
            .radius = 5,
            .control = true,
        }, key);
        const it = c.interact(row, .{});
        if (it.pressed and c.input.pressed) tr.takeFocus();
        // Assistive technology opens and closes it without choosing it.
        if (open) |o| if (c.expandRequest(it.id)) |want| {
            if (o.* != want) tr.result.changed = true;
            o.* = want;
        };
        c.describe(it.id, .{ .role = .tree_item, .label = label, .selected = chosen, .level = @intCast(tr.depth + 1), .expanded = if (open) |o| o.* else null });
        if (chosen) c.describe(tr.id, .{ .active_descendant = it.id });
        tr.shown.append(c.alloc(), .{
            .key = key,
            .depth = tr.depth,
            .open = open,
            .parent = if (tr.parents.items.len > 0) tr.parents.items[tr.parents.items.len - 1] else null,
        }) catch {};
        // The arrow opens and closes it; a leaf keeps its room.
        if (open) |o| {
            const arrow = c.open(.{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .align_items = .center, .justify = .center }, "arrow");
            const at = c.interact(arrow, .{});
            if (at.pressed and c.input.pressed) tr.takeFocus();
            if (at.clicked) {
                o.* = !o.*;
                tr.result.changed = true;
                c.changed = true;
            }
            widgets.icon(c, if (o.*) "chevron.down" else "chevron.right", .{ .size = 11, .weight = .semibold, .color = structure.rowText(c, chosen, tr.focused).alpha(0.7) });
            c.end();
        } else _ = c.leaf(.{ .width = .{ .px = 16 } }, .none, null);
        if (it.clicked) {
            if (!chosen) {
                tr.chosen.* = key;
                tr.result.changed = true;
            }
            if (it.double_clicked) tr.result.submitted = true;
            c.changed = true;
        }
        const hover = c.animate(it.id, 0, if (it.hovered) 1 else 0, 20);
        c.node(row).style.background = structure.rowBackground(c, chosen, tr.focused, hover);
        widgets.text(c, label, .{ .size = 13, .color = structure.rowText(c, chosen, tr.focused) });
        c.end();
        const has_children = if (open) |o| o.* else false;
        if (has_children) {
            tr.parents.append(c.alloc(), tr.shown.items.len - 1) catch {};
            tr.depth += 1;
        }
        return has_children;
    }

    /// Closes the children of the item whose `item` returned true.
    pub fn endChildren(tr: *Tree) void {
        std.debug.assert(tr.depth > 0);
        tr.depth -= 1;
        _ = tr.parents.pop();
    }

    fn takeFocus(tr: *Tree) void {
        if (tr.c.focus == tr.id) return;
        tr.c.focus = tr.id;
        tr.focused = true;
        tr.c.changed = true;
    }

    /// Closes the tree, after this frame's keys moved through its items.
    pub fn end(tr: *Tree) Result {
        const c = tr.c;
        std.debug.assert(tr.depth == 0);
        c.end();
        tr.result.focused = tr.focused;
        if (!tr.focused or tr.shown.items.len == 0) return tr.result;
        const k = c.input.key orelse return tr.result;
        const rows = tr.shown.items;
        var at: ?usize = null;
        for (rows, 0..) |r, i| if (std.mem.eql(u8, r.key, tr.chosen.*)) {
            at = i;
            break;
        };
        var to: ?usize = null;
        switch (k) {
            .enter => if (at != null) {
                tr.result.submitted = true;
            },
            .right => if (at) |i| {
                const r = rows[i];
                if (r.open) |o| {
                    if (!o.*) {
                        o.* = true;
                        tr.result.changed = true;
                    } else if (i + 1 < rows.len and rows[i + 1].depth > r.depth) to = i + 1;
                }
            } else {
                to = 0;
            },
            .left => if (at) |i| {
                const r = rows[i];
                if (r.open != null and r.open.?.*) {
                    r.open.?.* = false;
                    tr.result.changed = true;
                } else if (r.parent) |p| to = p;
            } else {
                to = 0;
            },
            else => to = structure.step(k, at, rows.len, .up, .down, 10),
        }
        if (to == null and !tr.result.changed and !tr.result.submitted) return tr.result;
        _ = structure.takeKey(c);
        c.changed = true;
        if (to) |n| if (at != n) {
            tr.chosen.* = rows[n].key;
            tr.result.changed = true;
        };
        return tr.result;
    }
};

pub fn tree(c: *Context, chosen: *[]const u8, opts: Options) Tree {
    const box = c.open(.{ .direction = .column, .width = opts.width, .height = opts.height, .gap = 1 }, null);
    const it = c.interact(box, .{ .focusable = true });
    c.describe(it.id, .{ .role = .tree });
    return .{ .c = c, .id = it.id, .chosen = chosen, .opts = opts, .focused = c.focus == it.id };
}
