//! App icons from one square PNG: macOS's .icns, Windows' .ico and the
//! images of its icon resources, Linux's sizes (after mygo's icon.go).
const std = @import("std");
const png = @import("png.zig");

/// The entries of an .icns, with PNG payloads. icp4 and icp5 (16 and 32
/// pixels) are left out: IconServices reads their payloads as the old
/// ARGB format even when they hold a PNG; macOS scales ic11 and ic12 down.
const icns_entries = [_]struct { []const u8, u32 }{
    .{ "ic11", 32 }, .{ "ic12", 64 }, .{ "ic07", 128 }, .{ "ic13", 256 }, .{ "ic08", 256 },
    .{ "ic14", 512 }, .{ "ic09", 512 }, .{ "ic10", 1024 },
};

/// The sizes of Windows icons, in pixels.
pub const windows_sizes = [_]u32{ 16, 24, 32, 48, 64, 128, 256 };

/// Renders an .icns.
pub fn icns(gpa: std.mem.Allocator, src_png: []const u8) ![]u8 {
    const src = try png.Source.init(gpa, src_png);
    defer src.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "icns\x00\x00\x00\x00");
    for (icns_entries) |e| {
        const p = try src.png(gpa, e[1]);
        defer gpa.free(p);
        try out.appendSlice(gpa, e[0]);
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(p.len + 8), .big);
        try out.appendSlice(gpa, &len);
        try out.appendSlice(gpa, p);
    }
    std.mem.writeInt(u32, out.items[4..8], @intCast(out.items.len), .big);
    return out.toOwnedSlice(gpa);
}

/// The PNG images of a Windows icon, at `windows_sizes`.
pub fn windowsImages(gpa: std.mem.Allocator, src_png: []const u8) ![windows_sizes.len][]u8 {
    const src = try png.Source.init(gpa, src_png);
    defer src.deinit(gpa);
    var images: [windows_sizes.len][]u8 = undefined;
    for (windows_sizes, &images) |n, *img| img.* = try src.png(gpa, n);
    return images;
}

/// The 16-byte directory entry of an icon image (ICONDIRENTRY, and with
/// `id` the resource's GRPICONDIRENTRY, 14 bytes).
pub fn dirEntry(out: *std.ArrayList(u8), gpa: std.mem.Allocator, n: u32, len: usize, last: union(enum) { offset: u32, id: u16 }) !void {
    const dim: u8 = if (n >= 256) 0 else @intCast(n);
    var b: [16]u8 = undefined;
    b[0..4].* = .{ dim, dim, 0, 0 };
    std.mem.writeInt(u16, b[4..6], 1, .little); // planes
    std.mem.writeInt(u16, b[6..8], 32, .little); // bits per pixel
    std.mem.writeInt(u32, b[8..12], @intCast(len), .little);
    switch (last) {
        .offset => |o| {
            std.mem.writeInt(u32, b[12..16], o, .little);
            try out.appendSlice(gpa, &b);
        },
        .id => |id| {
            std.mem.writeInt(u16, b[12..14], id, .little);
            try out.appendSlice(gpa, b[0..14]);
        },
    }
}

/// An .ico of PNG images (the installer's icon).
pub fn ico(gpa: std.mem.Allocator, src_png: []const u8) ![]u8 {
    const images = try windowsImages(gpa, src_png);
    defer for (images) |i| gpa.free(i);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var head: [6]u8 = undefined;
    std.mem.writeInt(u16, head[0..2], 0, .little);
    std.mem.writeInt(u16, head[2..4], 1, .little);
    std.mem.writeInt(u16, head[4..6], images.len, .little);
    try out.appendSlice(gpa, &head);
    var offset: u32 = 6 + 16 * images.len;
    for (images, windows_sizes) |img, n| {
        try dirEntry(&out, gpa, n, img.len, .{ .offset = offset });
        offset += @intCast(img.len);
    }
    for (images) |img| try out.appendSlice(gpa, img);
    return out.toOwnedSlice(gpa);
}

test icns {
    const gpa = std.testing.allocator;
    const src = try png.testIcon(gpa, 64, .{ 0, 120, 255 });
    defer gpa.free(src);
    const data = try icns(gpa, src);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("icns", data[0..4]);
    try std.testing.expectEqual(@as(u32, @intCast(data.len)), std.mem.readInt(u32, data[4..8], .big));
    // Walk the entries: each a known type holding a PNG of its size.
    var at: usize = 8;
    var i: usize = 0;
    while (at < data.len) : (i += 1) {
        try std.testing.expectEqualStrings(icns_entries[i][0], data[at..][0..4]);
        const len = std.mem.readInt(u32, data[at + 4 ..][0..4], .big);
        const w, _ = try png.size(data[at + 8 .. at + len]);
        try std.testing.expectEqual(icns_entries[i][1], w);
        at += len;
    }
    try std.testing.expectEqual(icns_entries.len, i);
}

test ico {
    const gpa = std.testing.allocator;
    const src = try png.testIcon(gpa, 32, .{ 10, 200, 90 });
    defer gpa.free(src);
    const data = try ico(gpa, src);
    defer gpa.free(data);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, data[2..4], .little));
    try std.testing.expectEqual(@as(u16, windows_sizes.len), std.mem.readInt(u16, data[4..6], .little));
    for (windows_sizes, 0..) |n, k| {
        const e = data[6 + 16 * k ..][0..16];
        try std.testing.expectEqual(if (n >= 256) @as(u8, 0) else @as(u8, @intCast(n)), e[0]);
        const len = std.mem.readInt(u32, e[8..12], .little);
        const off = std.mem.readInt(u32, e[12..16], .little);
        const w, _ = try png.size(data[off .. off + len]);
        try std.testing.expectEqual(n, w);
    }
}
