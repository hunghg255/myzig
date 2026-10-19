//! Layer III from frequency values to samples: stereo processing (mid/side
//! and intensity, MPEG-1's and MPEG-2's), short blocks' reordering, alias
//! reduction, the IMDCT with block switching and its overlap, frequency
//! inversion, and the polyphase synthesis filter bank.
const std = @import("std");
const frame = @import("mp3_frame.zig");
const tables = @import("mp3_tables.zig");
const Channel = @import("mp3_layer3.zig").Channel;

const Header = frame.Header;
const Granule = frame.Granule;

/// What carries over from frame to frame, and the transforms' tables.
pub const State = struct {
    overlap: [2][32][18]f32 = @splat(@splat(@splat(0))),
    v: [2][1024]f32 = @splat(@splat(0)),
    v_off: [2]usize = .{ 0, 0 },
    windows: [4][36]f32 = undefined,
    cos36: [18][36]f32 = undefined,
    cos12: [6][12]f32 = undefined,
    matrix: [64][32]f32 = undefined,

    pub fn init(s: *State) void {
        s.* = .{};
        const pi = std.math.pi;
        for (0..36) |i| {
            const fi: f64 = @floatFromInt(i);
            const long: f32 = @floatCast(@sin(pi / 36.0 * (fi + 0.5)));
            s.windows[0][i] = long;
            s.windows[1][i] = if (i < 18) long else if (i < 24) 1 else if (i < 30) @floatCast(@sin(pi / 12.0 * (fi - 18 + 0.5))) else 0;
            s.windows[2][i] = if (i < 12) @floatCast(@sin(pi / 12.0 * (fi + 0.5))) else 0;
            s.windows[3][i] = if (i < 6) 0 else if (i < 12) @floatCast(@sin(pi / 12.0 * (fi - 6 + 0.5))) else if (i < 18) 1 else long;
        }
        for (0..18) |m| for (0..36) |p| {
            s.cos36[m][p] = @floatCast(@cos(pi / 72.0 * @as(f64, @floatFromInt((2 * p + 1 + 18) * (2 * m + 1)))));
        };
        for (0..6) |m| for (0..12) |p| {
            s.cos12[m][p] = @floatCast(@cos(pi / 24.0 * @as(f64, @floatFromInt((2 * p + 1 + 6) * (2 * m + 1)))));
        };
        for (0..64) |i| for (0..32) |k| {
            s.matrix[i][k] = @floatCast(@cos(@as(f64, @floatFromInt((16 + i) * (2 * k + 1))) * (pi / 64.0)));
        };
    }

    /// Forgets the previous frames (after a seek).
    pub fn reset(s: *State) void {
        s.overlap = @splat(@splat(@splat(0)));
        s.v = @splat(@splat(0));
    }
};

const inv_sqrt2: f32 = std.math.sqrt1_2;

/// How a band's lines are processed: left alone, mid/side, or intensity
/// with these gains of the left channel.
const Op = union(enum) { none, ms, is: [2]f32 };

fn applyOp(op: Op, l: []f32, r: []f32) void {
    switch (op) {
        .none => {},
        .ms => for (l, r) |*a, *b| {
            const m = a.*;
            const s = b.*;
            a.* = (m + s) * inv_sqrt2;
            b.* = (m - s) * inv_sqrt2;
        },
        .is => |k| for (l, r) |*a, *b| {
            const v = a.*;
            a.* = v * k[0];
            b.* = v * k[1];
        },
    }
}

fn isGains(h: Header, right: *const Granule, pos: u32, max: u32) ?[2]f32 {
    if (!h.lsf()) {
        if (pos >= 7) return null;
        if (pos == 6) return .{ 1, 0 };
        const k: f32 = @floatCast(@tan(@as(f64, @floatFromInt(pos)) * std.math.pi / 12.0));
        return .{ k / (1 + k), 1 / (1 + k) };
    }
    if (pos == max) return null;
    const io: f32 = if (right.scalefac_compress & 1 != 0) inv_sqrt2 else 0.8408964; // 2^-1/4
    if (pos == 0) return .{ 1, 1 };
    if (pos & 1 != 0) return .{ std.math.pow(f32, io, @floatFromInt((pos + 1) / 2)), 1 };
    return .{ 1, std.math.pow(f32, io, @floatFromInt(pos / 2)) };
}

fn nonzero(x: []const f32) bool {
    for (x) |v| if (v != 0) return true;
    return false;
}

/// Joint stereo: mid/side and intensity, on both channels of a granule
/// (short blocks in their windows' order).
pub fn stereo(h: Header, grs: *const [2]Granule, chs: *[2]Channel) void {
    if (h.mode != 1 or h.channels() != 2) return;
    const ms = h.mode_ext & 2 != 0;
    const intensity = h.mode_ext & 1 != 0;
    const plain: Op = if (ms) .ms else .none;
    const l = &chs[0].xr;
    const r = &chs[1].xr;
    chs[0].nonzero = 576;
    chs[1].nonzero = 576;
    if (!intensity) {
        applyOp(plain, l, r);
        return;
    }
    const g = &grs[0];
    const rg = &grs[1];
    const right = &chs[1];
    const bands = &tables.bands[h.bandIndex()];
    var long_end: usize = 576;
    var short_from: usize = 13;
    if (g.short()) {
        long_end = if (g.mixed) 36 else 0;
        short_from = if (g.mixed) 3 else 0;
    }
    // Short windows: intensity above each window's last band with sound.
    var right_short = false;
    if (short_from < 13) for (0..3) |w| {
        var bound: usize = short_from;
        for (short_from..13) |s| {
            const width: usize = bands.short[s + 1] - bands.short[s];
            const from = @as(usize, bands.short[s]) * 3 + w * width;
            if (nonzero(r[from..][0..width])) bound = s + 1;
        }
        if (bound > short_from) right_short = true;
        var prev: [2]u32 = .{ 0, 0 };
        for (short_from..13) |s| {
            const width: usize = bands.short[s + 1] - bands.short[s];
            const from = @as(usize, bands.short[s]) * 3 + w * width;
            // The last band has no scale factor: the one before's.
            const pos: [2]u32 = if (s < 12) .{ right.sf_s[s][w], right.is_max_s[s] } else prev;
            prev = pos;
            const op: Op = if (s >= bound) (if (isGains(h, rg, pos[0], pos[1])) |k| .{ .is = k } else plain) else plain;
            applyOp(op, l[from..][0..width], r[from..][0..width]);
        }
    };
    // Long bands: intensity above the right channel's last line with sound.
    if (long_end > 0) {
        var last: usize = 0;
        var any = false;
        for (r[0..long_end], 0..) |v, i| if (v != 0) {
            last = i;
            any = true;
        };
        var prev: [2]u32 = .{ 0, 0 };
        var sfb: usize = 0;
        while (sfb < 22 and bands.long[sfb] < long_end) : (sfb += 1) {
            const from: usize = bands.long[sfb];
            const to: usize = @min(bands.long[sfb + 1], long_end);
            const pos: [2]u32 = if (sfb < 21) .{ right.sf_l[sfb], right.is_max_l[sfb] } else prev;
            prev = pos;
            const above = !right_short and (!any or from > last);
            const op: Op = if (above) (if (isGains(h, rg, pos[0], pos[1])) |k| .{ .is = k } else plain) else plain;
            applyOp(op, l[from..to], r[from..to]);
        }
    }
}

const cs = blk: {
    const c = [8]f64{ -0.6, -0.535, -0.33, -0.185, -0.095, -0.041, -0.0142, -0.0037 };
    var t: [2][8]f32 = undefined;
    for (c, 0..) |x, i| {
        const d = @sqrt(1 + x * x);
        t[0][i] = @floatCast(1 / d);
        t[1][i] = @floatCast(x / d);
    }
    break :blk t;
};

/// From a channel's frequency values to its 576 samples, into `out`
/// (interleaved by `stride`).
pub fn synthesize(st: *State, h: Header, g: *const Granule, ch: *Channel, c: usize, out: []f32, stride: usize) void {
    const x = &ch.xr;
    const bands = &tables.bands[h.bandIndex()];
    if (g.short()) {
        // Reorder: each band's three windows interleaved, line by line.
        var tmp: [576]f32 = undefined;
        var s: usize = if (g.mixed) 3 else 0;
        while (s < 13) : (s += 1) {
            const width: usize = bands.short[s + 1] - bands.short[s];
            const base = @as(usize, bands.short[s]) * 3;
            for (0..3) |w| for (0..width) |j| {
                tmp[j * 3 + w] = x[base + w * width + j];
            };
            @memcpy(x[base..][0 .. 3 * width], tmp[0 .. 3 * width]);
        }
    }
    const sblim: usize = if (!g.short()) 32 else if (g.mixed) 2 else 0;
    if (sblim > 0) for (1..sblim) |sb| for (0..8) |i| {
        const li = 18 * sb - 1 - i;
        const ui = 18 * sb + i;
        const lb = x[li] * cs[0][i] - x[ui] * cs[1][i];
        const ub = x[ui] * cs[0][i] + x[li] * cs[1][i];
        x[li] = lb;
        x[ui] = ub;
    };
    for (0..32) |sb| {
        const bt: usize = if (g.window_switching and !(g.mixed and sb < 2)) g.block_type else 0;
        const in = x[sb * 18 ..][0..18];
        var raw: [36]f32 = @splat(0);
        if (bt == 2) {
            for (0..3) |w| for (0..12) |p| {
                var sum: f32 = 0;
                for (0..6) |m| sum += in[w + 3 * m] * st.cos12[m][p];
                raw[6 * w + p + 6] += sum * st.windows[2][p];
            };
        } else {
            for (0..36) |p| {
                var sum: f32 = 0;
                for (0..18) |m| sum += in[m] * st.cos36[m][p];
                raw[p] = sum * st.windows[bt][p];
            }
        }
        const ov = &st.overlap[c][sb];
        for (0..18) |i| {
            in[i] = raw[i] + ov[i];
            ov[i] = raw[i + 18];
        }
        // Frequency inversion: odd subbands' odd samples.
        if (sb & 1 == 1) {
            var i: usize = 1;
            while (i < 18) : (i += 2) in[i] = -in[i];
        }
    }
    const v = &st.v[c];
    for (0..18) |t| {
        st.v_off[c] = (st.v_off[c] + 1024 - 64) & 1023;
        const off = st.v_off[c];
        var s: [32]f32 = undefined;
        for (&s, 0..) |*y, k| y.* = x[k * 18 + t];
        for (0..64) |i| {
            var sum: f32 = 0;
            for (st.matrix[i], s) |m, y| sum += m * y;
            v[(off + i) & 1023] = sum;
        }
        for (0..32) |j| {
            var sum: f32 = 0;
            for (0..8) |i| {
                sum += v[(off + 128 * i + j) & 1023] * tables.synth_window[64 * i + j];
                sum += v[(off + 128 * i + 96 + j) & 1023] * tables.synth_window[64 * i + 32 + j];
            }
            out[(t * 32 + j) * stride] = sum;
        }
    }
}
