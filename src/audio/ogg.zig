//! Ogg, the container of Vorbis: pages (a header, a table of segments and
//! their bytes, checked by a CRC) carry one logical stream's packets, split
//! into segments of up to 255 bytes. `Packets` reassembles them as they
//! play; `scan` lists the pages, for a stream's length and for seeking.
const std = @import("std");
const bytesrc = @import("bytesrc.zig");

pub const Src = bytesrc.Src;

pub const Error = error{InvalidOgg};

pub const flag_continued: u8 = 1;
pub const flag_first: u8 = 2;
pub const flag_last: u8 = 4;

/// A page's header, as it is in the file.
pub const Page = struct {
    offset: u64,
    flags: u8,
    /// The position after the last packet that ends on the page, or -1.
    granule: i64,
    serial: u32,
    crc: u32,
    nseg: u8,
    /// The header's length, with its segment table, and the body's.
    header_len: u32,
    body_len: u32,

    pub fn end(p: Page) u64 {
        return p.offset + p.header_len + p.body_len;
    }
};

/// Reads the page header at `offset` into `p`, and its segment table into
/// `segs`. Null at the end of the source, an error where no page starts.
pub fn readPage(src: Src, offset: u64, segs: *[255]u8) !?Page {
    var h: [27]u8 = undefined;
    const got = try bytesrc.readAt(src, &h, offset);
    if (got == 0) return null;
    if (got < 27 or !std.mem.eql(u8, h[0..4], "OggS") or h[4] != 0) return error.InvalidOgg;
    const nseg = h[26];
    if (try bytesrc.readAt(src, segs[0..nseg], offset + 27) < nseg) return error.InvalidOgg;
    var body: u32 = 0;
    for (segs[0..nseg]) |s| body += s;
    return .{
        .offset = offset,
        .flags = h[5],
        .granule = std.mem.readInt(i64, h[6..14], .little),
        .serial = std.mem.readInt(u32, h[14..18], .little),
        .crc = std.mem.readInt(u32, h[22..26], .little),
        .nseg = nseg,
        .header_len = 27 + @as(u32, nseg),
        .body_len = body,
    };
}

/// The next page at or after `offset` (after damage: the capture pattern
/// searched for), or null.
pub fn findPage(src: Src, offset: u64, segs: *[255]u8) !?Page {
    var buf: [4096]u8 = undefined;
    var at = offset;
    while (true) {
        const n = try bytesrc.readAt(src, &buf, at);
        if (n < 4) return null;
        if (std.mem.indexOf(u8, buf[0..n], "OggS")) |i| {
            if (readPage(src, at + i, segs)) |p| return p else |_| {}
            at += i + 1;
        } else at += n - 3;
    }
}

const crc_table = blk: {
    @setEvalBranchQuota(10000);
    var t: [256]u32 = undefined;
    for (&t, 0..) |*e, i| {
        var r: u32 = @as(u32, i) << 24;
        for (0..8) |_| r = if (r & 0x80000000 != 0) (r << 1) ^ 0x04c11db7 else r << 1;
        e.* = r;
    }
    break :blk t;
};

fn crcUpdate(crc: u32, bytes: []const u8) u32 {
    var c = crc;
    for (bytes) |b| c = (c << 8) ^ crc_table[((c >> 24) ^ b) & 0xff];
    return c;
}

/// A page as `scan` lists it: where it is, its position, and where the
/// last packet that both starts and ends on it starts (a place to start
/// decoding from), if one does.
pub const Entry = struct {
    offset: u64,
    granule: i64,
    /// The segment that packet starts at, or -1.
    restart_seg: i16,
};

/// The segment where the last packet starting and ending on the page
/// starts, or -1.
pub fn restartSegment(p: Page, segs: []const u8) i16 {
    var ends: [2]i16 = .{ -1, -1 };
    var count: usize = 0;
    for (segs[0..p.nseg], 0..) |s, i| if (s < 255) {
        ends[0] = ends[1];
        ends[1] = @intCast(i);
        count += 1;
    };
    const continued = p.flags & flag_continued != 0;
    if (count == 0 or (continued and count < 2)) return -1;
    return if (count >= 2) ends[0] + 1 else 0;
}

/// Lists the pages of stream `serial`, from `offset` to the end.
pub fn scan(gpa: std.mem.Allocator, src: Src, serial: u32, offset: u64) ![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    errdefer list.deinit(gpa);
    var segs: [255]u8 = undefined;
    var at = offset;
    while (true) {
        const p = (readPage(src, at, &segs) catch try findPage(src, at, &segs)) orelse break;
        at = p.end();
        if (p.serial != serial) continue;
        try list.append(gpa, .{ .offset = p.offset, .granule = p.granule, .restart_seg = restartSegment(p, &segs) });
        if (p.flags & flag_last != 0) break;
    }
    return list.toOwnedSlice(gpa);
}

/// Reassembles one stream's packets from its pages, as they play.
pub const Packets = struct {
    gpa: std.mem.Allocator,
    src: Src,
    serial: u32,
    /// Where the next page starts.
    next_page: u64,
    page: ?Page = null,
    segs: [255]u8 = undefined,
    seg: usize = 0,
    body: []u8,
    body_pos: usize = 0,
    packet: std.ArrayList(u8) = .empty,
    /// Drop the rest of a packet that began before where reading started.
    drop_continued: bool = true,
    /// The granule of the page the last packet returned ended on, if it was
    /// the page's last packet.
    granule: ?i64 = null,
    ended: bool = false,

    pub const max_packet = 8 << 20;

    pub fn init(gpa: std.mem.Allocator, src: Src, serial: u32, offset: u64) !Packets {
        return .{ .gpa = gpa, .src = src, .serial = serial, .next_page = offset, .body = try gpa.alloc(u8, 255 * 255) };
    }

    pub fn deinit(p: *Packets) void {
        p.packet.deinit(p.gpa);
        p.gpa.free(p.body);
    }

    /// Reads from the page at `offset`, its packet starting at segment `seg`.
    pub fn restart(p: *Packets, offset: u64, seg: usize) !void {
        p.next_page = offset;
        p.ended = false;
        p.packet.clearRetainingCapacity();
        p.page = null;
        if (!try p.loadPage()) return;
        p.drop_continued = false;
        p.seg = @min(seg, p.page.?.nseg);
        p.body_pos = 0;
        for (p.segs[0..p.seg]) |s| p.body_pos += s;
    }

    /// Loads the next page of the stream, its CRC checked. False at its end.
    fn loadPage(p: *Packets) !bool {
        while (true) {
            const pg = (readPage(p.src, p.next_page, &p.segs) catch try findPage(p.src, p.next_page, &p.segs)) orelse return false;
            p.next_page = pg.end();
            if (pg.serial != p.serial) continue;
            if (try bytesrc.readAt(p.src, p.body[0..pg.body_len], pg.offset + pg.header_len) < pg.body_len) return false;
            var hdr: [27 + 255]u8 = undefined;
            _ = try bytesrc.readAt(p.src, hdr[0..pg.header_len], pg.offset);
            @memset(hdr[22..26], 0);
            const crc = crcUpdate(crcUpdate(0, hdr[0..pg.header_len]), p.body[0..pg.body_len]);
            if (crc != pg.crc) {
                // A damaged page: what spanned it is lost.
                p.packet.clearRetainingCapacity();
                p.drop_continued = true;
                continue;
            }
            const continued = pg.flags & flag_continued != 0;
            if (!continued and p.packet.items.len > 0) p.packet.clearRetainingCapacity();
            if (continued and p.packet.items.len == 0) p.drop_continued = true;
            if (!continued) p.drop_continued = false;
            p.page = pg;
            p.seg = 0;
            p.body_pos = 0;
            return true;
        }
    }

    /// The next packet (valid until the next call), or null at the end.
    pub fn next(p: *Packets) !?[]const u8 {
        if (p.ended) return null;
        p.packet.clearRetainingCapacity();
        p.granule = null;
        while (true) {
            if (p.page == null or p.seg >= p.page.?.nseg) {
                const last = if (p.page) |pg| pg.flags & flag_last != 0 else false;
                if (last or !try p.loadPage()) {
                    p.ended = true;
                    return null;
                }
                continue;
            }
            const pg = p.page.?;
            const len = p.segs[p.seg];
            const bytes = p.body[p.body_pos..][0..len];
            p.seg += 1;
            p.body_pos += len;
            if (!p.drop_continued) {
                if (p.packet.items.len + len > max_packet) return error.InvalidOgg;
                try p.packet.appendSlice(p.gpa, bytes);
            }
            if (len == 255) continue;
            if (p.drop_continued) {
                p.drop_continued = false;
                continue;
            }
            // The page's last packet: its position is the page's.
            var more = false;
            for (p.segs[p.seg..pg.nseg]) |s| if (s < 255) {
                more = true;
            };
            if (!more) p.granule = pg.granule;
            return p.packet.items;
        }
    }
};

test "Ogg: CRC of a known page" {
    // The CRC of "OggS" with the polynomial Ogg uses (no reflection).
    try std.testing.expectEqual(@as(u32, 0x5fb0a94f), crcUpdate(0, "OggS"));
}

test "Ogg: the packet to restart from on a page" {
    const pg: Page = .{ .offset = 0, .flags = 0, .granule = 0, .serial = 0, .crc = 0, .nseg = 4, .header_len = 31, .body_len = 0 };
    try std.testing.expectEqual(@as(i16, 3), restartSegment(pg, &.{ 255, 10, 20, 30 }));
    try std.testing.expectEqual(@as(i16, 0), restartSegment(pg, &.{ 255, 10, 255, 255 }));
    var cont = pg;
    cont.flags = flag_continued;
    try std.testing.expectEqual(@as(i16, -1), restartSegment(cont, &.{ 255, 10, 255, 255 }));
    try std.testing.expectEqual(@as(i16, 2), restartSegment(cont, &.{ 255, 10, 255, 1 }));
}
