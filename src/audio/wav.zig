//! WAV files: integer PCM of 8 to 32 bits and 32 or 64 bit floats, decoded
//! from memory or a file as they play; and written, from float samples, as
//! 16 bit PCM or 32 bit floats (what a test sink records).
const std = @import("std");
const source = @import("source.zig");

pub const Error = error{ InvalidWav, UnsupportedEncoding, EndOfStream };

/// What the `fmt ` chunk says, and where the samples are.
pub const Header = struct {
    rate: u32,
    channels: u16,
    bits: u16,
    float: bool,
    /// The data chunk's offset and length in bytes.
    data_start: u64,
    data_len: ?u64,

    pub fn frameBytes(h: Header) u32 {
        return @as(u32, h.channels) * h.bits / 8;
    }

    pub fn frames(h: Header) ?u64 {
        const n = h.data_len orelse return null;
        return n / h.frameBytes();
    }
};

/// Reads bytes at an offset: from memory or from a file.
pub const Src = union(enum) {
    bytes: []const u8,
    file: struct { file: std.Io.File, io: std.Io },

    fn readAt(s: Src, buf: []u8, offset: u64) !usize {
        switch (s) {
            .bytes => |b| {
                if (offset >= b.len) return 0;
                const n = @min(buf.len, b.len - @as(usize, @intCast(offset)));
                @memcpy(buf[0..n], b[@intCast(offset)..][0..n]);
                return n;
            },
            .file => |f| return f.file.readPositionalAll(f.io, buf, offset),
        }
    }

    fn len(s: Src) ?u64 {
        return switch (s) {
            .bytes => |b| b.len,
            .file => null,
        };
    }
};

pub fn parseHeader(s: Src) !Header {
    var riff: [12]u8 = undefined;
    if (try s.readAt(&riff, 0) < 12 or !std.mem.eql(u8, riff[0..4], "RIFF") or !std.mem.eql(u8, riff[8..12], "WAVE")) return error.InvalidWav;
    var off: u64 = 12;
    var fmt: ?Header = null;
    while (true) {
        var h: [8]u8 = undefined;
        if (try s.readAt(&h, off) < 8) return error.InvalidWav;
        const size: u64 = std.mem.readInt(u32, h[4..8], .little);
        off += 8;
        if (std.mem.eql(u8, h[0..4], "fmt ")) {
            if (size < 16 or size > 1 << 16) return error.InvalidWav;
            var b: [40]u8 = @splat(0);
            const got = try s.readAt(b[0..@min(size, 40)], off);
            if (got < 16) return error.InvalidWav;
            var tag = std.mem.readInt(u16, b[0..2], .little);
            const channels = std.mem.readInt(u16, b[2..4], .little);
            const rate = std.mem.readInt(u32, b[4..8], .little);
            const bits = std.mem.readInt(u16, b[14..16], .little);
            // WAVE_FORMAT_EXTENSIBLE: the encoding is its sub format's.
            if (tag == 0xfffe and size >= 40) tag = std.mem.readInt(u16, b[24..26], .little);
            const float = switch (tag) {
                1 => if (bits >= 8 and bits <= 32 and bits % 8 == 0) false else return error.UnsupportedEncoding,
                3 => if (bits == 32 or bits == 64) true else return error.UnsupportedEncoding,
                else => return error.UnsupportedEncoding,
            };
            if (channels < 1 or rate < 1) return error.InvalidWav;
            fmt = .{ .rate = rate, .channels = channels, .bits = bits, .float = float, .data_start = 0, .data_len = null };
        } else if (std.mem.eql(u8, h[0..4], "data")) {
            var hdr = fmt orelse return error.InvalidWav;
            hdr.data_start = off;
            // 0 and 0xffffffff: written as it streamed, to the end.
            hdr.data_len = if (size != 0 and size != 0xffffffff) size else null;
            if (s.len()) |total| hdr.data_len = @min(hdr.data_len orelse total - off, total - off);
            return hdr;
        }
        off += size + (size & 1);
    }
}

/// One sample at `b`, as a float in [-1, 1].
fn sampleAt(h: Header, b: []const u8) f32 {
    const bs = h.bits / 8;
    if (h.float) return if (bs == 4) @bitCast(std.mem.readInt(u32, b[0..4], .little)) else @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, b[0..8], .little))));
    return switch (bs) {
        1 => (@as(f32, @floatFromInt(b[0])) - 128) / 128,
        2 => @as(f32, @floatFromInt(std.mem.readInt(i16, b[0..2], .little))) / 32768,
        3 => @as(f32, @floatFromInt(std.mem.readInt(i24, b[0..3], .little))) / 8388608,
        else => @as(f32, @floatFromInt(std.mem.readInt(i32, b[0..4], .little))) / 2147483648,
    };
}

/// A WAV decoder: reads its source's frames as they play.
pub const Decoder = struct {
    src: Src,
    header: Header,
    pos: u64 = 0,
    buf: [4096]u8 = undefined,
    gpa: std.mem.Allocator,
    /// Closed with the decoder (a stream's file).
    owns_file: bool = false,

    pub fn init(gpa: std.mem.Allocator, src: Src) !*Decoder {
        const d = try gpa.create(Decoder);
        errdefer gpa.destroy(d);
        d.* = .{ .src = src, .header = try parseHeader(src), .gpa = gpa };
        return d;
    }

    pub fn decoder(d: *Decoder) source.Decoder {
        return .{ .ptr = d, .vtable = &vtable, .rate = d.header.rate, .channels = d.header.channels, .frames = d.header.frames() };
    }

    const vtable: source.Decoder.VTable = .{ .read = read, .seek = seek, .deinit = deinit };

    fn read(ptr: *anyopaque, dst: []f32) anyerror!usize {
        const d: *Decoder = @ptrCast(@alignCast(ptr));
        const h = d.header;
        const fb = h.frameBytes();
        var want = dst.len / h.channels;
        if (h.frames()) |n| want = @min(want, n -| d.pos);
        var done: usize = 0;
        while (done < want) {
            const chunk = @min(want - done, d.buf.len / fb);
            const got = try d.src.readAt(d.buf[0 .. chunk * fb], h.data_start + d.pos * fb);
            const frames = got / fb;
            if (frames == 0) break;
            const bs = h.bits / 8;
            for (0..frames * h.channels) |i| dst[(done * h.channels) + i] = sampleAt(h, d.buf[i * bs ..]);
            done += frames;
            d.pos += frames;
            if (frames < chunk) break;
        }
        return done;
    }

    fn seek(ptr: *anyopaque, frame: u64) anyerror!void {
        const d: *Decoder = @ptrCast(@alignCast(ptr));
        d.pos = if (d.header.frames()) |n| @min(frame, n) else frame;
    }

    fn deinit(ptr: *anyopaque) void {
        const d: *Decoder = @ptrCast(@alignCast(ptr));
        if (d.owns_file) switch (d.src) {
            .file => |f| f.file.close(f.io),
            .bytes => {},
        };
        d.gpa.destroy(d);
    }
};

pub const Encoding = enum { pcm16, float32 };

/// Writes `samples` (interleaved floats) as a WAV file.
pub fn write(w: *std.Io.Writer, samples: []const f32, rate: u32, channels: u16, enc: Encoding) !void {
    const bits: u16 = if (enc == .pcm16) 16 else 32;
    const block: u32 = @as(u32, channels) * bits / 8;
    const data_len: u32 = @intCast(samples.len * (bits / 8));
    try w.writeAll("RIFF");
    try w.writeInt(u32, 36 + data_len, .little);
    try w.writeAll("WAVEfmt ");
    try w.writeInt(u32, 16, .little);
    try w.writeInt(u16, if (enc == .pcm16) 1 else 3, .little);
    try w.writeInt(u16, channels, .little);
    try w.writeInt(u32, rate, .little);
    try w.writeInt(u32, rate * block, .little);
    try w.writeInt(u16, @intCast(block), .little);
    try w.writeInt(u16, bits, .little);
    try w.writeAll("data");
    try w.writeInt(u32, data_len, .little);
    for (samples) |s| switch (enc) {
        .pcm16 => try w.writeInt(i16, @intFromFloat(@round(std.math.clamp(s, -1, 1) * 32767)), .little),
        .float32 => try w.writeInt(u32, @bitCast(s), .little),
    };
}

test "WAV: write and decode again, PCM and float" {
    const gpa = std.testing.allocator;
    const samples = [_]f32{ 0, 0.5, -0.5, 1, -1, 0.25 };
    inline for (.{ Encoding.pcm16, Encoding.float32 }) |enc| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try write(&aw.writer, &samples, 22050, 2, enc);
        const d = try Decoder.init(gpa, .{ .bytes = aw.written() });
        const dec = d.decoder();
        defer dec.deinit();
        try std.testing.expectEqual(@as(u32, 22050), dec.rate);
        try std.testing.expectEqual(@as(u16, 2), dec.channels);
        try std.testing.expectEqual(@as(?u64, 3), dec.frames);
        var out: [8]f32 = undefined;
        try std.testing.expectEqual(@as(usize, 3), try dec.read(&out));
        for (samples, out[0..6]) |a, b| try std.testing.expectApproxEqAbs(a, b, 1.0 / 32000.0);
        try std.testing.expectEqual(@as(usize, 0), try dec.read(&out));
        try dec.seek(2);
        try std.testing.expectEqual(@as(usize, 1), try dec.read(&out));
        try std.testing.expectApproxEqAbs(@as(f32, -1), out[0], 1.0 / 32000.0);
    }
}

test "WAV: 8 and 24 bit PCM, extensible headers, chunks before the data" {
    const gpa = std.testing.allocator;
    // 24 bit mono, WAVE_FORMAT_EXTENSIBLE, a LIST chunk first.
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    const w = struct {
        fn int(l: *std.ArrayList(u8), comptime T: type, v: T) void {
            var x: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
            std.mem.writeInt(T, &x, v, .little);
            l.appendSlice(std.testing.allocator, &x) catch unreachable;
        }
    };
    try b.appendSlice(gpa, "RIFF\x00\x00\x00\x00WAVELIST");
    w.int(&b, u32, 3);
    try b.appendSlice(gpa, "abc\x00fmt ");
    w.int(&b, u32, 40);
    w.int(&b, u16, 0xfffe);
    w.int(&b, u16, 1);
    w.int(&b, u32, 48000);
    w.int(&b, u32, 48000 * 3);
    w.int(&b, u16, 3);
    w.int(&b, u16, 24);
    w.int(&b, u16, 22);
    w.int(&b, u16, 24);
    w.int(&b, u32, 4);
    w.int(&b, u16, 1); // PCM
    try b.appendNTimes(gpa, 0, 14);
    try b.appendSlice(gpa, "data");
    w.int(&b, u32, 6);
    w.int(&b, i24, 4194304); // 0.5
    w.int(&b, i24, -8388608); // -1
    const d = try Decoder.init(gpa, .{ .bytes = b.items });
    const dec = d.decoder();
    defer dec.deinit();
    var out: [4]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try dec.read(&out));
    try std.testing.expectEqual(@as(f32, 0.5), out[0]);
    try std.testing.expectEqual(@as(f32, -1), out[1]);
    try std.testing.expectError(error.InvalidWav, parseHeader(.{ .bytes = "RIFX" }));
    const h8 = sampleAt(.{ .rate = 1, .channels = 1, .bits = 8, .float = false, .data_start = 0, .data_len = 1 }, &.{192});
    try std.testing.expectEqual(@as(f32, 0.5), h8);
}
