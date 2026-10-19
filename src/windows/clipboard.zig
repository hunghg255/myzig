//! The clipboard's other formats on Windows: images (the "PNG" format
//! apps like browsers write, else a DIB), files (CF_HDROP, as Explorer
//! copies them) and HTML (the "HTML Format" with its offsets header).
//! The conversions are pure functions, tested without the clipboard.
const std = @import("std");
const w = @import("win32.zig");
const png = @import("../ui/png.zig");
const png_decode = @import("../ui/png_decode.zig");

extern "user32" fn RegisterClipboardFormatW(name: [*:0]const u16) callconv(.winapi) u32;
extern "user32" fn IsClipboardFormatAvailable(format: u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn GlobalSize(mem: *anyopaque) callconv(.winapi) usize;
extern "shell32" fn DragQueryFileW(drop: *anyopaque, index: u32, file: ?[*]u16, size: u32) callconv(.winapi) u32;

const CF_DIB = 8;
const CF_HDROP = 15;
const CF_UNICODETEXT = 13;

fn format(comptime name: []const u8) u32 {
    return RegisterClipboardFormatW(std.unicode.utf8ToUtf16LeStringLiteral(name));
}

/// The bytes of clipboard format `fmt` (open), copied. Caller frees them.
fn read(gpa: std.mem.Allocator, fmt: u32) !?[]u8 {
    const mem = w.GetClipboardData(fmt) orelse return null;
    const p: [*]const u8 = @ptrCast(w.GlobalLock(mem) orelse return null);
    defer _ = w.GlobalUnlock(mem);
    return try gpa.dupe(u8, p[0..GlobalSize(mem)]);
}

/// Global memory holding `bytes`, for SetClipboardData.
fn global(bytes: []const u8) ?*anyopaque {
    const mem = w.GlobalAlloc(0x0002, @max(bytes.len, 1)) orelse return null;
    const p: [*]u8 = @ptrCast(w.GlobalLock(mem) orelse return null);
    @memcpy(p[0..bytes.len], bytes);
    _ = w.GlobalUnlock(mem);
    return mem;
}

/// Replaces the clipboard's contents with `items` (format, bytes).
fn write(items: []const struct { u32, []const u8 }) bool {
    if (w.OpenClipboard(null) == 0) return false;
    defer _ = w.CloseClipboard();
    _ = w.EmptyClipboard();
    for (items) |it| if (global(it[1])) |mem| {
        _ = w.SetClipboardData(it[0], mem);
    };
    return true;
}

/// The clipboard's image as PNG, or null. Caller frees it.
pub fn readImage(gpa: std.mem.Allocator) !?[]u8 {
    if (w.OpenClipboard(null) == 0) return null;
    defer _ = w.CloseClipboard();
    if (try read(gpa, format("PNG"))) |bytes| return bytes;
    const dib = (try read(gpa, CF_DIB)) orelse return null;
    defer gpa.free(dib);
    const px = dibToPixels(gpa, dib) catch return null;
    defer gpa.free(px.bytes);
    return try png.encode(gpa, .{ .bytes = px.bytes, .width = px.width, .height = px.height });
}

/// Puts a PNG image on the clipboard: as "PNG" and as a DIB.
pub fn writeImage(gpa: std.mem.Allocator, bytes: []const u8) !void {
    const d = try png_decode.decode(gpa, bytes);
    defer d.deinit(gpa);
    const dib = try pixelsToDib(gpa, d.bgra, d.width, d.height);
    defer gpa.free(dib);
    if (!write(&.{ .{ format("PNG"), bytes }, .{ CF_DIB, dib } })) return error.Clipboard;
}

/// The paths of the files on the clipboard (copied in Explorer), or null.
pub fn readFiles(gpa: std.mem.Allocator) !?[][]u8 {
    if (IsClipboardFormatAvailable(CF_HDROP) == 0) return null;
    if (w.OpenClipboard(null) == 0) return null;
    defer _ = w.CloseClipboard();
    const drop = w.GetClipboardData(CF_HDROP) orelse return null;
    const n = DragQueryFileW(drop, 0xFFFFFFFF, null, 0);
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    var buf: [32768]u16 = undefined;
    for (0..n) |i| {
        const len = DragQueryFileW(drop, @intCast(i), &buf, buf.len);
        if (len > 0) try out.append(gpa, try std.unicode.utf16LeToUtf8Alloc(gpa, buf[0..len]));
    }
    return try out.toOwnedSlice(gpa);
}

/// Puts files on the clipboard, as Explorer's copy does.
pub fn writeFiles(gpa: std.mem.Allocator, paths: []const []const u8) !void {
    const bytes = try dropFiles(gpa, paths);
    defer gpa.free(bytes);
    if (!write(&.{.{ CF_HDROP, bytes }})) return error.Clipboard;
}

/// The clipboard's HTML (its fragment), or null. Caller frees it.
pub fn readHtml(gpa: std.mem.Allocator) !?[]u8 {
    if (w.OpenClipboard(null) == 0) return null;
    defer _ = w.CloseClipboard();
    const raw = (try read(gpa, format("HTML Format"))) orelse return null;
    defer gpa.free(raw);
    return try gpa.dupe(u8, htmlFragment(raw) orelse return null);
}

/// Puts HTML on the clipboard, with `text` for apps that take text only.
pub fn writeHtml(gpa: std.mem.Allocator, html: []const u8, text: []const u8) !void {
    const cf = try encodeHtml(gpa, html);
    defer gpa.free(cf);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(gpa, text);
    defer gpa.free(wide);
    if (!write(&.{ .{ format("HTML Format"), cf }, .{ CF_UNICODETEXT, std.mem.sliceAsBytes(wide[0 .. wide.len + 1]) } })) return error.Clipboard;
}

/// "HTML Format": a header of byte offsets, then the document with the
/// fragment between its markers.
pub fn encodeHtml(gpa: std.mem.Allocator, fragment: []const u8) ![]u8 {
    const header_len = "Version:0.9\r\nStartHTML:0000000000\r\nEndHTML:0000000000\r\nStartFragment:0000000000\r\nEndFragment:0000000000\r\n".len;
    const pre = "<html><body>\r\n<!--StartFragment-->";
    const post = "<!--EndFragment-->\r\n</body></html>";
    const start_html = header_len;
    const start_frag = start_html + pre.len;
    const end_frag = start_frag + fragment.len;
    const end_html = end_frag + post.len;
    return std.fmt.allocPrint(gpa, "Version:0.9\r\nStartHTML:{d:0>10}\r\nEndHTML:{d:0>10}\r\nStartFragment:{d:0>10}\r\nEndFragment:{d:0>10}\r\n{s}{s}{s}", .{ start_html, end_html, start_frag, end_frag, pre, fragment, post });
}

fn offset(raw: []const u8, key: []const u8) ?usize {
    const i = std.mem.indexOf(u8, raw, key) orelse return null;
    var end = i + key.len;
    while (end < raw.len and std.ascii.isDigit(raw[end])) end += 1;
    return std.fmt.parseInt(usize, raw[i + key.len .. end], 10) catch null;
}

/// The fragment of an "HTML Format", by its offsets (or its markers).
pub fn htmlFragment(raw: []const u8) ?[]const u8 {
    const data = std.mem.sliceTo(raw, 0);
    if (offset(data, "StartFragment:")) |s| if (offset(data, "EndFragment:")) |e| if (s <= e and e <= data.len) return data[s..e];
    const s = std.mem.indexOf(u8, data, "<!--StartFragment-->") orelse return null;
    const e = std.mem.indexOf(u8, data, "<!--EndFragment-->") orelse return null;
    if (e < s) return null;
    return data[s + "<!--StartFragment-->".len .. e];
}

/// DROPFILES and the paths, each NUL-terminated UTF-16, then one more NUL.
pub fn dropFiles(gpa: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var head: [20]u8 = @splat(0);
    std.mem.writeInt(u32, head[0..4], 20, .little); // pFiles
    std.mem.writeInt(u32, head[16..20], 1, .little); // fWide
    try out.appendSlice(gpa, &head);
    for (paths) |p| {
        const wide = try std.unicode.utf8ToUtf16LeAlloc(gpa, p);
        defer gpa.free(wide);
        try out.appendSlice(gpa, std.mem.sliceAsBytes(wide));
        try out.appendSlice(gpa, &.{ 0, 0 });
    }
    try out.appendSlice(gpa, &.{ 0, 0 });
    return out.toOwnedSlice(gpa);
}

pub const Pixels = struct { bytes: []u8, width: usize, height: usize };

/// A DIB (BITMAPINFOHEADER, 24 or 32 bits, rows bottom up or top down)
/// as premultiplied BGRA rows from the top. Caller frees the bytes.
pub fn dibToPixels(gpa: std.mem.Allocator, dib: []const u8) !Pixels {
    if (dib.len < 40) return error.BadImage;
    const size = std.mem.readInt(u32, dib[0..4], .little);
    const width: i32 = std.mem.readInt(i32, dib[4..8], .little);
    const height: i32 = std.mem.readInt(i32, dib[8..12], .little);
    const bits = std.mem.readInt(u16, dib[14..16], .little);
    const compression = std.mem.readInt(u32, dib[16..20], .little);
    if (width <= 0 or height == 0 or (bits != 24 and bits != 32)) return error.BadImage;
    // BI_BITFIELDS puts three masks after a 40-byte header.
    const masks: usize = if (compression == 3 and size == 40) 12 else 0;
    if (compression != 0 and compression != 3) return error.BadImage;
    const wu: usize = @intCast(width);
    const hu: usize = @abs(height);
    const stride = (wu * bits / 8 + 3) & ~@as(usize, 3);
    const start = size + masks;
    if (dib.len < start + stride * hu) return error.BadImage;
    const out = try gpa.alloc(u8, wu * hu * 4);
    var any_alpha = false;
    for (0..hu) |y| {
        const src_row = if (height > 0) hu - 1 - y else y;
        const row = dib[start + src_row * stride ..];
        for (0..wu) |x| {
            const d = out[(y * wu + x) * 4 ..][0..4];
            if (bits == 32) {
                d.* = row[x * 4 ..][0..4].*;
                if (d[3] != 0) any_alpha = true;
            } else d.* = .{ row[x * 3], row[x * 3 + 1], row[x * 3 + 2], 255 };
        }
    }
    // 32-bit DIBs often leave alpha at zero: opaque then.
    if (bits == 32 and !any_alpha) {
        var i: usize = 3;
        while (i < out.len) : (i += 4) out[i] = 255;
    } else if (bits == 32) {
        var i: usize = 0;
        while (i < out.len) : (i += 4) {
            const a: u32 = out[i + 3];
            for (out[i .. i + 3]) |*c| c.* = @intCast(@as(u32, c.*) * a / 255);
        }
    }
    return .{ .bytes = out, .width = wu, .height = hu };
}

/// Premultiplied BGRA rows from the top as a 32-bit DIB (straight alpha,
/// rows bottom up). Caller frees it.
pub fn pixelsToDib(gpa: std.mem.Allocator, bgra: []const u8, width: u32, height: u32) ![]u8 {
    const out = try gpa.alloc(u8, 40 + bgra.len);
    @memset(out[0..40], 0);
    std.mem.writeInt(u32, out[0..4], 40, .little);
    std.mem.writeInt(i32, out[4..8], @intCast(width), .little);
    std.mem.writeInt(i32, out[8..12], @intCast(height), .little);
    std.mem.writeInt(u16, out[12..14], 1, .little);
    std.mem.writeInt(u16, out[14..16], 32, .little);
    std.mem.writeInt(u32, out[20..24], @intCast(bgra.len), .little);
    const row = width * 4;
    for (0..height) |y| {
        const src = bgra[y * row ..][0..row];
        const dst = out[40 + (height - 1 - y) * row ..][0..row];
        var x: usize = 0;
        while (x < row) : (x += 4) {
            const a: u32 = src[x + 3];
            for (0..3) |c| dst[x + c] = if (a == 0) 0 else @intCast(@min(255, (@as(u32, src[x + c]) * 255 + a / 2) / a));
            dst[x + 3] = src[x + 3];
        }
    }
    return out;
}

test "HTML Format: offsets written and read back" {
    const gpa = std.testing.allocator;
    const cf = try encodeHtml(gpa, "<b>Hi</b> &amp; bye");
    defer gpa.free(cf);
    try std.testing.expectEqualStrings("<b>Hi</b> &amp; bye", htmlFragment(cf).?);
    const s = offset(cf, "StartHTML:").?;
    try std.testing.expect(std.mem.startsWith(u8, cf[s..], "<html>"));
    try std.testing.expectEqual(cf.len, offset(cf, "EndHTML:").?);
    try std.testing.expectEqualStrings("x", htmlFragment("<!--StartFragment-->x<!--EndFragment-->").?);
}

test "DROPFILES: wide paths, double terminated" {
    const gpa = std.testing.allocator;
    const b = try dropFiles(gpa, &.{ "C:\\a.txt", "D:\\é" });
    defer gpa.free(b);
    try std.testing.expectEqual(@as(u32, 20), std.mem.readInt(u32, b[0..4], .little));
    try std.testing.expectEqual(@as(usize, 20 + (8 + 1 + 4 + 1 + 1) * 2), b.len);
    try std.testing.expectEqual(@as(u8, 'C'), b[20]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, b[b.len - 4 ..]);
}

test "DIBs to pixels and back, bottom-up rows, alpha" {
    const gpa = std.testing.allocator;
    // Two pixels high: red on top, half-transparent blue below (premultiplied).
    const px = [_]u8{ 0, 0, 255, 255, 64, 0, 0, 128 };
    const dib = try pixelsToDib(gpa, &px, 1, 2);
    defer gpa.free(dib);
    // Bottom-up: the blue row first, straight alpha.
    try std.testing.expectEqual(@as(u8, 128), dib[40 + 0]);
    try std.testing.expectEqual(@as(u8, 255), dib[40 + 6]);
    const back = try dibToPixels(gpa, dib);
    defer gpa.free(back.bytes);
    try std.testing.expectEqual(@as(usize, 2), back.height);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, back.bytes[0..4]);
    try std.testing.expectEqual(@as(u8, 128), back.bytes[7]);
    try std.testing.expect(@abs(@as(i32, back.bytes[4]) - 64) <= 1);
    // 24 bits: opaque.
    var d24: [40 + 4]u8 = @splat(0);
    std.mem.writeInt(u32, d24[0..4], 40, .little);
    std.mem.writeInt(i32, d24[4..8], 1, .little);
    std.mem.writeInt(i32, d24[8..12], 1, .little);
    std.mem.writeInt(u16, d24[14..16], 24, .little);
    d24[40..43].* = .{ 1, 2, 3 };
    const p24 = try dibToPixels(gpa, &d24);
    defer gpa.free(p24.bytes);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, p24.bytes);
}
