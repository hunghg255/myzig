//! A drawer's drag (`drawer.zig`), after vaul: it follows the pointer
//! toward its edge, holds back past open, and on letting go closes, steps
//! to the next snap point, or settles at the nearest, by how far and how
//! fast it went.
const std = @import("std");
const types = @import("types.zig");
const motion = @import("motion.zig");
const drawer = @import("drawer.zig");
const Context = @import("context.zig").Context;

/// How fast a throw is, in points a millisecond: past `step` it goes on to
/// the next snap point (or closes), past `fling` to the last (or closes).
const step: f32 = 0.4;
const fling: f32 = 2;
/// The pointer moves this far along the drawer's axis before it drags.
const start_distance: f32 = 2;
/// A drawer just opened is not dragged for a moment.
const settle_time: f64 = 0.5;

pub const Drag = struct {
    on: bool = false,
    /// It went past `start_distance`: it drags (and a click is not one).
    moved: bool = false,
    start: types.Point = .{},
    start_time: f64 = 0,
    /// Where it was as the press began, from open toward the edge.
    from: f32 = 0,
    /// Where it is, as last built.
    at: f32 = 0,
    /// The handle's id, from the last frame.
    handle: u64 = 0,
};

/// vaul's hold past open: nothing for a few points, then less and less.
fn dampen(v: f32) f32 {
    return 8 * (@log(v + 1) - 2);
}

fn transition() motion.Animation {
    return .curve(drawer.seconds, drawer.ease);
}

/// Where the drawer is this frame, from open toward its edge: dragged, or
/// on its way to where it rests (or out, closing). Presses on the panel
/// (`panel`, not on its controls) or the handle start a drag.
pub fn follow(c: *Context, s: *drawer.DrawerState, opts: drawer.Options, id: u64, panel: u64, extent: f32, target: f32) f32 {
    const g = &s.drag;
    const across = drawer.horizontal(opts.side);
    const along = if (across) c.input.mouse.x else c.input.mouse.y;
    const cross = if (across) c.input.mouse.y else c.input.mouse.x;
    // Toward open is positive: up for a drawer at the bottom.
    const sign: f32 = if (opts.side == .bottom or opts.side == .right) 1 else -1;
    if (c.input.pressed and s.open) {
        const on_handle = g.handle != 0 and c.hot == g.handle;
        if (on_handle or (c.hot == panel and !opts.handle_only)) {
            g.* = .{ .on = true, .start = c.input.mouse, .start_time = c.time, .from = g.at, .handle = g.handle };
        }
    }
    if (g.on) {
        const d = ((if (across) g.start.x else g.start.y) - along) * sign;
        if (c.input.down) {
            if (!g.moved) {
                const waited = across or c.time - s.opened_at >= settle_time;
                if (waited and @abs(d) > start_distance) {
                    g.moved = true;
                } else if (@abs((if (across) g.start.y else g.start.x) - cross) > start_distance and !g.moved) {
                    g.on = false;
                }
            }
            if (g.moved) {
                g.at = motion.jump(c, id, "moved", place(opts, extent, g.from - d));
                c.changed = true;
                return g.at;
            }
        } else {
            g.on = false;
            if (g.moved) {
                const ms: f32 = @floatCast(@max(1, (c.time - g.start_time) * 1000));
                release(c, s, opts, extent, d, @abs(d) / ms, g.from - d);
                c.changed = true;
                const to = if (s.open) drawer.restAt(opts, s, extent) else drawer.room(c, opts.side);
                g.at = motion.animateTo(c, id, "moved", to, transition());
                return g.at;
            }
        }
    }
    g.at = motion.animateTo(c, id, "moved", target, transition());
    return g.at;
}

/// Where a drag to `raw` (from open toward the edge) puts the drawer.
fn place(opts: drawer.Options, extent: f32, raw: f32) f32 {
    const n = opts.snap_points.len;
    if (n == 0) {
        if (raw >= 0) return if (opts.dismissible) raw else 0;
        return @min(-dampen(-raw), 0);
    }
    var v = @max(raw, drawer.snapOffset(opts, extent, n - 1));
    if (!opts.dismissible) v = @min(v, drawer.snapOffset(opts, extent, 0));
    return v;
}

/// Decides, as the pointer lets go after dragging `d` (toward open
/// positive) at `speed`, whether the drawer closes or where it rests.
fn release(c: *Context, s: *drawer.DrawerState, opts: drawer.Options, extent: f32, d: f32, speed: f32, at: f32) void {
    const n = opts.snap_points.len;
    if (n == 0) {
        if (d > 0 or !opts.dismissible) return;
        if (speed > step or at >= @min(extent, drawer.room(c, opts.side)) * opts.close_threshold) s.open = false;
        return;
    }
    const last = n - 1;
    if (speed > fling and !opts.snap_to_sequential) {
        if (d < 0) {
            if (opts.dismissible) s.open = false else s.snap = 0;
        } else s.snap = last;
        return;
    }
    if (speed > step and @abs(d) < 0.4 * drawer.room(c, opts.side)) {
        if (d > 0) {
            s.snap = @min(s.snap + 1, last);
        } else if (s.snap == 0) {
            if (opts.dismissible) s.open = false;
        } else s.snap -= 1;
        return;
    }
    // The nearest snap point.
    var best: usize = 0;
    var best_d = std.math.inf(f32);
    for (0..n) |i| {
        const off = drawer.snapOffset(opts, extent, i);
        if (@abs(off - at) < best_d) {
            best_d = @abs(off - at);
            best = i;
        }
    }
    s.snap = best;
}

/// A click on the handle: the next snap point, or closed from the last.
pub fn cycle(c: *Context, s: *drawer.DrawerState, opts: drawer.Options) void {
    const n = opts.snap_points.len;
    if (n == 0) return;
    if (s.snap + 1 >= n) {
        if (opts.dismissible) s.open = false;
    } else s.snap += 1;
    c.changed = true;
}

test "the hold past open: nothing at first, then less and less" {
    try std.testing.expect(dampen(5) < 0);
    try std.testing.expect(dampen(20) > 0);
    try std.testing.expect(dampen(200) - dampen(100) < 100 - 20);
}
