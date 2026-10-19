//! Linux's output: PulseAudio's simple API (which PipeWire serves as
//! well), else ALSA's default device, both loaded with dlopen.
const std = @import("std");
const mixer = @import("mixer.zig");
const frames_per_write = mixer.rate / 100;

const SampleSpec = extern struct { format: i32, rate: u32, channels: u8 };
const BufferAttr = extern struct { max_length: u32, tlength: u32, prebuf: u32, minreq: u32, fragsize: u32 };
const PA_STREAM_PLAYBACK = 1;
const PA_SAMPLE_FLOAT32LE = 5;
const SND_PCM_STREAM_PLAYBACK = 0;
const SND_PCM_FORMAT_FLOAT_LE = 14;
const SND_PCM_ACCESS_RW_INTERLEAVED = 3;

const Pulse = struct {
    new: *const fn (server: ?[*:0]const u8, name: [*:0]const u8, dir: i32, dev: ?[*:0]const u8, stream: [*:0]const u8, spec: *const SampleSpec, map: ?*const anyopaque, attr: ?*const BufferAttr, err: *i32) callconv(.c) ?*anyopaque,
    write: *const fn (s: *anyopaque, data: *const anyopaque, bytes: usize, err: *i32) callconv(.c) i32,
    free: *const fn (s: *anyopaque) callconv(.c) void,
};

const Alsa = struct {
    open: *const fn (pcm: *?*anyopaque, name: [*:0]const u8, stream: i32, mode: i32) callconv(.c) i32,
    set_params: *const fn (pcm: *anyopaque, format: i32, access: i32, channels: u32, rate: u32, soft_resample: i32, latency: u32) callconv(.c) i32,
    writei: *const fn (pcm: *anyopaque, buf: *const anyopaque, frames: usize) callconv(.c) isize,
    recover: *const fn (pcm: *anyopaque, err: i32, silent: i32) callconv(.c) i32,
    close: *const fn (pcm: *anyopaque) callconv(.c) i32,
};

var pulse: ?Pulse = null;
var alsa: ?Alsa = null;
var tried_pulse = false;
var tried_alsa = false;

fn load(comptime T: type, lib_name: [:0]const u8, comptime names: []const [:0]const u8) ?T {
    const lib = std.c.dlopen(lib_name, .{ .NOW = true }) orelse return null;
    var t: T = undefined;
    inline for (@typeInfo(T).@"struct".field_names, names) |f, n| {
        const sym = std.c.dlsym(lib, n) orelse return null;
        @field(t, f) = @ptrCast(@alignCast(sym));
    }
    return t;
}

pub const Device = struct {
    pa: ?*anyopaque = null,
    pcm: ?*anyopaque = null,

    pub fn write(d: *Device, samples: []const f32) !void {
        if (d.pa) |s| {
            var code: i32 = 0;
            if (pulse.?.write(s, samples.ptr, samples.len * 4, &code) < 0) return error.PulseAudio;
            return;
        }
        const pcm = d.pcm.?;
        var at: usize = 0;
        const frames = samples.len / mixer.channels;
        while (at < frames) {
            const n = alsa.?.writei(pcm, samples[at * mixer.channels ..].ptr, frames - at);
            if (n < 0) {
                // An underrun, a suspend: recover, or give up.
                if (alsa.?.recover(pcm, @intCast(n), 1) < 0) return error.Alsa;
                continue;
            }
            at += @intCast(n);
        }
    }

    pub fn close(d: *Device) void {
        if (d.pa) |s| pulse.?.free(s);
        if (d.pcm) |p| _ = alsa.?.close(p);
        d.* = .{};
    }
};

pub fn open() !Device {
    if (!tried_pulse) {
        tried_pulse = true;
        pulse = load(Pulse, "libpulse-simple.so.0", &.{ "pa_simple_new", "pa_simple_write", "pa_simple_free" });
    }
    if (pulse) |pa| {
        const spec: SampleSpec = .{ .format = PA_SAMPLE_FLOAT32LE, .rate = mixer.rate, .channels = mixer.channels };
        const frame = mixer.channels * 4;
        const attr: BufferAttr = .{ .max_length = std.math.maxInt(u32), .tlength = mixer.rate / 25 * frame, .prebuf = std.math.maxInt(u32), .minreq = frames_per_write * frame, .fragsize = std.math.maxInt(u32) };
        var code: i32 = 0;
        if (pa.new(null, "myzig", PA_STREAM_PLAYBACK, null, "myzig", &spec, null, &attr, &code)) |s| return .{ .pa = s };
    }
    if (!tried_alsa) {
        tried_alsa = true;
        alsa = load(Alsa, "libasound.so.2", &.{ "snd_pcm_open", "snd_pcm_set_params", "snd_pcm_writei", "snd_pcm_recover", "snd_pcm_close" });
    }
    const a = alsa orelse return error.NoAudioOutput;
    var pcm: ?*anyopaque = null;
    if (a.open(&pcm, "default", SND_PCM_STREAM_PLAYBACK, 0) < 0) return error.NoAudioOutput;
    if (a.set_params(pcm.?, SND_PCM_FORMAT_FLOAT_LE, SND_PCM_ACCESS_RW_INTERLEAVED, mixer.channels, mixer.rate, 1, 40000) < 0) {
        _ = a.close(pcm.?);
        return error.Alsa;
    }
    return .{ .pcm = pcm };
}
