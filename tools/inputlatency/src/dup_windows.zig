//! Reading the probe back from the desktop on Windows, through DXGI's
//! desktop duplication: each desktop image the compositor presents comes
//! with the time it was presented (`LastPresentTime`, on the
//! QueryPerformanceCounter clock), and the tool copies the one pixel of
//! the probe out of it. Only that pixel of the tool's own window is read.
//! COM through vtables, by index, from the Windows SDK's headers.
const std = @import("std");

const HRESULT = i32;
const Object = *anyopaque;
const GUID = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
pub const RECT = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };

const iid_dxgi_device: GUID = .{ .a = 0x54ec77fa, .b = 0x1377, .c = 0x44e6, .d = .{ 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c } };
const iid_dxgi_output1: GUID = .{ .a = 0x00cddea8, .b = 0x939b, .c = 0x4b83, .d = .{ 0xa3, 0x40, 0xa6, 0x85, 0x22, 0x66, 0x66, 0xcc } };
const iid_texture2d: GUID = .{ .a = 0x6f15aaf2, .b = 0xd208, .c = 0x4e89, .d = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c } };

const wait_timeout: HRESULT = @bitCast(@as(u32, 0x887A0027));

fn callAs(comptime R: type, obj: Object, index: usize, args: anytype) R {
    const info = @typeInfo(@TypeOf(args)).@"struct";
    const params = comptime blk: {
        var p: [info.field_types.len + 1]type = undefined;
        p[0] = Object;
        for (info.field_types, 0..) |t, i| p[i + 1] = t;
        break :blk p;
    };
    const F = @Fn(&params, &@splat(.{}), R, .{ .@"callconv" = .winapi });
    const vtbl: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    const f: *const F = @ptrCast(@alignCast(vtbl.*[index]));
    return @call(.auto, f, .{obj} ++ args);
}

fn call(obj: Object, index: usize, args: anytype) HRESULT {
    return callAs(HRESULT, obj, index, args);
}

fn release(obj: ?Object) void {
    if (obj) |o| _ = callAs(u32, o, 2, .{});
}

fn failed(hr: HRESULT) bool {
    return hr < 0;
}

const OutputDesc = extern struct {
    name: [32]u16,
    desktop: RECT,
    attached: i32,
    rotation: u32,
    monitor: ?*anyopaque,
};

const FrameInfo = extern struct {
    last_present: i64,
    last_mouse_update: i64,
    accumulated: u32,
    rects_coalesced: i32,
    protected_masked: i32,
    pointer_x: i32,
    pointer_y: i32,
    pointer_visible: i32,
    metadata_size: u32,
    pointer_shape_size: u32,
};

const Texture2DDesc = extern struct {
    width: u32,
    height: u32,
    mip_levels: u32 = 1,
    array_size: u32 = 1,
    format: u32 = 87, // DXGI_FORMAT_B8G8R8A8_UNORM, as duplication hands images out
    sample_count: u32 = 1,
    sample_quality: u32 = 0,
    usage: u32 = 3, // D3D11_USAGE_STAGING
    bind: u32 = 0,
    cpu_access: u32 = 0x20000, // D3D11_CPU_ACCESS_READ
    misc: u32 = 0,
};

const Box = extern struct { left: u32, top: u32, front: u32 = 0, right: u32, bottom: u32, back: u32 = 1 };
const Mapped = extern struct { data: ?[*]const u8 = null, row_pitch: u32 = 0, depth_pitch: u32 = 0 };

const CreateDevice = *const fn (?Object, u32, ?*anyopaque, u32, ?[*]const u32, u32, u32, *?Object, ?*u32, *?Object) callconv(.winapi) HRESULT;
extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

/// The desktop image of the output showing a point, duplicated.
pub const Duplication = struct {
    device: Object,
    context: Object,
    dup: Object,
    staging: Object,
    /// The output's place on the desktop.
    desktop: RECT,

    /// The duplication of the output whose desktop contains `x`, `y`
    /// (desktop pixels).
    pub fn open(x: i32, y: i32) !Duplication {
        const lib = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("d3d11.dll")) orelse return error.NoDirect3D;
        const create: CreateDevice = @ptrCast(GetProcAddress(lib, "D3D11CreateDevice") orelse return error.NoDirect3D);
        var device: ?Object = null;
        var context: ?Object = null;
        if (failed(create(null, 1, null, 0x20, null, 0, 7, &device, null, &context))) return error.NoDevice;
        errdefer release(device);
        errdefer release(context);
        var dxgi: ?Object = null;
        if (failed(call(device.?, 0, .{ &iid_dxgi_device, &dxgi }))) return error.NoDxgi;
        defer release(dxgi);
        var adapter: ?Object = null;
        if (failed(call(dxgi.?, 7, .{&adapter}))) return error.NoAdapter;
        defer release(adapter);
        var i: u32 = 0;
        while (true) : (i += 1) {
            var output: ?Object = null;
            if (failed(call(adapter.?, 7, .{ i, &output }))) return error.NoOutput;
            defer release(output);
            var desc: OutputDesc = undefined;
            if (failed(call(output.?, 7, .{&desc}))) continue;
            const r = desc.desktop;
            if (x < r.left or x >= r.right or y < r.top or y >= r.bottom) continue;
            var output1: ?Object = null;
            if (failed(call(output.?, 0, .{ &iid_dxgi_output1, &output1 }))) return error.NoOutput1;
            defer release(output1);
            var dup: ?Object = null;
            if (failed(call(output1.?, 22, .{ device.?, &dup }))) return error.NoDuplication;
            errdefer release(dup);
            const td: Texture2DDesc = .{ .width = 1, .height = 1 };
            var staging: ?Object = null;
            if (failed(call(device.?, 5, .{ &td, @as(?*const anyopaque, null), &staging }))) return error.NoTexture;
            return .{ .device = device.?, .context = context.?, .dup = dup.?, .staging = staging.?, .desktop = r };
        }
    }

    pub fn close(d: *Duplication) void {
        release(d.staging);
        release(d.dup);
        release(d.context);
        release(d.device);
    }

    pub const Pixel = struct {
        /// When the desktop image was presented, in counter ticks.
        presented: i64,
        bgra: [4]u8,
    };

    /// The next desktop image presented within `timeout_ms`, and the pixel
    /// at `x`, `y` (desktop pixels) of it; null when none came.
    pub fn next(d: *Duplication, timeout_ms: u32, x: i32, y: i32) !?Pixel {
        var info: FrameInfo = undefined;
        var resource: ?Object = null;
        const hr = call(d.dup, 8, .{ timeout_ms, &info, &resource });
        if (hr == wait_timeout) return null;
        if (failed(hr)) return error.AcquireFailed;
        defer _ = call(d.dup, 14, .{});
        defer release(resource);
        // Only the pointer moved: the image is the last one.
        if (info.last_present == 0) return null;
        var tex: ?Object = null;
        if (failed(call(resource.?, 0, .{ &iid_texture2d, &tex }))) return error.NoTexture;
        defer release(tex);
        const px: u32 = @intCast(x - d.desktop.left);
        const py: u32 = @intCast(y - d.desktop.top);
        const box: Box = .{ .left = px, .top = py, .right = px + 1, .bottom = py + 1 };
        callAs(void, d.context, 46, .{ d.staging, @as(u32, 0), @as(u32, 0), @as(u32, 0), @as(u32, 0), tex.?, @as(u32, 0), &box });
        var m: Mapped = .{};
        if (failed(call(d.context, 14, .{ d.staging, @as(u32, 0), @as(u32, 1), @as(u32, 0), &m }))) return error.MapFailed;
        defer callAs(void, d.context, 15, .{ d.staging, @as(u32, 0) });
        const p = m.data orelse return error.MapFailed;
        return .{ .presented = info.last_present, .bgra = p[0..4].* };
    }
};
