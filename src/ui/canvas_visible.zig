//! The part of a canvas in view (`Painter.visible`), after mygo's
//! `Painter.Visible` (26d1584): a canvas asking for it is remembered, and
//! painting records, for each one, the part of its box the clips around it
//! and the window leave, in its own coordinates: under a transform, its
//! box's or an ancestor's, the clip in the window taken back through it.
//! The canvas draws before the frame is laid out, so it reads what the
//! last frame painted; a part that changed asks for one more frame, which
//! draws it with the part as it now is.
const std = @import("std");
const types = @import("types.zig");
const Affine = types.Affine;
const Context = @import("context.zig").Context;

pub const Entry = struct {
    rect: types.Rect,
    /// The frame it was last asked for, to forget canvases gone.
    frame: u64,
};

pub const Map = std.AutoHashMapUnmanaged(u64, Entry);

/// What the last frame showed of canvas `id`, `whole` until one painted it.
pub fn of(c: *Context, id: u64, whole: types.Rect) types.Rect {
    c.canvas_record = &record;
    sweep(c);
    const gop = c.canvas_visible.getOrPut(c.gpa, id) catch return whole;
    if (!gop.found_existing) gop.value_ptr.* = .{ .rect = whole, .frame = c.frame };
    gop.value_ptr.frame = c.frame;
    return gop.value_ptr.rect;
}

/// Records, as box `id` at `r` is painted, what of it shows: the clip
/// `clip` of its coordinates (in the window through `m`; the clip `outer`
/// around a general transform's, whose own clip is infinite) within the
/// window, back in its coordinates, from its top left.
pub fn record(c: *Context, id: u64, r: types.Rect, m: Affine, general: bool, outer: types.Rect, clip: types.Rect) void {
    const e = c.canvas_visible.getPtr(id) orelse return;
    const window: types.Rect = .{ .w = c.size.w, .h = c.size.h };
    const world = (if (general) outer else m.bounds(clip)).intersect(window);
    const inv = m.inverse() orelse return;
    var local = if (m.isIdentity()) world else inv.bounds(world);
    local.x -= r.x;
    local.y -= r.y;
    if (local.w <= 0 or local.h <= 0) local = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    const was = e.rect;
    e.rect = local;
    const near = struct {
        fn f(a: f32, b: f32) bool {
            return @abs(a - b) < 0.5;
        }
    }.f;
    // The canvas drew with the part as it was: one more frame draws it anew.
    if (!(near(was.x, local.x) and near(was.y, local.y) and near(was.w, local.w) and near(was.h, local.h))) c.animating = true;
}

/// Forgets canvases not asked for a while.
fn sweep(c: *Context) void {
    if (c.frame % 64 != 0 or c.canvas_visible.count() == 0) return;
    var gone: [16]u64 = undefined;
    var n: usize = 0;
    var it = c.canvas_visible.iterator();
    while (it.next()) |e| if (e.value_ptr.frame + 64 < c.frame and n < gone.len) {
        gone[n] = e.key_ptr.*;
        n += 1;
    };
    for (gone[0..n]) |k| _ = c.canvas_visible.remove(k);
}
