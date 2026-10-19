//! Keyframes (`motion.keyframes`), after mygo's: timed values played in
//! turn, each segment along the easing of the frame it arrives at, holding
//! the last; played again when `Options.run` changes, from the value shown.
//!
//!     const x = ui.motion.keyframes(c, id, "shake", &.{
//!         .{ .value = 0 },
//!         .{ .at = 0.2, .value = 100, .ease = .ease_out },
//!         .{ .at = 0.7, .value = 40 },
//!         .{ .at = 1, .value = 0, .ease = .ease_in_out },
//!     }, .{ .run = s.shakes });
const std = @import("std");
const curve = @import("motion_curve.zig");
const store = @import("motion_store.zig");
const Context = @import("context.zig").Context;

pub const Keyframe = struct {
    /// Seconds from the start: the first 0, then increasing.
    at: f32 = 0,
    value: f32,
    /// How the segment arriving here eases.
    ease: curve.Easing = .linear,
};

/// Plays for ever.
pub const forever: i32 = -1;

pub const Options = struct {
    /// Change it to play again (or a changed sequence).
    run: u64 = 0,
    /// How many more times it plays after the first (`forever`).
    repeat: i32 = 0,
    /// Every other time backward.
    alternate: bool = false,
    /// Seconds it holds its first value before it plays, and where it got
    /// to between plays.
    delay: f32 = 0,
    repeat_delay: f32 = 0,
};

pub const State = struct {
    run: u64,
    start: f64,
    /// The first value the first time through: what was shown when it
    /// started again.
    from: f32,
    value: f32,
    done: bool = false,
    rested: u64 = std.math.maxInt(u64),
    frame: u64 = 0,
};

/// Where a play of `d` seconds is after `raw` seconds, repeating and
/// alternating as asked; which time through; and whether it is done.
pub fn playhead(raw: f64, d: f64, repeat: i32, alternate: bool, repeat_delay: f64) struct { f64, i64, bool } {
    if (raw <= 0) return .{ 0, 0, false };
    if (d <= 0) return .{ raw, 0, false };
    const plays: i64 = if (repeat == forever) 0 else @as(i64, repeat) + 1;
    const period = @max(d + repeat_delay, d);
    const iteration: i64 = @intFromFloat(@floor(raw / period));
    const rest = raw - @as(f64, @floatFromInt(iteration)) * period;
    if (repeat != forever and (iteration >= plays or (iteration == plays - 1 and rest >= d))) {
        if (alternate and @mod(plays, 2) == 0) return .{ 0, iteration, true };
        return .{ d, iteration, true };
    }
    var at = @min(rest, d);
    if (alternate and @mod(iteration, 2) == 1) at = d - at;
    return .{ at, iteration, false };
}

fn final(frames: []const Keyframe, o: Options) f32 {
    const plays: i64 = if (o.repeat == forever) 0 else @as(i64, o.repeat) + 1;
    if (o.alternate and plays != 0 and @mod(plays, 2) == 0) return frames[0].value;
    return frames[frames.len - 1].value;
}

fn sample(s: *const State, frames: []const Keyframe, o: Options, now: f64) struct { f32, bool } {
    if (s.done) return .{ s.value, true };
    const elapsed = now - s.start;
    if (elapsed < 0) return .{ s.from, false };
    const d: f64 = frames[frames.len - 1].at;
    const p = playhead(elapsed, d, o.repeat, o.alternate, o.repeat_delay);
    if (p[2]) return .{ final(frames, o), true };
    for (frames[1..], 1..) |b, i| {
        if (p[0] > b.at) continue;
        var a = frames[i - 1];
        if (i == 1 and p[1] == 0) a.value = s.from;
        const t: f32 = @floatCast((p[0] - a.at) / (b.at - a.at));
        return .{ a.value + (b.value - a.value) * b.ease.at(t), false };
    }
    return .{ final(frames, o), false };
}

/// Plays `frames` (at least two, from 0, times increasing) as value `key`
/// of box `id`; returns the value to show this frame.
pub fn play(c: *Context, id: u64, key: []const u8, frames: []const Keyframe, o: Options) f32 {
    if (frames.len == 0) return 0;
    if (frames.len < 2) return frames[0].value;
    c.motion.sweep(c.gpa, c.frame);
    const gop = c.motion.sequences.getOrPut(c.gpa, store.keyOf(id, key)) catch return frames[0].value;
    if (!gop.found_existing or gop.value_ptr.run != o.run) {
        const from = if (gop.found_existing) sample(gop.value_ptr, frames, o, c.time)[0] else frames[0].value;
        gop.value_ptr.* = .{ .run = o.run, .start = c.time + o.delay, .from = from, .value = from };
    }
    const s = gop.value_ptr;
    s.frame = c.frame;
    if (s.done) return s.value;
    if (@import("motion.zig").reduced(c)) {
        s.value = final(frames, o);
        s.done = true;
        s.rested = c.frame;
        return s.value;
    }
    const r = sample(s, frames, o, c.time);
    s.value = r[0];
    s.done = r[1];
    if (s.done) s.rested = c.frame else c.animationFrame();
    return s.value;
}

/// Whether the keyframes `key` of box `id` are done (true for unknown).
pub fn done(c: *Context, id: u64, key: []const u8) bool {
    const s = c.motion.sequences.getPtr(store.keyOf(id, key)) orelse return true;
    return s.done;
}

test "the playhead repeats, alternates and holds" {
    const p = playhead(2.5, 1, 2, true, 0);
    try std.testing.expectEqual(@as(i64, 2), p[1]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), p[0], 1e-9);
    try std.testing.expect(playhead(3.5, 1, 2, false, 0)[2]);
    // Alternating an even number of plays ends where it started.
    try std.testing.expectEqual(@as(f64, 0), playhead(9, 1, 1, true, 0)[0]);
    try std.testing.expect(!playhead(1e6, 1, forever, false, 0)[2]);
}
