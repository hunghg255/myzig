//! Layer III's main data: each granule and channel's scale factors (MPEG-1's
//! and MPEG-2's), its Huffman coded frequency lines, and their
//! requantization into frequency values.
const std = @import("std");
const frame = @import("mp3_frame.zig");
const tables = @import("mp3_tables.zig");

const Bits = frame.Bits;
const Header = frame.Header;
const Granule = frame.Granule;

/// A granule's channel, decoded to frequency values (before stereo
/// processing, short blocks still in their windows' order).
pub const Channel = struct {
    xr: [576]f32 = @splat(0),
    /// The lines from here on are zero.
    nonzero: usize = 0,
    sf_l: [22]u8 = @splat(0),
    sf_s: [13][3]u8 = @splat(@splat(0)),
    /// MPEG-2 intensity stereo: each band's illegal position (its scale
    /// factor's largest value), meaning "not intensity coded".
    is_max_l: [22]u8 = @splat(0),
    is_max_s: [13]u8 = @splat(0),
};

/// Decodes the main data of a frame: `main` starts where its first granule does.
pub fn decodeMain(h: Header, si: *frame.SideInfo, main: []const u8, out: *[2][2]Channel) void {
    var b: Bits = .{ .data = main };
    const bands = &tables.bands[h.bandIndex()];
    for (0..h.granules()) |gi| for (0..h.channels()) |c| {
        const g = &si.gr[gi][c];
        const ch = &out[gi][c];
        const start = b.pos;
        if (h.lsf()) {
            lsfScalefactors(h, g, c, &b, ch);
        } else {
            const prev: ?*const Channel = if (gi == 1) &out[0][c] else null;
            scalefactors(g, si.scfsi[c], prev, &b, ch);
        }
        var is: [576]i32 = undefined;
        const end = start + g.part23;
        ch.nonzero = huffman(g, bands, &b, end, &is);
        requantize(g, bands, ch, &is);
        b.pos = end;
    };
}

fn scalefactors(g: *const Granule, scfsi: [4]bool, prev: ?*const Channel, b: *Bits, ch: *Channel) void {
    const s1: u5 = @intCast(tables.slen[g.scalefac_compress][0]);
    const s2: u5 = @intCast(tables.slen[g.scalefac_compress][1]);
    ch.sf_l = @splat(0);
    ch.sf_s = @splat(@splat(0));
    if (g.short()) {
        var sfb: usize = 0;
        if (g.mixed) {
            for (0..8) |i| ch.sf_l[i] = @intCast(b.read(s1));
            sfb = 3;
        }
        while (sfb < 12) : (sfb += 1) for (0..3) |w| {
            ch.sf_s[sfb][w] = @intCast(b.read(if (sfb < 6) s1 else s2));
        };
        return;
    }
    const parts = [5]usize{ 0, 6, 11, 16, 21 };
    for (0..4) |p| {
        const n: u5 = if (p < 2) s1 else s2;
        for (parts[p]..parts[p + 1]) |sfb| ch.sf_l[sfb] = if (scfsi[p] and prev != null) prev.?.sf_l[sfb] else @intCast(b.read(n));
    }
}

fn lsfScalefactors(h: Header, g: *Granule, c: usize, b: *Bits, ch: *Channel) void {
    var sc = g.scalefac_compress;
    var slen: [4]u32 = .{ 0, 0, 0, 0 };
    var table: usize = 0;
    const intensity = c == 1 and h.mode == 1 and h.mode_ext & 1 != 0;
    var preflag = false;
    if (intensity) {
        sc >>= 1;
        if (sc < 180) {
            slen = .{ sc / 36, (sc % 36) / 6, sc % 6, 0 };
            table = 3;
        } else if (sc < 244) {
            const x = sc - 180;
            slen = .{ (x % 64) >> 4, (x % 16) >> 2, x % 4, 0 };
            table = 4;
        } else {
            const x = sc - 244;
            slen = .{ x / 3, x % 3, 0, 0 };
            table = 5;
        }
    } else if (sc < 400) {
        slen = .{ (sc >> 4) / 5, (sc >> 4) % 5, (sc % 16) >> 2, sc % 4 };
    } else if (sc < 500) {
        const x = sc - 400;
        slen = .{ (x >> 2) / 5, (x >> 2) % 5, x % 4, 0 };
        table = 1;
    } else {
        const x = sc - 500;
        slen = .{ x / 3, x % 3, 0, 0 };
        table = 2;
        preflag = true;
    }
    // The decoder's own preflag: MPEG-2 has none in its side information.
    g.preflag = preflag;
    const block: usize = if (!g.short()) 0 else if (g.mixed) 2 else 1;
    var sf: [39]u8 = @splat(0);
    var max: [39]u8 = @splat(0);
    var n: usize = 0;
    for (0..4) |p| for (0..tables.lsf_counts[table][block][p]) |_| {
        sf[n] = @intCast(b.read(@intCast(slen[p])));
        max[n] = @intCast((@as(u32, 1) << @intCast(slen[p])) - 1);
        n += 1;
    };
    ch.sf_l = @splat(0);
    ch.sf_s = @splat(@splat(0));
    ch.is_max_l = @splat(0);
    ch.is_max_s = @splat(0);
    var k: usize = 0;
    if (block == 0) {
        for (0..21) |i| {
            ch.sf_l[i] = sf[i];
            ch.is_max_l[i] = max[i];
        }
        return;
    }
    var sfb: usize = 0;
    if (block == 2) {
        for (0..6) |i| {
            ch.sf_l[i] = sf[i];
            ch.is_max_l[i] = max[i];
        }
        k = 6;
        sfb = 3;
    }
    while (sfb < 12) : (sfb += 1) {
        for (0..3) |w| ch.sf_s[sfb][w] = sf[k + w];
        ch.is_max_s[sfb] = max[k];
        k += 3;
    }
}

/// Decodes one pair (or quadruple, tables 32 and 33) of values.
fn decodePair(table: usize, b: *Bits, out: []i32) bool {
    const t = tables.huffman_tables[table];
    if (t.len == 0) {
        @memset(out, 0);
        return true;
    }
    const tree = tables.huffman_tree[t.offset..];
    var point: usize = 0;
    var steps: usize = 0;
    while (tree[point] & 0xff00 != 0) : (steps += 1) {
        if (steps > 32) return false;
        if (b.read(1) == 1) {
            while (tree[point] & 0xff >= 250) point += tree[point] & 0xff;
            point += tree[point] & 0xff;
        } else {
            while (tree[point] >> 8 >= 250) point += tree[point] >> 8;
            point += tree[point] >> 8;
        }
        if (point >= t.len) return false;
    }
    var x: i32 = (tree[point] >> 4) & 15;
    var y: i32 = tree[point] & 15;
    if (table >= 32) {
        const vals = [4]i32{ (y >> 3) & 1, (y >> 2) & 1, (y >> 1) & 1, y & 1 };
        for (vals, 0..) |v, i| out[i] = if (v != 0 and b.read(1) == 1) -v else v;
        return true;
    }
    if (t.linbits > 0 and x == 15) x += @intCast(b.read(t.linbits));
    if (x != 0 and b.read(1) == 1) x = -x;
    if (t.linbits > 0 and y == 15) y += @intCast(b.read(t.linbits));
    if (y != 0 and b.read(1) == 1) y = -y;
    out[0] = x;
    out[1] = y;
    return true;
}

/// Decodes the Huffman coded lines up to bit `end`; returns where the zeros start.
fn huffman(g: *const Granule, bands: *const tables.Bands, b: *Bits, end: usize, is: *[576]i32) usize {
    var r1: usize = undefined;
    var r2: usize = undefined;
    if (g.window_switching) {
        r1 = if (g.block_type == 2) @as(usize, bands.short[3]) * 3 else bands.long[8];
        r2 = 576;
    } else {
        r1 = bands.long[@min(g.region0 + 1, 22)];
        r2 = bands.long[@min(g.region0 + g.region1 + 2, 22)];
    }
    const big = @min(g.big_values * 2, 576);
    var i: usize = 0;
    while (i < big) : (i += 2) {
        const t: usize = if (i < r1) g.table_select[0] else if (i < r2) g.table_select[1] else g.table_select[2];
        if (!decodePair(t, b, is[i..][0..2])) break;
    }
    // The count1 region: quadruples of -1, 0 and 1.
    while (i + 4 <= 576 and b.pos < end) {
        var q: [4]i32 = undefined;
        if (!decodePair(32 + @as(usize, g.count1table), b, &q)) break;
        if (b.pos > end) break; // the last one overran: it isn't data
        @memcpy(is[i..][0..4], &q);
        i += 4;
    }
    @memset(is[i..], 0);
    return i;
}

fn pow43(x: i32) f32 {
    const a: f32 = @floatFromInt(@abs(x));
    const v = if (a < 2) a else std.math.pow(f32, a, 4.0 / 3.0);
    return if (x < 0) -v else v;
}

fn requantize(g: *const Granule, bands: *const tables.Bands, ch: *Channel, is: *const [576]i32) void {
    const gain = @as(f32, @floatFromInt(@as(i32, @intCast(g.global_gain)) - 210)) * 0.25;
    const mult: f32 = if (g.scalefac_scale) 1 else 0.5;
    @memset(&ch.xr, 0);
    const n = ch.nonzero;
    var i: usize = 0;
    var sfb: usize = 0;
    // Long bands: all of them, or a mixed block's first two subbands.
    const long_end: usize = if (!g.short()) 576 else if (g.mixed) 36 else 0;
    while (i < @min(long_end, n)) {
        while (i >= bands.long[sfb + 1]) sfb += 1;
        const pre: f32 = if (g.preflag) @floatFromInt(tables.pretab[sfb]) else 0;
        const sf: f32 = @floatFromInt(ch.sf_l[sfb]);
        const scale = std.math.exp2(gain - mult * (sf + pre));
        const stop = @min(bands.long[sfb + 1], long_end, n);
        while (i < stop) : (i += 1) ch.xr[i] = pow43(is[i]) * scale;
    }
    if (long_end == 576) return;
    // Short bands: each band's three windows one after another.
    var s: usize = if (g.mixed) 3 else 0;
    while (s < 13 and @as(usize, bands.short[s]) * 3 < n) : (s += 1) {
        const width: usize = bands.short[s + 1] - bands.short[s];
        const base: usize = @as(usize, bands.short[s]) * 3;
        for (0..3) |w| {
            const sf: f32 = if (s < 12) @floatFromInt(ch.sf_s[s][w]) else 0;
            const sub: f32 = @floatFromInt(@as(u32, g.subblock_gain[w]) * 8);
            const scale = std.math.exp2(gain - sub * 0.25 - mult * sf);
            const from = base + w * width;
            const stop = @min(from + width, n);
            if (from < stop) for (from..stop) |k| {
                ch.xr[k] = pow43(is[k]) * scale;
            };
        }
    }
}
