//! The clipboard written lazily on macOS: an item's formats with bytes
//! go on its NSPasteboardItem at once, its lazy ones (`transfer.lazy`)
//! through a data provider (NSPasteboardItemDataProvider) whose
//! `pasteboard:item:provideDataForType:` makes them when an app pastes
//! them, once. The data stays (a copy, its providers shared) until every
//! item's provider is finished with (`pasteboardFinishedWithDataProvider:`:
//! another app took the clipboard, or the app quits after rendering).
const std = @import("std");
const objc = @import("objc.zig");
const transfer = @import("transfer.zig");
const native = @import("transfer_native.zig");

const ca = std.heap.c_allocator;

/// The data the providers share, and how many are not finished.
const Offer = struct {
    data: transfer.Data,
    refs: usize,

    fn unref(o: *Offer) void {
        o.refs -= 1;
        if (o.refs > 0) return;
        o.data.deinit();
        ca.destroy(o);
    }
};

/// One item's provider.
const Provider = struct { offer: *Offer, index: usize };

/// Whether `format` travels as a URL (a pasteboard item holds one).
fn isUrl(format: []const u8) bool {
    return std.mem.eql(u8, format, transfer.file_list) or std.mem.eql(u8, format, transfer.uri_list);
}

/// The bytes of `format` an item puts on the pasteboard: a URL list's first.
pub fn itemBytes(format: []const u8, b: []const u8) []const u8 {
    return if (isUrl(format)) b[0 .. std.mem.indexOfAny(u8, b, "\r\n") orelse b.len] else b;
}

fn setData(item: objc.Object, t: []const u8, bytes: []const u8) void {
    const nsdata = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ bytes.ptr, bytes.len });
    _ = objc.msg(objc.BOOL, item, "setData:forType:", .{ nsdata, objc.nsString(t) });
}

fn provideData(self: objc.Object, _: objc.SEL, _: objc.Object, item: objc.Object, ns_type: objc.Object) callconv(.c) void {
    const p = objc.getZig(Provider, self) orelse return;
    var arena = std.heap.ArenaAllocator.init(ca);
    defer arena.deinit();
    const a = arena.allocator();
    const wanted = objc.fromNSString(ns_type);
    if (p.index >= p.offer.data.items.len) return;
    for (p.offer.data.items[p.index]) |r| {
        const t = native.macType(a, r.format) catch continue;
        if (!std.mem.eql(u8, t, wanted)) continue;
        // The provider runs now, once; a failed one gives nothing.
        const b = p.offer.data.itemBytes(p.index, r.format) catch return;
        setData(item, t, itemBytes(r.format, b));
        return;
    }
}

fn finished(self: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const p = objc.getZig(Provider, self) orelse return;
    objc.setZig(self, null);
    p.offer.unref();
    ca.destroy(p);
    objc.release(self);
}

fn providerClass() objc.Class {
    return objc.defineClass(.{
        .name = "MyZigPasteboardProvider",
        .protocols = &.{"NSPasteboardItemDataProvider"},
        .methods = &.{
            .{ .name = "pasteboard:item:provideDataForType:", .imp = &provideData, .types = "v@:@@@" },
            .{ .name = "pasteboardFinishedWithDataProvider:", .imp = &finished, .types = "v@:@" },
        },
    });
}

/// Whether item `i` of `d` has bytes of `format` yet.
fn lazy(d: *const transfer.Data, i: usize, format: []const u8) bool {
    for (d.items[i]) |r| if (std.mem.eql(u8, r.format, format)) return r.bytes == null;
    return false;
}

/// Replaces the clipboard's contents with `data`: one pasteboard item per
/// item, its lazy formats made when an app pastes them (their providers
/// must stay valid while the clipboard is the app's).
pub fn writeData(_: std.mem.Allocator, data: *transfer.Data) !void {
    const pool = objc.Pool.push();
    defer pool.pop();
    var arena = std.heap.ArenaAllocator.init(ca);
    defer arena.deinit();
    const a = arena.allocator();
    const offer = try ca.create(Offer);
    offer.* = .{ .data = try data.clone(ca), .refs = 1 };
    // Our reference: dropped once the items are written.
    defer offer.unref();
    const d = &offer.data;
    const items = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    for (d.items, 0..) |item, i| {
        const pi = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSPasteboardItem"), "alloc", .{}), "init", .{});
        objc.autorelease(pi);
        const later = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
        var any = false;
        for (item) |r| {
            if (std.mem.startsWith(u8, r.format, transfer.value_prefix)) continue; // this process's only
            const t = try native.macType(a, r.format);
            if (lazy(d, i, r.format)) {
                objc.msg(void, later, "addObject:", .{objc.nsString(t)});
                any = true;
                continue;
            }
            const b = d.itemBytes(i, r.format) catch continue;
            setData(pi, t, itemBytes(r.format, b));
            any = true;
        }
        if (objc.msg(objc.NSUInteger, later, "count", .{}) > 0) {
            const p = try ca.create(Provider);
            p.* = .{ .offer = offer, .index = i };
            offer.refs += 1;
            const obj = objc.msg(objc.Object, objc.msg(objc.Object, providerClass(), "alloc", .{}), "init", .{});
            objc.setZig(obj, p);
            // Released when finished with (`finished`).
            if (!objc.msg(objc.BOOL, pi, "setDataProvider:forTypes:", .{ obj, later })) {
                objc.setZig(obj, null);
                offer.refs -= 1;
                ca.destroy(p);
                objc.release(obj);
            }
        }
        if (any) objc.msg(void, items, "addObject:", .{pi});
    }
    const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
    _ = objc.msg(objc.NSInteger, pb, "clearContents", .{});
    if (!objc.msg(objc.BOOL, pb, "writeObjects:", .{items})) return error.Clipboard;
}

test "an item's URL list puts its first URL" {
    try std.testing.expectEqualStrings("file:///a", itemBytes(transfer.file_list, "file:///a\r\nfile:///b\r\n"));
    try std.testing.expectEqualStrings("x\ny", itemBytes(transfer.text, "x\ny"));
}
