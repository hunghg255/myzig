//! What a backdrop effect reads of what is under it (`effect.zig`), as
//! every renderer reads it, after mygo's renderers: the pixels of an area
//! around the effect's shape, averaged over squares of `down` pixels a side
//! for large blurs, then blurred by a Gaussian rows then columns, rounded
//! to 8 bits at each step as the GPUs' textures hold them. The GPU
//! renderers do these steps in passes over textures; this is their CPU
//! twin, which the CPU renderer draws effects with.
const std = @import("std");

/// A frame's pixels: BGRA, premultiplied, `width * 4` bytes a row.
pub const Image = struct {
    bytes: []u8,
    width: usize,
    height: usize,
};

pub const Backdrop = struct {
    x0: usize,
    y0: usize,
    x1: usize,
    y1: usize,
    down: usize,
    sigma: f32,
    radius: usize,
    w: usize = 0,
    h: usize = 0,
    /// RGBA texels, premultiplied, each channel n/255.
    pix: []f32 = &.{},

    /// The backdrop of rectangle `r` (x, y, w, h, pixels) blurred by
    /// `blur` pixels (a standard deviation) in a frame of `fw`×`fh`. Large
    /// blurs are found at a fraction of the size, a power of two up to 8
    /// leaving at least 2 texels of blur.
    pub fn of(r: [4]f32, blur_in: f32, fw: usize, fh: usize) Backdrop {
        const amount = @max(blur_in, 0);
        var down: usize = 1;
        while (down < 8 and amount / @as(f32, @floatFromInt(2 * down)) >= 2) down *= 2;
        const df: f32 = @floatFromInt(down);
        const sigma: f32 = if (amount == 0) 0 else @sqrt(@max(amount * amount - df * df / 12, 0)) / df;
        const radius: usize = @min(max_radius, @as(usize, @intFromFloat(@ceil(3 * sigma))));
        const reach: f32 = @floatFromInt(radius * down + down);
        const fwf: f32 = @floatFromInt(fw);
        const fhf: f32 = @floatFromInt(fh);
        return .{
            .x0 = @intFromFloat(std.math.clamp(@floor(r[0] - reach), 0, fwf)),
            .y0 = @intFromFloat(std.math.clamp(@floor(r[1] - reach), 0, fhf)),
            .x1 = @intFromFloat(std.math.clamp(@ceil(r[0] + r[2] + reach), 0, fwf)),
            .y1 = @intFromFloat(std.math.clamp(@ceil(r[1] + r[3] + reach), 0, fhf)),
            .down = down,
            .sigma = sigma,
            .radius = radius,
        };
    }

    /// The texels it is made of, across and down.
    pub fn texels(b: *const Backdrop) [2]usize {
        if (b.x1 <= b.x0 or b.y1 <= b.y0) return .{ 0, 0 };
        return .{ (b.x1 - b.x0 + b.down - 1) / b.down, (b.y1 - b.y0 + b.down - 1) / b.down };
    }

    /// Reads the backdrop from `img`.
    pub fn read(b: *Backdrop, gpa: std.mem.Allocator, img: Image) !void {
        const size = b.texels();
        if (size[0] == 0) return;
        const k = b.down;
        b.w = size[0];
        b.h = size[1];
        b.pix = try gpa.alloc(f32, 4 * b.w * b.h);
        const inv = 1 / @as(f32, @floatFromInt(k * k));
        for (0..b.h) |j| for (0..b.w) |i| {
            var c: [4]f32 = @splat(0);
            for (0..k) |dy| {
                const y = @min(b.y0 + j * k + dy, b.y1 - 1);
                for (0..k) |dx| {
                    const x = @min(b.x0 + i * k + dx, b.x1 - 1);
                    const p = img.bytes[4 * (y * img.width + x) ..][0..4];
                    c[0] += @as(f32, @floatFromInt(p[2])) / 255;
                    c[1] += @as(f32, @floatFromInt(p[1])) / 255;
                    c[2] += @as(f32, @floatFromInt(p[0])) / 255;
                    c[3] += @as(f32, @floatFromInt(p[3])) / 255;
                }
            }
            for (0..4) |ch| b.pix[4 * (j * b.w + i) + ch] = texel(c[ch] * inv);
        };
        if (b.radius == 0) return;
        var wbuf: [max_radius + 1]f32 = undefined;
        const w = b.weights(&wbuf);
        const tmp = try gpa.alloc(f32, b.pix.len);
        defer gpa.free(tmp);
        for (0..b.h) |j| blurLine(tmp, b.pix, 4, 4 * b.w * j, b.w, w);
        for (0..b.w) |i| blurLine(b.pix, tmp, 4 * b.w, 4 * i, b.h, w);
    }

    /// The Gaussian's weights from its middle out, unnormalized.
    pub fn weights(b: *const Backdrop, buf: *[max_radius + 1]f32) []const f32 {
        const n = @min(b.radius, max_radius) + 1;
        for (buf[0..n], 0..) |*w, i| {
            const x: f32 = @floatFromInt(i);
            w.* = if (b.sigma <= 0) 1 else @exp(-(x * x) / (2 * b.sigma * b.sigma));
        }
        return buf[0..n];
    }

    pub fn deinit(b: *Backdrop, gpa: std.mem.Allocator) void {
        gpa.free(b.pix);
        b.pix = &.{};
    }

    /// The backdrop at (x, y), in the frame's pixels: premultiplied RGB,
    /// filtered bilinearly and clamped to its edges.
    pub fn sample(b: *const Backdrop, x: f32, y: f32) [3]f32 {
        const k: f32 = @floatFromInt(b.down);
        const u = (x - @as(f32, @floatFromInt(b.x0))) / k - 0.5;
        const v = (y - @as(f32, @floatFromInt(b.y0))) / k - 0.5;
        const fu = @floor(u);
        const fv = @floor(v);
        const tx = u - fu;
        const ty = v - fv;
        const x0 = clampIndex(fu, b.w);
        const y0 = clampIndex(fv, b.h);
        const x1 = clampIndex(fu + 1, b.w);
        const y1 = clampIndex(fv + 1, b.h);
        var c: [3]f32 = undefined;
        for (0..3) |i| {
            const top = b.pix[4 * (y0 * b.w + x0) + i] * (1 - tx) + b.pix[4 * (y0 * b.w + x1) + i] * tx;
            const bot = b.pix[4 * (y1 * b.w + x0) + i] * (1 - tx) + b.pix[4 * (y1 * b.w + x1) + i] * tx;
            c[i] = top * (1 - ty) + bot * ty;
        }
        return c;
    }
};

/// The most texels a blur reaches each way (three standard deviations of
/// 8 texels after downsampling, with room).
pub const max_radius = 64;

fn clampIndex(v: f32, n: usize) usize {
    return @intFromFloat(std.math.clamp(v, 0, @as(f32, @floatFromInt(n - 1))));
}

/// `v` as an 8-bit channel of a texture holds it.
pub fn texel(v: f32) f32 {
    return @round(std.math.clamp(v, 0, 1) * 255) / 255;
}

/// Blurs a line of `n` texels `step` apart from `base`, clamping at its ends.
fn blurLine(dst: []f32, src: []const f32, step: usize, base: usize, n: usize, w: []const f32) void {
    const rad = w.len - 1;
    var sum = w[0];
    for (1..rad + 1) |o| sum += 2 * w[o];
    for (0..n) |i| {
        var c: [4]f32 = undefined;
        for (0..4) |ch| c[ch] = src[base + i * step + ch] * w[0];
        for (1..rad + 1) |o| {
            const a = base + (if (i >= o) i - o else 0) * step;
            const b = base + @min(i + o, n - 1) * step;
            for (0..4) |ch| c[ch] += (src[a + ch] + src[b + ch]) * w[o];
        }
        for (0..4) |ch| dst[base + i * step + ch] = texel(c[ch] / sum);
    }
}

test "a backdrop blurs what is under it: stripes to gray" {
    const gpa = std.testing.allocator;
    const w = 64;
    const bytes = try gpa.alloc(u8, w * w * 4);
    defer gpa.free(bytes);
    for (0..w) |y| for (0..w) |x| {
        const v: u8 = if (x % 4 < 2) 0 else 255;
        bytes[(y * w + x) * 4 ..][0..4].* = .{ v, v, v, 255 };
    };
    var b = Backdrop.of(.{ 16, 16, 32, 32 }, 6, w, w);
    try b.read(gpa, .{ .bytes = bytes, .width = w, .height = w });
    defer b.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), b.down);
    const c = b.sample(32, 32);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), c[0], 0.05);
}
