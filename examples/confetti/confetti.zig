//! Bursts of confetti, as canvas-confetti throws them: squares, circles,
//! stars, hearts and emoji that fly out, slow down, fall, tumble and fade.
//! Each piece adds up canvas-confetti's three motions in closed form: a
//! burst whose speed decays, a steady fall that fades it, and a spin in a
//! plane turned away from the viewer, which makes it tumble.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

pub const Shape = union(enum) {
    square,
    circle,
    star,
    heart,
    /// An emoji.
    text: []const u8,
};

/// How a burst flies, as canvas-confetti's options: speeds and distances
/// are in points per tick, a sixtieth of a second.
pub const Options = struct {
    count: usize = 50,
    /// Degrees counterclockwise from the right (90 is up), and how far the
    /// pieces stray from it.
    angle: f32 = 90,
    spread: f32 = 45,
    /// A piece starts at half of it to one and a half times it; `decay` is
    /// what its speed keeps every tick.
    start_velocity: f32 = 45,
    decay: f32 = 0.9,
    /// Pulls the pieces down 3 points a tick, times `gravity`; `drift`
    /// moves them sideways.
    gravity: f32 = 1,
    drift: f32 = 0,
    /// How long the pieces last, fading as they go.
    ticks: u32 = 200,
    /// Where it starts, in fractions of the window.
    x: f32 = 0.5,
    y: f32 = 0.5,
    colors: []const ui.Color = &default_colors,
    shapes: []const Shape = &.{ .square, .circle },
    scalar: f32 = 1,
    /// Facing the viewer rather than tumbling.
    flat: bool = false,
};

/// canvas-confetti's colors.
pub const default_colors = [_]ui.Color{ .hex(0x26ccff), .hex(0xa25afd), .hex(0xff5e7e), .hex(0x88ff5a), .hex(0xfcff42), .hex(0xffa62d), .hex(0xff36ff) };

const tick: f32 = 1.0 / 60.0;

pub const Piece = struct {
    w: f32,
    h: f32,
    color: ui.Color,
    shape: Shape,
    /// Where the burst carries it, in points.
    to_x: f32,
    to_y: f32,
    /// Degrees it turns in its plane over its life, which `tilt` turns
    /// away from the viewer around an axis turned by `turn` degrees.
    spin: f32 = 0,
    tilt: f32 = 0,
    turn: f32 = 0,
};

pub const Burst = struct {
    id: u64,
    /// Where it starts, in window points, and when (the context's clock).
    x: f32,
    y: f32,
    born: f64,
    life: f32,
    fall_x: f32,
    fall_y: f32,
    /// ln(decay) times the ticks: how the burst eases (1 − e^(k·t)) / (1 − e^k).
    k: f32,
    pieces: []Piece,

    pub fn init(gpa: std.mem.Allocator, rand: std.Random, o: Options, x: f32, y: f32, id: u64, now: f64) !Burst {
        const ticks: f32 = @floatFromInt(@max(o.ticks, 1));
        const shapes: []const Shape = if (o.shapes.len == 0) &.{ .square, .circle } else o.shapes;
        const colors = if (o.colors.len == 0) &default_colors else o.colors;
        const b: Burst = .{
            .id = id,
            .x = x,
            .y = y,
            .born = now,
            .life = ticks * tick,
            .fall_x = o.drift * ticks,
            .fall_y = 3 * o.gravity * ticks,
            .k = if (o.decay == 1) 0 else @log(o.decay) * ticks,
            .pieces = try gpa.alloc(Piece, o.count),
        };
        // What the speed adds up to over the ticks, per point a tick of
        // the starting speed.
        const reach = if (o.decay == 1) ticks else (1 - std.math.pow(f32, o.decay, ticks)) / (1 - o.decay);
        const angle = o.angle * std.math.pi / 180;
        const spread = o.spread * std.math.pi / 180;
        for (b.pieces) |*p| {
            const dir = -angle + spread / 2 - rand.float(f32) * spread;
            const speed = o.start_velocity * 0.5 + rand.float(f32) * o.start_velocity;
            const shape = shapes[rand.uintLessThan(usize, shapes.len)];
            const s = o.scalar;
            const size: [2]f32 = switch (shape) {
                .square => .{ 10 * s, 10 * s * (0.5 + 0.4 * rand.float(f32)) },
                .circle => .{ 8 * s, 8 * s },
                .star => .{ 16 * s, 16 * s },
                .heart => .{ 14 * s, 13 * s },
                .text => .{ 12 * s, 12 * s },
            };
            p.* = .{
                .w = size[0],
                .h = size[1],
                .color = colors[rand.uintLessThan(usize, colors.len)],
                .shape = shape,
                .to_x = @cos(dir) * speed * reach,
                .to_y = @sin(dir) * speed * reach,
            };
            if (!o.flat) {
                p.tilt = 45 + 40 * rand.float(f32);
                p.turn = 360 * rand.float(f32);
                // About a turn a second, either way; a circle looks the
                // same however it spins.
                if (shape != .circle) {
                    var turns = (0.6 + 0.8 * rand.float(f32)) * b.life;
                    if (rand.boolean()) turns = -turns;
                    p.spin = turns * 360;
                }
            }
        }
        return b;
    }

    pub fn deinit(b: *Burst, gpa: std.mem.Allocator) void {
        gpa.free(b.pieces);
    }

    pub fn done(b: *const Burst, now: f64) bool {
        return now - b.born >= b.life;
    }

    /// The burst's pieces where they are at `now`, over everything, as
    /// absolute boxes of `parent`'s.
    pub fn build(b: *const Burst, c: *ui.Context, now: f64) void {
        const u: f32 = std.math.clamp(@as(f32, @floatCast((now - b.born) / b.life)), 0, 1);
        const ease = if (b.k == 0) u else (1 - @exp(b.k * u)) / (1 - @exp(b.k));
        for (b.pieces, 0..) |*p, i| {
            const x = b.x + b.fall_x * u + p.to_x * ease - p.w / 2;
            const y = b.y + b.fall_y * u + p.to_y * ease - p.h / 2;
            // A spin in a plane tilted away from the viewer (seen without
            // perspective: squashed along y by the tilt's cosine), turned.
            var m = ui.Affine.rotation(p.spin * u);
            if (p.tilt != 0) m = m.then(.scaling(1, @cos(p.tilt * std.math.pi / 180))).then(.rotation(p.turn));
            const style: ui.Style = .{
                .absolute = true,
                .offset = .{ .x = x, .y = y },
                .width = .{ .px = p.w },
                .height = .{ .px = p.h },
                .opacity = 1 - u,
                .transform = m,
            };
            c.next_key_int = b.id *% 4096 +% i;
            switch (p.shape) {
                .square => {
                    var s = style;
                    s.background = p.color;
                    _ = c.leaf(s, .none, null);
                },
                .circle => {
                    var s = style;
                    s.background = p.color;
                    s.radius = p.w / 2;
                    _ = c.leaf(s, .none, null);
                },
                .star, .heart => {
                    _ = c.open(style, null);
                    if (p.shape == .star) _ = ui.canvas(c, .{ .w = p.w, .h = p.h }, .{}, p, drawStar) else _ = ui.canvas(c, .{ .w = p.w, .h = p.h }, .{}, p, drawHeart);
                    c.end();
                },
                .text => |t| {
                    var s = style;
                    s.width = .auto;
                    s.height = .auto;
                    _ = c.leaf(s, .{ .text = .{ .str = t, .style = .{ .size = p.h }, .color = .black } }, null);
                },
            }
        }
    }
};

/// A five-pointed star filling the canvas.
fn drawStar(p: *const Piece, pt: *ui.Painter) void {
    const cx = pt.size.w / 2;
    const cy = pt.size.h / 2;
    const outer = pt.size.w / 2;
    const inner = outer * 0.45;
    var path = pt.path();
    for (0..10) |i| {
        const rad = if (i % 2 == 1) inner else outer;
        const a = -std.math.pi / 2.0 + @as(f32, @floatFromInt(i)) * std.math.pi / 5.0;
        const x = cx + rad * @cos(a);
        const y = cy + rad * @sin(a);
        if (i == 0) path.moveTo(x, y) else path.lineTo(x, y);
    }
    path.close();
    pt.fill(&path, .color(p.color));
}

/// A heart filling the canvas.
fn drawHeart(p: *const Piece, pt: *ui.Painter) void {
    const w = pt.size.w;
    const h = pt.size.h;
    var path = pt.path();
    path.moveTo(w / 2, h);
    path.cubicTo(-w * 0.15, h * 0.55, w * 0.05, -h * 0.1, w / 2, h * 0.22);
    path.cubicTo(w * 0.95, -h * 0.1, w * 1.15, h * 0.55, w / 2, h);
    path.close();
    pt.fill(&path, .color(p.color));
}
