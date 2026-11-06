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
    /// Shown over a sortable header on hover, when set.
    tooltip: []const u8 = "",
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

/// A table scrolling sideways (`Options.sideways`): the frame's offset and
/// where its columns go, the frozen ones at the box's leading edge. The other
/// cells of a row share a clipped box, which starts past the frozen ones and
/// stays there while its content moves, so what scrolls never goes under them
/// and they need no background of their own.
pub const Sideways = struct {
    on: bool = false,
    /// The box that scrolls, and its width as the last frame laid it out.
    id: u64 = 0,
    view: f32 = 0,
    x: f32 = 0,
    /// How many of the first columns stay (hidden ones count), how wide
    /// those shown are, and how wide the others are.
    frozen: usize = 0,
    frozen_w: f32 = 0,
    rest_w: f32 = 0,

    pub fn total(s: Sideways) f32 {
        return s.frozen_w + s.rest_w;
    }

    /// Opens the box of the cells that scroll; `endRest` closes it.
    pub fn openRest(s: Sideways, c: *Context) void {
        _ = c.open(.{ .direction = .row, .width = .{ .px = s.rest_w }, .align_items = .stretch, .clip = true, .offset = .{ .x = s.x } }, "rest");
        _ = c.open(.{ .direction = .row, .width = .{ .px = s.rest_w }, .align_items = .stretch, .offset = .{ .x = -s.x } }, null);
    }

    /// With a line along the frozen columns once something is under them.
    pub fn endRest(s: Sideways, c: *Context) void {
        c.end();
        if (s.x > 0) _ = c.leaf(.{ .absolute = true, .width = .{ .px = 1 }, .height = .fill, .background = c.theme.border }, .none, "edge");
        c.end();
    }

    /// Scrolls column `col` of `columns` into the room the frozen ones leave.
    pub fn reveal(s: Sideways, c: *Context, columns: []const Column, col: usize) void {
        if (!s.on or col < s.frozen or col >= columns.len) return;
        var at: f32 = 0;
        for (columns[s.frozen..col]) |k| {
            if (!k.hidden) at += k.width;
        }
        if (structure.reveal(at, columns[col].width, s.x, s.view - s.frozen_w)) |to| c.scroll.put(c.gpa, s.id, to) catch {};
    }
};

/// Below this room, the frozen columns scroll with the others: else the
/// others could not be reached at all.
const min_rest: f32 = 48;

/// Gives every column shown its width in a box `view` wide, as a table
/// scrolling sideways needs (those that share the room get at least their
/// `min_width`), in frame memory, and says where they go.
pub fn sideways(c: *Context, input: []const Column, frozen: usize, view: f32) struct { columns: []const Column, side: Sideways } {
    const columns = c.alloc().dupe(Column, input) catch @panic("OOM");
    var fixed: f32 = 0;
    var fills: f32 = 0;
    for (columns) |col| {
        if (col.hidden) continue;
        if (col.width > 0) fixed += col.width else fills += 1;
    }
    const share = if (fills > 0) (view - fixed) / fills else 0;
    var side: Sideways = .{ .on = true, .id = c.peekId(null), .view = view, .frozen = @min(frozen, columns.len) };
    var whole: f32 = 0;
    for (columns, 0..) |*col, i| {
        if (col.hidden) continue;
        if (col.width <= 0) col.width = @max(share, col.min_width);
        if (i < side.frozen) side.frozen_w += col.width;
        whole += col.width;
    }
    if (side.frozen_w == 0 or side.frozen_w + min_rest > view) {
        side.frozen = 0;
        side.frozen_w = 0;
    }
    // Narrower than the box, they leave room the rows still fill.
    whole = @max(whole, view);
    side.rest_w = whole - side.frozen_w;
    side.x = std.math.clamp(c.scroll.get(side.id) orelse 0, 0, whole - view);
    return .{ .columns = columns, .side = side };
}

pub fn header(c: *Context, state: anytype, columns: []const Column, count: usize, opts: anytype, side: Sideways, result: anytype) void {
    const th = c.theme;
    _ = c.open(.{ .direction = .row, .width = .fill, .height = .{ .px = opts.header_height }, .align_items = .stretch }, "header");
    var in_rest = false;
    for (columns, 0..) |col, i| {
        if (col.hidden) continue;
        if (side.frozen > 0 and i >= side.frozen and !in_rest) {
            side.openRest(c);
            in_rest = true;
        }
        c.next_key_int = i;
        var st = cellStyle(col);
        st.gap = 4;
        st.control = true;
        if (i < side.frozen) st.offset.x = side.x;
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
            if (col.tooltip.len > 0) @import("popover.zig").tooltip(c, it, col.tooltip);
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
    if (in_rest) side.endRest(c);
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
