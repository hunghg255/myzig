//! Transfer data (`transfer.zig`) and Windows' formats, both ways: the
//! clipboard written from several formats at once and read by MIME type,
//! and what another app's drag (an IDataObject) offers, decoded the same
//! way. Formats are read through a `Source` (the open clipboard, or a
//! data object), so the decoding is one and is tested without either.
const std = @import("std");
const w = @import("win32.zig");
const transfer = @import("../transfer.zig");
const native = @import("../transfer_native.zig");
const clipboard = @import("clipboard.zig");
const oledrag = @import("oledrag.zig");

extern "user32" fn RegisterClipboardFormatW(name: [*:0]const u16) callconv(.winapi) u32;
extern "user32" fn EnumClipboardFormats(format: u32) callconv(.winapi) u32;
extern "user32" fn GetClipboardFormatNameW(format: u32, name: [*]u16, max: i32) callconv(.winapi) i32;
extern "kernel32" fn GlobalSize(mem: *anyopaque) callconv(.winapi) usize;

/// The registered format of `name`.
pub fn registered(name: []const u8) u32 {
    var buf: [256]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(buf[0..255], name[0..@min(name.len, 120)]) catch return 0;
    buf[n] = 0;
    return RegisterClipboardFormatW(buf[0..n :0]);
}

/// The name of a registered format (0xC000 and up), in `buf`.
pub fn nameOf(cf: u32, buf: []u8) []const u8 {
    if (cf < 0xC000) return "";
    var wide: [256]u16 = undefined;
    const n = GetClipboardFormatNameW(cf, &wide, wide.len);
    if (n <= 0) return "";
    const len = std.unicode.utf16LeToUtf8(buf, wide[0..@intCast(n)]) catch return "";
    return buf[0..len];
}

/// Where formats' bytes come from: `get` copies format `cf`'s bytes into
/// `a`'s memory, or null.
pub const Source = struct {
    ctx: ?*anyopaque,
    get: *const fn (ctx: ?*anyopaque, a: std.mem.Allocator, cf: u32) ?[]u8,
};

/// The bytes of global memory, copied.
pub fn globalBytes(a: std.mem.Allocator, mem: *anyopaque) ?[]u8 {
    const p: [*]const u8 = @ptrCast(w.GlobalLock(mem) orelse return null);
    defer _ = w.GlobalUnlock(mem);
    return a.dupe(u8, p[0..GlobalSize(mem)]) catch null;
}

fn wideText(a: std.mem.Allocator, b: []const u8) ?[]u8 {
    const n = b.len / 2;
    const units = a.alloc(u16, n) catch return null;
    for (units, 0..) |*u, i| u.* = std.mem.readInt(u16, b[i * 2 ..][0..2], .little);
    const end = std.mem.indexOfScalar(u16, units, 0) orelse n;
    return std.unicode.utf16LeToUtf8Alloc(a, units[0..end]) catch null;
}

/// The paths of a DROPFILES (CF_HDROP's bytes), wide or not.
pub fn dropPaths(a: std.mem.Allocator, b: []const u8) ![][]u8 {
    if (b.len < 20) return error.BadDrop;
    const start = std.mem.readInt(u32, b[0..4], .little);
    const wide = std.mem.readInt(u32, b[16..20], .little) != 0;
    var out: std.ArrayList([]u8) = .empty;
    var i: usize = start;
    while (i < b.len) {
        if (wide) {
            var e = i;
            while (e + 1 < b.len and (b[e] != 0 or b[e + 1] != 0)) e += 2;
            if (e == i) break;
            try out.append(a, wideText(a, b[i..e]) orelse return error.BadDrop);
            i = e + 2;
        } else {
            const e = std.mem.indexOfScalarPos(u8, b, i, 0) orelse b.len;
            if (e == i) break;
            try out.append(a, try a.dupe(u8, b[i..e]));
            i = e + 1;
        }
    }
    return out.toOwnedSlice(a);
}

/// The bytes of MIME type `format` from `src`, decoded from the
/// system's format: UTF-8 text, the HTML fragment, PNG (from a DIB too),
/// file URLs for dropped files. Null when `src` has none.
pub fn decode(a: std.mem.Allocator, src: Source, format: []const u8) ?[]u8 {
    if (std.mem.eql(u8, format, transfer.text)) {
        if (src.get(src.ctx, a, native.CF_UNICODETEXT)) |b| return wideText(a, b);
        const b = src.get(src.ctx, a, native.CF_TEXT) orelse return null;
        return a.dupe(u8, std.mem.sliceTo(b, 0)) catch null;
    }
    if (std.mem.eql(u8, format, transfer.html)) {
        const raw = src.get(src.ctx, a, registered("HTML Format")) orelse return null;
        return a.dupe(u8, clipboard.htmlFragment(raw) orelse return null) catch null;
    }
    if (std.mem.eql(u8, format, transfer.png)) {
        if (src.get(src.ctx, a, registered("PNG"))) |b| return b;
        const dib = src.get(src.ctx, a, native.CF_DIB) orelse return null;
        const px = clipboard.dibToPixels(a, dib) catch return null;
        return @import("../ui/png.zig").encode(a, .{ .bytes = px.bytes, .width = px.width, .height = px.height }) catch null;
    }
    if (std.mem.eql(u8, format, transfer.file_list) or std.mem.eql(u8, format, transfer.uri_list)) {
        if (std.mem.eql(u8, format, transfer.uri_list)) {
            if (src.get(src.ctx, a, registered(transfer.uri_list))) |b| return a.dupe(u8, std.mem.sliceTo(b, 0)) catch null;
            if (src.get(src.ctx, a, registered("UniformResourceLocatorW"))) |b| return wideText(a, b);
        }
        const drop = src.get(src.ctx, a, native.CF_HDROP) orelse return null;
        const paths = dropPaths(a, drop) catch return null;
        return native.uriListOf(a, paths) catch null;
    }
    const b = src.get(src.ctx, a, registered(native.windowsName(format))) orelse return null;
    return b;
}

/// The MIME types of Windows formats `cfs`, without repeats.
pub fn formatsOf(a: std.mem.Allocator, cfs: []const u32) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var buf: [512]u8 = undefined;
    for (cfs) |cf| {
        const f = native.ofWindows(cf, nameOf(cf, &buf)) orelse continue;
        try native.addUnique(a, &out, try a.dupe(u8, f));
        if (cf == native.CF_HDROP) try native.addUnique(a, &out, transfer.uri_list);
    }
    return out.toOwnedSlice(a);
}

fn clipboardGet(_: ?*anyopaque, a: std.mem.Allocator, cf: u32) ?[]u8 {
    const mem = w.GetClipboardData(cf) orelse return null;
    return globalBytes(a, mem);
}

/// Replaces the clipboard's contents with `data`'s formats, as other apps
/// read them (text, files, HTML, PNG, MIME types as registered formats).
/// Lazy providers run now.
pub fn writeData(_: std.mem.Allocator, data: *transfer.Data) !void {
    const items = try oledrag.render(data);
    defer {
        for (items) |r| std.heap.c_allocator.free(r.bytes);
        std.heap.c_allocator.free(items);
    }
    if (w.OpenClipboard(null) == 0) return error.Clipboard;
    defer _ = w.CloseClipboard();
    _ = w.EmptyClipboard();
    for (items) |it| {
        const mem = w.GlobalAlloc(0x0002, @max(it.bytes.len, 1)) orelse return error.OutOfMemory;
        const p: [*]u8 = @ptrCast(w.GlobalLock(mem) orelse return error.OutOfMemory);
        @memcpy(p[0..it.bytes.len], it.bytes);
        _ = w.GlobalUnlock(mem);
        _ = w.SetClipboardData(it.cf, mem);
    }
}

/// The MIME types the clipboard offers, in its order. Free with `freeFormats`.
pub fn formats(gpa: std.mem.Allocator) ![][]u8 {
    var cfs: std.ArrayList(u32) = .empty;
    defer cfs.deinit(gpa);
    if (w.OpenClipboard(null) != 0) {
        defer _ = w.CloseClipboard();
        var cf: u32 = 0;
        while (true) {
            cf = EnumClipboardFormats(cf);
            if (cf == 0) break;
            try cfs.append(gpa, cf);
        }
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const fs = try formatsOf(arena.allocator(), cfs.items);
    const out = try gpa.alloc([]u8, fs.len);
    for (fs, out) |f, *o| o.* = try gpa.dupe(u8, f);
    return out;
}

/// The bytes of MIME type `format` on the clipboard, or null. Caller frees them.
pub fn read(gpa: std.mem.Allocator, format: []const u8) !?[]u8 {
    if (w.OpenClipboard(null) == 0) return null;
    defer _ = w.CloseClipboard();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const b = decode(arena.allocator(), .{ .ctx = null, .get = clipboardGet }, format) orelse return null;
    return try gpa.dupe(u8, b);
}

test "formats decoded from a source: text, HTML, dropped files, custom" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Fake = struct {
        fn get(_: ?*anyopaque, al: std.mem.Allocator, cf: u32) ?[]u8 {
            if (cf == native.CF_UNICODETEXT) return al.dupe(u8, std.mem.sliceAsBytes(std.unicode.utf8ToUtf16LeStringLiteral("héllo\x00junk"))) catch null;
            if (cf == native.CF_HDROP) return clipboard.dropFiles(al, &.{ "C:\\a b.txt", "D:\\é" }) catch null;
            if (cf == registered("HTML Format")) return clipboard.encodeHtml(al, "<b>x</b>") catch null;
            if (cf == registered("application/x-note")) return al.dupe(u8, "note") catch null;
            return null;
        }
    };
    const src: Source = .{ .ctx = null, .get = Fake.get };
    try std.testing.expectEqualStrings("héllo", decode(a, src, transfer.text).?);
    try std.testing.expectEqualStrings("<b>x</b>", decode(a, src, transfer.html).?);
    try std.testing.expectEqualStrings("note", decode(a, src, "application/x-note").?);
    try std.testing.expect(decode(a, src, transfer.png) == null);
    const list = decode(a, src, transfer.file_list).?;
    try std.testing.expect(std.mem.indexOf(u8, list, "a%20b.txt\r\n") != null);
    const paths = try dropPaths(a, try clipboard.dropFiles(a, &.{"C:\\x"}));
    try std.testing.expectEqualStrings("C:\\x", paths[0]);
    const fs = try formatsOf(a, &.{ native.CF_UNICODETEXT, native.CF_TEXT, native.CF_HDROP, registered("HTML Format"), registered("Ole Private Data") });
    try std.testing.expectEqual(@as(usize, 4), fs.len);
    try std.testing.expectEqualStrings(transfer.text, fs[0]);
    try std.testing.expectEqualStrings(transfer.html, fs[3]);
}
