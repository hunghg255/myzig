//! A table: rows in columns under a header, built only as they show (a
//! virtualized `ui.list`), so tables of a million rows cost what a
//! screenful does.
//!
//!     const cols: []const ui.TableColumn = &.{
//!         .{ .title = "Name", .sortable = true },
//!         .{ .title = "Size", .width = 90, .alignment = .end, .sortable = true },
//!     };
//!     var t = ui.table(c, &s.files, cols, files.len, .{});
//!     while (t.next()) |row| {
//!         while (t.cell()) |col| switch (col) {
//!             0 => ui.text(c, files[row].name, .{}),
//!             else => ui.text(c, files[row].size, .{}),
//!         };
//!     }
//!     const r = t.end();
//!     if (r.sorted) sortFiles(s); // by s.files.sort
//!
//! A column's `width` is points, or 0 to share the room the others leave.
//! A click on a sortable column's header sorts by it, ascending, and a
//! second click reverses the order: the header shows an arrow, and the app
//! sorts its rows as `state.sort` says. A click chooses a row; while the
//! table has the focus the arrows, Home, End and Page Up and Down do, and
//! Enter (or a double click) submits it. Rows are `row_height` tall.
//! With `drag_select`, a drag over the rows and Shift choose a block of
//! them; with `cells`, a block of cells, as a spreadsheet does
//! (`table_cells.zig`). With `state.selection`, the rows chosen are a set
//! (`ui.Selection`, by the rows' keys): Cmd-clicks (Ctrl-clicks off the
//! Mac) add rows and take them out, and a right-click on a row (a cell)
//! outside the choice chooses it before its menu opens. A `row_header`
//! column chooses whole rows; `cell_menu` gives the cells a context menu.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const structure = @import("structure.zig");
const widgets = @import("widgets.zig");
const list_mod = @import("list.zig");
const cells_mod = @import("table_cells.zig");
const set = @import("selection_set.zig");
const menu_mod = @import("menu.zig");
const Choice = set.Choice;
const Context = ctx_mod.Context;

const column_mod = @import("table_columns.zig");
pub const Alignment = column_mod.Alignment;
pub const Column = column_mod.Column;

pub const Sort = struct {
    column: usize,
    descending: bool = false,
};

/// What a table keeps across frames: the rows (and cells) chosen and the
/// order.
pub const TableState = struct {
    /// The cursor's row: what keys move, and Enter submits.
    selected: ?usize = null,
    sort: ?Sort = null,
    /// With `Options.drag_select` or `cells`: the row Shift extends from.
    /// The rows chosen are those from it to `selected`.
    anchor: ?usize = null,
    /// With `Options.cells`: the columns of the block chosen, from the
    /// one Shift extends from to the cursor's, in the order shown.
    cols: ?[2]usize = null,
    /// A press dragging over the rows, choosing them.
    drag: ?cells_mod.Drag = null,
    /// The rows chosen as a set, by their keys (`key`, else their rows):
    /// Cmd-clicks add rows and take them out. Without, the rows from
    /// `anchor` to `selected`.
    selection: ?*set.Selection = null,
    key: ?set.Key = null,
    /// A right-click leaves the choice as it is.
    menu_keeps_selection: bool = false,
    /// The cells' context menu (`Options.cell_menu`), and its cell.
    cell_menu: menu_mod.Menu = .{},
    menu_cell: [2]usize = .{ 0, 0 },
    seen_row: ?usize = null,
    seen_key: ?u64 = null,
    anchor_key: ?u64 = null,

    /// The rows chosen, first and last (of a set: the cursor's row).
    pub fn rows(s: *const TableState) ?[2]usize {
        const sel = s.selected orelse return null;
        if (s.selection != null) return .{ sel, sel };
        return cells_mod.span(s.anchor orelse sel, sel);
    }

    pub fn rowChosen(s: *const TableState, row: usize) bool {
        if (s.selection != null) return Choice.chosen(s, row);
        const r = s.rows() orelse return false;
        return row >= r[0] and row <= r[1];
    }

    /// Whether the cell of `row` and column `col` is in the block chosen.
    pub fn cellChosen(s: *const TableState, row: usize, col: usize) bool {
        const cs = s.cols orelse return false;
        const r = cells_mod.span(cs[0], cs[1]);
        return s.rowChosen(row) and col >= r[0] and col <= r[1];
    }
};

pub const Options = struct {
    row_height: f32 = 28,
    header_height: f32 = 28,
    width: types.Length = .fill,
    height: types.Length = .fill,
    /// Every other row tinted.
    striped: bool = true,
    /// A drag over the rows chooses them, Shift-clicks extend the choice
    /// (`TableState.anchor`), as Finder's list does.
    drag_select: bool = false,
    /// Chooses blocks of cells as a spreadsheet does: the rows chosen times
    /// a run of columns (`TableState.cols`), by clicks, Shift, drags and
    /// Left and Right; their cells show in the accent color.
    cells: bool = false,
    /// A context menu over each cell, padding included (a menu built
    /// without items does not open; one of what a cell holds takes the
    /// right-click over it instead).
    cell_menu: ?CellMenu = null,
    /// App-owned widths parallel to columns. 0 shares room. Supplying
    /// this slice enables resize grips (pointer, arrows, Home/End).
    column_widths: ?[]f32 = null,
};

/// Builds the menu of the cell of `row` and `col` into `m`.
pub const CellMenu = struct {
    ctx: *anyopaque,
    build: *const fn (ctx: *anyopaque, m: *menu_mod.MenuPanel, row: usize, col: usize) void,
};

pub const Result = struct {
    /// A click or a key chose another row.
    changed: bool = false,
    /// A click on a header changed `state.sort`.
    sorted: bool = false,
    resized: bool = false,
    /// Enter or a double click on the row chosen.
    submitted: bool = false,
    focused: bool = false,
    /// A drag choosing rows goes on (the pointer holds it): work that
    /// follows the choice, as a sum of the cells chosen, can wait for it.
    drag_selecting: bool = false,
    /// The row (and column) right-clicked in this frame, which its menu
    /// acts on.
    menu_row: ?usize = null,
    menu_col: ?usize = null,
};

pub const Table = struct {
    c: *Context,
    state: *TableState,
    columns: []const Column,
    opts: Options,
    list: list_mod.Rows,
    id: u64,
    focused: bool,
    result: Result,
    row: ?usize = null,
    next_col: usize = 0,
    in_cell: bool = false,
    /// The column of the cell being built, and its box.
    col: usize = 0,
    cell_box: u32 = 0,

    /// The next row in view, opened, or null when the view is full: build
    /// its cells with `cell`.
    pub fn next(t: *Table) ?usize {
        const c = t.c;
        t.closeRow();
        const i = t.list.next() orelse return null;
        const s = t.state;
        const box = c.open(.{ .direction = .row, .width = .fill, .height = .{ .px = t.opts.row_height }, .align_items = .stretch, .control = true }, null);
        t.row = i;
        t.next_col = 0;
        const it = c.interact(box, .{});
        const picks = t.opts.drag_select or t.opts.cells or s.selection != null;
        const col = if (t.opts.cells) cells_mod.colAt(c, t.id, t.columns) else null;
        const adding = s.selection != null and c.input.adding();
        if (it.pressed and c.input.pressed) {
            t.takeFocus();
            if (picks) {
                // Outside the choice, it chooses as the pointer goes down;
                // inside, at the release, so a drag of the choice keeps it.
                // A Shift-press extends the choice, and so does its drag;
                // a Cmd-press adds the row or takes it out.
                const inside = if (col) |k| s.cellChosen(i, k) else s.rowChosen(i);
                if (c.input.shift) t.extend(i, col) else if (adding) t.toggle(i) else if (!inside) t.choose(i, col);
                s.drag = if (c.input.shift)
                    .{ .row = s.anchor orelse i, .col = if (s.cols) |cs| cs[0] else col }
                else
                    .{ .row = i, .col = col };
            }
        }
        if (it.clicked) {
            const moved = if (s.drag) |d| d.moved else false;
            if (!picks) {
                if (s.selected != i) {
                    s.selected = i;
                    t.result.changed = true;
                }
            } else if (!c.input.shift and !adding and !moved) t.choose(i, col);
            if (it.double_clicked) t.result.submitted = true;
            c.changed = true;
        }
        if (it.hovered and @import("overlay_base.zig").rightPressed(c)) t.rightClick(i, col);
        const hover = c.animate(it.id, 0, if (it.hovered) 1 else 0, 20);
        const now_chosen = s.rowChosen(i);
        // Each row says which of all it is, though only those in view are built.
        c.describe(it.id, .{ .role = .row, .selected = now_chosen, .pos_in_set = @intCast(i + 1), .set_size = @intCast(t.list.opts.count) });
        if (s.selected == i) c.describe(t.id, .{ .active_descendant = it.id });
        // Choosing cells, the cells show the choice, not the rows.
        var bg = structure.rowBackground(c, now_chosen and !t.opts.cells, t.focused, hover);
        if (bg == null and t.opts.striped and i % 2 == 1) bg = c.theme.text.alpha(0.03);
        c.node(box).style.background = bg;
        return i;
    }

    /// Chooses row `row` (and column `col`) alone; a row header's column,
    /// every column.
    fn choose(t: *Table, row: usize, col: ?usize) void {
        const s = t.state;
        if (Choice.only(s, row)) t.result.changed = true;
        if (col) |k| if (t.columns[k].row_header) {
            const every = [2]usize{ 0, t.columns.len - 1 };
            if (!std.meta.eql(s.cols, every)) t.result.changed = true;
            s.cols = every;
            t.c.changed = true;
            return;
        };
        if (col) |k| {
            if (!std.meta.eql(s.cols, [2]usize{ k, k })) t.result.changed = true;
            s.cols = .{ k, k };
        }
        t.c.changed = true;
    }

    /// Extends the choice from where it began to row `row` (column `col`).
    fn extend(t: *Table, row: usize, col: ?usize) void {
        const s = t.state;
        if (s.anchor == null) s.anchor = s.selected orelse row;
        if (s.selected != row) t.result.changed = true;
        _ = Choice.extend(s, row, t.c.input.adding());
        if (col) |k| {
            // From a row header, whole rows.
            const from = if (t.columns[k].row_header) 0 else if (s.cols) |cs| cs[0] else k;
            const to = if (t.columns[k].row_header) t.columns.len - 1 else k;
            if (!std.meta.eql(s.cols, [2]usize{ from, to })) t.result.changed = true;
            s.cols = .{ from, to };
        }
        t.c.changed = true;
    }

    /// Adds row `row` to the set chosen, or takes it out; the columns stay.
    fn toggle(t: *Table, row: usize) void {
        _ = Choice.toggle(t.state, row);
        t.result.changed = true;
        t.c.changed = true;
    }

    /// A right-click on row `row` (column `col`): outside the choice, it
    /// chooses that row (that cell) before the menu opens; inside, the
    /// choice stays.
    fn rightClick(t: *Table, row: usize, col: ?usize) void {
        const s = t.state;
        t.result.menu_row = row;
        t.result.menu_col = col;
        const several = s.selection != null or t.opts.drag_select or t.opts.cells;
        if (!several or s.menu_keeps_selection) return;
        const inside = if (col) |k| s.cellChosen(row, k) else s.rowChosen(row);
        if (!inside) t.choose(row, col);
    }

    /// Whether the cell of `row` and column `col` is in the block chosen,
    /// for a cell builder's text on the accent.
    pub fn cellSelected(t: *const Table, row: usize, col: usize) bool {
        return t.opts.cells and t.state.cellChosen(row, col);
    }

    /// The next column of the row, its cell opened for its content, or null
    /// after the last.
    pub fn cell(t: *Table) ?usize {
        const c = t.c;
        std.debug.assert(t.row != null);
        t.closeCell();
        while (t.next_col < t.columns.len and t.columns[t.next_col].hidden) t.next_col += 1;
        if (t.next_col >= t.columns.len) return null;
        const col = t.next_col;
        t.next_col += 1;
        c.next_key_int = col;
        const cell_box = c.open(column_mod.cellStyle(t.columns[col]), null);
        t.cell_box = cell_box;
        if (t.cellSelected(t.row.?, col)) c.node(cell_box).style.background = if (t.focused) c.theme.accent else c.theme.text.alpha(0.12);
        t.col = col;
        c.describeOpen(.{ .role = .cell });
        t.in_cell = true;
        return col;
    }

    /// The color of text on the row being built (with `cells`, in the cell
    /// being built): the accent's text on what is chosen while the table
    /// has the focus.
    pub fn textColor(t: *const Table) types.Color {
        const row = t.row orelse return t.c.theme.text;
        const chosen = if (t.opts.cells) t.cellSelected(row, t.col) else t.state.rowChosen(row);
        return structure.rowText(t.c, chosen, t.focused);
    }

    /// Closes the cell being built: a right-click over it, which what it
    /// holds did not take, opens the cell menu.
    fn closeCell(t: *Table) void {
        if (!t.in_cell) return;
        const c = t.c;
        if (t.opts.cell_menu != null and !t.state.cell_menu.isOpen() and @import("overlay_base.zig").rightPressed(c)) {
            if (c.rects.get(c.node(t.cell_box).id)) |r| if (r.contains(c.input.mouse)) {
                c.input.right_pressed = false;
                t.state.cell_menu.openAt(c.input.mouse);
                t.state.menu_cell = .{ t.row.?, t.col };
                c.changed = true;
            };
        }
        c.end();
        t.in_cell = false;
    }

    fn closeRow(t: *Table) void {
        if (t.row == null) return;
        t.closeCell();
        t.c.end();
        t.row = null;
    }

    fn takeFocus(t: *Table) void {
        if (t.c.focus == t.id) return;
        t.c.focus = t.id;
        t.focused = true;
        t.c.changed = true;
    }

    pub fn end(t: *Table) Result {
        t.closeRow();
        t.list.end();
        if (t.opts.cell_menu) |cm| if (menu_mod.menu(t.c, &t.state.cell_menu)) |p| {
            cm.build(cm.ctx, p, t.state.menu_cell[0], t.state.menu_cell[1]);
            // A menu without items does not open.
            if (p.count == 0) t.state.cell_menu.close();
            p.end();
        };
        Choice.remember(t.state);
        t.c.end();
        // The drag over the rows ends with the release, once its click is read.
        if (!t.c.input.down) t.state.drag = null;
        t.result.focused = t.focused;
        return t.result;
    }
};

/// Opens a table of `count` rows in `columns`: `next` each row in view,
/// `cell` each of its columns, then `end`.
pub fn table(c: *Context, state: *TableState, input_columns: []const Column, count: usize, opts: Options) Table {
    const columns = if (opts.column_widths) |widths| blk: {
        std.debug.assert(widths.len == input_columns.len);
        const copy = c.alloc().dupe(Column, input_columns) catch @panic("OOM");
        for (copy, widths) |*col, width| col.width = if (width > 0) std.math.clamp(width, @max(1, col.min_width), @max(col.min_width, col.max_width)) else 0;
        break :blk copy;
    } else input_columns;
    _ = c.open(.{ .direction = .column, .width = opts.width, .height = opts.height }, null);
    var result: Result = .{};
    column_mod.header(c, state, columns, count, opts, &result);
    // The choice follows its items (with a key), within the rows.
    Choice.sync(state, count);
    const id = c.peekId(null);
    const focused = c.focus == id;
    const picks = opts.drag_select or opts.cells or state.selection != null;
    var scroll_to: ?f32 = null;
    if (focused) if (c.input.key) |k| {
        const view_h = if (c.rects.get(id)) |r| r.h else c.size.h;
        const page: usize = @intFromFloat(@max(1, @floor(view_h / opts.row_height) - 1));
        if (k == .enter and state.selected != null) {
            _ = structure.takeKey(c);
            result.submitted = true;
            c.changed = true;
        } else if (structure.step(k, state.selected, count, .up, .down, page)) |to| {
            _ = structure.takeKey(c);
            c.changed = true;
            if (state.selected != to) {
                state.selected = to;
                result.changed = true;
            }
            // Shift extends the rows (and the columns); else one row, and
            // one column.
            if (picks) if (c.input.shift) {
                if (state.anchor == null) state.anchor = to;
            } else {
                state.anchor = to;
                if (state.cols) |cs| state.cols = .{ cs[1], cs[1] };
            };
            if (state.selection != null) _ = if (c.input.shift) Choice.extend(state, to, false) else Choice.only(state, to);
            const top = opts.row_height * @as(f32, @floatFromInt(to));
            scroll_to = structure.reveal(top, opts.row_height, c.scroll.get(id) orelse 0, view_h);
        } else if (opts.cells and columns.len > 0 and (k == .left or k == .right)) {
            _ = structure.takeKey(c);
            c.changed = true;
            const cs = state.cols orelse [2]usize{ 0, 0 };
            var to = @min(cs[1], columns.len - 1);
            var remaining = columns.len;
            while (remaining > 0) : (remaining -= 1) {
                const next = if (k == .left) to -| 1 else @min(columns.len - 1, to + 1);
                if (next == to) break;
                to = next;
                if (!columns[to].hidden) break;
            }
            if (columns[to].hidden) to = cs[1];
            state.cols = if (c.input.shift) .{ cs[0], to } else .{ to, to };
            if (state.selected == null and count > 0) {
                state.selected = 0;
                state.anchor = 0;
            }
            result.changed = true;
        }
    };
    if (focused and picks and count > 0 and c.shortcut(.{ .key = 'a', .cmd = true })) {
        state.anchor = 0;
        state.selected = count - 1;
        _ = Choice.all(state, count);
        if (opts.cells and columns.len > 0) state.cols = .{ 0, columns.len - 1 };
        result.changed = true;
    }
    if (opts.drag_select or opts.cells) dragSelect(c, state, id, columns, count, opts, &result) else state.drag = null;
    const l = list_mod.list(c, .{ .count = count, .row_height = opts.row_height, .height = .fill, .scroll_to = scroll_to });
    _ = c.interact(c.stack.items[c.stack.items.len - 1], .{ .focusable = true });
    c.describe(id, .{ .role = .table, .set_size = @intCast(count) });
    return .{ .c = c, .state = state, .columns = columns, .opts = opts, .list = l, .id = id, .focused = focused, .result = result };
}

/// A press on a row dragging over the rows (and cells) chooses what the
/// pointer goes over, from where it began, scrolling near the edges.
fn dragSelect(c: *Context, state: *TableState, id: u64, columns: []const Column, count: usize, opts: Options, result: *Result) void {
    const d = if (state.drag) |*x| x else return;
    // Released: what it chose stays, which the release's click reads.
    if (!c.input.down) return;
    if (c.input.pressed) return; // the press itself chose
    _ = cells_mod.autoScroll(c, id);
    const row = cells_mod.rowAt(c, id, opts.row_height, count) orelse return;
    const col = if (opts.cells) cells_mod.colAt(c, id, columns) else null;
    if (row != d.row or !std.meta.eql(col, d.col)) d.moved = true;
    result.drag_selecting = true;
    if (!d.moved) return;
    // Over a row header's cells, whole rows.
    const whole = if (d.col) |k| columns[k].row_header else false;
    const cols: ?[2]usize = if (whole) .{ 0, columns.len - 1 } else if (col) |k| .{ d.col orelse k, k } else state.cols;
    if (state.selected != row or state.anchor != d.row or !std.meta.eql(state.cols, cols)) {
        state.anchor = d.row;
        state.selected = row;
        _ = Choice.extend(state, row, false);
        state.cols = cols;
        result.changed = true;
        c.changed = true;
    }
}
