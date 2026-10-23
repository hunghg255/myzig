//! What overlays share: their state kept by the app (`OverlayState`),
//! placing a panel beside an anchor inside the window (`attach`), keys
//! taken by the overlay on top, presses inside or outside what an overlay
//! built, and small values kept across frames.
//!
//! Overlays are built over everything else with `Context.openOverlay`;
//! a panel measures itself as it ends, so it is placed (flipped to the
//! other side of its anchor, moved into the window) in the frame it opens.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const layout = @import("layout.zig");
const Context = ctx_mod.Context;
const Key = ctx_mod.Key;
const S = ctx_mod.Shortcut;
const Rect = types.Rect;
const Size = types.Size;
const Point = types.Point;

/// Room kept between a panel and the window's edges.
pub const window_margin: f32 = 4;

/// Whether an overlay shows, kept by the app: a popover, a dialog, an
/// alert. Set `open` (or `show`) to open it; the widget closes it.
pub const OverlayState = struct {
    open: bool = false,
    /// Set in the frame Escape or a press outside closed it: one that must
    /// stay open sets `open` back to true then.
    dismissed: bool = false,

    // Kept by the widget.
    shown: bool = false,
    /// The focus as it opened, given back as it closes.
    return_focus: u64 = 0,
    focus_inside: bool = false,
    /// The frame it opened in, to fade in from.
    opened_frame: u64 = 0,
    dismissed_frame: u64 = 0,
    /// The boxes it built in the last frame: [lo, hi) in the node list.
    lo: u32 = 0,
    hi: u32 = 0,

    pub fn show(s: *OverlayState) void {
        s.open = true;
    }

    pub fn close(s: *OverlayState) void {
        s.open = false;
    }

    pub fn toggle(s: *OverlayState) void {
        s.open = !s.open;
    }

    /// Called as the widget builds: notes the frame it opens and gives
    /// the focus back as it closes. Returns whether it shows.
    pub fn sync(s: *OverlayState, c: *Context) bool {
        if (s.dismissed and s.dismissed_frame != c.frame) s.dismissed = false;
        if (s.open and !s.shown) {
            s.shown = true;
            s.return_focus = c.focus;
            s.opened_frame = c.frame;
            s.focus_inside = false;
            s.lo = 0;
            s.hi = 0;
        } else if (!s.open and s.shown) {
            s.shown = false;
            if (c.focus == 0 or s.focus_inside) c.focus = s.return_focus;
            s.focus_inside = false;
        }
        return s.open;
    }

    /// Whether it opened in this frame.
    pub fn justOpened(s: *const OverlayState, c: *Context) bool {
        return s.opened_frame == c.frame;
    }

    /// Closes it as the user did (Escape, a press outside).
    pub fn dismiss(s: *OverlayState, c: *Context) void {
        s.open = false;
        s.dismissed = true;
        s.dismissed_frame = c.frame;
        c.changed = true;
        _ = s.sync(c);
    }

    /// Records the boxes built since `lo`, as the overlay ends.
    pub fn record(s: *OverlayState, c: *Context, lo: u32) void {
        s.lo = lo;
        s.hi = @intCast(c.nodes.items.len);
        s.focus_inside = focusIn(c, lo, s.hi);
    }

    /// Whether this frame's press (left or right) lands outside what the
    /// overlay built last frame, and outside `except` (its anchor).
    pub fn pressedOutside(s: *const OverlayState, c: *Context, except: u64) bool {
        if (!c.input.pressed and !rightPressed(c)) return false;
        if (except != 0 and hotIn(c, except)) return false;
        const at = hotIndex(c) orelse return true;
        return at < s.lo or at >= s.hi;
    }
};

/// Opens an overlay (`Context.openOverlay`) whose id comes from `seed`
/// (the anchor's id, the state's address), so that the boxes after it
/// where it is opened keep theirs as it comes and goes: a tip showing must
/// not change the id of the button beside it.
pub fn overlay(c: *Context, style: types.Style, seed: u64) u32 {
    const saved_key = c.next_key;
    const saved_int = c.next_key_int;
    c.next_key = null;
    c.next_key_int = seed ^ 0x6f7665726c6179;
    const index = c.openOverlay(style, null);
    c.next_key = saved_key;
    c.next_key_int = saved_int;
    return index;
}

/// A seed for `overlay` from the state a widget keeps.
pub fn seedOf(p: anytype) u64 {
    return @intFromPtr(p);
}

/// Whether the focused box is one of the nodes [lo, hi).
pub fn focusIn(c: *Context, lo: u32, hi: u32) bool {
    if (c.focus == 0) return false;
    for (c.nodes.items[lo..@min(hi, c.nodes.items.len)]) |n| if (n.id == c.focus) return true;
    return false;
}

/// Whether the pointer is over the box `id` or a box inside it.
pub fn hotIn(c: *Context, id: u64) bool {
    return c.hot == id or std.mem.indexOfScalar(u64, c.hot_path.items, id) != null;
}

/// The node index (in the last frame's tree) of the box under the pointer.
pub fn hotIndex(c: *Context) ?u32 {
    if (c.hot == 0) return null;
    var i = c.hits.items.len;
    while (i > 0) {
        i -= 1;
        if (c.hits.items[i].id == c.hot) return c.hits.items[i].index;
    }
    return null;
}

/// Whether the secondary (right) button went down in this event. Input
/// does not carry it yet: once `Input` has `right_pressed`, it is read.
pub fn rightPressed(c: *Context) bool {
    if (comptime @hasField(ctx_mod.Input, "right_pressed")) return c.input.right_pressed;
    return false;
}

/// Takes the key `k` from this event, offered as a key combination (with
/// no modifiers) or as a key; true if it was there. What takes it first,
/// as the overlay on top, leaves nothing for what is built after it.
pub fn takeKey(c: *Context, k: Key) bool {
    const sc: ?u21 = switch (k) {
        .up => S.up,
        .down => S.down,
        .left => S.left,
        .right => S.right,
        .escape => S.escape,
        .tab => S.tab,
        .enter => S.enter,
        .home => S.home,
        .end => S.end,
        else => null,
    };
    if (sc) |v| if (c.input.shortcut) |s| if (s.key == v and !s.cmd and !s.ctrl and !s.alt) {
        c.shortcut_taken = true;
        c.changed = true;
        c.input.shortcut = null;
        return true;
    };
    if (c.input.key == k) {
        c.input.key = null;
        c.changed = true;
        return true;
    }
    // A focused text field's input system sends Escape and Return as commands.
    const cmd: ?ctx_mod.Command = switch (k) {
        .escape => .cancel,
        .enter => .insert_newline,
        .up => .move_up,
        .down => .move_down,
        .home => .move_doc_start,
        .end => .move_doc_end,
        else => null,
    };
    if (cmd) |want| for (c.input.ops, 0..) |op, i| if (op == .command and op.command == want) {
        const rest = c.alloc().alloc(ctx_mod.TextOp, c.input.ops.len - 1) catch return true;
        @memcpy(rest[0..i], c.input.ops[0..i]);
        @memcpy(rest[i..], c.input.ops[i + 1 ..]);
        c.input.ops = rest;
        c.changed = true;
        return true;
    };
    return false;
}

/// Takes a typed space (which chooses in selects and menus).
pub fn takeSpace(c: *Context) bool {
    if (!std.mem.eql(u8, c.input.chars, " ")) return false;
    c.input.chars = "";
    c.changed = true;
    return true;
}

pub const Side = enum { below, above, right, left };
pub const Align = enum { start, center };

/// Where a panel of `size` goes beside `anchor`, `gap` apart, inside a
/// window of `win`: on `side` of it, or the other side where there is no
/// room; along it lined up at the start (or the end, where the start
/// would leave the window) or centered; then moved into the window.
pub fn attach(anchor: Rect, size: Size, win: Size, side: Side, al: Align, gap: f32) Point {
    const m = window_margin;
    var p: Point = .{};
    switch (side) {
        .below, .above => {
            const below_y = anchor.y + anchor.h + gap;
            const above_y = anchor.y - gap - size.h;
            const fits_below = below_y + size.h <= win.h - m;
            const fits_above = above_y >= m;
            p.y = if (side == .below)
                (if (fits_below or !fits_above) below_y else above_y)
            else
                (if (fits_above or !fits_below) above_y else below_y);
            p.x = switch (al) {
                .center => anchor.x + (anchor.w - size.w) / 2,
                .start => if (anchor.x + size.w > win.w - m and anchor.x + anchor.w - size.w >= m) anchor.x + anchor.w - size.w else anchor.x,
            };
        },
        .right, .left => {
            const right_x = anchor.x + anchor.w + gap;
            const left_x = anchor.x - gap - size.w;
            const fits_right = right_x + size.w <= win.w - m;
            const fits_left = left_x >= m;
            p.x = if (side == .right)
                (if (fits_right or !fits_left) right_x else left_x)
            else
                (if (fits_left or !fits_right) left_x else right_x);
            p.y = switch (al) {
                .center => anchor.y + (anchor.h - size.h) / 2,
                .start => if (anchor.y + size.h > win.h - m and anchor.y + anchor.h - size.h >= m) anchor.y + anchor.h - size.h else anchor.y,
            };
        },
    }
    p.x = std.math.clamp(p.x, m, @max(m, win.w - m - size.w));
    p.y = std.math.clamp(p.y, m, @max(m, win.h - m - size.h));
    return p;
}

/// The most a panel beside `anchor` can be tall and stay in the window.
pub fn roomAlong(anchor: Rect, win: Size, side: Side, gap: f32) f32 {
    const m = window_margin;
    const room = switch (side) {
        .below, .above => @max(anchor.y, win.h - (anchor.y + anchor.h)) - gap - m,
        .right, .left => win.h - 2 * m,
    };
    return @max(room, 0);
}

/// Measures the overlay box `index` (all its children built) and moves it
/// beside `anchor`: what a panel does as it ends.
pub fn place(c: *Context, index: u32, anchor: Rect, side: Side, al: Align, gap: f32) Rect {
    // One that scrolls, as a select's long list of options, is no taller
    // than the room on the anchor's larger side (beside it vertically, or
    // the window), where its options scroll.
    const st = &c.node(index).style;
    if (st.scroll) st.max_height = @min(st.max_height, roomAlong(anchor, c.size, side, gap));
    const size = layout.measure(c, index, c.size.w);
    const at = attach(anchor, size, c.size, side, al, gap);
    c.node(index).style.offset = at;
    return .{ .x = at.x, .y = at.y, .w = size.w, .h = size.h };
}

fn slotKey(id: u64, salt: u32) u64 {
    var h = std.hash.Wyhash.init(id);
    h.update("overlay");
    h.update(std.mem.asBytes(&salt));
    return h.final();
}

/// A number kept across frames for the box `id` (a time, an index),
/// `default` the first time; forgotten once its box is gone a while.
/// Use the pointer at once: the next `memo` or `animate` may move it.
pub fn memo(c: *Context, id: u64, salt: u32, default: f32) *f32 {
    const gop = c.anims.getOrPut(c.gpa, slotKey(id, salt)) catch @panic("OOM");
    if (!gop.found_existing) gop.value_ptr.* = .{ .value = default, .frame = c.frame };
    gop.value_ptr.frame = c.frame;
    return &gop.value_ptr.value;
}

/// Fades a panel in from its first frame (`opened`): its opacity now.
pub fn fadeIn(c: *Context, id: u64, opened: bool) f32 {
    const salt: u32 = 0x6f76;
    if (opened) restart(c, id, salt, 0);
    return c.animate(id, salt, 1, 30);
}

/// Starts `id`'s animated value (`Context.animate`) anew from `from`,
/// whatever it was the last time the box showed.
pub fn restart(c: *Context, id: u64, salt: u32, from: f32) void {
    var h = std.hash.Wyhash.init(id);
    h.update(std.mem.asBytes(&salt));
    _ = c.anims.remove(h.final());
    _ = c.animate(id, salt, from, 1);
}

test "attach: below, flipped above, kept inside the window" {
    const win: Size = .{ .w = 400, .h = 300 };
    const a: Rect = .{ .x = 20, .y = 20, .w = 80, .h = 30 };
    const p = attach(a, .{ .w = 120, .h = 100 }, win, .below, .start, 4);
    try std.testing.expectEqual(@as(f32, 20), p.x);
    try std.testing.expectEqual(@as(f32, 54), p.y);
    // No room below: above.
    const low: Rect = .{ .x = 20, .y = 250, .w = 80, .h = 30 };
    const q = attach(low, .{ .w = 120, .h = 100 }, win, .below, .start, 4);
    try std.testing.expectEqual(@as(f32, 146), q.y);
    // At the right edge: the panel's end lines up with the anchor's.
    const right: Rect = .{ .x = 340, .y = 20, .w = 50, .h = 30 };
    const r = attach(right, .{ .w = 120, .h = 100 }, win, .below, .start, 4);
    try std.testing.expectEqual(@as(f32, 270), r.x);
    // Centered, moved inside the window.
    const t = attach(.{ .x = 0, .y = 100, .w = 20, .h = 20 }, .{ .w = 100, .h = 20 }, win, .above, .center, 6);
    try std.testing.expectEqual(window_margin, t.x);
    try std.testing.expectEqual(@as(f32, 74), t.y);
    // To the right, flipped left at the window's edge.
    const s = attach(.{ .x = 300, .y = 40, .w = 80, .h = 20 }, .{ .w = 100, .h = 50 }, win, .right, .start, 0);
    try std.testing.expectEqual(@as(f32, 200), s.x);
    // Larger than the window: at its margin.
    const big = attach(a, .{ .w = 900, .h = 900 }, win, .below, .start, 0);
    try std.testing.expectEqual(window_margin, big.x);
    try std.testing.expectEqual(window_margin, big.y);
}
