//! The Ogg Vorbis and MP3 decoders, against what FFmpeg decodes. The files
//! in testdata/ were encoded by FFmpeg (libvorbis, libmp3lame, and
//! Windows' Media Foundation MP3 encoder for mfclicks.mp3, which uses
//! intensity stereo) from these sources (`ffmpeg -f lavfi -i ...`):
//!
//!   tone      aevalsrc=0.5*sin(2*PI*440*t):s=44100:d=0.5 (ogg -q:a 3, mp3 96k)
//!   stereo    0.4 sin 440 Hz | 0.3 sin 1000 Hz, 48 kHz, 0.3 s (ogg -q:a 4, mp3 128k)
//!   lsf       0.5 sin 300 Hz, 22.05 kHz, 0.4 s, mp3 32k (MPEG-2)
//!   mpeg25    0.5 sin 200 Hz, 8 kHz, 0.4 s, mp3 16k (MPEG-2.5)
//!   clicks    10 ms bursts of 500 and 700 Hz every 0.1 s, a quiet 3 kHz
//!             tone, 44.1 kHz stereo, 0.6 s: short blocks
//!   noise     anoisesrc=c=pink:a=0.3, stereo, 1 s, mp3 -q:a 6 (mid/side)
//!
//! The Ogg files have 40 ms pages (-page_duration 40000), to seek in.
//! Each `.ref` is FFmpeg's decoding (to floats) of every `stride`th frame,
//! as 16 bit integers.
const std = @import("std");
const audio = @import("audio.zig");
const source = @import("source.zig");
const formats = @import("formats.zig");

const gpa = std.testing.allocator;
const io = std.testing.io;

const File = struct {
    name: []const u8,
    bytes: []const u8,
    ref: []const u8,
    rate: u32,
    channels: u16,
    frames: u64,
    stride: usize,
};

fn file(comptime name: []const u8, rate: u32, channels: u16, frames: u64, stride: usize) File {
    return .{
        .name = name,
        .bytes = @embedFile("testdata/" ++ name),
        .ref = @embedFile("testdata/" ++ name ++ ".ref"),
        .rate = rate,
        .channels = channels,
        .frames = frames,
        .stride = stride,
    };
}

const files = [_]File{
    file("tone.ogg", 44100, 1, 22050, 15),
    file("stereo.ogg", 48000, 2, 14400, 20),
    file("clicks.ogg", 44100, 2, 26460, 37),
    file("tone.mp3", 44100, 1, 22050, 15),
    file("stereo.mp3", 48000, 2, 14400, 20),
    file("noise.mp3", 44100, 2, 44100, 59),
    file("lsf.mp3", 22050, 1, 9349, 8),
    file("mpeg25.mp3", 8000, 1, 3729, 8),
    file("mfclicks.mp3", 44100, 2, 28271, 38),
};

fn decodeAll(d: source.Decoder) ![]f32 {
    const s = try source.Sound.decode(gpa, d);
    defer gpa.destroy(s);
    return s.samples;
}

/// The RMS and largest difference from FFmpeg's samples.
fn compare(f: File, samples: []const f32) [2]f32 {
    const ref: []align(1) const i16 = std.mem.bytesAsSlice(i16, f.ref);
    const ch = f.channels;
    var sum: f64 = 0;
    var max: f32 = 0;
    var n: usize = 0;
    var frame: usize = 0;
    while (frame * ch < samples.len and (frame / f.stride + 1) * ch <= ref.len) : (frame += f.stride) {
        for (0..ch) |c| {
            const r = @as(f32, @floatFromInt(std.mem.littleToNative(i16, ref[frame / f.stride * ch + c]))) / 32767;
            const e = @abs(samples[frame * ch + c] - r);
            sum += e * e;
            max = @max(max, e);
            n += 1;
        }
    }
    return .{ @floatCast(@sqrt(sum / @as(f64, @floatFromInt(@max(n, 1))))), max };
}

test "codecs: Vorbis and MP3 decode from memory as FFmpeg does" {
    const e = try audio.Engine.create(gpa, io, .{ .device = .manual });
    defer e.destroy();
    for (files) |f| {
        errdefer std.debug.print("{s}\n", .{f.name});
        const s = try e.decodeSound(f.bytes);
        defer s.release();
        try std.testing.expectEqual(f.rate, s.rate);
        try std.testing.expectEqual(f.channels, s.channels);
        try std.testing.expectEqual(f.frames, s.frames());
        const err = compare(f, s.samples);
        // 16 bit references: within their rounding.
        try std.testing.expect(err[0] < 2e-5);
        try std.testing.expect(err[1] < 1e-4);
    }
}

fn rms(s: []const f32, ch: usize, c: usize) f32 {
    var sum: f64 = 0;
    var i = c;
    while (i < s.len) : (i += ch) sum += s[i] * s[i];
    return @floatCast(@sqrt(sum / @as(f64, @floatFromInt(s.len / ch))));
}

fn upCrossings(s: []const f32, ch: usize, c: usize) usize {
    var n: usize = 0;
    var i = c + ch;
    while (i < s.len) : (i += ch) if (s[i - ch] < 0 and s[i] >= 0) {
        n += 1;
    };
    return n;
}

/// The RMS difference from `amp * sin(2 pi freq t)`, from frame 0 (gapless).
fn sineError(s: []const f32, ch: usize, c: usize, rate: u32, freq: f32, amp: f32) f32 {
    var sum: f64 = 0;
    const frames = s.len / ch;
    for (0..frames) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(rate));
        const d = s[i * ch + c] - amp * @sin(2 * std.math.pi * freq * t);
        sum += d * d;
    }
    return @floatCast(@sqrt(sum / @as(f64, @floatFromInt(frames))));
}

test "codecs: sines decode to their frequency and amplitude, gaplessly" {
    const Case = struct { f: File, c: usize, freq: f32, amp: f32, gapless: bool };
    const cases = [_]Case{
        .{ .f = files[0], .c = 0, .freq = 440, .amp = 0.5, .gapless = true },
        .{ .f = files[1], .c = 0, .freq = 440, .amp = 0.4, .gapless = true },
        .{ .f = files[1], .c = 1, .freq = 1000, .amp = 0.3, .gapless = true },
        .{ .f = files[3], .c = 0, .freq = 440, .amp = 0.5, .gapless = true },
        .{ .f = files[4], .c = 0, .freq = 440, .amp = 0.4, .gapless = true },
        .{ .f = files[4], .c = 1, .freq = 1000, .amp = 0.3, .gapless = true },
        .{ .f = files[6], .c = 0, .freq = 300, .amp = 0.5, .gapless = false },
        .{ .f = files[7], .c = 0, .freq = 200, .amp = 0.5, .gapless = false },
    };
    for (cases) |k| {
        errdefer std.debug.print("{s} channel {d}\n", .{ k.f.name, k.c });
        const d = try formats.open(gpa, .{ .bytes = k.f.bytes }, false);
        const s = try decodeAll(d);
        defer gpa.free(s);
        const ch = k.f.channels;
        const seconds = @as(f32, @floatFromInt(s.len / ch)) / @as(f32, @floatFromInt(k.f.rate));
        const periods = k.freq * seconds;
        const n: f32 = @floatFromInt(upCrossings(s, ch, k.c));
        try std.testing.expect(@abs(n - periods) <= 2);
        // Away from the edges, a sine's RMS is its amplitude over sqrt 2
        // (within what the encoders lose: LAME at 96 kb/s, 5%).
        const mid = s[s.len / 4 / ch * ch .. s.len * 3 / 4 / ch * ch];
        try std.testing.expectApproxEqAbs(k.amp / std.math.sqrt2, rms(mid, ch, k.c), 0.025);
        if (k.gapless) try std.testing.expect(sineError(s, ch, k.c, k.f.rate, k.freq, k.amp) < 0.02);
    }
}

test "codecs: seeking decodes what decoding from the start does" {
    for (files) |f| {
        errdefer std.debug.print("{s}\n", .{f.name});
        const ch = f.channels;
        const all = try decodeAll(try formats.open(gpa, .{ .bytes = f.bytes }, false));
        defer gpa.free(all);
        const d = try formats.open(gpa, .{ .bytes = f.bytes }, false);
        defer d.deinit();
        const n = f.frames;
        var buf: [1000 * 2]f32 = undefined;
        for ([_]u64{ n / 2, 1, 5000, 1234, n - 300, 0, n / 3 }) |target| {
            if (target >= n) continue;
            try d.seek(target);
            const want = @min(1000, n - target);
            var got: usize = 0;
            while (got < want) {
                const k = try d.read(buf[got * ch .. want * ch]);
                if (k == 0) break;
                got += k;
            }
            try std.testing.expectEqual(want, got);
            for (buf[0 .. want * ch], all[target * ch ..][0 .. want * ch]) |a, b| try std.testing.expectApproxEqAbs(b, a, 1e-6);
        }
        // At the end: nothing more.
        try d.seek(n);
        try std.testing.expectEqual(@as(usize, 0), try d.read(&buf));
    }
}

test "codecs: streams from files, played through the engine" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const e = try audio.Engine.create(gpa, io, .{ .device = .manual });
    defer e.destroy();
    for ([_]File{ files[1], files[4] }) |f| {
        try tmp.dir.writeFile(io, .{ .sub_path = f.name, .data = f.bytes });
        const path = try std.fs.path.join(gpa, &.{ dir, f.name });
        defer gpa.free(path);
        // The file's samples are the memory's.
        const fd = try std.Io.Dir.cwd().openFile(io, path, .{});
        const from_file = try decodeAll(try formats.open(gpa, .{ .file = .{ .file = fd, .io = io } }, true));
        defer gpa.free(from_file);
        const from_memory = try decodeAll(try formats.open(gpa, .{ .bytes = f.bytes }, false));
        defer gpa.free(from_memory);
        try std.testing.expectEqualSlices(f32, from_memory, from_file);
        // Played: 0.3 s at 48 kHz, then silence.
        const p = try e.openStream(path);
        defer p.release();
        try std.testing.expectApproxEqAbs(@as(f64, 0.3), p.duration().?, 0.001);
        p.play();
        const out = try gpa.alloc(f32, 48000 * 2);
        defer gpa.free(out);
        var at: usize = 0;
        while (at < out.len) : (at += 960) _ = e.render(out[at..@min(out.len, at + 960)]);
        try std.testing.expect(rms(out[0 .. 14000 * 2], 2, 0) > 0.2);
        try std.testing.expectEqual(@as(f32, 0), rms(out[15000 * 2 ..], 2, 0));
        try std.testing.expect(!p.playing());
    }
    e.mix.collect();
}

test "codecs: damaged files decode what they can, or fail" {
    for (files) |f| {
        // Cut in half: the first half, about.
        const half = f.bytes[0 .. f.bytes.len / 2];
        const d = formats.open(gpa, .{ .bytes = half }, false) catch continue;
        const s = try decodeAll(d);
        defer gpa.free(s);
        try std.testing.expect(s.len / f.channels <= f.frames);
    }
    // Bytes flipped in the middle of each.
    for (files) |f| {
        const b = try gpa.dupe(u8, f.bytes);
        defer gpa.free(b);
        var prng = std.Random.DefaultPrng.init(f.bytes.len);
        for (0..64) |_| b[b.len / 3 + prng.random().uintLessThan(usize, b.len / 3)] ^= 0x5a;
        const d = formats.open(gpa, .{ .bytes = b }, false) catch continue;
        const s = try decodeAll(d);
        defer gpa.free(s);
    }
    try std.testing.expectError(error.UnsupportedFormat, formats.open(gpa, .{ .bytes = "not audio at all" }, false));
    try std.testing.expectError(error.InvalidOgg, formats.open(gpa, .{ .bytes = "OggS" }, false));
}
