//! Vorbis's headers: the identification header (rate, channels, block
//! sizes), and the setup header: codebooks (Huffman codes with vectors),
//! floors (types 0 and 1), residues (types 0, 1 and 2), mappings and modes,
//! allocated in one arena freed with the decoder.
const std = @import("std");

pub const Error = error{ InvalidVorbis, UnsupportedVorbis };

/// Reads a packet's bits, least significant first. Past the end it reads
/// zeros and sets `eop`, which decoding treats as the packet's end.
pub const Bits = struct {
    data: []const u8,
    pos: usize = 0,
    eop: bool = false,

    pub fn read(b: *Bits, n: u6) u32 {
        if (n == 0) return 0;
        if (b.pos + n > b.data.len * 8) {
            b.eop = true;
            b.pos = b.data.len * 8;
            return 0;
        }
        const at = b.pos >> 3;
        var w: u64 = 0;
        const take = @min(b.data.len - at, 8);
        for (b.data[at..][0..take], 0..) |x, i| w |= @as(u64, x) << @intCast(i * 8);
        b.pos += n;
        const v = w >> @intCast(b.pos - n - at * 8);
        return @truncate(v & ((@as(u64, 1) << n) - 1));
    }

    pub fn flag(b: *Bits) bool {
        return b.read(1) == 1;
    }
};

pub fn ilog(x: u32) u6 {
    return @intCast(32 - @clz(x));
}

/// A codebook: a Huffman code of entries, and the vectors entries stand
/// for when the book has a lookup table.
pub const Codebook = struct {
    dims: u16,
    entries: u32,
    /// Nodes' two children: >= 0 another node, < 0 the entry -(e + 1),
    /// `missing` none (a code the book leaves unused).
    tree: [][2]i32,
    /// `entries * dims` values, or empty (scalar books).
    values: []f32,

    const missing: i32 = std.math.minInt(i32);

    /// An entry's number, or null at the packet's end or on a bad code.
    pub fn decode(c: *const Codebook, b: *Bits) ?u32 {
        if (c.tree.len == 0) return null;
        var node: i32 = 0;
        while (true) {
            const bit = b.read(1);
            if (b.eop) return null;
            node = c.tree[@intCast(node)][bit];
            if (node == missing) return null;
            if (node < 0) return @intCast(-(node + 1));
        }
    }

    /// An entry's vector.
    pub fn vector(c: *const Codebook, b: *Bits) ?[]const f32 {
        const e = c.decode(b) orelse return null;
        return c.values[e * c.dims ..][0..c.dims];
    }
};

pub const Floor0 = struct {
    order: u8,
    rate: u16,
    bark_map_size: u16,
    amplitude_bits: u6,
    amplitude_offset: u8,
    books: []u8,
};

pub const Floor1 = struct {
    partition_class: []u8,
    class_dims: [16]u8,
    class_subs: [16]u3,
    class_master: [16]u8,
    /// Per class, 8 books (-1: none).
    sub_books: [16][8]i16,
    multiplier: u8,
    /// Its X list (at most 65), sorted order and neighbors.
    xs: []u16,
    sorted: []u8,
    low: []u8,
    high: []u8,
};

pub const Floor = union(enum) { zero: Floor0, one: Floor1 };

pub const Residue = struct {
    kind: u2,
    begin: u32,
    end: u32,
    partition_size: u32,
    classifications: u8,
    classbook: u8,
    /// Per class and pass: a book, or -1.
    books: [][8]i16,
};

pub const Mapping = struct {
    submaps: u8,
    coupling_mag: []u8,
    coupling_ang: []u8,
    mux: []u8,
    submap_floor: [16]u8,
    submap_residue: [16]u8,
};

pub const Mode = struct { blockflag: bool, mapping: u8 };

pub const Setup = struct {
    rate: u32,
    channels: u16,
    blocksize: [2]u32,
    books: []Codebook = &.{},
    floors: []Floor = &.{},
    residues: []Residue = &.{},
    mappings: []Mapping = &.{},
    modes: []Mode = &.{},
};

fn isHeader(p: []const u8, kind: u8) bool {
    return p.len > 7 and p[0] == kind and std.mem.eql(u8, p[1..7], "vorbis");
}

/// Reads the identification header (packet 1).
pub fn readIdentification(p: []const u8) !Setup {
    if (!isHeader(p, 1) or p.len < 30) return error.InvalidVorbis;
    const h = p[7..];
    if (std.mem.readInt(u32, h[0..4], .little) != 0) return error.UnsupportedVorbis;
    const channels = h[4];
    const rate = std.mem.readInt(u32, h[5..9], .little);
    const b0 = h[21] & 15;
    const b1 = h[21] >> 4;
    if (channels == 0 or rate == 0 or b0 < 6 or b1 > 13 or b0 > b1 or h[22] & 1 == 0) return error.InvalidVorbis;
    return .{ .rate = rate, .channels = channels, .blocksize = .{ @as(u32, 1) << @intCast(b0), @as(u32, 1) << @intCast(b1) } };
}

pub fn isComment(p: []const u8) bool {
    return isHeader(p, 3);
}

/// Reads the setup header (packet 3) into `s`, allocating in `a` (an arena).
pub fn readSetup(a: std.mem.Allocator, s: *Setup, p: []const u8) !void {
    if (!isHeader(p, 5)) return error.InvalidVorbis;
    var b: Bits = .{ .data = p[7..] };
    s.books = try a.alloc(Codebook, b.read(8) + 1);
    for (s.books) |*c| c.* = try readCodebook(a, &b);
    const times = b.read(6) + 1;
    for (0..times) |_| if (b.read(16) != 0) return error.InvalidVorbis;
    s.floors = try a.alloc(Floor, b.read(6) + 1);
    for (s.floors) |*f| f.* = switch (b.read(16)) {
        0 => .{ .zero = try readFloor0(a, &b, s.books.len) },
        1 => .{ .one = try readFloor1(a, &b, s.books.len) },
        else => return error.InvalidVorbis,
    };
    s.residues = try a.alloc(Residue, b.read(6) + 1);
    for (s.residues) |*r| r.* = try readResidue(a, &b, s.books);
    s.mappings = try a.alloc(Mapping, b.read(6) + 1);
    for (s.mappings) |*m| m.* = try readMapping(a, &b, s.channels, s.floors.len, s.residues.len);
    s.modes = try a.alloc(Mode, b.read(6) + 1);
    for (s.modes) |*m| {
        m.blockflag = b.flag();
        if (b.read(16) != 0 or b.read(16) != 0) return error.InvalidVorbis;
        const mapping = b.read(8);
        if (mapping >= s.mappings.len) return error.InvalidVorbis;
        m.mapping = @intCast(mapping);
    }
    if (!b.flag() or b.eop) return error.InvalidVorbis;
}

fn float32Unpack(x: u32) f32 {
    const mantissa: f64 = @floatFromInt(x & 0x1fffff);
    const exp: i32 = @intCast((x & 0x7fe00000) >> 21);
    const v = std.math.ldexp(mantissa, exp - 788);
    return @floatCast(if (x & 0x80000000 != 0) -v else v);
}

/// The largest r with r^dims <= entries.
fn lookup1Values(entries: u32, dims: u16) u32 {
    var r: u32 = @intFromFloat(@floor(std.math.pow(f64, @floatFromInt(entries), 1.0 / @as(f64, @floatFromInt(dims)))));
    while (pow(r + 1, dims) <= entries) r += 1;
    while (r > 0 and pow(r, dims) > entries) r -= 1;
    return r;
}

fn pow(x: u32, n: u16) u64 {
    var p: u64 = 1;
    for (0..n) |_| {
        p *|= x;
    }
    return p;
}

fn readCodebook(a: std.mem.Allocator, b: *Bits) !Codebook {
    if (b.read(24) != 0x564342) return error.InvalidVorbis;
    const dims: u16 = @intCast(b.read(16));
    const entries = b.read(24);
    if (entries == 0 or b.eop) return error.InvalidVorbis;
    const lengths = try a.alloc(u8, entries);
    if (b.flag()) {
        // Ordered: runs of entries of increasing lengths.
        var len: u32 = b.read(5) + 1;
        var i: u32 = 0;
        while (i < entries) {
            const n = b.read(ilog(entries - i));
            if (i + n > entries or len > 32 or b.eop) return error.InvalidVorbis;
            @memset(lengths[i..][0..n], @intCast(len));
            i += n;
            len += 1;
        }
    } else {
        const sparse = b.flag();
        for (lengths) |*l| l.* = if (!sparse or b.flag()) @intCast(b.read(5) + 1) else 0;
    }
    if (b.eop) return error.InvalidVorbis;
    var c: Codebook = .{ .dims = dims, .entries = entries, .tree = try buildTree(a, lengths), .values = &.{} };
    const lookup = b.read(4);
    if (lookup == 0) return c;
    if (lookup > 2 or dims == 0) return error.InvalidVorbis;
    const min = float32Unpack(b.read(32));
    const delta = float32Unpack(b.read(32));
    const bits: u6 = @intCast(b.read(4) + 1);
    const seq = b.flag();
    const count: u64 = if (lookup == 1) lookup1Values(entries, dims) else @as(u64, entries) * dims;
    if (count == 0 or count * bits > (b.data.len * 8 - b.pos)) return error.InvalidVorbis;
    if (@as(u64, entries) * dims > 1 << 24) return error.UnsupportedVorbis;
    const mult = try a.alloc(u32, @intCast(count));
    for (mult) |*m| m.* = b.read(bits);
    c.values = try a.alloc(f32, entries * dims);
    for (0..entries) |e| {
        var last: f32 = 0;
        var div: u64 = 1;
        for (0..dims) |i| {
            const off: usize = if (lookup == 1) @intCast((e / div) % count) else e * dims + i;
            const v = @as(f32, @floatFromInt(mult[off])) * delta + min + last;
            c.values[e * dims + i] = v;
            if (seq) last = v;
            div *|= count;
        }
    }
    return c;
}

/// The Huffman tree of entries' code lengths (0: unused), whose codes are
/// assigned in order, each the lowest still free (Vorbis's rule).
fn buildTree(a: std.mem.Allocator, lengths: []const u8) ![][2]i32 {
    var used: u32 = 0;
    var only: u32 = 0;
    for (lengths, 0..) |l, i| if (l > 0) {
        used += 1;
        only = @intCast(i);
    };
    if (used == 0) return &.{};
    var nodes: std.ArrayList([2]i32) = .empty;
    try nodes.append(a, .{ Codebook.missing, Codebook.missing });
    if (used == 1) {
        // One entry: one bit, either value.
        nodes.items[0] = .{ -@as(i32, @intCast(only)) - 1, -@as(i32, @intCast(only)) - 1 };
        return nodes.items;
    }
    var marker: [33]u32 = @splat(0);
    for (lengths, 0..) |l, e| {
        if (l == 0) continue;
        var code = marker[l];
        if (l < 32 and code >> @intCast(l) != 0) return error.InvalidVorbis;
        const word = code;
        var j: usize = l;
        while (j > 0) : (j -= 1) {
            if (marker[j] & 1 != 0) {
                marker[j] = if (j == 1) marker[1] + 1 else marker[j - 1] << 1;
                break;
            }
            marker[j] += 1;
        }
        j = l + 1;
        while (j < 33) : (j += 1) {
            if (marker[j] >> 1 != code) break;
            code = marker[j];
            marker[j] = marker[j - 1] << 1;
        }
        // Insert `word`, most significant bit first.
        var node: usize = 0;
        var k: usize = l;
        while (k > 0) : (k -= 1) {
            const bit: u1 = @truncate(word >> @intCast(k - 1));
            const child = nodes.items[node][bit];
            if (k == 1) {
                if (child != Codebook.missing) return error.InvalidVorbis;
                nodes.items[node][bit] = -@as(i32, @intCast(e)) - 1;
            } else if (child == Codebook.missing) {
                try nodes.append(a, .{ Codebook.missing, Codebook.missing });
                const n: i32 = @intCast(nodes.items.len - 1);
                nodes.items[node][bit] = n;
                node = @intCast(n);
            } else if (child < 0) {
                return error.InvalidVorbis;
            } else node = @intCast(child);
        }
    }
    return nodes.items;
}

fn readFloor0(a: std.mem.Allocator, b: *Bits, nbooks: usize) !Floor0 {
    var f: Floor0 = .{
        .order = @intCast(b.read(8)),
        .rate = @intCast(b.read(16)),
        .bark_map_size = @intCast(b.read(16)),
        .amplitude_bits = @intCast(b.read(6)),
        .amplitude_offset = @intCast(b.read(8)),
        .books = undefined,
    };
    f.books = try a.alloc(u8, b.read(4) + 1);
    for (f.books) |*x| {
        x.* = @intCast(b.read(8));
        if (x.* >= nbooks) return error.InvalidVorbis;
    }
    if (f.order == 0 or f.bark_map_size == 0 or f.rate == 0) return error.InvalidVorbis;
    return f;
}

fn readFloor1(a: std.mem.Allocator, b: *Bits, nbooks: usize) !Floor1 {
    var f: Floor1 = undefined;
    f.partition_class = try a.alloc(u8, b.read(5));
    var max_class: usize = 0;
    for (f.partition_class) |*c| {
        c.* = @intCast(b.read(4));
        max_class = @max(max_class, c.*);
    }
    for (0..max_class + 1) |c| {
        f.class_dims[c] = @intCast(b.read(3) + 1);
        f.class_subs[c] = @intCast(b.read(2));
        f.class_master[c] = 0;
        if (f.class_subs[c] != 0) {
            f.class_master[c] = @intCast(b.read(8));
            if (f.class_master[c] >= nbooks) return error.InvalidVorbis;
        }
        for (0..@as(usize, 1) << f.class_subs[c]) |k| {
            const book = @as(i16, @intCast(b.read(8))) - 1;
            if (book >= nbooks) return error.InvalidVorbis;
            f.sub_books[c][k] = book;
        }
    }
    f.multiplier = @intCast(b.read(2) + 1);
    const range_bits: u6 = @intCast(b.read(4));
    var count: usize = 2;
    for (f.partition_class) |c| count += f.class_dims[c];
    if (count > 65) return error.InvalidVorbis;
    f.xs = try a.alloc(u16, count);
    f.xs[0] = 0;
    f.xs[1] = @intCast(@as(u32, 1) << @intCast(range_bits));
    var n: usize = 2;
    for (f.partition_class) |c| for (0..f.class_dims[c]) |_| {
        f.xs[n] = @intCast(b.read(range_bits));
        n += 1;
    };
    if (b.eop) return error.InvalidVorbis;
    f.sorted = try a.alloc(u8, count);
    for (f.sorted, 0..) |*s, i| s.* = @intCast(i);
    std.mem.sortUnstable(u8, f.sorted, f.xs, struct {
        fn lt(xs: []u16, l: u8, r: u8) bool {
            return xs[l] < xs[r];
        }
    }.lt);
    for (1..count) |i| if (f.xs[f.sorted[i]] == f.xs[f.sorted[i - 1]]) return error.InvalidVorbis;
    f.low = try a.alloc(u8, count);
    f.high = try a.alloc(u8, count);
    for (2..count) |i| {
        var lo: usize = 0;
        var hi: usize = 1;
        for (0..i) |j| {
            if (f.xs[j] < f.xs[i] and f.xs[j] > f.xs[lo]) lo = j;
            if (f.xs[j] > f.xs[i] and f.xs[j] < f.xs[hi]) hi = j;
        }
        f.low[i] = @intCast(lo);
        f.high[i] = @intCast(hi);
    }
    return f;
}

fn readResidue(a: std.mem.Allocator, b: *Bits, books: []const Codebook) !Residue {
    const kind = b.read(16);
    if (kind > 2) return error.InvalidVorbis;
    var r: Residue = .{
        .kind = @intCast(kind),
        .begin = b.read(24),
        .end = b.read(24),
        .partition_size = b.read(24) + 1,
        .classifications = @intCast(b.read(6) + 1),
        .classbook = @intCast(b.read(8)),
        .books = undefined,
    };
    if (r.classbook >= books.len) return error.InvalidVorbis;
    var cascade: [64]u8 = undefined;
    for (cascade[0..r.classifications]) |*c| {
        const low: u8 = @intCast(b.read(3));
        const high: u8 = if (b.flag()) @intCast(b.read(5)) else 0;
        c.* = high * 8 + low;
    }
    r.books = try a.alloc([8]i16, r.classifications);
    for (r.books, 0..) |*row, i| for (row, 0..) |*x, j| {
        x.* = -1;
        if (cascade[i] & (@as(u8, 1) << @intCast(j)) != 0) {
            const book = b.read(8);
            if (book >= books.len or books[book].values.len == 0) return error.InvalidVorbis;
            x.* = @intCast(book);
        }
    };
    return r;
}

fn readMapping(a: std.mem.Allocator, b: *Bits, channels: u16, nfloors: usize, nresidues: usize) !Mapping {
    if (b.read(16) != 0) return error.InvalidVorbis;
    var m: Mapping = undefined;
    m.submaps = if (b.flag()) @intCast(b.read(4) + 1) else 1;
    const steps: usize = if (b.flag()) b.read(8) + 1 else 0;
    m.coupling_mag = try a.alloc(u8, steps);
    m.coupling_ang = try a.alloc(u8, steps);
    const bits = ilog(channels - 1);
    for (0..steps) |i| {
        const mag = b.read(bits);
        const ang = b.read(bits);
        if (mag == ang or mag >= channels or ang >= channels) return error.InvalidVorbis;
        m.coupling_mag[i] = @intCast(mag);
        m.coupling_ang[i] = @intCast(ang);
    }
    if (b.read(2) != 0) return error.InvalidVorbis;
    m.mux = try a.alloc(u8, channels);
    @memset(m.mux, 0);
    if (m.submaps > 1) for (m.mux) |*x| {
        x.* = @intCast(b.read(4));
        if (x.* >= m.submaps) return error.InvalidVorbis;
    };
    for (0..m.submaps) |i| {
        _ = b.read(8);
        const fl = b.read(8);
        const res = b.read(8);
        if (fl >= nfloors or res >= nresidues) return error.InvalidVorbis;
        m.submap_floor[i] = @intCast(fl);
        m.submap_residue[i] = @intCast(res);
    }
    return m;
}

test "Vorbis: bits are read least significant first" {
    var b: Bits = .{ .data = &.{ 0b1010_1100, 0xff } };
    try std.testing.expectEqual(@as(u32, 0b100), b.read(3));
    try std.testing.expectEqual(@as(u32, 0b1_1010_1), b.read(6));
    try std.testing.expectEqual(@as(u32, 0x7f), b.read(7));
    try std.testing.expect(!b.eop);
    _ = b.read(1);
    try std.testing.expect(b.eop);
}

test "Vorbis: codewords assigned in order, the lowest free first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The specification's example: lengths 2 4 4 4 4 2 3 3.
    const tree = try buildTree(arena.allocator(), &.{ 2, 4, 4, 4, 4, 2, 3, 3 });
    const book: Codebook = .{ .dims = 1, .entries = 8, .tree = tree, .values = &.{} };
    // Codes 00 0100 0101 0110 0111 10 110 111, written first bit first
    // (bit 0 of each byte read first).
    const codes = [_][]const u1{ &.{ 0, 0 }, &.{ 0, 1, 0, 0 }, &.{ 0, 1, 0, 1 }, &.{ 0, 1, 1, 0 }, &.{ 0, 1, 1, 1 }, &.{ 1, 0 }, &.{ 1, 1, 0 }, &.{ 1, 1, 1 } };
    for (codes, 0..) |code, e| {
        var byte: u8 = 0;
        for (code, 0..) |bit, i| byte |= @as(u8, bit) << @intCast(i);
        var b: Bits = .{ .data = &.{byte} };
        try std.testing.expectEqual(@as(?u32, @intCast(e)), book.decode(&b));
        try std.testing.expectEqual(code.len, b.pos);
    }
    try std.testing.expectEqual(@as(u32, 3), lookup1Values(27, 3));
    try std.testing.expectEqual(@as(u32, 2), lookup1Values(26, 3));
    try std.testing.expectEqual(@as(f32, 1), float32Unpack((788 << 21) | 1));
}
