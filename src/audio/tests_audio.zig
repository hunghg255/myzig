//! Audio through a manual engine: frames pulled by the test, as an output
//! would pull them, and written to a WAV sink. No sound is played.
const std = @import("std");
const audio = @import("audio.zig");

const gpa = std.testing.allocator;
const io = std.testing.io;

fn engine() !*audio.Engine {
    return audio.Engine.create(gpa, io, .{ .device = .manual });
}

/// A sine of `freq` Hz, `seconds` long, mono at `rate`, as a WAV file.
fn sineWav(rate: u32, freq: f32, seconds: f32, amp: f32) ![]u8 {
    const n: usize = @intFromFloat(@as(f32, @floatFromInt(rate)) * seconds);
    const s = try gpa.alloc(f32, n);
    defer gpa.free(s);
    for (s, 0..) |*x, i| x.* = amp * @sin(2 * std.math.pi * freq * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(rate)));
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try audio.wav.write(&aw.writer, s, rate, 1, .pcm16);
    return aw.toOwnedSlice();
}

/// Pulls `frames` frames (stereo) from the engine.
fn pull(e: *audio.Engine, frames: usize) ![]f32 {
    const out = try gpa.alloc(f32, frames * 2);
    var at: usize = 0;
    while (at < out.len) : (at += 480 * 2) _ = e.render(out[at..@min(out.len, at + 480 * 2)]);
    return out;
}

fn rms(s: []const f32, stride: usize, offset: usize) f32 {
    var sum: f64 = 0;
    var n: usize = 0;
    var i = offset;
    while (i < s.len) : (i += stride) {
        sum += s[i] * s[i];
        n += 1;
    }
    return @floatCast(@sqrt(sum / @as(f64, @floatFromInt(@max(n, 1)))));
}

/// Zero crossings of the left channel going up: a sine's frequency.
fn upCrossings(s: []const f32) usize {
    var n: usize = 0;
    var i: usize = 2;
    while (i < s.len) : (i += 2) if (s[i - 2] < 0 and s[i] >= 0) {
        n += 1;
    };
    return n;
}

test "audio: a sound decoded from WAV plays, resampled to 48 kHz, and ends" {
    const e = try engine();
    defer e.destroy();
    const bytes = try sineWav(22050, 441, 0.5, 0.5);
    defer gpa.free(bytes);
    const s = try e.decodeSound(bytes);
    defer s.release();
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), s.duration(), 0.001);
    const p = try e.newPlayer(s);
    defer p.release();
    p.play();
    try std.testing.expect(p.playing());
    // A second: half of it the sound, at 48 kHz.
    const out = try pull(e, 48000);
    defer gpa.free(out);
    const first = out[0..48000];
    // 441 Hz for half a second: 220 periods, whatever the rates.
    const crossings = upCrossings(first);
    try std.testing.expect(crossings >= 218 and crossings <= 222);
    // Mono plays in both channels at equal power: 0.5 amplitude each.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5 / std.math.sqrt2), rms(first[1000..], 2, 0), 0.02);
    try std.testing.expectApproxEqAbs(rms(first[1000..], 2, 0), rms(first[1000..], 2, 1), 0.001);
    // Then silence, and the player ended.
    try std.testing.expectEqual(@as(f32, 0), rms(out[49000..], 1, 0));
    try std.testing.expect(!p.playing());
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), p.position(), 0.01);
}

test "audio: several sounds mix, volume and pan, the master volume" {
    const e = try engine();
    defer e.destroy();
    const a_bytes = try sineWav(48000, 300, 1, 0.25);
    defer gpa.free(a_bytes);
    const a = try e.decodeSound(a_bytes);
    defer a.release();
    // Two players of one sound, in phase: twice as loud.
    const p1 = try e.newPlayer(a);
    defer p1.release();
    const p2 = try e.newPlayer(a);
    defer p2.release();
    p1.play();
    p2.play();
    const both = try pull(e, 4800);
    defer gpa.free(both);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5 / std.math.sqrt2), rms(both, 2, 0), 0.01);
    // Panned hard left: nothing on the right (after the 5 ms ramp).
    _ = p1.setPan(-1);
    _ = p2.setPan(-1).setVolume(0);
    const left = try pull(e, 4800);
    defer gpa.free(left);
    try std.testing.expect(rms(left[960..], 2, 1) < 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), rms(left[960..], 2, 0), 0.01);
    e.setVolume(0.5);
    const half = try pull(e, 4800);
    defer gpa.free(half);
    try std.testing.expectApproxEqAbs(@as(f32, 0.125), rms(half[960..], 2, 0), 0.01);
}

test "audio: pausing ramps down without a click, loops play on, speed raises the pitch" {
    const e = try engine();
    defer e.destroy();
    const bytes = try sineWav(48000, 480, 0.1, 0.8);
    defer gpa.free(bytes);
    const s = try e.decodeSound(bytes);
    defer s.release();
    const p = try e.newPlayer(s);
    defer p.release();
    _ = p.setLoop(true);
    p.play();
    const loud = try pull(e, 480);
    defer gpa.free(loud);
    p.pause();
    const fade = try pull(e, 480);
    defer gpa.free(fade);
    // The fade's first sample is next to the last one played: no jump.
    try std.testing.expect(@abs(fade[0] - loud[loud.len - 2]) < 0.1);
    try std.testing.expectEqual(@as(f32, 0), rms(fade[480..], 1, 0));
    // Looping: still playing after ten times its length.
    p.play();
    const long = try pull(e, 48000);
    defer gpa.free(long);
    try std.testing.expect(p.playing());
    try std.testing.expect(rms(long[40000..], 2, 0) > 0.4);
    // Twice as fast: twice the crossings.
    p.stop();
    _ = p.setSpeed(2);
    p.play();
    const fast = try pull(e, 4800);
    defer gpa.free(fast);
    const c = upCrossings(fast);
    try std.testing.expect(c >= 94 and c <= 98);
}

test "audio: a WAV sink records what the engine plays" {
    const e = try engine();
    defer e.destroy();
    const bytes = try sineWav(48000, 1000, 0.05, 0.5);
    defer gpa.free(bytes);
    const s = try e.decodeSound(bytes);
    defer s.release();
    e.play(s); // a player of its own, freed when it ends
    const out = try pull(e, 4800);
    defer gpa.free(out);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try audio.wav.write(&aw.writer, out, audio.rate, audio.channels, .float32);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "out.wav", .data = aw.written() });
    // Read back from the file, as a stream decodes it.
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "out.wav" });
    defer gpa.free(path);
    const p = try e.openStream(path);
    defer p.release();
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), p.duration().?, 0.001);
    p.play();
    const again = try pull(e, 4800);
    defer gpa.free(again);
    // The first 50 ms are the sound, with its rms.
    try std.testing.expectApproxEqAbs(rms(out[200..4800], 1, 0), rms(again[200..4800], 1, 0), 0.01);
    e.mix.collect();
}

test "audio: a decoder of the app's own (a synthesizer), endless" {
    const e = try engine();
    defer e.destroy();
    const Tone = struct {
        pos: u64 = 0,
        fn read(ptr: *anyopaque, dst: []f32) anyerror!usize {
            const t: *@This() = @ptrCast(@alignCast(ptr));
            for (dst) |*x| {
                x.* = 0.2 * @sin(2 * std.math.pi * 440 * @as(f32, @floatFromInt(t.pos)) / 48000);
                t.pos += 1;
            }
            return dst.len;
        }
        fn seek(ptr: *anyopaque, f: u64) anyerror!void {
            const t: *@This() = @ptrCast(@alignCast(ptr));
            t.pos = f;
        }
        fn deinit(_: *anyopaque) void {}
    };
    var tone: Tone = .{};
    const p = try e.newStreamPlayer(.{ .ptr = &tone, .vtable = &.{ .read = Tone.read, .seek = Tone.seek, .deinit = Tone.deinit }, .rate = 48000, .channels = 1, .frames = null });
    defer p.release();
    try std.testing.expect(p.duration() == null);
    p.play();
    const out = try pull(e, 48000);
    defer gpa.free(out);
    const c = upCrossings(out);
    try std.testing.expect(c >= 438 and c <= 442);
    try std.testing.expect(p.playing());
}
