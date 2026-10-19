//! A scrolling box following its end (`Style.follow_end`) that glides
//! there (`Style.follow_glide`), after mygo's `ListState.FollowAnimation`:
//! as its content grows, the children that stay show where they were on
//! the frame it changed, then go to their place as the animation says, so
//! what is added comes up from below, as the chat apps scroll. A glide on
//! its way goes on from where it is as more comes; the reader scrolling
//! stops it; with less motion the end shows at once.
//!
//! The lag is how far the content that changed moves the children that
//! stay (mygo's 4ccea24): where the content as it was would show in the
//! box as it is, less where the content shows, as the box places it
//! following its end (`justify` for content that fits, the end at the
//! bottom for content that overflows). Content that fits the box with
//! `justify = .start` then moves nothing. A box whose height changes by
//! itself (a window resized, a composer below grew) moves its children at
//! once; a box as tall as its content (`max_height`) follows it, in the
//! same frame or the next, and its children keep their place.
const std = @import("std");
const types = @import("types.zig");
const curve = @import("motion_curve.zig");
const Context = @import("context.zig").Context;

/// A box following its end as a layout left it: its last child (its id),
/// how much content was from that child's top to the end, how tall the
/// content and the box were, how wide, and whether the box was as tall as
/// its content (or was before it changed and has yet to follow).
const Mark = struct {
    seen: bool = false,
    child: u64 = 0,
    below: f32 = 0,
    height: f32 = 0,
    width: f32 = 0,
    hugs: bool = false,
};

/// A box's glide: the lag (how far below their place its children show),
/// the box as the last layout left it and as the frame before did, and
/// the lag as it was at the start of `frame`: every layout of a frame
/// starts from the frame before, so the one that shows decides.
pub const Glide = struct {
    lag: curve.Channel,
    follow: Mark = .{},
    was: Mark = .{},
    base: curve.Channel,
    frame: ?u64 = null,
    /// The frame it was last laid out in, to forget boxes gone.
    seen: u64 = 0,
};

pub const Glides = std.AutoHashMapUnmanaged(u64, Glide);

/// A glide to the end (`Style.follow_glide`): its animation, and what
/// layout calls, set by `of`, so that apps not gliding don't carry it.
///
///     const glide: ui.FollowGlide = .of(.smooth);
///     _ = c.open(.{ .scroll = true, .follow_end = true, .follow_glide = &glide }, "chat");
pub const FollowGlide = struct {
    animation: curve.Animation,
    lag: *const fn (c: *Context, id: u64, a: curve.Animation, justify: types.Justify, content: f32, height: f32, width: f32, tops: Tops) f32,
    wanted: *const fn (c: *Context, id: u64) ?u64,

    pub fn of(a: curve.Animation) FollowGlide {
        return .{ .animation = a, .lag = &lag, .wanted = &wanted };
    }
};

/// What the layout of the box tells: the top in the content of the child
/// the last frame ended with (`want`, if it is still there), and its last
/// child now and that child's top.
pub const Tops = struct {
    want: ?u64,
    found: ?f32 = null,
    last: u64 = 0,
    last_top: f32 = 0,

    pub fn see(t: *Tops, id: u64, top: f32) void {
        if (t.want) |w| if (w == id) {
            t.found = top;
        };
        t.last = id;
        t.last_top = top;
    }
};

/// The child box `id`'s glide measures from, if it has one.
pub fn wanted(c: *Context, id: u64) ?u64 {
    const g = c.follow_glides.getPtr(id) orelse return null;
    // The frame before's, whichever layout of this frame asks.
    const m = if (g.frame == c.frame) g.was else g.follow;
    return if (m.seen) m.child else null;
}

/// How far below their place the children of the scrolling box `id`
/// show, its content `content` tall in `height`, `width` wide: the glide
/// toward its end, moved by what changed since the last frame.
pub fn lag(c: *Context, id: u64, a: curve.Animation, justify: types.Justify, content: f32, height: f32, width: f32, tops: Tops) f32 {
    sweep(c);
    const gop = c.follow_glides.getOrPut(c.gpa, id) catch return 0;
    if (!gop.found_existing) gop.value_ptr.* = .{ .lag = .init(0, c.time), .base = .init(0, c.time) };
    const g = gop.value_ptr;
    g.seen = c.frame;
    const following = c.scroll_follow.get(id) orelse true;
    const motion = @import("motion.zig");
    if (!following or c.scroll_moved.contains(id) or motion.reduced(c) or c.motion.instant == c.frame) {
        g.* = .{ .lag = .init(0, c.time), .base = .init(0, c.time), .seen = c.frame };
        return 0;
    }
    if (g.frame != c.frame) {
        g.lag.advance(c.time);
        g.frame = c.frame;
        g.was = g.follow;
        g.base = g.lag;
    } else g.lag = g.base;
    const C = content;
    const H = height;
    var hugs = @abs(H - C) < 0.5;
    const p = g.was;
    if (p.seen and p.width == width) {
        if (tops.found) |top| {
            // As much as what changed below the child that ended the
            // content moves the children that stay, they show where they
            // were, and go on to their place.
            var d = (C - top) - p.below;
            if (@abs(d) < 0.5) d = 0;
            // A box as tall as its content follows it, in the frame or the
            // next: the children keep their place in it. Another moves its
            // children itself as its height changes, and the glide only
            // takes what the content moved them in the box as it is.
            const dh = H - p.height;
            const dc = C - p.height;
            const follows = p.hugs and ((dh > 0.5 and dh <= dc + 0.5) or (dh < -0.5 and dh >= dc - 0.5));
            const was = if (follows) p.height else H;
            const m = place(justify, C - d, was) - place(justify, C, H);
            if (@abs(m) > 0.5) {
                g.lag.value = std.math.clamp(g.lag.value + m, -H, H);
                g.lag.retarget(0, a);
            }
            hugs = hugs or (p.hugs and (d != 0 or follows));
        } else g.lag = .init(0, c.time);
    }
    g.follow = .{ .seen = true, .child = tops.last, .below = C - tops.last_top, .height = H, .width = width, .hugs = hugs };
    if (g.lag.moving or g.lag.pending) c.animating = true;
    const v: f32 = @floatCast(g.lag.value);
    return if (@abs(v) > 0.01) v else 0;
}

/// How far below its place in the content a box `height` tall following
/// its end shows its content `content` tall: the end at the bottom of
/// content that overflows it, and where `justify` puts content that fits.
pub fn place(justify: types.Justify, content: f32, height: f32) f32 {
    if (content > height or justify == .end) return height - content;
    if (justify == .center) return (height - content) / 2;
    return 0;
}

/// Forgets the glides of boxes not laid out for a while.
fn sweep(c: *Context) void {
    if (c.frame % 64 != 0 or c.follow_glides.count() == 0) return;
    var it = c.follow_glides.iterator();
    var gone: [16]u64 = undefined;
    var n: usize = 0;
    while (it.next()) |e| if (e.value_ptr.seen + 64 < c.frame and n < gone.len) {
        gone[n] = e.key_ptr.*;
        n += 1;
    };
    for (gone[0..n]) |k| _ = c.follow_glides.remove(k);
}
