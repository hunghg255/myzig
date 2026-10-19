//! macOS's output: an Audio Queue on the default output (which follows
//! it), from AudioToolbox loaded with dlopen. The queue calls back on a
//! thread of its own when a buffer has played; `write` waits for a free
//! buffer on a semaphore, fills it and enqueues it.
const std = @import("std");
const mixer = @import("mixer.zig");
const frames_per_write = mixer.rate / 100;

const AudioStreamBasicDescription = extern struct {
    sample_rate: f64,
    format_id: u32,
    format_flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    bytes_per_frame: u32,
    channels_per_frame: u32,
    bits_per_channel: u32,
    reserved: u32 = 0,
};
const AudioQueueBuffer = extern struct {
    capacity: u32,
    data: [*]u8,
    size: u32,
    user_data: ?*anyopaque,
    packet_capacity: u32,
    packets: ?*anyopaque,
    packet_count: u32,
};
const Callback = *const fn (user: ?*anyopaque, queue: *anyopaque, buffer: *AudioQueueBuffer) callconv(.c) void;

const Api = struct {
    new_output: *const fn (format: *const AudioStreamBasicDescription, cb: Callback, user: ?*anyopaque, run_loop: ?*anyopaque, mode: ?*anyopaque, flags: u32, out: *?*anyopaque) callconv(.c) i32,
    allocate_buffer: *const fn (q: *anyopaque, size: u32, out: *?*AudioQueueBuffer) callconv(.c) i32,
    enqueue_buffer: *const fn (q: *anyopaque, b: *AudioQueueBuffer, n: u32, descs: ?*const anyopaque) callconv(.c) i32,
    start: *const fn (q: *anyopaque, at: ?*const anyopaque) callconv(.c) i32,
    stop: *const fn (q: *anyopaque, immediate: u8) callconv(.c) i32,
    dispose: *const fn (q: *anyopaque, immediate: u8) callconv(.c) i32,
};
extern "c" fn dispatch_semaphore_create(value: isize) ?*anyopaque;
extern "c" fn dispatch_semaphore_wait(s: *anyopaque, timeout: u64) isize;
extern "c" fn dispatch_semaphore_signal(s: *anyopaque) isize;
extern "c" fn dispatch_release(o: *anyopaque) void;
extern "c" fn dispatch_time(when: u64, delta: i64) u64;

var api: ?Api = null;
var tried = false;

const k_lpcm: u32 = 0x6c70636d; // 'lpcm'
const k_float_packed: u32 = 1 | 8; // float, packed
const buffers = 4;

pub const Device = struct {
    queue: *anyopaque,
    free: *anyopaque,
    ring: [buffers]*AudioQueueBuffer,
    next: usize = 0,
    started: bool = false,

    pub fn write(d: *Device, samples: []const f32) !void {
        // A buffer has played (or was never used); a second at most.
        if (dispatch_semaphore_wait(d.free, dispatch_time(0, std.time.ns_per_s)) != 0) return error.AudioQueueStalled;
        const b = d.ring[d.next];
        d.next = (d.next + 1) % buffers;
        const bytes = std.mem.sliceAsBytes(samples);
        @memcpy(b.data[0..bytes.len], bytes);
        b.size = @intCast(bytes.len);
        if (api.?.enqueue_buffer(d.queue, b, 0, null) != 0) return error.AudioQueue;
        if (!d.started) {
            d.started = true;
            if (api.?.start(d.queue, null) != 0) return error.AudioQueue;
        }
    }

    pub fn close(d: *Device) void {
        _ = api.?.stop(d.queue, 1);
        _ = api.?.dispose(d.queue, 1);
        dispatch_release(d.free);
    }
};

fn onBuffer(user: ?*anyopaque, _: *anyopaque, _: *AudioQueueBuffer) callconv(.c) void {
    _ = dispatch_semaphore_signal(user.?);
}

pub fn open() !Device {
    if (!tried) {
        tried = true;
        const lib = std.c.dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", .{ .NOW = true });
        if (lib) |l| {
            var a: Api = undefined;
            const names = [_][:0]const u8{ "AudioQueueNewOutput", "AudioQueueAllocateBuffer", "AudioQueueEnqueueBuffer", "AudioQueueStart", "AudioQueueStop", "AudioQueueDispose" };
            var ok = true;
            inline for (@typeInfo(Api).@"struct".field_names, names) |f, n| {
                if (std.c.dlsym(l, n)) |sym| @field(a, f) = @ptrCast(@alignCast(sym)) else ok = false;
            }
            if (ok) api = a;
        }
    }
    const a = api orelse return error.NoAudioOutput;
    const format: AudioStreamBasicDescription = .{
        .sample_rate = mixer.rate,
        .format_id = k_lpcm,
        .format_flags = k_float_packed,
        .bytes_per_packet = mixer.channels * 4,
        .frames_per_packet = 1,
        .bytes_per_frame = mixer.channels * 4,
        .channels_per_frame = mixer.channels,
        .bits_per_channel = 32,
    };
    const free = dispatch_semaphore_create(buffers) orelse return error.NoAudioOutput;
    errdefer dispatch_release(free);
    var q: ?*anyopaque = null;
    // No run loop: the queue calls back on a thread of its own.
    if (a.new_output(&format, onBuffer, free, null, null, 0, &q) != 0) return error.NoAudioOutput;
    var d: Device = .{ .queue = q.?, .free = free, .ring = undefined };
    for (&d.ring) |*b| {
        var out: ?*AudioQueueBuffer = null;
        if (a.allocate_buffer(d.queue, frames_per_write * mixer.channels * 4, &out) != 0) {
            _ = a.dispose(d.queue, 1);
            return error.NoAudioOutput;
        }
        b.* = out.?;
    }
    return d;
}
