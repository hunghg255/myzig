//! Ogg Vorbis files, decoded as they play (from memory or a file): the
//! three headers, then audio packets. The pages are listed once when the
//! file opens, which gives its length (the last page's position) and lets
//! it seek: from the last page before the target that a packet both starts
//! and ends on, decoding on to the target. Trims what the first page's
//! position says comes before the start, and what the last page's says
//! comes after the end.
const std = @import("std");
const source = @import("source.zig");
const bytesrc = @import("bytesrc.zig");
const ogg = @import("ogg.zig");
const setup = @import("vorbis_setup.zig");
const packet = @import("vorbis_packet.zig");

pub const Src = bytesrc.Src;

/// Whether `bytes` (a file's first bytes) start an Ogg stream.
pub fn sniff(bytes: []const u8) bool {
    return bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "OggS");
}

pub const Decoder = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    src: Src,
    /// Closed with the decoder (a stream's file).
    owns_file: bool = false,
    setup: setup.Setup,
    dsp: packet.Dsp,
    packets: ogg.Packets,
    pages: []ogg.Entry,
    /// The first page after the headers' last.
    first_audio: usize,
    /// Where the first audio packet starts.
    audio_offset: u64,
    audio_seg: usize,
    total: ?u64,
    skip_start: u64,
    /// The position of `pending[pend_off]`; frames before `skip_to` are dropped.
    pos: i64 = 0,
    skip_to: u64 = 0,
    pending: []f32,
    pend_len: usize = 0,
    pend_off: usize = 0,

    pub fn init(gpa: std.mem.Allocator, src: Src) !*Decoder {
        const d = try gpa.create(Decoder);
        errdefer gpa.destroy(d);
        d.* = undefined;
        d.gpa = gpa;
        d.src = src;
        d.owns_file = false;
        d.skip_to = 0;
        d.arena = .init(gpa);
        errdefer d.arena.deinit();
        const a = d.arena.allocator();
        const serial = try findVorbis(src);
        d.packets = try ogg.Packets.init(gpa, src, serial, 0);
        errdefer d.packets.deinit();
        const id = try d.packets.next() orelse return error.InvalidVorbis;
        d.setup = try setup.readIdentification(id);
        const comment = try d.packets.next() orelse return error.InvalidVorbis;
        if (!setup.isComment(comment)) return error.InvalidVorbis;
        const sp = try d.packets.next() orelse return error.InvalidVorbis;
        try setup.readSetup(a, &d.setup, sp);
        const last_header = d.packets.page.?;
        d.audio_offset = last_header.offset;
        d.audio_seg = d.packets.seg;
        d.dsp = try packet.Dsp.init(a, &d.setup);
        d.pending = try a.alloc(f32, d.setup.blocksize[1] / 2 * d.setup.channels);
        d.pages = try ogg.scan(gpa, src, serial, 0);
        errdefer gpa.free(d.pages);
        d.first_audio = d.pages.len;
        for (d.pages, 0..) |p, i| if (p.offset == last_header.offset) {
            d.first_audio = i + 1;
        };
        d.total = null;
        var i = d.pages.len;
        while (i > d.first_audio) {
            i -= 1;
            if (d.pages[i].granule >= 0) {
                d.total = @intCast(d.pages[i].granule);
                break;
            }
        }
        d.skip_start = try d.startTrim();
        try d.rewind();
        return d;
    }

    /// The serial of the first logical stream that is Vorbis.
    fn findVorbis(src: Src) !u32 {
        var segs: [255]u8 = undefined;
        var at: u64 = 0;
        while (try ogg.readPage(src, at, &segs)) |p| : (at = p.end()) {
            if (p.flags & ogg.flag_first == 0) break;
            var head: [7]u8 = undefined;
            if (try bytesrc.readAt(src, &head, p.offset + p.header_len) == 7 and std.mem.eql(u8, &head, "\x01vorbis")) return p.serial;
        }
        return error.UnsupportedFormat;
    }

    /// How many frames the first audio page decodes to beyond its position
    /// (a stream that doesn't start at 0), from its packets' block sizes.
    fn startTrim(d: *Decoder) !u64 {
        try d.packets.restart(d.audio_offset, d.audio_seg);
        var prev: u32 = 0;
        var produced: u64 = 0;
        while (try d.packets.next()) |p| {
            const n = packet.blocksize(&d.setup, p) orelse continue;
            if (prev != 0) produced += prev / 4 + n / 4;
            prev = n;
            if (d.packets.granule) |g| {
                const last = d.packets.page.?.flags & ogg.flag_last != 0;
                if (last or g < 0) return 0;
                return produced -| @as(u64, @intCast(g));
            }
        }
        return 0;
    }

    fn rewind(d: *Decoder) !void {
        try d.packets.restart(d.audio_offset, d.audio_seg);
        d.dsp.reset();
        d.pos = -@as(i64, @intCast(d.skip_start));
        d.pend_len = 0;
        d.pend_off = 0;
    }

    pub fn decoder(d: *Decoder) source.Decoder {
        return .{ .ptr = d, .vtable = &vtable, .rate = d.setup.rate, .channels = d.setup.channels, .frames = d.total };
    }

    const vtable: source.Decoder.VTable = .{ .read = read, .seek = seek, .deinit = deinit };

    fn read(ptr: *anyopaque, dst: []f32) anyerror!usize {
        const d: *Decoder = @ptrCast(@alignCast(ptr));
        const ch: usize = d.setup.channels;
        const want = dst.len / ch;
        var done: usize = 0;
        while (done < want) {
            if (d.pend_off < d.pend_len) {
                var avail = d.pend_len - d.pend_off;
                // Before the start, or the target of a seek.
                const floor_pos = @max(0, @as(i64, @intCast(d.skip_to)));
                if (d.pos < floor_pos) {
                    const k: usize = @intCast(@min(@as(i64, @intCast(avail)), floor_pos - d.pos));
                    d.pend_off += k;
                    d.pos += @intCast(k);
                    continue;
                }
                if (d.total) |t| {
                    if (d.pos >= t) break;
                    avail = @min(avail, t - @as(u64, @intCast(d.pos)));
                }
                const k = @min(avail, want - done);
                @memcpy(dst[done * ch ..][0 .. k * ch], d.pending[d.pend_off * ch ..][0 .. k * ch]);
                done += k;
                d.pend_off += k;
                d.pos += @intCast(k);
                continue;
            }
            const p = try d.packets.next() orelse break;
            d.pend_len = d.dsp.decode(p, d.pending);
            d.pend_off = 0;
        }
        return done;
    }

    fn seek(ptr: *anyopaque, frame: u64) anyerror!void {
        const d: *Decoder = @ptrCast(@alignCast(ptr));
        const target = if (d.total) |t| @min(frame, t) else frame;
        d.skip_to = target;
        // The last page before the target to start from.
        var i = d.pages.len;
        while (i > d.first_audio) {
            i -= 1;
            const p = d.pages[i];
            if (p.granule < 0 or p.restart_seg < 0 or p.granule > target) continue;
            try d.packets.restart(p.offset, @intCast(p.restart_seg));
            d.dsp.reset();
            d.pos = p.granule;
            d.pend_len = 0;
            d.pend_off = 0;
            return;
        }
        try d.rewind();
    }

    fn deinit(ptr: *anyopaque) void {
        const d: *Decoder = @ptrCast(@alignCast(ptr));
        if (d.owns_file) bytesrc.close(d.src);
        d.packets.deinit();
        d.gpa.free(d.pages);
        d.arena.deinit();
        d.gpa.destroy(d);
    }
};
