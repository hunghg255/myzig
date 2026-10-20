//! The Direct3D 11 renderer: one pipeline, one instanced draw per frame,
//! the instances Metal draws (`gpu.zig`, `d3d11.hlsl` after
//! `shader.metal`), into a window's DXGI flip model swap chain or into an
//! offscreen texture. Its pixels are the CPU renderer's (`raster.zig`), to
//! a level or two of blending's rounding, so a window without Direct3D
//! shows the same frames drawn on the CPU. Windows makes it with the first
//! frame a window shows (`windows/surface.zig`).
const std = @import("std");
const d3d = @import("d3d11_api.zig");
const gpu = @import("gpu.zig");
const types = @import("types.zig");
const raster = @import("raster.zig");
const images_mod = @import("images.zig");
const fx_mod = @import("d3d11_fx.zig");
const damage = @import("damage.zig");

pub const Instance = gpu.Instance;
pub const Pixels = gpu.Pixels;
/// Frames timed, for benchmarks.
pub const Timer = @import("d3d11_timing.zig").Timer;
const Object = d3d.Object;
const call = d3d.call;
const callAs = d3d.callAs;
const failed = d3d.failed;
const release = d3d.release;

const shaders = @import("d3d11_gen.zig");
/// `d3d11.hlsl` compiled ahead of time (`zig run src/ui/d3d11_gen.zig`).
const compiled = @embedFile("d3d11.cso");

/// Instance buffers in the ring: the one the GPU may still read is not
/// written (each is also mapped with discard, so the driver renames it).
const frames_in_flight = 2;

/// A texture and the view the shader samples it through.
const Texture = struct {
    tex: ?Object = null,
    srv: ?Object = null,

    fn deinit(t: *Texture) void {
        release(t.srv);
        release(t.tex);
        t.* = .{};
    }
};

pub const Renderer = struct {
    device: Object,
    context: Object,
    vs: ?Object = null,
    ps: ?Object = null,
    layout: ?Object = null,
    blend: ?Object = null,
    rasterizer: ?Object = null,
    /// The frame's constants: the target's size in pixels, and the scale.
    constants: ?Object = null,
    buffers: [frames_in_flight]?Object = @splat(null),
    capacities: [frames_in_flight]usize = @splat(0),
    next_buffer: usize = 0,
    /// The glyph atlas (R8) and the image atlas (BGRA), as uploaded.
    atlas: Texture = .{},
    atlas_size: u32 = 0,
    atlas_generation: u64 = std.math.maxInt(u64),
    images: Texture = .{},
    images_side: u32 = 0,
    images_generation: u64 = std.math.maxInt(u64),
    /// The window's swap chain and its back buffer's view, once attached.
    swap_chain: ?Object = null,
    target: ?Object = null,
    width: u32 = 0,
    height: u32 = 0,
    /// The frame's rows (`gpu.Frame`), when it has any, and their view.
    rows: ?Object = null,
    rows_view: ?Object = null,
    rows_capacity: usize = 0,
    /// The passes of effects and blurred layers, made when first needed.
    fx: fx_mod.Passes = .{},
    /// The rasterizer of frames drawn in part, scissored to the part.
    scissored: ?Object = null,
    /// Frames draw only what changed since the last (`damage.zig`): the
    /// swap chain flips in sequence, so DXGI keeps what its buffers hold
    /// and, as a frame is presented with the area it drew as dirty
    /// (`Present1`), copies in what the last frame showed elsewhere.
    /// `held` tells that the swap chain holds the last frame drawn;
    /// `dirty`, what the frames drawn since the last present changed.
    differ: damage.Differ,
    held: bool = false,
    dirty: Dirty = .none,
    /// The swap chain's flags, and its frame latency object
    /// (`windows/surface_present.zig`), when it has one.
    swap_flags: u32 = 0,
    latency: ?*anyopaque = null,
    /// A frame's instances with its large shadows with continuous corners
    /// cut into pieces (`gpu_corners.zig`).
    pieces: std.ArrayList(Instance) = .empty,

    pub const Dirty = union(enum) { none, part: damage.Box, whole };
    /// How much of a frame `render` drew.
    pub const Drawn = enum { nothing, part, whole };

    /// A renderer on the GPU, or an error when Direct3D 11 (or its shader
    /// compiler) is unavailable: the caller draws on the CPU then.
    pub fn init(gpa: std.mem.Allocator) !Renderer {
        const d = d3d.createDevice() orelse return error.NoDirect3D;
        var self: Renderer = .{ .device = d.device, .context = d.context, .differ = .init(gpa) };
        errdefer self.deinit();
        try self.pipeline(gpa);
        return self;
    }

    fn pipeline(self: *Renderer, gpa: std.mem.Allocator) !void {
        // The bytecode embedded, or, when the shader changed since it was
        // compiled, the shader compiled now (slower to start).
        var owned: [2][]u8 = .{ &.{}, &.{} };
        defer for (owned) |o| gpa.free(o);
        const code = shaders.embedded(compiled) orelse blk: {
            // Only while developing: releases trust the bytecode (a test
            // checks it is the source's) and don't carry the source.
            if (comptime !std.ascii.eqlIgnoreCase(@tagName(@import("builtin").mode), "debug")) return error.StaleShaders;
            std.log.warn("myzig: d3d11.cso is stale: run zig run src/ui/d3d11_gen.zig", .{});
            owned[0] = try d3d.compile(gpa, shaders.source, "vs", "vs_4_0");
            owned[1] = try d3d.compile(gpa, shaders.source, "ps", "ps_4_0");
            break :blk shaders.Code{ .vs = owned[0], .ps = owned[1] };
        };
        const vs_code = code.vs;
        const ps_code = code.ps;
        const dv = self.device;
        if (failed(call(dv, d3d.dev.create_vertex_shader, .{ vs_code.ptr, vs_code.len, @as(?Object, null), &self.vs }))) return error.ShaderCreate;
        if (failed(call(dv, d3d.dev.create_pixel_shader, .{ ps_code.ptr, ps_code.len, @as(?Object, null), &self.ps }))) return error.ShaderCreate;

        // The instance's six float4s, in `gpu.Instance`'s order.
        const elements = [_]d3d.InputElement{
            .{ .name = "RECT", .index = 0, .offset = 0 },
            .{ .name = "COLOR", .index = 0, .offset = 16 },
            .{ .name = "COLOR", .index = 1, .offset = 32 },
            .{ .name = "UV", .index = 0, .offset = 48 },
            .{ .name = "CLIP", .index = 0, .offset = 64 },
            .{ .name = "PARAMS", .index = 0, .offset = 80 },
        };
        comptime std.debug.assert(@sizeOf(Instance) == 96 and @offsetOf(Instance, "radius") == 80);
        if (failed(call(dv, d3d.dev.create_input_layout, .{ &elements, @as(u32, elements.len), vs_code.ptr, vs_code.len, &self.layout }))) return error.InputLayout;

        // Premultiplied alpha: one, one minus source alpha.
        const one = 2;
        const inv_src_alpha = 6;
        const add = 1;
        var blend: d3d.BlendDesc = .{ .targets = @splat(.{ .enable = 0, .src = one, .dst = 1, .op = add, .src_alpha = one, .dst_alpha = 1, .op_alpha = add, .mask = 0xf }) };
        blend.targets[0] = .{ .enable = 1, .src = one, .dst = inv_src_alpha, .op = add, .src_alpha = one, .dst_alpha = inv_src_alpha, .op_alpha = add, .mask = 0xf };
        if (failed(call(dv, d3d.dev.create_blend_state, .{ &blend, &self.blend }))) return error.BlendState;
        const rs: d3d.RasterizerDesc = .{};
        if (failed(call(dv, d3d.dev.create_rasterizer_state, .{ &rs, &self.rasterizer }))) return error.RasterizerState;
        const sc: d3d.RasterizerDesc = .{ .scissor = 1 };
        if (failed(call(dv, d3d.dev.create_rasterizer_state, .{ &sc, &self.scissored }))) return error.RasterizerState;
        const cb: d3d.BufferDesc = .{ .width = 16, .usage = d3d.usage_default, .bind = d3d.bind_constant_buffer };
        if (failed(call(dv, d3d.dev.create_buffer, .{ &cb, @as(?*const d3d.SubresourceData, null), &self.constants }))) return error.Buffer;
    }

    pub fn deinit(self: *Renderer) void {
        self.detach();
        self.fx.deinit();
        release(self.rows_view);
        release(self.rows);
        self.atlas.deinit();
        self.images.deinit();
        for (self.buffers) |b| release(b);
        self.differ.deinit();
        self.pieces.deinit(self.differ.gpa);
        inline for (.{ "constants", "scissored", "rasterizer", "blend", "layout", "ps", "vs" }) |f| release(@field(self, f));
        callAs(void, self.context, d3d.ctx.clear_state, .{});
        release(self.context);
        release(self.device);
    }

    /// Draws into window `hwnd` from now on, `width` × `height` pixels.
    pub fn attach(self: *Renderer, hwnd: *anyopaque, width: u32, height: u32) !void {
        const dxgi_device = queryOf(self.device, &d3d.iid_dxgi_device) orelse return error.NoDxgiDevice;
        defer release(dxgi_device);
        // One frame queued ahead of the screen: a frame shows the input of
        // when it was drawn.
        if (queryOf(self.device, &d3d.iid_dxgi_device1)) |d1| {
            _ = call(d1, d3d.dxgi.device1_set_max_latency, .{@as(u32, 1)});
            release(d1);
        }
        var adapter: ?Object = null;
        if (failed(call(dxgi_device, d3d.dxgi.device_get_adapter, .{&adapter}))) return error.NoAdapter;
        defer release(adapter);
        var factory: ?Object = null;
        if (failed(call(adapter.?, d3d.dxgi.get_parent, .{ &d3d.iid_dxgi_factory2, &factory }))) return error.NoDxgiFactory2;
        defer release(factory);
        var desc: d3d.SwapChainDesc1 = .{ .width = @max(1, width), .height = @max(1, height) };
        var sc: ?Object = null;
        if (failed(call(factory.?, d3d.dxgi.factory2_create_swap_chain_for_hwnd, .{ self.device, hwnd, &desc, @as(?*const anyopaque, null), @as(?Object, null), &sc }))) {
            // Before Windows 8.1: no frame latency object.
            desc.flags = 0;
            if (failed(call(factory.?, d3d.dxgi.factory2_create_swap_chain_for_hwnd, .{ self.device, hwnd, &desc, @as(?*const anyopaque, null), @as(?Object, null), &sc }))) return error.SwapChain;
        }
        // Alt+Enter is no full screen toggle here.
        _ = call(factory.?, d3d.dxgi.factory_make_window_association, .{ hwnd, @as(u32, 2) });
        self.swap_chain = sc;
        self.swap_flags = desc.flags;
        self.held = false;
        // One frame waits ahead of the screen, which the swap chain's frame
        // latency object tells room for: Present then never blocks.
        if (desc.flags & d3d.swap_chain_waitable != 0) if (queryOf(sc.?, &d3d.iid_dxgi_swap_chain2)) |sc2| {
            defer release(sc2);
            _ = call(sc2, d3d.dxgi.swap_chain2_set_max_latency, .{@as(u32, 1)});
            self.latency = callAs(?*anyopaque, sc2, d3d.dxgi.swap_chain2_latency_waitable, .{});
        };
        self.width = desc.width;
        self.height = desc.height;
        self.targetView() catch |e| {
            self.detach();
            return e;
        };
    }

    fn detach(self: *Renderer) void {
        if (self.latency) |l| _ = CloseHandle(l);
        self.latency = null;
        self.held = false;
        release(self.target);
        self.target = null;
        release(self.swap_chain);
        self.swap_chain = null;
    }

    fn targetView(self: *Renderer) !void {
        var back: ?Object = null;
        if (failed(call(self.swap_chain.?, d3d.dxgi.swap_chain_get_buffer, .{ @as(u32, 0), &d3d.iid_texture2d, &back }))) return error.NoBackBuffer;
        defer release(back);
        if (failed(call(self.device, d3d.dev.create_rtv, .{ back.?, @as(?*const anyopaque, null), &self.target }))) return error.RenderTarget;
    }

    /// Sizes the swap chain's buffers to `width` × `height` pixels.
    pub fn resize(self: *Renderer, width: u32, height: u32) !void {
        const sc = self.swap_chain orelse return;
        const w = @max(1, width);
        const h = @max(1, height);
        if (w == self.width and h == self.height) return;
        callAs(void, self.context, d3d.ctx.om_set_render_targets, .{ @as(u32, 0), @as(?*const ?Object, null), @as(?Object, null) });
        release(self.target);
        self.target = null;
        self.held = false;
        self.dirty = .none;
        if (failed(call(sc, d3d.dxgi.swap_chain_resize_buffers, .{ @as(u32, 0), w, h, d3d.format_unknown, self.swap_flags }))) return error.ResizeBuffers;
        self.width = w;
        self.height = h;
        try self.targetView();
    }

    /// Brings the GPU's glyph atlas up to date: the rows that changed since
    /// the last sync (`Atlas.takeDirty`), or all of it when they are not
    /// known (null).
    pub fn syncAtlas(self: *Renderer, mask: raster.Mask, generation: u64, dirty: ?[2]u32) void {
        if (mask.size == 0) return;
        if (mask.size != self.atlas_size) {
            self.atlas.deinit();
            self.atlas = self.texture(mask.size, mask.size, d3d.format_r8_unorm, mask.pixels.ptr, mask.size) catch return;
            self.atlas_size = mask.size;
        } else if (generation != self.atlas_generation) {
            const rows: [2]u32 = dirty orelse .{ 0, mask.size };
            if (rows[1] > rows[0]) {
                const box: d3d.Box = .{ .left = 0, .top = rows[0], .right = mask.size, .bottom = rows[1] };
                callAs(void, self.context, d3d.ctx.update_subresource, .{ self.atlas.tex.?, @as(u32, 0), &box, mask.pixels.ptr + @as(usize, rows[0]) * mask.size, mask.size, @as(u32, 0) });
            }
        }
        self.atlas_generation = generation;
    }

    /// Writes pictures straight to the image atlas (`images.Sink`), which
    /// then keeps no copy in memory.
    pub fn uploadImage(ctx: *anyopaque, side: u32, x: u32, y: u32, w: u32, h: u32, bgra: []const u8) void {
        const self: *Renderer = @ptrCast(@alignCast(ctx));
        if (side != self.images_side) {
            // Cleared, as the atlas in memory starts.
            const zero = std.heap.page_allocator.alloc(u8, side * side * 4) catch return;
            defer std.heap.page_allocator.free(zero);
            @memset(zero, 0);
            self.imagesTexture(side, zero) catch return;
        }
        if (w == 0 or h == 0) return;
        const box: d3d.Box = .{ .left = x, .top = y, .right = x + w, .bottom = y + h };
        callAs(void, self.context, d3d.ctx.update_subresource, .{ self.images.tex.?, @as(u32, 0), &box, bgra.ptr, w * 4, @as(u32, 0) });
    }

    fn imagesTexture(self: *Renderer, side: u32, pixels: []const u8) !void {
        self.images.deinit();
        self.images_side = 0;
        self.images = try self.texture(side, side, d3d.format_b8g8r8a8_unorm, pixels.ptr, side * 4);
        self.images_side = side;
    }

    /// Brings the GPU's image atlas up to date: the rows that changed.
    pub fn syncImages(self: *Renderer, im: *images_mod.Images) void {
        if (im.pixels.len == 0 or im.generation == self.images_generation) return;
        const side = im.side;
        if (self.images.tex == null or self.images_side != side) {
            self.imagesTexture(side, im.pixels) catch return;
        } else if (im.dirty) |rows| if (rows[1] > rows[0]) {
            const box: d3d.Box = .{ .left = 0, .top = rows[0], .right = side, .bottom = rows[1] };
            callAs(void, self.context, d3d.ctx.update_subresource, .{ self.images.tex.?, @as(u32, 0), &box, im.pixels.ptr + @as(usize, rows[0]) * side * 4, side * 4, @as(u32, 0) });
        };
        im.dirty = null;
        self.images_generation = im.generation;
    }

    fn texture(self: *Renderer, w: u32, h: u32, format: u32, pixels: [*]const u8, pitch: u32) !Texture {
        const desc: d3d.Texture2DDesc = .{ .width = w, .height = h, .format = format, .bind = d3d.bind_shader_resource };
        const data: d3d.SubresourceData = .{ .mem = pixels, .pitch = pitch };
        var t: Texture = .{};
        errdefer t.deinit();
        if (failed(call(self.device, d3d.dev.create_texture2d, .{ &desc, &data, &t.tex }))) return error.Texture;
        if (failed(call(self.device, d3d.dev.create_srv, .{ t.tex.?, @as(?*const anyopaque, null), &t.srv }))) return error.Texture;
        return t;
    }

    /// Draws `instances` over `clear` into the window and presents the
    /// frame at the display's refresh (no tearing), `scale` pixels a point.
    pub fn draw(self: *Renderer, instances: []const Instance, scale: f32, clear: types.Color) !void {
        try self.drawUnpresented(instances, scale, clear);
        try self.present(1);
    }

    /// Draws a frame whole into the swap chain's back buffer, not shown yet.
    pub fn drawUnpresented(self: *Renderer, instances: []const Instance, scale: f32, clear: types.Color) !void {
        const target = self.target orelse return error.NotAttached;
        self.held = false;
        self.dirty = .whole;
        try self.encode(target, null, instances, scale, self.width, self.height, clear, null);
    }

    /// Draws frame `f` into the back buffer, only where it changed since
    /// the last frame drawn when the swap chain holds that one, and tells
    /// how much it drew: a frame that changed nothing draws nothing.
    pub fn render(self: *Renderer, f: damage.Frame) !Drawn {
        const target = self.target orelse return error.NotAttached;
        var part: ?damage.Box = null;
        if (damage.enabled()) {
            const since = self.differ.diff(f);
            if (self.held) if (self.differ.planOne(f, since)) |p| {
                if (damage.empty(p)) return .nothing;
                part = p;
            };
        }
        self.held = false;
        try self.encode(target, null, f.instances, f.scale, self.width, self.height, f.clear, part);
        self.differ.remember(f);
        self.held = true;
        self.dirty = if (part) |p| switch (self.dirty) {
            .none => .{ .part = p },
            .part => |d| .{ .part = damage.unite(d, p) },
            .whole => .whole,
        } else .whole;
        return if (part != null) .part else .whole;
    }

    /// Whether a frame drawn waits to be presented.
    pub fn unpresented(self: *const Renderer) bool {
        return self.dirty != .none;
    }

    /// Shows the back buffer after `sync` refreshes (0: at once): what the
    /// frames drew since the last present, and DXGI the rest.
    pub fn present(self: *Renderer, sync: u32) !void {
        const sc = self.swap_chain orelse return error.NotAttached;
        const dirty = self.dirty;
        self.dirty = .none;
        // Occluded (minimized) is a success; a removed device is not.
        // DXGI fills the buffer presented outside its dirty rectangle from
        // the frame presented before; a frame drawn whole is dirty all over.
        const p: damage.Box = switch (dirty) {
            .part => |p| p,
            else => .{ 0, 0, @intCast(self.width), @intCast(self.height) },
        };
        const rect: d3d.Rect = .{ .left = p[0], .top = p[1], .right = p[2], .bottom = p[3] };
        const params: d3d.PresentParameters = .{ .dirty_count = 1, .dirty = &rect };
        const hr = call(sc, d3d.dxgi.swap_chain1_present1, .{ sync, @as(u32, 0), &params });
        if (failed(hr)) {
            self.held = false;
            return error.Present;
        }
    }

    /// The back buffer's pixels, before it is presented: for tests.
    pub fn readBackBuffer(self: *Renderer, gpa: std.mem.Allocator) !Pixels {
        var back: ?Object = null;
        if (failed(call(self.swap_chain orelse return error.NotAttached, d3d.dxgi.swap_chain_get_buffer, .{ @as(u32, 0), &d3d.iid_texture2d, &back }))) return error.NoBackBuffer;
        defer release(back);
        return self.read(gpa, back.?, self.width, self.height);
    }

    /// Draws into a new offscreen texture and returns its BGRA pixels,
    /// premultiplied, `width * 4` bytes per row: frames without a window.
    pub fn drawOffscreen(self: *Renderer, gpa: std.mem.Allocator, instances: []const Instance, size: types.Size, scale: f32, clear: types.Color) !Pixels {
        const w: u32 = @intFromFloat(@max(1, @round(size.w * scale)));
        const h: u32 = @intFromFloat(@max(1, @round(size.h * scale)));
        const desc: d3d.Texture2DDesc = .{ .width = w, .height = h, .format = d3d.format_b8g8r8a8_unorm, .bind = d3d.bind_render_target | d3d.bind_shader_resource };
        var tex: ?Object = null;
        if (failed(call(self.device, d3d.dev.create_texture2d, .{ &desc, @as(?*const d3d.SubresourceData, null), &tex }))) return error.Texture;
        defer release(tex);
        var rtv: ?Object = null;
        if (failed(call(self.device, d3d.dev.create_rtv, .{ tex.?, @as(?*const anyopaque, null), &rtv }))) return error.RenderTarget;
        defer release(rtv);
        try self.encode(rtv.?, tex.?, instances, scale, w, h, clear, null);

        return self.read(gpa, tex.?, w, h);
    }

    /// A texture drawn into across frames, for tests of frames drawn in part.
    pub const Target = struct { tex: Object, rtv: Object, w: u32, h: u32 };

    pub fn newTarget(self: *Renderer, w: u32, h: u32) !Target {
        const desc: d3d.Texture2DDesc = .{ .width = w, .height = h, .format = d3d.format_b8g8r8a8_unorm, .bind = d3d.bind_render_target | d3d.bind_shader_resource };
        var tex: ?Object = null;
        if (failed(call(self.device, d3d.dev.create_texture2d, .{ &desc, @as(?*const d3d.SubresourceData, null), &tex }))) return error.Texture;
        errdefer release(tex);
        var rtv: ?Object = null;
        if (failed(call(self.device, d3d.dev.create_rtv, .{ tex.?, @as(?*const anyopaque, null), &rtv }))) return error.RenderTarget;
        return .{ .tex = tex.?, .rtv = rtv.?, .w = w, .h = h };
    }

    pub fn freeTarget(_: *Renderer, t: Target) void {
        release(t.rtv);
        release(t.tex);
    }

    /// Draws into `t`, whole or only `part` (the rest kept).
    pub fn drawTarget(self: *Renderer, t: Target, instances: []const Instance, scale: f32, clear: types.Color, part: ?damage.Box) !void {
        try self.encode(t.rtv, t.tex, instances, scale, t.w, t.h, clear, part);
    }

    pub fn readTarget(self: *Renderer, gpa: std.mem.Allocator, t: Target) !Pixels {
        return self.read(gpa, t.tex, t.w, t.h);
    }

    /// The pixels of texture `tex`, `w` × `h` BGRA, copied to memory.
    fn read(self: *Renderer, gpa: std.mem.Allocator, tex: Object, w: u32, h: u32) !Pixels {
        const desc: d3d.Texture2DDesc = .{ .width = w, .height = h, .format = d3d.format_b8g8r8a8_unorm, .usage = d3d.usage_staging, .cpu = d3d.cpu_read };
        var staging: ?Object = null;
        if (failed(call(self.device, d3d.dev.create_texture2d, .{ &desc, @as(?*const d3d.SubresourceData, null), &staging }))) return error.Texture;
        defer release(staging);
        callAs(void, self.context, d3d.ctx.copy_resource, .{ staging.?, tex });
        var m: d3d.Mapped = .{};
        if (failed(call(self.context, d3d.ctx.map, .{ staging.?, @as(u32, 0), d3d.map_read, @as(u32, 0), &m }))) return error.Map;
        defer callAs(void, self.context, d3d.ctx.unmap, .{ staging.?, @as(u32, 0) });
        const bytes = try gpa.alloc(u8, @as(usize, w) * h * 4);
        for (0..h) |y| @memcpy(bytes[y * w * 4 ..][0 .. w * 4], m.data.?[y * m.row_pitch ..][0 .. w * 4]);
        return .{ .bytes = bytes, .width = w, .height = h };
    }

    /// Draws a frame into `target` (a view of texture `tex`, or of the
    /// swap chain's back buffer when null), in parts around the marks of
    /// effects and layers, which `d3d11_fx.zig` draws between them.
    /// Drawn in `part`, the frame clears it with an opaque quad of its
    /// color (`damage.clearQuad`) and draws scissored to it, leaving the
    /// target as it was elsewhere, and draws only the effects and layers
    /// in it.
    fn encode(self: *Renderer, target: Object, tex: ?Object, instances: []const Instance, scale: f32, w: u32, h: u32, clear: types.Color, part: ?damage.Box) !void {
        const c = self.context;
        if (part == null) {
            const clear4: [4]f32 = .{ clear.r, clear.g, clear.b, 1 };
            callAs(void, c, d3d.ctx.clear_render_target_view, .{ target, &clear4 });
        }
        const fr = gpu.Frame.of(@import("gpu_corners.zig").split(self.differ.gpa, instances, scale, &self.pieces));
        if (fr.instances.len == 0 and part == null) return;
        const buffer = try self.upload(fr.instances, if (part) |p| damage.clearQuad(p, scale, clear) else null);
        try self.uploadRows(fr.rows);
        const constants: [4]f32 = .{ @floatFromInt(w), @floatFromInt(h), scale, 0 };
        callAs(void, c, d3d.ctx.update_subresource, .{ self.constants.?, @as(u32, 0), @as(?*const d3d.Box, null), &constants, @as(u32, 0), @as(u32, 0) });
        self.bindMain(target, buffer, w, h, part);
        if (part != null) self.drawRange(fr.instances.len, fr.instances.len + 1);
        var markers: damage.Markers = .{ .part = part };
        var start: usize = 0;
        for (fr.instances, 0..) |*i, k| {
            if (!gpu.isMarker(i.kind)) continue;
            self.drawRange(start, k);
            if (markers.draws(i, w, h, scale)) {
                self.fx.apply(self, target, tex, i, fr.rows, scale, w, h);
                self.bindMain(target, buffer, w, h, part);
            }
            start = k + 1;
        }
        self.drawRange(start, fr.instances.len);
        self.fx.endFrame();
    }

    fn drawRange(self: *Renderer, from: usize, to: usize) void {
        if (to <= from) return;
        callAs(void, self.context, d3d.ctx.draw_instanced, .{ @as(u32, 4), @as(u32, @intCast(to - from)), @as(u32, 0), @as(u32, @intCast(from)) });
    }

    /// The main pipeline, drawing into `target`.
    fn bindMain(self: *Renderer, target: Object, buffer: Object, w: u32, h: u32, part: ?damage.Box) void {
        const c = self.context;
        const vp: d3d.Viewport = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
        const targets = [1]?Object{target};
        callAs(void, c, d3d.ctx.om_set_render_targets, .{ @as(u32, 1), &targets, @as(?Object, null) });
        callAs(void, c, d3d.ctx.om_set_blend_state, .{ self.blend, @as(?*const [4]f32, null), @as(u32, 0xffffffff) });
        callAs(void, c, d3d.ctx.rs_set_viewports, .{ @as(u32, 1), &vp });
        if (part) |p| {
            callAs(void, c, d3d.ctx.rs_set_state, .{self.scissored});
            const rect: d3d.Rect = .{ .left = p[0], .top = p[1], .right = p[2], .bottom = p[3] };
            callAs(void, c, d3d.ctx.rs_set_scissor_rects, .{ @as(u32, 1), &rect });
        } else callAs(void, c, d3d.ctx.rs_set_state, .{self.rasterizer});
        callAs(void, c, d3d.ctx.ia_set_input_layout, .{self.layout});
        callAs(void, c, d3d.ctx.ia_set_primitive_topology, .{d3d.topology_triangle_strip});
        const bufs = [1]?Object{buffer};
        const strides = [1]u32{@sizeOf(Instance)};
        const offsets = [1]u32{0};
        callAs(void, c, d3d.ctx.ia_set_vertex_buffers, .{ @as(u32, 0), @as(u32, 1), &bufs, &strides, &offsets });
        callAs(void, c, d3d.ctx.vs_set_shader, .{ self.vs, @as(?*const ?Object, null), @as(u32, 0) });
        const cbs = [1]?Object{self.constants};
        callAs(void, c, d3d.ctx.vs_set_constant_buffers, .{ @as(u32, 0), @as(u32, 1), &cbs });
        callAs(void, c, d3d.ctx.ps_set_constant_buffers, .{ @as(u32, 0), @as(u32, 1), &cbs });
        callAs(void, c, d3d.ctx.ps_set_shader, .{ self.ps, @as(?*const ?Object, null), @as(u32, 0) });
        // No pictures yet: the slot is empty, and never sampled.
        const views = [3]?Object{ self.atlas.srv, self.images.srv, self.rows_view };
        callAs(void, c, d3d.ctx.ps_set_shader_resources, .{ @as(u32, 0), @as(u32, 3), &views });
        callAs(void, c, d3d.ctx.vs_set_shader_resources, .{ @as(u32, 2), @as(u32, 1), views[2..3].ptr });
    }

    /// Copies a frame's rows into their buffer, grown as needed.
    fn uploadRows(self: *Renderer, rows: []const [4]f32) !void {
        if (rows.len == 0) return;
        const bytes = std.mem.sliceAsBytes(rows);
        if (self.rows_capacity < bytes.len) {
            release(self.rows_view);
            release(self.rows);
            self.rows_view = null;
            self.rows = null;
            self.rows_capacity = 0;
            const cap = @max(bytes.len * 3 / 2, 16 * 1024);
            const desc: d3d.BufferDesc = .{ .width = @intCast(cap), .usage = d3d.usage_dynamic, .bind = d3d.bind_shader_resource, .cpu = d3d.cpu_write };
            if (failed(call(self.device, d3d.dev.create_buffer, .{ &desc, @as(?*const d3d.SubresourceData, null), &self.rows }))) return error.Buffer;
            const view: d3d.SrvBuffer = .{ .n = @intCast(cap / 16) };
            if (failed(call(self.device, d3d.dev.create_srv, .{ self.rows.?, &view, &self.rows_view }))) return error.Buffer;
            self.rows_capacity = cap;
        }
        var m: d3d.Mapped = .{};
        if (failed(call(self.context, d3d.ctx.map, .{ self.rows.?, @as(u32, 0), d3d.map_write_discard, @as(u32, 0), &m }))) return error.Map;
        @memcpy(m.data.?[0..bytes.len], bytes);
        callAs(void, self.context, d3d.ctx.unmap, .{ self.rows.?, @as(u32, 0) });
    }

    /// Copies `instances`, and `extra` after them, into the next buffer of
    /// the ring, grown as needed.
    fn upload(self: *Renderer, instances: []const Instance, extra: ?Instance) !Object {
        const i = self.next_buffer;
        self.next_buffer = (i + 1) % frames_in_flight;
        const bytes = std.mem.sliceAsBytes(instances);
        const need = bytes.len + @as(usize, if (extra != null) @sizeOf(Instance) else 0);
        if (self.capacities[i] < need) {
            release(self.buffers[i]);
            self.buffers[i] = null;
            self.capacities[i] = 0;
            const cap = @max(need * 3 / 2, 64 * 1024);
            const desc: d3d.BufferDesc = .{ .width = @intCast(cap), .usage = d3d.usage_dynamic, .bind = d3d.bind_vertex_buffer, .cpu = d3d.cpu_write };
            if (failed(call(self.device, d3d.dev.create_buffer, .{ &desc, @as(?*const d3d.SubresourceData, null), &self.buffers[i] }))) return error.Buffer;
            self.capacities[i] = cap;
        }
        const buf = self.buffers[i].?;
        var m: d3d.Mapped = .{};
        if (failed(call(self.context, d3d.ctx.map, .{ buf, @as(u32, 0), d3d.map_write_discard, @as(u32, 0), &m }))) return error.Map;
        @memcpy(m.data.?[0..bytes.len], bytes);
        if (extra) |e| @memcpy(m.data.?[bytes.len..][0..@sizeOf(Instance)], std.mem.asBytes(&e));
        callAs(void, self.context, d3d.ctx.unmap, .{ buf, @as(u32, 0) });
        return buf;
    }
};

extern "kernel32" fn CloseHandle(h: *anyopaque) callconv(.winapi) i32;

fn queryOf(obj: Object, iid: *const d3d.GUID) ?Object {
    var out: ?Object = null;
    if (failed(call(obj, 0, .{ iid, &out }))) return null;
    return out;
}
