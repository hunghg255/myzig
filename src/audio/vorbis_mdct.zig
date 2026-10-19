//! Vorbis's inverse MDCT, through a DCT-IV computed with a complex FFT of
//! a quarter of the block, and its windows' slopes.
const std = @import("std");

const C = struct {
    re: f32,
    im: f32,

    fn mul(a: C, b: C) C {
        return .{ .re = a.re * b.re - a.im * b.im, .im = a.re * b.im + a.im * b.re };
    }
};

fn expi(x: f64) C {
    return .{ .re = @floatCast(@cos(x)), .im = @floatCast(@sin(x)) };
}

/// The tables of one block size `n` (n outputs from n/2 coefficients).
pub const Imdct = struct {
    n: usize,
    pre: []C,
    post: []C,
    twiddle: []C,
    rev: []u16,
    work: []C,
    /// The rising slope of a window over this block's half: n/2 values.
    slope: []f32,

    pub fn init(a: std.mem.Allocator, n: usize) !Imdct {
        const m = n / 2;
        const k = m / 2;
        const mf: f64 = @floatFromInt(m);
        const t: Imdct = .{
            .n = n,
            .pre = try a.alloc(C, k),
            .post = try a.alloc(C, k),
            .twiddle = try a.alloc(C, k / 2),
            .rev = try a.alloc(u16, k),
            .work = try a.alloc(C, k),
            .slope = try a.alloc(f32, m),
        };
        for (0..k) |i| {
            const fi: f64 = @floatFromInt(i);
            t.pre[i] = expi(-std.math.pi * fi / mf);
            t.post[i] = expi(-std.math.pi * (fi + 0.25) / mf);
        }
        for (t.twiddle, 0..) |*w, j| w.* = expi(-2 * std.math.pi * @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(k)));
        const bits: u5 = @intCast(std.math.log2_int(usize, k));
        for (t.rev, 0..) |*r, i| r.* = if (bits == 0) 0 else @intCast(@bitReverse(@as(u16, @intCast(i))) >> @intCast(16 - @as(u6, bits)));
        for (t.slope, 0..) |*s, i| {
            const x = (@as(f64, @floatFromInt(i)) + 0.5) / mf * (std.math.pi / 2.0);
            s.* = @floatCast(@sin((std.math.pi / 2.0) * @sin(x) * @sin(x)));
        }
        return t;
    }

    /// `out` (n samples) from `in` (n/2 coefficients):
    /// out[i] = sum in[k] cos(2pi/n (i + 1/2 + n/4)(k + 1/2)).
    pub fn inverse(t: *const Imdct, in: []const f32, out: []f32) void {
        const m = t.n / 2;
        const k = m / 2;
        const z = t.work;
        for (0..k) |i| z[t.rev[i]] = (C{ .re = in[2 * i], .im = in[m - 1 - 2 * i] }).mul(t.pre[i]);
        // Radix-2 decimation in time, in place.
        var size: usize = 2;
        while (size <= k) : (size *= 2) {
            const half = size / 2;
            const step = k / size;
            var start: usize = 0;
            while (start < k) : (start += size) {
                for (0..half) |j| {
                    const w = t.twiddle[j * step];
                    const b = z[start + j + half].mul(w);
                    const a = z[start + j];
                    z[start + j] = .{ .re = a.re + b.re, .im = a.im + b.im };
                    z[start + j + half] = .{ .re = a.re - b.re, .im = a.im - b.im };
                }
            }
        }
        // u (the DCT-IV) into out's middle, then unfolded by its symmetries.
        const u = out[0..m];
        for (0..k) |p| {
            const v = z[p].mul(t.post[p]);
            u[2 * p] = v.re;
            u[m - 1 - 2 * p] = -v.im;
        }
        // out[i] = u[i + m/2] for i < m/2; -u[3m/2 - 1 - i] up to 3m/2;
        // -u[i - 3m/2] after. Written from the end, so u is read first.
        const h = m / 2;
        var i: usize = t.n;
        while (i > 3 * h) {
            i -= 1;
            out[i] = -u[i - 3 * h];
        }
        // i in [h, 3h): needs u[3h-1-i] in [0, 2h): all of u, kept aside.
        var tmp: [4096]f32 = undefined;
        @memcpy(tmp[0..m], u);
        while (i > h) {
            i -= 1;
            out[i] = -tmp[3 * h - 1 - i];
        }
        while (i > 0) {
            i -= 1;
            out[i] = tmp[i + h];
        }
    }
};

test "Vorbis: the inverse MDCT matches its definition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    inline for (.{ 64, 256, 2048 }) |n| {
        const t = try Imdct.init(arena.allocator(), n);
        var in: [n / 2]f32 = undefined;
        var prng = std.Random.DefaultPrng.init(n);
        for (&in) |*x| x.* = prng.random().float(f32) * 2 - 1;
        var out: [n]f32 = undefined;
        t.inverse(&in, &out);
        for ([_]usize{ 0, 1, n / 4, n / 2 - 1, n / 2, 3 * n / 4 + 3, n - 1 }) |i| {
            var sum: f64 = 0;
            for (in, 0..) |x, kk| {
                const a = 2 * std.math.pi / @as(f64, n) * (@as(f64, @floatFromInt(i)) + 0.5 + n / 4.0) * (@as(f64, @floatFromInt(kk)) + 0.5);
                sum += x * @cos(a);
            }
            try std.testing.expectApproxEqAbs(@as(f32, @floatCast(sum)), out[i], 1e-3);
        }
    }
}
