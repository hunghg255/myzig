//! Transitions as painted (`motion_transition.zig`): boxes moved from
//! where the layout had them the frame before, what boxes with an exit
//! painted kept for when they go, and the copies of boxes gone drawn on
//! their way out, under their siblings, in the parent they left.
const std = @import("std");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const xf = @import("paint_xf.zig");
const tr = @import("motion_transition.zig");

/// The translation that moves box `index` from where it was, if any.
pub fn offset(p: anytype, index: u32) ?types.Affine {
    const c = p.c;
    if (c.motion.moving_boxes == 0) return null;
    const off = tr.offsetOf(c, index) orelse return null;
    return .translation(off.x, off.y);
}

/// Keeps what box `index` painted from instance `first` on, for its exit.
pub fn keep(p: anytype, index: u32, first: usize) void {
    if (p.c.motion.boxes.count() == 0) return;
    tr.keep(p.c, index, p.out.items[first..]);
}

/// Draws the copies of the boxes gone from box `parent`.
pub fn drawGoing(p: anytype, parent: u64) void {
    const c = p.c;
    for (p.going.list[0..p.going.n], 0..) |g, k| {
        if (g.parent != parent or p.going_drawn & (@as(u32, 1) << @intCast(k)) != 0) continue;
        p.going_drawn |= @as(u32, 1) << @intCast(k);
        const e = tr.exitPose(c, g.id) orelse {
            tr.gone(c, g.id);
            continue;
        };
        // The copy is in the window's coordinates already: its pose maps
        // the window to itself.
        var sp: xf.Space = .{};
        if (e.pose) |m| sp = (xf.enter(&p.rows, c.alloc(), .{}, m, types.Rect.infinite) orelse continue)[0];
        for (e.rec.snapshot.items) |inst| {
            var i = inst;
            i.color[3] *= e.opacity;
            i.border_color[3] *= e.opacity;
            if (e.clip) |k2| {
                const box = gpu.clip4(k2);
                i.clip = .{ @max(i.clip[0], box[0]), @max(i.clip[1], box[1]), @min(i.clip[2], box[2]), @min(i.clip[3], box[3]) };
                if (i.clip[2] <= i.clip[0] or i.clip[3] <= i.clip[1]) continue;
            }
            p.out.append(c.gpa, xf.place(&sp, i)) catch return;
        }
    }
}

/// Forgets the boxes gone whose parent went too.
pub fn finish(p: anytype) void {
    for (p.going.list[0..p.going.n], 0..) |g, k| {
        if (p.going_drawn & (@as(u32, 1) << @intCast(k)) == 0) tr.gone(p.c, g.id);
    }
}
