//! Column layout, accessible headers and resize grips.
const std = @import("std");
const Context = @import("context.zig").Context;
const types = @import("types.zig");
const widgets = @import("widgets.zig");
const Choice = @import("selection_set.zig").Choice;
const structure = @import("structure.zig");
const base = @import("overlay_base.zig");
const direction = @import("direction.zig");
pub const Alignment = enum { start, center, end };

pub const Column = struct {
    title: []const u8,
    /// Points, or 0 to share the room left with the other such columns.
    width: f32 = 0,
    alignment: Alignment = .start,
    sortable: bool = false,
    /// A spreadsheet's row numbers: with `cells`, a click or a drag on its
    /// cells chooses whole rows, every column, and a click on its header
    /// every row. It does not sort.
    row_header: bool = false,
    /// Hidden columns keep their original index for sorting and cell().
    hidden: bool = false,
    min_width: f32 = 40,
    max_width: f32 = 2000,
};

pub fn cellStyle(col: Column) types.Style {
    return .{
        .direction = .row,
        .width = if (col.width > 0) .{ .px = col.width } else .fill,
        .align_items = .center,
        .justify = switch (col.alignment) {
            .start => .start,
            .center => .center,
            .end => .end,
        },
        .padding = .xy(8, 0),
        .clip = true,
    };
}

pub fn header(c: *Context, state: anytype, columns: []const Column, count: usize, opts: anytype, result: anytype) void {
    const th = c.theme;
    _ = c.open(.{ .direction = .row, .width = .fill, .height = .{ .px = opts.header_height }, .align_items = .stretch }, "header");
    for (columns, 0..) |col, i| {
        if (col.hidden) continue;
        c.next_key_int = i;
        var st = cellStyle(col);
        st.gap = 4;
        st.control = true;
        const box = c.open(st, null);
        defer c.end();
        const sorted_by = if (state.sort) |s| s.column == i else false;
        c.describe(c.node(box).id, .{ .role = .column_header, .label = col.title, .description = if (!sorted_by) "" else if (state.sort.?.descending) "descending" else "ascending" });
        if (col.row_header and opts.cells) {
            // A row header's header chooses every row and column.
            const it = c.interact(box, .{});
            if (it.clicked and count > 0) {
                state.anchor = 0;
                state.selected = count - 1;
                _ = Choice.all(state, count);
                state.cols = .{ 0, columns.len - 1 };
                result.changed = true;
                c.changed = true;
            }
        } else if (col.sortable) {
            const it = c.interact(box, .{ .focusable = true, .keys = true });
            widgets.focusRing(c, box, it);
            if (it.clicked) {
                state.sort = if (sorted_by) .{ .column = i, .descending = !state.sort.?.descending } else .{ .column = i };
                result.sorted = true;
                c.changed = true;
            }
            const hover = c.animate(it.id, 0, if (it.hovered) 1 else 0, 20);
            c.node(box).style.background = th.text.alpha(0.05 * hover);
        }
        widgets.text(c, col.title, .{ .size = 12, .weight = .semibold, .color = if (sorted_by) th.text else th.muted });
        if (col.sortable and sorted_by)
            widgets.icon(c, if (state.sort.?.descending) "chevron.down" else "chevron.up", .{ .size = 10, .weight = .semibold, .color = th.muted });
        if (opts.column_widths) |widths| {
            if (!col.row_header) resize(c, box, &widths[i], col, result);
        }
    }
    c.end();
    widgets.divider(c);
}

fn resize(c: *Context, box: u32, width: *f32, col: Column, result: anytype) void {
    const rect = c.rects.get(c.node(box).id) orelse return;
    const rtl = direction.of(c, box) == .rtl;
    const handle = c.leaf(.{ .absolute = true, .offset = .{ .x = @max(0, rect.w - c.node(box).style.padding.left - 6) }, .width = .{ .px = 6 }, .height = .fill, .background = c.theme.border }, .none, "resize");
    const it = c.interact(handle, .{ .focusable = true });
    c.describe(it.id, .{ .role = .splitter, .label = c.print("Resize {s}", .{col.title}), .vertical = true });
    widgets.focusRing(c, handle, it);
    if (it.hovered or it.pressed) c.cursor = .resize_left_right;
    if (it.pressed and c.input.pressed) {
        structure.slot(c, it.id, 10, 0).* = c.input.mouse.x;
        structure.slot(c, it.id, 11, rect.w).* = rect.w;
    }
    const origin = structure.slot(c, it.id, 10, 0).*;
    const initial = structure.slot(c, it.id, 11, rect.w).*;
    var wanted: ?f32 = null;
    if (it.pressed) wanted = initial + (c.input.mouse.x - origin) * @as(f32, if (rtl) -1 else 1);
    if (it.focused) {
        if (base.takeKey(c, .left)) wanted = rect.w + @as(f32, if (rtl) 10 else -10);
        if (base.takeKey(c, .right)) wanted = rect.w + @as(f32, if (rtl) -10 else 10);
        if (base.takeKey(c, .home)) wanted = col.min_width;
        if (base.takeKey(c, .end)) wanted = col.max_width;
    }
    if (wanted) |v| {
        const next = std.math.clamp(v, @max(1, col.min_width), @max(col.min_width, col.max_width));
        if (next != width.*) {
            width.* = next;
            result.resized = true;
            c.changed = true;
        }
    }
}
