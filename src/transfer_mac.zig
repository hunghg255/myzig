//! Transfer data (`transfer.zig`) on macOS's pasteboards: the clipboard
//! written as one NSPasteboardItem per item with each of its formats
//! (`transfer_native.macType`; lazy providers run now), read by MIME
//! type and its formats listed; and what drags (`dnd_mac.zig`) share:
//! a pasteboard's data as transfer data, and items for one.
const std = @import("std");
const objc = @import("objc.zig");
const transfer = @import("transfer.zig");
const native = @import("transfer_native.zig");

fn general() objc.Object {
    return objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
}

/// NSPasteboardItems of `data`'s items, autoreleased.
pub fn pasteboardItems(a: std.mem.Allocator, data: *transfer.Data) !objc.Object {
    const items = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    for (data.items, 0..) |item, i| {
        const pi = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSPasteboardItem"), "alloc", .{}), "init", .{});
        objc.autorelease(pi);
        var any = false;
        for (item) |r| {
            if (std.mem.startsWith(u8, r.format, transfer.value_prefix)) continue; // this process's only
            const b = data.itemBytes(i, r.format) catch continue;
            const t = try native.macType(a, r.format);
            // A pasteboard item holds one URL: an item's first.
            const url = std.mem.eql(u8, r.format, transfer.file_list) or std.mem.eql(u8, r.format, transfer.uri_list);
            const bytes = if (url) b[0 .. std.mem.indexOfAny(u8, b, "\r\n") orelse b.len] else b;
            const nsdata = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ bytes.ptr, bytes.len });
            if (objc.msg(objc.BOOL, pi, "setData:forType:", .{ nsdata, objc.nsString(t) })) any = true;
        }
        if (any) objc.msg(void, items, "addObject:", .{pi});
    }
    return items;
}

/// The MIME types a pasteboard offers.
pub fn formatsOf(a: std.mem.Allocator, pb: objc.Object) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const types = objc.msg(?objc.Object, pb, "types", .{}) orelse return out.toOwnedSlice(a);
    const n = objc.msg(objc.NSUInteger, types, "count", .{});
    for (0..n) |i| {
        const t = objc.fromNSString(objc.msg(?objc.Object, types, "objectAtIndex:", .{i}));
        const f = (try native.ofMac(a, t)) orelse continue;
        try native.addUnique(a, &out, try a.dupe(u8, f));
    }
    return out.toOwnedSlice(a);
}

/// The URLs on a pasteboard (files only, or any), a line each (CRLF).
fn urls(a: std.mem.Allocator, pb: objc.Object, files_only: bool) !?[]u8 {
    const classes = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{objc.class("NSURL")});
    const list = objc.msg(?objc.Object, pb, "readObjectsForClasses:options:", .{ classes, @as(?objc.Object, null) }) orelse return null;
    var out: std.ArrayList(u8) = .empty;
    const n = objc.msg(objc.NSUInteger, list, "count", .{});
    for (0..n) |i| {
        const url = objc.msg(objc.Object, list, "objectAtIndex:", .{i});
        if (files_only and !objc.msg(objc.BOOL, url, "isFileURL", .{})) continue;
        try out.appendSlice(a, objc.fromNSString(objc.msg(?objc.Object, url, "absoluteString", .{})));
        try out.appendSlice(a, "\r\n");
    }
    if (out.items.len == 0) return null;
    return out.items;
}

/// The bytes of MIME type `format` on pasteboard `pb`, in `a`'s memory.
pub fn readFrom(a: std.mem.Allocator, pb: objc.Object, format: []const u8) !?[]u8 {
    if (std.mem.eql(u8, format, transfer.file_list)) return urls(a, pb, true);
    if (std.mem.eql(u8, format, transfer.uri_list)) return urls(a, pb, false);
    if (std.mem.eql(u8, format, transfer.text)) {
        const s = objc.msg(?objc.Object, pb, "stringForType:", .{objc.nsString("public.utf8-plain-text")}) orelse return null;
        return try a.dupe(u8, objc.fromNSString(s));
    }
    const d = objc.msg(?objc.Object, pb, "dataForType:", .{objc.nsString(try native.macType(a, format))}) orelse return null;
    const len = objc.msg(objc.NSUInteger, d, "length", .{});
    if (len == 0) return try a.dupe(u8, "");
    const p = objc.msg([*]const u8, d, "bytes", .{});
    return try a.dupe(u8, p[0..len]);
}

/// Every format on pasteboard `pb`, read now, as one item.
pub fn dataOf(gpa: std.mem.Allocator, pb: objc.Object) !transfer.Data {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var reps: std.ArrayList(transfer.Rep) = .empty;
    for (try formatsOf(a, pb)) |f| if (try readFrom(a, pb, f)) |b| try reps.append(a, transfer.bytes(f, b));
    return transfer.Data.init(gpa, &.{.{ .reps = reps.items }});
}

/// Replaces the clipboard's contents with `data`, one pasteboard item per item.
pub fn writeData(gpa: std.mem.Allocator, data: *transfer.Data) !void {
    const pool = objc.Pool.push();
    defer pool.pop();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = try pasteboardItems(arena.allocator(), data);
    const pb = general();
    _ = objc.msg(objc.NSInteger, pb, "clearContents", .{});
    if (!objc.msg(objc.BOOL, pb, "writeObjects:", .{items})) return error.Clipboard;
}

/// The MIME types the clipboard offers. Free with `transfer.freeFormats`.
pub fn formats(gpa: std.mem.Allocator) ![][]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const fs = try formatsOf(arena.allocator(), general());
    const out = try gpa.alloc([]u8, fs.len);
    for (fs, out) |f, *o| o.* = try gpa.dupe(u8, f);
    return out;
}

/// The bytes of MIME type `format` on the clipboard, or null. Caller frees them.
pub fn read(gpa: std.mem.Allocator, format: []const u8) !?[]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const b = (try readFrom(arena.allocator(), general(), format)) orelse return null;
    return try gpa.dupe(u8, b);
}
