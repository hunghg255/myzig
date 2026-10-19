//! Drag and drop with other apps on macOS: drags from them over a
//! window's native UI reach its `ui.DragDrop` targets (the view is their
//! NSDraggingDestination: the formats on entering, every format read at
//! the drop), and drags leaving it go on in an AppKit dragging session
//! (the view is its NSDraggingSource), started in the frame the pointer
//! leaves, while the mouse event is current. The methods are added to
//! native UI's view class when first asked for.
const std = @import("std");
const objc = @import("objc.zig");
const transfer = @import("transfer.zig");
const native = @import("transfer_native.zig");
const pasteboard = @import("transfer_mac.zig");
const dragdrop = @import("ui/dragdrop.zig");
const Point = @import("ui/types.zig").Point;

extern "c" fn class_addMethod(cls: objc.Class, name: objc.SEL, imp: *const anyopaque, types: [*:0]const u8) objc.BOOL;
extern "c" fn class_addProtocol(cls: objc.Class, protocol: *anyopaque) objc.BOOL;
extern "c" fn objc_getProtocol(name: [*:0]const u8) ?*anyopaque;
extern "c" fn object_getClass(obj: objc.Object) objc.Class;

const NSDragOperationCopy: objc.NSUInteger = 1;
const NSDragOperationLink: objc.NSUInteger = 2;
const NSDragOperationMove: objc.NSUInteger = 16;

pub fn effectsOf(mask: objc.NSUInteger) transfer.Effects {
    return .{ .copy = mask & NSDragOperationCopy != 0, .move = mask & NSDragOperationMove != 0, .link = mask & NSDragOperationLink != 0 };
}

pub fn operationOf(e: transfer.Effect) objc.NSUInteger {
    return switch (e) {
        .none => 0,
        .copy => NSDragOperationCopy,
        .move => NSDragOperationMove,
        .link => NSDragOperationLink,
    };
}

pub fn effectOf(op: objc.NSUInteger) transfer.Effect {
    if (op & NSDragOperationMove != 0) return .move;
    if (op & NSDragOperationCopy != 0) return .copy;
    if (op & NSDragOperationLink != 0) return .link;
    return .none;
}

/// A view and what drags over it reach.
const Link = struct {
    view: objc.Object,
    win: *anyopaque,
    redraw: *const fn (win: *anyopaque) void,
    dd: ?*dragdrop.DragDrop = null,
    out: ?*dragdrop.DragDrop = null,
    allowed: transfer.Effects = .{},
};

var links: std.ArrayList(*Link) = .empty;

fn find(view: objc.Object) ?*Link {
    for (links.items) |l| if (l.view == view) return l;
    return null;
}

var methods_added = false;

fn linkOf(view: objc.Object, win: *anyopaque, redraw: *const fn (*anyopaque) void) ?*Link {
    if (find(view)) |l| return l;
    if (!methods_added) {
        methods_added = true;
        const cls = object_getClass(view);
        const ms = [_]objc.Method{
            .{ .name = "draggingEntered:", .imp = &entered, .types = "Q@:@" },
            .{ .name = "draggingUpdated:", .imp = &updated, .types = "Q@:@" },
            .{ .name = "draggingExited:", .imp = &exited, .types = "v@:@" },
            .{ .name = "performDragOperation:", .imp = &perform, .types = "c@:@" },
            .{ .name = "draggingSession:sourceOperationMaskForDraggingContext:", .imp = &sourceMask, .types = "Q@:@q" },
            .{ .name = "draggingSession:endedAtPoint:operation:", .imp = &ended, .types = "v@:@{CGPoint=dd}Q" },
        };
        for (ms) |m| _ = class_addMethod(cls, objc.sel(m.name), m.imp, m.types);
        if (objc_getProtocol("NSDraggingSource")) |p| _ = class_addProtocol(cls, p);
    }
    const l = std.heap.c_allocator.create(Link) catch return null;
    l.* = .{ .view = view, .win = win, .redraw = redraw };
    links.append(std.heap.c_allocator, l) catch {
        std.heap.c_allocator.destroy(l);
        return null;
    };
    return l;
}

/// The pasteboard types drags may bring: myzig's formats and the
/// common ones, and `extra` (MIME types of the app's own).
fn draggedTypes(extra: []const []const u8) objc.Object {
    const types = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    for ([_][]const u8{ "public.utf8-plain-text", "public.html", "public.png", "public.tiff", "public.jpeg", "public.file-url", "public.url", "public.rtf", "com.adobe.pdf", "net.daringfireball.markdown" }) |t| objc.msg(void, types, "addObject:", .{objc.nsString(t)});
    var buf: [512]u8 = undefined;
    for (extra) |f| {
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const t = native.macType(fba.allocator(), f) catch continue;
        objc.msg(void, types, "addObject:", .{objc.nsString(t)});
    }
    return types;
}

/// Lets drags from other apps drop on `dd`'s targets in `view` (native
/// UI's), of the common formats and `extra`; `redraw(win)` draws a frame.
pub fn accept(view: objc.Object, dd: *dragdrop.DragDrop, extra: []const []const u8, win: *anyopaque, redraw: *const fn (*anyopaque) void) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const l = linkOf(view, win, redraw) orelse return;
    l.dd = dd;
    objc.msg(void, view, "registerForDraggedTypes:", .{draggedTypes(extra)});
}

fn pointOf(l: *Link, info: objc.Object) Point {
    const p = objc.msg(objc.CGPoint, info, "draggingLocation", .{});
    // The view is flipped: from its top left, in points.
    const local = objc.msg(objc.CGPoint, l.view, "convertPoint:fromView:", .{ p, @as(?objc.Object, null) });
    return .{ .x = @floatCast(local.x), .y = @floatCast(local.y) };
}

var unread: u8 = 0;
fn notYet(_: *u8, _: std.mem.Allocator) anyerror![]u8 {
    return error.FormatUnavailable;
}

fn entered(self_obj: objc.Object, _: objc.SEL, info: objc.Object) callconv(.c) objc.NSUInteger {
    const l = find(self_obj) orelse return 0;
    const dd = l.dd orelse return 0;
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pb = objc.msg(objc.Object, info, "draggingPasteboard", .{});
    const fs = pasteboard.formatsOf(a, pb) catch return 0;
    // The formats now; their bytes are read at the drop.
    const reps = a.alloc(transfer.Rep, fs.len) catch return 0;
    for (fs, reps) |f, *r| r.* = transfer.lazy(f, .of(&unread, notYet));
    const data = transfer.Data.init(std.heap.c_allocator, &.{.{ .reps = reps }}) catch return 0;
    const at = pointOf(l, info);
    dd.externalEnter(data, effectsOf(objc.msg(objc.NSUInteger, info, "draggingSourceOperationMask", .{})), at);
    l.redraw(l.win);
    return operationOf(dd.externalOver(at, null));
}

fn updated(self_obj: objc.Object, _: objc.SEL, info: objc.Object) callconv(.c) objc.NSUInteger {
    const l = find(self_obj) orelse return 0;
    const dd = l.dd orelse return 0;
    const e = dd.externalOver(pointOf(l, info), null);
    l.redraw(l.win);
    return operationOf(e);
}

fn exited(self_obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const l = find(self_obj) orelse return;
    const dd = l.dd orelse return;
    dd.externalLeave();
    l.redraw(l.win);
}

fn perform(self_obj: objc.Object, _: objc.SEL, info: objc.Object) callconv(.c) objc.BOOL {
    const l = find(self_obj) orelse return objc.NO;
    const dd = l.dd orelse return objc.NO;
    const pool = objc.Pool.push();
    defer pool.pop();
    const pb = objc.msg(objc.Object, info, "draggingPasteboard", .{});
    const data = pasteboard.dataOf(std.heap.c_allocator, pb) catch null;
    const e = dd.externalDrop(pointOf(l, info), data, null);
    l.redraw(l.win);
    return e != .none;
}

/// `ui.DragDrop.external` for native UI's `view`: drags leaving it go on
/// in an AppKit dragging session.
pub fn external(view: objc.Object, win: *anyopaque, redraw: *const fn (*anyopaque) void) ?dragdrop.External {
    const l = linkOf(view, win, redraw) orelse return null;
    return .{ .ctx = l, .start = begin };
}

fn begin(ctx: ?*anyopaque, dd: *dragdrop.DragDrop) void {
    const l: *Link = @ptrCast(@alignCast(ctx));
    const act = if (dd.active) |*x| x else return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    const event = objc.msg(?objc.Object, nsapp, "currentEvent", .{}) orelse return dd.externalDone(.none);
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const writers = pasteboard.pasteboardItems(arena.allocator(), &act.data) catch return dd.externalDone(.none);
    const n = objc.msg(objc.NSUInteger, writers, "count", .{});
    if (n == 0) return dd.externalDone(.none);
    const items = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    const p = objc.msg(objc.CGPoint, event, "locationInWindow", .{});
    const local = objc.msg(objc.CGPoint, l.view, "convertPoint:fromView:", .{ p, @as(?objc.Object, null) });
    const frame: objc.CGRect = .{ .origin = .{ .x = local.x - 16, .y = local.y - 16 }, .size = .{ .width = 32, .height = 32 } };
    for (0..n) |i| {
        const item = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSDraggingItem"), "alloc", .{}), "initWithPasteboardWriter:", .{objc.msg(objc.Object, writers, "objectAtIndex:", .{i})});
        objc.autorelease(item);
        objc.msg(void, item, "setDraggingFrame:contents:", .{ frame, @as(?objc.Object, null) });
        objc.msg(void, items, "addObject:", .{item});
    }
    l.out = dd;
    l.allowed = act.effects;
    _ = objc.msg(?objc.Object, l.view, "beginDraggingSessionWithItems:event:source:", .{ items, event, l.view });
}

fn sourceMask(self_obj: objc.Object, _: objc.SEL, _: objc.Object, _: objc.NSInteger) callconv(.c) objc.NSUInteger {
    const l = find(self_obj) orelse return NSDragOperationCopy;
    const e = l.allowed;
    return (if (e.copy) @as(objc.NSUInteger, NSDragOperationCopy) else 0) | (if (e.move) @as(objc.NSUInteger, NSDragOperationMove) else 0) | (if (e.link) @as(objc.NSUInteger, NSDragOperationLink) else 0);
}

fn ended(self_obj: objc.Object, _: objc.SEL, _: objc.Object, point: objc.CGPoint, op: objc.NSUInteger) callconv(.c) void {
    const l = find(self_obj) orelse return;
    const dd = l.out orelse return;
    l.out = null;
    // AppKit's tracking loop takes Escape itself: the event that ended
    // the session tells it from letting go (a key down of keyCode 53).
    const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    const escaped = if (objc.msg(?objc.Object, nsapp, "currentEvent", .{})) |ev|
        objc.msg(objc.NSUInteger, ev, "type", .{}) == 10 and objc.msg(u16, ev, "keyCode", .{}) == 53
    else
        false;
    // Screen coordinates from the primary display's bottom left.
    const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    const ph: f64 = if (objc.msg(objc.NSUInteger, screens, "count", .{}) > 0)
        objc.msg(objc.CGRect, objc.msg(objc.Object, screens, "objectAtIndex:", .{@as(objc.NSUInteger, 0)}), "frame", .{}).size.height
    else
        0;
    dd.externalEnd(.{ .effect = effectOf(op), .escaped = escaped, .screen = .{ .x = @floatCast(point.x), .y = @floatCast(ph - point.y) } });
    l.redraw(l.win);
}

test "AppKit's drag operations are transfer's effects" {
    const e = effectsOf(NSDragOperationCopy | NSDragOperationMove);
    try std.testing.expect(e.copy and e.move and !e.link);
    try std.testing.expectEqual(transfer.Effect.move, effectOf(NSDragOperationMove | NSDragOperationCopy));
    try std.testing.expectEqual(@as(objc.NSUInteger, 0), operationOf(.none));
}
