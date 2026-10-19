//! MP3 files (MPEG-1, 2 and 2.5 layer III), decoded as they play, from
//! memory or a file. The frames are listed once when the file opens: its
//! length, and seeking (from a few frames before the target, decoded and
//! dropped, for the bit reservoir and the filters' overlap to fill up).
//! With LAME's tag (in the Xing/Info frame), the encoder's delay and
//! padding are trimmed: the samples are the ones encoded, gaplessly.
const std = @import("std");
const source = @import("source.zig");
const bytesrc = @import("bytesrc.zig");
const frame = @import("mp3_frame.zig");
const layer3 = @import("mp3_layer3.zig");
const synth = @import("mp3_synth.zig");

pub const Src = bytesrc.Src;

/// Whether `bytes` (a file's first bytes) start an MP3 file: an ID3v2 tag
/// or a layer III frame.
pub fn sniff(bytes: []const u8) bool {
    if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "ID3")) return true;
    return frame.Header.parse(bytes) != null;
}

/// Frames decoded before a seek's target, dropped: the bit reservoir
/// reaches 511 bytes back, several frames at low bitrates.
const priming = 10;
/// The decoder's own delay, which LAME's delay doesn't count.
const decoder_delay = 529;

pub const Decoder = struct {
    gpa: std.mem.Allocator,
    src: Src,
    /// Closed with the decoder (a stream's file).
    owns_file: bool = false,
    offsets: []u64,
    first: frame.Header,
    channels: u16,
    rate: u32,
    spf: u32,
    /// Samples dropped at the start (the encoder's and decoder's delay).
    skip: u64 = 0,
    total: ?u64,
    state: synth.State,
    chs: [2][2]layer3.Channel = @splat(@splat(.{})),
    reservoir: [4096]u8 = undefined,
    res_len: usize = 0,
    frame_buf: [2048]u8 = undefined,
    planar: [2][1152]f32 = undefined,
    next: usize = 0,
    pos: i64 = 0,
    skip_to: u64 = 0,
    pending: [2 * 1152]f32 = undefined,
    pend_len: usize = 0,
    pend_off: usize = 0,

    pub fn init(gpa: std.mem.Allocator, src: Src) !*Decoder {
        const s = try frame.scan(gpa, src);
        errdefer gpa.free(s.offsets);
        const d = try gpa.create(Decoder);
        errdefer gpa.destroy(d);
        d.* = .{
            .gpa = gpa,
            .src = src,
            .offsets = s.offsets,
            .first = s.first,
            .channels = s.first.channels(),
            .rate = s.first.rate(),
            .spf = s.first.samples(),
            .total = null,
            .state = undefined,
        };
        d.state.init();
        // The frames found, rather than the Info frame's count (which
        // some muxers write before the last frames).
        const frames: u64 = s.offsets.len;
        if (s.info) |info| {
            if (info.delay) |delay| {
                d.skip = delay + decoder_delay;
                d.total = @min((frames * d.spf) -| (delay + info.padding), (frames * d.spf) -| d.skip);
            }
        }
        if (d.total == null) d.total = frames * d.spf;
        d.pos = -@as(i64, @intCast(d.skip));
        return d;
    }

    pub fn decoder(d: *Decoder) source.Decoder {
        return .{ .ptr = d, .vtable = &vtable, .rate = d.rate, .channels = d.channels, .frames = d.total };
    }

    const vtable: source.Decoder.VTable = .{ .read = read, .seek = seek, .deinit = deinit };

    /// Decodes frame `i` into `pending`: its samples, or silence where
    /// the reservoir lacks what it needs (after a seek) or it is damaged.
    fn decodeFrame(d: *Decoder, i: usize) !usize {
        const off = d.offsets[i];
        const got = try bytesrc.readAt(d.src, &d.frame_buf, off);
        const ch: usize = d.channels;
        const n = d.spf;
        @memset(d.pending[0 .. n * ch], 0);
        const h = frame.Header.parse(d.frame_buf[0..got]) orelse return n;
        const len = h.bytes();
        if (got < len or h.samples() != n) return n;
        const si_at: usize = if (h.crc) 6 else 4;
        const main_at = si_at + h.sideInfoBytes();
        if (main_at > len) return n;
        var si = frame.readSideInfo(h, d.frame_buf[si_at..main_at]) orelse return n;
        const main = d.frame_buf[main_at..len];
        if (d.res_len + main.len > d.reservoir.len) {
            const keep = 1024;
            std.mem.copyForwards(u8, d.reservoir[0..keep], d.reservoir[d.res_len - keep .. d.res_len]);
            d.res_len = keep;
        }
        const before = d.res_len;
        @memcpy(d.reservoir[before..][0..main.len], main);
        d.res_len += main.len;
        if (si.main_data_begin > before) return n;
        layer3.decodeMain(h, &si, d.reservoir[before - si.main_data_begin .. d.res_len], &d.chs);
        const hch = h.channels();
        for (0..h.granules()) |g| {
            synth.stereo(h, &si.gr[g], &d.chs[g]);
            for (0..hch) |c| synth.synthesize(&d.state, h, &si.gr[g][c], &d.chs[g][c], c, d.planar[c][g * 576 ..], 1);
        }
        // A frame of the other channel count: mono doubled, or stereo's left.
        for (0..n) |k| for (0..ch) |c| {
            d.pending[k * ch + c] = d.planar[@min(c, hch - 1)][k];
        };
        return n;
    }

    fn read(ptr: *anyopaque, dst: []f32) anyerror!usize {
        const d: *Decoder = @ptrCast(@alignCast(ptr));
        const ch: usize = d.channels;
        const want = dst.len / ch;
        var done: usize = 0;
        while (done < want) {
            if (d.pend_off < d.pend_len) {
                var avail = d.pend_len - d.pend_off;
                const floor_pos = @as(i64, @intCast(d.skip_to));
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
            if (d.next >= d.offsets.len) break;
            d.pend_len = try d.decodeFrame(d.next);
            d.pend_off = 0;
            d.next += 1;
        }
        return done;
    }

    fn seek(ptr: *anyopaque, target_frame: u64) anyerror!void {
        const d: *Decoder = @ptrCast(@alignCast(ptr));
        const target = if (d.total) |t| @min(target_frame, t) else target_frame;
        const k = (target + d.skip) / d.spf;
        const start = @min(k -| priming, d.offsets.len);
        d.next = start;
        d.state.reset();
        d.res_len = 0;
        d.pend_len = 0;
        d.pend_off = 0;
        d.pos = @as(i64, @intCast(start * d.spf)) - @as(i64, @intCast(d.skip));
        d.skip_to = target;
    }

    fn deinit(ptr: *anyopaque) void {
        const d: *Decoder = @ptrCast(@alignCast(ptr));
        if (d.owns_file) bytesrc.close(d.src);
        d.gpa.free(d.offsets);
        d.gpa.destroy(d);
    }
};
