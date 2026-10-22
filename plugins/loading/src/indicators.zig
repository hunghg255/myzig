//! The 29 loading.dev designs, ported from mygo/plugins/loading.
const ui = @import("myzig").ui;
const g = @import("drawing.zig");
const extra = @import("indicators_extra.zig");
const Drawing = g.Drawing;
const pi = g.pi;
const tau = g.tau;
const f = g.f;
const ease = g.ease;
const frames = g.frames;

pub const names = [_][]const u8{
    "Arc",     "Atom",       "Blocks", "Bouncing dots", "Cascade",     "Circular dots",
    "Classic", "Classic v2", "Clock",  "Comet",         "Compass",     "Dual",
    "Eclipse", "Flip",       "Gather", "Leap",          "Linear dots", "Loading",
    "Morph",   "Orbit",      "Pulse",  "Radar",         "Ring",        "Ripple",
    "Slide",   "Snake",      "Swirl",  "Trace",         "Wave",
};
pub const cycles = [_]f64{
    0.8, 1,   1.3, 0.5, 1.5, 0.8, 1.2,  0.8, 1.2, 0.7, 0.5, 1,   1.2,
    1.2, 1.6, 1.8, 0.9, 1,   1.2, 0.75, 1.2, 1.5, 0.8, 1.2, 2.4, 1.4,
    1.2, 1.2, 0.9,
};
pub fn aspect(i: usize) f32 {
    return switch (i) {
        3 => 1.15,
        16 => 0.9375,
        else => 1,
    };
}

pub const Frame = struct {
    index: usize,
    seconds: f64,
    options: g.Options,

    pub fn draw(s: *const Frame, p: *ui.Painter) void {
        const k = @min(p.size.h / 24, p.size.w / (24 * aspect(s.index)));
        p.translate((p.size.w - k * 24 * aspect(s.index)) / 2, (p.size.h - k * 24) / 2);
        p.scaleBy(k, k);
        const d: Drawing = .{ .p = p, .cycles = s.seconds / cycles[s.index], .o = s.options };
        switch (s.index) {
            0 => d.arc(12, 12, 10, 2.5, d.spin(false, 0), d.spin(false, 0) + 1.8, 1),
            1 => atom(d),
            2 => blocks(d),
            3 => bouncing(d),
            4 => cascade(d),
            5 => circular(d),
            6 => classic(d),
            7 => ticks(d, 8, 0, false),
            8 => clock(d),
            9 => comet(d),
            10 => ticks(d, 4, if (d.o.still) 0 else pi / 2 * ease(d.at(0, 0)), true),
            11 => {
                const a = d.spin(false, 0);
                const b = d.spin(true, pi);
                d.arc(12, 12, 10, 2.5, a, a + 1.8, 1);
                d.arc(12, 12, 5.5, 2.5, b, b + 10.0 / 5.5, 1);
            },
            12 => eclipse(d),
            13 => flip(d),
            14 => gather(d),
            else => extra.draw(s.index, d),
        }
    }
};

fn atom(d: Drawing) void {
    d.hoop(12, 12, 12, 0.055 * 24, 1);
    for (0..3) |i| {
        const a = if (d.o.still) pi / 3 else d.turn(d.at(i, 3)) * tau;
        const k = @cos(a);
        if (@abs(k) < 0.0001) continue;
        d.rotate(f(i) * pi / 3, 12, 12);
        d.scale(k, 1, 12, 12);
        d.hoop(12, 12, 12, 0.045 * 24, 1);
        d.p.restore();
        d.p.restore();
    }
}

fn blocks(d: Drawing) void {
    const cell: f32 = 24 * 0.8 / 3.0;
    for (0..3) |row| for (0..3) |col| {
        const step = switch (d.o.sweep) {
            .diagonal => row + col,
            .rows => row * 3 + col,
            .columns => col * 3 + row,
        };
        const k = if (d.o.still) 0.8 else frames(d.at(step, if (d.o.sweep == .diagonal) 5 else 9), ease, &.{ .{ 0, 1 }, .{ 0.35, 0 }, .{ 0.7, 1 }, .{ 1, 1 } });
        if (k <= 0) continue;
        const x = f(col) * (cell + 2.4);
        const y = f(row) * (cell + 2.4);
        d.scale(k, k, x + cell / 2, y + cell / 2);
        d.box(x, y, cell, cell, 1.5, 1);
        d.p.restore();
    };
}

fn bouncing(d: Drawing) void {
    for (0..3) |i| {
        var y: f32 = 0;
        if (!d.o.still) {
            const t = d.cycles + @as(f64, @floatFromInt(3 - i)) / 3;
            const n = @floor(t);
            var p: f32 = @floatCast(t - n);
            if (@mod(n, 2) == 1) p = 1 - p;
            y = 0.28 - ease(p);
        }
        d.dot(3 + f(i) * 10.8, 12 + y * 6, 3, 1);
    }
}

fn cascade(d: Drawing) void {
    for ([_]f32{ 10.5, 7, 3.5 }, 0..) |r, i| {
        const a = if (d.o.still) 0 else g.bezier(d.at(i, 24), 0.68, -0.75, 0.265, 1.75) * tau;
        d.arc(12, 12, r, 2, a, a + pi / 2, 1);
    }
}

fn circular(d: Drawing) void {
    for (0..8) |i| {
        const a = f(i) * pi / 4 - pi / 2;
        d.dot(12 + 9.75 * @cos(a), 12 + 9.75 * @sin(a), 2.25, d.fade(i, 8, 0.2, 0.6));
    }
}

fn classic(d: Drawing) void {
    const x = 24 * 0.52;
    const y = 24 * 0.501;
    for (0..12) |i| {
        d.rotate(f(i) * pi / 6, x, y);
        d.box(x - 2.88 + 1.46 * 5.76, y - 0.96, 5.76, 1.92, 0.96, d.fade(i, 12, 0.15, 0.5));
        d.p.restore();
    }
}

fn ticks(d: Drawing, n: usize, angle: f32, solid: bool) void {
    for (0..n) |i| {
        d.rotate(angle + f(i) * tau / f(n), 12, 12);
        d.capsule(12, 1, 12, 5, 2, if (solid) 1 else d.fade(i, n, 0.4, 0.5));
        d.p.restore();
    }
}

fn clock(d: Drawing) void {
    d.dot(12, 12, 12, 0.1);
    d.rotate(d.spin(false, 0), 12, 12);
    d.p.scaleBy(1.5, 1.5);
    var path = d.p.path();
    path.moveTo(11.1937, 2.92061);
    path.cubicTo(10.5206, 2.49739, 9.77304, 2.21397, 8.9954, 2.08314);
    path.cubicTo(8.45076, 1.99151, 8, 2.44772, 8, 3);
    path.lineTo(8, 7.20324);
    path.cubicTo(8, 7.49211, 8.12492, 7.76686, 8.34259, 7.95677);
    path.lineTo(11.8999, 11.0603);
    path.cubicTo(12.3287, 11.4344, 12.9913, 11.378, 13.2643, 10.8787);
    path.cubicTo(13.6356, 10.1998, 13.8736, 9.45248, 13.9617, 8.67713);
    path.cubicTo(14.0892, 7.55433, 13.8971, 6.41834, 13.4074, 5.39993);
    path.cubicTo(12.9177, 4.38152, 12.1503, 3.5221, 11.1937, 2.92061);
    path.close();
    d.p.fill(&path, .color(d.o.color));
    d.p.restore();
}

fn comet(d: Drawing) void {
    const a = d.spin(false, 0);
    d.tail(12, 2.88, a - pi / 2, tau);
    d.dot(12 + 10.56 * @sin(a), 12 - 10.56 * @cos(a), 1.44, 1);
}

fn eclipse(d: Drawing) void {
    for (0..2) |i| {
        const p = d.at(i, 2);
        const x = if (d.o.still) f(i) * 1.5 - 0.75 else frames(p, ease, &.{ .{ 0, 0.75 }, .{ 0.5, -0.75 }, .{ 1, 0.75 } });
        const a = if (d.o.still) 1 else frames(p, ease, &.{ .{ 0, 0.75 }, .{ 0.25, 1 }, .{ 0.5, 0.75 }, .{ 0.75, 0.5 }, .{ 1, 0.75 } });
        const k = if (d.o.still) 1 else frames(p, ease, &.{ .{ 0, 1 }, .{ 0.25, 1.3 }, .{ 0.5, 1 }, .{ 0.75, 0.7 }, .{ 1, 1 } });
        d.dot(12 + x * 9.6, 12, 4.8 * k, a);
    }
}

/// Project a rounded square through CSS rotateX/rotateY and perspective.
/// Canvas has affine transforms, so project the outline's points explicitly.
fn flip(d: Drawing) void {
    const p = d.at(0, 0);
    const ax = if (d.o.still) 0 else frames(p, ease, &.{ .{ 0, 0 }, .{ 0.5, -pi }, .{ 1, -pi } });
    const ay = if (d.o.still) 0 else frames(p, ease, &.{ .{ 0, 0 }, .{ 0.5, 0 }, .{ 1, -pi } });
    const half: f32 = 0.32 * 24;
    const r: f32 = 0.06 * 24;
    var path = d.p.path();
    for (0..68) |i| {
        const corner = i / 17;
        const a = (f(corner) + f(i % 17) / 16) * pi / 2;
        const x = (if (corner == 0 or corner == 3) half - r else r - half) + r * @cos(a);
        const y = (if (corner < 2) half - r else r - half) + r * @sin(a);
        const z = -x * @sin(ay);
        const xx = x * @cos(ay);
        const yy = y * @cos(ax) - z * @sin(ax);
        const zz = y * @sin(ax) + z * @cos(ax);
        const k = 72 / (72 - zz);
        if (i == 0) path.moveTo(12 + xx * k, 12 + yy * k) else path.lineTo(12 + xx * k, 12 + yy * k);
    }
    path.close();
    d.p.fill(&path, .color(d.o.color));
}

fn gather(d: Drawing) void {
    const p = d.at(0, 0);
    const pull = if (d.o.still) 0 else frames(p, ease, &.{ .{ 0, 0 }, .{ 0.3, 1 }, .{ 0.6, 1 }, .{ 1, 0 } });
    const turn = if (d.o.still) 0 else frames(p, ease, &.{ .{ 0, 0 }, .{ 0.3, 0 }, .{ 0.6, pi / 2 }, .{ 1, pi / 2 } });
    d.rotate(turn, 12, 12);
    defer d.p.restore();
    for (0..4) |i| {
        const col = f(i % 2);
        const row = f(i / 2);
        const x = col * 14.88 + (1 - 2 * col) * pull * 0.211 * 9.12;
        const y = row * 14.88 + (1 - 2 * row) * pull * 0.211 * 9.12;
        d.box(x, y, 9.12, 9.12, 3.36, 1);
    }
}
