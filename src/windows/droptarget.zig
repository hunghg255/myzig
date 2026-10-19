//! Drags from other apps over a window's native UI on Windows: an OLE
//! IDropTarget registered on the window, whose drags reach the window's
//! `ui.DragDrop` targets. The formats are known on entering (the data
//! object's, as MIME types: `transfer_win.zig`); their bytes are read at
//! the drop, while the data object is still there. Files let go where no
//! target takes them reach the window's `on_drop`, as before.
const std = @import("std");
const com = @import("com.zig");
const w = @import("win32.zig");
const oledrag = @import("oledrag.zig");
const xfer = @import("transfer_win.zig");
const transfer = @import("../transfer.zig");
const dragdrop = @import("../ui/dragdrop.zig");
const Point = @import("../ui/types.zig").Point;

extern "ole32" fn OleInitialize(reserved: ?*anyopaque) callconv(.winapi) com.HRESULT;
extern "ole32" fn RegisterDragDrop(hwnd: w.HWND, target: *anyopaque) callconv(.winapi) com.HRESULT;
extern "ole32" fn RevokeDragDrop(hwnd: w.HWND) callconv(.winapi) com.HRESULT;
extern "ole32" fn CoTaskMemFree(p: ?*anyopaque) callconv(.winapi) void;
extern "ole32" fn ReleaseStgMedium(m: *oledrag.STGMEDIUM) callconv(.winapi) void;

const iid_unknown = com.GUID.parse("00000000-0000-0000-c000-000000000046");
const iid_drop_target = com.GUID.parse("00000122-0000-0000-c000-000000000046");
const POINTL = extern struct { x: i32, y: i32 };
const MK_SHIFT = 4;
const MK_CONTROL = 8;

const a = std.heap.c_allocator;

/// DROPEFFECT bits as transfer's effects, and back.
pub fn effectsOf(bits: u32) transfer.Effects {
    return .{ .copy = bits & 1 != 0, .move = bits & 2 != 0, .link = bits & 4 != 0 };
}

pub fn bitsOf(e: transfer.Effect) u32 {
    return switch (e) {
        .none => 0,
        .copy => 1,
        .move => 2,
        .link => 4,
    };
}

/// The effect the keys held ask for: Ctrl copies, Shift moves.
pub fn suggested(keys: u32) ?transfer.Effect {
    if (keys & MK_CONTROL != 0) return .copy;
    if (keys & MK_SHIFT != 0) return .move;
    return null;
}

/// What the target reaches of its window.
pub const Host = struct {
    ctx: *anyopaque,
    hwnd: w.HWND,
    /// Points per pixel of the window now.
    scale: *const fn (ctx: *anyopaque) f64,
    redraw: *const fn (ctx: *anyopaque) void,
    /// Files no target took (the window's `on_drop`), or null.
    files: ?*const fn (ctx: *anyopaque, paths: []const []const u8) void = null,
};

pub const DropTarget = extern struct {
    vtbl: *const Vtbl,
    refs: u32 = 1,
    dd: *dragdrop.DragDrop,
    host: *const Host,

    const Vtbl = extern struct {
        query: *const fn (*DropTarget, *const com.GUID, *?*anyopaque) callconv(.winapi) com.HRESULT = query,
        add_ref: *const fn (*DropTarget) callconv(.winapi) u32 = addRef,
        release: *const fn (*DropTarget) callconv(.winapi) u32 = release,
        enter: *const fn (*DropTarget, *anyopaque, u32, POINTL, *u32) callconv(.winapi) com.HRESULT = dragEnter,
        over: *const fn (*DropTarget, u32, POINTL, *u32) callconv(.winapi) com.HRESULT = dragOver,
        leave: *const fn (*DropTarget) callconv(.winapi) com.HRESULT = dragLeave,
        drop: *const fn (*DropTarget, *anyopaque, u32, POINTL, *u32) callconv(.winapi) com.HRESULT = drop,
    };
    const vtbl_shared: Vtbl = .{};

    fn query(t: *DropTarget, iid: *const com.GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
        if (iid.eql(iid_unknown) or iid.eql(iid_drop_target)) {
            out.* = t;
            _ = addRef(t);
            return com.S_OK;
        }
        out.* = null;
        return com.E_NOINTERFACE;
    }
    fn addRef(t: *DropTarget) callconv(.winapi) u32 {
        t.refs += 1;
        return t.refs;
    }
    fn release(t: *DropTarget) callconv(.winapi) u32 {
        t.refs -= 1;
        if (t.refs > 0) return t.refs;
        a.destroy(t.host);
        a.destroy(t);
        return 0;
    }

    fn pointOf(t: *DropTarget, pt: POINTL) Point {
        var p: w.POINT = .{ .x = pt.x, .y = pt.y };
        _ = w.ScreenToClient(t.host.hwnd, &p);
        const s: f32 = @floatCast(t.host.scale(t.host.ctx));
        return .{ .x = @as(f32, @floatFromInt(p.x)) / s, .y = @as(f32, @floatFromInt(p.y)) / s };
    }

    fn dragEnter(t: *DropTarget, obj: *anyopaque, keys: u32, pt: POINTL, effect: *u32) callconv(.winapi) com.HRESULT {
        const allowed = effect.*;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const fs = formatsOf(arena.allocator(), obj) catch &.{};
        // The formats now; their bytes are read at the drop.
        const reps = arena.allocator().alloc(transfer.Rep, fs.len) catch return com.E_FAIL;
        for (fs, reps) |f, *r| r.* = transfer.lazy(f, .of(&unread, notYet));
        const data = transfer.Data.init(a, &.{.{ .reps = reps }}) catch return com.E_FAIL;
        const at = t.pointOf(pt);
        t.dd.externalEnter(data, effectsOf(allowed), at);
        effect.* = bitsOf(t.dd.externalOver(at, suggested(keys)));
        t.host.redraw(t.host.ctx);
        return com.S_OK;
    }
    fn dragOver(t: *DropTarget, keys: u32, pt: POINTL, effect: *u32) callconv(.winapi) com.HRESULT {
        effect.* = bitsOf(t.dd.externalOver(t.pointOf(pt), suggested(keys))) & effect.*;
        t.host.redraw(t.host.ctx);
        return com.S_OK;
    }
    fn dragLeave(t: *DropTarget) callconv(.winapi) com.HRESULT {
        t.dd.externalLeave();
        t.host.redraw(t.host.ctx);
        return com.S_OK;
    }
    fn drop(t: *DropTarget, obj: *anyopaque, keys: u32, pt: POINTL, effect: *u32) callconv(.winapi) com.HRESULT {
        const at = t.pointOf(pt);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const ar = arena.allocator();
        const data = read(ar, obj) catch null;
        const e = t.dd.externalDrop(at, data, suggested(keys));
        effect.* = bitsOf(e) & effect.*;
        if (e == .none) if (t.host.files) |files| {
            // Files no target took: the window's own drop.
            const src: xfer.Source = .{ .ctx = obj, .get = objectGet };
            if (xfer.decode(ar, src, transfer.file_list)) |list| {
                var d = transfer.Data.init(ar, &.{.{ .reps = &.{transfer.bytes(transfer.file_list, list)} }}) catch return com.S_OK;
                const paths = d.files(ar) catch &.{};
                if (paths.len > 0) {
                    files(t.host.ctx, @ptrCast(paths));
                    effect.* = 1;
                }
            }
        };
        t.host.redraw(t.host.ctx);
        return com.S_OK;
    }
};

var unread: u8 = 0;
fn notYet(_: *u8, _: std.mem.Allocator) anyerror![]u8 {
    return error.FormatUnavailable;
}

/// The clipboard formats a data object offers.
fn cfsOf(ar: std.mem.Allocator, obj: *anyopaque) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    var e: ?*anyopaque = null;
    if (com.failed(com.call(obj, 8, .{ @as(u32, 1), &e })) or e == null) return out.toOwnedSlice(ar);
    defer com.release(e);
    var f: [1]oledrag.FORMATETC = undefined;
    var n: u32 = 0;
    while (com.call(e.?, 3, .{ @as(u32, 1), &f, &n }) == com.S_OK and n == 1) {
        if (f[0].tymed & 1 != 0) try out.append(ar, f[0].cf); // TYMED_HGLOBAL
        if (f[0].ptd) |p| CoTaskMemFree(p);
    }
    return out.toOwnedSlice(ar);
}

fn formatsOf(ar: std.mem.Allocator, obj: *anyopaque) ![]const []const u8 {
    return xfer.formatsOf(ar, try cfsOf(ar, obj));
}

fn objectGet(ctx: ?*anyopaque, ar: std.mem.Allocator, cf: u32) ?[]u8 {
    const obj: *anyopaque = ctx orelse return null;
    var f: oledrag.FORMATETC = .{ .cf = @truncate(cf) };
    var m: oledrag.STGMEDIUM = undefined;
    if (com.call(obj, 3, .{ &f, &m }) != com.S_OK) return null;
    defer ReleaseStgMedium(&m);
    if (m.tymed != 1) return null;
    return xfer.globalBytes(ar, m.hglobal orelse return null);
}

/// Every format of a data object, read now (owned by `a`).
fn read(ar: std.mem.Allocator, obj: *anyopaque) !transfer.Data {
    const fs = try formatsOf(ar, obj);
    var reps: std.ArrayList(transfer.Rep) = .empty;
    const src: xfer.Source = .{ .ctx = obj, .get = objectGet };
    for (fs) |f| if (xfer.decode(ar, src, f)) |b| try reps.append(ar, transfer.bytes(f, b));
    return transfer.Data.init(a, &.{.{ .reps = reps.items }});
}

/// Lets drags from other apps drop on `dd`'s targets in window `win`
/// (one with `hwnd`, `dpiScale`, `redraw` and `on_drop`), for as long as
/// it lives. Main thread; the app keeps `dd`.
pub fn register(win: anytype, dd: *dragdrop.DragDrop) !void {
    const Win = @TypeOf(win.*);
    const hwnd = win.hwnd orelse return; // headless
    const S = struct {
        fn scale(ctx: *anyopaque) f64 {
            return @as(*Win, @ptrCast(@alignCast(ctx))).dpiScale();
        }
        fn redraw(ctx: *anyopaque) void {
            @as(*Win, @ptrCast(@alignCast(ctx))).redraw();
        }
        fn files(ctx: *anyopaque, paths: []const []const u8) void {
            const self: *Win = @ptrCast(@alignCast(ctx));
            if (self.on_drop) |cb| cb.func(cb.ctx, self, paths);
        }
    };
    if (com.failed(OleInitialize(null))) return error.OleInitialize;
    const host = try a.create(Host);
    errdefer a.destroy(host);
    host.* = .{ .ctx = win, .hwnd = hwnd, .scale = S.scale, .redraw = S.redraw, .files = if (@hasField(Win, "on_drop")) S.files else null };
    const t = try a.create(DropTarget);
    t.* = .{ .vtbl = &DropTarget.vtbl_shared, .dd = dd, .host = host };
    // Registered again: the newer target replaces the older.
    _ = RevokeDragDrop(hwnd);
    const hr = RegisterDragDrop(hwnd, t);
    // OLE holds it while registered; it goes when the window does.
    _ = DropTarget.release(t);
    if (com.failed(hr)) return error.RegisterDragDrop;
}

test "a drop target turns OLE's effects into transfer's" {
    try std.testing.expectEqual(@as(u32, 3), bitsOf(.copy) | bitsOf(.move));
    const e = effectsOf(5);
    try std.testing.expect(e.copy and !e.move and e.link);
    try std.testing.expectEqual(transfer.Effect.copy, suggested(MK_CONTROL).?);
    try std.testing.expectEqual(transfer.Effect.move, suggested(MK_SHIFT).?);
    try std.testing.expect(suggested(0) == null);
}

test "drags from an OLE data object read as transfer data" {
    const gpa = std.testing.allocator;
    var d = try transfer.Data.init(gpa, &.{.{ .reps = &.{ transfer.bytes(transfer.text, "héllo"), transfer.bytes(transfer.html, "<i>x</i>"), transfer.bytes("application/x-note", "n") } }});
    defer d.deinit();
    const obj = try oledrag.DataObject.create(&d);
    defer com.release(@ptrCast(obj));
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const fs = try formatsOf(arena.allocator(), obj);
    try std.testing.expectEqual(@as(usize, 3), fs.len);
    var got = try read(arena.allocator(), obj);
    defer got.deinit();
    try std.testing.expectEqualStrings("héllo", try got.read(arena.allocator(), transfer.text));
    try std.testing.expectEqualStrings("<i>x</i>", try got.read(arena.allocator(), transfer.html));
    try std.testing.expectEqualStrings("n", try got.read(arena.allocator(), "application/x-note"));
}
