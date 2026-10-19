//! What a run does, step by step, the same on every platform: the events
//! it injects and the pauses between them, as mygo's tool does. Typing:
//! a key every 60 to 140 ms (each frame after a pause). Scrolling: a
//! trackpad's gestures of 60 events, one every 4 to 12 ms, then a pause.
//! Dragging: a press, 60 moves of 3 points (30 right, 30 back), one every
//! 4 to 12 ms, a release, a pause. The animations inject nothing: their
//! warmup and events count refreshes. Pauses are drawn from a seeded
//! generator, so runs differ in phase against the display, and tests see
//! the same plan every time.
const std = @import("std");

pub const Mode = enum {
    type,
    scroll,
    drag,
    anim,
    heavy,

    /// Whether the mode's runs inject input (not the animations).
    pub fn input(m: Mode) bool {
        return m != .anim and m != .heavy;
    }
};

pub const Action = union(enum) {
    /// A key typed ("a"): down and up.
    key,
    /// A trackpad's gesture: its start, a step of `dy` points, its end.
    scroll_begin,
    scroll: f32,
    scroll_end,
    /// The left button down at the box, the pointer dragged by `dx`
    /// points, the button up.
    down,
    drag: f32,
    up,
};

pub const Step = struct {
    action: Action,
    /// Measured: the run starts measuring before the first.
    measured: bool,
    /// Whether the event is timed (handled, then shown); gestures' starts
    /// and ends, the press and the release are not.
    timed: bool,
    /// The pause after it, in milliseconds.
    wait_ms: f64,
};

pub const Plan = struct {
    mode: Mode,
    warmup: usize,
    events: usize,
    prng: std.Random.DefaultPrng,
    /// Timed events so far.
    n: usize = 0,
    /// The gesture's state: its timed events so far, or null between them.
    in_gesture: ?usize = null,
    ended: bool = false,

    pub const gesture = 60;

    pub fn init(mode: Mode, warmup: usize, events: usize, seed: u64) Plan {
        return .{ .mode = mode, .warmup = warmup, .events = events, .prng = .init(seed) };
    }

    fn between(p: *Plan, lo: f64, hi: f64) f64 {
        return lo + p.prng.random().float(f64) * (hi - lo);
    }

    fn timed(p: *Plan, action: Action, wait_ms: f64) Step {
        p.n += 1;
        return .{ .action = action, .measured = p.n > p.warmup, .timed = true, .wait_ms = wait_ms };
    }

    fn untimed(p: *Plan, action: Action, wait_ms: f64) Step {
        return .{ .action = action, .measured = p.n >= p.warmup, .timed = false, .wait_ms = wait_ms };
    }

    /// The next step, or null once the run injected all it measures.
    pub fn next(p: *Plan) ?Step {
        if (p.ended or !p.mode.input()) return null;
        const total = p.warmup + p.events;
        switch (p.mode) {
            .type => {
                if (p.n >= total) return null;
                return p.timed(.key, p.between(60, 140));
            },
            .scroll, .drag => {
                const begin: Action = if (p.mode == .scroll) .scroll_begin else .down;
                const end: Action = if (p.mode == .scroll) .scroll_end else .up;
                const k = p.in_gesture orelse {
                    if (p.n >= total) return null;
                    p.in_gesture = 0;
                    return p.untimed(begin, if (p.mode == .drag) 50 else 0);
                };
                if (k == gesture or p.n >= total) {
                    p.in_gesture = null;
                    if (p.n >= total) p.ended = true;
                    return p.untimed(end, 300);
                }
                p.in_gesture = k + 1;
                const step: Action = if (p.mode == .scroll) .{ .scroll = -3 } else .{ .drag = if (k < gesture / 2) 3 else -3 };
                return p.timed(step, p.between(4, 12));
            },
            .anim, .heavy => unreachable,
        }
    }
};

const t = std.testing;

test "typing: a key every 60 to 140 ms, the first after the warmup measured" {
    var p: Plan = .init(.type, 3, 5, 1);
    var keys: usize = 0;
    var unmeasured: usize = 0;
    while (p.next()) |s| {
        try t.expect(s.action == .key and s.timed);
        try t.expect(s.wait_ms >= 60 and s.wait_ms <= 140);
        keys += 1;
        if (!s.measured) unmeasured += 1;
    }
    try t.expectEqual(@as(usize, 8), keys);
    try t.expectEqual(@as(usize, 3), unmeasured);
}

test "scrolling: gestures of 60 steps between their start and end" {
    var p: Plan = .init(.scroll, 10, 100, 7);
    var steps: std.ArrayList(Step) = .empty;
    defer steps.deinit(t.allocator);
    while (p.next()) |s| try steps.append(t.allocator, s);
    var timed: usize = 0;
    var gestures: usize = 0;
    var run: usize = 0;
    for (steps.items) |s| switch (s.action) {
        .scroll_begin => {
            gestures += 1;
            run = 0;
        },
        .scroll => |dy| {
            try t.expectEqual(@as(f32, -3), dy);
            try t.expect(s.wait_ms >= 4 and s.wait_ms <= 12);
            run += 1;
            timed += 1;
            try t.expect(run <= Plan.gesture);
        },
        .scroll_end => try t.expectEqual(@as(f64, 300), s.wait_ms),
        else => return error.UnexpectedAction,
    };
    try t.expectEqual(@as(usize, 110), timed);
    try t.expectEqual(@as(usize, 2), gestures);
    try t.expect(steps.items[0].action == .scroll_begin and !steps.items[0].measured);
    try t.expect(steps.items[steps.items.len - 1].action == .scroll_end);
}

test "dragging: right then back, between a press and a release" {
    var p: Plan = .init(.drag, 0, 60, 3);
    try t.expect(p.next().?.action == .down);
    var x: f32 = 0;
    var furthest: f32 = 0;
    var n: usize = 0;
    while (p.next()) |s| switch (s.action) {
        .drag => |dx| {
            try t.expect(s.measured and s.timed);
            x += dx;
            furthest = @max(furthest, x);
            n += 1;
        },
        .up => break,
        else => return error.UnexpectedAction,
    };
    try t.expectEqual(@as(usize, 60), n);
    try t.expectEqual(@as(f32, 90), furthest);
    try t.expectEqual(@as(f32, 0), x);
    try t.expect(p.next() == null);
}

test "animations inject nothing; the same seed, the same plan" {
    var a: Plan = .init(.anim, 30, 300, 1);
    try t.expect(a.next() == null);
    var p1: Plan = .init(.type, 0, 4, 42);
    var p2: Plan = .init(.type, 0, 4, 42);
    while (p1.next()) |s| try t.expectEqual(s.wait_ms, p2.next().?.wait_ms);
}
