//! Timelines (`motion.timeline`), after mygo's: several tweens along one
//! playhead, so motion that belongs together is arranged, played and
//! tested together, placed as GSAP's position parameter places them.
//!
//!     var tl = ui.motion.timeline(c, id, "intro", .{ .run = s.opened });
//!     const x = tl.tween(.{ .from = -200, .to = 0, .duration = 0.4 }, .{});
//!     const fade = tl.tween(.{ .from = 0, .to = 1, .duration = 0.3 }, .after(-0.15));
//!
//! A tween with no placement follows the one before it. `paused` holds the
//! playhead (the time paused is not time played), `reverse` plays it back
//! to its start, `seek` and `progress` put it where a scrubber asks; `run`
//! plays it over when it changes. The view arranges it every build; the
//! playhead moves once a frame, on the context's clock.
const std = @import("std");
const curve = @import("motion_curve.zig");
const store = @import("motion_store.zig");
const keyframes = @import("motion_keyframes.zig");
const Context = @import("context.zig").Context;

pub const forever = keyframes.forever;

pub const Tween = struct {
    from: f32,
    to: f32,
    /// Seconds.
    duration: f32,
    ease: curve.Easing = .ease_out,
};

/// Where a tween (or a label) starts.
pub const Placement = struct {
    kind: enum { after, with, at, label } = .after,
    /// Seconds: after the tween before ends (negative overlaps it), after
    /// it starts, a time of the timeline, or after the label.
    offset: f32 = 0,
    name: []const u8 = "",

    pub fn after(offset: f32) Placement {
        return .{ .kind = .after, .offset = offset };
    }
    pub fn with(offset: f32) Placement {
        return .{ .kind = .with, .offset = offset };
    }
    pub fn at(seconds: f32) Placement {
        return .{ .kind = .at, .offset = seconds };
    }
    pub fn atLabel(name: []const u8, offset: f32) Placement {
        return .{ .kind = .label, .offset = offset, .name = name };
    }
};

pub const Options = struct {
    /// Change it to play the timeline over.
    run: u64 = 0,
    /// How many more times it plays after the first (`forever`), every
    /// other time backward with `alternate`.
    repeat: i32 = 0,
    alternate: bool = false,
    /// Seconds it holds its start before it plays, and between plays.
    delay: f32 = 0,
    repeat_delay: f32 = 0,
    paused: bool = false,
    reverse: bool = false,
    /// Holds the playhead at a time, or a part of the duration.
    seek: ?f32 = null,
    progress: ?f32 = null,
};

const max_labels = 32;

pub const State = struct {
    frame: u64 = 0,
    at: f64 = 0,
    started: bool = false,
    built: bool = false,
    moving: bool = false,
    reverse: bool = false,
    holding: bool = false,
    run: u64 = 0,
    /// Where the playhead is through its repeats, its delay included.
    raw: f64 = 0,
    /// The last frame's duration, which this one's playhead folds; and the
    /// one this frame arranges.
    duration: f64 = 0,
    build: f64 = 0,
    t: f64 = 0,
    done: bool = false,
    over: bool = false,
    at_start: bool = false,
    rested: u64 = 0,
    labels: [max_labels]struct { name: u64, at: f64 } = undefined,
    label_count: usize = 0,
};

/// A timeline as this build arranges it.
pub const Timeline = struct {
    c: *Context,
    st: *State,
    prev_start: f64 = 0,
    prev_end: f64 = 0,

    /// Adds `tw` where `p` places it; returns the value it shows this
    /// frame: its `from` before its time, its `to` after.
    pub fn tween(t: *Timeline, tw: Tween, p: Placement) f32 {
        const start = t.place(p);
        const d: f64 = @max(tw.duration, 0);
        const st = t.st;
        const stop = start + d;
        if (stop > st.build) {
            st.build = stop;
            if (st.done and !st.over and !st.reverse and !st.holding and stop > st.duration) {
                // A longer timeline than the one the playhead rested at the
                // end of: it plays on from there.
                st.moving = true;
                t.c.animationFrame();
            }
        }
        t.prev_start = start;
        t.prev_end = stop;
        return t.show(tw, start, d);
    }

    /// Marks a time for tweens to start at (`Placement.atLabel`); with no
    /// placement, where the tween before it ends.
    pub fn label(t: *Timeline, name: []const u8, p: Placement) void {
        const st = t.st;
        if (st.label_count == max_labels) return;
        st.labels[st.label_count] = .{ .name = std.hash.Wyhash.hash(0, name), .at = t.place(p) };
        st.label_count += 1;
    }

    /// The end of its last tween, in seconds, without repeats.
    pub fn duration(t: *const Timeline) f32 {
        return @floatCast(@max(t.st.build, t.st.duration));
    }

    /// Where the playhead is, in seconds.
    pub fn time(t: *const Timeline) f32 {
        const st = t.st;
        if (st.over) return if (st.at_start) 0 else t.duration();
        return @floatCast(@min(st.t, t.duration()));
    }

    /// How far along it the playhead is, from 0 to 1.
    pub fn progress(t: *const Timeline) f32 {
        const st = t.st;
        const d = t.duration();
        if (st.over or (st.done and d <= 0)) return if (st.at_start) 0 else 1;
        if (d <= 0) return 0;
        return std.math.clamp(@as(f32, @floatCast(st.t)) / d, 0, 1);
    }

    /// Whether it rests: at its end, repeats played, or at its start in reverse.
    pub fn settled(t: *const Timeline) bool {
        const st = t.st;
        if (!st.done) return false;
        if (st.over or st.reverse) return true;
        return st.build <= st.duration;
    }

    /// True in the one frame it came to rest.
    pub fn arrived(t: *const Timeline) bool {
        return t.st.rested != 0 and t.st.rested == t.c.frame;
    }

    fn place(t: *Timeline, p: Placement) f64 {
        const off: f64 = p.offset;
        const pos = switch (p.kind) {
            .with => t.prev_start + off,
            .at => off,
            .label => t.labelAt(p.name) + off,
            .after => t.prev_end + off,
        };
        return @max(pos, 0);
    }

    fn labelAt(t: *Timeline, name: []const u8) f64 {
        const h = std.hash.Wyhash.hash(0, name);
        var i = t.st.label_count;
        while (i > 0) {
            i -= 1;
            if (t.st.labels[i].name == h) return t.st.labels[i].at;
        }
        return 0;
    }

    fn show(t: *Timeline, tw: Tween, start: f64, d: f64) f32 {
        const st = t.st;
        if (st.over) return if (st.at_start) tw.from else tw.to;
        const now = st.t;
        if (d <= 0) return if (now >= start) tw.to else tw.from;
        if (now <= start) return tw.from;
        if (now >= start + d) return tw.to;
        const k = tw.ease.at(@floatCast((now - start) / d));
        return tw.from + (tw.to - tw.from) * k;
    }
};

/// The timeline `key` of box `id`, played as `o` says.
pub fn of(c: *Context, id: u64, key: []const u8, o: Options) Timeline {
    c.motion.sweep(c.gpa, c.frame);
    const gop = c.motion.timelines.getOrPut(c.gpa, store.keyOf(id, key)) catch {
        const S = struct {
            var spare: State = .{};
        };
        return .{ .c = c, .st = &S.spare };
    };
    if (!gop.found_existing) gop.value_ptr.* = .{};
    const st = gop.value_ptr;
    var t: Timeline = .{ .c = c, .st = st };
    if (st.frame != c.frame or !st.started) {
        st.frame = c.frame;
        st.duration = st.build;
        st.build = 0;
        st.label_count = 0;
        tick(&t, o);
    } else {
        // Built again in the same frame (its state changed): arranged over,
        // played as this build's options say.
        st.build = 0;
        st.label_count = 0;
        cue(&t, o);
    }
    return t;
}

fn tick(t: *Timeline, o: Options) void {
    const st = t.st;
    const c = t.c;
    if (!st.started) {
        st.started = true;
        st.at = c.time;
        st.run = o.run;
        cue(t, o);
        return;
    }
    st.built = true;
    const dt = c.time - st.at;
    st.at = c.time;
    // Only time it played moves it: a paused or finished timeline asks for
    // no frames, and the frame letting it go would carry the whole wait.
    if (dt > 0 and st.moving) {
        if (st.reverse) {
            st.raw = @max(st.raw - dt, @min(st.raw, o.delay));
        } else st.raw += dt;
    }
    cue(t, o);
}

fn end(st: *const State, o: Options) ?f64 {
    if (o.repeat == forever or st.duration <= 0) return null;
    const plays: f64 = @floatFromInt(o.repeat + 1);
    return plays * st.duration + (plays - 1) * o.repeat_delay;
}

fn cue(t: *Timeline, o: Options) void {
    const st = t.st;
    const c = t.c;
    if (st.run != o.run) {
        st.run = o.run;
        st.raw = 0;
        st.done = false;
        st.over = false;
        st.rested = 0;
        if (o.reverse) st.raw = o.delay + (end(st, o) orelse st.duration);
    }
    st.reverse = o.reverse;
    var held = false;
    if (o.seek) |s| {
        st.raw = o.delay + s;
        held = true;
    }
    if (o.progress) |p| {
        st.raw = o.delay + p * st.duration;
        held = true;
    }
    if (held) {
        st.over = false;
    } else if (!o.paused and @import("motion.zig").reduced(c)) st.over = true;
    if (st.over) {
        st.at_start = o.reverse or (o.alternate and @mod(o.repeat + 1, 2) == 0);
        st.t = if (st.at_start) 0 else st.duration;
        st.done = true;
        st.moving = false;
        st.holding = true;
        if (st.rested == 0) st.rested = c.frame;
        return;
    }
    if (end(st, o)) |e| st.raw = @min(st.raw, o.delay + e);
    st.raw = @max(st.raw, 0);
    const raw = st.raw - o.delay;
    const p = keyframes.playhead(raw, st.duration, o.repeat, o.alternate, o.repeat_delay);
    st.t = p[0];
    st.done = p[2];
    if (raw > 0 and st.duration <= 0) st.done = st.built;
    if (o.reverse) st.done = raw <= 0;
    st.holding = o.paused or held;
    st.moving = !st.done and !st.holding;
    if (st.done) {
        if (st.rested == 0) st.rested = c.frame;
        return;
    }
    st.rested = 0;
    if (held and !st.built) return c.animationFrame();
    if (st.moving) c.animationFrame();
}
