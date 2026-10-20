//! Flexbox layout in two passes: `measure` sizes boxes from their content,
//! bottom up; `arrange` places them, top down, sharing the free room among
//! the boxes that grow as CSS does (`layout_flex.zig`). A box is never
//! smaller than its padding. Within a frame's layout, a box measured again
//! at the width it was measured at is as it was, so deep trees are not
//! measured once per level around them; across frames, what did not
//! change is measured from what the last frame kept (`layout_cache.zig`).
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const none = ctx_mod.none;
const rich = @import("text.zig").rich;
const direction = @import("direction.zig");
const grid = @import("grid.zig");
const grid_layout = @import("grid_layout.zig");
const flex = @import("layout_flex.zig");
const baseline = @import("layout_baseline.zig");
const cache = @import("layout_cache.zig");

fn main(d: types.Direction, s: types.Size) f32 {
    return if (d == .row) s.w else s.h;
}

fn cross(d: types.Direction, s: types.Size) f32 {
    return if (d == .row) s.h else s.w;
}

inline fn mainLen(d: types.Direction, st: *const types.Style) types.Length {
    return if (d == .row) st.width else st.height;
}

/// Sizes box `index` and its children, given `avail_w` points of width.
pub fn measure(c: *Context, index: u32, avail_w: f32) types.Size {
    const n = c.node(index);
    if (c.layout_pass != 0 and n.pass == c.layout_pass and n.measured_at == avail_w and !c.layout_cache.off) return n.measured;
    const size = compute(c, index, avail_w);
    const m = c.node(index);
    m.measured_at = avail_w;
    m.pass = c.layout_pass;
    return size;
}

inline fn compute(c: *Context, index: u32, avail_w: f32) types.Size {
    const n = c.node(index);
    const st = &n.style;
    var box_w = switch (st.width) {
        .px => |v| v,
        else => avail_w,
    };
    box_w = @min(box_w, st.max_width);
    const inner_w = @max(0, box_w - st.padding.horizontal());

    var content: types.Size = .{};
    var flexible = false;
    switch (n.content) {
        .text => |*t| {
            const lh = c.text.lineHeight(t.style);
            if (t.style.wrap) {
                flexible = true;
                t.lines = cache.wrap(c, index, t, inner_w);
                for (t.lines) |l| content.w = @max(content.w, l.width);
                content.h = lh * @as(f32, @floatFromInt(t.lines.len));
            } else {
                content.w = cache.width(c, index, t) orelse w: {
                    const w = if (rich.styled(t.spans)) rich.layout(c.text, t.str, t.style, t.spans, 0).width else c.text.width(t.str, t.style);
                    break :w @ceil(w);
                };
                content.h = lh;
            }
        },
        .icon => |ic| {
            if (c.text.atlas.symbol(ic.name, ic.size, @intFromEnum(ic.weight))) |sp| {
                content = .{ .w = sp.w + 2 * sp.x, .h = sp.h + 2 * sp.y };
            } else content = .{ .w = ic.size, .h = ic.size };
        },
        // Sized by its style (the widget gives the size).
        .image => {},
        .none => if (grid.lookup(c, index)) |spec| {
            content = grid_layout.measure(c, index, spec, inner_w);
            var child = n.first_child;
            while (child != none) : (child = c.node(child).next) flexible = flexible or c.node(child).flexible;
        } else {
            var child = n.first_child;
            var count: f32 = 0;
            // A row lining its children up by their baselines is as high
            // as the highest above its line and the deepest below.
            const lines = baseline.lines(st.*);
            var ascent: f32 = 0;
            var descent: f32 = 0;
            while (child != none) : (child = c.node(child).next) {
                const s = measure(c, child, inner_w);
                if (c.node(child).style.absolute) continue;
                flexible = flexible or c.node(child).flexible;
                const dir = st.direction;
                const m = main(dir, s);
                const x = cross(dir, s);
                if (dir == .row) {
                    content.w += m;
                    content.h = @max(content.h, x);
                    if (lines) {
                        const b = baseline.of(c, child, st.baselines) orelse s.h;
                        ascent = @max(ascent, b);
                        descent = @max(descent, s.h - b);
                    }
                } else {
                    content.h += m;
                    content.w = @max(content.w, x);
                }
                count += 1;
            }
            if (lines) content.h = @max(content.h, ascent + descent);
            if (count > 1) {
                if (st.direction == .row) content.w += st.gap * (count - 1) else content.h += st.gap * (count - 1);
            }
        },
    }

    // A scrolling box takes the room it is given, not its content's height
    // (CSS's `min-height: 0`), or a scrolling row its content's width: its
    // content scrolls instead.
    if (st.scroll and st.direction == .row) {
        content.w = 0;
    } else if (st.scroll and st.max_height == std.math.inf(f32)) content.h = 0;
    var size: types.Size = .{
        .w = content.w + st.padding.horizontal(),
        .h = content.h + st.padding.vertical(),
    };
    if (st.width == .px) size.w = st.width.px;
    if (st.height == .px) size.h = st.height.px;
    // No smaller than its padding, whatever its size says (CSS).
    size.w = @max(size.w, st.padding.horizontal());
    size.h = @max(size.h, st.padding.vertical());
    const m = c.node(index);
    m.base = size;
    size.w = @max(st.padding.horizontal(), std.math.clamp(size.w, st.min_width, @max(st.min_width, st.max_width)));
    size.h = @max(st.padding.vertical(), std.math.clamp(size.h, st.min_height, @max(st.min_height, st.max_height)));
    m.measured = size;
    m.flexible = flexible and st.width != .px;
    return size;
}

/// Places box `index` in `rect` and its children inside it; the root's
/// tree is then mirrored where it reads right to left (`direction.zig`).
pub fn arrange(c: *Context, index: u32, rect_in: types.Rect) void {
    arrangeBox(c, index, rect_in);
    if (index == 0) direction.mirror(c);
}

/// `arrange` without mirroring, for layouts of their own (grids).
pub fn arrangeBox(c: *Context, index: u32, rect_in: types.Rect) void {
    const n = c.node(index);
    const st = &n.style;
    var rect = rect_in;
    rect.x += st.offset.x;
    rect.y += st.offset.y;
    n.rect = rect;
    if (n.first_child == none) {
        // An empty scrolling box scrolls nowhere: its offset goes to 0,
        // and the wheel passes it by.
        if (st.scroll) _ = scrollOffset(c, n.id, st.*, 0, 0);
        return;
    }
    if (n.content == .none) if (grid.lookup(c, index)) |spec|
        return grid_layout.arrange(c, index, spec, rect.inset(st.padding), st.height != .auto);

    const dir = st.direction;
    const inner = rect.inset(st.padding);
    const inner_main = if (dir == .row) inner.w else inner.h;
    const inner_cross = if (dir == .row) inner.h else inner.w;

    // Each child's flex base size: in a column, its height at the width it
    // gets across (wrapped text needs more or fewer lines). Most lines
    // neither grow nor shrink: their children take their hypothetical
    // sizes, and nothing is kept for them.
    var count: usize = 0;
    var sum_hyp: f32 = 0;
    var flexes = false;
    var shrinks = false;
    // Growing items no minimum or maximum stops share the room at once.
    var simple = true;
    var grow_sum: f32 = 0;
    var child = n.first_child;
    while (child != none) : (child = c.node(child).next) {
        const ch = c.node(child);
        if (ch.style.absolute) continue;
        if (dir == .column and ch.flexible and ch.style.width != .px) {
            const x = crossSize(st, &ch.style, ch.measured.w, inner_cross);
            if (@abs(x - ch.measured.w) > 0.5) _ = measure(c, child, x);
        }
        const m = c.node(child);
        const grow = growOf(dir, &m.style);
        sum_hyp += hypOf(c, dir, child);
        if (grow > 0) {
            flexes = true;
            grow_sum += grow;
            const max = if (dir == .row) m.style.max_width else m.style.max_height;
            simple = simple and mainLen(dir, &m.style) != .fill and main(dir, m.base) == main(dir, m.measured) and max == std.math.inf(f32);
        }
        shrinks = shrinks or (dir == .row and m.flexible);
        count += 1;
    }
    const gaps = st.gap * @as(f32, @floatFromInt(count -| 1));
    const space = inner_main - gaps;
    var items: []flex.Item = &.{};
    var per: f32 = 0;
    if (flexes and sum_hyp < space and simple and grow_sum >= 1) {
        per = (space - sum_hyp) / grow_sum;
        sum_hyp = space;
    } else if ((flexes and sum_hyp < space) or (shrinks and sum_hyp > space)) {
        // Growing items a minimum or maximum stops, or shrinking ones:
        // resolved as CSS does, in frame memory.
        items = c.alloc().alloc(flex.Item, count) catch &.{};
        var k: usize = 0;
        child = n.first_child;
        while (child != none and k < items.len) : (child = c.node(child).next) {
            if (c.node(child).style.absolute) continue;
            items[k] = itemOf(c, dir, child);
            k += 1;
        }
        flex.resolve(items, space);
        sum_hyp = 0;
        for (items) |it| sum_hyp += it.main;
    }
    const used = sum_hyp + gaps;
    const free = inner_main - used;

    var pos: f32 = 0;
    var spacing = st.gap;
    if (free > 0) switch (st.justify) {
        .start => {},
        .center => pos = free / 2,
        .end => pos = free,
        .space_between => if (count > 1) {
            spacing += free / @as(f32, @floatFromInt(count - 1));
        },
    };
    var scroll_y: f32 = if (st.scroll) scrollOffset(c, n.id, st.*, used, inner_main) else 0;
    if (st.scroll and st.follow_end and dir == .column) if (st.follow_glide) |a| {
        scroll_y -= glideLag(c, n, a, items, per, spacing, used, inner_main, inner.w);
    };

    // A row lining up its children's baselines: where its line is, once
    // they have their widths (wrapped text measured again at its width).
    const lines = baseline.lines(st.*);
    var line: f32 = 0;
    if (lines) {
        var k: usize = 0;
        child = n.first_child;
        while (child != none) : (child = c.node(child).next) {
            const ch = c.node(child);
            if (ch.style.absolute) continue;
            const m = mainAt(c, dir, child, items, k, per);
            if (ch.flexible and @abs(m - ch.measured.w) > 0.5 and ch.style.width != .px) _ = measure(c, child, m);
            line = @max(line, baseline.of(c, child, st.baselines) orelse c.node(child).measured.h);
            k += 1;
        }
    }

    var k: usize = 0;
    child = n.first_child;
    while (child != none) : (child = c.node(child).next) {
        const ch = c.node(child);
        if (ch.style.absolute) {
            const w = if (ch.style.width == .fill) inner.w else ch.measured.w;
            const h = if (ch.style.height == .fill) inner.h else ch.measured.h;
            arrangeBox(c, child, if (dir == .row)
                .{ .x = inner.x - scroll_y, .y = inner.y, .w = w, .h = h }
            else
                .{ .x = inner.x, .y = inner.y - scroll_y, .w = w, .h = h });
            continue;
        }
        const m = mainAt(c, dir, child, items, k, per);
        k += 1;
        var x: f32 = undefined;
        if (dir == .row) {
            // Given its width, a row's child takes its height.
            if (!lines and ch.flexible and @abs(m - ch.measured.w) > 0.5 and ch.style.width != .px) _ = measure(c, child, m);
            x = crossSize(st, &ch.style, c.node(child).measured.h, inner_cross);
        } else x = crossSize(st, &ch.style, ch.measured.w, inner_cross);
        const cpos: f32 = if (lines)
            line - (baseline.of(c, child, st.baselines) orelse c.node(child).measured.h)
        else switch (st.align_items) {
            .start, .stretch, .baseline => 0,
            .center => (inner_cross - x) / 2,
            .end => inner_cross - x,
        };
        // A scrolling row scrolls sideways (a strip of tabs).
        const r: types.Rect = if (dir == .row)
            .{ .x = inner.x + pos - scroll_y, .y = inner.y + cpos, .w = m, .h = x }
        else
            .{ .x = inner.x + cpos, .y = inner.y + pos - scroll_y, .w = x, .h = m };
        arrangeBox(c, child, r);
        pos += m + spacing;
    }
}

/// The main size of child `index`, the `k`th of its line: resolved, or
/// its hypothetical size and `per` point of what it grows by.
inline fn mainAt(c: *Context, dir: types.Direction, index: u32, items: []const flex.Item, k: usize, per: f32) f32 {
    if (items.len > 0) return items[k].main;
    const h = hypOf(c, dir, index);
    return if (per == 0) h else h + per * growOf(dir, &c.node(index).style);
}

/// Child `index`'s hypothetical main size: as measured (its base within
/// its minimum and maximum, no smaller than its padding), or for one
/// that fills, its padding so.
inline fn hypOf(c: *Context, dir: types.Direction, index: u32) f32 {
    const ch = c.node(index);
    if (mainLen(dir, &ch.style) == .fill) return itemOf(c, dir, index).hyp;
    return main(dir, ch.measured);
}

/// Child `index`'s flex item along `dir`, before its line is resolved.
fn itemOf(c: *Context, dir: types.Direction, index: u32) flex.Item {
    const ch = c.node(index);
    const cs = &ch.style;
    const row = dir == .row;
    const pad = if (row) cs.padding.horizontal() else cs.padding.vertical();
    return (flex.Item{
        .base = if (mainLen(dir, cs) == .fill) pad else if (row) ch.base.w else ch.base.h,
        .min = if (row) cs.min_width else cs.min_height,
        .max = if (row) cs.max_width else cs.max_height,
        .pad = pad,
        .grow = growOf(dir, cs),
        // Only boxes of wrapping text give room back in a row.
        .shrink = if (row and ch.flexible) 1 else 0,
    }).init();
}

/// The size of a child across its parent: stretched (or filling), else
/// as measured, within its minimum and maximum and no smaller than its
/// padding.
inline fn crossSize(parent: *const types.Style, cs: *const types.Style, measured: f32, inner_cross: f32) f32 {
    const row = parent.direction == .row;
    const clen = if (row) cs.height else cs.width;
    const stretch = clen == .fill or (parent.align_items == .stretch and clen == .auto);
    const x = if (stretch) inner_cross else measured;
    const lo = if (row) cs.min_height else cs.min_width;
    const hi = if (row) cs.max_height else cs.max_width;
    const pad = if (row) cs.padding.vertical() else cs.padding.horizontal();
    return @max(pad, std.math.clamp(x, lo, @max(lo, hi)));
}

/// How far below their place the children of `n`, a scrolling column
/// following its end with a glide, show (`follow_glide.zig`): from where
/// each child is in its content.
fn glideLag(c: *Context, n: *const ctx_mod.Node, g: *const @import("follow_glide.zig").FollowGlide, items: []const flex.Item, per: f32, spacing: f32, content: f32, height: f32, width: f32) f32 {
    var tops: @import("follow_glide.zig").Tops = .{ .want = g.wanted(c, n.id) };
    var at: f32 = 0;
    var k: usize = 0;
    var child = n.first_child;
    while (child != none) : (child = c.node(child).next) {
        const ch = c.node(child);
        if (ch.style.absolute) continue;
        tops.see(ch.id, at);
        at += mainAt(c, .column, child, items, k, per) + spacing;
        k += 1;
    }
    return g.lag(c, n.id, g.animation, n.style.justify, content, height, width, tops);
}

/// The offset of scrolling box `id`, whose content is `content_h` tall
/// in `view_h`: kept within it, and following its end while the reader
/// left it there.
fn scrollOffset(c: *Context, id: u64, st: types.Style, content_h: f32, view_h: f32) f32 {
    const max_scroll = @max(0, content_h - view_h);
    c.scroll_limit.put(c.gpa, id, max_scroll) catch {};
    if (st.follow_end) {
        // It follows its end while the reader left it there: the
        // decision is made when the offset is moved (a wheel, a jump),
        // never because shrinking content pulled the offset to the end.
        const prev_max = c.scroll_max.get(id) orelse 0;
        const gop = c.scroll.getOrPut(c.gpa, id) catch null;
        if (gop) |g| {
            var follow = c.scroll_follow.get(id) orelse true;
            if (!g.found_existing) {
                follow = true;
            } else if (c.scroll_seen.get(id)) |seen| {
                if (g.value_ptr.* != seen) {
                    follow = g.value_ptr.* >= prev_max - 1;
                    c.scroll_moved.put(c.gpa, id, {}) catch {};
                }
            }
            if (follow) {
                const want = if (c.scroll_cap.get(id)) |cap| @min(max_scroll, cap) else max_scroll;
                // Moved by following: what reads the last layout (a
                // pinned header, a pill) needs one more frame.
                if (g.value_ptr.* != want) c.animating = true;
                g.value_ptr.* = want;
            }
            c.scroll_follow.put(c.gpa, id, follow) catch {};
        }
        c.scroll_max.put(c.gpa, id, max_scroll) catch {};
    }
    const s = c.scroll.getPtr(id) orelse return 0;
    s.* = @min(s.*, max_scroll);
    if (st.follow_end) c.scroll_seen.put(c.gpa, id, s.*) catch {};
    return s.*;
}

inline fn growOf(dir: types.Direction, st: *const types.Style) f32 {
    if (st.grow > 0) return st.grow;
    return if (mainLen(dir, st) == .fill) 1 else 0;
}

test "row with a growing child" {
    var ts: @import("text.zig").TextSystem = undefined;
    var c = Context.init(std.testing.allocator, &ts);
    defer c.deinit();
    c.size = .{ .w = 300, .h = 100 };
    c.begin();
    _ = c.open(.{ .direction = .row, .width = .fill, .height = .fill, .gap = 10, .padding = .all(10) }, null);
    const a = c.leaf(.{ .width = .{ .px = 50 }, .height = .{ .px = 20 } }, .none, null);
    const b = c.leaf(.{ .grow = 1, .height = .{ .px = 20 } }, .none, null);
    const d = c.leaf(.{ .width = .{ .px = 30 }, .height = .{ .px = 20 } }, .none, null);
    c.end();
    _ = measure(&c, 0, 300);
    arrange(&c, 0, .{ .w = 300, .h = 100 });
    try std.testing.expectEqual(@as(f32, 10), c.node(a).rect.x);
    try std.testing.expectEqual(@as(f32, 70), c.node(b).rect.x);
    try std.testing.expectEqual(@as(f32, 180), c.node(b).rect.w);
    try std.testing.expectEqual(@as(f32, 260), c.node(d).rect.x);
}

test "centered column" {
    var ts: @import("text.zig").TextSystem = undefined;
    var c = Context.init(std.testing.allocator, &ts);
    defer c.deinit();
    c.size = .{ .w = 200, .h = 200 };
    c.begin();
    _ = c.open(.{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .gap = 10 }, null);
    const a = c.leaf(.{ .width = .{ .px = 40 }, .height = .{ .px = 40 } }, .none, null);
    const b = c.leaf(.{ .width = .{ .px = 80 }, .height = .{ .px = 40 } }, .none, null);
    c.end();
    _ = measure(&c, 0, 200);
    arrange(&c, 0, .{ .w = 200, .h = 200 });
    try std.testing.expectEqual(@as(f32, 80), c.node(a).rect.x);
    try std.testing.expectEqual(@as(f32, 55), c.node(a).rect.y);
    try std.testing.expectEqual(@as(f32, 60), c.node(b).rect.x);
    try std.testing.expectEqual(@as(f32, 105), c.node(b).rect.y);
}
