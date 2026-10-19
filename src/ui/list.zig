//! A virtualized list, in the manner of GPUI's `uniform_list`: rows of one
//! height, of which only those in view (and a few around) are built, so a
//! list of a hundred thousand rows costs what a screenful does.
//!
//!     var rows = ui.list(c, .{ .count = items.len, .row_height = 28 });
//!     while (rows.next()) |i| {
//!         ui.row(c, .{ .height = .{ .px = 28 }, .align_items = .center });
//!         defer ui.end(c);
//!         ui.text(c, items[i].name, .{});
//!     }
//!     rows.end();
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;

pub const Options = struct {
    count: usize,
    row_height: f32,
    width: types.Length = .fill,
    height: types.Length = .fill,
    gap: f32 = 0,
    padding: types.Edges = .{},
    /// Rows built beyond each edge of the view, for smooth scrolling.
    overscan: usize = 4,
    /// Scrolls the list to this offset (points) in this frame.
    scroll_to: ?f32 = null,
    /// Starts at the end, and keeps it in view as rows come, until the
    /// reader scrolls away from it, as a chat or a log does
    /// (`Style.follow_end`).
    follow_end: bool = false,
    /// Following its end, glides there as rows come, as the animation says
    /// (`ui.FollowGlide.of(.smooth)`): what is added comes up from below
    /// (`Style.follow_glide`).
    follow_glide: ?*const @import("follow_glide.zig").FollowGlide = null,
    /// Its rows are chosen: a click, the keys, and with a selection Shift,
    /// Cmd and Cmd+A (`list_select.zig`). The list opens each row's box
    /// (`row_height` tall); build its content in it. `Rows.result` tells
    /// what changed, once `end`ed.
    choice: ?*select.Choice = null,
};

const select = @import("selection_set.zig");
const list_select = @import("list_select.zig");

pub const Rows = struct {
    c: *Context,
    opts: Options,
    next_index: usize,
    last: usize,
    id: u64 = 0,
    /// A row's box is open (with a choice).
    in_row: bool = false,
    result: list_select.Result = .{},

    /// The index of the next row to build, or null when the view is full.
    pub fn next(r: *Rows) ?usize {
        r.closeRow();
        if (r.next_index >= r.last) return null;
        const i = r.next_index;
        r.next_index += 1;
        // Rows keep their identity (hover, animations) as the list scrolls.
        r.c.next_key_int = i;
        if (r.opts.choice) |ch| {
            list_select.row(r.c, ch, i, r.opts.row_height, r.id, &r.result);
            r.in_row = true;
        }
        return i;
    }

    fn closeRow(r: *Rows) void {
        if (!r.in_row) return;
        r.c.end();
        r.in_row = false;
    }

    /// The color of text on the row being built: the accent's text on a
    /// row chosen while the list has the focus.
    pub fn textColor(r: *const Rows) types.Color {
        const ch = r.opts.choice orelse return r.c.theme.text;
        const i = r.next_index -| 1;
        return @import("structure.zig").rowText(r.c, select.Choice.chosen(ch, i), r.c.focus == r.id);
    }

    /// Closes the list: the room of the rows after the view, then the box.
    pub fn end(r: *Rows) void {
        r.closeRow();
        if (r.opts.choice) |ch| select.Choice.remember(ch);
        const pitch = r.opts.row_height + r.opts.gap;
        const after = r.opts.count - r.last;
        if (after > 0) _ = r.c.leaf(.{ .height = .{ .px = pitch * @as(f32, @floatFromInt(after)) - r.opts.gap } }, .none, "list-after");
        r.c.end();
    }
};

pub fn list(c: *Context, opts_in: Options) Rows {
    const id = c.peekId(null);
    var opts = opts_in;
    var result: list_select.Result = .{};
    if (opts.choice) |ch| {
        const view_h0 = if (c.rects.get(id)) |r| r.h else c.size.h;
        if (list_select.begin(c, ch, id, opts.count, opts.row_height + opts.gap, view_h0, &result)) |y| opts.scroll_to = y;
    }
    if (opts.scroll_to) |y| c.scroll.put(c.gpa, id, @max(0, y)) catch {};
    const i = c.open(.{
        .direction = .column,
        .width = opts.width,
        .height = opts.height,
        .padding = opts.padding,
        .scroll = true,
        .follow_end = opts.follow_end,
        .follow_glide = opts.follow_glide,
    }, null);
    std.debug.assert(c.node(i).id == id);
    const pitch = opts.row_height + opts.gap;
    // The view's height as the last frame laid it out; a screenful at first.
    const view_h = if (c.rects.get(id)) |r| r.h else c.size.h;
    // The list knows its height: keep the offset inside it before building
    // the spacers that make it, which layout would otherwise clamp too late.
    const content_h = pitch * @as(f32, @floatFromInt(opts.count)) - opts.gap + opts.padding.vertical();
    const max_scroll = @max(0, content_h - view_h);
    if (c.scroll.getPtr(id)) |sc| sc.* = std.math.clamp(sc.*, 0, max_scroll);
    // Following its end, the layout will show the end: the rows there.
    const follows = opts.follow_end and opts.scroll_to == null and (c.scroll_follow.get(id) orelse true);
    const at = if (follows) max_scroll else c.scroll.get(id) orelse 0;
    const offset = @max(0, at - opts.padding.top);
    const first_visible: usize = @intFromFloat(@floor(offset / pitch));
    const visible: usize = @intFromFloat(@ceil(view_h / pitch) + 1);
    // Rows gliding to the end show below their place: those above come
    // into view.
    const glide: f32 = if (c.follow_glides.get(id)) |g| @floatCast(@max(0, g.lag.value)) else 0;
    const first = first_visible -| (opts.overscan + @as(usize, @intFromFloat(@ceil(glide / pitch))));
    const last = @min(opts.count, first_visible + visible + opts.overscan);
    if (first > 0) _ = c.leaf(.{ .height = .{ .px = pitch * @as(f32, @floatFromInt(first)) - opts.gap } }, .none, "list-before");
    // The spacers stand for rows and their gaps: the gap between them and
    // the first row built is the column's own.
    c.node(i).style.gap = opts.gap;
    if (opts.choice != null) {
        _ = c.interact(i, .{ .focusable = true });
        c.describe(id, .{ .role = .list, .set_size = @intCast(opts.count) });
    }
    return .{ .c = c, .opts = opts, .next_index = @min(first, last), .last = last, .id = id, .result = result };
}
