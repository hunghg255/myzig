//! MP3 frames: the 4 byte header (MPEG-1, 2 and 2.5, layer III), the side
//! information, the Xing/Info frame with LAME's encoder delay and padding
//! (gapless playback), ID3v2 tags before the first frame, and the list of
//! frames a file has, for its length and for seeking.
const std = @import("std");
const bytesrc = @import("bytesrc.zig");
const tables = @import("mp3_tables.zig");

pub const Src = bytesrc.Src;

pub const Version = enum(u2) { mpeg25 = 0, mpeg2 = 2, mpeg1 = 3 };

pub const Header = struct {
    version: Version,
    crc: bool,
    bitrate_index: u4,
    rate_index: u2,
    padding: bool,
    /// 0 stereo, 1 joint stereo, 2 dual channel, 3 mono.
    mode: u2,
    mode_ext: u2,

    pub fn parse(b: []const u8) ?Header {
        if (b.len < 4 or b[0] != 0xff or b[1] & 0xe0 != 0xe0) return null;
        const ver = (b[1] >> 3) & 3;
        const layer = (b[1] >> 1) & 3;
        const br: u4 = @intCast(b[2] >> 4);
        const sr: u2 = @intCast((b[2] >> 2) & 3);
        // Layer III only (1); free format (0) and the reserved values aren't decoded.
        if (ver == 1 or layer != 1 or br == 0 or br == 15 or sr == 3 or b[3] & 3 == 2) return null;
        return .{
            .version = @enumFromInt(ver),
            .crc = b[1] & 1 == 0,
            .bitrate_index = br,
            .rate_index = sr,
            .padding = b[2] & 2 != 0,
            .mode = @intCast(b[3] >> 6),
            .mode_ext = @intCast((b[3] >> 4) & 3),
        };
    }

    pub fn lsf(h: Header) bool {
        return h.version != .mpeg1;
    }

    pub fn channels(h: Header) u16 {
        return if (h.mode == 3) 1 else 2;
    }

    pub fn rate(h: Header) u32 {
        const base = ([3]u32{ 44100, 48000, 32000 })[h.rate_index];
        return switch (h.version) {
            .mpeg1 => base,
            .mpeg2 => base / 2,
            .mpeg25 => base / 4,
        };
    }

    /// Which of `tables.bands`.
    pub fn bandIndex(h: Header) usize {
        return @as(usize, switch (h.version) {
            .mpeg1 => 0,
            .mpeg2 => 3,
            .mpeg25 => 6,
        }) + h.rate_index;
    }

    pub fn granules(h: Header) u32 {
        return if (h.lsf()) 1 else 2;
    }

    pub fn samples(h: Header) u32 {
        return 576 * h.granules();
    }

    pub fn bytes(h: Header) u32 {
        const kbps: u32 = tables.bitrates[@intFromBool(h.lsf())][h.bitrate_index];
        const per: u32 = if (h.lsf()) 72 else 144;
        return per * kbps * 1000 / h.rate() + @intFromBool(h.padding);
    }

    pub fn sideInfoBytes(h: Header) u32 {
        return if (h.lsf()) (if (h.mode == 3) 9 else 17) else (if (h.mode == 3) 17 else 32);
    }

    /// Whether a frame of `o` can follow this one in the same stream.
    pub fn sameStream(h: Header, o: Header) bool {
        return h.version == o.version and h.rate_index == o.rate_index;
    }
};

pub const Granule = struct {
    part23: u32 = 0,
    big_values: u32 = 0,
    global_gain: u32 = 0,
    scalefac_compress: u32 = 0,
    window_switching: bool = false,
    block_type: u2 = 0,
    mixed: bool = false,
    table_select: [3]u5 = .{ 0, 0, 0 },
    subblock_gain: [3]u3 = .{ 0, 0, 0 },
    region0: u32 = 0,
    region1: u32 = 0,
    preflag: bool = false,
    scalefac_scale: bool = false,
    count1table: u1 = 0,

    pub fn short(g: Granule) bool {
        return g.window_switching and g.block_type == 2;
    }
};

pub const SideInfo = struct {
    main_data_begin: u32,
    scfsi: [2][4]bool,
    gr: [2][2]Granule,
};

/// Reads bits most significant first (side information, main data).
pub const Bits = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn read(b: *Bits, n: u5) u32 {
        var v: u32 = 0;
        for (0..n) |_| {
            const at = b.pos >> 3;
            const bit: u32 = if (at < b.data.len) (b.data[at] >> @intCast(7 - (b.pos & 7))) & 1 else 0;
            v = (v << 1) | bit;
            b.pos += 1;
        }
        return v;
    }
};

pub fn readSideInfo(h: Header, b: []const u8) ?SideInfo {
    var r: Bits = .{ .data = b };
    const nch = h.channels();
    var si: SideInfo = .{ .main_data_begin = 0, .scfsi = @splat(@splat(false)), .gr = @splat(@splat(.{})) };
    if (h.lsf()) {
        si.main_data_begin = r.read(8);
        _ = r.read(if (nch == 1) 1 else 2);
    } else {
        si.main_data_begin = r.read(9);
        _ = r.read(if (nch == 1) 5 else 3);
        for (0..nch) |c| for (&si.scfsi[c]) |*x| {
            x.* = r.read(1) == 1;
        };
    }
    for (0..h.granules()) |gi| for (0..nch) |c| {
        const g = &si.gr[gi][c];
        g.part23 = r.read(12);
        g.big_values = r.read(9);
        if (g.big_values > 288) return null;
        g.global_gain = r.read(8);
        g.scalefac_compress = r.read(if (h.lsf()) 9 else 4);
        g.window_switching = r.read(1) == 1;
        if (g.window_switching) {
            g.block_type = @intCast(r.read(2));
            if (g.block_type == 0) return null;
            g.mixed = r.read(1) == 1;
            for (g.table_select[0..2]) |*t| t.* = @intCast(r.read(5));
            for (&g.subblock_gain) |*s| s.* = @intCast(r.read(3));
        } else {
            for (&g.table_select) |*t| t.* = @intCast(r.read(5));
            g.region0 = r.read(4);
            g.region1 = r.read(3);
        }
        if (!h.lsf()) g.preflag = r.read(1) == 1;
        g.scalefac_scale = r.read(1) == 1;
        g.count1table = @intCast(r.read(1));
    };
    return si;
}

/// The length of the ID3v2 tag at the start of `b`, or 0.
pub fn id3Length(b: []const u8) u64 {
    if (b.len < 10 or !std.mem.eql(u8, b[0..3], "ID3")) return 0;
    var size: u64 = 0;
    for (b[6..10]) |x| {
        if (x & 0x80 != 0) return 0;
        size = (size << 7) | x;
    }
    return 10 + size + @as(u64, if (b[5] & 0x10 != 0) 10 else 0);
}

/// What a Xing/Info (or VBRI) frame says: the frames that follow it, and
/// LAME's delay and padding (samples the encoder added before and after).
pub const Info = struct {
    frames: ?u32 = null,
    delay: ?u32 = null,
    padding: u32 = 0,
};

/// Reads the Xing/Info frame `f` (a whole frame), or null if it is audio.
pub fn readInfo(h: Header, f: []const u8) ?Info {
    const off: usize = 4 + @as(usize, if (h.crc) 2 else 0) + h.sideInfoBytes();
    if (f.len >= off + 8 and (std.mem.eql(u8, f[off..][0..4], "Xing") or std.mem.eql(u8, f[off..][0..4], "Info"))) {
        const flags = std.mem.readInt(u32, f[off + 4 ..][0..4], .big);
        var info: Info = .{};
        var x = off + 8;
        if (flags & 1 != 0) {
            if (f.len < x + 4) return info;
            info.frames = std.mem.readInt(u32, f[x..][0..4], .big);
            x += 4;
        }
        if (flags & 2 != 0) x += 4;
        if (flags & 4 != 0) x += 100;
        if (flags & 8 != 0) x += 4;
        // LAME's tag: a 9 character encoder name, then at 21 the delay
        // and padding, 12 bits each.
        if (f.len >= x + 24 and std.ascii.isAlphabetic(f[x]) and std.ascii.isAlphabetic(f[x + 1])) {
            const d = f[x + 21 ..][0..3];
            info.delay = (@as(u32, d[0]) << 4) | (d[1] >> 4);
            info.padding = (@as(u32, d[1] & 15) << 8) | d[2];
        }
        return info;
    }
    if (f.len >= 36 + 18 and std.mem.eql(u8, f[36..40], "VBRI")) {
        return .{ .frames = std.mem.readInt(u32, f[36 + 14 ..][0..4], .big) };
    }
    return null;
}

/// Reads a source through a window of its bytes (scanning reads a few
/// bytes a frame).
const Window = struct {
    src: Src,
    buf: [32768]u8 = undefined,
    base: u64 = 0,
    len: usize = 0,

    fn at(w: *Window, off: u64, n: usize) ![]const u8 {
        if (off < w.base or off + n > w.base + w.len) {
            w.base = off;
            w.len = try bytesrc.readAt(w.src, &w.buf, off);
        }
        const start: usize = @intCast(off - w.base);
        return w.buf[start..@min(w.len, start + n)];
    }
};

/// The frames of a file: where each starts, its first header, and what
/// an Info frame said (which isn't among the frames).
pub const Scan = struct {
    offsets: []u64,
    first: Header,
    info: ?Info,
};

/// A frame starts at `off`: a header, then another frame or the end.
fn frameAt(w: *Window, off: u64, size: u64) !?Header {
    const h = Header.parse(try w.at(off, 4)) orelse return null;
    const next = off + h.bytes();
    if (next + 4 > size) return if (next <= size) h else null;
    const h2 = Header.parse(try w.at(next, 4)) orelse return null;
    return if (h.sameStream(h2)) h else null;
}

pub fn scan(gpa: std.mem.Allocator, src: Src) !Scan {
    const size = try bytesrc.size(src);
    const w = try gpa.create(Window);
    defer gpa.destroy(w);
    w.* = .{ .src = src };
    var off: u64 = 0;
    while (true) {
        const n = id3Length(try w.at(off, 10));
        if (n == 0) break;
        off += n;
    }
    // The first frame: a header followed by another, within 64 KB.
    const limit = off + 65536;
    const first = while (off < @min(limit, size)) : (off += 1) {
        if (try frameAt(w, off, size)) |h| break h;
    } else return error.InvalidMp3;
    var list: std.ArrayList(u64) = .empty;
    errdefer list.deinit(gpa);
    var info: ?Info = null;
    const f0 = try w.at(off, first.bytes());
    if (readInfo(first, f0)) |i| {
        info = i;
        off += first.bytes();
    }
    while (off + 4 <= size) {
        if (Header.parse(try w.at(off, 4))) |h| if (h.sameStream(first)) {
            if (off + h.bytes() > size) break;
            try list.append(gpa, off);
            off += h.bytes();
            continue;
        };
        // Damage, or a tag at the end: the next frame, if any.
        const tail = try w.at(off, 3);
        if (std.mem.eql(u8, tail, "TAG") and size - off <= 128 + 227) break;
        off += 1;
        while (off + 4 <= size) : (off += 1) if (try frameAt(w, off, size)) |h| {
            if (h.sameStream(first)) break;
        };
    }
    if (list.items.len == 0) return error.InvalidMp3;
    return .{ .offsets = try list.toOwnedSlice(gpa), .first = first, .info = info };
}

test "MP3: frame headers, ID3v2 lengths" {
    // MPEG-1 layer III, 128 kb/s, 44.1 kHz, joint stereo.
    const h = Header.parse(&.{ 0xff, 0xfb, 0x90, 0x44 }).?;
    try std.testing.expectEqual(Version.mpeg1, h.version);
    try std.testing.expectEqual(@as(u32, 44100), h.rate());
    try std.testing.expectEqual(@as(u32, 417), h.bytes());
    try std.testing.expectEqual(@as(u16, 2), h.channels());
    try std.testing.expectEqual(@as(u32, 1152), h.samples());
    // MPEG-2.5, 8 kHz, 8 kb/s, mono.
    const l = Header.parse(&.{ 0xff, 0xe3, 0x18, 0xc4 }).?;
    try std.testing.expectEqual(Version.mpeg25, l.version);
    try std.testing.expectEqual(@as(u32, 8000), l.rate());
    try std.testing.expectEqual(@as(u32, 72), l.bytes());
    try std.testing.expectEqual(@as(?Header, null), Header.parse(&.{ 0xff, 0xfd, 0x90, 0x44 })); // layer II
    try std.testing.expectEqual(@as(u64, 10 + 257), id3Length("ID3\x04\x00\x00\x00\x00\x02\x01"));
}
