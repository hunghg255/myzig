//! Drags that leave the window on Windows: OLE's `DoDragDrop` with an
//! IDataObject offering the data's formats as other apps read them
//! (CF_UNICODETEXT, CF_HDROP for files, "HTML Format", "PNG", and MIME
//! names as registered formats) and an IDropSource that drops when the
//! button goes up and gives up on Escape. `DoDragDrop` runs its own loop
//! until then; call it on the main thread while the button is down.
const std = @import("std");
const com = @import("com.zig");
const w = @import("win32.zig");
const clipboard = @import("clipboard.zig");
const transfer = @import("../transfer.zig");
const dragdrop = @import("../ui/dragdrop.zig");

extern "ole32" fn OleInitialize(reserved: ?*anyopaque) callconv(.winapi) com.HRESULT;
extern "ole32" fn DoDragDrop(data: *anyopaque, source: *anyopaque, ok: u32, effect: *u32) callconv(.winapi) com.HRESULT;
extern "user32" fn RegisterClipboardFormatW(name: [*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn GlobalFree(mem: *anyopaque) callconv(.winapi) ?*anyopaque;

const CF_UNICODETEXT = 13;
const CF_HDROP = 15;
const TYMED_HGLOBAL = 1;
const DVASPECT_CONTENT = 1;
const E_NOTIMPL: com.HRESULT = @bitCast(@as(u32, 0x80004001));
const DV_E_FORMATETC: com.HRESULT = @bitCast(@as(u32, 0x80040064));
const OLE_E_ADVISENOTSUPPORTED: com.HRESULT = @bitCast(@as(u32, 0x80040003));
const DATA_S_SAMEFORMATETC: com.HRESULT = 0x00040130;
const DRAGDROP_S_DROP: com.HRESULT = 0x00040100;
const DRAGDROP_S_CANCEL: com.HRESULT = 0x00040101;
const DRAGDROP_S_USEDEFAULTCURSORS: com.HRESULT = 0x00040102;
const S_FALSE: com.HRESULT = 1;
const MK_LBUTTON = 1;

pub const FORMATETC = extern struct { cf: u16, ptd: ?*anyopaque = null, aspect: u32 = DVASPECT_CONTENT, lindex: i32 = -1, tymed: u32 = TYMED_HGLOBAL };
pub const STGMEDIUM = extern struct { tymed: u32, hglobal: ?*anyopaque, release: ?*anyopaque };

const iid_unknown = com.GUID.parse("00000000-0000-0000-c000-000000000046");
const iid_data_object = com.GUID.parse("0000010e-0000-0000-c000-000000000046");
const iid_drop_source = com.GUID.parse("00000121-0000-0000-c000-000000000046");
const iid_enum_formatetc = com.GUID.parse("00000103-0000-0000-c000-000000000046");

const a = std.heap.c_allocator;

/// A format as other apps read it, and its bytes.
const Rendered = struct { cf: u16, bytes: []u8 };

/// The registered clipboard format of a name ("PNG", a MIME type).
fn registered(name: []const u8) u16 {
    var buf: [256]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(buf[0..255], name[0..@min(name.len, 120)]) catch return 0;
    buf[n] = 0;
    return @truncate(RegisterClipboardFormatW(buf[0..n :0]));
}

/// The formats of `data` as Windows has them; their bytes made now.
pub fn render(data: *transfer.Data) ![]Rendered {
    var out: std.ArrayList(Rendered) = .empty;
    errdefer {
        for (out.items) |r| a.free(r.bytes);
        out.deinit(a);
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const fs = try data.formats(ar);
    var files_done = false;
    for (fs) |f| {
        if (std.mem.startsWith(u8, f, transfer.value_prefix)) continue; // this process's only
        if (std.mem.eql(u8, f, transfer.text)) {
            const t = data.read(ar, f) catch continue;
            const wide = try std.unicode.utf8ToUtf16LeAllocZ(ar, t);
            try out.append(a, .{ .cf = CF_UNICODETEXT, .bytes = try a.dupe(u8, std.mem.sliceAsBytes(wide[0 .. wide.len + 1])) });
        } else if (std.mem.eql(u8, f, transfer.file_list) or std.mem.eql(u8, f, transfer.uri_list)) {
            if (files_done) continue;
            const paths = data.files(ar) catch continue;
            if (paths.len == 0) continue;
            files_done = true;
            const drop = try clipboard.dropFiles(ar, paths);
            try out.append(a, .{ .cf = CF_HDROP, .bytes = try a.dupe(u8, drop) });
            if (std.mem.eql(u8, f, transfer.uri_list)) try out.append(a, .{ .cf = registered(transfer.uri_list), .bytes = try a.dupe(u8, data.read(ar, f) catch "") });
        } else if (std.mem.eql(u8, f, transfer.html)) {
            const h = data.read(ar, f) catch continue;
            try out.append(a, .{ .cf = registered("HTML Format"), .bytes = try a.dupe(u8, try clipboard.encodeHtml(ar, h)) });
        } else {
            const b = data.read(ar, f) catch continue;
            const name = if (std.mem.eql(u8, f, transfer.png)) "PNG" else f;
            try out.append(a, .{ .cf = registered(name), .bytes = try a.dupe(u8, b) });
        }
    }
    return out.toOwnedSlice(a);
}

fn hglobal(bytes: []const u8) ?*anyopaque {
    const mem = w.GlobalAlloc(0x0002, @max(bytes.len, 1)) orelse return null;
    const p: [*]u8 = @ptrCast(w.GlobalLock(mem) orelse return null);
    @memcpy(p[0..bytes.len], bytes);
    _ = w.GlobalUnlock(mem);
    return mem;
}

/// IDataObject over rendered formats.
pub const DataObject = extern struct {
    vtbl: *const Vtbl,
    refs: u32 = 1,
    items: [*]Rendered,
    len: usize,

    const Vtbl = extern struct {
        query: *const fn (*DataObject, *const com.GUID, *?*anyopaque) callconv(.winapi) com.HRESULT = query,
        add_ref: *const fn (*DataObject) callconv(.winapi) u32 = addRef,
        release: *const fn (*DataObject) callconv(.winapi) u32 = release,
        get_data: *const fn (*DataObject, *const FORMATETC, *STGMEDIUM) callconv(.winapi) com.HRESULT = getData,
        get_data_here: *const fn (*DataObject, *const FORMATETC, *STGMEDIUM) callconv(.winapi) com.HRESULT = notImpl2,
        query_get_data: *const fn (*DataObject, *const FORMATETC) callconv(.winapi) com.HRESULT = queryGetData,
        canonical: *const fn (*DataObject, *const FORMATETC, *FORMATETC) callconv(.winapi) com.HRESULT = canonical,
        set_data: *const fn (*DataObject, *const FORMATETC, *STGMEDIUM, i32) callconv(.winapi) com.HRESULT = setData,
        enum_format: *const fn (*DataObject, u32, *?*anyopaque) callconv(.winapi) com.HRESULT = enumFormat,
        dadvise: *const fn (*DataObject, *const FORMATETC, u32, ?*anyopaque, *u32) callconv(.winapi) com.HRESULT = dadvise,
        dunadvise: *const fn (*DataObject, u32) callconv(.winapi) com.HRESULT = dunadvise,
        enum_dadvise: *const fn (*DataObject, *?*anyopaque) callconv(.winapi) com.HRESULT = enumDadvise,
    };
    const vtbl_shared: Vtbl = .{};

    pub fn create(data: *transfer.Data) !*DataObject {
        const items = try render(data);
        const o = try a.create(DataObject);
        o.* = .{ .vtbl = &vtbl_shared, .items = items.ptr, .len = items.len };
        return o;
    }

    fn slice(o: *DataObject) []Rendered {
        return o.items[0..o.len];
    }

    fn query(o: *DataObject, iid: *const com.GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
        if (iid.eql(iid_unknown) or iid.eql(iid_data_object)) {
            out.* = o;
            _ = addRef(o);
            return com.S_OK;
        }
        out.* = null;
        return com.E_NOINTERFACE;
    }
    fn addRef(o: *DataObject) callconv(.winapi) u32 {
        o.refs += 1;
        return o.refs;
    }
    fn release(o: *DataObject) callconv(.winapi) u32 {
        o.refs -= 1;
        if (o.refs > 0) return o.refs;
        for (o.slice()) |r| a.free(r.bytes);
        a.free(o.slice());
        a.destroy(o);
        return 0;
    }
    fn find(o: *DataObject, f: *const FORMATETC) ?Rendered {
        if (f.tymed & TYMED_HGLOBAL == 0 or f.aspect != DVASPECT_CONTENT) return null;
        for (o.slice()) |r| if (r.cf == f.cf) return r;
        return null;
    }
    fn getData(o: *DataObject, f: *const FORMATETC, m: *STGMEDIUM) callconv(.winapi) com.HRESULT {
        const r = o.find(f) orelse return DV_E_FORMATETC;
        m.* = .{ .tymed = TYMED_HGLOBAL, .hglobal = hglobal(r.bytes) orelse return com.E_FAIL, .release = null };
        return com.S_OK;
    }
    fn notImpl2(_: *DataObject, _: *const FORMATETC, _: *STGMEDIUM) callconv(.winapi) com.HRESULT {
        return E_NOTIMPL;
    }
    fn queryGetData(o: *DataObject, f: *const FORMATETC) callconv(.winapi) com.HRESULT {
        return if (o.find(f) != null) com.S_OK else DV_E_FORMATETC;
    }
    fn canonical(_: *DataObject, _: *const FORMATETC, out: *FORMATETC) callconv(.winapi) com.HRESULT {
        out.ptd = null;
        return DATA_S_SAMEFORMATETC;
    }
    fn setData(_: *DataObject, _: *const FORMATETC, _: *STGMEDIUM, _: i32) callconv(.winapi) com.HRESULT {
        // The shell's drag images: the default looks are fine.
        return E_NOTIMPL;
    }
    fn enumFormat(o: *DataObject, dir: u32, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
        if (dir != 1) { // DATADIR_GET
            out.* = null;
            return E_NOTIMPL;
        }
        const e = a.create(EnumFormats) catch return com.E_FAIL;
        e.* = .{ .vtbl = &EnumFormats.vtbl_shared, .owner = o };
        _ = addRef(o);
        out.* = e;
        return com.S_OK;
    }
    fn dadvise(_: *DataObject, _: *const FORMATETC, _: u32, _: ?*anyopaque, _: *u32) callconv(.winapi) com.HRESULT {
        return OLE_E_ADVISENOTSUPPORTED;
    }
    fn dunadvise(_: *DataObject, _: u32) callconv(.winapi) com.HRESULT {
        return OLE_E_ADVISENOTSUPPORTED;
    }
    fn enumDadvise(_: *DataObject, _: *?*anyopaque) callconv(.winapi) com.HRESULT {
        return OLE_E_ADVISENOTSUPPORTED;
    }
};

/// IEnumFORMATETC over a data object's formats.
const EnumFormats = extern struct {
    vtbl: *const Vtbl,
    refs: u32 = 1,
    owner: *DataObject,
    at: usize = 0,

    const Vtbl = extern struct {
        query: *const fn (*EnumFormats, *const com.GUID, *?*anyopaque) callconv(.winapi) com.HRESULT = query,
        add_ref: *const fn (*EnumFormats) callconv(.winapi) u32 = addRef,
        release: *const fn (*EnumFormats) callconv(.winapi) u32 = release,
        next: *const fn (*EnumFormats, u32, [*]FORMATETC, ?*u32) callconv(.winapi) com.HRESULT = next,
        skip: *const fn (*EnumFormats, u32) callconv(.winapi) com.HRESULT = skip,
        reset: *const fn (*EnumFormats) callconv(.winapi) com.HRESULT = reset,
        clone: *const fn (*EnumFormats, *?*anyopaque) callconv(.winapi) com.HRESULT = clone,
    };
    const vtbl_shared: Vtbl = .{};

    fn query(e: *EnumFormats, iid: *const com.GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
        if (iid.eql(iid_unknown) or iid.eql(iid_enum_formatetc)) {
            out.* = e;
            _ = addRef(e);
            return com.S_OK;
        }
        out.* = null;
        return com.E_NOINTERFACE;
    }
    fn addRef(e: *EnumFormats) callconv(.winapi) u32 {
        e.refs += 1;
        return e.refs;
    }
    fn release(e: *EnumFormats) callconv(.winapi) u32 {
        e.refs -= 1;
        if (e.refs > 0) return e.refs;
        _ = DataObject.release(e.owner);
        a.destroy(e);
        return 0;
    }
    fn next(e: *EnumFormats, n: u32, out: [*]FORMATETC, fetched: ?*u32) callconv(.winapi) com.HRESULT {
        const items = e.owner.slice();
        var k: u32 = 0;
        while (k < n and e.at < items.len) : (k += 1) {
            out[k] = .{ .cf = items[e.at].cf };
            e.at += 1;
        }
        if (fetched) |f| f.* = k;
        return if (k == n) com.S_OK else S_FALSE;
    }
    fn skip(e: *EnumFormats, n: u32) callconv(.winapi) com.HRESULT {
        e.at += n;
        return if (e.at <= e.owner.len) com.S_OK else S_FALSE;
    }
    fn reset(e: *EnumFormats) callconv(.winapi) com.HRESULT {
        e.at = 0;
        return com.S_OK;
    }
    fn clone(e: *EnumFormats, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
        const c = a.create(EnumFormats) catch return com.E_FAIL;
        c.* = .{ .vtbl = &vtbl_shared, .owner = e.owner, .at = e.at };
        _ = DataObject.addRef(e.owner);
        out.* = c;
        return com.S_OK;
    }
};

/// IDropSource: drops when the button goes up, gives up on Escape.
const DropSource = extern struct {
    vtbl: *const Vtbl,
    /// Escape ended the drag.
    escaped: bool = false,

    const Vtbl = extern struct {
        query: *const fn (*DropSource, *const com.GUID, *?*anyopaque) callconv(.winapi) com.HRESULT = query,
        add_ref: *const fn (*DropSource) callconv(.winapi) u32 = one,
        release: *const fn (*DropSource) callconv(.winapi) u32 = one,
        query_continue: *const fn (*DropSource, i32, u32) callconv(.winapi) com.HRESULT = queryContinue,
        give_feedback: *const fn (*DropSource, u32) callconv(.winapi) com.HRESULT = giveFeedback,
    };
    const vtbl_shared: Vtbl = .{};

    fn query(s: *DropSource, iid: *const com.GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
        if (iid.eql(iid_unknown) or iid.eql(iid_drop_source)) {
            out.* = s;
            return com.S_OK;
        }
        out.* = null;
        return com.E_NOINTERFACE;
    }
    /// It lives on `start`'s stack, which outlives the drag.
    fn one(_: *DropSource) callconv(.winapi) u32 {
        return 1;
    }
    fn queryContinue(s: *DropSource, escape: i32, keys: u32) callconv(.winapi) com.HRESULT {
        if (escape != 0) {
            s.escaped = true;
            return DRAGDROP_S_CANCEL;
        }
        if (keys & MK_LBUTTON == 0) return DRAGDROP_S_DROP;
        return com.S_OK;
    }
    fn giveFeedback(_: *DropSource, _: u32) callconv(.winapi) com.HRESULT {
        return DRAGDROP_S_USEDEFAULTCURSORS;
    }
};

var ole_ready = false;

/// Drags `data` out of the window until the button goes up (or Escape),
/// over other apps and Explorer; returns what the drop did (`.none`
/// when no target took it), whether Escape gave it up, and where it
/// ended in screen pixels. Main thread, while the left button is down.
pub fn start(data: *transfer.Data, effects: transfer.Effects) !dragdrop.ExternalEnd {
    if (!ole_ready) {
        if (com.failed(OleInitialize(null))) return error.OleInitialize;
        ole_ready = true;
    }
    const obj = try DataObject.create(data);
    defer _ = DataObject.release(obj);
    var src: DropSource = .{ .vtbl = &DropSource.vtbl_shared };
    var ok: u32 = 0;
    if (effects.copy) ok |= 1;
    if (effects.move) ok |= 2;
    if (effects.link) ok |= 4;
    var effect: u32 = 0;
    const hr = DoDragDrop(obj, &src, ok, &effect);
    var pt: w.POINT = .{};
    _ = @import("gdi.zig").GetCursorPos(&pt);
    return .{ .effect = effectOf(hr, effect), .escaped = src.escaped, .screen = .{ .x = @floatFromInt(pt.x), .y = @floatFromInt(pt.y) } };
}

/// What a drop did, by `DoDragDrop`'s result and effect.
fn effectOf(hr: com.HRESULT, effect: u32) transfer.Effect {
    if (hr != DRAGDROP_S_DROP) return .none;
    // A move the target did itself (Explorer's optimized move) shows as none.
    if (effect & 2 != 0) return .move;
    if (effect & 1 != 0) return .copy;
    if (effect & 4 != 0) return .link;
    return .none;
}

/// `ui.DragDrop.external` of a window: drags leaving it go on in other
/// windows and apps, from the next turn of the loop (outside the frame,
/// since `DoDragDrop` runs a loop of its own).
pub fn external(win: anytype) dragdrop.External {
    const Win = @TypeOf(win.*);
    const S = struct {
        const Pending = struct { dd: *dragdrop.DragDrop, win: *Win };
        fn begin(ctx: ?*anyopaque, dd: *dragdrop.DragDrop) void {
            const p = a.create(Pending) catch return dd.externalDone(.none);
            p.* = .{ .dd = dd, .win = @ptrCast(@alignCast(ctx)) };
            @import("app.zig").App.after(0, p, run);
        }
        fn run(arg: ?*anyopaque) callconv(.c) void {
            const p: *Pending = @ptrCast(@alignCast(arg));
            defer a.destroy(p);
            const act = if (p.dd.active) |*x| x else return;
            var end = start(&act.data, act.effects) catch dragdrop.ExternalEnd{ .effect = .none };
            // Pixels to points, at the window's scale.
            if (end.screen) |*pt| if (@hasDecl(Win, "dpiScale")) {
                const s: f32 = @floatCast(p.win.dpiScale());
                if (s > 0) pt.* = .{ .x = pt.x / s, .y = pt.y / s };
            };
            p.dd.externalEnd(end);
            p.win.redraw();
        }
    };
    return .{ .ctx = win, .start = S.begin };
}

test "the data object offers text and files as other apps read them" {
    const gpa = std.testing.allocator;
    var d = try transfer.Data.init(gpa, &.{
        .{ .reps = &.{ transfer.bytes(transfer.text, "héllo"), transfer.bytes("application/x-test", "raw") } },
    });
    defer d.deinit();
    const obj = try DataObject.create(&d);
    const o: com.Object = @ptrCast(obj);
    var fmt: FORMATETC = .{ .cf = CF_UNICODETEXT };
    try std.testing.expectEqual(com.S_OK, com.call(o, 5, .{&fmt}));
    var m: STGMEDIUM = undefined;
    try std.testing.expectEqual(com.S_OK, com.call(o, 3, .{ &fmt, &m }));
    const p: [*]const u16 = @ptrCast(@alignCast(w.GlobalLock(m.hglobal.?).?));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("héllo"), std.mem.sliceTo(p, 0));
    _ = w.GlobalUnlock(m.hglobal.?);
    _ = GlobalFree(m.hglobal.?);
    try std.testing.expectEqual(DV_E_FORMATETC, com.call(o, 5, .{&FORMATETC{ .cf = CF_HDROP }}));
    // Enumerated: text and the registered custom format.
    var e: ?*anyopaque = null;
    try std.testing.expectEqual(com.S_OK, com.call(o, 8, .{ @as(u32, 1), &e }));
    var got: [4]FORMATETC = undefined;
    var n: u32 = 0;
    try std.testing.expectEqual(S_FALSE, com.call(e.?, 3, .{ @as(u32, 4), &got, &n }));
    try std.testing.expectEqual(@as(u32, 2), n);
    try std.testing.expectEqual(@as(u16, registered("application/x-test")), got[1].cf);
    com.release(e);
    com.release(o);

    const path = "C:\\x\\a.txt";
    var f = try transfer.fileData(gpa, &.{path});
    defer f.deinit();
    const items = try render(&f);
    defer {
        for (items) |r| a.free(r.bytes);
        a.free(items);
    }
    try std.testing.expectEqual(@as(u16, CF_HDROP), items[0].cf);
}

test "the drop source tells a drag given up with Escape from one let go over no target" {
    var src: DropSource = .{ .vtbl = &DropSource.vtbl_shared };
    try std.testing.expectEqual(DRAGDROP_S_DROP, src.vtbl.query_continue(&src, 0, 0));
    try std.testing.expect(!src.escaped);
    try std.testing.expectEqual(DRAGDROP_S_CANCEL, src.vtbl.query_continue(&src, 1, MK_LBUTTON));
    try std.testing.expect(src.escaped);
    try std.testing.expectEqual(transfer.Effect.none, effectOf(DRAGDROP_S_CANCEL, 1));
    try std.testing.expectEqual(transfer.Effect.move, effectOf(DRAGDROP_S_DROP, 3));
}
