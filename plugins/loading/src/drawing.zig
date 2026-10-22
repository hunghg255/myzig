//! Canvas primitives and CSS timing used by the loading.dev indicators.
const std = @import("std");
const ui = @import("myzig").ui;
pub const pi: f32 = std.math.pi;
pub const tau = 2 * pi;
pub const Easing = enum { linear, ease_in_out, stacked };
pub const Cap = enum { round, flat };
pub const Options = struct {
    color: ui.Color,
    easing: Easing = .linear,
    cap: Cap = .round,
    still: bool = false,
    sweep: @import("loading.zig").Sweep = .diagonal,
    direction: @import("loading.zig").Direction = .out,
    origin: @import("loading.zig").Origin = .center,
};

pub const Drawing = struct {
    p: *ui.Painter,
    cycles: f64,
    o: Options,

    pub fn at(d: Drawing, step: usize, count: usize) f32 {
        const t = d.cycles + if (count == 0) @as(f64, 0) else @as(f64, @floatFromInt(count - step)) / @as(f64, @floatFromInt(count));
        return @floatCast(t - @floor(t));
    }

    pub fn turn(d: Drawing, p: f32) f32 {
        return switch (d.o.easing) {
            .linear => p,
            .ease_in_out => ease(p),
            .stacked => p + ease(p),
        };
    }

    pub fn spin(d: Drawing, reverse: bool, rest: f32) f32 {
        if (d.o.still) return rest;
        const p = d.at(0, 0);
        return d.turn(if (reverse) 1 - p else p) * tau;
    }

    pub fn color(d: Drawing, a: f32) ui.Color {
        return d.o.color.alpha(std.math.clamp(a, 0, 1));
    }

    pub fn fade(d: Drawing, i: usize, n: usize, dim: f32, rest: f32) f32 {
        return if (d.o.still) rest else 1 + (dim - 1) * d.at(i, n);
    }

    pub fn dot(d: Drawing, x: f32, y: f32, r: f32, a: f32) void {
        if (r > 0 and a > 0) d.p.fillCircle(x, y, r, .color(d.color(a)));
    }

    pub fn box(d: Drawing, x: f32, y: f32, w: f32, h: f32, r: f32, a: f32) void {
        if (w > 0 and h > 0 and a > 0)
            d.p.fillRoundRect(.{ .x = x, .y = y, .w = w, .h = h }, r, .color(d.color(a)));
    }

    pub fn hoop(d: Drawing, x: f32, y: f32, r: f32, width: f32, a: f32) void {
        if (r > 0 and width > 0 and a > 0)
            d.p.strokeCircle(x, y, r - width / 2, width, d.color(a));
    }

    pub fn arc(d: Drawing, x: f32, y: f32, r: f32, width: f32, a0: f32, a1: f32, opacity: f32) void {
        if (a1 <= a0) return;
        var path = d.p.path();
        path.arc(x, y, r, a0, a1, false);
        d.p.stroke(&path, .color(d.color(opacity)), .{ .width = width, .cap = if (d.o.cap == .round) .round else .butt });
    }

    pub fn capsule(d: Drawing, x0: f32, y0: f32, x1: f32, y1: f32, w: f32, a: f32) void {
        var path = d.p.path();
        path.moveTo(x0, y0);
        path.lineTo(x1, y1);
        d.p.stroke(&path, .color(d.color(a)), .{ .width = w, .cap = .round });
    }

    pub fn rotate(d: Drawing, a: f32, x: f32, y: f32) void {
        d.p.save();
        d.p.rotate(a, x, y);
    }

    pub fn scale(d: Drawing, x: f32, y: f32, cx: f32, cy: f32) void {
        d.p.save();
        d.p.translate(cx, cy);
        d.p.scaleBy(x, y);
        d.p.translate(-cx, -cy);
    }

    /// Conic gradients are not canvas paints in myzig: tessellate the ring
    /// into short sectors, with shared edges and a continuously fading tail.
    pub fn tail(d: Drawing, r: f32, w: f32, angle: f32, sweep: f32) void {
        const n = 128;
        for (0..n) |i| {
            const a = angle + f(i) / n * sweep;
            var path = d.p.path();
            path.arc(12, 12, r, a, a + sweep / n, false);
            path.arc(12, 12, r - w, a + sweep / n, a, true);
            path.close();
            d.p.fill(&path, .color(d.color((f(i) + 0.5) / n)));
        }
    }
};

pub fn f(i: usize) f32 {
    return @floatFromInt(i);
}

/// CSS cubic-bezier: invert its x coordinate before evaluating y.
pub fn bezier(t: f32, x1: f32, y1: f32, x2: f32, y2: f32) f32 {
    if (t <= 0 or t >= 1) return t;
    var lo: f32 = 0;
    var hi: f32 = 1;
    for (0..30) |_| {
        const s = (lo + hi) / 2;
        const x = 3 * (1 - s) * (1 - s) * s * x1 + 3 * (1 - s) * s * s * x2 + s * s * s;
        if (x < t) lo = s else hi = s;
    }
    const s = (lo + hi) / 2;
    return 3 * (1 - s) * (1 - s) * s * y1 + 3 * (1 - s) * s * s * y2 + s * s * s;
}

pub fn ease(t: f32) f32 {
    return bezier(t, 0.42, 0, 0.58, 1);
}
pub fn easeOut(t: f32) f32 {
    return bezier(t, 0, 0, 0.58, 1);
}
pub const Key = struct { f32, f32 };
pub fn frames(t: f32, timing: *const fn (f32) f32, keys: []const Key) f32 {
    std.debug.assert(keys.len >= 2);
    for (keys[1..], 1..) |b, i| {
        const a = keys[i - 1];
        if (t <= b[0]) return a[1] + (b[1] - a[1]) * timing((t - a[0]) / (b[0] - a[0]));
    }
    return keys[keys.len - 1][1];
}

pub fn linear(t: f32) f32 {
    return t;
}

test "CSS easing and staggered phases" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), ease(0.5), 0.00001);
    try std.testing.expect(easeOut(0.5) > 0.5);
    const d: Drawing = .{ .p = undefined, .cycles = 0.25, .o = .{ .color = .hex(0xffffff) } };
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), d.at(0, 3), 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 11.0 / 12.0), d.at(1, 3), 0.00001);
}
