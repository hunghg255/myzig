//! The clipboard written with delayed rendering on Windows: formats whose
//! bytes are made when an app asks (`transfer.lazy`) are put on the
//! clipboard without data (SetClipboardData with NULL), owned by a hidden
//! message-only window, which renders a format on WM_RENDERFORMAT, all
//! those left before it goes (WM_RENDERALLFORMATS, `shutdown`), and lets
//! the data go when another app takes the clipboard (WM_DESTROYCLIPBOARD).
//! Formats with bytes are rendered at once. The clipboard calls go
//! through a `Board`, which tests replace: they never touch the user's.
const std = @import("std");
const w = @import("win32.zig");
const transfer = @import("../transfer.zig");
const native = @import("../transfer_native.zig");
const clipboard = @import("clipboard.zig");

extern "user32" fn RegisterClipboardFormatW(name: [*:0]const u16) callconv(.winapi) u32;
extern "user32" fn GetClipboardOwner() callconv(.winapi) ?w.HWND;

pub const WM_RENDERFORMAT = 0x0305;
pub const WM_RENDERALLFORMATS = 0x0306;
pub const WM_DESTROYCLIPBOARD = 0x0307;

const ca = std.heap.c_allocator;

/// The clipboard as the window uses it.
pub const Board = struct {
    ctx: ?*anyopaque = null,
    open: *const fn (ctx: ?*anyopaque, owner: w.HWND) bool,
    close: *const fn (ctx: ?*anyopaque) void,
    /// Empties it (the window becomes its owner).
    empty: *const fn (ctx: ?*anyopaque) void,
    owner: *const fn (ctx: ?*anyopaque) ?w.HWND,
    /// Sets format `cf` to `bytes`, or to be rendered later (null).
    set: *const fn (ctx: ?*anyopaque, cf: u32, bytes: ?[]const u8) void,
};

fn realOpen(_: ?*anyopaque, owner: w.HWND) bool {
    return w.OpenClipboard(owner) != 0;
}
fn realClose(_: ?*anyopaque) void {
    _ = w.CloseClipboard();
}
fn realEmpty(_: ?*anyopaque) void {
    _ = w.EmptyClipboard();
}
fn realOwner(_: ?*anyopaque) ?w.HWND {
    return GetClipboardOwner();
}
fn realSet(_: ?*anyopaque, cf: u32, bytes: ?[]const u8) void {
    const b = bytes orelse {
        _ = w.SetClipboardData(cf, null);
        return;
    };
    const mem = w.GlobalAlloc(0x0002, @max(b.len, 1)) orelse return;
    const p: [*]u8 = @ptrCast(w.GlobalLock(mem) orelse return);
    @memcpy(p[0..b.len], b);
    _ = w.GlobalUnlock(mem);
    _ = w.SetClipboardData(cf, mem);
}

pub const system: Board = .{ .open = realOpen, .close = realClose, .empty = realEmpty, .owner = realOwner, .set = realSet };
/// The board in use (tests replace it).
pub var board: Board = system;

fn registered(name: []const u8) u32 {
    var buf: [256]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(buf[0..255], name[0..@min(name.len, 120)]) catch return 0;
    buf[n] = 0;
    return RegisterClipboardFormatW(buf[0..n :0]);
}

/// A Windows format offered, and the MIME type it is made from.
pub const Entry = struct { cf: u32, format: []const u8, lazy: bool, rendered: bool = false };

/// What the clipboard holds of the app's: a copy of the data, its formats.
pub const Offer = struct {
    data: transfer.Data,
    entries: []Entry,

    /// The formats of `data` as Windows has them, lazy where an item's
    /// bytes of it are made on demand.
    pub fn create(data: *const transfer.Data) !*Offer {
        const o = try ca.create(Offer);
        errdefer ca.destroy(o);
        o.data = try data.clone(ca);
        errdefer o.data.deinit();
        var list: std.ArrayList(Entry) = .empty;
        errdefer list.deinit(ca);
        var arena = std.heap.ArenaAllocator.init(ca);
        defer arena.deinit();
        for (try o.data.formats(arena.allocator())) |f| {
            if (std.mem.startsWith(u8, f, transfer.value_prefix)) continue; // this process's only
            const lazy = isLazy(&o.data, f);
            const fmt = formatOf(&o.data, f); // owned by the data
            const add = struct {
                fn add(l: *std.ArrayList(Entry), cf: u32, format: []const u8, lz: bool) !void {
                    for (l.items) |e| if (e.cf == cf) return;
                    try l.append(ca, .{ .cf = cf, .format = format, .lazy = lz });
                }
            }.add;
            if (std.mem.eql(u8, f, transfer.text)) {
                try add(&list, native.CF_UNICODETEXT, fmt, lazy);
            } else if (std.mem.eql(u8, f, transfer.file_list)) {
                try add(&list, native.CF_HDROP, fmt, lazy);
            } else if (std.mem.eql(u8, f, transfer.uri_list)) {
                try add(&list, native.CF_HDROP, fmt, lazy);
                try add(&list, registered(transfer.uri_list), fmt, lazy);
            } else {
                try add(&list, registered(native.windowsName(f)), fmt, lazy);
            }
        }
        o.entries = try list.toOwnedSlice(ca);
        return o;
    }

    pub fn destroy(o: *Offer) void {
        o.data.deinit();
        ca.free(o.entries);
        ca.destroy(o);
    }

    /// The bytes of format `e` as other apps read it (null when the data
    /// has none: a URI list of no local files as CF_HDROP).
    pub fn render(o: *Offer, a: std.mem.Allocator, e: Entry) !?[]u8 {
        if (e.cf == native.CF_UNICODETEXT) {
            const t = try o.data.read(a, transfer.text);
            const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, t);
            return std.mem.sliceAsBytes(wide[0 .. wide.len + 1]);
        }
        if (e.cf == native.CF_HDROP) {
            const paths = try o.data.files(a);
            if (paths.len == 0) return null;
            return try clipboard.dropFiles(a, paths);
        }
        const b = try o.data.read(a, e.format);
        if (std.mem.eql(u8, e.format, transfer.html)) return try clipboard.encodeHtml(a, b);
        return b;
    }

    fn entry(o: *Offer, cf: u32) ?*Entry {
        for (o.entries) |*e| if (e.cf == cf) return e;
        return null;
    }

    /// Renders `cf` onto the open clipboard; once.
    pub fn renderOnto(o: *Offer, cf: u32) void {
        const e = o.entry(cf) orelse return;
        if (e.rendered) return;
        e.rendered = true;
        var arena = std.heap.ArenaAllocator.init(ca);
        defer arena.deinit();
        const bytes = (o.render(arena.allocator(), e.*) catch return) orelse return;
        board.set(board.ctx, cf, bytes);
    }
};

/// Whether an item's representation of `f` has no bytes yet.
fn isLazy(d: *const transfer.Data, f: []const u8) bool {
    for (d.items) |it| for (it) |r| if (std.mem.eql(u8, r.format, f) and r.bytes == null) return true;
    return false;
}

/// `f` as the data's own string (the offer outlives the caller's).
fn formatOf(d: *const transfer.Data, f: []const u8) []const u8 {
    for (d.items) |it| for (it) |r| if (std.mem.eql(u8, r.format, f)) return r.format;
    return f;
}

/// The window owning what the app put on the clipboard, and that.
var owner_hwnd: ?w.HWND = null;
var current: ?*Offer = null;
var registered_class = false;
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("MyZigClipboard");

fn window() !w.HWND {
    if (owner_hwnd) |h| return h;
    const inst = w.GetModuleHandleW(null);
    if (!registered_class) {
        const wc: w.WNDCLASSEXW = .{ .lpfnWndProc = wndProc, .hInstance = inst, .lpszClassName = class_name };
        if (w.RegisterClassExW(&wc) == 0) return error.RegisterClass;
        registered_class = true;
    }
    // A message-only window (HWND_MESSAGE): never shown, no broadcasts.
    const hwnd = w.CreateWindowExW(0, class_name, class_name, 0, 0, 0, 0, 0, @ptrFromInt(@as(usize, @bitCast(@as(isize, -3)))), null, inst, null) orelse return error.CreateWindow;
    owner_hwnd = hwnd;
    return hwnd;
}

fn wndProc(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    switch (msg) {
        // An app pastes a format not rendered yet: the clipboard is open.
        WM_RENDERFORMAT => if (current) |o| o.renderOnto(@truncate(wp)),
        // The window goes while the clipboard still has its formats.
        WM_RENDERALLFORMATS => if (current) |o| {
            if (!board.open(board.ctx, hwnd)) return 0;
            defer board.close(board.ctx);
            if (board.owner(board.ctx) != hwnd) return 0;
            for (o.entries) |e| if (e.lazy) o.renderOnto(e.cf);
        },
        // Another app (or a later copy) took the clipboard.
        WM_DESTROYCLIPBOARD => if (current) |o| {
            current = null;
            o.destroy();
        },
        else => return w.DefWindowProcW(hwnd, msg, wp, lp),
    }
    return 0;
}

/// Replaces the clipboard's contents with `data`'s formats: those with
/// bytes now, the lazy ones when an app asks for them (their providers
/// must stay valid while the clipboard is the app's).
pub fn writeData(_: std.mem.Allocator, data: *transfer.Data) !void {
    const hwnd = try window();
    const o = try Offer.create(data);
    if (!board.open(board.ctx, hwnd)) {
        o.destroy();
        return error.Clipboard;
    }
    defer board.close(board.ctx);
    // The previous offer goes with WM_DESTROYCLIPBOARD, sent by emptying.
    board.empty(board.ctx);
    if (current) |old| old.destroy();
    current = o;
    var arena = std.heap.ArenaAllocator.init(ca);
    defer arena.deinit();
    for (o.entries) |*e| {
        if (e.lazy) {
            board.set(board.ctx, e.cf, null);
        } else {
            e.rendered = true;
            if (o.render(arena.allocator(), e.*) catch null) |b| board.set(board.ctx, e.cf, b);
        }
    }
}

/// Renders what is still lazy onto the clipboard and closes the window:
/// for the app's end, so that what it copied stays pasteable.
pub fn shutdown() void {
    const h = owner_hwnd orelse return;
    owner_hwnd = null;
    _ = w.DestroyWindow(h);
    if (current) |o| o.destroy();
    current = null;
}

/// The window, for tests that send it the clipboard's messages.
pub fn ownerWindow() ?w.HWND {
    return owner_hwnd;
}
