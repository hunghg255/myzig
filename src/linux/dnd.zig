//! Drag and drop with other apps on Linux, through GTK: drags from them
//! over a window's native UI reach its `ui.DragDrop` targets (a drag
//! destination on its drawing area: the formats on entering, the bytes
//! asked for at the drop), and drags leaving it go on in GTK's drag
//! (`ui.DragDrop.external`), each format's bytes made when the app it
//! drops on asks.
const std = @import("std");
const gtk = @import("gtk.zig");
const sel = @import("transfer_gtk.zig");
const transfer = @import("../transfer.zig");
const native = @import("../transfer_native.zig");
const dragdrop = @import("../ui/dragdrop.zig");
const Point = @import("../ui/types.zig").Point;

const Api = struct {
    gtk_drag_dest_set: *const fn (w: *gtk.Widget, flags: c_int, targets: ?*const anyopaque, n: c_int, actions: c_int) callconv(.c) void,
    gtk_drag_get_data: *const fn (w: *gtk.Widget, ctx: *anyopaque, target: ?*anyopaque, time: c_uint) callconv(.c) void,
    gtk_drag_finish: *const fn (ctx: *anyopaque, success: c_int, del: c_int, time: c_uint) callconv(.c) void,
    gtk_drag_begin_with_coordinates: *const fn (w: *gtk.Widget, targets: *anyopaque, actions: c_int, button: c_int, event: ?*anyopaque, x: c_int, y: c_int) callconv(.c) ?*anyopaque,
    gtk_target_list_new: *const fn (targets: [*]const sel.TargetEntry, n: c_uint) callconv(.c) ?*anyopaque,
    gtk_target_list_unref: *const fn (list: *anyopaque) callconv(.c) void,
    gdk_drag_context_list_targets: *const fn (ctx: *anyopaque) callconv(.c) ?*List,
    gdk_drag_context_get_actions: *const fn (ctx: *anyopaque) callconv(.c) c_int,
    gdk_drag_context_get_suggested_action: *const fn (ctx: *anyopaque) callconv(.c) c_int,
    gdk_drag_context_get_selected_action: *const fn (ctx: *anyopaque) callconv(.c) c_int,
    gdk_drag_status: *const fn (ctx: *anyopaque, action: c_int, time: c_uint) callconv(.c) void,
    gdk_drag_context_get_device: *const fn (ctx: *anyopaque) callconv(.c) ?*anyopaque,
    gdk_device_get_position: *const fn (device: *anyopaque, screen: ?*?*anyopaque, x: *c_int, y: *c_int) callconv(.c) void,
};

const List = extern struct { data: ?*anyopaque, next: ?*List, prev: ?*List };

var api: Api = undefined;
var loaded = false;

fn load() bool {
    if (loaded) return true;
    if (!sel.load()) return false;
    const lib = std.c.dlopen("libgtk-3.so.0", .{ .NOW = true, .GLOBAL = true }) orelse return false;
    inline for (@typeInfo(Api).@"struct".field_names) |name| {
        const sym = std.c.dlsym(lib, name) orelse return false;
        @field(api, name) = @ptrCast(@alignCast(sym));
    }
    loaded = true;
    return true;
}

const copy_action: c_int = 1 << 1;
const move_action: c_int = 1 << 2;
const link_action: c_int = 1 << 3;

/// GDK's actions as transfer's effects, and back.
pub fn effectsOf(actions: c_int) transfer.Effects {
    return .{ .copy = actions & copy_action != 0, .move = actions & move_action != 0, .link = actions & link_action != 0 };
}

pub fn effectOf(action: c_int) ?transfer.Effect {
    if (action & move_action != 0) return .move;
    if (action & copy_action != 0) return .copy;
    if (action & link_action != 0) return .link;
    return null;
}

pub fn actionOf(e: transfer.Effect) c_int {
    return switch (e) {
        .none => 0,
        .copy => copy_action,
        .move => move_action,
        .link => link_action,
    };
}

pub fn actionsOf(e: transfer.Effects) c_int {
    return (if (e.copy) copy_action else 0) | (if (e.move) move_action else 0) | (if (e.link) link_action else 0);
}

/// A window's drawing area and what drags over it reach.
const Link = struct {
    widget: *gtk.Widget,
    win: *anyopaque,
    redraw: *const fn (win: *anyopaque) void,
    /// Takes drops from other apps (`accept`).
    dd: ?*dragdrop.DragDrop = null,
    /// Drops from other apps: the drag over it, and at the drop the
    /// targets asked for and the bytes they brought.
    over: ?*anyopaque = null,
    leaving: bool = false,
    at: Point = .{},
    arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator),
    asked: std.ArrayList(sel.Entry) = .empty,
    got: std.ArrayList(transfer.Rep) = .empty,
    pending: usize = 0,
    /// A drag of its own out of the window.
    out: ?*dragdrop.DragDrop = null,
    out_entries: []sel.Entry = &.{},
    out_failed: bool = false,
    /// The drag out was given up (Escape), not let go over no target.
    out_escaped: bool = false,
};

var links: std.ArrayList(*Link) = .empty;

fn linkOf(widget: *gtk.Widget, win: *anyopaque, redraw: *const fn (*anyopaque) void) ?*Link {
    for (links.items) |l| if (l.widget == widget) return l;
    if (!load()) return null;
    const l = std.heap.c_allocator.create(Link) catch return null;
    l.* = .{ .widget = widget, .win = win, .redraw = redraw };
    links.append(std.heap.c_allocator, l) catch {
        std.heap.c_allocator.destroy(l);
        return null;
    };
    gtk.connect(widget, "drag-data-get", @ptrCast(&onDataGet), l);
    gtk.connect(widget, "drag-end", @ptrCast(&onDragEnd), l);
    gtk.connect(widget, "drag-failed", @ptrCast(&onDragFailed), l);
    return l;
}

/// Lets drags from other apps drop on `dd`'s targets in `widget` (a
/// window's drawing area); `redraw(win)` draws a frame.
pub fn accept(widget: *gtk.Widget, dd: *dragdrop.DragDrop, win: *anyopaque, redraw: *const fn (*anyopaque) void) void {
    const l = linkOf(widget, win, redraw) orelse return;
    if (l.dd != null) {
        l.dd = dd;
        return;
    }
    l.dd = dd;
    // No default behavior: motion, drops and their data are ours.
    api.gtk_drag_dest_set(widget, 0, null, 0, copy_action | move_action | link_action);
    gtk.connect(widget, "drag-motion", @ptrCast(&onMotion), l);
    gtk.connect(widget, "drag-leave", @ptrCast(&onLeave), l);
    gtk.connect(widget, "drag-drop", @ptrCast(&onDrop), l);
    gtk.connect(widget, "drag-data-received", @ptrCast(&onReceived), l);
}

fn noBytes(_: *u8, _: std.mem.Allocator) anyerror![]u8 {
    return error.FormatUnavailable;
}
var no_bytes_ctx: u8 = 0;

/// The MIME types a drag offers and the target each is asked for by.
fn offered(a: std.mem.Allocator, ctx: *anyopaque) ![]sel.Entry {
    var out: std.ArrayList(sel.Entry) = .empty;
    var it = api.gdk_drag_context_list_targets(ctx);
    while (it) |node| : (it = node.next) {
        const name = sel.atomName(a, node.data) orelse continue;
        const f = native.ofGtk(name) orelse continue;
        for (out.items) |e| {
            if (std.mem.eql(u8, e.format, f)) break;
        } else try out.append(a, .{ .target = try native.dupeZ(a, name), .format = try a.dupe(u8, f) });
    }
    return out.toOwnedSlice(a);
}

fn enter(l: *Link, ctx: *anyopaque) void {
    const dd = l.dd orelse return;
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fs = offered(a, ctx) catch return;
    // The formats now; their bytes are asked for at the drop.
    const reps = a.alloc(transfer.Rep, fs.len) catch return;
    for (fs, reps) |e, *r| r.* = transfer.lazy(e.format, .of(&no_bytes_ctx, noBytes));
    const data = transfer.Data.init(std.heap.c_allocator, &.{.{ .reps = reps }}) catch return;
    dd.externalEnter(data, effectsOf(api.gdk_drag_context_get_actions(ctx)), l.at);
}

fn onMotion(_: *gtk.Widget, ctx: *anyopaque, x: c_int, y: c_int, time: c_uint, data: ?*anyopaque) callconv(.c) c_int {
    const l: *Link = @ptrCast(@alignCast(data));
    const dd = l.dd orelse return 0;
    l.at = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    l.leaving = false;
    if (l.over != ctx) {
        l.over = ctx;
        enter(l, ctx);
    }
    const e = dd.externalOver(l.at, effectOf(api.gdk_drag_context_get_suggested_action(ctx)));
    api.gdk_drag_status(ctx, actionOf(e), time);
    l.redraw(l.win);
    return 1;
}

fn onLeave(_: *gtk.Widget, _: *anyopaque, _: c_uint, data: ?*anyopaque) callconv(.c) void {
    const l: *Link = @ptrCast(@alignCast(data));
    // GTK leaves just before a drop too: left only if no drop follows.
    l.leaving = true;
    _ = gtk.api.g_idle_add(leaveLater, l);
}

fn leaveLater(data: ?*anyopaque) callconv(.c) c_int {
    const l: *Link = @ptrCast(@alignCast(data));
    if (!l.leaving or l.pending > 0) return 0;
    l.leaving = false;
    l.over = null;
    if (l.dd) |dd| dd.externalLeave();
    l.redraw(l.win);
    return 0;
}

fn onDrop(widget: *gtk.Widget, ctx: *anyopaque, x: c_int, y: c_int, time: c_uint, data: ?*anyopaque) callconv(.c) c_int {
    const l: *Link = @ptrCast(@alignCast(data));
    l.leaving = false;
    l.at = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    _ = l.arena.reset(.free_all);
    l.asked = .empty;
    l.got = .empty;
    const a = l.arena.allocator();
    const fs = offered(a, ctx) catch &.{};
    l.asked.appendSlice(a, fs) catch {};
    l.pending = l.asked.items.len;
    if (l.pending == 0) {
        api.gtk_drag_finish(ctx, 0, 0, time);
        finish(l);
        return 1;
    }
    for (l.asked.items) |e| api.gtk_drag_get_data(widget, ctx, gtk.api.gdk_atom_intern(e.target.ptr, 0), time);
    return 1;
}

fn onReceived(_: *gtk.Widget, ctx: *anyopaque, _: c_int, _: c_int, sd: ?*anyopaque, _: c_uint, time: c_uint, data: ?*anyopaque) callconv(.c) void {
    const l: *Link = @ptrCast(@alignCast(data));
    if (l.pending == 0) return;
    const a = l.arena.allocator();
    if (sd) |s| if (sel.atomName(a, sel.api.gtk_selection_data_get_target(s))) |target| {
        for (l.asked.items) |e| if (std.mem.eql(u8, e.target, target)) {
            if (sel.selectionBytes(a, s)) |b| l.got.append(a, transfer.bytes(e.format, sel.fromTarget(a, target, b))) catch {};
            break;
        };
    };
    l.pending -= 1;
    if (l.pending > 0) return;
    const dropped = transfer.Data.init(std.heap.c_allocator, &.{.{ .reps = l.got.items }}) catch null;
    const e: transfer.Effect = if (l.dd) |dd| dd.externalDrop(l.at, dropped, effectOf(api.gdk_drag_context_get_suggested_action(ctx))) else .none;
    api.gtk_drag_finish(ctx, @intFromBool(e != .none), @intFromBool(e == .move), time);
    finish(l);
}

fn finish(l: *Link) void {
    l.over = null;
    l.pending = 0;
    if (l.dd) |dd| if (dd.incoming != null and !dd.incoming_drop) dd.externalLeave();
    l.redraw(l.win);
}

/// `ui.DragDrop.external` for a window's drawing area: drags leaving it
/// go on in GTK's drag, from the next turn of the loop.
pub fn external(widget: *gtk.Widget, win: *anyopaque, redraw: *const fn (*anyopaque) void) ?dragdrop.External {
    const l = linkOf(widget, win, redraw) orelse return null;
    return .{ .ctx = l, .start = begin };
}

fn begin(ctx: ?*anyopaque, dd: *dragdrop.DragDrop) void {
    const l: *Link = @ptrCast(@alignCast(ctx));
    l.out = dd;
    _ = gtk.api.g_idle_add(beginLater, l);
}

fn beginLater(data: ?*anyopaque) callconv(.c) c_int {
    const l: *Link = @ptrCast(@alignCast(data));
    const dd = l.out orelse return 0;
    const act = if (dd.active) |*x| x else return 0;
    const ca = std.heap.c_allocator;
    freeOut(l);
    l.out_entries = sel.entriesOf(ca, &act.data) catch &.{};
    var table: [64]sel.TargetEntry = undefined;
    const n = @min(table.len, l.out_entries.len);
    for (l.out_entries[0..n], table[0..n], 0..) |e, *t, i| t.* = .{ .target = e.target.ptr, .flags = 0, .info = @intCast(i) };
    const list = api.gtk_target_list_new(&table, @intCast(n)) orelse return done(l, .none);
    defer api.gtk_target_list_unref(list);
    l.out_failed = false;
    l.out_escaped = false;
    // Button 1, no event at hand: GTK takes the pointer now.
    if (api.gtk_drag_begin_with_coordinates(l.widget, list, actionsOf(act.effects), 1, null, -1, -1) == null) return done(l, .none);
    return 0;
}

fn freeOut(l: *Link) void {
    const ca = std.heap.c_allocator;
    for (l.out_entries) |e| {
        ca.free(e.target);
        ca.free(e.format);
    }
    if (l.out_entries.len > 0) ca.free(l.out_entries);
    l.out_entries = &.{};
}

fn done(l: *Link, effect: transfer.Effect) c_int {
    return doneAt(l, .{ .effect = effect });
}

fn doneAt(l: *Link, end: dragdrop.ExternalEnd) c_int {
    freeOut(l);
    if (l.out) |dd| dd.externalEnd(end);
    l.out = null;
    l.redraw(l.win);
    return 0;
}

fn onDataGet(_: *gtk.Widget, _: *anyopaque, sd: *anyopaque, info: c_uint, _: c_uint, data: ?*anyopaque) callconv(.c) void {
    const l: *Link = @ptrCast(@alignCast(data));
    const dd = l.out orelse return;
    const act = if (dd.active) |*x| x else return;
    if (info >= l.out_entries.len) return;
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const b = sel.serve(arena.allocator(), &act.data, l.out_entries[info]) orelse return;
    sel.api.gtk_selection_data_set(sd, sel.api.gtk_selection_data_get_target(sd), 8, b.ptr, @intCast(b.len));
}

fn onDragFailed(_: *gtk.Widget, _: *anyopaque, result: c_int, data: ?*anyopaque) callconv(.c) c_int {
    const l: *Link = @ptrCast(@alignCast(data));
    l.out_failed = true;
    // GTK_DRAG_RESULT_USER_CANCELLED (Escape), not NO_TARGET (1).
    l.out_escaped = result == 2;
    return 0;
}

fn onDragEnd(_: *gtk.Widget, ctx: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const l: *Link = @ptrCast(@alignCast(data));
    if (l.out == null) return;
    const e: transfer.Effect = if (l.out_failed) .none else effectOf(api.gdk_drag_context_get_selected_action(ctx)) orelse .none;
    // Where the pointer let go, in GDK's screen coordinates.
    var screen: ?Point = null;
    if (api.gdk_drag_context_get_device(ctx)) |device| {
        var x: c_int = 0;
        var y: c_int = 0;
        api.gdk_device_get_position(device, null, &x, &y);
        screen = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    }
    _ = doneAt(l, .{ .effect = e, .escaped = l.out_escaped, .screen = screen });
}

test "GDK's actions are transfer's effects" {
    const e = effectsOf(copy_action | move_action);
    try std.testing.expect(e.copy and e.move and !e.link);
    try std.testing.expectEqual(copy_action | move_action, actionsOf(e));
    try std.testing.expectEqual(transfer.Effect.move, effectOf(move_action | copy_action).?);
    try std.testing.expect(effectOf(0) == null);
    try std.testing.expectEqual(@as(c_int, 0), actionOf(.none));
}
