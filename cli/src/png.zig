//! Icons' pixels: PNGs read with myzig's decoder, scaled to the sizes
//! platforms want (area averaging down, bilinear up, in premultiplied
//! alpha so that transparent pixels don't darken edges), and written back
//! as compressed PNGs.
const std = @import("std");
const png_decode = @import("png_decode");
const compress = @import("compress.zig");

/// Straight (not premultiplied) RGBA, `width * 4` bytes a row.
pub const Image = struct {
    width: u32,
    height: u32,
    rgba: []u8,

    pub fn deinit(img: Image, gpa: std.mem.Allocator) void {
        gpa.free(img.rgba);
    }
};

/// Decodes a PNG into premultiplied RGBA, the form `resize` works in.
fn decodePremultiplied(gpa: std.mem.Allocator, bytes: []const u8) !Image {
    const d = try png_decode.decode(gpa, bytes);
    // BGRA to RGBA, in place.
    var i: usize = 0;
    while (i + 4 <= d.bgra.len) : (i += 4) std.mem.swap(u8, &d.bgra[i], &d.bgra[i + 2]);
    return .{ .width = d.width, .height = d.height, .rgba = d.bgra };
}

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) !Image {
    const img = try decodePremultiplied(gpa, bytes);
    unpremultiply(img.rgba);
    return img;
}

fn unpremultiply(px: []u8) void {
    var i: usize = 0;
    while (i + 4 <= px.len) : (i += 4) {
        const a: u32 = px[i + 3];
        if (a == 0 or a == 255) continue;
        for (px[i..][0..3]) |*c| c.* = @intCast(@min(255, (@as(u32, c.*) * 255 + a / 2) / a));
    }
}

/// The width and height of a PNG, from its header.
pub fn size(bytes: []const u8) !struct { u32, u32 } {
    if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n") or !std.mem.eql(u8, bytes[12..16], "IHDR")) return error.NotPng;
    return .{ std.mem.readInt(u32, bytes[16..20], .big), std.mem.readInt(u32, bytes[20..24], .big) };
}

/// Checks that an icon is a square PNG.
pub fn validateIcon(bytes: []const u8) !void {
    const w, const h = try size(bytes);
    if (w != h) return error.IconNotSquare;
}

/// The premultiplied `src` scaled to `n` x `n`, straight alpha out.
fn resizePremultiplied(gpa: std.mem.Allocator, src: Image, n: u32) !Image {
    const out = try gpa.alloc(u8, @as(usize, n) * n * 4);
    @memset(out, 0);
    const w = src.width;
    const h = src.height;
    if (w == 0 or h == 0) return .{ .width = n, .height = n, .rgba = out };
    const sx = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(n));
    const sy = @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(n));
    const at = struct {
        fn f(s: Image, x: i64, y: i64) [4]f64 {
            const cx: usize = @intCast(std.math.clamp(x, 0, @as(i64, s.width) - 1));
            const cy: usize = @intCast(std.math.clamp(y, 0, @as(i64, s.height) - 1));
            const p = s.rgba[(cy * s.width + cx) * 4 ..][0..4];
            return .{ @floatFromInt(p[0]), @floatFromInt(p[1]), @floatFromInt(p[2]), @floatFromInt(p[3]) };
        }
    }.f;
    for (0..n) |y| for (0..n) |x| {
        var acc: [4]f64 = .{ 0, 0, 0, 0 };
        var wsum: f64 = 0;
        const fx: f64 = @floatFromInt(x);
        const fy: f64 = @floatFromInt(y);
        if (sx >= 1) {
            const x0: i64 = @intFromFloat(fx * sx);
            const x1: i64 = @max(@as(i64, @intFromFloat((fx + 1) * sx)), x0 + 1);
            const y0: i64 = @intFromFloat(fy * sy);
            const y1: i64 = @max(@as(i64, @intFromFloat((fy + 1) * sy)), y0 + 1);
            var yy = y0;
            while (yy < y1) : (yy += 1) {
                var xx = x0;
                while (xx < x1) : (xx += 1) {
                    const c = at(src, xx, yy);
                    for (&acc, c) |*a, v| a.* += v;
                    wsum += 1;
                }
            }
        } else {
            const px = (fx + 0.5) * sx - 0.5;
            const py = (fy + 0.5) * sy - 0.5;
            const x0: i64 = @intFromFloat(@floor(px));
            const y0: i64 = @intFromFloat(@floor(py));
            const dx = px - @as(f64, @floatFromInt(x0));
            const dy = py - @as(f64, @floatFromInt(y0));
            const taps = [4]struct { i64, i64, f64 }{
                .{ x0, y0, (1 - dx) * (1 - dy) },     .{ x0 + 1, y0, dx * (1 - dy) },
                .{ x0, y0 + 1, (1 - dx) * dy },       .{ x0 + 1, y0 + 1, dx * dy },
            };
            for (taps) |t| {
                const c = at(src, t[0], t[1]);
                for (&acc, c) |*a, v| a.* += v * t[2];
                wsum += t[2];
            }
        }
        const alpha = acc[3] / wsum;
        if (alpha < 0.5 / 255.0) continue;
        const o = out[(y * n + x) * 4 ..][0..4];
        // Premultiplied sums: divide by the alpha to straighten.
        for (0..3) |k| o[k] = @intFromFloat(@min(255, @round(acc[k] / acc[3] * 255)));
        o[3] = @intFromFloat(@min(255, @round(alpha)));
    };
    return .{ .width = n, .height = n, .rgba = out };
}

/// A PNG decoded once, rendered at many sizes.
pub const Source = struct {
    premultiplied: Image,

    pub fn init(gpa: std.mem.Allocator, bytes: []const u8) !Source {
        return .{ .premultiplied = try decodePremultiplied(gpa, bytes) };
    }

    pub fn deinit(s: Source, gpa: std.mem.Allocator) void {
        s.premultiplied.deinit(gpa);
    }

    /// The image at `n` x `n`, as a PNG file.
    pub fn png(s: Source, gpa: std.mem.Allocator, n: u32) ![]u8 {
        const img = try resizePremultiplied(gpa, s.premultiplied, n);
        defer img.deinit(gpa);
        return encode(gpa, img);
    }
};

fn chunk(out: *std.ArrayList(u8), gpa: std.mem.Allocator, kind: *const [4]u8, data: []const u8) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, @intCast(data.len), .big);
    try out.appendSlice(gpa, &b);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, data);
    var c = std.hash.Crc32.init();
    c.update(kind);
    c.update(data);
    std.mem.writeInt(u32, &b, c.final(), .big);
    try out.appendSlice(gpa, &b);
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    return if (pb <= pc) b else c;
}

/// Encodes straight RGBA as an 8-bit RGBA PNG, each row with the filter
/// that leaves it smallest (by the sum of its bytes as signed values).
pub fn encode(gpa: std.mem.Allocator, img: Image) ![]u8 {
    const stride = @as(usize, img.width) * 4;
    const raw = try gpa.alloc(u8, (stride + 1) * img.height);
    defer gpa.free(raw);
    const trial = try gpa.alloc(u8, stride);
    defer gpa.free(trial);
    for (0..img.height) |y| {
        const row = img.rgba[y * stride ..][0..stride];
        const dst = raw[y * (stride + 1) ..][0 .. stride + 1];
        var best: u64 = std.math.maxInt(u64);
        for (0..5) |f| {
            for (0..stride) |i| {
                const a: u8 = if (i >= 4) row[i - 4] else 0;
                const b: u8 = if (y > 0) img.rgba[(y - 1) * stride + i] else 0;
                const c: u8 = if (y > 0 and i >= 4) img.rgba[(y - 1) * stride + i - 4] else 0;
                trial[i] = row[i] -% switch (f) {
                    0 => 0,
                    1 => a,
                    2 => b,
                    3 => @as(u8, @intCast((@as(u16, a) + b) / 2)),
                    else => paeth(a, b, c),
                };
            }
            var score: u64 = 0;
            for (trial) |v| score += @abs(@as(i8, @bitCast(v)));
            if (score < best) {
                best = score;
                dst[0] = @intCast(f);
                @memcpy(dst[1..], trial);
            }
        }
    }
    const z = try compress.deflate(gpa, raw, .zlib);
    defer gpa.free(z);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], img.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], img.height, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    try chunk(&out, gpa, "IHDR", &ihdr);
    try chunk(&out, gpa, "IDAT", z);
    try chunk(&out, gpa, "IEND", "");
    return out.toOwnedSlice(gpa);
}

/// A test icon: an opaque disc of `color` on transparency.
pub fn testIcon(gpa: std.mem.Allocator, n: u32, color: [3]u8) ![]u8 {
    const px = try gpa.alloc(u8, @as(usize, n) * n * 4);
    defer gpa.free(px);
    const r = @as(f64, @floatFromInt(n)) / 2;
    for (0..n) |y| for (0..n) |x| {
        const dx = @as(f64, @floatFromInt(x)) + 0.5 - r;
        const dy = @as(f64, @floatFromInt(y)) + 0.5 - r;
        const in = dx * dx + dy * dy <= r * r;
        px[(y * n + x) * 4 ..][0..4].* = if (in) .{ color[0], color[1], color[2], 255 } else .{ 0, 0, 0, 0 };
    };
    return encode(gpa, .{ .width = n, .height = n, .rgba = px });
}

test "encode, decode and resize" {
    const gpa = std.testing.allocator;
    const icon = try testIcon(gpa, 64, .{ 200, 40, 10 });
    defer gpa.free(icon);
    const w, const h = try size(icon);
    try std.testing.expectEqual(@as(u32, 64), w);
    try std.testing.expectEqual(@as(u32, 64), h);
    try validateIcon(icon);
    const back = try decode(gpa, icon);
    defer back.deinit(gpa);
    // The center is the color, the corner transparent.
    try std.testing.expectEqualSlices(u8, &.{ 200, 40, 10, 255 }, back.rgba[(32 * 64 + 32) * 4 ..][0..4]);
    try std.testing.expectEqual(@as(u8, 0), back.rgba[3]);

    const src = try Source.init(gpa, icon);
    defer src.deinit(gpa);
    for ([_]u32{ 16, 128 }) |n| {
        const p = try src.png(gpa, n);
        defer gpa.free(p);
        const img = try decode(gpa, p);
        defer img.deinit(gpa);
        try std.testing.expectEqual(n, img.width);
        const c = img.rgba[((n / 2) * n + n / 2) * 4 ..][0..4];
        // Edges average with transparency without darkening the color.
        try std.testing.expectEqualSlices(u8, &.{ 200, 40, 10, 255 }, c);
        try std.testing.expectEqual(@as(u8, 0), img.rgba[3]);
    }
}
