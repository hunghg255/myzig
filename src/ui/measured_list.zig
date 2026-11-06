//! A virtualized list of rows of any height, in the manner of GPUI's `list`:
//! a chat, a feed, a log of wrapped lines. Only the rows in view (and a few
//! around) are built, and each is measured as it closes, in the frame that
//! builds it, so the rows stop as the view fills and what shows is never a
//! guess. Rows never built count for `estimate`.
//!
//!     var rows = ui.measuredList(c, &s.messages, .{ .count = items.len, .estimate = 60, .gap = 8 });
//!     while (rows.next()) |i| ui.text(c, items[i].text, .{ .wrap = true });
//!     rows.end();
//!
//! The reader's place is a row and how far into it they are, not an offset:
//! as rows above are measured and turn out taller or shorter than thought,
//! the offset changes in the same frame and nothing on screen moves. A row
//! keeps its height until it is built again, or the list's width changes,
//! which forgets them all (their lines wrap anew).
const std = @import("std");
const types = @import("types.zig");
const layout = @import("layout.zig");
const structure = @import("structure.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;

/// What a measured list keeps across frames: the app owns it.
pub const State = struct {
    /// A row the app wants shown: the next frame brings it to the top of
    /// the view, unless all of it shows, then clears it.
    reveal: ?usize = null,
    /// Where each row starts, with the gaps, and past the last row's gap.
    tops: std.ArrayListUnmanaged(f64) = .empty,
    /// What the tops were reckoned for.
    width: f32 = -1,
    estimate: f32 = 0,
    gap: f32 = 0,
    forget: bool = false,
    /// The row at the top of the view and how far into it the view starts;
    /// less than nothing, in the padding above the first row.
    anchor: usize = 0,
    into: f64 = 0,
    /// The offset as this list last left it: another means it was moved,
    /// and the frame that happened in.
    seen: f32 = 0,
    moved_at: ?u64 = null,
    size: types.Size = .{},

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.tops.deinit(gpa);
        s.* = .{};
    }

    /// Forgets every row's height: the rows changed in ways the list can't
    /// see out of view (they were filtered, sorted, or rows came above).
    pub fn reset(s: *State) void {
        s.forget = true;
    }

    /// Takes `count` rows, reckoning those not measured at `pitch`.
    fn sync(s: *State, gpa: std.mem.Allocator, count: usize, width: f32, estimate: f32, gap: f32) void {
        const pitch: f64 = estimate + gap;
        const redo = s.forget or s.tops.items.len == 0 or s.width != width or s.estimate != estimate or s.gap != gap;
        s.forget = false;
        s.width = width;
        s.estimate = estimate;
        s.gap = gap;
        const had = if (redo) 0 else s.tops.items.len;
        s.tops.resize(gpa, count + 1) catch @panic("OOM");
        if (redo) s.tops.items[0] = 0;
        var i = @max(had, 1);
        while (i <= count) : (i += 1) s.tops.items[i] = s.tops.items[i - 1] + pitch;
        if (s.anchor >= count) {
            s.anchor = count -| 1;
            s.into = 0;
        }
    }

    /// Takes the row at `y` of the rows for the reader's place.
    fn anchorAt(s: *State, y: f64, count: usize) void {
        const tops = s.tops.items;
        var lo: usize = 0;
        var hi: usize = count;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (tops[mid] <= y) lo = mid else hi = mid;
        }
        s.anchor = lo;
        s.into = y - tops[lo];
    }

    fn place(s: *const State) f64 {
        return s.tops.items[s.anchor] + s.into;
    }

    /// The place of a view `view` tall at the end of `count` rows.
    fn endPlace(s: *const State, count: usize, view: f64, pad: types.Edges) f64 {
        const content = @max(0, s.tops.items[count] - s.gap) + pad.vertical();
        return @max(0, content - view) - pad.top;
    }
};

pub const Options = struct {
    count: usize,
    /// About how tall a row is, for the rows not built yet: the scroll bar
    /// and how many rows a jump passes over read it, what shows does not.
    estimate: f32 = 44,
    width: types.Length = .fill,
    height: types.Length = .fill,
    gap: f32 = 0,
    padding: types.Edges = .{},
    /// Rows built beyond each edge of the view.
    overscan: usize = 2,
    /// Starts at the end, and keeps it in view as rows come or grow, until
    /// the reader scrolls away from it, as a chat or a log does.
    follow_end: bool = false,
};

pub const Rows = struct {
    c: *Context,
    s: *State,
    opts: Options,
    id: u64,
    /// The next row, and the first built.
    index: usize,
    first: usize,
    /// How tall the view is, with its padding, and how many rows go past
    /// its bottom.
    view: f64,
    past: usize,
    following: bool,
    /// The box of the row being built.
    box: ?u32 = null,
    /// How far the rows built moved those after them.
    shift: f64 = 0,

    /// The index of the next row, its box open for its content, or null
    /// when the view is full.
    pub fn next(r: *Rows) ?usize {
        r.closeRow();
        const s = r.s;
        if (r.index >= r.opts.count) return null;
        // Following its end, the rows to the end show, however tall.
        if (!r.following and r.index > s.anchor and s.tops.items[r.index] >= s.place() + r.view) {
            if (r.past == 0) return null;
            r.past -= 1;
        }
        const i = r.index;
        r.index += 1;
        // Rows keep their identity (hover, animations) as the list scrolls.
        r.c.next_key_int = i;
        r.box = r.c.open(.{ .direction = .column, .width = .fill }, null);
        return i;
    }

    fn closeRow(r: *Rows) void {
        const box = r.box orelse return;
        r.box = null;
        const c = r.c;
        c.end();
        // Measured as layout will, at the width it will give the row.
        const h = layout.measure(c, box, r.s.width).h;
        const s = r.s;
        const tops = s.tops.items;
        const i = r.index - 1;
        const was = tops[i + 1];
        tops[i + 1] = tops[i] + h + r.opts.gap;
        const shift = tops[i + 1] - was;
        // Of the row at the view's top, the end shows: what comes after it
        // stays, and what it gained or lost goes above the view. A row seen
        // from its start stays as it is.
        if (i == s.anchor and s.into > 0) s.into += shift - r.shift;
        r.shift = shift;
    }

    /// Closes the list: the room of the rows after the view, then the box.
    pub fn end(r: *Rows) void {
        r.closeRow();
        const c = r.c;
        const s = r.s;
        const count = r.opts.count;
        const gap: f64 = r.opts.gap;
        if (r.shift != 0) for (s.tops.items[r.index + 1 .. count + 1]) |*t| {
            t.* += r.shift;
        };
        const tops = s.tops.items;
        if (r.index < count) _ = c.leaf(.{ .height = .{ .px = @floatCast(tops[count] - tops[r.index] - gap) } }, .none, "list-after");
        c.end();

        // The rows' room is known now: the view's place within it.
        const pad = r.opts.padding;
        const top = s.endPlace(count, r.view, pad);
        const y = @max(-pad.top, if (r.following) top else @min(s.place(), top));
        if (count > 0) s.anchorAt(y, count);
        const offset: f32 = @floatCast(y + pad.top);
        // Following, layout takes it to the end, as a move of its own.
        if (!r.following and offset != (c.scroll.get(r.id) orelse 0)) {
            c.scroll.put(c.gpa, r.id, offset) catch {};
            // Not the reader's move: layout must not stop following for it.
            // The reader's, it has yet to see.
            if (r.opts.follow_end and s.moved_at != c.frame) c.scroll_seen.put(c.gpa, r.id, offset) catch {};
        }
        s.seen = offset;
        // Fewer rows than thought fill the end: those above, not built yet,
        // show there. Built again from where they turned out to be.
        if (r.first > 0 and tops[r.first] > y) {
            c.changed = true;
            c.animationFrame();
        }
    }
};

pub fn measuredList(c: *Context, s: *State, opts: Options) Rows {
    const id = c.peekId(null);
    const last = c.rects.get(id);
    const box: types.Size = if (last) |b| .{ .w = b.w, .h = b.h } else c.size;
    // The window's new size shows in the next frame's rectangles, and the
    // first frame has none: what they change is built in one more.
    if (last == null or s.size.w != c.size.w or s.size.h != c.size.h) c.animationFrame();
    s.size = c.size;
    // It opens at the top: its padding shows.
    if (s.tops.items.len == 0) s.into = -opts.padding.top;
    s.sync(c.gpa, opts.count, @max(0, box.w - opts.padding.horizontal()), opts.estimate, opts.gap);
    const view: f64 = box.h;
    const rows = @max(opts.count, 1);

    const offset = c.scroll.get(id) orelse 0;
    if (offset != s.seen) {
        s.moved_at = c.frame;
        s.anchorAt(@as(f64, offset) - opts.padding.top, rows);
    }
    var revealed = false;
    if (s.reveal) |row| {
        s.reveal = null;
        if (row < opts.count) {
            const tops = s.tops.items;
            const h = tops[row + 1] - tops[row] - opts.gap;
            if (structure.reveal(@floatCast(tops[row]), @floatCast(h), @floatCast(s.place()), @floatCast(view)) != null) {
                s.anchor = row;
                s.into = if (row == 0) -opts.padding.top else 0;
                s.moved_at = c.frame;
                revealed = true;
            }
        }
    }
    // Moved by the reader, it no longer follows, which layout only finds
    // out after the rows are built; at the end it follows again.
    const held = c.scroll_seen.get(id);
    const still = held == null or held.? == offset;
    const following = opts.follow_end and !revealed and (c.scroll_follow.get(id) orelse true) and still;
    if (following) s.anchorAt(s.endPlace(opts.count, view, opts.padding), rows);

    const i = c.open(.{
        .direction = .column,
        .width = opts.width,
        .height = opts.height,
        .padding = opts.padding,
        .scroll = true,
        .follow_end = opts.follow_end,
    }, null);
    std.debug.assert(c.node(i).id == id);
    c.node(i).style.gap = opts.gap;
    const start = @min(s.anchor -| opts.overscan, opts.count);
    if (start > 0) _ = c.leaf(.{ .height = .{ .px = @floatCast(s.tops.items[start] - opts.gap) } }, .none, "list-before");
    return .{ .c = c, .s = s, .opts = opts, .id = id, .index = start, .first = start, .view = view, .past = opts.overscan, .following = following };
}
