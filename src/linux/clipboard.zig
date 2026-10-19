//! The clipboard's other formats on Linux, through GTK (looked up when
//! first used): images (GdkPixbuf, as PNG), files (text/uri-list, and
//! GNOME's x-special/gnome-copied-files for file managers) and HTML
//! (text/html, with text for other apps). What myzig writes it serves
//! from memory until another app takes the clipboard.
const std = @import("std");
const gtk = @import("gtk.zig");

const TargetEntry = extern struct { target: [*:0]const u8, flags: c_uint, info: c_uint };
const GetFn = *const fn (cb: *anyopaque, sd: *anyopaque, info: c_uint, data: ?*anyopaque) callconv(.c) void;
const ClearFn = *const fn (cb: *anyopaque, data: ?*anyopaque) callconv(.c) void;

const Api = struct {
    gtk_clipboard_wait_for_image: *const fn (cb: *anyopaque) callconv(.c) ?*anyopaque,
    gtk_clipboard_set_image: *const fn (cb: *anyopaque, pixbuf: *anyopaque) callconv(.c) void,
    gtk_clipboard_wait_for_uris: *const fn (cb: *anyopaque) callconv(.c) ?[*:null]?[*:0]u8,
    gtk_clipboard_wait_for_contents: *const fn (cb: *anyopaque, target: ?*anyopaque) callconv(.c) ?*anyopaque,
    gtk_clipboard_set_with_data: *const fn (cb: *anyopaque, targets: [*]const TargetEntry, n: c_uint, get: GetFn, clear: ClearFn, data: ?*anyopaque) callconv(.c) c_int,
    gtk_selection_data_get_data: *const fn (sd: *anyopaque) callconv(.c) ?[*]const u8,
    gtk_selection_data_get_length: *const fn (sd: *anyopaque) callconv(.c) c_int,
    gtk_selection_data_get_target: *const fn (sd: *anyopaque) callconv(.c) ?*anyopaque,
    gtk_selection_data_set: *const fn (sd: *anyopaque, kind: ?*anyopaque, format: c_int, data: [*]const u8, len: c_int) callconv(.c) void,
    gtk_selection_data_free: *const fn (sd: *anyopaque) callconv(.c) void,
    gdk_pixbuf_save_to_buffer: *const fn (pixbuf: *anyopaque, buf: *?[*]u8, size: *usize, kind: [*:0]const u8, err: ?*anyopaque, ...) callconv(.c) c_int,
    gdk_pixbuf_loader_new_with_type: *const fn (kind: [*:0]const u8, err: ?*anyopaque) callconv(.c) ?*anyopaque,
    gdk_pixbuf_loader_write: *const fn (loader: *anyopaque, buf: [*]const u8, len: usize, err: ?*anyopaque) callconv(.c) c_int,
    gdk_pixbuf_loader_close: *const fn (loader: *anyopaque, err: ?*anyopaque) callconv(.c) c_int,
    gdk_pixbuf_loader_get_pixbuf: *const fn (loader: *anyopaque) callconv(.c) ?*anyopaque,
    g_filename_from_uri: *const fn (uri: [*:0]const u8, host: ?*anyopaque, err: ?*anyopaque) callconv(.c) ?[*:0]u8,
    g_filename_to_uri: *const fn (path: [*:0]const u8, host: ?[*:0]const u8, err: ?*anyopaque) callconv(.c) ?[*:0]u8,
    g_strfreev: *const fn (v: ?[*:null]?[*:0]u8) callconv(.c) void,
};

var api: Api = undefined;
var loaded = false;

fn board() ?*anyopaque {
    if (!loaded) {
        if (!gtk.load()) return null;
        const lib = std.c.dlopen("libgtk-3.so.0", .{ .NOW = true, .GLOBAL = true }) orelse return null;
        inline for (@typeInfo(Api).@"struct".field_names) |name| {
            const sym = std.c.dlsym(lib, name) orelse return null;
            @field(api, name) = @ptrCast(@alignCast(sym));
        }
        loaded = true;
    }
    return gtk.api.gtk_clipboard_get(gtk.api.gdk_atom_intern("CLIPBOARD", 0));
}

pub fn readImage(gpa: std.mem.Allocator) !?[]u8 {
    const b = board() orelse return null;
    const pixbuf = api.gtk_clipboard_wait_for_image(b) orelse return null;
    defer gtk.api.g_object_unref(pixbuf);
    var buf: ?[*]u8 = null;
    var size: usize = 0;
    if (api.gdk_pixbuf_save_to_buffer(pixbuf, &buf, &size, "png", null, @as(?*anyopaque, null)) == 0) return null;
    defer gtk.api.g_free(buf);
    return try gpa.dupe(u8, (buf orelse return null)[0..size]);
}

pub fn writeImage(_: std.mem.Allocator, png: []const u8) !void {
    const b = board() orelse return error.Clipboard;
    const loader = api.gdk_pixbuf_loader_new_with_type("png", null) orelse return error.Clipboard;
    defer gtk.api.g_object_unref(loader);
    _ = api.gdk_pixbuf_loader_write(loader, png.ptr, png.len, null);
    _ = api.gdk_pixbuf_loader_close(loader, null);
    const pixbuf = api.gdk_pixbuf_loader_get_pixbuf(loader) orelse return error.BadImage;
    api.gtk_clipboard_set_image(b, pixbuf);
}

pub fn readFiles(gpa: std.mem.Allocator) !?[][]u8 {
    const b = board() orelse return null;
    const uris = api.gtk_clipboard_wait_for_uris(b) orelse return null;
    defer api.g_strfreev(uris);
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    var i: usize = 0;
    while (uris[i]) |uri| : (i += 1) {
        const p = api.g_filename_from_uri(uri, null, null) orelse continue;
        defer gtk.api.g_free(p);
        try out.append(gpa, try gpa.dupe(u8, std.mem.span(p)));
    }
    if (out.items.len == 0) {
        out.deinit(gpa);
        return null;
    }
    return try out.toOwnedSlice(gpa);
}

pub fn readHtml(gpa: std.mem.Allocator) !?[]u8 {
    const b = board() orelse return null;
    const sd = api.gtk_clipboard_wait_for_contents(b, gtk.api.gdk_atom_intern("text/html", 0)) orelse return null;
    defer api.gtk_selection_data_free(sd);
    const n = api.gtk_selection_data_get_length(sd);
    if (n <= 0) return null;
    const data = api.gtk_selection_data_get_data(sd) orelse return null;
    return try gpa.dupe(u8, data[0..@intCast(n)]);
}

/// What myzig serves while it owns the clipboard: each target's bytes.
const Offer = struct {
    gpa: std.mem.Allocator,
    bytes: [3][]u8,
};

fn onGet(_: *anyopaque, sd: *anyopaque, info: c_uint, data: ?*anyopaque) callconv(.c) void {
    const o: *Offer = @ptrCast(@alignCast(data));
    if (info >= o.bytes.len) return;
    const b = o.bytes[info];
    api.gtk_selection_data_set(sd, api.gtk_selection_data_get_target(sd), 8, b.ptr, @intCast(b.len));
}

fn onClear(_: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const o: *Offer = @ptrCast(@alignCast(data));
    for (o.bytes) |b| o.gpa.free(b);
    o.gpa.destroy(o);
}

fn offer(gpa: std.mem.Allocator, targets: []const TargetEntry, bytes: [3][]u8) !void {
    const b = board() orelse {
        for (bytes) |x| gpa.free(x);
        return error.Clipboard;
    };
    const o = try gpa.create(Offer);
    o.* = .{ .gpa = gpa, .bytes = bytes };
    if (api.gtk_clipboard_set_with_data(b, targets.ptr, @intCast(targets.len), onGet, onClear, o) == 0) {
        onClear(b, o);
        return error.Clipboard;
    }
}

pub fn writeHtml(gpa: std.mem.Allocator, html: []const u8, text: []const u8) !void {
    const targets = [_]TargetEntry{
        .{ .target = "text/html", .flags = 0, .info = 0 },
        .{ .target = "UTF8_STRING", .flags = 0, .info = 1 },
        .{ .target = "text/plain;charset=utf-8", .flags = 0, .info = 2 },
    };
    const a = try gpa.dupe(u8, html);
    errdefer gpa.free(a);
    const t1 = try gpa.dupe(u8, text);
    errdefer gpa.free(t1);
    try offer(gpa, &targets, .{ a, t1, try gpa.dupe(u8, text) });
}

/// The file URIs of `paths`, one a line: text/uri-list's (CRLF) and
/// GNOME's copied files ("copy" first, LF).
pub fn uriLists(gpa: std.mem.Allocator, paths: []const []const u8) ![2][]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var gnome: std.ArrayList(u8) = .empty;
    errdefer gnome.deinit(gpa);
    try gnome.appendSlice(gpa, "copy");
    for (paths) |p| {
        var buf: [4096]u8 = undefined;
        if (p.len >= buf.len) continue;
        @memcpy(buf[0..p.len], p);
        buf[p.len] = 0;
        const uri = api.g_filename_to_uri(@ptrCast(&buf), null, null) orelse continue;
        defer gtk.api.g_free(uri);
        try list.appendSlice(gpa, std.mem.span(uri));
        try list.appendSlice(gpa, "\r\n");
        try gnome.append(gpa, '\n');
        try gnome.appendSlice(gpa, std.mem.span(uri));
    }
    return .{ try list.toOwnedSlice(gpa), try gnome.toOwnedSlice(gpa) };
}

pub fn writeFiles(gpa: std.mem.Allocator, paths: []const []const u8) !void {
    if (board() == null) return error.Clipboard;
    const lists = try uriLists(gpa, paths);
    const targets = [_]TargetEntry{
        .{ .target = "text/uri-list", .flags = 0, .info = 0 },
        .{ .target = "x-special/gnome-copied-files", .flags = 0, .info = 1 },
    };
    try offer(gpa, &targets, .{ lists[0], lists[1], try gpa.dupe(u8, "") });
}

test "HTML, files and images round trip through a virtual display's clipboard (MYZIG_XVFB=1)" {
    // Only on a display of its own (Xvfb in the container): never the user's clipboard.
    if (std.c.getenv("MYZIG_XVFB") == null) return error.SkipZigTest;
    if (!gtk.load() or gtk.api.gtk_init_check(null, null) == 0) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    try writeHtml(gpa, "<b>Hi</b>", "Hi");
    const html = (try readHtml(gpa)).?;
    defer gpa.free(html);
    try std.testing.expectEqualStrings("<b>Hi</b>", html);
    try writeFiles(gpa, &.{ "/tmp/a b.txt", "/etc/hosts" });
    const files = (try readFiles(gpa)).?;
    defer @import("../dialog_types.zig").freePaths(gpa, files);
    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("/tmp/a b.txt", files[0]);
    var px = [_]u8{ 0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255 };
    const png = try @import("../ui/png.zig").encode(gpa, .{ .bytes = &px, .width = 2, .height = 2 });
    defer gpa.free(png);
    try writeImage(gpa, png);
    const back = (try readImage(gpa)).?;
    defer gpa.free(back);
    const d = try @import("../ui/png_decode.zig").decode(gpa, back);
    defer d.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), d.width);
    try std.testing.expectEqualSlices(u8, &px, d.bgra);
}
