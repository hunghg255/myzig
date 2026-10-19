//! Split views: two panes side by side (or one above the other) with a
//! divider between them, which the pointer drags to resize them (showing a
//! resize cursor) or the arrows move once it has the keyboard focus.
//!
//!     var sp = ui.split(c, &s.sidebar_width, .{});
//!     files(s, c);
//!     sp.second();
//!     editor(s, c);
//!     if (sp.end().changed) save(s);
//!
//! `size.*` is the first pane's width (its height with `vertical`), or with
//! `percent` its share of the room, from 0 to 100, so both panes grow with
//! the window. The divider keeps `min` points from either edge; when the
//! window leaves less room, the first pane gives way and takes its size
//! back when there is room again: `size.*` keeps what the user chose.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const structure = @import("structure.zig");
const Context = ctx_mod.Context;

pub const Options = struct {
    vertical: bool = false,
    /// `size.*` is a percentage of the room rather than points.
    percent: bool = false,
    /// The least room either pane keeps.
    min: f32 = 40,
    width: types.Length = .fill,
    height: types.Length = .fill,
    /// How far the arrows move the divider.
    step: f32 = 10,
    /// How wide the divider is to the pointer, across its line.
    grip: f32 = 8,
};

pub const Result = struct {
    /// A drag or a key moved the divider in this frame.
    changed: bool = false,
    dragging: bool = false,
    focused: bool = false,
};

pub const Split = struct {
    c: *Context,
    size: *f32,
    opts: Options,
    /// The first pane's size as this frame lays it out (from the last
    /// frame's room), which drags and keys move the divider from.
    shown: f32,
    /// The room to share, as the last frame laid it out (0 before).
    total: f32,
    origin: f32,
    in_second: bool = false,
    /// The divider's box in this build.
    divider: u32 = 0,
    /// In percent, the panes share the room by their percentages: the
    /// second's share.
    second_grow: ?f32 = null,

    /// Closes the first pane, adds the divider, and opens the second.
    pub fn second(sp: *Split) void {
        const c = sp.c;
        std.debug.assert(!sp.in_second);
        sp.in_second = true;
        c.end();
        sp.divider = c.leaf(sp.along(.{ .background = c.theme.border }, 1, 1), .none, "divider");
        var st = sp.along(.{ .clip = true, .direction = .column }, null, sp.opts.min);
        if (sp.second_grow) |g| st.grow = g;
        _ = c.open(st, "second");
    }

    /// Closes the second pane and the split, after taking the divider's
    /// drag and keys.
    pub fn end(sp: *Split) Result {
        const c = sp.c;
        if (!sp.in_second) sp.second();
        c.end();
        const o = sp.opts;
        var result: Result = .{};
        // The divider's handle, over both panes' edges, last: on top.
        var hs: types.Style = .{ .absolute = true };
        const at = sp.shown + 0.5 - o.grip / 2;
        if (o.vertical) {
            hs.width = .fill;
            hs.height = .{ .px = o.grip };
            hs.offset.y = at;
        } else {
            hs.height = .fill;
            hs.width = .{ .px = o.grip };
            hs.offset.x = at;
        }
        const handle = c.leaf(hs, .none, "handle");
        const it = c.interact(handle, .{ .focusable = true });
        c.describe(it.id, .{ .role = .splitter, .vertical = !o.vertical });
        result.focused = it.focused;
        const mouse = if (o.vertical) c.input.mouse.y else c.input.mouse.x;
        // Where in the handle it was grabbed: the divider keeps it there.
        const grab = structure.slot(c, it.id, 0, 0);
        if (it.pressed and c.input.pressed) grab.* = mouse - (sp.origin + sp.shown);
        if (it.pressed) {
            result.dragging = true;
            const want = mouse - sp.origin - grab.*;
            if (@abs(want - sp.shown) >= 0.5) result.changed = sp.set(want);
        }
        if (it.focused) if (c.input.key) |k| {
            const back: ctx_mod.Key = if (o.vertical) .up else .left;
            const forth: ctx_mod.Key = if (o.vertical) .down else .right;
            if (k == back or k == forth) {
                _ = structure.takeKey(c);
                result.changed = sp.set(sp.shown + if (k == back) -o.step else o.step) or result.changed;
                c.changed = true;
            }
        };
        if (it.hovered or it.pressed) c.cursor = if (o.vertical) .resize_up_down else .resize_left_right;
        // The line lights up while the handle is hovered, held or focused.
        const lit = c.animate(it.id, 0, if (it.hovered or it.pressed or it.focused) 1 else 0, 20);
        c.end();
        if (lit > 0.01) c.node(sp.divider).style.background = c.theme.border.mix(c.theme.accent, lit);
        return result;
    }

    /// Sets the first pane's size from `v` points, kept `min` from either
    /// edge; true when `size.*` changed.
    fn set(sp: *Split, v_in: f32) bool {
        const v = fit(v_in, sp.total, sp.opts.min);
        var nv = v;
        if (sp.opts.percent) {
            if (sp.total <= 1) return false;
            nv = v * 100 / (sp.total - 1);
        }
        if (nv == sp.size.*) return false;
        sp.size.* = nv;
        sp.c.changed = true;
        return true;
    }

    /// A pane's (or the divider's) style along the split's axis: `len`
    /// points, or the room left; at least `min`.
    fn along(sp: *const Split, base: types.Style, len: ?f32, min: f32) types.Style {
        var s = base;
        const l: types.Length = if (len) |v| .{ .px = v } else .fill;
        if (sp.opts.vertical) {
            s.height = l;
            s.min_height = min;
        } else {
            s.width = l;
            s.min_width = min;
        }
        return s;
    }
};

/// Keeps `v`, the first pane's size, `min` from either edge of `total`
/// points of room (unknown before the first layout: 0).
pub fn fit(v: f32, total: f32, min: f32) f32 {
    var x = v;
    if (total > 0) x = @min(x, total - 1 - min);
    return @max(x, min);
}

/// Opens a split and its first pane: build it, then `second`, the second
/// pane, then `end`.
pub fn split(c: *Context, size: *f32, opts: Options) Split {
    const id = c.peekId(null);
    const box = c.open(.{
        .direction = if (opts.vertical) .column else .row,
        .width = opts.width,
        .height = opts.height,
        .align_items = .stretch,
    }, null);
    std.debug.assert(c.node(box).id == id);
    const last = c.rects.get(id);
    const total: f32 = if (last) |r| (if (opts.vertical) r.h else r.w) else 0;
    const origin: f32 = if (last) |r| (if (opts.vertical) r.y else r.x) else 0;
    var shown = size.*;
    if (opts.percent) {
        const share = std.math.clamp(size.*, 0, 100) / 100;
        shown = if (total > 0) fit(share * (total - 1), total, opts.min) else 0;
    } else shown = fit(size.*, total, opts.min);
    var sp: Split = .{ .c = c, .size = size, .opts = opts, .shown = @round(shown), .total = total, .origin = origin };
    if (opts.percent) {
        // Both panes grow by their shares: the layout sizes them with this
        // frame's room, as the window resizes.
        const share = std.math.clamp(size.*, 0, 100) / 100;
        var s = sp.along(.{ .clip = true, .direction = .column }, null, 0);
        s.grow = @max(share, 0.0001);
        _ = c.open(s, "first");
        sp.second_grow = @max(1 - share, 0.0001);
        return sp;
    }
    _ = c.open(sp.along(.{ .clip = true, .direction = .column }, sp.shown, @min(sp.shown, opts.min)), "first");
    return sp;
}
