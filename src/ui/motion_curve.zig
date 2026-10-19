//! How animated values move, after mygo's `ui.Animation`: along an easing
//! curve for a duration, or with a spring, solved exactly (a slow frame
//! does not change its path) and keeping its velocity when its target
//! changes on the way. A `Channel` is one value moving; `motion.zig` keeps
//! them by box and key.
const std = @import("std");

/// Maps the time a curve has run, from 0 to 1 of its duration, to how far
/// its value has gone, as CSS's timing functions do.
pub const Easing = union(enum) {
    linear,
    /// Cubics: slowly at the start, at the end, or both.
    ease_in,
    ease_out,
    ease_in_out,
    /// Lands as a dropped ball does, bouncing three times (easings.net's
    /// easeOutBounce); `bounce_in` the same backward in time.
    bounce,
    bounce_in,
    /// Overshoots and settles with a decaying spring (easeOutElastic);
    /// `elastic_in` winds up before it goes.
    elastic,
    elastic_in,
    /// CSS's cubic-bezier(x1, y1, x2, y2), x1 and x2 within 0 and 1.
    cubic: [4]f32,
    /// Your own.
    custom: *const fn (t: f32) f32,

    pub fn cubicBezier(x1: f32, y1: f32, x2: f32, y2: f32) Easing {
        return .{ .cubic = .{ std.math.clamp(x1, 0, 1), y1, std.math.clamp(x2, 0, 1), y2 } };
    }

    pub fn at(e: Easing, t: f32) f32 {
        return switch (e) {
            .linear => t,
            .ease_in => t * t * t,
            .ease_out => blk: {
                const u = 1 - t;
                break :blk 1 - u * u * u;
            },
            .ease_in_out => if (t < 0.5) 4 * t * t * t else blk: {
                const u = 2 - 2 * t;
                break :blk 1 - u * u * u / 2;
            },
            .bounce => bounceOut(t),
            .bounce_in => 1 - bounceOut(1 - t),
            .elastic => elasticOut(t),
            .elastic_in => 1 - elasticOut(1 - t),
            .cubic => |p| bezier(p, t),
            .custom => |f| f(t),
        };
    }

    /// An easing that goes along `ease` and comes back in the same time, as
    /// a pulse does (mygo's Bounce): for loops.
    pub fn pulse(comptime ease: Easing) Easing {
        return .{ .custom = struct {
            fn f(t: f32) f32 {
                return if (t < 0.5) ease.at(2 * t) else ease.at(2 - 2 * t);
            }
        }.f };
    }
};

fn bounceOut(t: f32) f32 {
    const n: f32 = 7.5625;
    const d: f32 = 2.75;
    if (t < 1 / d) return n * t * t;
    if (t < 2 / d) {
        const u = t - 1.5 / d;
        return n * u * u + 0.75;
    }
    if (t < 2.5 / d) {
        const u = t - 2.25 / d;
        return n * u * u + 0.9375;
    }
    const u = t - 2.625 / d;
    return n * u * u + 0.984375;
}

fn elasticOut(t: f32) f32 {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    return std.math.pow(f32, 2, -10 * t) * @sin((t * 10 - 0.75) * (2.0 * std.math.pi / 3.0)) + 1;
}

test "bounce and elastic easings start at 0, end at 1; bounce stays within, elastic overshoots" {
    for ([_]Easing{ .bounce, .bounce_in, .elastic, .elastic_in, Easing.pulse(.ease_out) }) |e| {
        try std.testing.expectApproxEqAbs(@as(f32, 0), e.at(0), 1e-4);
        if (e != .custom) try std.testing.expectApproxEqAbs(@as(f32, 1), e.at(1), 1e-4);
    }
    var over = false;
    var t: f32 = 0;
    while (t <= 1) : (t += 0.01) {
        const b = Easing.at(.bounce, t);
        try std.testing.expect(b >= -1e-4 and b <= 1 + 1e-4);
        if (Easing.at(.elastic, t) > 1.01) over = true;
    }
    try std.testing.expect(over);
    // The ball touches the ground between bounces.
    try std.testing.expectApproxEqAbs(@as(f32, 1), Easing.at(.bounce, 1.0 / 2.75), 1e-4);
    // A pulse is at its peak halfway, and back at the end.
    try std.testing.expectApproxEqAbs(@as(f32, 1), Easing.pulse(.ease_out).at(0.5), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), Easing.pulse(.ease_out).at(1), 1e-4);
}

/// The y of CSS's cubic Bézier easing at x: Newton's method, then
/// bisection where the slope is too flat.
fn bezier(p: [4]f32, x_in: f32) f32 {
    if (x_in <= 0 or x_in >= 1) return x_in;
    const cx: f64 = 3 * @as(f64, p[0]);
    const bx: f64 = 3 * @as(f64, p[2] - p[0]) - cx;
    const ax: f64 = 1 - cx - bx;
    const cy: f64 = 3 * @as(f64, p[1]);
    const by: f64 = 3 * @as(f64, p[3] - p[1]) - cy;
    const ay: f64 = 1 - cy - by;
    const x: f64 = x_in;
    const curve = struct {
        fn f(a: f64, b: f64, c: f64, t: f64) f64 {
            return ((a * t + b) * t + c) * t;
        }
    }.f;
    var t = x;
    for (0..8) |_| {
        const dx = (3 * ax * t + 2 * bx) * t + cx;
        if (@abs(dx) < 1e-6) break;
        const e = curve(ax, bx, cx, t) - x;
        if (@abs(e) < 1e-7) return @floatCast(curve(ay, by, cy, t));
        t -= e / dx;
    }
    var lo: f64 = 0;
    var hi: f64 = 1;
    t = x;
    for (0..40) |_| {
        const v = curve(ax, bx, cx, t);
        if (@abs(v - x) < 1e-7) break;
        if (v < x) lo = t else hi = t;
        t = (lo + hi) / 2;
    }
    return @floatCast(curve(ay, by, cy, t));
}

/// A spring as one perceives it, SwiftUI's and Motion's way: `duration`
/// (seconds) about how long it takes to arrive and `bounce`, from 0 (no
/// overshoot) toward 1; or physically, when `stiffness` or `damping` is
/// set (react-spring's 170 and 26 by default).
pub const Spring = struct {
    duration: f32 = 0.5,
    bounce: f32 = 0,
    stiffness: ?f32 = null,
    damping: ?f32 = null,
    mass: f32 = 1,
    /// How close to its target, in the value's units, it rests there.
    precision: f32 = 0.001,
    /// The velocity the value takes when its target changes (a throw's).
    velocity: ?f32 = null,

    /// Mass, stiffness and damping.
    pub fn physics(s: Spring) [3]f64 {
        const m: f64 = if (s.mass > 0) s.mass else 1;
        if (s.stiffness != null or s.damping != null) {
            return .{ m, @max(s.stiffness orelse 170, 1e-3), @max(s.damping orelse 26, 1e-3) };
        }
        // SwiftUI's: the undamped period is the duration, the damping
        // ratio 1 - bounce (1 / (1 + bounce) below 0).
        const d: f64 = if (s.duration > 0) s.duration else 0.5;
        const b: f64 = std.math.clamp(s.bounce, -0.99, 0.99);
        const w = 2 * std.math.pi / d;
        const ratio = if (b < 0) 1 / (1 + b) else 1 - b;
        return .{ m, w * w * m, 2 * ratio * w * m };
    }
};

/// How a value goes to a new target: a curve of `duration` seconds along
/// `ease`, or, with a duration of 0, `spring`. `delay` keeps the value
/// going as it was for a while after its target changes.
pub const Animation = struct {
    duration: f32 = 0,
    ease: Easing = .ease_out,
    spring: Spring = .{},
    delay: f32 = 0,

    /// SwiftUI's springs: no bounce, a little, a visible one.
    pub const smooth: Animation = .{};
    pub const snappy: Animation = .{ .spring = .{ .bounce = 0.15 } };
    pub const bouncy: Animation = .{ .spring = .{ .bounce = 0.3 } };

    pub fn curve(seconds: f32, ease: Easing) Animation {
        return .{ .duration = seconds, .ease = ease };
    }
};

/// Where a damped spring at `x` from its rest, going at `v`, is after `dt`
/// seconds, and its velocity: solved exactly.
pub fn solveSpring(x: f64, v: f64, m: f64, k: f64, c: f64, dt: f64) [2]f64 {
    if (x == 0 and v == 0) return .{ 0, 0 };
    const w = @sqrt(k / m);
    const a = (c / m) / 2;
    const d = a * a - w * w;
    if (@abs(d) < 1e-8 * w * w) {
        const b = v + a * x;
        const decay = @exp(-a * dt);
        return .{ (x + b * dt) * decay, (v - a * b * dt) * decay };
    }
    if (d < 0) {
        const f = @sqrt(-d);
        const sn = @sin(f * dt);
        const cs = @cos(f * dt);
        const b = (v + a * x) / f;
        const decay = @exp(-a * dt);
        const y = x * cs + b * sn;
        return .{ y * decay, (f * (-x * sn + b * cs) - a * y) * decay };
    }
    const f = @sqrt(d);
    const r1 = -w * w / (a + f);
    const r2 = -a - f;
    const c1 = (v - r2 * x) / (r1 - r2);
    const c2 = x - c1;
    const u = c1 * @exp(r1 * dt);
    const z = c2 * @exp(r2 * dt);
    return .{ u + z, r1 * u + r2 * z };
}

/// One value moving toward its target, at time `at` (seconds of the
/// context's clock).
pub const Channel = struct {
    value: f64,
    velocity: f64 = 0,
    target: f64,
    at: f64,
    moving: bool = false,
    // A spring's.
    m: f64 = 1,
    k: f64 = 170,
    c: f64 = 26,
    eps: f64 = 0.001,
    // A curve's: from `from` at `start`, for `duration`.
    curve: bool = false,
    from: f64 = 0,
    start: f64 = 0,
    duration: f64 = 0,
    ease: Easing = .ease_out,
    // A target taken after a delay: when, and how.
    pending: bool = false,
    pending_to: f64 = 0,
    pending_at: f64 = 0,
    pending_anim: Animation = .{},
    /// The frame it came to rest in, after moving.
    rested: u64 = std.math.maxInt(u64),
    /// The frame it was last asked for (unused ones are forgotten).
    frame: u64 = 0,
    jumped: bool = false,

    pub fn init(value: f64, now: f64) Channel {
        return .{ .value = value, .target = value, .at = now };
    }

    /// Where it is headed: the target it takes after a delay, or its target.
    pub fn goal(ch: *const Channel) f64 {
        return if (ch.pending) ch.pending_to else ch.target;
    }

    /// Heads for `target` from where it is, as `a` says.
    pub fn retarget(ch: *Channel, target: f64, a: Animation) void {
        ch.target = target;
        ch.moving = true;
        ch.jumped = false;
        if (a.duration > 0) {
            ch.curve = true;
            ch.from = ch.value;
            ch.start = ch.at;
            ch.duration = a.duration;
            ch.ease = a.ease;
            return;
        }
        ch.curve = false;
        const p = a.spring.physics();
        ch.m = p[0];
        ch.k = p[1];
        ch.c = p[2];
        ch.eps = if (a.spring.precision > 0) a.spring.precision else 0.001;
        if (a.spring.velocity) |v| ch.velocity = v;
    }

    /// Moves it to `now`, heading for a pending target once its delay is over.
    pub fn advance(ch: *Channel, now: f64) void {
        if (ch.pending and now >= ch.pending_at) {
            ch.step(ch.pending_at);
            ch.pending = false;
            ch.retarget(ch.pending_to, ch.pending_anim);
        }
        ch.step(now);
    }

    fn step(ch: *Channel, now: f64) void {
        const dt = now - ch.at;
        if (dt <= 0) {
            ch.at = now;
            return;
        }
        ch.at = now;
        const jumped = ch.jumped;
        ch.jumped = false;
        if (!ch.moving) {
            // A value a drag jumped keeps going as it did for a moment,
            // for a spring to take over.
            if (!jumped or dt > 0.1) ch.velocity = 0;
            return;
        }
        if (ch.curve) {
            const t = (now - ch.start) / ch.duration;
            if (t >= 1) {
                ch.value = ch.target;
                ch.velocity = 0;
                ch.moving = false;
                return;
            }
            const tc = @max(t, 0);
            const span = ch.target - ch.from;
            ch.value = ch.from + span * ch.ease.at(@floatCast(tc));
            // The easing's slope, for a spring taking over.
            const h = 1e-3;
            const lo = @max(tc - h, 0);
            const hi = @min(tc + h, 1);
            ch.velocity = span * (ch.ease.at(@floatCast(hi)) - ch.ease.at(@floatCast(lo))) / (hi - lo) / ch.duration;
            return;
        }
        const s = solveSpring(ch.value - ch.target, ch.velocity, ch.m, ch.k, ch.c, dt);
        ch.value = ch.target + s[0];
        ch.velocity = s[1];
        if (@abs(s[0]) <= ch.eps and @abs(s[1]) <= ch.eps * @sqrt(ch.k / ch.m)) {
            ch.value = ch.target;
            ch.velocity = 0;
            ch.moving = false;
        }
    }
};

const testing = std.testing;

test "easings: CSS's cubic Bézier, and the cubics" {
    try testing.expect(Easing.at(.ease_in, 0.5) < 0.5 and Easing.at(.ease_out, 0.5) > 0.5);
    try testing.expectEqual(@as(f32, 0.5), Easing.at(.ease_in_out, 0.5));
    // CSS's ease (0.25, 0.1, 0.25, 1) at x = 0.5 is about 0.8024.
    try testing.expectApproxEqAbs(@as(f32, 0.8024), Easing.at(.cubicBezier(0.25, 0.1, 0.25, 1), 0.5), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.5), Easing.at(.cubicBezier(0, 0, 1, 1), 0.5), 1e-4);
}

test "a spring is solved exactly, whatever the frames, and keeps its velocity" {
    var a = Channel.init(0, 0);
    var b = Channel.init(0, 0);
    a.retarget(100, .snappy);
    b.retarget(100, .snappy);
    // One in 60 frames a second, one in two big steps.
    for (1..31) |i| a.advance(@as(f64, @floatFromInt(i)) / 60);
    b.advance(0.2);
    b.advance(0.5);
    try testing.expectApproxEqAbs(a.value, b.value, 1e-6);
    // Snappy overshoots a little, then rests at its target.
    var peak: f64 = 0;
    var t: f64 = 0.5;
    while (t < 3) : (t += 1.0 / 60.0) {
        a.advance(t);
        peak = @max(peak, a.value);
    }
    try testing.expect(peak > 100 and peak < 110);
    try testing.expect(!a.moving and a.value == 100);
    // Turned around on the way, it keeps going for a while.
    var c = Channel.init(0, 0);
    c.retarget(100, .smooth);
    c.advance(0.1);
    const v = c.velocity;
    c.retarget(0, .smooth);
    c.advance(0.1 + 1.0 / 60.0);
    try testing.expect(v > 0 and c.velocity > 0);
}
