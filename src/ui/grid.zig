//! A grid, after mygo's `ui.Grid` and CSS grid: children fill its cells
//! row by row, or go where they are put, spanning columns and rows. Its
//! tracks are `.{ .px = 220 }`, `.{ .fr = 1 }` (a share of the room the
//! others leave) or `.fit` (as large as their content); rows beyond those
//! given fit their content. A grid builds all its children; for many
//! items built as they show, use `ui.gridView`.
//!
//!     var g = ui.grid(c, .{ .columns = &.{ .fit, .{ .fr = 1 } }, .gap_x = 16, .gap_y = 8 });
//!     g.cell(.{ .col_span = -1 }); // across every column
//!     ui.text(c, "Profile", .{ .weight = .bold });
//!     ui.end(c);
//!     ui.text(c, "Name", .{}); // a child outside a cell takes the next one
//!     _ = ui.textField(c, &s.name, .{});
//!     g.end();
//!
//! Children stretch to fill their cells unless `justify_items` and
//! `align_items` (or a cell's `justify` and `align`) say otherwise.
//! Right to left, its columns go from the right (`direction.zig`).
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const none = ctx_mod.none;

pub const Track = union(enum) {
    /// As large as its content.
    fit,
    /// Exactly this many points.
    px: f32,
    /// A share of the room the other tracks leave (CSS's minmax(0, 1fr));
    /// where the grid's size is not set, as large as its content.
    fr: f32,
};

/// Where in its grid alignment puts a child within its cell.
/// `baseline` lines up the first lines of text of the items of each row
/// (spanning one row), as a row of boxes does (`layout_baseline.zig`).
pub const Align = enum { stretch, start, center, end, baseline };

pub const Options = struct {
    columns: []const Track = &.{.{ .fr = 1 }},
    /// The first rows; those after fit their content.
    rows: []const Track = &.{},
    gap_x: f32 = 0,
    gap_y: f32 = 0,
    justify_items: Align = .stretch,
    align_items: Align = .stretch,
    /// The grid box itself (padding, background, size): `.fill` wide by
    /// default.
    style: types.Style = .{ .width = .fill },
};

pub const Cell = struct {
    /// The column and row it starts in, from 1; 0 places it in the next
    /// free cell.
    col: u16 = 0,
    row: u16 = 0,
    /// How many columns and rows it spans; negative to the last column
    /// (or the last row the grid gives).
    col_span: i16 = 1,
    row_span: i16 = 1,
    justify: ?Align = null,
    @"align": ?Align = null,
    /// The cell's box (a column), filling the cell as its grid aligns it.
    style: types.Style = .{},
};

/// A child placed in its grid: from column `col` and row `row`, from 0.
pub const Placed = struct {
    col: u16,
    row: u16,
    col_span: u16,
    row_span: u16,
    justify: Align,
    @"align": Align,
};

pub const max_tracks = 32;
const max_grids = 32;
const max_cells = 4096;

/// What layout reads of a grid (`lookup`), kept by value: its tracks and
/// where its children go, in order.
pub const Spec = struct {
    columns: [max_tracks]Track = undefined,
    rows: [max_tracks]Track = undefined,
    n_cols: u16 = 0,
    /// The rows its children reach, at least those given.
    n_rows: u16 = 0,
    n_given_rows: u16 = 0,
    gap_x: f32 = 0,
    gap_y: f32 = 0,
    cells_lo: u32 = 0,
    cells_hi: u32 = 0,

    pub fn column(s: *const Spec, i: usize) Track {
        return if (i < s.n_cols) s.columns[i] else .fit;
    }

    pub fn row(s: *const Spec, i: usize) Track {
        return if (i < s.n_given_rows) s.rows[i] else .fit;
    }

    pub fn cells(s: *const Spec) []const Placed {
        return registry.cells[s.cells_lo..s.cells_hi];
    }
};

// The grids of the frame being built, until boxes have a field for them:
// one context's, by value (nothing points into the frame's memory), found
// by box index and id. A build pass of the same frame starts again when
// the tree is shorter than at the last grid's end. Native UI runs on the
// main thread only.
const Registry = struct {
    ctx: ?*Context = null,
    frame: u64 = 0,
    last_len: usize = 0,
    grids: [max_grids]struct { index: u32, id: u64, spec: Spec } = undefined,
    n_grids: usize = 0,
    cells: [max_cells]Placed = undefined,
    n_cells: u32 = 0,
};
var registry: Registry = .{};

fn sameFrame(c: *Context) bool {
    return registry.ctx == c and registry.frame == c.frame;
}

/// The grid box `index` is, in this frame, if it is one.
pub fn lookup(c: *Context, index: u32) ?*const Spec {
    if (!sameFrame(c) or registry.n_grids == 0) return null;
    const id = c.nodes.items[index].id;
    for (registry.grids[0..registry.n_grids]) |*g| if (g.index == index and g.id == id) {
        const n = c.nodes.items[index];
        if (n.child_count != g.spec.cells_hi - g.spec.cells_lo) return null;
        return &g.spec;
    };
    return null;
}

pub const Grid = struct {
    c: *Context,
    index: u32,
    opts: Options,
    /// Cells given (`cell`), by the child's place among the grid's.
    given: std.ArrayList(struct { at: u32, cell: Cell }) = .empty,

    /// Opens a cell: its children follow, then `ui.end`.
    pub fn cell(g: *Grid, opts: Cell) void {
        const c = g.c;
        const at = c.node(g.index).child_count;
        g.given.append(c.alloc(), .{ .at = at, .cell = opts }) catch {};
        var s = opts.style;
        s.direction = .column;
        _ = c.open(s, null);
    }

    /// Closes the grid, placing its children in its cells.
    pub fn end(g: *Grid) void {
        const c = g.c;
        std.debug.assert(c.stack.items[c.stack.items.len - 1] == g.index);
        c.end();
        register(g) catch {};
    }

    fn register(g: *Grid) !void {
        const c = g.c;
        const len = c.nodes.items.len;
        if (!sameFrame(c) or len < registry.last_len) registry = .{ .ctx = c, .frame = c.frame };
        registry.last_len = len;
        const o = g.opts;
        if (o.columns.len > max_tracks or o.rows.len > max_tracks) return error.TooManyTracks;
        const n = c.node(g.index);
        if (registry.n_cells + n.child_count > max_cells) return error.TooManyCells;
        // A grid built again in this pass replaces itself.
        var slot: ?usize = null;
        for (registry.grids[0..registry.n_grids], 0..) |e, i| if (e.index == g.index and e.id == n.id) {
            slot = i;
        };
        if (slot == null) {
            if (registry.n_grids == max_grids) return error.TooManyGrids;
            slot = registry.n_grids;
            registry.n_grids += 1;
        }
        var spec: Spec = .{ .gap_x = o.gap_x, .gap_y = o.gap_y };
        spec.n_cols = @intCast(@max(1, o.columns.len));
        @memcpy(spec.columns[0..o.columns.len], o.columns);
        if (o.columns.len == 0) spec.columns[0] = .{ .fr = 1 };
        spec.n_given_rows = @intCast(o.rows.len);
        @memcpy(spec.rows[0..o.rows.len], o.rows);
        spec.cells_lo = registry.n_cells;
        const out = registry.cells[registry.n_cells..][0..n.child_count];
        spec.n_rows = @intCast(@min(max_tracks, place(c.alloc(), g, spec.n_cols, out) catch return error.OutOfMemory));
        registry.n_cells += n.child_count;
        spec.cells_hi = registry.n_cells;
        registry.grids[slot.?] = .{ .index = g.index, .id = n.id, .spec = spec };
    }

    /// Places the children as CSS does: those given both a column and a
    /// row, then those given a row, then the rest in order, a cursor
    /// going row by row. Returns the number of rows.
    fn place(arena: std.mem.Allocator, g: *Grid, n_cols: u16, out: []Placed) !usize {
        const o = g.opts;
        const cols: usize = n_cols;
        const given_rows = o.rows.len;
        // Each child's cell, given or not.
        const want = try arena.alloc(Cell, out.len);
        @memset(want, .{});
        for (g.given.items) |e| if (e.at < want.len) {
            want[e.at] = e.cell;
        };
        for (want, out) |w, *p| {
            const col0: u16 = if (w.col > 0) @min(w.col - 1, n_cols - 1) else 0;
            var cs: i32 = w.col_span;
            if (cs < 0) cs = @as(i32, n_cols) - col0 else if (cs == 0) cs = 1;
            var rs: i32 = w.row_span;
            const row0: i32 = if (w.row > 0) w.row - 1 else 0;
            if (rs < 0) rs = @max(1, @as(i32, @intCast(given_rows)) - row0) else if (rs == 0) rs = 1;
            p.* = .{
                .col = col0,
                .row = 0,
                .col_span = @intCast(std.math.clamp(cs, 1, @as(i32, n_cols) - col0)),
                .row_span = @intCast(@min(rs, max_tracks)),
                .justify = w.justify orelse o.justify_items,
                .@"align" = w.@"align" orelse o.align_items,
            };
        }
        var occ: Occupancy = .{ .cols = cols, .arena = arena };
        var rows: usize = given_rows;
        // Given a column and a row.
        for (want, out) |w, *p| if (w.col > 0 and w.row > 0) {
            p.row = w.row - 1;
            try occ.mark(p.*);
        };
        // Given a row: the first column where it fits.
        for (want, out) |w, *p| if (w.row > 0 and w.col == 0) {
            p.row = w.row - 1;
            var col: u16 = 0;
            while (col + p.col_span < n_cols and !occ.fits(p.*, p.row, col)) col += 1;
            p.col = col;
            try occ.mark(p.*);
        };
        // The rest, row by row.
        var cr: u16 = 0;
        var cc: u16 = 0;
        for (want, out) |w, *p| {
            if (w.row > 0) continue;
            if (w.col > 0) {
                if (p.col < cc) cr += 1;
                cc = p.col;
                while (!occ.fits(p.*, cr, cc)) cr += 1;
            } else while (true) {
                while (cc + p.col_span <= n_cols and !occ.fits(p.*, cr, cc)) cc += 1;
                if (cc + p.col_span <= n_cols) break;
                cr += 1;
                cc = 0;
            }
            p.row = cr;
            p.col = cc;
            try occ.mark(p.*);
            cc += p.col_span;
        }
        for (out) |p| rows = @max(rows, @as(usize, p.row) + p.row_span);
        return rows;
    }
};

const Occupancy = struct {
    cols: usize,
    arena: std.mem.Allocator,
    taken: std.ArrayList(bool) = .empty,

    fn at(o: *const Occupancy, r: usize, col: usize) bool {
        const i = r * o.cols + col;
        return i < o.taken.items.len and o.taken.items[i];
    }

    fn fits(o: *const Occupancy, p: Placed, r: u16, col: u16) bool {
        for (r..@as(usize, r) + p.row_span) |rr| for (col..@as(usize, col) + p.col_span) |cc| {
            if (cc >= o.cols or o.at(rr, cc)) return false;
        };
        return true;
    }

    fn mark(o: *Occupancy, p: Placed) !void {
        const need = (@as(usize, p.row) + p.row_span) * o.cols;
        if (need > o.taken.items.len) try o.taken.appendNTimes(o.arena, false, need - o.taken.items.len);
        for (p.row..@as(usize, p.row) + p.row_span) |rr| for (p.col..@as(usize, p.col) + p.col_span) |cc| {
            if (cc < o.cols) o.taken.items[rr * o.cols + cc] = true;
        };
    }
};

/// Opens a grid: its children follow, then `Grid.end`.
pub fn grid(c: *Context, opts: Options) Grid {
    var s = opts.style;
    s.direction = .column;
    const index = c.open(s, null);
    return .{ .c = c, .index = index, .opts = opts };
}
