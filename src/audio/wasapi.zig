//! Windows' output: WASAPI in shared mode on the default output, opened
//! again when the default changes or the device goes. Every call runs on
//! the engine's output thread, in COM's multithreaded apartment.
const std = @import("std");
const com = @import("../windows/com.zig");
const mixer = @import("mixer.zig");

const HANDLE = *anyopaque;
extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) com.HRESULT;
extern "ole32" fn CoCreateInstance(clsid: *const com.GUID, outer: ?*anyopaque, ctx: u32, iid: *const com.GUID, out: *?com.Object) callconv(.winapi) com.HRESULT;
extern "ole32" fn CoTaskMemFree(p: ?*anyopaque) callconv(.winapi) void;
extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual: i32, initial: i32, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

const clsid_enumerator = com.GUID.parse("bcde0395-e52f-467c-8e3d-c4579291692e");
const iid_enumerator = com.GUID.parse("a95664d2-9614-4f35-a746-de8db636171e");
const iid_audio_client = com.GUID.parse("1cb9ad4c-dbfa-4c32-b178-c2f568a703b2");
const iid_render_client = com.GUID.parse("f294acfc-3146-4483-a7bf-addca7c260e2");
const subtype_float = com.GUID.parse("00000003-0000-0010-8000-00aa00389b71");

const WaveFormatExtensible = extern struct {
    format_tag: u16 align(1) = 0xfffe,
    channels: u16 align(1) = mixer.channels,
    samples_per_sec: u32 align(1) = mixer.rate,
    avg_bytes_per_sec: u32 align(1) = mixer.rate * mixer.channels * 4,
    block_align: u16 align(1) = mixer.channels * 4,
    bits_per_sample: u16 align(1) = 32,
    size: u16 align(1) = 22,
    valid_bits: u16 align(1) = 32,
    channel_mask: u32 align(1) = 0x1 | 0x2,
    sub_format: com.GUID align(1) = subtype_float,
};

const CLSCTX_ALL = 0x17;
const E_NOTFOUND: u32 = 0x80070490;
const FLAGS: u32 = 0x00040000 | 0x00080000 | 0x80000000 | 0x08000000; // event callback, no persist, auto convert, SRC quality

var com_ready = false;

pub const Device = struct {
    enumerator: ?com.Object = null,
    client: ?com.Object = null,
    render: ?com.Object = null,
    event: ?HANDLE = null,
    frames: u32 = 0,
    /// The endpoint's id, to see the default output change.
    id: [128]u16 = @splat(0),
    checked: u64 = 0,

    pub fn write(d: *Device, samples: []const f32) !void {
        const n: u32 = @intCast(samples.len / mixer.channels);
        const deadline = GetTickCount64() + 1000;
        while (true) {
            var padding: u32 = 0;
            if (com.failed(com.call(d.client.?, 6, .{&padding}))) return error.AudioClient;
            if (padding <= d.frames and d.frames - padding >= n) break;
            if (GetTickCount64() > deadline) return error.AudioClientUnresponsive;
            _ = WaitForSingleObject(d.event.?, 100);
        }
        var p: ?[*]f32 = null;
        if (com.failed(com.call(d.render.?, 3, .{ n, &p }))) return error.AudioClient;
        @memcpy(p.?[0..samples.len], samples);
        if (com.failed(com.call(d.render.?, 4, .{ n, @as(u32, 0) }))) return error.AudioClient;
        // The default output changing (headphones plugged in) moves a
        // shared stream nowhere: open the new one.
        const now = GetTickCount64();
        if (now - d.checked > 500) {
            d.checked = now;
            var id: [128]u16 = @splat(0);
            defaultId(d.enumerator.?, &id) catch return error.DefaultChanged;
            if (!std.mem.eql(u16, &id, &d.id)) return error.DefaultChanged;
        }
    }

    pub fn close(d: *Device) void {
        if (d.client) |c| _ = com.call(c, 11, .{}); // Stop
        com.release(d.render);
        com.release(d.client);
        com.release(d.enumerator);
        d.render = null;
        d.client = null;
        d.enumerator = null;
        if (d.event) |e| _ = CloseHandle(e);
        d.event = null;
    }
};

fn defaultEndpoint(enumerator: com.Object) !com.Object {
    var dev: ?com.Object = null;
    const hr = com.call(enumerator, 4, .{ @as(u32, 0), @as(u32, 0), &dev }); // eRender, eConsole
    if (@as(u32, @bitCast(hr)) == E_NOTFOUND) return error.NoAudioOutput;
    if (com.failed(hr)) return error.DefaultEndpoint;
    return dev.?;
}

fn defaultId(enumerator: com.Object, out: *[128]u16) !void {
    const dev = try defaultEndpoint(enumerator);
    defer com.release(dev);
    var p: ?[*:0]u16 = null;
    if (com.failed(com.call(dev, 5, .{&p}))) return error.DeviceId;
    defer CoTaskMemFree(p);
    const s = std.mem.sliceTo(p.?, 0);
    const n = @min(s.len, out.len);
    @memcpy(out[0..n], s[0..n]);
}

pub fn open() !Device {
    if (!com_ready) {
        // S_FALSE, already initialized, succeeds as well.
        if (com.failed(CoInitializeEx(null, 0))) return error.CoInitialize;
        com_ready = true;
    }
    var d: Device = .{};
    errdefer d.close();
    if (com.failed(CoCreateInstance(&clsid_enumerator, null, CLSCTX_ALL, &iid_enumerator, &d.enumerator))) return error.DeviceEnumerator;
    const dev = try defaultEndpoint(d.enumerator.?);
    defer com.release(dev);
    try defaultId(d.enumerator.?, &d.id);
    if (com.failed(com.call(dev, 3, .{ &iid_audio_client, @as(u32, CLSCTX_ALL), @as(?*anyopaque, null), &d.client }))) return error.Activate;
    const format: WaveFormatExtensible = .{};
    // 40 ms, converted to the device's format by WASAPI's resampler.
    const duration: i64 = 40 * 10000;
    if (com.failed(com.call(d.client.?, 3, .{ @as(u32, 0), FLAGS, duration, @as(i64, 0), &format, @as(?*anyopaque, null) }))) return error.Initialize;
    if (com.failed(com.call(d.client.?, 4, .{&d.frames}))) return error.BufferSize;
    if (com.failed(com.call(d.client.?, 14, .{ &iid_render_client, &d.render }))) return error.RenderClient;
    d.event = CreateEventW(null, 0, 0, null) orelse return error.Event;
    if (com.failed(com.call(d.client.?, 13, .{d.event.?}))) return error.SetEvent;
    if (com.failed(com.call(d.client.?, 10, .{}))) return error.Start;
    d.checked = GetTickCount64();
    return d;
}
