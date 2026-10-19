//! Backdrop effects and blurred layers on Metal: `d3d11_fx.zig`'s passes
//! (the CPU renderer's steps, `raster_fx.zig`) as render passes and blits,
//! between the parts of a frame (`metal.zig`'s `encode`): the frame's
//! encoder ends at a mark, the passes run in the same command buffer, and
//! a new encoder loads what was drawn and draws on. The passes' pipelines
//! (`metal_fx.metal`, and each effect's) are made when first needed.
const std = @import("std");
const objc = @import("../objc.zig");
const gpu = @import("gpu.zig");
const effect = @import("effect.zig");
const backdrop = @import("backdrop.zig");
const raster_fx = @import("raster_fx.zig");

const gpa = std.heap.page_allocator;
const source = @import("shader_min.zig").minify(@embedFile("metal_fx.metal"));
const pixel_format: objc.NSUInteger = 80; // BGRA8Unorm

const effect_main =
    \\
    \\fragment float4 fx_effect(FxOut v [[stage_in]], constant Fx &fx [[buffer(0)]], texture2d<float> backdrop [[texture(0)]]) {
    \\    EffectIn i = effect_in(v, fx);
    \\    float cov = effect_cover(i, fx);
    \\    if (cov <= 0.0) discard_fragment();
    \\    // Rounded as the CPU rounds where the shape covers the pixel whole.
    \\    float3 c = floor(saturate(effect_color(i, backdrop)) * 255.0 + 0.5) / 255.0;
    \\    return float4(c * cov, cov);
    \\}
    \\
;

const plain_color =
    \\
    \\float3 effect_color(EffectIn i, texture2d<float> backdrop) { return backdrop_at(i, backdrop, i.p); }
;

/// The passes' constants (`Fx` in `metal_fx.metal`).
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

const Origin = extern struct { x: objc.NSUInteger = 0, y: objc.NSUInteger = 0, z: objc.NSUInteger = 0 };
const Size = extern struct { w: objc.NSUInteger, h: objc.NSUInteger, d: objc.NSUInteger = 1 };

const Saved = struct { tex: objc.Object, area: [4]usize };

/// The passes' textures, kept from frame to frame by their size (as
/// `d3d11_fx.zig`'s): an effect or a layer whose box moves draws through
/// the textures of the frame before; those no frame took for a while go.
/// Metal orders the passes of successive frames that use one texture.
pub const Pool = struct {
    kept: std.ArrayList(struct { tex: objc.Object, w: u32, h: u32, used: u64 }) = .empty,
    frame: u64 = 0,
    made: usize = 0,
    const idle_frames = 120;
    const most = 24;

    fn take(p: *Pool, device: objc.Object, w: u32, h: u32) objc.Object {
        for (p.kept.items, 0..) |k, i| if (k.w == w and k.h == h) return p.kept.swapRemove(i).tex;
        p.made += 1;
        return texture(device, w, h);
    }

    fn give(p: *Pool, t: objc.Object, w: u32, h: u32) void {
        if (p.kept.items.len >= most) return objc.release(t);
        p.kept.append(gpa, .{ .tex = t, .w = w, .h = h, .used = p.frame }) catch objc.release(t);
    }

    fn sweep(p: *Pool) void {
        p.frame += 1;
        var i: usize = 0;
        while (i < p.kept.items.len) {
            if (p.frame - p.kept.items[i].used > idle_frames) {
                objc.release(p.kept.items[i].tex);
                _ = p.kept.swapRemove(i);
            } else i += 1;
        }
    }

    fn deinit(p: *Pool) void {
        for (p.kept.items) |k| objc.release(k.tex);
        p.kept.deinit(gpa);
        p.* = .{};
    }

    pub fn count(p: *const Pool) usize {
        return p.kept.items.len;
    }
};

/// The frame being drawn: its command buffer, texture, size and scale.
pub const Frame = struct { cmd: objc.Object, target: objc.Object, w: u32, h: u32, scale: f32 };

pub const Passes = struct {
    state: enum { unmade, made, failed } = .unmade,
    down: ?objc.Object = null,
    blur: ?objc.Object = null,
    layer: ?objc.Object = null,
    clear: ?objc.Object = null,
    plain: ?objc.Object = null,
    effects: std.AutoHashMapUnmanaged(usize, ?objc.Object) = .empty,
    layers: std.ArrayList(Saved) = .empty,
    pool: Pool = .{},

    /// A frame drawn: textures of passes no frame used for a while go.
    pub fn endFrame(p: *Passes) void {
        if (p.state == .made) p.pool.sweep();
    }

    pub fn deinit(p: *Passes) void {
        p.pool.deinit();
        for (p.layers.items) |l| objc.release(l.tex);
        p.layers.deinit(gpa);
        var it = p.effects.valueIterator();
        while (it.next()) |v| if (v.*) |o| objc.release(o);
        p.effects.deinit(gpa);
        inline for (.{ "down", "blur", "layer", "clear", "plain" }) |f| if (@field(p, f)) |o| objc.release(o);
        p.* = .{};
    }

    fn make(p: *Passes, device: objc.Object) !void {
        if (p.state == .made) return;
        if (p.state == .failed) return error.Unavailable;
        errdefer p.state = .failed;
        const lib = try library(device, source);
        defer objc.release(lib);
        p.down = try pipeline(device, lib, "fx_down", false);
        p.blur = try pipeline(device, lib, "fx_blur", false);
        p.layer = try pipeline(device, lib, "fx_layer", true);
        p.clear = try pipeline(device, lib, "fx_clear", false);
        p.plain = try effectPipeline(device, plain_color);
        p.state = .made;
    }

    /// Draws the effect or layer mark `i` into the frame, its encoder ended.
    pub fn apply(p: *Passes, device: objc.Object, f: Frame, i: *const gpu.Instance, rows: []const [4]f32) void {
        // Turned with their box, they are not drawn (as on the CPU).
        if (i.kind >= 16) return;
        p.make(device) catch return;
        if (i.kind == gpu.Kind.effect) {
            p.drawEffect(device, f, i, rows);
        } else if (i.kind == gpu.Kind.layer) {
            p.beginLayer(device, f, i);
        } else p.endLayer(device, f, i);
    }

    fn drawEffect(p: *Passes, device: objc.Object, f: Frame, i: *const gpu.Instance, rows: []const [4]f32) void {
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
        const cw: u32 = @intCast(b.x1 - b.x0);
        const ch: u32 = @intCast(b.y1 - b.y0);
        const copy = p.pool.take(device, cw, ch);
        defer p.pool.give(copy, cw, ch);
        blit(f.cmd, f.target, .{ b.x0, b.y0, b.x1, b.y1 }, copy, 0, 0);
        const t0 = p.pool.take(device, tw, th);
        defer p.pool.give(t0, tw, th);
        const t1 = p.pool.take(device, tw, th);
        defer p.pool.give(t1, tw, th);
        const down: f32 = @floatFromInt(b.down);
        const radius: f32 = @floatFromInt(b.radius);
        const whole: [4]f32 = .{ 0, 0, @floatFromInt(tw), @floatFromInt(th) };
        pass(f.cmd, p.down.?, copy, t0, tw, th, .{ .area = whole, .info = .{ down, b.sigma, radius, 0 }, .dir = .{ 0, 0, @floatFromInt(b.x1 - b.x0), @floatFromInt(b.y1 - b.y0) } }, false);
        if (b.radius > 0) {
            pass(f.cmd, p.blur.?, t0, t1, tw, th, .{ .area = whole, .info = .{ down, b.sigma, radius, 0 }, .dir = .{ 1, 0, @floatFromInt(tw), @floatFromInt(th) } }, false);
            pass(f.cmd, p.blur.?, t1, t0, tw, th, .{ .area = whole, .info = .{ down, b.sigma, radius, 0 }, .dir = .{ 0, 1, @floatFromInt(tw), @floatFromInt(th) } }, false);
        }
        var k: Constants = .{
            .area = areaOf(a),
            .info = .{ down, b.sigma, radius, 0 },
            .shape = shape,
            .shape2 = .{ i.radius * s, s, i.clip_round, 0 },
            .clip = i.clip,
            .origin = .{ @floatFromInt(b.x0), @floatFromInt(b.y0), @floatFromInt(tw), @floatFromInt(th) },
        };
        k.params = effect.paramsOf(rows, row).*;
        pass(f.cmd, p.pipelineFor(device, effect.shaderOf(rows, row)), t0, f.target, f.w, f.h, k, true);
    }

    fn beginLayer(p: *Passes, device: objc.Object, f: Frame, i: *const gpu.Instance) void {
        const a = raster_fx.area(f.w, f.h, i.rect, i.clip, f.scale) orelse [4]usize{ 0, 0, 0, 0 };
        const kept = p.pool.take(device, @intCast(a[2] - a[0]), @intCast(a[3] - a[1]));
        if (a[2] > a[0] and a[3] > a[1]) {
            blit(f.cmd, f.target, a, kept, 0, 0);
            pass(f.cmd, p.clear.?, null, f.target, f.w, f.h, .{ .area = areaOf(a) }, true);
        }
        p.layers.append(gpa, .{ .tex = kept, .area = a }) catch p.pool.give(kept, @intCast(a[2] - a[0]), @intCast(a[3] - a[1]));
    }

    fn endLayer(p: *Passes, device: objc.Object, f: Frame, i: *const gpu.Instance) void {
        const l = p.layers.pop() orelse return;
        defer p.pool.give(l.tex, @intCast(l.area[2] - l.area[0]), @intCast(l.area[3] - l.area[1]));
        const a = l.area;
        if (a[2] <= a[0] or a[3] <= a[1]) return;
        const aw: u32 = @intCast(a[2] - a[0]);
        const ah: u32 = @intCast(a[3] - a[1]);
        const layer = p.pool.take(device, aw, ah);
        defer p.pool.give(layer, aw, ah);
        blit(f.cmd, f.target, a, layer, 0, 0);
        const sigma = i.border_width * f.scale;
        var buf: [backdrop.max_radius + 1]f32 = undefined;
        const radius: f32 = @floatFromInt(raster_fx.layerWeights(sigma, &buf).len - 1);
        if (radius > 0) {
            const t = p.pool.take(device, aw, ah);
            defer p.pool.give(t, aw, ah);
            const whole: [4]f32 = .{ 0, 0, @floatFromInt(aw), @floatFromInt(ah) };
            pass(f.cmd, p.blur.?, layer, t, aw, ah, .{ .area = whole, .info = .{ 1, sigma, radius, 1 }, .dir = .{ 1, 0, @floatFromInt(aw), @floatFromInt(ah) } }, false);
            pass(f.cmd, p.blur.?, t, layer, aw, ah, .{ .area = whole, .info = .{ 1, sigma, radius, 1 }, .dir = .{ 0, 1, @floatFromInt(aw), @floatFromInt(ah) } }, false);
        }
        // What was under it, then the layer over it.
        blit(f.cmd, l.tex, .{ 0, 0, aw, ah }, f.target, a[0], a[1]);
        pass(f.cmd, p.layer.?, layer, f.target, f.w, f.h, .{ .area = areaOf(a) }, true);
    }

    /// The pipeline of an effect, made the first time it draws.
    fn pipelineFor(p: *Passes, device: objc.Object, s: ?*const effect.Shader) objc.Object {
        const shader = s orelse return p.plain.?;
        if (shader.msl.len == 0) return p.plain.?;
        const gop = p.effects.getOrPut(gpa, @intFromPtr(shader)) catch return p.plain.?;
        if (!gop.found_existing) gop.value_ptr.* = effectPipeline(device, shader.msl) catch |e| blk: {
            std.log.warn("myzig: effect {s}: {s}", .{ shader.name, @errorName(e) });
            break :blk null;
        };
        return gop.value_ptr.* orelse p.plain.?;
    }
};

fn areaOf(a: [4]usize) [4]f32 {
    return .{ @floatFromInt(a[0]), @floatFromInt(a[1]), @floatFromInt(a[2] - a[0]), @floatFromInt(a[3] - a[1]) };
}

/// A texture drawn into and read, on the GPU only (owned).
fn texture(device: objc.Object, w: u32, h: u32) objc.Object {
    const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
        pixel_format, @as(objc.NSUInteger, @max(w, 1)), @as(objc.NSUInteger, @max(h, 1)), objc.NO,
    });
    objc.msg(void, desc, "setUsage:", .{@as(objc.NSUInteger, 1 | 4)}); // shader read, render target
    objc.msg(void, desc, "setStorageMode:", .{@as(objc.NSUInteger, 2)}); // private
    return objc.msg(objc.Object, device, "newTextureWithDescriptor:", .{desc});
}

/// Copies pixels `a` (x0, y0, x1, y1) of `src` to (`x`, `y`) of `dst`.
fn blit(cmd: objc.Object, src: objc.Object, a: [4]usize, dst: objc.Object, x: usize, y: usize) void {
    const enc = objc.msg(objc.Object, cmd, "blitCommandEncoder", .{});
    objc.msg(void, enc, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:", .{
        src,                     @as(objc.NSUInteger, 0),           @as(objc.NSUInteger, 0),
        Origin{ .x = a[0], .y = a[1] }, Size{ .w = a[2] - a[0], .h = a[3] - a[1] }, dst,
        @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 0),           Origin{ .x = x, .y = y },
    });
    objc.msg(void, enc, "endEncoding", .{});
}

/// A render pass of `pipe` reading `src` into `dst` (`w` × `h`): what is
/// there is kept when `load` (the frame), else drawn over whole.
fn pass(cmd: objc.Object, pipe: objc.Object, src: ?objc.Object, dst: objc.Object, w: u32, h: u32, k_in: Constants, load: bool) void {
    var k = k_in;
    k.target = .{ @floatFromInt(w), @floatFromInt(h), 0, 0 };
    const desc = objc.msg(objc.Object, objc.class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{});
    const ca = objc.msg(objc.Object, objc.msg(objc.Object, desc, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(objc.NSUInteger, 0)});
    objc.msg(void, ca, "setTexture:", .{dst});
    objc.msg(void, ca, "setLoadAction:", .{@as(objc.NSUInteger, if (load) 1 else 0)}); // load, or don't care
    objc.msg(void, ca, "setStoreAction:", .{@as(objc.NSUInteger, 1)}); // store
    const enc = objc.msg(objc.Object, cmd, "renderCommandEncoderWithDescriptor:", .{desc});
    objc.msg(void, enc, "setRenderPipelineState:", .{pipe});
    objc.msg(void, enc, "setVertexBytes:length:atIndex:", .{ @as(*const anyopaque, &k), @as(objc.NSUInteger, @sizeOf(Constants)), @as(objc.NSUInteger, 0) });
    objc.msg(void, enc, "setFragmentBytes:length:atIndex:", .{ @as(*const anyopaque, &k), @as(objc.NSUInteger, @sizeOf(Constants)), @as(objc.NSUInteger, 0) });
    if (src) |t| objc.msg(void, enc, "setFragmentTexture:atIndex:", .{ t, @as(objc.NSUInteger, 0) });
    objc.msg(void, enc, "drawPrimitives:vertexStart:vertexCount:", .{ @as(objc.NSUInteger, 4), @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 4) });
    objc.msg(void, enc, "endEncoding", .{});
}

fn library(device: objc.Object, src: []const u8) !objc.Object {
    var err: ?objc.Object = null;
    const str = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSString"), "alloc", .{}), "initWithBytes:length:encoding:", .{ @as(*const anyopaque, src.ptr), @as(objc.NSUInteger, src.len), @as(objc.NSUInteger, 4) });
    defer objc.release(str);
    return objc.msg(?objc.Object, device, "newLibraryWithSource:options:error:", .{ str, @as(?objc.Object, null), &err }) orelse {
        if (err) |e| std.log.err("myzig: effect shader: {s}", .{objc.fromNSString(objc.msg(objc.Object, e, "localizedDescription", .{}))});
        return error.ShaderCompile;
    };
}

/// A pipeline of `fragment` in `lib`, blending premultiplied or not.
fn pipeline(device: objc.Object, lib: objc.Object, fragment: [:0]const u8, blend: bool) !objc.Object {
    const vs = objc.msg(objc.Object, lib, "newFunctionWithName:", .{objc.nsString("fx_vs")});
    defer objc.release(vs);
    const fs = objc.msg(?objc.Object, lib, "newFunctionWithName:", .{objc.nsString(fragment)}) orelse return error.ShaderCompile;
    defer objc.release(fs);
    const desc = objc.new("MTLRenderPipelineDescriptor");
    defer objc.release(desc);
    objc.msg(void, desc, "setVertexFunction:", .{vs});
    objc.msg(void, desc, "setFragmentFunction:", .{fs});
    const ca = objc.msg(objc.Object, objc.msg(objc.Object, desc, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(objc.NSUInteger, 0)});
    objc.msg(void, ca, "setPixelFormat:", .{pixel_format});
    if (blend) {
        objc.msg(void, ca, "setBlendingEnabled:", .{objc.YES});
        objc.msg(void, ca, "setSourceRGBBlendFactor:", .{@as(objc.NSUInteger, 1)});
        objc.msg(void, ca, "setSourceAlphaBlendFactor:", .{@as(objc.NSUInteger, 1)});
        objc.msg(void, ca, "setDestinationRGBBlendFactor:", .{@as(objc.NSUInteger, 5)});
        objc.msg(void, ca, "setDestinationAlphaBlendFactor:", .{@as(objc.NSUInteger, 5)});
    }
    var err: ?objc.Object = null;
    return objc.msg(?objc.Object, device, "newRenderPipelineStateWithDescriptor:error:", .{ desc, &err }) orelse error.PipelineCreate;
}

fn effectPipeline(device: objc.Object, color: []const u8) !objc.Object {
    const src = try std.mem.concat(gpa, u8, &.{ source, "\n", color, effect_main });
    defer gpa.free(src);
    const lib = try library(device, src);
    defer objc.release(lib);
    return pipeline(device, lib, "fx_effect", true);
}
