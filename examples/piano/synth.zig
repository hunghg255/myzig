//! The piano's sound: a sound per key, synthesized, decoded nowhere.
//! Every key's is made ahead on a thread of its own, so that none waits
//! for it; a key pressed before then makes its own.
const std = @import("std");
const myzig = @import("myzig");
const audio = myzig.audio;

pub const lowest = 48;
pub const highest = 84;
const synth_rate = 32000;

pub const Bank = struct {
    engine: *audio.Engine,
    gpa: std.mem.Allocator,
    sounds: [highest + 1]?*audio.Sound = @splat(null),
    /// 0 not made, 1 being made, 2 made.
    state: [highest + 1]std.atomic.Value(u8) = @splat(.init(0)),
    thread: ?std.Thread = null,
    quit: std.atomic.Value(bool) = .init(false),

    pub fn start(b: *Bank) void {
        b.thread = std.Thread.spawn(.{}, ahead, .{b}) catch null;
    }

    pub fn deinit(b: *Bank) void {
        b.quit.store(true, .release);
        if (b.thread) |t| t.join();
        for (b.sounds) |s| if (s) |x| x.release();
    }

    fn ahead(b: *Bank) void {
        var n: u8 = lowest;
        while (n <= highest and !b.quit.load(.acquire)) : (n += 1) _ = b.get(n);
    }

    /// The sound of `note`'s key, synthesized the first time.
    pub fn get(b: *Bank, note: u8) ?*audio.Sound {
        const st = &b.state[note];
        while (true) {
            switch (st.load(.acquire)) {
                2 => return b.sounds[note],
                0 => if (st.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
                    const samples = synthSamples(b.gpa, note) catch null;
                    b.sounds[note] = if (samples) |s| b.engine.newSound(synth_rate, 1, s) catch null else null;
                    st.store(2, .release);
                    return b.sounds[note];
                },
                else => std.Thread.yield() catch {},
            }
        }
    }
};

/// A piano-like tone: partials a little sharper than harmonics, as a stiff
/// string's are, from two strings a cent apart, each dying away fast and
/// then slowly, the higher the faster, with the thump of a hammer.
fn synthSamples(gpa: std.mem.Allocator, note: u8) ![]f32 {
    const nf: f64 = @floatFromInt(note);
    const f = 440 * std.math.pow(f64, 2, (nf - 69) / 12);
    // Low strings ring longer.
    const dur = 1.4 + 2.6 * (highest - nf) / (highest - lowest);
    const n: usize = @intFromFloat(dur * synth_rate);
    const out = try gpa.alloc(f64, n);
    defer gpa.free(out);
    @memset(out, 0);
    const stiffness = 0.00008 * std.math.pow(f64, 2, (nf - lowest) / 12);
    for (1..19) |k| {
        const kf: f64 = @floatFromInt(k);
        const fk = kf * f * @sqrt(1 + stiffness * kf * kf);
        if (fk > synth_rate * 0.45) break;
        const amp = 1 / std.math.pow(f64, kf, 1.1);
        const fast = 0.3 * std.math.pow(f64, 261.6 / f, 0.5) / (1 + 0.3 * (kf - 1));
        const slow = fast * 7;
        for ([_]f64{ 1, 1.0006 }) |detune| {
            // A rotation for the sine and products for the decays, which
            // sin and exp for each sample would make slow.
            const w = 2 * std.math.pi * fk * detune / synth_rate;
            const cw = @cos(w);
            const sw = @sin(w);
            var s: f64 = 0;
            var c: f64 = 1;
            var e1: f64 = 0.65;
            var e2: f64 = 0.35;
            const d1 = @exp(-1 / (fast * synth_rate));
            const d2 = @exp(-1 / (slow * synth_rate));
            for (out) |*o| {
                o.* += amp * (e1 + e2) * s;
                const s2 = s * cw + c * sw;
                c = c * cw - s * sw;
                s = s2;
                e1 *= d1;
                e2 *= d2;
            }
        }
    }
    // The hammer: a short burst of noise, and an attack of 2 ms.
    var prng: std.Random.DefaultPrng = .init(note);
    const r = prng.random();
    var lp: f64 = 0;
    for (0..@min(n, synth_rate / 20)) |i| {
        const t = @as(f64, @floatFromInt(i)) / synth_rate;
        lp += 0.3 * (r.float(f64) * 2 - 1 - lp);
        out[i] += 0.4 * lp * @exp(-t / 0.006);
        out[i] *= @min(t / 0.002, 1);
    }
    // The release of the last 50 ms, and every key as loud as another.
    var peak: f64 = 0;
    for (out, 0..) |*v, i| {
        const left = n - i;
        if (left < synth_rate / 20) v.* *= @as(f64, @floatFromInt(left)) / (synth_rate / 20);
        peak = @max(peak, @abs(v.*));
    }
    const samples = try gpa.alloc(f32, n);
    for (samples, out) |*s, v| s.* = @floatCast(0.22 * v / peak);
    return samples;
}
