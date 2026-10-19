//! The CPU renderer's effects and blurred layers, drawn between the parts
//! of a frame (`raster.draw`), every band of the part before done:
//!
//! - a backdrop effect (`effect.zig`) reads the frame around its shape
//!   (`backdrop.zig`), and draws the shape from it, with its shader's CPU
//!   twin or as it is, smoothed along its edge;
//! - a blurred layer (`Style.blur`) keeps what is under its area and
//!   clears it; what draws until its end draws there alone; at its end the
//!   area is blurred, transparent around it, and drawn over what was kept.
//!
//! The GPU renderers draw both with the same steps over textures.
const std = @import("std");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const effect = @import("effect.zig");
const backdrop = @import("backdrop.zig");

const gpa = std.heap.page_allocator;

pub const marker = gpu.isMarker;

const Layer = struct { area: [4]usize, kept: []u8 };

/// Blurred layers open, innermost last.
pub const Layers = struct {
    list: std.ArrayList(Layer) = .empty,

    pub fn deinit(l: *Layers) void {
        for (l.list.items) |x| gpa.free(x.kept);
        l.list.deinit(gpa);
    }
};

/// The pixels of `r` (points) within `clip`, as `raster.bounds` rounds.
pub fn area(width: usize, height: usize, r: [4]f32, clip: [4]f32, scale: f32) ?[4]usize {
    const x0 = @max(r[0], clip[0]);
    const y0 = @max(r[1], clip[1]);
    const x1 = @min(r[0] + r[2], clip[2]);
    const y1 = @min(r[1] + r[3], clip[3]);
    if (x1 <= x0 or y1 <= y0) return null;
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    const px0 = std.math.clamp(@round(x0 * scale), 0, w);
    const py0 = std.math.clamp(@round(y0 * scale), 0, h);
    const px1 = std.math.clamp(@round(x1 * scale), 0, w);
    const py1 = std.math.clamp(@round(y1 * scale), 0, h);
    if (px1 <= px0 or py1 <= py0) return null;
    return .{ @intFromFloat(px0), @intFromFloat(py0), @intFromFloat(px1), @intFromFloat(py1) };
}

pub fn apply(out: gpu.Pixels, i: *const gpu.Instance, rows: []const [4]f32, scale: f32, layers: *Layers) void {
    // Effects and layers turned with their box are not drawn (yet).
    if (i.kind >= 16) return;
    if (i.kind == gpu.Kind.effect) return drawEffect(out, i, rows, scale);
    if (i.kind == gpu.Kind.layer) {
        const a = area(out.width, out.height, i.rect, i.clip, scale) orelse [4]usize{ 0, 0, 0, 0 };
        const kept = gpa.alloc(u8, (a[2] - a[0]) * (a[3] - a[1]) * 4) catch return;
        const rw = (a[2] - a[0]) * 4;
        for (a[1]..a[3], 0..) |y, k| {
            const row = out.bytes[(y * out.width + a[0]) * 4 ..][0..rw];
            @memcpy(kept[k * rw ..][0..rw], row);
            @memset(row, 0);
        }
        layers.list.append(gpa, .{ .area = a, .kept = kept }) catch gpa.free(kept);
        return;
    }
    const l = layers.list.pop() orelse return;
    defer gpa.free(l.kept);
    composite(out, l, i.border_width * scale);
}

/// The layer's area blurred by `sigma` pixels, transparent around it,
/// over what was under it.
fn composite(out: gpu.Pixels, l: Layer, sigma: f32) void {
    const a = l.area;
    const w = a[2] - a[0];
    const h = a[3] - a[1];
    if (w == 0 or h == 0) return;
    const layer = gpa.alloc(f32, w * h * 4) catch return;
    defer gpa.free(layer);
    for (0..h) |y| for (0..w) |x| {
        const p = out.bytes[((a[1] + y) * out.width + a[0] + x) * 4 ..][0..4];
        for (0..4) |ch| layer[(y * w + x) * 4 + ch] = @as(f32, @floatFromInt(p[ch])) / 255;
    };
    blurLayer(layer, w, h, sigma) catch {};
    // What was under it, then the layer over it.
    for (0..h) |y| {
        const row = ((a[1] + y) * out.width + a[0]) * 4;
        @memcpy(out.bytes[row..][0 .. w * 4], l.kept[y * w * 4 ..][0 .. w * 4]);
        for (0..w) |x| {
            const t = layer[(y * w + x) * 4 ..][0..4];
            raster.blend(out.bytes, row + x * 4, t[2], t[1], t[0], t[3]);
        }
    }
}

/// The weights of a Gaussian of `sigma` texels, out to 3 sigma, unnormalized.
pub fn layerWeights(sigma: f32, buf: *[backdrop.max_radius + 1]f32) []const f32 {
    const radius: usize = @min(backdrop.max_radius, @as(usize, @intFromFloat(@ceil(3 * @max(sigma, 0)))));
    for (buf[0 .. radius + 1], 0..) |*v, k| {
        const x: f32 = @floatFromInt(k);
        v.* = if (sigma <= 0) 1 else @exp(-(x * x) / (2 * sigma * sigma));
    }
    return buf[0 .. radius + 1];
}

/// Blurs BGRA texels (n/255) rows then columns, transparent past the
/// edges, each pass rounded to 8 bits as a texture holds it.
fn blurLayer(pix: []f32, w: usize, h: usize, sigma: f32) !void {
    var buf: [backdrop.max_radius + 1]f32 = undefined;
    const wt = layerWeights(sigma, &buf);
    if (wt.len <= 1) return;
    var sum = wt[0];
    for (wt[1..]) |v| sum += 2 * v;
    const tmp = try gpa.alloc(f32, pix.len);
    defer gpa.free(tmp);
    for (0..2) |pass| {
        const src = if (pass == 0) pix else tmp;
        const dst = if (pass == 0) tmp else pix;
        const n = if (pass == 0) w else h;
        const lines = if (pass == 0) h else w;
        for (0..lines) |line| for (0..n) |i| {
            var c: [4]f32 = @splat(0);
            for (0..wt.len) |o| {
                const k: f32 = wt[o];
                inline for (.{ -1, 1 }) |dir| {
                    if (!(o == 0 and dir == 1)) {
                        const at: isize = @as(isize, @intCast(i)) + dir * @as(isize, @intCast(o));
                        if (at >= 0 and at < n) {
                            const u: usize = @intCast(at);
                            const idx = if (pass == 0) (line * w + u) * 4 else (u * w + line) * 4;
                            for (0..4) |ch| c[ch] += src[idx + ch] * k;
                        }
                    }
                }
            }
            const idx = if (pass == 0) (line * w + i) * 4 else (i * w + line) * 4;
            for (0..4) |ch| dst[idx + ch] = backdrop.texel(c[ch] / sum);
        };
    }
}

fn sdRound(r: [4]f32, radius: f32, px: f32, py: f32) f32 {
    const hx = r[2] / 2;
    const hy = r[3] / 2;
    const rad = @min(radius, hx, hy);
    const ax = @abs(px - r[0] - hx) - hx + rad;
    const ay = @abs(py - r[1] - hy) - hy + rad;
    const mx = @max(ax, 0);
    const my = @max(ay, 0);
    return @sqrt(mx * mx + my * my) + @min(@max(ax, ay), 0) - rad;
}

fn drawEffect(out: gpu.Pixels, i: *const gpu.Instance, rows: []const [4]f32, scale: f32) void {
    const row: usize = @intFromFloat(i.uv[0]);
    if (row + effect.rows_per_effect > rows.len) return;
    const a = area(out.width, out.height, i.rect, i.clip, scale) orelse return;
    const r: [4]f32 = .{ i.rect[0] * scale, i.rect[1] * scale, i.rect[2] * scale, i.rect[3] * scale };
    const radius = i.radius * scale;
    const img: backdrop.Image = .{ .bytes = out.bytes, .width = out.width, .height = out.height };
    var b = backdrop.Backdrop.of(r, rows[row][0] * scale, out.width, out.height);
    b.read(gpa, img) catch return;
    defer b.deinit(gpa);
    if (b.pix.len == 0) return;
    const shader = effect.shaderOf(rows, row);
    const params = effect.paramsOf(rows, row);
    const inv = 1 / scale;
    for (a[1]..a[3]) |y| for (a[0]..a[2]) |x| {
        const px = @as(f32, @floatFromInt(x)) + 0.5;
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        // Smoothed along the edge, half a pixel each way.
        const cov = std.math.clamp(0.5 - sdRound(r, radius, px, py), 0, 1) * raster.clipCover(i, px * inv, py * inv, inv);
        if (cov <= 0) continue;
        const in: effect.Input = .{ .p = .{ px, py }, .rect = r, .radius = radius, .params = params, .backdrop = &b };
        const c = if (shader) |s| s.cpu(&in) else b.sample(px, py);
        raster.blend(out.bytes, (y * out.width + x) * 4, c[0] * cov, c[1] * cov, c[2] * cov, cov);
    };
}
