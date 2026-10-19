//! The glass and the backdrop blur on the CPU, over a rendered frame's
//! pixels (BGRA, premultiplied, as myzig's renderers draw): what is under
//! a rounded rectangle is read (`Backdrop`, averaged and blurred as mygo's
//! renderers do, rounded to 8 bits at each step as textures hold it), then
//! the effect draws over it, antialiased along the shape's edge. These are
//! the CPU twins a renderer's effect hook would call (see the README).
const std = @import("std");
const material = @import("material.zig");
const Material = material.Material;

/// A frame's pixels: BGRA, premultiplied, `width * 4` bytes a row.
pub const Image = struct {
    bytes: []u8,
    width: usize,
    height: usize,
};

/// What an effect reads of what is under it: the pixels of an area,
/// averaged over squares of `down` pixels a side, blurred by a Gaussian of
/// standard deviation `sigma` texels out to `radius`, rows then columns.
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
    /// `blur` pixels in a frame of `fw`×`fh`. Large blurs are computed at
    /// a fraction of the size, a power of two up to 8 leaving at least 2
    /// texels of blur.
    pub fn of(r: [4]f32, blur_in: f32, fw: usize, fh: usize) Backdrop {
        const amount = @max(blur_in, 0);
        var down: usize = 1;
        while (down < 8 and amount / @as(f32, @floatFromInt(2 * down)) >= 2) down *= 2;
        const df: f32 = @floatFromInt(down);
        const sigma: f32 = if (amount == 0) 0 else @sqrt(@max(amount * amount - df * df / 12, 0)) / df;
        const radius: usize = @intFromFloat(@ceil(3 * sigma));
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

    /// Reads the backdrop from `img`.
    pub fn read(b: *Backdrop, gpa: std.mem.Allocator, img: Image) !void {
        if (b.x1 <= b.x0 or b.y1 <= b.y0) return;
        const k = b.down;
        b.w = (b.x1 - b.x0 + k - 1) / k;
        b.h = (b.y1 - b.y0 + k - 1) / k;
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
        const weights = try gpa.alloc(f32, b.radius + 1);
        defer gpa.free(weights);
        for (weights, 0..) |*w, i| {
            const x: f32 = @floatFromInt(i);
            w.* = if (b.sigma <= 0) 1 else @exp(-(x * x) / (2 * b.sigma * b.sigma));
        }
        const tmp = try gpa.alloc(f32, b.pix.len);
        defer gpa.free(tmp);
        for (0..b.h) |j| blurLine(tmp, b.pix, 4, 4 * b.w * j, b.w, weights);
        for (0..b.w) |i| blurLine(b.pix, tmp, 4 * b.w, 4 * i, b.h, weights);
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

fn clampIndex(v: f32, n: usize) usize {
    return @intFromFloat(std.math.clamp(v, 0, @as(f32, @floatFromInt(n - 1))));
}

/// `v` as an 8-bit channel of a texture holds it.
fn texel(v: f32) f32 {
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

/// The glass's color at the pixel center (x, y), over backdrop `b` (one
/// that `sample`s: a `Backdrop`, or a renderer's effect input).
pub fn glassColor(m: *const Material, r: [4]f32, radii: [4]f32, x: f32, y: f32, b: anytype) [3]f32 {
    const t = @max(-material.sdRoundRect(r, radii, x, y), 0);
    var n: [2]f32 = .{ 0, 0 };
    if (t < m.bezel or t < 3 * m.rim_width) n = material.normal(x, y, r, radii);
    var sx = x;
    var sy = y;
    if (t < m.bezel) {
        const d = m.refraction * material.lens(t, m.bezel);
        sx = x - n[0] * d;
        sy = y - n[1] * d;
    }
    var c = material.tone(b.sample(sx, sy), m);
    for (&c, 0..) |*v, i| v.* += (m.tint[i] - v.*) * m.tint[3];
    if (m.rim > 0 and t < 3 * m.rim_width) {
        const q = t / m.rim_width;
        const a = m.rim * @exp(-q * q);
        const l = @abs(n[0] * @cos(m.light) + n[1] * @sin(m.light));
        for (&c) |*v| v.* += (l - v.*) * a;
    }
    return c;
}

/// What an effect draws at a pixel.
const Effect = union(enum) {
    glass: *const Material,
    /// A plain blur: the backdrop as it is.
    blur,
};

/// Draws a pane of glass of material `m` over `img`, in the rounded
/// rectangle `r` (x, y, w, h) with `radii`, in pixels.
pub fn glass(gpa: std.mem.Allocator, img: Image, r: [4]f32, radii: [4]f32, m: Material) !void {
    try draw(gpa, img, r, radii, m.blur, .{ .glass = &m });
}

/// Blurs what is under the rounded rectangle `r` by `blur` pixels (the
/// standard deviation, as CSS's blur() takes), with no tint or rim.
pub fn blur(gpa: std.mem.Allocator, img: Image, r: [4]f32, radii: [4]f32, sigma: f32) !void {
    try draw(gpa, img, r, radii, sigma, .blur);
}

fn draw(gpa: std.mem.Allocator, img: Image, r: [4]f32, radii_in: [4]f32, sigma: f32, fx: Effect) !void {
    if (r[2] <= 0 or r[3] <= 0) return;
    var radii = radii_in;
    for (&radii) |*v| v.* = @min(v.*, r[2] / 2, r[3] / 2);
    var b = Backdrop.of(r, sigma, img.width, img.height);
    try b.read(gpa, img);
    defer b.deinit(gpa);
    if (b.pix.len == 0) return;
    const fw: f32 = @floatFromInt(img.width);
    const fh: f32 = @floatFromInt(img.height);
    const x0: usize = @intFromFloat(std.math.clamp(@floor(r[0]), 0, fw));
    const y0: usize = @intFromFloat(std.math.clamp(@floor(r[1]), 0, fh));
    const x1: usize = @intFromFloat(std.math.clamp(@ceil(r[0] + r[2]), 0, fw));
    const y1: usize = @intFromFloat(std.math.clamp(@ceil(r[1] + r[3]), 0, fh));
    for (y0..y1) |y| for (x0..x1) |x| {
        const px = @as(f32, @floatFromInt(x)) + 0.5;
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        // Antialiased along the edge: half a pixel each way.
        const cov = std.math.clamp(0.5 - material.sdRoundRect(r, radii, px, py), 0, 1);
        if (cov <= 0) continue;
        const c = switch (fx) {
            .glass => |m| glassColor(m, r, radii, px, py, &b),
            .blur => b.sample(px, py),
        };
        const p = img.bytes[4 * (y * img.width + x) ..][0..4];
        const rgb: [3]u8 = .{ p[2], p[1], p[0] };
        var out: [3]u8 = undefined;
        for (0..3) |i| {
            const dst = @as(f32, @floatFromInt(rgb[i])) / 255;
            out[i] = @intFromFloat(@round(std.math.clamp(c[i] * cov + dst * (1 - cov), 0, 1) * 255));
        }
        p[0] = out[2];
        p[1] = out[1];
        p[2] = out[0];
        p[3] = @intFromFloat(@round(std.math.clamp(cov + @as(f32, @floatFromInt(p[3])) / 255 * (1 - cov), 0, 1) * 255));
    };
}
