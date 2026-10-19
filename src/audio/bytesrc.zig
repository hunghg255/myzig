//! Bytes at an offset, from memory or from a file, for the decoders of
//! compressed formats (MP3, Ogg Vorbis): the same source as WAV's.
const std = @import("std");
const wav = @import("wav.zig");

pub const Src = wav.Src;

/// Reads at most `buf.len` bytes at `offset`: fewer only at the end.
pub fn readAt(s: Src, buf: []u8, offset: u64) !usize {
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

/// The source's length in bytes.
pub fn size(s: Src) !u64 {
    return switch (s) {
        .bytes => |b| b.len,
        .file => |f| f.file.length(f.io),
    };
}

/// Closes a file source (a stream's, opened for the decoder).
pub fn close(s: Src) void {
    switch (s) {
        .file => |f| f.file.close(f.io),
        .bytes => {},
    }
}
