//! Vorbis's floors: the spectral envelope each channel's residue is
//! multiplied by. Floor 1 (what encoders write): a piecewise linear curve
//! in dB through points decoded per packet. Floor 0 (old files): an LSP
//! curve over the Bark scale.
const std = @import("std");
const setup = @import("vorbis_setup.zig");

const Bits = setup.Bits;

/// A channel's decoded floor, before it is drawn.
pub const Decoded = union(enum) {
    unused,
    one: [65]i32,
    zero: struct { amplitude: u32, coefficients: [256]f32 },
};

pub fn decode(f: *const setup.Floor, books: []const setup.Codebook, b: *Bits) Decoded {
    return switch (f.*) {
        .one => |*f1| decode1(f1, books, b),
        .zero => |*f0| decode0(f0, books, b),
    };
}

const ranges = [4]i32{ 256, 128, 86, 64 };

fn decode1(f: *const setup.Floor1, books: []const setup.Codebook, b: *Bits) Decoded {
    if (!b.flag()) return .unused;
    var y: [65]i32 = undefined;
    const range = ranges[f.multiplier - 1];
    const bits = setup.ilog(@intCast(range - 1));
    y[0] = @intCast(b.read(bits));
    y[1] = @intCast(b.read(bits));
    var at: usize = 2;
    for (f.partition_class) |c| {
        const cdim = f.class_dims[c];
        const cbits = f.class_subs[c];
        const csub = (@as(u32, 1) << cbits) - 1;
        var cval: u32 = 0;
        if (cbits > 0) cval = books[f.class_master[c]].decode(b) orelse return .unused;
        for (0..cdim) |_| {
            const book = f.sub_books[c][cval & csub];
            cval >>= cbits;
            y[at] = if (book >= 0) @intCast(books[@intCast(book)].decode(b) orelse return .unused) else 0;
            at += 1;
        }
    }
    if (b.eop) return .unused;
    return .{ .one = y };
}

fn renderPoint(x0: i32, y0: i32, x1: i32, y1: i32, x: i32) i32 {
    const dy = y1 - y0;
    const adx = x1 - x0;
    const off = @divTrunc(@as(i32, @intCast(@abs(dy))) * (x - x0), adx);
    return if (dy < 0) y0 - off else y0 + off;
}

/// Multiplies v[x0..x1) by the line's dB values (clipped to v).
fn renderLine(x0: i32, y0: i32, x1: i32, y1: i32, v: []f32) void {
    const dy = y1 - y0;
    const adx = x1 - x0;
    var ady: i32 = @intCast(@abs(dy));
    const base = @divTrunc(dy, adx);
    const sy = if (dy < 0) base - 1 else base + 1;
    ady -= @as(i32, @intCast(@abs(base))) * adx;
    var y = y0;
    var err: i32 = 0;
    const n: i32 = @intCast(v.len);
    if (x0 >= n) return;
    v[@intCast(x0)] *= inverse_db[@intCast(std.math.clamp(y, 0, 255))];
    var x = x0 + 1;
    while (x < x1 and x < n) : (x += 1) {
        err += ady;
        if (err >= adx) {
            err -= adx;
            y += sy;
        } else y += base;
        v[@intCast(x)] *= inverse_db[@intCast(std.math.clamp(y, 0, 255))];
    }
}

/// Multiplies a channel's spectrum `v` (n/2 values) by its floor.
pub fn apply(f: *const setup.Floor, d: *const Decoded, v: []f32) void {
    switch (d.*) {
        .unused => @memset(v, 0),
        .one => |*y| apply1(&f.one, y, v),
        .zero => |*z| apply0(&f.zero, z.amplitude, &z.coefficients, v),
    }
}

fn apply1(f: *const setup.Floor1, y: *const [65]i32, v: []f32) void {
    const range = ranges[f.multiplier - 1];
    const count = f.xs.len;
    var step2: [65]bool = undefined;
    var final: [65]i32 = undefined;
    step2[0] = true;
    step2[1] = true;
    final[0] = y[0];
    final[1] = y[1];
    for (2..count) |i| {
        const lo = f.low[i];
        const hi = f.high[i];
        const predicted = renderPoint(f.xs[lo], final[lo], f.xs[hi], final[hi], f.xs[i]);
        const val = y[i];
        const high_room = range - predicted;
        const low_room = predicted;
        const room = @min(high_room, low_room) * 2;
        if (val != 0) {
            step2[lo] = true;
            step2[hi] = true;
            step2[i] = true;
            final[i] = if (val >= room)
                (if (high_room > low_room) val - low_room + predicted else predicted - val + high_room - 1)
            else if (val & 1 != 0) predicted - @divTrunc(val + 1, 2) else predicted + @divTrunc(val, 2);
        } else {
            step2[i] = false;
            final[i] = predicted;
        }
        final[i] = std.math.clamp(final[i], 0, range - 1);
    }
    const mult: i32 = f.multiplier;
    var lx: i32 = 0;
    var ly: i32 = final[0] * mult;
    for (f.sorted[1..]) |i| if (step2[i]) {
        const hx: i32 = f.xs[i];
        const hy = final[i] * mult;
        if (hx > lx) renderLine(lx, ly, hx, hy, v);
        lx = hx;
        ly = hy;
    };
    const n: i32 = @intCast(v.len);
    if (lx < n) {
        const g = inverse_db[@intCast(std.math.clamp(ly, 0, 255))];
        for (v[@intCast(lx)..]) |*x| x.* *= g;
    }
}

fn decode0(f: *const setup.Floor0, books: []const setup.Codebook, b: *Bits) Decoded {
    const amplitude = b.read(f.amplitude_bits);
    if (amplitude == 0 or b.eop) return .unused;
    const which = b.read(setup.ilog(@intCast(f.books.len)));
    if (which >= f.books.len) return .unused;
    const book = &books[f.books[which]];
    if (book.values.len == 0) return .unused;
    var out: Decoded = .{ .zero = .{ .amplitude = amplitude, .coefficients = undefined } };
    var i: usize = 0;
    var last: f32 = 0;
    while (i < f.order) {
        const vec = book.vector(b) orelse return .unused;
        for (vec) |c| {
            if (i < f.order) out.zero.coefficients[i] = c + last;
            i += 1;
        }
        last = vec[vec.len - 1] + last;
    }
    return out;
}

fn bark(x: f64) f64 {
    return 13.1 * std.math.atan(0.00074 * x) + 2.24 * std.math.atan(0.0000000185 * x * x) + 0.0001 * x;
}

fn apply0(f: *const setup.Floor0, amplitude: u32, coeffs: []const f32, v: []f32) void {
    const n = v.len;
    const order: usize = f.order;
    const rate: f64 = @floatFromInt(f.rate);
    const size: f64 = @floatFromInt(f.bark_map_size);
    const map = struct {
        fn at(i: usize, nn: usize, r: f64, s: f64, max: u16) i32 {
            const x = bark(r * @as(f64, @floatFromInt(i)) / (2 * @as(f64, @floatFromInt(nn)))) * s / bark(0.5 * r);
            return @min(@as(i32, @intFromFloat(@floor(x))), @as(i32, max) - 1);
        }
    };
    var cos_c: [256]f64 = undefined;
    for (coeffs[0..order], 0..) |c, j| cos_c[j] = @cos(@as(f64, c));
    const amp_scale: f64 = @floatFromInt((@as(u64, 1) << f.amplitude_bits) - 1);
    var i: usize = 0;
    while (i < n) {
        const m = map.at(i, n, rate, size, f.bark_map_size);
        const w = std.math.pi * @as(f64, @floatFromInt(m)) / size;
        const cw = @cos(w);
        var p: f64 = undefined;
        var q: f64 = undefined;
        if (order % 2 == 1) {
            p = 1 - cw * cw;
            q = 0.25;
        } else {
            p = (1 - cw) / 2;
            q = (1 + cw) / 2;
        }
        var j: usize = 0;
        while (2 * j + 1 < order) : (j += 1) p *= 4 * (cos_c[2 * j + 1] - cw) * (cos_c[2 * j + 1] - cw);
        j = 0;
        while (2 * j < order) : (j += 1) q *= 4 * (cos_c[2 * j] - cw) * (cos_c[2 * j] - cw);
        const amp: f64 = @floatFromInt(amplitude);
        const off: f64 = @floatFromInt(f.amplitude_offset);
        const g: f32 = @floatCast(@exp(0.11512925 * (amp * off / (amp_scale * @sqrt(p + q)) - off)));
        while (i < n and map.at(i, n, rate, size, f.bark_map_size) == m) : (i += 1) v[i] *= g;
    }
}

/// Floor 1's dB scale, from -140 dB to 0 (the specification's table).
pub const inverse_db = [256]f32{
    1.0649863e-07, 1.1341951e-07, 1.2079015e-07, 1.2863978e-07, 1.3699951e-07, 1.4590251e-07, 1.5538408e-07, 1.6548181e-07,
    1.7623575e-07, 1.8768855e-07, 1.9988561e-07, 2.1287530e-07, 2.2670913e-07, 2.4144197e-07, 2.5713223e-07, 2.7384213e-07,
    2.9163793e-07, 3.1059021e-07, 3.3077411e-07, 3.5226968e-07, 3.7516214e-07, 3.9954229e-07, 4.2550680e-07, 4.5315863e-07,
    4.8260743e-07, 5.1396998e-07, 5.4737065e-07, 5.8294187e-07, 6.2082472e-07, 6.6116941e-07, 7.0413592e-07, 7.4989464e-07,
    7.9862701e-07, 8.5052630e-07, 9.0579828e-07, 9.6466216e-07, 1.0273513e-06, 1.0941144e-06, 1.1652161e-06, 1.2409384e-06,
    1.3215816e-06, 1.4074654e-06, 1.4989305e-06, 1.5963394e-06, 1.7000785e-06, 1.8105592e-06, 1.9282195e-06, 2.0535261e-06,
    2.1869758e-06, 2.3290978e-06, 2.4804557e-06, 2.6416497e-06, 2.8133190e-06, 2.9961443e-06, 3.1908506e-06, 3.3982101e-06,
    3.6190449e-06, 3.8542308e-06, 4.1047004e-06, 4.3714470e-06, 4.6555282e-06, 4.9580707e-06, 5.2802740e-06, 5.6234160e-06,
    5.9888572e-06, 6.3780469e-06, 6.7925283e-06, 7.2339451e-06, 7.7040476e-06, 8.2047000e-06, 8.7378876e-06, 9.3057248e-06,
    9.9104632e-06, 1.0554501e-05, 1.1240392e-05, 1.1970856e-05, 1.2748789e-05, 1.3577278e-05, 1.4459606e-05, 1.5399272e-05,
    1.6400004e-05, 1.7465768e-05, 1.8600792e-05, 1.9809576e-05, 2.1096914e-05, 2.2467911e-05, 2.3928002e-05, 2.5482978e-05,
    2.7139006e-05, 2.8902651e-05, 3.0780908e-05, 3.2781225e-05, 3.4911534e-05, 3.7180282e-05, 3.9596466e-05, 4.2169667e-05,
    4.4910090e-05, 4.7828601e-05, 5.0936773e-05, 5.4246931e-05, 5.7772202e-05, 6.1526565e-05, 6.5524908e-05, 6.9783085e-05,
    7.4317983e-05, 7.9147585e-05, 8.4291040e-05, 8.9768747e-05, 9.5602426e-05, 0.00010181521, 0.00010843174, 0.00011547824,
    0.00012298267, 0.00013097477, 0.00013948625, 0.00014855085, 0.00015820453, 0.00016848555, 0.00017943469, 0.00019109536,
    0.00020351382, 0.00021673929, 0.00023082423, 0.00024582449, 0.00026179955, 0.00027881276, 0.00029693158, 0.00031622787,
    0.00033677814, 0.00035866388, 0.00038197188, 0.00040679456, 0.00043323036, 0.00046138411, 0.00049136745, 0.00052329927,
    0.00055730621, 0.00059352311, 0.00063209358, 0.00067317058, 0.00071691700, 0.00076350630, 0.00081312324, 0.00086596457,
    0.00092223983, 0.00098217216, 0.0010459992, 0.0011139742, 0.0011863665, 0.0012634633, 0.0013455702, 0.0014330129,
    0.0015261382, 0.0016253153, 0.0017309374, 0.0018434235, 0.0019632195, 0.0020908006, 0.0022266726, 0.0023713743,
    0.0025254795, 0.0026895994, 0.0028643847, 0.0030505286, 0.0032487691, 0.0034598925, 0.0036847358, 0.0039241906,
    0.0041792066, 0.0044507950, 0.0047400328, 0.0050480668, 0.0053761186, 0.0057254891, 0.0060975636, 0.0064938176,
    0.0069158225, 0.0073652516, 0.0078438871, 0.0083536271, 0.0088964928, 0.009474637, 0.010090352, 0.010746080,
    0.011444421, 0.012188144, 0.012980198, 0.013823725, 0.014722068, 0.015678791, 0.016697687, 0.017782797,
    0.018938423, 0.020169149, 0.021479854, 0.022875735, 0.024362330, 0.025945531, 0.027631618, 0.029427276,
    0.031339626, 0.033376252, 0.035545228, 0.037855157, 0.040315199, 0.042935108, 0.045725273, 0.048696758,
    0.051861348, 0.055231591, 0.058820850, 0.062643361, 0.066714279, 0.071049749, 0.075666962, 0.080584227,
    0.085821044, 0.091398179, 0.097337747, 0.10366330, 0.11039993, 0.11757434, 0.12521498, 0.13335215,
    0.14201813, 0.15124727, 0.16107617, 0.17154380, 0.18269168, 0.19456402, 0.20720788, 0.22067342,
    0.23501402, 0.25028656, 0.26655159, 0.28387361, 0.30232132, 0.32196786, 0.34289114, 0.36517414,
    0.38890521, 0.41417847, 0.44109412, 0.46975890, 0.50028648, 0.53279791, 0.56742212, 0.60429640,
    0.64356699, 0.68538959, 0.72993007, 0.77736504, 0.82788260, 0.88168307, 0.9389798, 1.0,
};
