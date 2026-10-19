//! A grid view: items in a wrapping grid, as Photos' library and Finder's
//! icon view, as many columns as fit items at least `min_item_width` wide,
//! sharing the width left, in rows `row_height` tall. Only the rows in
//! view are built (a virtualized `ui.list`), so grids of a million items
//! cost what a screenful does.
//!
//!     var g = ui.gridView(c, &s.photos, .{ .count = photos.len, .min_item_width = 140, .row_height = 120 });
//!     while (g.next()) |i| ui.text(c, photos[i].name, .{});
//!     if (g.end().submitted) open(s.photos.selected.?);
//!
//! A click chooses an item; while the grid has the focus, the arrows move
//! the choice in both directions, Home and End to the ends, Page Up and
//! Down a screenful, and Enter (or a double click) submits it.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const structure = @import("structure.zig");
const list_mod = @import("list.zig");
const Context = ctx_mod.Context;

pub const GridState = struct {
    selected: ?usize = null,
};

pub const Options = struct {
    count: usize,
    min_item_width: f32 = 120,
    row_height: f32 = 120,
    gap: f32 = 8,
    padding: types.Edges = .all(8),
    width: types.Length = .fill,
    height: types.Length = .fill,
};

pub const Result = struct {
    changed: bool = false,
    submitted: bool = false,
    focused: bool = false,
};

pub const GridView = struct {
    c: *Context,
    state: *GridState,
    opts: Options,
    list: list_mod.Rows,
    id: u64,
    columns: usize,
    focused: bool,
    result: Result,
    /// The next item of the row being built, and the row's end.
    item: usize = 0,
    row_end: usize = 0,
    in_row: bool = false,
    in_item: bool = false,

    /// The next item in view, its cell opened for its content, or null when
    /// the view is full.
    pub fn next(g: *GridView) ?usize {
        const c = g.c;
        if (g.in_item) {
            c.end();
            g.in_item = false;
        }
        while (!g.in_row or g.item >= g.row_end) {
            if (g.in_row) {
                // The rest of the last row keeps its columns' room (as
                // padded as the items, which grow from their padding).
                for (g.row_end - g.rowStart()..g.columns) |_| _ = c.leaf(.{ .width = .fill, .padding = .all(6) }, .none, null);
                c.end();
                g.in_row = false;
            }
            const r = g.list.next() orelse return null;
            _ = c.open(.{ .direction = .row, .width = .fill, .height = .{ .px = g.opts.row_height }, .gap = g.opts.gap, .align_items = .stretch }, null);
            g.in_row = true;
            g.item = r * g.columns;
            g.row_end = @min(g.opts.count, g.item + g.columns);
        }
        const i = g.item;
        g.item += 1;
        const chosen = g.state.selected == i;
        c.next_key_int = i;
        const box = c.open(.{ .direction = .column, .width = .fill, .align_items = .center, .justify = .center, .gap = 4, .padding = .all(6), .radius = 8, .clip = true, .control = true }, null);
        g.in_item = true;
        const it = c.interact(box, .{});
        if (it.pressed and c.input.pressed and c.focus != g.id) {
            c.focus = g.id;
            g.focused = true;
            c.changed = true;
        }
        if (it.clicked) {
            if (!chosen) {
                g.state.selected = i;
                g.result.changed = true;
            }
            if (it.double_clicked) g.result.submitted = true;
            c.changed = true;
        }
        const hover = c.animate(it.id, 0, if (it.hovered) 1 else 0, 20);
        const th = c.theme;
        const n = c.node(box);
        if (g.state.selected == i) {
            n.style.background = if (g.focused) th.accent.alpha(0.2) else th.text.alpha(0.1);
            n.style.border = if (g.focused) th.accent else null;
        } else n.style.background = th.text.alpha(0.05 * hover);
        return i;
    }

    fn rowStart(g: *const GridView) usize {
        return (g.row_end -| 1) / g.columns * g.columns;
    }

    pub fn end(g: *GridView) Result {
        const c = g.c;
        if (g.in_item) c.end();
        if (g.in_row) {
            for (g.row_end - g.rowStart()..g.columns) |_| _ = c.leaf(.{ .width = .fill, .padding = .all(6) }, .none, null);
            c.end();
        }
        g.list.end();
        g.result.focused = g.focused;
        return g.result;
    }
};

/// How many columns of items at least `min` wide, `gap` apart, fit `width`.
pub fn columnsFor(width: f32, min: f32, gap: f32) usize {
    if (width <= 0) return 1;
    return @max(1, @as(usize, @intFromFloat(@floor((width + gap) / (@max(1, min) + gap)))));
}

/// Opens a grid view: `next` each item in view, add its content, then `end`.
pub fn gridView(c: *Context, state: *GridState, opts: Options) GridView {
    const id = c.peekId(null);
    const last = c.rects.get(id);
    const inner_w = (if (last) |r| r.w else c.size.w) - opts.padding.horizontal();
    const columns = columnsFor(inner_w, opts.min_item_width, opts.gap);
    const rows = (opts.count + columns - 1) / columns;
    if (state.selected) |s| if (s >= opts.count) {
        state.selected = if (opts.count > 0) opts.count - 1 else null;
    };
    const focused = c.focus == id;
    var result: Result = .{};
    var scroll_to: ?f32 = null;
    if (focused and opts.count > 0) if (c.input.key) |k| {
        const view_h = (if (last) |r| r.h else c.size.h) - opts.padding.vertical();
        const pitch = opts.row_height + opts.gap;
        const page_rows: usize = @intFromFloat(@max(1, @floor(view_h / pitch)));
        const last_i = opts.count - 1;
        const cur = state.selected;
        const to: ?usize = if (cur) |s| switch (k) {
            .left => s -| 1,
            .right => @min(last_i, s + 1),
            .up => if (s >= columns) s - columns else s,
            .down => if (s + columns <= last_i) s + columns else s,
            .home => 0,
            .end => last_i,
            .page_up => s -| columns * page_rows,
            .page_down => @min(last_i, s + columns * page_rows),
            else => null,
        } else switch (k) {
            .left, .right, .up, .down, .home, .page_up, .page_down => 0,
            .end => last_i,
            else => null,
        };
        if (k == .enter and cur != null) {
            _ = structure.takeKey(c);
            result.submitted = true;
            c.changed = true;
        } else if (to) |n| {
            _ = structure.takeKey(c);
            c.changed = true;
            if (cur != n) {
                state.selected = n;
                result.changed = true;
            }
            const top = pitch * @as(f32, @floatFromInt(n / columns));
            scroll_to = structure.reveal(top, opts.row_height, c.scroll.get(id) orelse 0, view_h);
        }
    };
    const l = list_mod.list(c, .{
        .count = rows,
        .row_height = opts.row_height,
        .gap = opts.gap,
        .padding = opts.padding,
        .width = opts.width,
        .height = opts.height,
        .scroll_to = scroll_to,
    });
    _ = c.interact(c.stack.items[c.stack.items.len - 1], .{ .focusable = true });
    return .{ .c = c, .state = state, .opts = opts, .list = l, .id = id, .columns = columns, .focused = focused, .result = result };
}
