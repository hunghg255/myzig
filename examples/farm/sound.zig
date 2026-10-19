//! The farm's sounds, made by its code: effects synthesized once, and
//! music made as it plays (a decoder of its own), for `myzig.audio`.
const std = @import("std");
const myzig = @import("myzig");
const audio = myzig.audio;
const Event = @import("world.zig").Event;

const sfx_rate = 32000;

pub const Sounds = struct {
    engine: *audio.Engine,
    effects: [6]?*audio.Sound = @splat(null),
    music: ?audio.Player = null,
    prng: std.Random.DefaultPrng = .init(35),

    pub fn init(engine: *audio.Engine) Sounds {
        var s: Sounds = .{ .engine = engine };
        const shapes = [_]struct { f32, *const fn (f64, std.Random) f64 }{
            .{ 0.07, step }, .{ 0.18, till }, .{ 0.12, plant }, .{ 0.35, water }, .{ 0.5, chime }, .{ 0.06, nothing },
        };
        for (shapes, &s.effects) |sh, *e| e.* = s.synth(sh[0], sh[1]) catch null;
        // The first bar is an intro: then the rest loops.
        if (engine.newStreamPlayer(Tune.decoder(engine.gpa) catch return s)) |p| {
            s.music = p.setLoopRange(4 * tune_beat, null).setVolume(0.35);
        } else |_| {}
        return s;
    }

    pub fn deinit(s: *Sounds) void {
        if (s.music) |m| {
            m.stop();
            m.release();
        }
        for (s.effects) |e| if (e) |x| x.release();
    }

    /// A sound of `d` seconds from `f`, a function of the time.
    fn synth(s: *Sounds, d: f32, f: *const fn (f64, std.Random) f64) !*audio.Sound {
        const n: usize = @intFromFloat(d * sfx_rate);
        const out = try s.engine.gpa.alloc(f32, n);
        const r = s.prng.random();
        for (out, 0..) |*o, i| {
            const t = @as(f64, @floatFromInt(i)) / sfx_rate;
            // No click at either end.
            const edge = @min(@min(t / 0.002, (d - t) / 0.01), 1);
            o.* = @floatCast(f(t, r) * edge);
        }
        return s.engine.newSound(sfx_rate, 1, out);
    }

    pub fn setMusic(s: *Sounds, on: bool) void {
        const m = s.music orelse return;
        if (on) m.play() else m.pause();
    }

    /// Plays what happened, a little different each time, as games vary
    /// effects that play often.
    pub fn play(s: *Sounds, events: []const Event) void {
        const r = s.prng.random();
        for (events) |e| {
            const snd = s.effects[@intFromEnum(e)] orelse continue;
            const volume: f32 = switch (e) {
                .step => 0.35,
                .nothing => 0.6,
                else => 1,
            };
            const p = s.engine.newPlayer(snd) catch continue;
            p.setVolume(volume).setSpeed(0.94 + r.float(f64) * 0.12).play();
            p.release();
        }
    }
};

fn noise(r: std.Random) f64 {
    return r.float(f64) * 2 - 1;
}
fn step(t: f64, r: std.Random) f64 {
    return noise(r) * @exp(-t * 60) * 0.5;
}
fn till(t: f64, r: std.Random) f64 {
    return (0.6 * @sin(2 * std.math.pi * 90 * t * (1 - t * 2)) + 0.5 * noise(r)) * @exp(-t * 25);
}
fn plant(t: f64, _: std.Random) f64 {
    return @sin(2 * std.math.pi * (700 - 2500 * t) * t) * @exp(-t * 30) * 0.5;
}
fn water(t: f64, r: std.Random) f64 {
    return noise(r) * (0.5 + 0.5 * @sin(2 * std.math.pi * 23 * t)) * @exp(-t * 8) * 0.25;
}
fn nothing(t: f64, _: std.Random) f64 {
    return @sin(2 * std.math.pi * 160 * t) * @exp(-t * 50) * 0.3;
}
/// Two bell-like notes, a fifth apart.
fn chime(t: f64, _: std.Random) f64 {
    const bell = struct {
        fn f(fr: f64, x: f64) f64 {
            if (x < 0) return 0;
            return (@sin(2 * std.math.pi * fr * x) + 0.4 * @sin(2 * std.math.pi * fr * 2.76 * x) * @exp(-x * 12)) * @exp(-x * 7);
        }
    }.f;
    return 0.3 * (bell(1046.5, t) + bell(1568, t - 0.09));
}

const tune_rate = 22050;
/// Seconds: 120 beats a minute.
const tune_beat = 0.5;
const tune_beats = 32;
const tune_frames: u64 = @intFromFloat(tune_beats * tune_beat * tune_rate);

/// The melody, in semitones above C5 for each half beat, -1 resting.
const melody = [_]i8{
    7,  -1, 4,  -1, 2,  4, 7, -1, 9, -1, 7, -1, 4, -1, -1, -1,
    2,  -1, 4,  -1, 7,  4, 2, -1, 0, -1, 2, -1, 4, -1, -1, -1,
    7,  -1, 9,  -1, 12, -1, 9, 7, 4, -1, 7, -1, 9, -1, -1, -1,
    12, -1, 9,  -1, 7,  4, 2, -1, 4, -1, 2, -1, 0, -1, -1, -1,
};

/// The chord of each bar of 4 beats: C, Am, F, G, as semitones above C3.
const chords = [_][3]i8{ .{ 0, 4, 7 }, .{ -3, 0, 4 }, .{ -7, -3, 0 }, .{ -5, -1, 2 }, .{ 0, 4, 7 }, .{ -3, 0, 4 }, .{ -7, -3, 0 }, .{ -5, -1, 2 } };

fn freq(semi: i8, base: f64) f64 {
    return base * std.math.pow(f64, 2, @as(f64, @floatFromInt(semi)) / 12);
}

/// The music: a slow, gentle loop in C major, chords under a pentatonic
/// melody, made as it plays.
const Tune = struct {
    gpa: std.mem.Allocator,
    pos: u64 = 0,

    fn decoder(gpa: std.mem.Allocator) !audio.Decoder {
        const t = try gpa.create(Tune);
        t.* = .{ .gpa = gpa };
        return .{ .ptr = t, .vtable = &vtable, .rate = tune_rate, .channels = 2, .frames = tune_frames };
    }

    const vtable: audio.Decoder.VTable = .{ .read = read, .seek = seek, .deinit = deinit };

    fn of(p: *anyopaque) *Tune {
        return @ptrCast(@alignCast(p));
    }

    fn seek(p: *anyopaque, frame: u64) anyerror!void {
        of(p).pos = frame;
    }

    fn deinit(p: *anyopaque) void {
        const t = of(p);
        t.gpa.destroy(t);
    }

    fn read(p: *anyopaque, dst: []f32) anyerror!usize {
        const t = of(p);
        var n: usize = 0;
        while (n * 2 + 2 <= dst.len and t.pos < tune_frames) : (n += 1) {
            const sec = @as(f64, @floatFromInt(t.pos)) / tune_rate;
            const beat = sec / tune_beat;
            // The melody: a soft plucked tone for each of its half beats.
            var lead: f64 = 0;
            const i: usize = @intFromFloat(beat * 2);
            if (melody[i] >= 0) {
                const nt = sec - @as(f64, @floatFromInt(i)) * tune_beat / 2;
                const f = freq(melody[i], 523.25);
                lead = (@sin(2 * std.math.pi * f * nt) + 0.3 * @sin(4 * std.math.pi * f * nt)) * @exp(-nt * 4) * @min(nt * 200, 1);
            }
            // The chord of the bar, swelling and fading.
            const bar: usize = @intFromFloat(beat / 4);
            const bt = sec - @as(f64, @floatFromInt(bar)) * 4 * tune_beat;
            const swell = @sin(std.math.pi * bt / (4 * tune_beat));
            var pad: f64 = 0;
            for (chords[bar]) |semi| {
                const f = freq(semi, 130.81);
                pad += @sin(2 * std.math.pi * f * sec) + 0.25 * @sin(2 * std.math.pi * 2 * f * sec);
            }
            pad *= swell / 3;
            dst[n * 2] = @floatCast(0.18 * lead + 0.12 * pad);
            dst[n * 2 + 1] = @floatCast(0.13 * lead + 0.15 * pad);
            t.pos += 1;
        }
        return n;
    }
};
