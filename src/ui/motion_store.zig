//! What animates across frames (`motion.zig`): values, colors, keyframes,
//! timelines and boxes' transitions, by box and key, each forgotten a while
//! after the view stops asking for it. A context keeps one
//! (`Context.motion`).
const std = @import("std");
const curve = @import("motion_curve.zig");
const keyframes = @import("motion_keyframes.zig");
const timeline = @import("motion_timeline.zig");
const transition = @import("motion_transition.zig");

/// A color animating (`motion.animateColor`): from, to, and as shown.
pub const ColorState = struct {
    from: @import("types.zig").Color,
    to: @import("types.zig").Color,
    now: @import("types.zig").Color,
    frame: u64 = 0,
};

/// Frames a thing not asked for is kept.
const keep_frames = 120;

pub const Store = struct {
    channels: std.AutoHashMapUnmanaged(u64, curve.Channel) = .empty,
    colors: std.AutoHashMapUnmanaged(u64, ColorState) = .empty,
    sequences: std.AutoHashMapUnmanaged(u64, keyframes.State) = .empty,
    timelines: std.AutoHashMapUnmanaged(u64, timeline.State) = .empty,
    /// Boxes with transitions, by id.
    boxes: std.AutoHashMapUnmanaged(u64, transition.Record) = .empty,
    /// How many of those move with the layout (`position`), and how many
    /// are going (their copy drawn to its exit): paint looks for them only
    /// while there are some.
    moving_boxes: usize = 0,
    exiting: usize = 0,
    /// The app's say on less motion, over the desktop's.
    reduce: ?bool = null,
    /// The desktop's, asked once.
    system: ?bool = null,
    /// The frame `disableAnimations` was called in.
    instant: u64 = std.math.maxInt(u64),
    swept: u64 = 0,

    pub fn deinit(s: *Store, gpa: std.mem.Allocator) void {
        var it = s.boxes.valueIterator();
        while (it.next()) |r| r.deinit(gpa);
        s.boxes.deinit(gpa);
        s.channels.deinit(gpa);
        s.colors.deinit(gpa);
        s.sequences.deinit(gpa);
        s.timelines.deinit(gpa);
        s.* = .{};
    }

    /// Forgets, now and then, what was not asked for in a while.
    pub fn sweep(s: *Store, gpa: std.mem.Allocator, frame: u64) void {
        if (frame < s.swept + keep_frames) return;
        s.swept = frame;
        drop(curve.Channel, &s.channels, frame);
        drop(ColorState, &s.colors, frame);
        drop(keyframes.State, &s.sequences, frame);
        drop(timeline.State, &s.timelines, frame);
        var stale: [64]u64 = undefined;
        var n: usize = 0;
        var it = s.boxes.iterator();
        while (it.next()) |e| {
            if (n == stale.len) break;
            if (frame > e.value_ptr.frame + keep_frames and !e.value_ptr.exiting) {
                stale[n] = e.key_ptr.*;
                n += 1;
            }
        }
        for (stale[0..n]) |k| if (s.boxes.fetchRemove(k)) |kv| {
            var r = kv.value;
            if (r.position) s.moving_boxes -|= 1;
            r.deinit(gpa);
        };
    }
};

fn drop(comptime T: type, map: *std.AutoHashMapUnmanaged(u64, T), frame: u64) void {
    var stale: [64]u64 = undefined;
    var n: usize = 0;
    var it = map.iterator();
    while (it.next()) |e| {
        if (n == stale.len) break;
        if (frame > e.value_ptr.frame + keep_frames) {
            stale[n] = e.key_ptr.*;
            n += 1;
        }
    }
    for (stale[0..n]) |k| _ = map.remove(k);
}

/// The key of `key` of box `id`.
pub fn keyOf(id: u64, key: []const u8) u64 {
    var h = std.hash.Wyhash.init(id);
    h.update(key);
    return h.final();
}
