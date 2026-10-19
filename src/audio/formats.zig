//! The formats `Engine.decodeSound` and `openStream` decode, told apart by
//! their first bytes: WAV ("RIFF"), Ogg Vorbis ("OggS"), and MP3 (an ID3v2
//! tag or a layer III frame).
const std = @import("std");
const source = @import("source.zig");
const bytesrc = @import("bytesrc.zig");
const wav = @import("wav.zig");
const vorbis = @import("vorbis.zig");
const mp3 = @import("mp3.zig");

pub const Format = enum { wav, vorbis, mp3 };

pub fn detect(head: []const u8) ?Format {
    if (head.len >= 12 and std.mem.eql(u8, head[0..4], "RIFF") and std.mem.eql(u8, head[8..12], "WAVE")) return .wav;
    if (vorbis.sniff(head)) return .vorbis;
    if (mp3.sniff(head)) return .mp3;
    return null;
}

/// A decoder of `src`, whatever its format; `owns_file`: it closes a file
/// source with itself (also when this fails).
pub fn open(gpa: std.mem.Allocator, src: bytesrc.Src, owns_file: bool) !source.Decoder {
    errdefer if (owns_file) bytesrc.close(src);
    var head: [12]u8 = undefined;
    const n = try bytesrc.readAt(src, &head, 0);
    switch (detect(head[0..n]) orelse return error.UnsupportedFormat) {
        .wav => {
            const d = try wav.Decoder.init(gpa, src);
            d.owns_file = owns_file;
            return d.decoder();
        },
        .vorbis => {
            const d = try vorbis.Decoder.init(gpa, src);
            d.owns_file = owns_file;
            return d.decoder();
        },
        .mp3 => {
            const d = try mp3.Decoder.init(gpa, src);
            d.owns_file = owns_file;
            return d.decoder();
        },
    }
}

test "formats: told apart by their first bytes" {
    try std.testing.expectEqual(Format.wav, detect("RIFF\x00\x00\x00\x00WAVEfmt ").?);
    try std.testing.expectEqual(Format.vorbis, detect("OggS\x00\x02").?);
    try std.testing.expectEqual(Format.mp3, detect("ID3\x04\x00").?);
    try std.testing.expectEqual(Format.mp3, detect("\xff\xfb\x90\x44").?);
    try std.testing.expectEqual(@as(?Format, null), detect("fLaC"));
    try std.testing.expectError(error.UnsupportedFormat, open(std.testing.allocator, .{ .bytes = "fLaC\x00\x00\x00\x22" }, false));
}
