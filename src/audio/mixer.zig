//! Mixing: every voice playing, resampled to the output's rate with a
//! Catmull-Rom spline, panned and scaled by gains that ramp over 5 ms (so
//! volume changes, pauses and resumes never click), summed and clipped.
//! The output's thread calls `Mixer.mix`; players change voices under the
//! same lock from any thread.
const std = @import("std");
const source = @import("source.zig");

/// The output: 48 kHz stereo.
pub const rate: u32 = 48000;
pub const channels: u16 = 2;
/// Volume ramps: 5 ms.
pub const ramp_frames: u32 = rate / 200;

/// A lock held for microseconds at a time: the output's thread mixing a
/// few milliseconds, a player changing a setting.
pub const Lock = struct {
    held: std.atomic.Value(bool) = .init(false),

    pub fn lock(l: *Lock) void {
        while (l.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    pub fn unlock(l: *Lock) void {
        l.held.store(false, .release);
    }
};

/// A player's state: its source, where it is, and how it resamples and
/// pans to the output. Settings are read by the mixer under its lock.
pub const Voice = struct {
    src: source.Source,
    src_rate: f64,
    mono: bool,

    /// As the API sees it.
    playing: bool = false,
    /// In the mixer's list: it stays while fading out.
    active: bool = false,
    /// Starts at its start: no fade in.
    snap: bool = true,
    /// Resumes in the middle: fades in from silence.
    fade_in: bool = false,
    /// Its player is gone: freed once it ends.
    orphan: bool = false,

    volume: f32 = 1,
    /// A volume ramp under way (`Player.fadeTo`): output frames left of
    /// `fade_frames`, from `fade_from` to `fade_to`; then paused when
    /// `fade_pause`, its volume back to `fade_restore` for the next play.
    fade_left: u64 = 0,
    fade_frames: u64 = 0,
    fade_from: f32 = 1,
    fade_to: f32 = 1,
    fade_restore: f32 = 1,
    fade_pause: bool = false,
    pan: f32 = 0,
    speed: f64 = 1,
    loop: bool = false,
    loop_start: u64 = 0,
    loop_end: ?u64 = null,

    /// The four source frames interpolated between, the second at `idx`,
    /// and how far the output is past it.
    hist: [4][2]f32 = @splat(.{ 0, 0 }),
    idx: i64 = -3,
    phase: f64 = 3,
    /// The frame after the last, once the source ended.
    end: ?i64 = null,
    in: [512]f32 = undefined,
    in_pos: usize = 0,
    in_len: usize = 0,
    /// Gains from the source's channels to the output's (ll, rl, lr, rr),
    /// ramping to `target`.
    gain: [4]f32 = @splat(0),
    target: [4]f32 = @splat(0),
    step: [4]f32 = @splat(0),
    ramp_left: u32 = 0,

    pub fn init(src: source.Source) Voice {
        return .{ .src = src, .src_rate = @floatFromInt(src.rate()), .mono = src.channels() == 1 };
    }

    /// Starts over at frame `f` of its source.
    pub fn reset(v: *Voice, f: u64) void {
        v.src.seek(f);
        v.hist = @splat(.{ 0, 0 });
        v.idx = @as(i64, @intCast(f)) - 3;
        v.phase = 3;
        v.end = null;
        v.in_pos = 0;
        v.in_len = 0;
    }

    pub fn ended(v: *const Voice) bool {
        return if (v.end) |e| v.idx >= e else false;
    }

    /// The source frame it is at.
    pub fn position(v: *const Voice) f64 {
        var p = @max(@as(f64, @floatFromInt(v.idx)) + v.phase, 0);
        const len = v.src.length();
        if (v.loop) {
            const e: f64 = @floatFromInt(v.loop_end orelse len orelse return p);
            const s: f64 = @floatFromInt(v.loop_start);
            if (e > s and p >= e) p = s + @mod(p - s, e - s);
            return p;
        }
        if (len) |l| p = @min(p, @as(f64, @floatFromInt(l)));
        return p;
    }

    fn shift(v: *Voice, l: f32, r: f32) void {
        v.hist[0] = v.hist[1];
        v.hist[1] = v.hist[2];
        v.hist[2] = v.hist[3];
        v.hist[3] = .{ l, r };
        v.idx += 1;
    }

    /// Shifts in the source's next frame.
    fn next(v: *Voice) void {
        const ch: usize = if (v.mono) 1 else v.src.channels();
        if (v.in_pos >= v.in_len) {
            if (v.end != null) return v.shift(0, 0);
            const per = v.in.len / ch * ch;
            const n = v.src.read(v.in[0..per], v.loop, v.loop_start, v.loop_end);
            v.in_pos = 0;
            v.in_len = n * ch;
            if (n == 0) {
                v.end = v.idx + 3;
                return v.shift(0, 0);
            }
        }
        const l = v.in[v.in_pos];
        const r = if (ch == 1) l else v.in[v.in_pos + 1];
        v.in_pos += ch;
        v.shift(l, r);
    }

    /// The matrix of its volume and pan, with the master volume.
    fn gains(v: *const Voice, master: f32) [4]f32 {
        const g: f32 = if (v.playing) v.volume * master else 0;
        const half_pi = std.math.pi / 2.0;
        if (v.mono) {
            // Equal power, the middle as decoded.
            const x = (v.pan + 1) / 2 * half_pi;
            return .{ g * std.math.sqrt2 * @cos(x), 0, 0, g * std.math.sqrt2 * @sin(x) };
        }
        // Web Audio's StereoPannerNode for stereo input.
        if (v.pan <= 0) {
            const x = (v.pan + 1) * half_pi;
            return .{ g, 0, g * @cos(x), g * @sin(x) };
        }
        const x = v.pan * half_pi;
        return .{ g * @cos(x), g * @sin(x), 0, g };
    }

    fn retarget(v: *Voice, t: [4]f32) void {
        if (v.snap) {
            v.snap = false;
            v.fade_in = false;
            v.gain = t;
            v.target = t;
            v.ramp_left = 0;
            return;
        }
        if (v.fade_in) {
            v.fade_in = false;
            v.gain = @splat(0);
        } else if (std.mem.eql(f32, &t, &v.target)) return;
        v.target = t;
        for (&v.step, t, v.gain) |*s, x, g| s.* = (x - g) / @as(f32, ramp_frames);
        v.ramp_left = ramp_frames;
    }

    /// Starts a volume ramp to `to` over `frames` output frames (none:
    /// at once); with `pause_at`, it pauses at its end and its volume goes
    /// back to `pause_at` for the next play.
    pub fn fade(v: *Voice, to: f32, frames: u64, pause_at: ?f32) void {
        v.fade_from = v.volume;
        v.fade_to = to;
        v.fade_frames = frames;
        v.fade_left = frames;
        v.fade_pause = pause_at != null;
        v.fade_restore = pause_at orelse to;
        if (frames == 0) v.endFade();
    }

    fn endFade(v: *Voice) void {
        v.fade_left = 0;
        if (v.fade_pause) {
            v.playing = false;
            v.volume = v.fade_restore;
            v.fade_pause = false;
        } else v.volume = v.fade_to;
    }

    /// Adds its next frames to `out` (stereo); false once it ended or
    /// faded out. A volume ramp moves its volume a step each `ramp_frames`
    /// frames, which the gains ramp between: a straight line, unbroken.
    pub fn mix(v: *Voice, out: []f32, master: f32) bool {
        var at: usize = 0;
        while (v.fade_left > 0 and at < out.len) {
            const n: u64 = @min(v.fade_left, ramp_frames, (out.len - at) / 2);
            v.fade_left -= n;
            const done: f32 = @floatCast(@as(f64, @floatFromInt(v.fade_frames - v.fade_left)) / @as(f64, @floatFromInt(v.fade_frames)));
            v.volume = v.fade_from + (v.fade_to - v.fade_from) * done;
            // The last step lands at once on the end's volume, as the ramp's.
            if (v.fade_left == 0) {
                if (v.fade_pause) v.volume = 0;
                v.retargetOver(v.gains(master), @intCast(n));
                const pausing = v.fade_pause;
                if (!v.mixFrames(out[at .. at + n * 2])) return false;
                at += n * 2;
                v.endFade();
                if (pausing) v.gain = @splat(0);
                continue;
            }
            v.retargetOver(v.gains(master), @intCast(n));
            if (!v.mixFrames(out[at .. at + n * 2])) return false;
            at += n * 2;
        }
        if (at >= out.len) return v.playing or v.ramp_left > 0;
        v.retarget(v.gains(master));
        return v.mixFrames(out[at..]);
    }

    /// Ramps the gains to `t` over `frames` frames.
    fn retargetOver(v: *Voice, t: [4]f32, frames: u32) void {
        if (v.snap or v.fade_in or frames == 0) return v.retarget(t);
        v.target = t;
        for (&v.step, t, v.gain) |*s, x, g| s.* = (x - g) / @as(f32, @floatFromInt(frames));
        v.ramp_left = frames;
    }

    fn mixFrames(v: *Voice, out: []f32) bool {
        const step = v.src_rate / @as(f64, rate) * v.speed;
        var i: usize = 0;
        while (i < out.len) : (i += 2) {
            while (v.phase >= 1) {
                v.next();
                v.phase -= 1;
            }
            if (v.ended()) {
                v.playing = false;
                return false;
            }
            if (v.ramp_left > 0) {
                for (&v.gain, v.step) |*g, s| g.* += s;
                v.ramp_left -= 1;
                if (v.ramp_left == 0) v.gain = v.target;
            } else if (!v.playing) return false; // faded out
            const s = v.sample();
            out[i] += s[0] * v.gain[0] + s[1] * v.gain[2];
            out[i + 1] += s[0] * v.gain[1] + s[1] * v.gain[3];
            v.phase += step;
        }
        return true;
    }

    /// Between the second and third frames, on a Catmull-Rom spline.
    fn sample(v: *const Voice) [2]f32 {
        const t: f32 = @floatCast(v.phase);
        const h = &v.hist;
        var out: [2]f32 = undefined;
        for (0..2) |c| {
            const p0 = h[0][c];
            const p1 = h[1][c];
            const p2 = h[2][c];
            const p3 = h[3][c];
            out[c] = p1 + 0.5 * t * (p2 - p0 + t * (2 * p0 - 5 * p1 + 4 * p2 - p3 + t * (3 * (p1 - p2) + p3 - p0)));
        }
        return out;
    }
};

/// The voices playing, or fading out.
pub const Mixer = struct {
    gpa: std.mem.Allocator,
    lock: Lock = .{},
    voices: std.ArrayList(*Voice) = .empty,
    /// Voices whose players are gone and which ended: freed by `collect`
    /// on a thread of the app's (the mixer never frees).
    done: std.ArrayList(*Voice) = .empty,
    master: f32 = 1,

    pub fn deinit(m: *Mixer) void {
        m.lock.lock();
        for (m.voices.items) |v| if (v.orphan) m.done.append(m.gpa, v) catch {};
        m.voices.deinit(m.gpa);
        m.voices = .empty;
        m.lock.unlock();
        m.collect();
        m.done.deinit(m.gpa);
    }

    /// Adds a voice to the mix (under the lock).
    pub fn activate(m: *Mixer, v: *Voice) void {
        if (v.active) return;
        m.voices.append(m.gpa, v) catch return;
        v.active = true;
    }

    /// Frees the voices of players gone that ended.
    pub fn collect(m: *Mixer) void {
        m.lock.lock();
        const list = m.done;
        m.done = .empty;
        m.lock.unlock();
        var l = list;
        for (l.items) |v| {
            v.src.deinit();
            m.gpa.destroy(v);
        }
        l.deinit(m.gpa);
    }

    /// Fills `out` (interleaved stereo) with the voices playing; true if
    /// any is.
    pub fn mix(m: *Mixer, out: []f32) bool {
        @memset(out, 0);
        m.lock.lock();
        defer m.lock.unlock();
        var n: usize = 0;
        for (m.voices.items) |v| {
            if (!v.mix(out, m.master)) {
                v.active = false;
                if (v.orphan) m.done.append(m.gpa, v) catch {};
                continue;
            }
            m.voices.items[n] = v;
            n += 1;
        }
        m.voices.shrinkRetainingCapacity(n);
        for (out) |*s| s.* = std.math.clamp(s.*, -1, 1);
        return n > 0;
    }

    pub fn busy(m: *Mixer) bool {
        m.lock.lock();
        defer m.lock.unlock();
        return m.voices.items.len > 0;
    }
};
