//! Transfer data (`transfer.zig`) on GTK's clipboard: written as many
//! targets (`transfer_native.gtkTargets`), whose bytes are made when an
//! app asks (lazy providers run then, once), read by MIME type, and its
//! formats listed. Also what drags (`dnd.zig`) share: GTK's functions
//! for selections, looked up when first used.
const std = @import("std");
const gtk = @import("gtk.zig");
const transfer = @import("../transfer.zig");
const native = @import("../transfer_native.zig");

pub const TargetEntry = extern struct { target: [*:0]const u8, flags: c_uint, info: c_uint };
const GetFn = *const fn (cb: *anyopaque, sd: *anyopaque, info: c_uint, data: ?*anyopaque) callconv(.c) void;
const ClearFn = *const fn (cb: *anyopaque, data: ?*anyopaque) callconv(.c) void;

pub const Api = struct {
    gtk_clipboard_set_with_data: *const fn (cb: *anyopaque, targets: [*]const TargetEntry, n: c_uint, get: GetFn, clear: ClearFn, data: ?*anyopaque) callconv(.c) c_int,
    gtk_clipboard_wait_for_targets: *const fn (cb: *anyopaque, targets: *?[*]?*anyopaque, n: *c_int) callconv(.c) c_int,
    gtk_clipboard_wait_for_contents: *const fn (cb: *anyopaque, target: ?*anyopaque) callconv(.c) ?*anyopaque,
    gtk_selection_data_get_data: *const fn (sd: *anyopaque) callconv(.c) ?[*]const u8,
    gtk_selection_data_get_length: *const fn (sd: *anyopaque) callconv(.c) c_int,
    gtk_selection_data_get_target: *const fn (sd: *anyopaque) callconv(.c) ?*anyopaque,
    gtk_selection_data_set: *const fn (sd: *anyopaque, kind: ?*anyopaque, format: c_int, data: [*]const u8, len: c_int) callconv(.c) void,
    gtk_selection_data_free: *const fn (sd: *anyopaque) callconv(.c) void,
    gdk_atom_name: *const fn (atom: ?*anyopaque) callconv(.c) ?[*:0]u8,
};

pub var api: Api = undefined;
var loaded = false;

pub fn load() bool {
    if (loaded) return true;
    if (!gtk.load()) return false;
    const lib = std.c.dlopen("libgtk-3.so.0", .{ .NOW = true, .GLOBAL = true }) orelse return false;
    inline for (@typeInfo(Api).@"struct".field_names) |name| {
        const sym = std.c.dlsym(lib, name) orelse return false;
        @field(api, name) = @ptrCast(@alignCast(sym));
    }
    loaded = true;
    return true;
}

fn board() ?*anyopaque {
    if (!load()) return null;
    return gtk.api.gtk_clipboard_get(gtk.api.gdk_atom_intern("CLIPBOARD", 0));
}

/// An atom's name, in `a`'s memory.
pub fn atomName(a: std.mem.Allocator, atom: ?*anyopaque) ?[]u8 {
    const n = api.gdk_atom_name(atom) orelse return null;
    defer gtk.api.g_free(n);
    return a.dupe(u8, std.mem.span(n)) catch null;
}

/// The bytes of selection data, copied into `a`'s memory.
pub fn selectionBytes(a: std.mem.Allocator, sd: *anyopaque) ?[]u8 {
    const n = api.gtk_selection_data_get_length(sd);
    if (n < 0) return null;
    const p = api.gtk_selection_data_get_data(sd) orelse return a.dupe(u8, "") catch null;
    return a.dupe(u8, p[0..@intCast(n)]) catch null;
}

/// The bytes a target received carries as MIME type `format`: GNOME's
/// copied files become a URI list.
pub fn fromTarget(a: std.mem.Allocator, target: []const u8, bytes: []const u8) []const u8 {
    if (!std.mem.eql(u8, target, "x-special/gnome-copied-files")) return bytes;
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, bytes, '\n');
    _ = it.next(); // "copy" or "cut"
    while (it.next()) |line| {
        out.appendSlice(a, line) catch return bytes;
        out.appendSlice(a, "\r\n") catch return bytes;
    }
    return out.items;
}

/// One target offered for one format of the data.
pub const Entry = struct { target: [:0]u8, format: []u8 };

/// The targets `data` offers, each once: its formats' GTK names. In `a`'s memory.
pub fn entriesOf(a: std.mem.Allocator, data: *const transfer.Data) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    const fs = try data.formats(a);
    for (fs) |f| {
        if (std.mem.startsWith(u8, f, transfer.value_prefix)) continue; // this process's only
        const named = native.gtkTargets(f);
        const own = [_][:0]const u8{try native.dupeZ(a, f)};
        const targets: []const [:0]const u8 = if (named.len > 0) named else &own;
        for (targets) |t| {
            for (out.items) |e| {
                if (std.mem.eql(u8, e.target, t)) break;
            } else try out.append(a, .{ .target = try native.dupeZ(a, t), .format = try a.dupe(u8, f) });
        }
    }
    return out.toOwnedSlice(a);
}

/// The bytes target `e` serves from `data` (lazy providers run now).
pub fn serve(a: std.mem.Allocator, data: *transfer.Data, e: Entry) ?[]const u8 {
    const b = data.read(a, e.format) catch return null;
    if (std.mem.eql(u8, e.target, "x-special/gnome-copied-files")) return native.gnomeCopied(a, b) catch null;
    return b;
}

/// What myzig serves while it owns the clipboard.
const Offer = struct {
    arena: std.heap.ArenaAllocator,
    data: transfer.Data,
    entries: []Entry,
};

fn onGet(_: *anyopaque, sd: *anyopaque, info: c_uint, ctx: ?*anyopaque) callconv(.c) void {
    const o: *Offer = @ptrCast(@alignCast(ctx));
    if (info >= o.entries.len) return;
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const b = serve(arena.allocator(), &o.data, o.entries[info]) orelse return;
    api.gtk_selection_data_set(sd, api.gtk_selection_data_get_target(sd), 8, b.ptr, @intCast(b.len));
}

fn onClear(_: *anyopaque, ctx: ?*anyopaque) callconv(.c) void {
    const o: *Offer = @ptrCast(@alignCast(ctx));
    o.data.deinit();
    o.arena.deinit();
    std.heap.c_allocator.destroy(o);
}

/// Replaces the clipboard's contents with `data` (copied; lazy providers
/// run when an app asks for their format, so what they read must live
/// while the clipboard is the app's).
pub fn writeData(_: std.mem.Allocator, data: *transfer.Data) !void {
    const b = board() orelse return error.Clipboard;
    const ca = std.heap.c_allocator;
    const o = try ca.create(Offer);
    o.arena = .init(ca);
    errdefer {
        o.arena.deinit();
        ca.destroy(o);
    }
    const a = o.arena.allocator();
    o.entries = try entriesOf(a, data);
    o.data = try data.clone(ca);
    const table = try a.alloc(TargetEntry, o.entries.len);
    for (o.entries, table, 0..) |e, *t, i| t.* = .{ .target = e.target.ptr, .flags = 0, .info = @intCast(i) };
    if (api.gtk_clipboard_set_with_data(b, table.ptr, @intCast(table.len), onGet, onClear, o) == 0) {
        o.data.deinit();
        return error.Clipboard;
    }
}

/// The MIME types the clipboard offers. Free with `transfer.freeFormats`.
pub fn formats(gpa: std.mem.Allocator) ![][]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var list: std.ArrayList([]const u8) = .empty;
    if (board()) |b| {
        var atoms: ?[*]?*anyopaque = null;
        var n: c_int = 0;
        if (api.gtk_clipboard_wait_for_targets(b, &atoms, &n) != 0) if (atoms) |p| {
            defer gtk.api.g_free(@ptrCast(p));
            for (p[0..@intCast(n)]) |atom| {
                const name = atomName(a, atom) orelse continue;
                if (native.ofGtk(name)) |f| try native.addUnique(a, &list, f);
            }
        };
    }
    const out = try gpa.alloc([]u8, list.items.len);
    for (list.items, out) |f, *o| o.* = try gpa.dupe(u8, f);
    return out;
}

/// The bytes of MIME type `format` on the clipboard, or null. Caller frees them.
pub fn read(gpa: std.mem.Allocator, format: []const u8) !?[]u8 {
    const b = board() orelse return null;
    if (std.mem.eql(u8, format, transfer.text)) {
        const s = gtk.api.gtk_clipboard_wait_for_text(b) orelse return null;
        defer gtk.api.g_free(s);
        return try gpa.dupe(u8, std.mem.span(s));
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const named = native.gtkTargets(format);
    const own = [_][:0]const u8{try native.dupeZ(a, format)};
    const uri = [_][:0]const u8{"text/uri-list"};
    const targets: []const [:0]const u8 = if (std.mem.eql(u8, format, transfer.uri_list)) &uri else if (named.len > 0) named else &own;
    for (targets) |t| {
        const sd = api.gtk_clipboard_wait_for_contents(b, gtk.api.gdk_atom_intern(t.ptr, 0)) orelse continue;
        defer api.gtk_selection_data_free(sd);
        const bytes = selectionBytes(a, sd) orelse continue;
        return try gpa.dupe(u8, fromTarget(a, t, bytes));
    }
    return null;
}

test "data offers each format under GTK's targets, served on request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try transfer.fileData(std.testing.allocator, &.{"/tmp/a b"});
    defer d.deinit();
    const es = try entriesOf(a, &d);
    // file_list and uri_list share text/uri-list.
    try std.testing.expectEqual(@as(usize, 2), es.len);
    try std.testing.expectEqualStrings("text/uri-list", es[0].target);
    const gnome = serve(a, &d, es[1]).?;
    try std.testing.expectEqualStrings("copy\nfile:///tmp/a%20b", gnome);
    try std.testing.expectEqualStrings("file:///tmp/a%20b\r\n", fromTarget(a, "x-special/gnome-copied-files", gnome));
    var t = try transfer.Data.init(std.testing.allocator, &.{.{ .reps = &.{ transfer.bytes(transfer.text, "hi"), transfer.bytes("application/x-note", "n") } }});
    defer t.deinit();
    const te = try entriesOf(a, &t);
    try std.testing.expectEqual(native.gtkTargets(transfer.text).len + 1, te.len);
    try std.testing.expectEqualStrings("hi", serve(a, &t, te[1]).?);
    try std.testing.expectEqualStrings("application/x-note", te[te.len - 1].target);
}
