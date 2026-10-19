//! Motion, after mygo's: values that animate toward the targets the view
//! gives them, with springs that keep their velocity or curves of a
//! duration, colors mixed with premultiplied alpha, keyframes, timelines
//! of tweens (`motion_timeline.zig`), poses, and transitions of boxes as
//! the layout moves them, as they come and as they go
//! (`motion_transition.zig`). The view says where things are; motion finds
//! the way, on the context's clock (`Context.time`, which `ui.Tester`
//! advances), drawing frames only while something moves.
//!
//!     const x = ui.motion.animateTo(c, id, "x", if (s.open) 200 else 0, .snappy);
//!     _ = c.open(.{ .transform = .translation(x, 0), ... }, "card");
//!
//! Values belong to a box's id (`c.peekId(key)` before opening it, or
//! `c.node(index).id`) and a key that tells its values apart; `to` uses
//! the box open now. While the desktop asks for less motion (`reduced`),
//! values go to their targets at once; colors and fades still change
//! smoothly.
const std = @import("std");
const types = @import("types.zig");
const curve = @import("motion_curve.zig");
const store = @import("motion_store.zig");
const Context = @import("context.zig").Context;

pub const Easing = curve.Easing;
pub const Spring = curve.Spring;
pub const Animation = curve.Animation;
pub const Keyframe = @import("motion_keyframes.zig").Keyframe;
pub const KeyframeOptions = @import("motion_keyframes.zig").Options;
pub const keyframes = @import("motion_keyframes.zig").play;
pub const Timeline = @import("motion_timeline.zig").Timeline;
pub const TimelineOptions = @import("motion_timeline.zig").Options;
pub const Tween = @import("motion_timeline.zig").Tween;
pub const Placement = @import("motion_timeline.zig").Placement;
pub const timeline = @import("motion_timeline.zig").of;
pub const Transition = @import("motion_transition.zig").Transition;
pub const Motion = @import("motion_transition.zig").Motion;
pub const transition = @import("motion_transition.zig").apply;
pub const transitioning = @import("motion_transition.zig").transitioning;

/// Whether values should go to their targets at once: the app's say
/// (`setReducedMotion`), else the desktop's (asked once; never in tests).
pub fn reduced(c: *Context) bool {
    const s = &c.motion;
    if (s.reduce) |r| return r;
    if (s.system == null) s.system = if (@import("builtin").is_test) false else @import("motion_system.zig").prefersReducedMotion();
    return s.system.?;
}

/// Overrides the desktop's wish for less motion (null: follow it again).
pub fn setReducedMotion(c: *Context, reduce: ?bool) void {
    c.motion.reduce = reduce;
}

/// Makes the values, colors, poses and transitions of this frame go to
/// their targets at once, as SwiftUI's disablesAnimations: for a change
/// that should not show as motion. Keyframes and timelines play on.
pub fn disableAnimations(c: *Context) void {
    c.motion.instant = c.frame;
}

fn instant(c: *Context) bool {
    return c.motion.instant == c.frame;
}

/// The channel of `key` of box `id`, made at `value`, and whether it was made.
pub fn channel(c: *Context, id: u64, key: []const u8, value: f32) ?struct { *curve.Channel, bool } {
    c.motion.sweep(c.gpa, c.frame);
    const gop = c.motion.channels.getOrPut(c.gpa, store.keyOf(id, key)) catch return null;
    if (!gop.found_existing) gop.value_ptr.* = .init(value, c.time);
    gop.value_ptr.frame = c.frame;
    return .{ gop.value_ptr, !gop.found_existing };
}

/// Moves value `key` of box `id` toward `target` as `a` says; returns the
/// value to show this frame, and asks for frames while it moves. It starts
/// at its first target. A new target on the way, or a new kind of
/// animation, takes over from where it is: a spring keeps its velocity.
pub fn animateTo(c: *Context, id: u64, key: []const u8, target: f32, a: Animation) f32 {
    return move(c, id, key, target, a, reduced(c));
}

fn move(c: *Context, id: u64, key: []const u8, target: f32, a: Animation, at_once: bool) f32 {
    if (!std.math.isFinite(target)) return target;
    const got = channel(c, id, key, target) orelse return target;
    const ch = got[0];
    if (got[1]) return target;
    const goal: f64 = target;
    const was_moving = ch.moving or ch.pending;
    ch.advance(c.time);
    if (at_once or instant(c)) {
        if (ch.moving or ch.pending or ch.value != goal) ch.rested = c.frame;
        ch.value = goal;
        ch.velocity = 0;
        ch.target = goal;
        ch.moving = false;
        ch.pending = false;
        return target;
    }
    if (goal != ch.goal() and a.delay > 0) {
        ch.pending = true;
        ch.pending_to = goal;
        ch.pending_at = c.time + a.delay;
        ch.pending_anim = a;
        ch.pending_anim.delay = 0;
    } else if (goal != ch.goal()) {
        ch.pending = false;
        ch.retarget(goal, a);
    } else if (ch.moving and !ch.curve and a.duration == 0 and !ch.pending) {
        // The spring's options may change on the way.
        const p = a.spring.physics();
        ch.m = p[0];
        ch.k = p[1];
        ch.c = p[2];
    }
    if (ch.moving or ch.pending) {
        c.animationFrame();
    } else if (was_moving) ch.rested = c.frame;
    return @floatCast(ch.value);
}

/// `animateTo` for the box open now.
pub fn to(c: *Context, key: []const u8, target: f32, a: Animation) f32 {
    return animateTo(c, openId(c), key, target, a);
}

/// The id of the box open now.
pub fn openId(c: *Context) u64 {
    return c.nodes.items[c.stack.items[c.stack.items.len - 1]].id;
}

/// A curve of `seconds` easing out: `animateTo` with `Animation.curve`.
pub fn animate(c: *Context, id: u64, key: []const u8, target: f32, seconds: f32) f32 {
    return animateTo(c, id, key, target, .curve(seconds, .ease_out));
}

/// Sets value `key` to `value` at once, as a drag moves it, keeping track
/// of how fast it goes, for a spring taking over to keep going that way.
pub fn jump(c: *Context, id: u64, key: []const u8, value: f32) f32 {
    const got = channel(c, id, key, value) orelse return value;
    const ch = got[0];
    if (got[1]) return value;
    const v: f64 = value;
    const dt = c.time - ch.at;
    if (dt > 0 and dt <= 0.1 and ch.jumped) {
        ch.velocity = (v - ch.value) / dt;
    } else if (dt > 0) {
        ch.advance(c.time);
        if (dt > 0.1) ch.velocity = 0;
    }
    ch.value = v;
    ch.target = v;
    ch.moving = false;
    ch.pending = false;
    ch.jumped = true;
    ch.at = c.time;
    return value;
}

fn find(c: *Context, id: u64, key: []const u8) ?*curve.Channel {
    return c.motion.channels.getPtr(store.keyOf(id, key));
}

/// How fast value `key` goes this frame, its units a second.
pub fn velocity(c: *Context, id: u64, key: []const u8) f32 {
    const ch = find(c, id, key) orelse return 0;
    return @floatCast(ch.velocity);
}

/// Whether value `key` rests at its target (true for one unknown).
pub fn settled(c: *Context, id: u64, key: []const u8) bool {
    const ch = find(c, id, key) orelse return true;
    return !ch.moving and !ch.pending;
}

/// True in the one frame value `key` came to rest at its target, after
/// moving: for the view to go on, as removing what faded out.
pub fn arrived(c: *Context, id: u64, key: []const u8) bool {
    const ch = find(c, id, key) orelse return false;
    return ch.rested == c.frame;
}

/// Mixes premultiplied: a color fading from transparent keeps its hue.
pub fn mixPremultiplied(a: types.Color, b: types.Color, t: f32) types.Color {
    const alpha = a.a + (b.a - a.a) * t;
    if (alpha <= 0) return .{ .r = b.r, .g = b.g, .b = b.b, .a = 0 };
    return .{
        .r = (a.r * a.a + (b.r * b.a - a.r * a.a) * t) / alpha,
        .g = (a.g * a.a + (b.g * b.a - a.g * a.a) * t) / alpha,
        .b = (a.b * a.a + (b.b * b.a - a.b * a.a) * t) / alpha,
        .a = alpha,
    };
}

/// Moves color `key` of box `id` toward `target`, mixed premultiplied.
/// Colors move nothing, so they change smoothly even with less motion.
pub fn animateColor(c: *Context, id: u64, key: []const u8, target: types.Color, a: Animation) types.Color {
    var h = std.hash.Wyhash.init(store.keyOf(id, key));
    h.update("color");
    const k = h.final();
    const gop = c.motion.colors.getOrPut(c.gpa, k) catch return target;
    if (!gop.found_existing) gop.value_ptr.* = .{ .from = target, .to = target, .now = target };
    const m = gop.value_ptr;
    m.frame = c.frame;
    // How far from `from` to `to` it is.
    const got = channel(c, k, "t", 1) orelse return target;
    const t = got[0];
    if (got[1]) return target;
    const was = t.moving or t.pending;
    t.advance(c.time);
    if (!std.meta.eql(m.to, target)) {
        if (instant(c)) {
            t.* = .init(1, c.time);
        } else {
            m.from = m.now;
            t.* = .init(0, c.time);
            t.retarget(1, a);
        }
        t.frame = c.frame;
        m.to = target;
    }
    if (t.moving or t.pending) {
        m.now = mixPremultiplied(m.from, target, @floatCast(std.math.clamp(t.value, 0, 1)));
        c.animationFrame();
    } else {
        m.now = target;
        if (was) t.rested = c.frame;
    }
    return m.now;
}

/// The part of a period of `seconds` the clock is in, from 0 to 1, for
/// spinners and pulses: it asks for frames.
pub fn loop(c: *Context, seconds: f32) f32 {
    if (seconds <= 0) return 0;
    c.animationFrame();
    const t = c.time / seconds;
    return @floatCast(t - @floor(t));
}

/// Where a throw at `velocity` (units a second) carries `value`, as iOS's
/// scroll views slow down: to choose where it lands.
pub fn project(value: f32, v: f32) f32 {
    const rate = 0.998;
    return value + v / 1000 * rate / (1 - rate);
}

/// `value` held within `lo` and `hi` as iOS holds content dragged past its
/// edges, going less and less far the larger `dimension` is.
pub fn rubberband(value: f32, lo: f32, hi: f32, dimension: f32) f32 {
    const band = struct {
        fn f(over: f32, d: f32) f32 {
            if (d <= 0) return 0;
            return (1 - 1 / (over * 0.55 / d + 1)) * d;
        }
    }.f;
    if (value < lo) return lo - band(lo - value, dimension);
    if (value > hi) return hi + band(value - hi, dimension);
    return value;
}

/// How a box is moved, scaled, turned and faded, after its own transform
/// (`pose`): `scale` 0 keeps its size, `fade` from 0 (opaque) to 1 (gone).
pub const Pose = struct {
    x: f32 = 0,
    y: f32 = 0,
    scale: f32 = 0,
    rotate: f32 = 0,
    fade: f32 = 0,
};

/// Animates box `index` (open or built) toward `p` with `a`: its
/// transform, after its own, and its opacity. With less motion it fades,
/// and moves at once.
pub fn pose(c: *Context, index: u32, p: Pose, a: Animation) void {
    const n = c.node(index);
    const id = n.id;
    const r = reduced(c);
    const x = move(c, id, "pose.x", p.x, a, r);
    const y = move(c, id, "pose.y", p.y, a, r);
    const s = move(c, id, "pose.scale", if (p.scale == 0) 1 else p.scale, a, r);
    const t = move(c, id, "pose.rotate", p.rotate, a, r);
    const f = move(c, id, "pose.fade", p.fade, a, false);
    const m = types.Affine.scaling(s, s).then(.rotation(t)).then(.translation(x, y));
    const st = &c.node(index).style;
    st.transform = if (st.transform) |own| own.then(m) else m;
    st.opacity *= std.math.clamp(1 - f, 0, 1);
}

test {
    _ = curve;
}
