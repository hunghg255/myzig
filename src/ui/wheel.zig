//! The notches of a mouse wheel, after mygo's: a scrolling box glides
//! through a notch along a short ease out, as browsers scroll it, rather
//! than jumping the whole notch at once; notches in a row add up, and a
//! box at its end leaves them to the box around it. A touchpad's small
//! moves already follow the fingers (`applyScroll`); with less motion, a
//! notch scrolls at once too.
//!
//! A glide moves its box by what it went since the last frame, so what
//! else moves the offset meanwhile (the app, a touchpad, a key) takes over:
//! the glide stops.
const std = @import("std");
const curve = @import("motion_curve.zig");
const motion = @import("motion.zig");
const Context = @import("context.zig").Context;

/// How a notch scrolls.
pub const animation: curve.Animation = .curve(0.15, .ease_out);

/// Notches on their way through a scrolling box: `ch` goes from 0 to as
/// far as all of them scroll, `done` is how far the box has gone with
/// them, `queued` what notches since the last frame add, and `seen` the
/// offset the glide left.
pub const Glide = struct {
    ch: curve.Channel = .init(0, 0),
    done: f64 = 0,
    queued: f64 = 0,
    seen: f32 = 0,
    started: bool = false,

    /// How far the notches have yet to scroll the box.
    fn ahead(g: Glide) f64 {
        return g.ch.goal() - g.done + g.queued;
    }
};

pub const Glides = std.AutoHashMapUnmanaged(u64, Glide);

/// The largest offset of box `id` in the last layout (none known: any).
fn limitOf(c: *Context, id: u64) f32 {
    return c.scroll_limit.get(id) orelse std.math.inf(f32);
}

/// Scrolls the innermost scrolling box under the pointer that a notch of
/// `dy` points moves (up positive, as `applyScroll`), smoothly; the box
/// around one at its end takes it. True if a scrolling box is under the
/// pointer, whether it could move or not.
pub fn applyWheel(c: *Context, dy: f32) bool {
    if (dy == 0) return c.applyScroll(0);
    if (motion.reduced(c)) return scrollAtOnce(c, dy);
    var under = false;
    var i = c.hits.items.len;
    while (i > 0) {
        i -= 1;
        const h = c.hits.items[i];
        if (!h.scroll or !h.contains(c.input.mouse)) continue;
        under = true;
        const g = c.wheel.getPtr(h.id);
        const ahead: f64 = if (g) |x| x.ahead() else 0;
        const limit = limitOf(c, h.id);
        const at = std.math.clamp((c.scroll.get(h.id) orelse 0) + @as(f32, @floatCast(ahead)), 0, limit);
        if (std.math.clamp(at - dy, 0, limit) == at) continue;
        const gop = c.wheel.getOrPut(c.gpa, h.id) catch return true;
        if (!gop.found_existing) gop.value_ptr.* = .{ .seen = c.scroll.get(h.id) orelse 0 };
        gop.value_ptr.queued -= dy;
        return true;
    }
    return under;
}

/// Glides scrolling box `id` by `dy` points (up positive), as a notch over
/// it would: for what scrolls a box from elsewhere (a minimap, an
/// overview), with the motion the box has under the pointer.
pub fn glideBy(c: *Context, id: u64, dy: f32) void {
    if (motion.reduced(c)) {
        const gop = c.scroll.getOrPut(c.gpa, id) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* = std.math.clamp(gop.value_ptr.* - dy, 0, limitOf(c, id));
        _ = c.wheel.remove(id);
        return;
    }
    const gop = c.wheel.getOrPut(c.gpa, id) catch return;
    if (!gop.found_existing) gop.value_ptr.* = .{ .seen = c.scroll.get(id) orelse 0 };
    gop.value_ptr.queued -= dy;
    c.animating = true;
}

/// A notch with less motion: at once, the box around one at its end
/// taking it.
fn scrollAtOnce(c: *Context, dy: f32) bool {
    var under = false;
    var i = c.hits.items.len;
    while (i > 0) {
        i -= 1;
        const h = c.hits.items[i];
        if (!h.scroll or !h.contains(c.input.mouse)) continue;
        under = true;
        const limit = limitOf(c, h.id);
        const gop = c.scroll.getOrPut(c.gpa, h.id) catch return true;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        const to = std.math.clamp(gop.value_ptr.* - dy, 0, limit);
        if (to == gop.value_ptr.*) continue;
        gop.value_ptr.* = to;
        _ = c.wheel.remove(h.id);
        return true;
    }
    return under;
}

/// Moves the boxes notches glide through to the frame's time, before the
/// view is built (`frame.zig`).
pub fn glide(c: *Context) void {
    if (c.wheel.count() == 0) return;
    var gone: [16]u64 = undefined;
    var n: usize = 0;
    var it = c.wheel.iterator();
    while (it.next()) |e| {
        const id = e.key_ptr.*;
        const g = e.value_ptr;
        const cur = c.scroll.get(id) orelse 0;
        var keep = cur == g.seen;
        if (keep) {
            if (!g.started) {
                g.ch = .init(0, c.time);
                g.started = true;
            }
            g.ch.advance(c.time);
            if (g.queued != 0) {
                g.ch.retarget(g.ch.goal() + g.queued, animation);
                g.queued = 0;
            }
            const d: f32 = @floatCast(g.ch.value - g.done);
            g.done = g.ch.value;
            const to = std.math.clamp(cur + d, 0, limitOf(c, id));
            c.scroll.put(c.gpa, id, to) catch {};
            g.seen = to;
            // At the end of the content, or there.
            keep = !(to == cur and d != 0) and g.ch.moving;
            if (keep) c.animating = true;
        }
        if (!keep and n < gone.len) {
            gone[n] = id;
            n += 1;
        }
    }
    for (gone[0..n]) |id| _ = c.wheel.remove(id);
}
