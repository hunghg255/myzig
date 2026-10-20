//! Debug builds: a scrolled box that changed its id.
//!
//! A scrolling box's offset is kept by its id (`c.scroll`), and its id
//! comes from its place among its parent's children. A box that comes or
//! goes before it (a sticky line shown now and then, a banner) gives it
//! another id, and its offset starts over at 0; one shown every other
//! frame makes the box jump between 0 and where the reader left it. This
//! tells: a box scrolled from 0 is gone from the layout, and a scrolling
//! box of another id, as wide, now covers its place. A change that input
//! made (a click, a key: a tab switched) is taken as meant; one that goes
//! back and forth is told whatever made it. Release builds carry none of it.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const Context = @import("context.zig").Context;

pub const on = builtin.mode == .debug;

const Box = struct { id: u64, rect: types.Rect, offset: f32 };
const Boxes = std.ArrayListUnmanaged(Box);

pub const State = if (on) struct {
    /// The scrolling boxes of this frame, the last and the one before.
    frames: [3]Boxes = .{ .empty, .empty, .empty },
    /// Input came this frame (a pass built again has it cleared).
    input: bool = false,
    warned: bool = false,
    warned_flapping: bool = false,
    /// Offsets lost so, and of those, ids going back and forth (tests).
    lost: u32 = 0,
    flapping: u32 = 0,
} else struct {};

pub fn deinit(c: *Context) void {
    if (!on) return;
    for (&c.scroll_check.frames) |*f| f.deinit(c.gpa);
}

/// Each build of a frame (`begin`): whether input came.
pub inline fn begin(c: *Context) void {
    if (!on) return;
    const in = &c.input;
    if (in.pressed or in.released or in.right_pressed or in.key != null or in.shortcut != null or in.chars.len > 0 or in.ops.len > 0)
        c.scroll_check.input = true;
}

/// After the frame's layout (`finish`).
pub inline fn check(c: *Context) void {
    if (on) checkFrame(c);
}

fn has(boxes: []const Box, id: u64) bool {
    for (boxes) |b| if (b.id == id) return true;
    return false;
}

/// One box in the place of the other: as wide, and over half of the
/// shorter's height.
fn samePlace(a: types.Rect, b: types.Rect) bool {
    if (@abs(a.w - b.w) > 1 or @abs(a.x - b.x) > 1) return false;
    const top = @max(a.y, b.y);
    const bottom = @min(a.y + a.h, b.y + b.h);
    return bottom - top > @min(a.h, b.h) / 2;
}

fn checkFrame(c: *Context) void {
    const s = &c.scroll_check;
    // The oldest list takes this frame's boxes.
    const oldest = s.frames[2];
    s.frames[2] = s.frames[1];
    s.frames[1] = s.frames[0];
    s.frames[0] = oldest;
    const now = &s.frames[0];
    now.clearRetainingCapacity();
    var it = c.scroll_limit.keyIterator();
    while (it.next()) |id| {
        const r = c.rects.get(id.*) orelse continue;
        now.append(c.gpa, .{ .id = id.*, .rect = r, .offset = c.scroll.get(id.*) orelse 0 }) catch return;
    }
    const last = s.frames[1].items;
    const before = s.frames[2].items;
    const input = s.input;
    s.input = false;
    for (now.items) |y| {
        if (has(last, y.id)) continue;
        for (last) |x| {
            if (x.offset == 0 or has(now.items, x.id) or !samePlace(x.rect, y.rect)) continue;
            // Back: this id was there the frame before the last.
            const back = has(before, y.id);
            if (input and !back) break;
            s.lost += 1;
            if (back) s.flapping += 1;
            warn(s, back);
            break;
        }
    }
}

fn warn(s: anytype, back: bool) void {
    // Tests read the counts: their output stays quiet.
    if (builtin.is_test) return;
    if (back and !s.warned_flapping) {
        s.warned_flapping = true;
        std.log.warn("myzig: a scrolling box changes its id back and forth between frames, and its offset jumps (a box before it shown every other frame?); key it with c.keyed() or keep the boxes before it", .{});
    } else if (!back and !s.warned) {
        s.warned = true;
        std.log.warn("myzig: a scrolled box changed its id between frames, and its offset started over (a box before it came or went?); key it with c.keyed() or keep the boxes before it", .{});
    }
}
