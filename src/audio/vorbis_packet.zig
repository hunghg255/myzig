//! Decodes Vorbis audio packets: each channel's floor and residue, the
//! inverse coupling of channel pairs, the inverse MDCT, and the windowed
//! overlap with the previous block, whose halves meet at their centers.
const std = @import("std");
const setup = @import("vorbis_setup.zig");
const floor = @import("vorbis_floor.zig");
const Imdct = @import("vorbis_mdct.zig").Imdct;

const Bits = setup.Bits;

pub const Dsp = struct {
    s: *const setup.Setup,
    imdct: [2]Imdct,
    spectrum: [][]f32,
    floors: []floor.Decoded,
    no_residue: []bool,
    raw: []f32,
    /// Each channel's previous block's windowed right half.
    prev: [][]f32,
    /// The previous block's size, 0 when there is none (at the start, after a seek).
    prev_n: u32 = 0,
    interleaved: []f32,
    classes: []u32,

    pub fn init(a: std.mem.Allocator, s: *const setup.Setup) !Dsp {
        const ch: usize = s.channels;
        const half = s.blocksize[1] / 2;
        var d: Dsp = .{
            .s = s,
            .imdct = .{ try Imdct.init(a, s.blocksize[0]), try Imdct.init(a, s.blocksize[1]) },
            .spectrum = try a.alloc([]f32, ch),
            .floors = try a.alloc(floor.Decoded, ch),
            .no_residue = try a.alloc(bool, ch),
            .raw = try a.alloc(f32, s.blocksize[1]),
            .prev = try a.alloc([]f32, ch),
            .interleaved = try a.alloc(f32, half * ch),
            .classes = undefined,
        };
        for (d.spectrum, d.prev) |*x, *p| {
            x.* = try a.alloc(f32, half);
            p.* = try a.alloc(f32, half);
        }
        var most: usize = 0;
        for (s.residues) |r| {
            const size: usize = if (r.kind == 2) half * ch else half;
            const parts = @min(r.end, size) / r.partition_size;
            const vecs: usize = if (r.kind == 2) 1 else ch;
            most = @max(most, vecs * (parts + s.books[r.classbook].dims));
        }
        d.classes = try a.alloc(u32, most);
        return d;
    }

    /// Forgets the previous block: the next packet makes no sound (it only overlaps the one after).
    pub fn reset(d: *Dsp) void {
        d.prev_n = 0;
    }

    /// Decodes `packet` into `out` (interleaved, room for half a long
    /// block), returning the frames it finished: from the previous block's
    /// center to this one's.
    pub fn decode(d: *Dsp, packet: []const u8, out: []f32) usize {
        const s = d.s;
        var b: Bits = .{ .data = packet };
        if (b.flag()) return 0; // not audio
        const mode_n = b.read(setup.ilog(@intCast(s.modes.len - 1)));
        if (mode_n >= s.modes.len) return 0;
        const mode = s.modes[mode_n];
        const long = mode.blockflag;
        const n = s.blocksize[@intFromBool(long)];
        var prev_long = false;
        var next_long = false;
        if (long) {
            prev_long = b.flag();
            next_long = b.flag();
        }
        if (b.eop) return 0;
        const map = &s.mappings[mode.mapping];
        const half = n / 2;
        const ch = s.channels;
        for (0..ch) |c| {
            @memset(d.spectrum[c][0..half], 0);
            const f = &s.floors[map.submap_floor[map.mux[c]]];
            d.floors[c] = floor.decode(f, s.books, &b);
            d.no_residue[c] = d.floors[c] == .unused;
        }
        for (map.coupling_mag, map.coupling_ang) |m, a| if (!d.no_residue[m] or !d.no_residue[a]) {
            d.no_residue[m] = false;
            d.no_residue[a] = false;
        };
        var vecs: [256][]f32 = undefined;
        var dnd: [256]bool = undefined;
        for (0..map.submaps) |sm| {
            var count: usize = 0;
            for (0..ch) |c| if (map.mux[c] == sm) {
                vecs[count] = d.spectrum[c][0..half];
                dnd[count] = d.no_residue[c];
                count += 1;
            };
            d.residue(&s.residues[map.submap_residue[sm]], vecs[0..count], dnd[0..count], half, &b);
        }
        var step = map.coupling_mag.len;
        while (step > 0) {
            step -= 1;
            const mv = d.spectrum[map.coupling_mag[step]][0..half];
            const av = d.spectrum[map.coupling_ang[step]][0..half];
            for (mv, av) |*mp, *ap| {
                const m = mp.*;
                const a = ap.*;
                if (m > 0) {
                    if (a > 0) ap.* = m - a else {
                        ap.* = m;
                        mp.* = m + a;
                    }
                } else {
                    if (a > 0) ap.* = m + a else {
                        ap.* = m;
                        mp.* = m - a;
                    }
                }
            }
        }
        const pn = d.prev_n;
        const frames: usize = if (pn == 0) 0 else pn / 4 + n / 4;
        for (0..ch) |c| {
            const spec = d.spectrum[c][0..half];
            floor.apply(&s.floors[map.submap_floor[map.mux[c]]], &d.floors[c], spec);
            const raw = d.raw[0..n];
            d.imdct[@intFromBool(long)].inverse(spec, raw);
            d.window(raw, long, prev_long, next_long);
            // The previous right half meets this left half: their quarters
            // (3pn/4 and n/4) line up.
            const shift = @as(i64, n / 4) - @as(i64, pn / 4);
            for (0..frames) |i| {
                var v: f32 = if (i < pn / 2) d.prev[c][i] else 0;
                const ci = @as(i64, @intCast(i)) + shift;
                if (ci >= 0) v += raw[@intCast(ci)];
                out[i * ch + c] = v;
            }
            @memcpy(d.prev[c][0..half], raw[half..n]);
        }
        d.prev_n = n;
        return frames;
    }

    /// Vorbis's window: slopes as long as the neighbors' overlaps, zero beyond.
    fn window(d: *const Dsp, raw: []f32, long: bool, prev_long: bool, next_long: bool) void {
        const n = raw.len;
        const left = &d.imdct[@intFromBool(long and prev_long)];
        const right = &d.imdct[@intFromBool(long and next_long)];
        const ln = left.n / 2;
        const ls = n / 4 - ln / 2;
        @memset(raw[0..ls], 0);
        for (raw[ls..][0..ln], left.slope) |*x, w| x.* *= w;
        const rn = right.n / 2;
        const rs = 3 * n / 4 - rn / 2;
        for (raw[rs..][0..rn], 0..) |*x, i| x.* *= right.slope[rn - 1 - i];
        @memset(raw[rs + rn ..], 0);
    }

    /// Decodes a residue into the vectors of a submap's channels (those
    /// not to decode stay zero, but for type 2, which decodes all or none).
    fn residue(d: *Dsp, r: *const setup.Residue, vecs: [][]f32, dnd_in: []const bool, half: usize, b: *Bits) void {
        const books = d.s.books;
        var targets = vecs;
        var dnd = dnd_in;
        var n = half;
        var single: [1][]f32 = undefined;
        if (r.kind == 2) {
            for (dnd_in) |x| {
                if (!x) break;
            } else return;
            n = half * vecs.len;
            single[0] = d.interleaved[0..n];
            @memset(single[0], 0);
            targets = &single;
            dnd = &.{false};
        }
        defer if (r.kind == 2) {
            const chs = vecs.len;
            for (0..half) |i| for (0..chs) |c| {
                vecs[c][i] = single[0][i * chs + c];
            };
        };
        const begin = @min(r.begin, n);
        const end = @min(r.end, n);
        const classbook = &books[r.classbook];
        const cpc: usize = classbook.dims;
        if (end <= begin or cpc == 0) return;
        const psize = r.partition_size;
        const parts = (end - begin) / psize;
        const stride = parts + cpc;
        const cls = d.classes;
        const nclass: u32 = r.classifications;
        for (0..8) |pass| {
            var p: usize = 0;
            while (p < parts) {
                if (pass == 0) for (targets, 0..) |_, j| if (!dnd[j]) {
                    var temp = classbook.decode(b) orelse return;
                    var i = cpc;
                    while (i > 0) {
                        i -= 1;
                        cls[j * stride + i + p] = temp % nclass;
                        temp /= nclass;
                    }
                };
                var i: usize = 0;
                while (i < cpc and p < parts) : ({
                    i += 1;
                    p += 1;
                }) for (targets, 0..) |v, j| if (!dnd[j]) {
                    const book_n = r.books[cls[j * stride + p]][pass];
                    if (book_n < 0) continue;
                    const book = &books[@intCast(book_n)];
                    const off = begin + p * psize;
                    if (r.kind == 0) {
                        const st = psize / book.dims;
                        for (0..st) |k| {
                            const vec = book.vector(b) orelse return;
                            for (vec, 0..) |x, m| v[off + k + m * st] += x;
                        }
                    } else {
                        var q: usize = 0;
                        while (q < psize) {
                            const vec = book.vector(b) orelse return;
                            for (vec) |x| {
                                if (q < psize) v[off + q] += x;
                                q += 1;
                            }
                        }
                    }
                };
            }
        }
    }
};

/// The block size of an audio packet, from its mode, without decoding it.
pub fn blocksize(s: *const setup.Setup, packet: []const u8) ?u32 {
    var b: Bits = .{ .data = packet };
    if (b.flag()) return null;
    const m = b.read(setup.ilog(@intCast(s.modes.len - 1)));
    if (b.eop or m >= s.modes.len) return null;
    return s.blocksize[@intFromBool(s.modes[m].blockflag)];
}
