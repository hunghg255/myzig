//! Watching files on Windows: a change notification on the file's folder
//! (which sees the file written, replaced, renamed or deleted), waited on
//! by a thread of the watch's own, which wakes the main thread through a
//! message-only window: the handler runs there. Nothing polls.
const std = @import("std");
const w = @import("win32.zig");

pub const Handler = *const fn (ctx: ?*anyopaque) callconv(.c) void;

const HANDLE = *anyopaque;
const INVALID: usize = std.math.maxInt(usize);
extern "kernel32" fn FindFirstChangeNotificationW(dir: [*:0]const u16, subtree: w.BOOL, filter: u32) callconv(.winapi) usize;
extern "kernel32" fn FindNextChangeNotification(h: HANDLE) callconv(.winapi) w.BOOL;
extern "kernel32" fn FindCloseChangeNotification(h: HANDLE) callconv(.winapi) w.BOOL;
extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual: w.BOOL, initial: w.BOOL, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetEvent(h: HANDLE) callconv(.winapi) w.BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) w.BOOL;
extern "kernel32" fn WaitForMultipleObjects(n: u32, handles: [*]const HANDLE, all: w.BOOL, ms: u32) callconv(.winapi) u32;

const FILE_NOTIFY_CHANGE_FILE_NAME = 0x1;
const FILE_NOTIFY_CHANGE_DIR_NAME = 0x2;
const FILE_NOTIFY_CHANGE_SIZE = 0x8;
const FILE_NOTIFY_CHANGE_LAST_WRITE = 0x10;
const WM_WATCH = w.WM_APP + 77;
const HWND_MESSAGE: usize = @bitCast(@as(isize, -3));

/// A watch: its handler runs on the main thread until it is canceled.
pub const Watch = struct {
    id: u32,
    ctx: ?*anyopaque,
    handler: Handler,
    change: HANDLE,
    stop: HANDLE,
    thread: std.Thread,

    pub fn cancel(self: *Watch) void {
        _ = SetEvent(self.stop);
        self.thread.join();
        _ = FindCloseChangeNotification(self.change);
        _ = CloseHandle(self.stop);
        for (table.items, 0..) |x, i| if (x == self) {
            _ = table.swapRemove(i);
            break;
        };
        std.heap.c_allocator.destroy(self);
    }
};

var table: std.ArrayList(*Watch) = .empty;
var next_id: u32 = 1;
var hwnd: ?w.HWND = null;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("MyZigFileWatch");

fn window() !w.HWND {
    if (hwnd) |h| return h;
    const inst = w.GetModuleHandleW(null);
    const wc: w.WNDCLASSEXW = .{ .lpfnWndProc = wndProc, .hInstance = inst, .lpszClassName = class_name };
    _ = w.RegisterClassExW(&wc);
    const parent: w.HWND = @ptrFromInt(HWND_MESSAGE);
    hwnd = w.CreateWindowExW(0, class_name, class_name, 0, 0, 0, 0, 0, parent, null, inst, null) orelse return error.CreateWindow;
    return hwnd.?;
}

fn wndProc(h: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    if (msg == WM_WATCH) {
        // The watch may be gone: find it by its id.
        for (table.items) |x| if (x.id == @as(u32, @truncate(wp))) {
            x.handler(x.ctx);
            break;
        };
        return 0;
    }
    return w.DefWindowProcW(h, msg, wp, lp);
}

/// Calls `handler(ctx)` on the main thread when `path` may have changed:
/// written, replaced, renamed, deleted (or another file of its folder).
pub fn watch(path: []const u8, ctx: ?*anyopaque, handler: Handler) !*Watch {
    const target = try window();
    const dir = std.fs.path.dirname(path) orelse ".";
    var buf: [1024]u16 = undefined;
    const n = try std.unicode.wtf8ToWtf16Le(buf[0 .. buf.len - 1], dir);
    buf[n] = 0;
    const filter = FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME | FILE_NOTIFY_CHANGE_SIZE | FILE_NOTIFY_CHANGE_LAST_WRITE;
    const change = FindFirstChangeNotificationW(buf[0..n :0], 0, filter);
    if (change == INVALID or change == 0) return error.WatchFailed;
    const change_h: HANDLE = @ptrFromInt(change);
    errdefer _ = FindCloseChangeNotification(change_h);
    const stop = CreateEventW(null, 1, 0, null) orelse return error.WatchFailed;
    errdefer _ = CloseHandle(stop);
    const self = try std.heap.c_allocator.create(Watch);
    errdefer std.heap.c_allocator.destroy(self);
    self.* = .{ .id = next_id, .ctx = ctx, .handler = handler, .change = change_h, .stop = stop, .thread = undefined };
    next_id +%= 1;
    try table.append(std.heap.c_allocator, self);
    errdefer _ = table.pop();
    self.thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, wait, .{ self.id, change_h, stop, target });
    return self;
}

fn wait(id: u32, change: HANDLE, stop: HANDLE, target: w.HWND) void {
    const handles = [_]HANDLE{ change, stop };
    while (true) {
        const r = WaitForMultipleObjects(2, &handles, 0, 0xFFFFFFFF);
        if (r != 0) return; // stopped, or failed
        _ = w.PostMessageW(target, WM_WATCH, id, 0);
        if (FindNextChangeNotification(change) == 0) return;
    }
}
