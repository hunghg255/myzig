//! Backdrop effects and blurred layers on Direct3D 11: the CPU renderer's
//! steps (`raster_fx.zig`, `backdrop.zig`) as passes over textures, drawn
//! between the parts of a frame (`d3d11.zig`'s `encode`). An effect copies
//! the area it reads into a texture, averages it down, blurs it rows then
//! columns, and draws its shape from it with its shader; a layer keeps what
//! is under its area and clears it, then at its end blurs what was drawn
//! there and draws it over what it kept. The passes' shaders
//! (`d3d11_fx.hlsl`, and each effect's) are compiled when first needed: a
//! frame without effects or layers never makes them.
const std = @import("std");
const d3d = @import("d3d11_api.zig");
const gpu = @import("gpu.zig");
const effect = @import("effect.zig");
const backdrop = @import("backdrop.zig");
const raster_fx = @import("raster_fx.zig");
const Renderer = @import("d3d11.zig").Renderer;

const Object = d3d.Object;
const call = d3d.call;
const callAs = d3d.callAs;
const failed = d3d.failed;
const release = d3d.release;
const gpa = std.heap.page_allocator;

const source = @import("shader_min.zig").minify(@embedFile("d3d11_fx.hlsl"));

/// The effect pass's entry, after the effect's `effect_color`.
const effect_main =
    \\
    \\float4 effect_ps(VOut v) : SV_Target {
    \\    EffectIn i = effect_in(v);
    \\    float cov = effect_cover(i);
    \\    if (cov <= 0.0) discard;
    \\    // Rounded as the CPU rounds where the shape covers the pixel whole.
    \\    float3 c = floor(saturate(effect_color(i)) * 255.0 + 0.5) / 255.0;
    \\    return float4(c * cov, cov);
    \\}
;

/// The backdrop as it is: an effect without a shader.
const plain_color =
    \\
    \\float3 effect_color(EffectIn i) { return backdrop_at(i, i.p); }
;

/// The passes' constants (`Fx` in `d3d11_fx.hlsl`).
const Constants = extern struct {
    area: [4]f32 = @splat(0),
    info: [4]f32 = @splat(0),
    dir: [4]f32 = @splat(0),
    shape: [4]f32 = @splat(0),
    shape2: [4]f32 = @splat(0),
    clip: [4]f32 = @splat(0),
    params: [4][4]f32 = @splat(@splat(0)),
    origin: [4]f32 = @splat(0),
    target: [4]f32 = @splat(0),
};

/// A texture drawn into and read: its views.
const Tex = struct {
    tex: ?Object = null,
    rtv: ?Object = null,
    srv: ?Object = null,
    w: u32 = 0,
    h: u32 = 0,

    fn init(device: Object, w: u32, h: u32) !Tex {
        var t: Tex = .{ .w = @max(w, 1), .h = @max(h, 1) };
        errdefer t.deinit();
        const desc: d3d.Texture2DDesc = .{ .width = t.w, .height = t.h, .format = d3d.format_b8g8r8a8_unorm, .bind = d3d.bind_render_target | d3d.bind_shader_resource };
        if (failed(call(device, d3d.dev.create_texture2d, .{ &desc, @as(?*const d3d.SubresourceData, null), &t.tex }))) return error.Texture;
        if (failed(call(device, d3d.dev.create_rtv, .{ t.tex.?, @as(?*const anyopaque, null), &t.rtv }))) return error.Texture;
        if (failed(call(device, d3d.dev.create_srv, .{ t.tex.?, @as(?*const anyopaque, null), &t.srv }))) return error.Texture;
        return t;
    }

    fn deinit(t: *Tex) void {
        release(t.srv);
        release(t.rtv);
        release(t.tex);
        t.* = .{};
    }
};

const Saved = struct { tex: Tex, area: [4]usize };

/// The passes' textures, kept from frame to frame by their size, after
/// mygo's effect layers: an effect or a layer whose box moves, or that
/// changes, reads and draws through the textures of the frame before
/// rather than new ones; those no frame took for `idle_frames` go.
pub const Pool = struct {
    kept: std.ArrayList(struct { tex: Tex, used: u64 }) = .empty,
    frame: u64 = 0,
    /// Textures made, for tests.
    made: usize = 0,
    const idle_frames = 120;
    const most = 24;

    fn take(p: *Pool, device: Object, w: u32, h: u32) !Tex {
        const tw = @max(w, 1);
        const th = @max(h, 1);
        for (p.kept.items, 0..) |k, i| if (k.tex.w == tw and k.tex.h == th) return p.kept.swapRemove(i).tex;
        p.made += 1;
        return Tex.init(device, tw, th);
    }

    fn give(p: *Pool, t: *Tex) void {
        if (t.tex == null) return;
        if (p.kept.items.len < most) {
            p.kept.append(gpa, .{ .tex = t.*, .used = p.frame }) catch return t.deinit();
            t.* = .{};
        } else t.deinit();
    }

    /// A frame ended: textures no frame took for a while go.
    fn sweep(p: *Pool) void {
        p.frame += 1;
        var i: usize = 0;
        while (i < p.kept.items.len) {
            if (p.frame - p.kept.items[i].used > idle_frames) {
                p.kept.items[i].tex.deinit();
                _ = p.kept.swapRemove(i);
            } else i += 1;
        }
    }

    fn deinit(p: *Pool) void {
        for (p.kept.items) |*k| k.tex.deinit();
        p.kept.deinit(gpa);
        p.* = .{};
    }

    pub fn count(p: *const Pool) usize {
        return p.kept.items.len;
    }
};

pub const Passes = struct {
    state: enum { unmade, made, failed } = .unmade,
    vs: ?Object = null,
    down: ?Object = null,
    blur: ?Object = null,
    layer: ?Object = null,
    clear: ?Object = null,
    plain: ?Object = null,
    constants: ?Object = null,
    replace: ?Object = null,
    /// Each effect's pixel shader, by its `Shader`'s address (null: it
    /// failed to compile, and draws as the plain one).
    effects: std.AutoHashMapUnmanaged(usize, ?Object) = .empty,
    /// Layers open, innermost last.
    layers: std.ArrayList(Saved) = .empty,
    pool: Pool = .{},

    /// A frame drawn: textures of passes no frame used for a while go.
    pub fn endFrame(p: *Passes) void {
        if (p.state == .made) p.pool.sweep();
    }

    pub fn deinit(p: *Passes) void {
        p.pool.deinit();
        for (p.layers.items) |*l| l.tex.deinit();
        p.layers.deinit(gpa);
        var it = p.effects.valueIterator();
        while (it.next()) |v| release(v.*);
        p.effects.deinit(gpa);
        inline for (.{ "vs", "down", "blur", "layer", "clear", "plain", "constants", "replace" }) |f| release(@field(p, f));
        p.* = .{};
    }

    fn make(p: *Passes, device: Object) !void {
        if (p.state == .made) return;
        if (p.state == .failed) return error.Unavailable;
        errdefer p.state = .failed;
        const vs = try d3d.compile(gpa, source, "vs", "vs_4_0");
        defer gpa.free(vs);
        if (failed(call(device, d3d.dev.create_vertex_shader, .{ vs.ptr, vs.len, @as(?Object, null), &p.vs }))) return error.ShaderCreate;
        p.down = try pixelShader(device, source, "down");
        p.blur = try pixelShader(device, source, "blur");
        p.layer = try pixelShader(device, source, "layer");
        p.clear = try pixelShader(device, source, "clear");
        p.plain = try effectShader(device, plain_color);
        const cb: d3d.BufferDesc = .{ .width = @sizeOf(Constants), .usage = d3d.usage_default, .bind = d3d.bind_constant_buffer };
        if (failed(call(device, d3d.dev.create_buffer, .{ &cb, @as(?*const d3d.SubresourceData, null), &p.constants }))) return error.Buffer;
        // Blending off: what is drawn replaces what is there.
        const blend: d3d.BlendDesc = .{ .targets = @splat(.{ .enable = 0, .src = 2, .dst = 1, .op = 1, .src_alpha = 2, .dst_alpha = 1, .op_alpha = 1, .mask = 0xf }) };
        if (failed(call(device, d3d.dev.create_blend_state, .{ &blend, &p.replace }))) return error.BlendState;
        p.state = .made;
    }

    /// Draws the effect or layer mark `i` between the parts of a frame
    /// drawn into `target` (a view of `tex_in`, or of the back buffer).
    pub fn apply(p: *Passes, r: *Renderer, target: Object, tex_in: ?Object, i: *const gpu.Instance, rows: []const [4]f32, scale: f32, w: u32, h: u32) void {
        // Turned with their box, they are not drawn (as on the CPU).
        if (i.kind >= 16) return;
        p.make(r.device) catch return;
        var back: ?Object = null;
        defer release(back);
        const tex = tex_in orelse blk: {
            const sc = r.swap_chain orelse return;
            if (failed(call(sc, d3d.dxgi.swap_chain_get_buffer, .{ @as(u32, 0), &d3d.iid_texture2d, &back }))) return;
            break :blk back.?;
        };
        const f: Frame = .{ .r = r, .target = target, .tex = tex, .w = w, .h = h, .scale = scale };
        if (i.kind == gpu.Kind.effect) {
            p.drawEffect(f, i, rows) catch {};
        } else if (i.kind == gpu.Kind.layer) {
            p.beginLayer(f, i) catch {};
        } else p.endLayer(f, i) catch {};
    }

    const Frame = struct { r: *Renderer, target: Object, tex: Object, w: u32, h: u32, scale: f32 };

    fn drawEffect(p: *Passes, f: Frame, i: *const gpu.Instance, rows: []const [4]f32) !void {
        const row: usize = @intFromFloat(i.uv[0]);
        if (row + effect.rows_per_effect > rows.len) return;
        const a = raster_fx.area(f.w, f.h, i.rect, i.clip, f.scale) orelse return;
        const s = f.scale;
        const shape: [4]f32 = .{ i.rect[0] * s, i.rect[1] * s, i.rect[2] * s, i.rect[3] * s };
        const b = backdrop.Backdrop.of(shape, rows[row][0] * s, f.w, f.h);
        const size = b.texels();
        if (size[0] == 0) return;
        const tw: u32 = @intCast(size[0]);
        const th: u32 = @intCast(size[1]);
        var copy = try p.pool.take(f.r.device, @intCast(b.x1 - b.x0), @intCast(b.y1 - b.y0));
        defer p.pool.give(&copy);
        p.copyFrom(f, copy, .{ b.x0, b.y0, b.x1, b.y1 });
        var t0 = try p.pool.take(f.r.device, tw, th);
        defer p.pool.give(&t0);
        var t1 = try p.pool.take(f.r.device, tw, th);
        defer p.pool.give(&t1);
        const down: f32 = @floatFromInt(b.down);
        const sigma = b.sigma;
        const radius: f32 = @floatFromInt(b.radius);
        p.pass(f.r, p.down.?, copy, t0, .{ .area = .{ 0, 0, @floatFromInt(tw), @floatFromInt(th) }, .info = .{ down, sigma, radius, 0 }, .dir = .{ 0, 0, @floatFromInt(copy.w), @floatFromInt(copy.h) } }, false);
        if (b.radius > 0) {
            const whole: [4]f32 = .{ 0, 0, @floatFromInt(tw), @floatFromInt(th) };
            p.pass(f.r, p.blur.?, t0, t1, .{ .area = whole, .info = .{ down, sigma, radius, 0 }, .dir = .{ 1, 0, @floatFromInt(tw), @floatFromInt(th) } }, false);
            p.pass(f.r, p.blur.?, t1, t0, .{ .area = whole, .info = .{ down, sigma, radius, 0 }, .dir = .{ 0, 1, @floatFromInt(tw), @floatFromInt(th) } }, false);
        }
        const ps = p.shaderFor(f.r.device, effect.shaderOf(rows, row));
        var k: Constants = .{
            .area = areaOf(a),
            .info = .{ down, sigma, radius, 0 },
            .shape = shape,
            .shape2 = .{ i.radius * s, s, i.clip_round, 0 },
            .clip = i.clip,
            .origin = .{ @floatFromInt(b.x0), @floatFromInt(b.y0), @floatFromInt(tw), @floatFromInt(th) },
        };
        k.params = effect.paramsOf(rows, row).*;
        p.passInto(f, ps, t0, k, true);
    }

    fn beginLayer(p: *Passes, f: Frame, i: *const gpu.Instance) !void {
        const a = raster_fx.area(f.w, f.h, i.rect, i.clip, f.scale) orelse [4]usize{ 0, 0, 0, 0 };
        var kept = try p.pool.take(f.r.device, @intCast(a[2] - a[0]), @intCast(a[3] - a[1]));
        errdefer p.pool.give(&kept);
        if (a[2] > a[0] and a[3] > a[1]) {
            p.copyFrom(f, kept, a);
            p.passInto(f, p.clear.?, null, .{ .area = areaOf(a) }, false);
        }
        try p.layers.append(gpa, .{ .tex = kept, .area = a });
    }

    fn endLayer(p: *Passes, f: Frame, i: *const gpu.Instance) !void {
        var l = p.layers.pop() orelse return;
        defer p.pool.give(&l.tex);
        const a = l.area;
        if (a[2] <= a[0] or a[3] <= a[1]) return;
        const aw: u32 = @intCast(a[2] - a[0]);
        const ah: u32 = @intCast(a[3] - a[1]);
        var layer = try p.pool.take(f.r.device, aw, ah);
        defer p.pool.give(&layer);
        p.copyFrom(f, layer, a);
        const sigma = i.border_width * f.scale;
        var buf: [backdrop.max_radius + 1]f32 = undefined;
        const radius: f32 = @floatFromInt(raster_fx.layerWeights(sigma, &buf).len - 1);
        if (radius > 0) {
            var t = try p.pool.take(f.r.device, aw, ah);
            defer p.pool.give(&t);
            const whole: [4]f32 = .{ 0, 0, @floatFromInt(aw), @floatFromInt(ah) };
            p.pass(f.r, p.blur.?, layer, t, .{ .area = whole, .info = .{ 1, sigma, radius, 1 }, .dir = .{ 1, 0, @floatFromInt(aw), @floatFromInt(ah) } }, false);
            p.pass(f.r, p.blur.?, t, layer, .{ .area = whole, .info = .{ 1, sigma, radius, 1 }, .dir = .{ 0, 1, @floatFromInt(aw), @floatFromInt(ah) } }, false);
        }
        // What was under it, then the layer over it.
        const box: d3d.Box = .{ .left = 0, .top = 0, .right = aw, .bottom = ah };
        callAs(void, f.r.context, d3d.ctx.copy_subresource_region, .{ f.tex, @as(u32, 0), @as(u32, @intCast(a[0])), @as(u32, @intCast(a[1])), @as(u32, 0), l.tex.tex.?, @as(u32, 0), &box });
        p.passInto(f, p.layer.?, layer, .{ .area = areaOf(a) }, true);
    }

    /// Copies the pixels `a` (x0, y0, x1, y1) of the frame into `dst`.
    fn copyFrom(_: *Passes, f: Frame, dst: Tex, a: [4]usize) void {
        const box: d3d.Box = .{ .left = @intCast(a[0]), .top = @intCast(a[1]), .right = @intCast(a[2]), .bottom = @intCast(a[3]) };
        callAs(void, f.r.context, d3d.ctx.copy_subresource_region, .{ dst.tex.?, @as(u32, 0), @as(u32, 0), @as(u32, 0), @as(u32, 0), f.tex, @as(u32, 0), &box });
    }

    /// A pass from `src` into texture `dst`, blending off.
    fn pass(p: *Passes, r: *Renderer, ps: Object, src: Tex, dst: Tex, k: Constants, blend: bool) void {
        p.run(r, ps, src.srv, dst.rtv.?, dst.w, dst.h, k, blend);
    }

    /// A pass from `src` into the frame's target.
    fn passInto(p: *Passes, f: Frame, ps: Object, src: ?Tex, k: Constants, blend: bool) void {
        p.run(f.r, ps, if (src) |s| s.srv else null, f.target, f.w, f.h, k, blend);
    }

    fn run(p: *Passes, r: *Renderer, ps: Object, src: ?Object, rtv: Object, w: u32, h: u32, k_in: Constants, blend: bool) void {
        const c = r.context;
        var k = k_in;
        k.target = .{ @floatFromInt(w), @floatFromInt(h), 0, 0 };
        callAs(void, c, d3d.ctx.update_subresource, .{ p.constants.?, @as(u32, 0), @as(?*const d3d.Box, null), &k, @as(u32, 0), @as(u32, 0) });
        // Not scissored to a frame's part: passes draw into textures too.
        callAs(void, c, d3d.ctx.rs_set_state, .{r.rasterizer});
        const none = [3]?Object{ null, null, null };
        callAs(void, c, d3d.ctx.ps_set_shader_resources, .{ @as(u32, 0), @as(u32, 3), &none });
        const targets = [1]?Object{rtv};
        callAs(void, c, d3d.ctx.om_set_render_targets, .{ @as(u32, 1), &targets, @as(?Object, null) });
        callAs(void, c, d3d.ctx.om_set_blend_state, .{ if (blend) r.blend else p.replace, @as(?*const [4]f32, null), @as(u32, 0xffffffff) });
        const vp: d3d.Viewport = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
        callAs(void, c, d3d.ctx.rs_set_viewports, .{ @as(u32, 1), &vp });
        callAs(void, c, d3d.ctx.ia_set_input_layout, .{@as(?Object, null)});
        callAs(void, c, d3d.ctx.ia_set_primitive_topology, .{d3d.topology_triangle_strip});
        callAs(void, c, d3d.ctx.vs_set_shader, .{ p.vs, @as(?*const ?Object, null), @as(u32, 0) });
        callAs(void, c, d3d.ctx.ps_set_shader, .{ ps, @as(?*const ?Object, null), @as(u32, 0) });
        const cbs = [1]?Object{p.constants};
        callAs(void, c, d3d.ctx.vs_set_constant_buffers, .{ @as(u32, 0), @as(u32, 1), &cbs });
        callAs(void, c, d3d.ctx.ps_set_constant_buffers, .{ @as(u32, 0), @as(u32, 1), &cbs });
        const views = [1]?Object{src};
        callAs(void, c, d3d.ctx.ps_set_shader_resources, .{ @as(u32, 0), @as(u32, 1), &views });
        callAs(void, c, d3d.ctx.draw, .{ @as(u32, 4), @as(u32, 0) });
        callAs(void, c, d3d.ctx.ps_set_shader_resources, .{ @as(u32, 0), @as(u32, 1), none[0..1] });
    }

    /// The pixel shader of an effect, compiled the first time it draws.
    fn shaderFor(p: *Passes, device: Object, s: ?*const effect.Shader) Object {
        const shader = s orelse return p.plain.?;
        if (shader.hlsl.len == 0) return p.plain.?;
        const gop = p.effects.getOrPut(gpa, @intFromPtr(shader)) catch return p.plain.?;
        if (!gop.found_existing) gop.value_ptr.* = effectShader(device, shader.hlsl) catch |e| blk: {
            std.log.warn("myzig: effect {s}: {s}", .{ shader.name, @errorName(e) });
            break :blk null;
        };
        return gop.value_ptr.* orelse p.plain.?;
    }
};

fn areaOf(a: [4]usize) [4]f32 {
    return .{ @floatFromInt(a[0]), @floatFromInt(a[1]), @floatFromInt(a[2] - a[0]), @floatFromInt(a[3] - a[1]) };
}

fn pixelShader(device: Object, src: []const u8, entry: [*:0]const u8) !Object {
    const code = try d3d.compile(gpa, src, entry, "ps_4_0");
    defer gpa.free(code);
    var ps: ?Object = null;
    if (failed(call(device, d3d.dev.create_pixel_shader, .{ code.ptr, code.len, @as(?Object, null), &ps }))) return error.ShaderCreate;
    return ps.?;
}

/// The effect pass with `color`, a shader's `effect_color`.
fn effectShader(device: Object, color: []const u8) !Object {
    const src = try std.mem.concat(gpa, u8, &.{ source, "\n", color, effect_main });
    defer gpa.free(src);
    return pixelShader(device, src, "effect_ps");
}
