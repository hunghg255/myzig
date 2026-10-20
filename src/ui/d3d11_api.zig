//! Direct3D 11 and DXGI without headers: the entry points, loaded from the
//! system directory when a renderer is first made (so an app that never
//! draws with Direct3D does not import them), the vtable indices of the
//! methods the renderer calls, and the structures they take, all from the
//! Windows SDK's headers. COM methods are called through their objects'
//! vtables, by index (as `windows/com.zig` does).
const std = @import("std");

pub const HRESULT = i32;
pub const Object = *anyopaque;

pub const GUID = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };

pub const iid_dxgi_device: GUID = .{ .a = 0x54ec77fa, .b = 0x1377, .c = 0x44e6, .d = .{ 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c } };
pub const iid_dxgi_device1: GUID = .{ .a = 0x77db970f, .b = 0x6276, .c = 0x48ba, .d = .{ 0xba, 0x28, 0x07, 0x01, 0x43, 0xb4, 0x39, 0x2c } };
pub const iid_dxgi_factory2: GUID = .{ .a = 0x50c83a1c, .b = 0xe072, .c = 0x4c48, .d = .{ 0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0 } };
pub const iid_dxgi_swap_chain2: GUID = .{ .a = 0xa8be2ac4, .b = 0x199f, .c = 0x4946, .d = .{ 0xb3, 0x31, 0x79, 0x59, 0x9f, 0xb9, 0x8d, 0xe7 } };
pub const iid_texture2d: GUID = .{ .a = 0x6f15aaf2, .b = 0xd208, .c = 0x4e89, .d = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c } };

pub fn failed(hr: HRESULT) bool {
    return hr < 0;
}

/// Calls method `index` of `obj` with `args` after the object itself.
pub fn call(obj: Object, index: usize, args: anytype) HRESULT {
    return callAs(HRESULT, obj, index, args);
}

pub fn callAs(comptime R: type, obj: Object, index: usize, args: anytype) R {
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

pub fn release(obj: ?Object) void {
    if (obj) |o| _ = callAs(u32, o, 2, .{});
}

/// ID3D11Device.
pub const dev = struct {
    pub const create_buffer = 3;
    pub const create_texture2d = 5;
    pub const create_srv = 7;
    pub const create_rtv = 9;
    pub const create_input_layout = 11;
    pub const create_vertex_shader = 12;
    pub const create_pixel_shader = 15;
    pub const create_blend_state = 20;
    pub const create_rasterizer_state = 22;
    pub const create_sampler_state = 23;
    pub const create_query = 24;
};

/// ID3D11DeviceContext.
pub const ctx = struct {
    pub const vs_set_constant_buffers = 7;
    pub const ps_set_shader_resources = 8;
    pub const ps_set_shader = 9;
    pub const vs_set_shader = 11;
    pub const draw = 13;
    pub const map = 14;
    pub const unmap = 15;
    pub const ps_set_constant_buffers = 16;
    pub const ia_set_input_layout = 17;
    pub const ia_set_vertex_buffers = 18;
    pub const draw_instanced = 21;
    pub const ia_set_primitive_topology = 24;
    pub const vs_set_shader_resources = 25;
    pub const begin = 27;
    pub const end = 28;
    pub const get_data = 29;
    pub const om_set_render_targets = 33;
    pub const om_set_blend_state = 35;
    pub const rs_set_state = 43;
    pub const rs_set_viewports = 44;
    pub const rs_set_scissor_rects = 45;
    pub const copy_subresource_region = 46;
    pub const copy_resource = 47;
    pub const update_subresource = 48;
    pub const clear_render_target_view = 50;
    pub const clear_state = 110;
    pub const flush = 111;
};

/// IDXGIObject, IDXGIDevice(1), IDXGIFactory(2), IDXGISwapChain.
pub const dxgi = struct {
    pub const get_parent = 6;
    pub const device_get_adapter = 7;
    pub const device1_set_max_latency = 12;
    pub const factory_make_window_association = 8;
    pub const factory2_create_swap_chain_for_hwnd = 15;
    pub const swap_chain_present = 8;
    pub const swap_chain_get_buffer = 9;
    pub const swap_chain_resize_buffers = 13;
    /// IDXGISwapChain1::Present1, with dirty rectangles.
    pub const swap_chain1_present1 = 22;
    /// IDXGISwapChain2.
    pub const swap_chain2_set_max_latency = 31;
    pub const swap_chain2_latency_waitable = 33;
};

/// DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT.
pub const swap_chain_waitable: u32 = 0x40;

/// A RECT (D3D11_RECT): left, top, right, bottom.
pub const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

/// DXGI_PRESENT_PARAMETERS.
pub const PresentParameters = extern struct {
    dirty_count: u32 = 0,
    dirty: ?*const Rect = null,
    scroll: ?*const Rect = null,
    offset: ?*const [2]i32 = null,
};

/// ID3DBlob.
pub const blob = struct {
    pub const pointer = 3;
    pub const size = 4;
};

pub const format_unknown: u32 = 0;
pub const format_r32g32b32a32_float: u32 = 2;
pub const format_r8_unorm: u32 = 61;
pub const format_b8g8r8a8_unorm: u32 = 87;

pub const usage_default: u32 = 0;
pub const usage_dynamic: u32 = 2;
pub const usage_staging: u32 = 3;
pub const bind_vertex_buffer: u32 = 0x1;
pub const bind_constant_buffer: u32 = 0x4;
pub const bind_shader_resource: u32 = 0x8;
pub const bind_render_target: u32 = 0x20;
pub const cpu_write: u32 = 0x10000;
pub const cpu_read: u32 = 0x20000;
pub const map_read: u32 = 1;
pub const map_write_discard: u32 = 4;
pub const topology_triangle_strip: u32 = 5;

pub const BufferDesc = extern struct {
    width: u32,
    usage: u32,
    bind: u32,
    cpu: u32 = 0,
    misc: u32 = 0,
    stride: u32 = 0,
};

pub const SubresourceData = extern struct {
    mem: *const anyopaque,
    pitch: u32,
    slice_pitch: u32 = 0,
};

pub const Texture2DDesc = extern struct {
    width: u32,
    height: u32,
    mips: u32 = 1,
    array: u32 = 1,
    format: u32,
    samples: u32 = 1,
    quality: u32 = 0,
    usage: u32 = usage_default,
    bind: u32 = 0,
    cpu: u32 = 0,
    misc: u32 = 0,
};

pub const InputElement = extern struct {
    name: [*:0]const u8,
    index: u32,
    format: u32 = format_r32g32b32a32_float,
    slot: u32 = 0,
    offset: u32,
    /// Per instance.
    class: u32 = 1,
    step: u32 = 1,
};

pub const RenderTargetBlend = extern struct {
    enable: i32,
    src: u32,
    dst: u32,
    op: u32,
    src_alpha: u32,
    dst_alpha: u32,
    op_alpha: u32,
    mask: u8,
};

pub const BlendDesc = extern struct {
    alpha_to_coverage: i32 = 0,
    independent: i32 = 0,
    targets: [8]RenderTargetBlend,
};

pub const RasterizerDesc = extern struct {
    /// Solid.
    fill: u32 = 3,
    /// None.
    cull: u32 = 1,
    front_ccw: i32 = 0,
    depth_bias: i32 = 0,
    depth_bias_clamp: f32 = 0,
    slope_scaled_depth_bias: f32 = 0,
    depth_clip: i32 = 1,
    scissor: i32 = 0,
    multisample: i32 = 0,
    antialiased_lines: i32 = 0,
};

pub const Viewport = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32,
    h: f32,
    min_depth: f32 = 0,
    max_depth: f32 = 1,
};

pub const Box = extern struct {
    left: u32,
    top: u32,
    front: u32 = 0,
    right: u32,
    bottom: u32,
    back: u32 = 1,
};

/// D3D11_SHADER_RESOURCE_VIEW_DESC of a buffer of `n` elements.
pub const SrvBuffer = extern struct {
    format: u32 = format_r32g32b32a32_float,
    /// D3D11_SRV_DIMENSION_BUFFER.
    dimension: u32 = 1,
    first: u32 = 0,
    n: u32,
    pad: [2]u32 = .{ 0, 0 },
};

pub const Mapped = extern struct {
    data: ?[*]u8 = null,
    row_pitch: u32 = 0,
    depth_pitch: u32 = 0,
};

pub const SwapChainDesc1 = extern struct {
    width: u32,
    height: u32,
    format: u32 = format_b8g8r8a8_unorm,
    stereo: i32 = 0,
    samples: u32 = 1,
    quality: u32 = 0,
    /// Render target output.
    usage: u32 = 0x20,
    buffers: u32 = 2,
    /// None: while resizing, a frame shows at its size, not stretched.
    scaling: u32 = 1,
    /// Flip sequential: the buffers keep what was drawn, so a frame draws
    /// only what changed (`damage.zig`) and presents it as dirty.
    effect: u32 = 3,
    /// Ignored: frames are opaque.
    alpha: u32 = 3,
    flags: u32 = swap_chain_waitable,
};

const CreateDevice = *const fn (adapter: ?Object, driver: u32, software: ?*anyopaque, flags: u32, levels: [*]const u32, n: u32, sdk: u32, device: *?Object, level: ?*u32, context: *?Object) callconv(.winapi) HRESULT;
const Compile = *const fn (src: [*]const u8, len: usize, name: ?[*:0]const u8, defines: ?*const anyopaque, include: ?*anyopaque, entry: [*:0]const u8, target: [*:0]const u8, flags1: u32, flags2: u32, code: *?Object, errors: *?Object) callconv(.winapi) HRESULT;

extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?*anyopaque, flags: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

/// `name` of the system directory's `dll`, or null.
fn proc(comptime T: type, comptime dll: []const u8, name: [*:0]const u8) ?T {
    const load_from_system32 = 0x800;
    const module = LoadLibraryExW(std.unicode.utf8ToUtf16LeStringLiteral(dll), null, load_from_system32) orelse return null;
    return @ptrCast(@alignCast(GetProcAddress(module, name) orelse return null));
}

pub const Device = struct { device: Object, context: Object };

/// A device on the GPU, made to draw BGRA (feature level 10.0 or later),
/// or null: no Direct3D, or no hardware for it (Windows' software
/// rasterizer is not taken: myzig's CPU renderer draws the same pixels).
pub fn createDevice() ?Device {
    const create = proc(CreateDevice, "d3d11.dll", "D3D11CreateDevice") orelse return null;
    const levels = [_]u32{ 0xb000, 0xa100, 0xa000 }; // 11.0, 10.1, 10.0
    const bgra_support = 0x20;
    // One draw a frame needs no driver thread of its own, and that thread's
    // buffers cost about 20 MB a device (measured on Intel's iGPU).
    const no_internal_threading = 0x8;
    const hardware = 1;
    var device: ?Object = null;
    var context: ?Object = null;
    const sdk_version = 7;
    if (failed(create(null, hardware, null, bgra_support | no_internal_threading, &levels, levels.len, sdk_version, &device, null, &context))) return null;
    return .{ .device = device orelse return null, .context = context orelse return null };
}

/// The bytecode of `entry` of `source` for `target` ("vs_4_0"), compiled
/// by Windows' shader compiler; the caller frees it.
pub fn compile(gpa: std.mem.Allocator, source: []const u8, entry: [*:0]const u8, target: [*:0]const u8) ![]u8 {
    const f = proc(Compile, "d3dcompiler_47.dll", "D3DCompile") orelse return error.NoShaderCompiler;
    const optimization_level3 = 1 << 15;
    var code: ?Object = null;
    var errors: ?Object = null;
    const hr = f(source.ptr, source.len, "d3d11.hlsl", null, null, entry, target, optimization_level3, 0, &code, &errors);
    defer release(errors);
    defer release(code);
    if (failed(hr) or code == null) {
        if (errors) |e| std.log.err("myzig: shader: {s}", .{blobBytes(e)});
        return error.ShaderCompile;
    }
    return gpa.dupe(u8, blobBytes(code.?));
}

fn blobBytes(b: Object) []const u8 {
    const p = callAs([*]const u8, b, blob.pointer, .{});
    return p[0..callAs(usize, b, blob.size, .{})];
}
