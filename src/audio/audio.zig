//! Sound from Zig: effects decoded into memory, music streamed as it plays,
//! and sound an app makes itself, mixed by myzig and sent to the system's
//! output (WASAPI on Windows, PulseAudio or ALSA on Linux, an Audio Queue
//! on macOS), loaded at run time: apps that play nothing link none of it.
//! Files are WAV, Ogg Vorbis or MP3, decoded by myzig.
//!
//!     const engine = try myzig.audio.Engine.create(gpa, io, .{});
//!     defer engine.destroy();
//!     const hoe = try engine.decodeSound(@embedFile("hoe.wav")); // decoded once
//!     defer hoe.release();
//!     _ = engine.play(hoe); // as often as it sounds, over itself
//!     const music = try engine.openStream("spring.ogg"); // decoded as it plays
//!     music.setLoop(true).setVolume(0.6).play();
//!     music.fadeOut(1.5); // to silence, then paused (also fadeIn, fadeTo)
//!
//! The output opens when something first plays and closes five seconds
//! after everything stopped. It plays at 48 kHz in stereo, about 40 ms
//! ahead; players of other rates are resampled as they play. Where no
//! output opens, players still play on time, unheard, and `Engine.err`
//! says why. Every method is safe from any thread.
const std = @import("std");
pub const source = @import("source.zig");
pub const mixer = @import("mixer.zig");
pub const wav = @import("wav.zig");
pub const vorbis = @import("vorbis.zig");
pub const mp3 = @import("mp3.zig");
pub const formats = @import("formats.zig");
const output = @import("output.zig");

pub const Sound = source.Sound;
pub const Decoder = source.Decoder;
pub const Voice = mixer.Voice;
pub const rate = mixer.rate;
pub const channels = mixer.channels;

pub const Options = struct {
    /// `system`: the default output. `manual`: no output; the app (or a
    /// test) pulls frames with `Engine.render`, a sink of its own.
    device: enum { system, manual } = .system,
    /// How long the output stays open with nothing playing.
    idle_close_ms: u32 = 5000,
};

pub const Engine = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    mix: mixer.Mixer,
    thread: ?std.Thread = null,
    /// Wakes the output's thread: something started playing.
    wake: std.atomic.Value(u32) = .init(0),
    quit: std.atomic.Value(bool) = .init(false),
    /// Why no output opened, if none did: an error's value, 0 for none.
    err: std.atomic.Value(u16) = .init(0),

    /// `gpa` must be safe from several threads: voices are allocated by
    /// the app's and freed after the output's thread let them go.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, options: Options) !*Engine {
        const e = try gpa.create(Engine);
        e.* = .{ .gpa = gpa, .io = io, .options = options, .mix = .{ .gpa = gpa } };
        return e;
    }

    pub fn destroy(e: *Engine) void {
        if (e.thread) |t| {
            e.quit.store(true, .release);
            e.poke();
            t.join();
        }
        e.mix.deinit();
        e.gpa.destroy(e);
    }

    /// Decodes a file in memory (WAV, Ogg Vorbis or MP3, told by its
    /// first bytes) into a sound, which copies what it needs.
    pub fn decodeSound(e: *Engine, bytes: []const u8) !*Sound {
        return Sound.decode(e.gpa, try formats.open(e.gpa, .{ .bytes = bytes }, false));
    }

    /// A sound of samples the app computed (interleaved; taken, allocated with the engine's gpa).
    pub fn newSound(e: *Engine, sample_rate: u32, chans: u16, samples: []f32) !*Sound {
        return Sound.create(e.gpa, sample_rate, chans, samples);
    }

    /// Plays `s` once, in a player of its own, freed when it ends.
    pub fn play(e: *Engine, s: *Sound) void {
        const p = e.newPlayer(s) catch return;
        p.play();
        p.release();
    }

    /// A paused player of `s`, to set up before it plays.
    pub fn newPlayer(e: *Engine, s: *Sound) !Player {
        s.retain();
        errdefer s.release();
        return e.player(.{ .sound = .{ .sound = s } });
    }

    /// A paused player of a decoder (closed with the player): a stream,
    /// or sound the app makes as it plays.
    pub fn newStreamPlayer(e: *Engine, d: Decoder) !Player {
        return e.player(.{ .stream = .{ .decoder = d } });
    }

    /// A paused player of a file (WAV, Ogg Vorbis or MP3), decoded as it plays.
    pub fn openStream(e: *Engine, path: []const u8) !Player {
        const f = try std.Io.Dir.cwd().openFile(e.io, path, .{});
        const d = try formats.open(e.gpa, .{ .file = .{ .file = f, .io = e.io } }, true);
        errdefer d.deinit();
        return e.newStreamPlayer(d);
    }

    fn player(e: *Engine, src: source.Source) !Player {
        e.mix.collect();
        const v = try e.gpa.create(Voice);
        v.* = .init(src);
        v.reset(0);
        return .{ .engine = e, .voice = v };
    }

    /// The volume of everything: 1 as decoded.
    pub fn setVolume(e: *Engine, v: f32) void {
        e.mix.lock.lock();
        e.mix.master = @max(v, 0);
        e.mix.lock.unlock();
    }

    /// Mixes the next frames into `out` (interleaved stereo at `rate`), as
    /// an output would: for a `manual` engine and its sink. True if
    /// anything played.
    pub fn render(e: *Engine, out: []f32) bool {
        return e.mix.mix(out);
    }

    /// Why the output couldn't open, if it couldn't.
    pub fn outputError(e: *Engine) ?anyerror {
        const code = e.err.load(.acquire);
        if (code == 0) return null;
        return @errorFromInt(code);
    }

    fn poke(e: *Engine) void {
        _ = e.wake.fetchAdd(1, .release);
        e.io.futexWake(u32, &e.wake.raw, 1);
    }

    /// Something plays: starts the output's thread, or wakes it.
    fn started(e: *Engine) void {
        if (e.options.device == .manual) return;
        if (e.thread == null) e.thread = std.Thread.spawn(.{}, run, .{e}) catch null;
        e.poke();
    }

    /// Opens the device while anything plays, and mixes into it.
    fn run(e: *Engine) void {
        var buf: [output.frames_per_write * channels]f32 = undefined;
        while (!e.quit.load(.acquire)) {
            const seen = e.wake.load(.acquire);
            if (!e.mix.busy()) {
                e.io.futexWaitUncancelable(u32, &e.wake.raw, seen);
                continue;
            }
            var dev = output.open(e.io) catch |err| blk: {
                e.err.store(@intFromError(err), .release);
                break :blk output.Device.nullDevice(e.io, true);
            };
            if (dev.real) e.err.store(0, .release);
            var idle_frames: u64 = 0;
            const idle_limit = @as(u64, e.options.idle_close_ms) * rate / 1000;
            while (!e.quit.load(.acquire)) {
                const busy = e.mix.mix(&buf);
                dev.write(&buf) catch break;
                if (busy) idle_frames = 0 else {
                    idle_frames += output.frames_per_write;
                    if (idle_frames >= idle_limit) break;
                }
            }
            dev.close();
        }
    }
};

/// A player: plays, pauses, stops, seeks, and sets its volume, pan, speed
/// and loop. The setters return the player, to chain them.
pub const Player = struct {
    engine: *Engine,
    voice: *Voice,

    fn locked(p: Player) *Voice {
        p.engine.mix.lock.lock();
        return p.voice;
    }
    fn unlock(p: Player) void {
        p.engine.mix.lock.unlock();
    }

    /// Plays from where it is; after its end, from the start again.
    pub fn play(p: Player) void {
        const v = p.locked();
        if (v.ended()) {
            v.reset(if (v.loop) v.loop_start else 0);
            v.snap = true;
        } else if (!v.playing and !v.snap) v.fade_in = !v.active;
        v.playing = true;
        p.engine.mix.activate(v);
        p.unlock();
        p.engine.started();
    }

    /// Pauses, fading out over 5 ms.
    pub fn pause(p: Player) void {
        const v = p.locked();
        v.playing = false;
        p.unlock();
    }

    /// Pauses and goes back to the start.
    pub fn stop(p: Player) void {
        const v = p.locked();
        v.playing = false;
        v.active = false;
        for (p.engine.mix.voices.items, 0..) |x, i| if (x == v) {
            _ = p.engine.mix.voices.swapRemove(i);
            break;
        };
        v.reset(0);
        v.snap = true;
        p.unlock();
    }

    /// Whether it plays: false at its end, so a game can wait for a sound.
    pub fn playing(p: Player) bool {
        const v = p.locked();
        defer p.unlock();
        return v.playing and !v.ended();
    }

    /// Moves to `seconds` from the start.
    pub fn seek(p: Player, seconds: f64) void {
        const v = p.locked();
        const f: u64 = @intFromFloat(@max(0, seconds) * v.src_rate);
        v.reset(f);
        v.fade_in = v.playing;
        p.unlock();
    }

    /// Where it is, in seconds.
    pub fn position(p: Player) f64 {
        const v = p.locked();
        defer p.unlock();
        return v.position() / v.src_rate;
    }

    /// How long it plays, in seconds (null: endless or unknown).
    pub fn duration(p: Player) ?f64 {
        const v = p.locked();
        defer p.unlock();
        const n = v.src.length() orelse return null;
        return @as(f64, @floatFromInt(n)) / v.src_rate;
    }

    /// A gain: 1 as decoded, 0 silent (ending a fade under way).
    pub fn setVolume(p: Player, x: f32) Player {
        const v = p.locked();
        v.volume = @max(x, 0);
        v.fade_left = 0;
        v.fade_pause = false;
        p.unlock();
        return p;
    }

    /// Moves its volume to `x` over `seconds`, in a straight line, as it
    /// plays (a crossfade's half, music ducking under speech).
    pub fn fadeTo(p: Player, x: f32, seconds: f64) Player {
        p.locked().fade(@max(x, 0), frames(seconds), null);
        p.unlock();
        return p;
    }

    /// Plays, its volume rising from silence to what it is over `seconds`.
    pub fn fadeIn(p: Player, seconds: f64) void {
        const v = p.locked();
        const to = if (v.fade_pause) v.fade_restore else if (v.fade_left > 0) v.fade_to else v.volume;
        v.volume = 0;
        v.fade(to, frames(seconds), null);
        p.unlock();
        p.play();
    }

    /// Fades to silence over `seconds`, then pauses: a later `play` (or
    /// `fadeIn`) plays at the volume it had.
    pub fn fadeOut(p: Player, seconds: f64) void {
        const v = p.locked();
        const keep = if (v.fade_pause) v.fade_restore else if (v.fade_left > 0) v.fade_to else v.volume;
        v.fade(0, frames(seconds), keep);
        p.unlock();
    }

    fn frames(seconds: f64) u64 {
        return @intFromFloat(@max(0, seconds) * rate);
    }

    /// From the left speaker (-1) to the right (1).
    pub fn setPan(p: Player, x: f32) Player {
        p.locked().pan = std.math.clamp(x, -1, 1);
        p.unlock();
        return p;
    }

    /// Speed and pitch together, as a record's: 2 is an octave higher.
    pub fn setSpeed(p: Player, x: f64) Player {
        p.locked().speed = std.math.clamp(x, 0.01, 16);
        p.unlock();
        return p;
    }

    /// Starts again at the end, without a gap.
    pub fn setLoop(p: Player, on: bool) Player {
        p.locked().loop = on;
        p.unlock();
        return p;
    }

    /// Loops from `end` back to `start` (seconds; `end` null for the end):
    /// a tune's intro plays once, then its loop.
    pub fn setLoopRange(p: Player, start: f64, end: ?f64) Player {
        const v = p.locked();
        v.loop = true;
        v.loop_start = @intFromFloat(@max(0, start) * v.src_rate);
        v.loop_end = if (end) |x| @as(u64, @intFromFloat(@max(0, x) * v.src_rate)) else null;
        p.unlock();
        return p;
    }

    /// Lets the player go: it plays on to its end (or stays paused), then
    /// it is freed. The player can't be used after.
    pub fn release(p: Player) void {
        const v = p.locked();
        v.orphan = true;
        if (!v.active) p.engine.mix.done.append(p.engine.gpa, v) catch {};
        p.unlock();
    }
};

test {
    _ = wav;
    _ = source;
    _ = @import("tests_audio.zig");
    _ = @import("tests_audio_fade.zig");
    _ = formats;
    _ = @import("ogg.zig");
    _ = @import("vorbis_setup.zig");
    _ = @import("vorbis_mdct.zig");
    _ = @import("mp3_frame.zig");
    _ = @import("tests_codecs.zig");
}
