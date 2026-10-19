//! What windows do beyond showing content on Linux: files dropped on them
//! (text/uri-list drags from file managers), looked up in GTK when first
//! used.
const std = @import("std");
const gtk = @import("gtk.zig");

const Api = struct {
    gtk_drag_dest_set: *const fn (w: *gtk.Widget, flags: c_int, targets: ?*const anyopaque, n: c_int, actions: c_int) callconv(.c) void,
    gtk_drag_dest_add_uri_targets: *const fn (w: *gtk.Widget) callconv(.c) void,
    gtk_selection_data_get_uris: *const fn (sd: *anyopaque) callconv(.c) ?[*:null]?[*:0]u8,
    g_strfreev: *const fn (v: ?[*:null]?[*:0]u8) callconv(.c) void,
    g_filename_from_uri: *const fn (uri: [*:0]const u8, host: ?*anyopaque, err: ?*anyopaque) callconv(.c) ?[*:0]u8,
};

var api: Api = undefined;
var loaded = false;

fn load() bool {
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

pub const DropFn = *const fn (ctx: *anyopaque, paths: []const []const u8) void;

/// Lets `widget` take dropped files; `func(ctx, paths)` gets their paths.
pub fn acceptDrops(widget: *gtk.Widget, ctx: *anyopaque, func: DropFn) void {
    if (!load()) return;
    const holder = std.heap.c_allocator.create(Holder) catch return;
    holder.* = .{ .ctx = ctx, .func = func };
    // GTK_DEST_DEFAULT_ALL, GDK_ACTION_COPY
    api.gtk_drag_dest_set(widget, 7, null, 0, 2);
    api.gtk_drag_dest_add_uri_targets(widget);
    gtk.connect(widget, "drag-data-received", @ptrCast(&onReceived), holder);
    gtk.connect(widget, "destroy", @ptrCast(&onDestroy), holder);
}

const Holder = struct { ctx: *anyopaque, func: DropFn };

fn onDestroy(_: *gtk.Widget, data: ?*anyopaque) callconv(.c) void {
    const h: *Holder = @ptrCast(@alignCast(data));
    std.heap.c_allocator.destroy(h);
}

fn onReceived(_: *gtk.Widget, _: ?*anyopaque, _: c_int, _: c_int, sd: ?*anyopaque, _: c_uint, _: c_uint, data: ?*anyopaque) callconv(.c) void {
    const h: *Holder = @ptrCast(@alignCast(data));
    const uris = api.gtk_selection_data_get_uris(sd orelse return) orelse return;
    defer api.g_strfreev(uris);
    var paths: [64][]const u8 = undefined;
    var owned: [64][*:0]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (uris[i]) |uri| : (i += 1) {
        if (n == paths.len) break;
        const p = api.g_filename_from_uri(uri, null, null) orelse continue;
        owned[n] = p;
        paths[n] = std.mem.span(p);
        n += 1;
    }
    defer for (owned[0..n]) |p| gtk.api.g_free(p);
    if (n > 0) h.func(h.ctx, paths[0..n]);
}
