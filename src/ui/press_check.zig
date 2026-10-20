//! Debug builds: a press lost because the box pressed changed its id.
//!
//! A box's id comes from its place among its parent's children, so a box
//! that comes or goes before it (a mark shown on hover) gives it another
//! id from one frame to the next. A press on the old id then finds no box
//! to take it, and the click is lost without a word. This tells: no box
//! answers to the id pressed, the pointer is still where it was, and the
//! box now under the pointer was not there the frame before. Release
//! builds carry none of it.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const Context = @import("context.zig").Context;

pub const on = builtin.mode == .debug;

pub const State = if (on) struct {
    /// The box pressed (0: none) and where it was.
    id: u64 = 0,
    rect: types.Rect = .{},
    /// This frame's view answered it (`interact`).
    seen: bool = false,
    warned: bool = false,
    /// Presses lost so, for tests.
    lost: u32 = 0,
} else struct {};

/// A press: the box under the pointer is the one pressed (`begin`).
pub inline fn begin(c: *Context) void {
    if (!on) return;
    if (!c.input.pressed or c.hot == 0) return;
    const p = &c.press_check;
    p.id = 0;
    p.rect = c.rects.get(c.hot) orelse return;
    p.id = c.hot;
}

/// The view answered the box `id` (`interact`).
pub inline fn saw(c: *Context, id: u64) void {
    if (!on) return;
    if (id == c.press_check.id) c.press_check.seen = true;
}

/// After the frame's layout and hits (`finish`).
pub inline fn check(c: *Context) void {
    if (on) checkFrame(c);
}

fn checkFrame(c: *Context) void {
    const p = &c.press_check;
    defer {
        p.seen = false;
        if (!c.input.down) p.id = 0;
    }
    if (p.id == 0) return;
    // Not whether a box has the id: the box that came before takes the
    // place, and so the id, of the one pressed. Whether one answered it.
    if (p.seen) {
        if (c.rects.get(p.id)) |r| p.rect = r;
        return;
    }
    if (!p.rect.contains(c.input.mouse) or c.hot == 0) return;
    // After `commitHits`, `next_hits` holds the frame before's boxes: a
    // box that was there (under a closed popover) is not this one again.
    for (c.next_hits.items) |h| if (h.id == c.hot) return;
    p.lost += 1;
    p.id = 0;
    if (!p.warned) {
        p.warned = true;
        // Tests read `lost` and `warned`: their output stays quiet.
        if (!builtin.is_test) std.log.warn("myzig: the box pressed changed its id between frames (a box before it came or went?); key it with c.keyed() or keep the boxes before it", .{});
    }
}
