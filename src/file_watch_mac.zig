//! Watching files on macOS: a kqueue with vnode events on the file and its
//! folder (which sees the file replaced by a rename, as editors save),
//! read on the main thread when libdispatch says the queue is readable.
//! After every event the file is opened again: a replaced file is a new
//! vnode. Nothing polls.
const std = @import("std");
const fdwatch = @import("fdwatch.zig");

pub const Handler = *const fn (ctx: ?*anyopaque) callconv(.c) void;

const Kevent = extern struct {
    ident: usize,
    filter: i16,
    flags: u16,
    fflags: u32,
    data: isize,
    udata: ?*anyopaque,
};
extern "c" fn kqueue() c_int;
extern "c" fn kevent(kq: c_int, changes: ?[*]const Kevent, n: c_int, events: ?[*]Kevent, m: c_int, timeout: ?*const extern struct { sec: isize, nsec: isize }) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;

const EVFILT_VNODE: i16 = -4;
const EV_ADD: u16 = 0x1;
const EV_CLEAR: u16 = 0x20;
const NOTE_DELETE: u32 = 0x1;
const NOTE_WRITE: u32 = 0x2;
const NOTE_EXTEND: u32 = 0x4;
const NOTE_ATTRIB: u32 = 0x8;
const NOTE_RENAME: u32 = 0x20;
const O_EVTONLY: c_int = 0x8000;

pub const Watch = struct {
    kq: c_int,
    file_fd: c_int = -1,
    dir_fd: c_int = -1,
    path: [:0]u8,
    ctx: ?*anyopaque,
    handler: Handler,
    source: fdwatch.Watch = undefined,

    pub fn cancel(self: *Watch) void {
        self.source.cancel();
        if (self.file_fd >= 0) _ = close(self.file_fd);
        if (self.dir_fd >= 0) _ = close(self.dir_fd);
        _ = close(self.kq);
        std.heap.c_allocator.free(self.path);
        std.heap.c_allocator.destroy(self);
    }

    fn add(self: *Watch, fd: c_int) void {
        const ev: Kevent = .{ .ident = @intCast(fd), .filter = EVFILT_VNODE, .flags = EV_ADD | EV_CLEAR, .fflags = NOTE_DELETE | NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_RENAME, .data = 0, .udata = null };
        _ = kevent(self.kq, @ptrCast(&ev), 1, null, 0, null);
    }

    /// (Re)opens the file: after a replace it is another vnode.
    fn openFile(self: *Watch) void {
        if (self.file_fd >= 0) _ = close(self.file_fd);
        self.file_fd = open(self.path.ptr, O_EVTONLY);
        if (self.file_fd >= 0) self.add(self.file_fd);
    }
};

/// Calls `handler(ctx)` on the main thread when `path` may have changed.
pub fn watch(path: []const u8, ctx: ?*anyopaque, handler: Handler) !*Watch {
    const a = std.heap.c_allocator;
    const kq = kqueue();
    if (kq < 0) return error.WatchFailed;
    errdefer _ = close(kq);
    const self = try a.create(Watch);
    errdefer a.destroy(self);
    const owned = try a.alloc(u8, path.len + 1);
    @memcpy(owned[0..path.len], path);
    owned[path.len] = 0;
    self.* = .{ .kq = kq, .path = owned[0..path.len :0], .ctx = ctx, .handler = handler };
    errdefer a.free(owned);
    const dir = std.fs.path.dirname(path) orelse ".";
    var buf: [1024]u8 = undefined;
    if (dir.len < buf.len) {
        @memcpy(buf[0..dir.len], dir);
        buf[dir.len] = 0;
        self.dir_fd = open(buf[0..dir.len :0], O_EVTONLY);
        if (self.dir_fd >= 0) self.add(self.dir_fd);
    }
    self.openFile();
    self.source = try fdwatch.readable(kq, self, onReadable);
    return self;
}

fn onReadable(ctx: ?*anyopaque) callconv(.c) void {
    const self: *Watch = @ptrCast(@alignCast(ctx));
    var events: [16]Kevent = undefined;
    const zero: extern struct { sec: isize, nsec: isize } = .{ .sec = 0, .nsec = 0 };
    const n = kevent(self.kq, null, 0, &events, events.len, @ptrCast(&zero));
    if (n <= 0) return;
    self.openFile();
    self.handler(self.ctx);
}
