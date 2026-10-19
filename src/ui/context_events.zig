//! What the surface does to the context between frames: the boxes just
//! painted become the ones the pointer is over, the wheel scrolls, the
//! button goes down and up, Tab moves the focus (`Context`'s methods).
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const Shortcut = ctx_mod.Shortcut;
const none = ctx_mod.none;
const Hit = @import("hit.zig").Hit;

/// Records an interactive box's visible rectangle, in paint order.
pub fn addHit(c: *Context, id: u64, index: u32, rect: types.Rect, scroll: bool) void {
    c.next_hits.append(c.gpa, .{ .id = id, .index = index, .rect = rect, .scroll = scroll }) catch {};
}

/// Swaps in the boxes of the frame just painted.
pub fn commitHits(c: *Context) void {
    std.mem.swap(std.ArrayList(Hit), &c.hits, &c.next_hits);
    c.updateHot();
}

/// The topmost interactive box under the pointer becomes hot.
pub fn updateHot(c: *Context) void {
    c.hot = 0;
    c.hot_path.clearRetainingCapacity();
    var i = c.hits.items.len;
    while (i > 0) {
        i -= 1;
        const h = c.hits.items[i];
        if (!h.scroll and h.contains(c.input.mouse)) {
            c.hot = h.id;
            hotPath(c, h);
            return;
        }
    }
}

/// The hot box's interactive ancestors, from the tree it was painted
/// in (between frames, still the last one).
fn hotPath(c: *Context, h: Hit) void {
    if (h.index >= c.nodes.items.len or c.nodes.items[h.index].id != h.id) return;
    var at = h.index;
    while (at != none) {
        const n = c.nodes.items[at];
        if (n.interactive) c.hot_path.append(c.gpa, n.id) catch return;
        at = n.parent;
    }
}

/// Scrolls the innermost scrolling box under the pointer.
pub fn applyScroll(c: *Context, dy: f32) bool {
    var i = c.hits.items.len;
    while (i > 0) {
        i -= 1;
        const h = c.hits.items[i];
        if (h.scroll and h.contains(c.input.mouse)) {
            const gop = c.scroll.getOrPut(c.gpa, h.id) catch return false;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* = @max(0, gop.value_ptr.* - dy);
            return true;
        }
    }
    return false;
}

pub fn pointerUp(c: *Context) void {
    c.input.down = false;
    c.input.released = true;
}

/// Moves the focus to the next box that takes it (the previous one,
/// `back`), around the end; true if there was one.
pub fn moveFocus(c: *Context, back: bool) bool {
    const order = c.focus_order.items;
    if (order.len == 0) return false;
    const at = std.mem.indexOfScalar(u64, order, c.focus);
    const next = if (at) |i|
        (if (back) (i + order.len - 1) % order.len else (i + 1) % order.len)
    else if (back) order.len - 1 else 0;
    c.focus = order[next];
    c.focus_visible = true;
    c.changed = true;
    return true;
}

/// Whether this event is Tab (with Shift: `back`) that nothing took.
pub fn tabPressed(c: *Context) ?bool {
    if (c.input.shortcut) |s| if (s.key == Shortcut.tab and !s.cmd and !s.ctrl and !s.alt) return s.shift;
    if (c.input.key == .tab) return c.input.shift;
    for (c.input.ops) |op| if (op == .command and op.command == .insert_tab) return c.input.shift;
    return null;
}

pub fn pointerDown(c: *Context) void {
    c.focus_visible = false;
    c.input.down = true;
    c.input.pressed = true;
    // A press outside every focusable box drops the focus.
    if (c.hot == 0) c.focus = 0;
}
