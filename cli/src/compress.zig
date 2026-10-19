//! Deflate, in zlib (PNG), gzip (tar.gz) and raw (zip) containers, and the
//! CRC-32 the containers check with, through std.compress.flate.
const std = @import("std");
const flate = std.compress.flate;

pub const Container = flate.Container;

/// `data` compressed in `container`, at the best compression.
pub fn deflate(gpa: std.mem.Allocator, data: []const u8, container: Container) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // The compressor wants room for a header in its output's buffer.
    try out.ensureUnusedCapacity(64);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var c = try flate.Compress.init(&out.writer, window, container, .best);
    try c.writer.writeAll(data);
    try c.finish();
    return out.toOwnedSlice();
}

/// `data` decompressed (tests read back what they wrote).
pub fn inflate(gpa: std.mem.Allocator, data: []const u8, container: Container) ![]u8 {
    var in: std.Io.Reader = .fixed(data);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var d: flate.Decompress = .init(&in, container, window);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try d.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

pub fn crc32(data: []const u8) u32 {
    return std.hash.Crc32.hash(data);
}

test "deflate round trips" {
    const gpa = std.testing.allocator;
    var text: [5000]u8 = undefined;
    for (&text, 0..) |*b, i| b.* = "myzig apps "[i % 11];
    for ([_]Container{ .zlib, .gzip, .raw }) |c| {
        const z = try deflate(gpa, &text, c);
        defer gpa.free(z);
        try std.testing.expect(z.len < text.len / 4);
        const back = try inflate(gpa, z, c);
        defer gpa.free(back);
        try std.testing.expectEqualSlices(u8, &text, back);
    }
    const empty = try deflate(gpa, "", .gzip);
    defer gpa.free(empty);
    const back = try inflate(gpa, empty, .gzip);
    defer gpa.free(back);
    try std.testing.expectEqual(@as(usize, 0), back.len);
}
