//! Choosing blocks of rows and cells in a table, after mygo's cell
//! selection and drag select (`table.zig` options `drag_select` and
//! `cells`): the rows chosen are those from the row Shift extends from
//! (`TableState.anchor`) to the cursor's (`selected`); with `cells`, times
//! the columns from `cols[0]` to `cols[1]`, as a spreadsheet chooses a
//! block. A press on a row (a cell) outside the choice chooses it as the
//! pointer goes down; one inside waits for the release, so a drag of the
//! choice keeps it. Dragging chooses what the pointer goes over, scrolling
//! the table near its top and bottom. With `cells`, Left and Right move
//! the cursor's column, Shift with them extends the columns, and the keys
//! that move the rows leave one column unless with Shift; Cmd+A (Ctrl+A)
//! chooses every row and column.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;

/// A press on a row dragging over the rows: the row and column it began on.
pub const Drag = struct { row: usize, col: ?usize = null, moved: bool = false };

/// The block from `a` to `b`, either way, as low and high.
pub fn span(a: usize, b: usize) [2]usize {
    return .{ @min(a, b), @max(a, b) };
}

/// The row under the pointer, from the last frame's list `id`: the first
/// or the last above or below the rows.
pub fn rowAt(c: *Context, id: u64, row_h: f32, count: usize) ?usize {
    if (count == 0) return null;
    const r = c.rects.get(id) orelse return null;
    const y = c.input.mouse.y - r.y + (c.scroll.get(id) orelse 0);
    if (y < 0) return 0;
    const i: usize = @intFromFloat(@floor(y / @max(1, row_h)));
    return @min(i, count - 1);
}

/// The column under the pointer in list `id`, as the columns share its
/// width: those of a width keep it, the others share what is left.
pub fn colAt(c: *Context, id: u64, widths: anytype) ?usize {
    const r = c.rects.get(id) orelse return null;
    if (widths.len == 0) return null;
    var fixed: f32 = 0;
    var fills: f32 = 0;
    for (widths) |col| {
        if (col.width > 0) fixed += col.width else fills += 1;
    }
    const share = if (fills > 0) @max(0, r.w - fixed) / fills else 0;
    var x = r.x;
    for (widths, 0..) |col, i| {
        x += if (col.width > 0) col.width else share;
        if (c.input.mouse.x < x) return i;
    }
    return widths.len - 1;
}

/// Scrolls list `id` while a drag goes near or past its top or bottom,
/// faster the further it goes; true while it does.
pub fn autoScroll(c: *Context, id: u64) bool {
    const r = c.rects.get(id) orelse return false;
    const edge: f32 = 16;
    const y = c.input.mouse.y;
    var d: f32 = 0;
    if (y < r.y + edge) d = y - (r.y + edge) else if (y > r.y + r.h - edge) d = y - (r.y + r.h - edge);
    if (d == 0) return false;
    const off = c.scroll.get(id) orelse 0;
    const limit = c.scroll_limit.get(id) orelse std.math.inf(f32);
    const to = std.math.clamp(off + std.math.clamp(d, -40, 40) * 12 * c.dt, 0, limit);
    if (to == off) return false;
    c.scroll.put(c.gpa, id, to) catch return false;
    c.animationFrame();
    return true;
}

test "a block from either end" {
    try std.testing.expectEqual([2]usize{ 2, 5 }, span(5, 2));
    try std.testing.expectEqual([2]usize{ 3, 3 }, span(3, 3));
}
