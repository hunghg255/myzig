//! An outline: a tree of items as AppKit's outline view and Finder's list
//! view, below each open item its children, indented, with an arrow that
//! opens and closes it. It builds only the rows in view, as `ui.list`
//! does, so trees of any size cost what a screenful does.
//!
//!     // In the app's state: `files: ui.OutlineState([]const u8) = .{}`.
//!     var rows = ui.outline([]const u8, c, &s.files, roots, s, .{});
//!     while (rows.next()) |r| ui.text(c, std.fs.path.basename(r.item), .{});
//!     if (rows.end().submitted) open(s.files.selected.?);
//!
//! `provider.children(item)` returns an item's children, empty for one
//! without any. While the outline has the focus, Up, Down, Home, End and
//! Page Up and Down choose rows, Right opens the item chosen or goes to its
//! first child, Left closes it or goes to its parent, and Enter (or a
//! double click) submits it. Closing an item whose child was chosen
//! chooses the item.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const structure = @import("structure.zig");
const widgets = @import("widgets.zig");
const list_mod = @import("list.zig");
const Context = ctx_mod.Context;

/// How items of type `T` are hashed and compared: strings by their bytes.
pub fn HashContext(comptime T: type) type {
    return if (T == []const u8) std.hash_map.StringContext else std.hash_map.AutoContext(T);
}

/// What an outline keeps across frames: the items open and the one chosen.
pub fn OutlineState(comptime T: type) type {
    return struct {
        const Self = @This();
        open: std.HashMapUnmanaged(T, void, HashContext(T), 80) = .empty,
        selected: ?T = null,

        pub fn deinit(s: *Self, gpa: std.mem.Allocator) void {
            s.open.deinit(gpa);
        }

        pub fn isOpen(s: *const Self, item: T) bool {
            return s.open.contains(item);
        }

        pub fn setOpen(s: *Self, gpa: std.mem.Allocator, item: T, open: bool) void {
            if (open) s.open.put(gpa, item, {}) catch {} else _ = s.open.remove(item);
        }

        pub fn isSelected(s: *const Self, item: T) bool {
            const sel = s.selected orelse return false;
            return (HashContext(T){}).eql(sel, item);
        }
    };
}

pub const Options = struct {
    row_height: f32 = 26,
    /// What each level adds before a row's arrow.
    indent: f32 = 16,
    width: types.Length = .fill,
    height: types.Length = .fill,
    padding: types.Edges = .all(4),
};

pub const Result = struct {
    /// A click or a key chose another row, or opened or closed one.
    changed: bool = false,
    /// Enter or a double click on the row chosen.
    submitted: bool = false,
    focused: bool = false,
};

pub fn Row(comptime T: type) type {
    return struct {
        item: T,
        depth: u32,
        has_children: bool,
        parent: ?usize,
    };
}

/// The rows of an outline being built: `next` opens each row in view (its
/// indent and arrow added) for the view to add its content; `end` closes.
pub fn Rows(comptime T: type) type {
    return struct {
        const Self = @This();
        c: *Context,
        state: *OutlineState(T),
        rows: []const Row(T),
        list: list_mod.Rows,
        id: u64,
        opts: Options,
        focused: bool,
        result: Result,
        in_row: bool = false,

        /// The next row in view, opened, or null when the view is full.
        pub fn next(r: *Self) ?Row(T) {
            const c = r.c;
            if (r.in_row) {
                c.end();
                r.in_row = false;
            }
            const i = r.list.next() orelse return null;
            const row = r.rows[i];
            // Rows keep their identity (hover) as items open and close above them.
            c.next_key_int = (HashContext(T){}).hash(row.item);
            const chosen = r.state.isSelected(row.item);
            const box = c.open(.{
                .direction = .row,
                .width = .fill,
                .height = .{ .px = r.opts.row_height },
                .align_items = .center,
                .gap = 4,
                .padding = .{ .left = 4 + r.opts.indent * @as(f32, @floatFromInt(row.depth)), .right = 8 },
                .radius = 5,
                .control = true,
            }, null);
            r.in_row = true;
            const it = c.interact(box, .{});
            if (it.pressed and c.input.pressed) r.takeFocus();
            if (row.has_children) {
                const open = r.state.isOpen(row.item);
                const arrow = c.open(.{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .align_items = .center, .justify = .center }, "arrow");
                const at = c.interact(arrow, .{});
                if (at.pressed and c.input.pressed) r.takeFocus();
                if (at.clicked) {
                    r.setOpen(i, !open);
                    c.changed = true;
                }
                widgets.icon(c, if (open) "chevron.down" else "chevron.right", .{ .size = 11, .weight = .semibold, .color = structure.rowText(c, chosen, r.focused).alpha(0.7) });
                c.end();
            } else _ = c.leaf(.{ .width = .{ .px = 16 } }, .none, null);
            if (it.clicked) {
                if (!chosen) {
                    r.state.selected = row.item;
                    r.result.changed = true;
                }
                if (it.double_clicked) r.result.submitted = true;
                c.changed = true;
            }
            const hover = c.animate(it.id, 0, if (it.hovered) 1 else 0, 20);
            c.node(box).style.background = structure.rowBackground(c, chosen, r.focused, hover);
            return row;
        }

        fn takeFocus(r: *Self) void {
            if (r.c.focus == r.id) return;
            r.c.focus = r.id;
            r.focused = true;
            r.c.changed = true;
        }

        /// Opens or closes row `i`'s item; closing it chooses it when it
        /// held the row chosen.
        fn setOpen(r: *Self, i: usize, open: bool) void {
            setOpenRow(T, r.c, r.state, r.rows, i, open);
            r.result.changed = true;
        }

        pub fn end(r: *Self) Result {
            if (r.in_row) r.c.end();
            r.list.end();
            r.result.focused = r.focused;
            return r.result;
        }
    };
}

fn setOpenRow(comptime T: type, c: *Context, state: *OutlineState(T), rows: []const Row(T), i: usize, open: bool) void {
    const item = rows[i].item;
    state.setOpen(c.gpa, item, open);
    if (open) return;
    // The rows after it that are deeper are inside it.
    var j = i + 1;
    while (j < rows.len and rows[j].depth > rows[i].depth) : (j += 1) {
        if (state.isSelected(rows[j].item)) {
            state.selected = item;
            return;
        }
    }
}

/// The rows the open items show, in order.
fn flatten(comptime T: type, c: *Context, state: *const OutlineState(T), out: *std.ArrayList(Row(T)), items: []const T, provider: anytype, depth: u32, parent: ?usize) void {
    for (items) |item| {
        const kids: []const T = provider.children(item);
        out.append(c.alloc(), .{ .item = item, .depth = depth, .has_children = kids.len > 0, .parent = parent }) catch return;
        if (kids.len > 0 and state.isOpen(item)) flatten(T, c, state, out, kids, provider, depth + 1, out.items.len - 1);
    }
}

fn indexOf(comptime T: type, state: *const OutlineState(T), rows: []const Row(T)) ?usize {
    if (state.selected == null) return null;
    for (rows, 0..) |row, i| if (state.isSelected(row.item)) return i;
    return null;
}

/// Opens an outline of `roots` and their children: `next` each row in view,
/// add its content, then `end`.
pub fn outline(comptime T: type, c: *Context, state: *OutlineState(T), roots: []const T, provider: anytype, opts: Options) Rows(T) {
    var rows: std.ArrayList(Row(T)) = .empty;
    flatten(T, c, state, &rows, roots, provider, 0, null);
    const id = c.peekId(null);
    const focused = c.focus == id;
    var result: Result = .{};
    var scroll_to: ?f32 = null;
    if (focused) if (c.input.key) |k| {
        const at = indexOf(T, state, rows.items);
        const view_h = if (c.rects.get(id)) |r| r.h else c.size.h;
        const page: usize = @intFromFloat(@max(1, @floor(view_h / opts.row_height) - 1));
        var to: ?usize = null;
        var reflat = false;
        var took = true;
        switch (k) {
            .enter => if (at != null) {
                result.submitted = true;
            } else {
                took = false;
            },
            .right => if (at) |i| {
                const row = rows.items[i];
                if (row.has_children and !state.isOpen(row.item)) {
                    setOpenRow(T, c, state, rows.items, i, true);
                    reflat = true;
                } else if (row.has_children) to = i + 1;
            } else {
                to = 0;
            },
            .left => if (at) |i| {
                const row = rows.items[i];
                if (row.has_children and state.isOpen(row.item)) {
                    setOpenRow(T, c, state, rows.items, i, false);
                    reflat = true;
                } else if (row.parent) |p| to = p;
            } else {
                to = 0;
            },
            else => {
                to = structure.step(k, at, rows.items.len, .up, .down, page);
                took = to != null;
            },
        }
        if (took) {
            _ = structure.takeKey(c);
            c.changed = true;
        }
        if (to) |n| if (n < rows.items.len and at != n) {
            state.selected = rows.items[n].item;
            result.changed = true;
        };
        if (reflat) {
            result.changed = true;
            rows.clearRetainingCapacity();
            flatten(T, c, state, &rows, roots, provider, 0, null);
        }
        // Keep the row chosen in view.
        if (to != null) if (indexOf(T, state, rows.items)) |n| {
            const top = opts.row_height * @as(f32, @floatFromInt(n));
            scroll_to = structure.reveal(top, opts.row_height, c.scroll.get(id) orelse 0, view_h - opts.padding.vertical());
        };
    };
    const l = list_mod.list(c, .{
        .count = rows.items.len,
        .row_height = opts.row_height,
        .width = opts.width,
        .height = opts.height,
        .padding = opts.padding,
        .scroll_to = scroll_to,
    });
    const box = c.stack.items[c.stack.items.len - 1];
    _ = c.interact(box, .{ .focusable = true });
    return .{ .c = c, .state = state, .rows = rows.items, .list = l, .id = id, .opts = opts, .focused = focused, .result = result };
}
