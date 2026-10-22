//! The second half of the gallery: dots, rings and a tracing square.
const ui = @import("myzig").ui;
const g = @import("drawing.zig");
const Drawing = g.Drawing;
const pi = g.pi;
const tau = g.tau;
const f = g.f;
const ease = g.ease;
const frames = g.frames;

pub fn draw(index: usize, d: Drawing) void {
    switch (index) {
        15 => leap(d),
        16 => linearDots(d),
        17 => mark(d),
        18 => morph(d),
        19 => {
            d.dot(12, 12, 3, 1);
            d.tail(10.08, 1.5, d.spin(false, 0) + pi / 2, pi);
        },
        20 => {
            const e = g.easeOut(d.at(0, 0));
            d.dot(12, 12, 12 * (if (d.o.still) @as(f32, 1) else 0.25 + 0.75 * e), if (d.o.still) 0.2 else 0.4 * (1 - e));
            d.dot(12, 12, 3, 1);
        },
        21 => radar(d),
        22 => {
            d.hoop(12, 12, 11.25, 2.5, 0.2);
            const a = d.spin(false, 0);
            d.arc(12, 12, 10, 2.5, a, a + 1.6, 1);
        },
        23 => ripple(d),
        24 => slide(d),
        25 => snake(d),
        26 => swirl(d),
        27 => trace(d),
        28 => wave(d),
        else => unreachable,
    }
}

fn leap(d: Drawing) void {
    // Round in DIPs, before entering our normalized viewBox, as upstream does.
    const scale = @sqrt(@abs(d.p.ctm.a * d.p.ctm.d - d.p.ctm.b * d.p.ctm.c));
    const dot = @round(0.22 * 24 * scale) / scale;
    const gap = @floor((24 * scale - dot * scale) / 2) / scale;
    const top = @round((24 * scale - dot * scale) / 2) / scale;
    const mx = 24 - dot - gap + dot / 2;
    const my = top + dot / 2;
    for (0..3) |i| {
        const p = d.at(i, 3);
        const x = if (d.o.still) f(i) * gap else frames(p, ease, &.{ .{ 0, 0 }, .{ 0.3333, 0 }, .{ 0.6666, -gap }, .{ 1, -2 * gap } });
        const a = if (d.o.still) 0 else frames(p, ease, &.{ .{ 0, 0 }, .{ 0.3333, pi }, .{ 0.6666, pi }, .{ 1, pi } });
        d.dot(mx + x + gap * @cos(a + pi), my + gap * @sin(a + pi), dot / 2, 1);
    }
}

fn linearDots(d: Drawing) void {
    for (0..3) |i| {
        const a = if (d.o.still) 0.75 else frames(d.at(i, 3), g.linear, &.{ .{ 0, 1 }, .{ 0.6667, 0.5 }, .{ 1, 1 } });
        d.dot(2.25 + f(i) * 9, 12, 2.25, a);
    }
}

fn mark(d: Drawing) void {
    const segments = [_][2]f32{ .{ 12, 6 }, .{ 10, 10 }, .{ 6, 12 }, .{ 2, 10 }, .{ 0, 6 }, .{ 2, 2 }, .{ 6, 0 }, .{ 10, 2 } };
    d.p.save();
    d.p.scaleBy(1.6, 1.6);
    defer d.p.restore();
    for (segments, 0..) |at, i| for (0..4) |j| {
        d.box(at[0] + f(j % 2) * 2, at[1] + f(j / 2) * 2, 1, 1, 0, d.fade(i, 8, 0.2, 0.6));
    };
}

fn morph(d: Drawing) void {
    const p = d.at(0, 0);
    const r = if (d.o.still) 1.92 else frames(p, ease, &.{ .{ 0, 1.92 }, .{ 0.5, 7.68 }, .{ 1, 1.92 } });
    const a = if (d.o.still) 0 else frames(p, ease, &.{ .{ 0, 0 }, .{ 0.5, pi / 4 }, .{ 1, pi / 2 } });
    d.rotate(a, 12, 12);
    defer d.p.restore();
    d.box(4.32, 4.32, 15.36, 15.36, r, 1);
}

fn radar(d: Drawing) void {
    d.dot(12, 12, 12, 0.2);
    d.hoop(12, 12, 9, 1.5, 0.2);
    d.rotate(d.spin(false, 0), 12, 12);
    // Keep the original leading edge. A radial canvas paint gives the
    // original opacity directly rather than layering many translucent bands.
    d.p.scaleBy(1.5, 1.5);
    var path = d.p.path();
    path.moveTo(8, 5);
    path.lineTo(8, 0);
    const end = @import("std").math.atan2(@as(f32, 12.9951 - 8), @as(f32, 14.249 - 8));
    path.arc(8, 8, 8, -pi / 2, end, false);
    path.lineTo(10.4707, 9.69922);
    path.arc(8, 8, 3, @import("std").math.atan2(@as(f32, 9.69922 - 8), @as(f32, 10.4707 - 8)), -pi / 2, true);
    path.close();
    d.p.fill(&path, .{ .radial = .{ .center = .{ 8, 8 }, .radius = 8, .stops = &.{ .{ .offset = 0, .color = d.o.color }, .{ .offset = 0.3334, .color = d.o.color }, .{ .offset = 1, .color = d.color(0) } } } });
    d.p.restore();
    d.dot(12, 12, 3, 1);
}

fn ripple(d: Drawing) void {
    for (0..3) |i| {
        const phase = d.at(i, 3);
        const e = g.easeOut(if (d.o.direction == .in) 1 - phase else phase);
        const k = if (d.o.still) (f(i) + 1) / 3 else e;
        d.hoop(12, 12, 12 * k, 1.92 * k, if (d.o.still) 0.4 else 1 - e);
    }
}

fn slide(d: Drawing) void {
    const far = 1.588 * 8.16;
    const rest = [_][2]f32{ .{ far, 0 }, .{ 0, 0 }, .{ 0, far } };
    for (rest, 0..) |pos, i| {
        const p = d.at(i, 3);
        const x = if (d.o.still) pos[0] else frames(p, ease, &.{ .{ 0, far }, .{ 0.0833, far }, .{ 0.25, far }, .{ 0.3333, 0 }, .{ 0.5, 0 }, .{ 0.5833, 0 }, .{ 0.75, 0 }, .{ 0.8333, far }, .{ 1, far } });
        const y = if (d.o.still) pos[1] else frames(p, ease, &.{ .{ 0, 0 }, .{ 0.0833, far }, .{ 0.25, far }, .{ 0.3333, far }, .{ 0.5, far }, .{ 0.5833, 0 }, .{ 0.75, 0 }, .{ 0.8333, 0 }, .{ 1, 0 } });
        d.dot(5.52 + x, 5.52 + y, 4.08, 1);
    }
}

fn snake(d: Drawing) void {
    const p = d.at(0, 0);
    const dash = if (d.o.still) 18 else frames(p, ease, &.{ .{ 0, 1 }, .{ 0.5, 45 }, .{ 1, 45 } });
    const offset = if (d.o.still) 0 else frames(p, ease, &.{ .{ 0, 0 }, .{ 0.5, -17 }, .{ 1, -62 } });
    var at = @mod(-offset, dash + 100) - (dash + 100);
    const a = d.spin(false, 0);
    while (at < tau * 10) : (at += dash + 100) {
        const from = @max(at, 0);
        const to = @min(at + dash, tau * 10);
        if (to > from) d.arc(12, 12, 10, 2.5, a + from / 10, a + to / 10, 1);
    }
}

fn swirl(d: Drawing) void {
    const steps = [_]?usize{ 0, 1, 2, 7, null, 3, 6, 5, 4 };
    for (steps, 0..) |step, i| {
        if (step) |n| d.box(1.5 + f(i % 3) * 8.25, 1.5 + f(i / 3) * 8.25, 4.5, 4.5, 1.5, d.fade(n, 8, 0.2, 0.6));
    }
}

fn trace(d: Drawing) void {
    // Original viewBox of 20: a single closed path lets the canvas stroker
    // handle a dash crossing its seam and both end-cap choices.
    d.p.save();
    defer d.p.restore();
    d.p.scaleBy(1.2, 1.2);
    var path = d.p.path();
    path.roundRect(1.25, 1.25, 17.5, 17.5, 4, 4);
    d.p.stroke(&path, .color(d.color(0.2)), .{ .width = 2.5 });
    const perimeter = 4 * (17.5 - 8) + tau * 4;
    const at = if (d.o.still) 0 else d.turn(d.at(0, 0)) * perimeter;
    d.p.stroke(&path, .color(d.o.color), .{ .width = 2.5, .cap = if (d.o.cap == .round) .round else .butt, .dash = &.{ 16, perimeter - 16 }, .dash_offset = -at });
}

fn wave(d: Drawing) void {
    for (0..5) |i| {
        const h = 24 * (if (d.o.still) 0.4 + 0.15 * f(i) else frames(d.at(i, 5), ease, &.{ .{ 0, 0.3 }, .{ 0.5, 1 }, .{ 1, 0.3 } }));
        d.box(f(i) * (24 - 2.88) / 4, if (d.o.origin == .bottom) 24 - h else (24 - h) / 2, 2.88, h, 1.44, 1);
    }
}
