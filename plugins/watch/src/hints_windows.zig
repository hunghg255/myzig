//! Hints on Windows: one ReadDirectoryChangesW on the directory (its whole
//! tree when recursive), overlapped, on a thread that also waits for a
//! stop event. The directory removed ends the reads with a last hint.
const std = @import("std");
const Notify = @import("hints.zig").Notify;

const HANDLE = *anyopaque;
const OVERLAPPED = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: u32 = 0,
    offset_high: u32 = 0,
    event: ?HANDLE = null,
};

extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disposition: u32, flags: u32, template: ?HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn ReadDirectoryChangesW(dir: HANDLE, buf: *anyopaque, len: u32, subtree: i32, filter: u32, returned: ?*u32, ov: *OVERLAPPED, routine: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetOverlappedResult(h: HANDLE, ov: *OVERLAPPED, bytes: *u32, wait: i32) callconv(.winapi) i32;
extern "kernel32" fn CreateEventW(sa: ?*anyopaque, manual: i32, initial: i32, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetEvent(h: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn WaitForMultipleObjects(n: u32, handles: [*]const HANDLE, all: i32, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn CancelIoEx(h: HANDLE, ov: ?*OVERLAPPED) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) i32;

const invalid: HANDLE = @ptrFromInt(std.math.maxInt(usize));
// FILE_NOTIFY_CHANGE_FILE_NAME | DIR_NAME | SIZE | LAST_WRITE | CREATION
const filter: u32 = 0x1 | 0x2 | 0x8 | 0x10 | 0x40;

pub const Hints = struct {
    gpa: std.mem.Allocator,
    dir: HANDLE,
    stop_event: HANDLE,
    io_event: HANDLE,
    recursive: bool,
    notify: Notify,
    thread: std.Thread,
    /// The read in flight: the system holds on to it.
    ov: OVERLAPPED = .{},
    buf: [16384]u8 align(8) = undefined,

    pub fn start(gpa: std.mem.Allocator, io: std.Io, path: []const u8, recursive: bool, notify: Notify) !*Hints {
        _ = io;
        var wide: [32768:0]u16 = undefined;
        const n = try std.unicode.wtf8ToWtf16Le(&wide, path);
        wide[n] = 0;
        // FILE_LIST_DIRECTORY; share read, write, delete; OPEN_EXISTING;
        // BACKUP_SEMANTICS (a directory) | OVERLAPPED.
        const dir = CreateFileW(wide[0..n :0], 0x1, 0x7, null, 3, 0x02000000 | 0x40000000, null);
        if (dir == invalid) return error.NotFound;
        errdefer _ = CloseHandle(dir);
        const stop_event = CreateEventW(null, 1, 0, null) orelse return error.Unexpected;
        errdefer _ = CloseHandle(stop_event);
        const io_event = CreateEventW(null, 1, 0, null) orelse return error.Unexpected;
        errdefer _ = CloseHandle(io_event);
        const h = try gpa.create(Hints);
        errdefer gpa.destroy(h);
        h.* = .{ .gpa = gpa, .dir = dir, .stop_event = stop_event, .io_event = io_event, .recursive = recursive, .notify = notify, .thread = undefined };
        // The first read is issued before returning: changes from now on count.
        h.ov = .{ .event = io_event };
        if (ReadDirectoryChangesW(dir, &h.buf, h.buf.len, @intFromBool(recursive), filter, null, &h.ov, null) == 0) return error.Unexpected;
        h.thread = std.Thread.spawn(.{}, run, .{h}) catch |err| {
            _ = CancelIoEx(dir, null);
            var bytes: u32 = 0;
            _ = GetOverlappedResult(dir, &h.ov, &bytes, 1);
            return err;
        };
        return h;
    }

    /// One watch covers the tree: nothing to add.
    pub fn refresh(_: *Hints, _: []const []const u8) void {}

    pub fn stop(h: *Hints) void {
        _ = SetEvent(h.stop_event);
        h.thread.join();
        _ = CloseHandle(h.dir);
        _ = CloseHandle(h.stop_event);
        _ = CloseHandle(h.io_event);
        h.gpa.destroy(h);
    }

    fn run(h: *Hints) void {
        const ov = &h.ov;
        while (true) {
            const handles = [_]HANDLE{ h.io_event, h.stop_event };
            const which = WaitForMultipleObjects(2, &handles, 0, 0xFFFFFFFF);
            if (which != 0) {
                _ = CancelIoEx(h.dir, ov);
                var bytes: u32 = 0;
                _ = GetOverlappedResult(h.dir, ov, &bytes, 1);
                return;
            }
            var bytes: u32 = 0;
            const ok = GetOverlappedResult(h.dir, ov, &bytes, 0) != 0;
            // Changes, an overflowing buffer (0 bytes), or the directory
            // gone: look again in every case.
            h.notify.func(h.notify.ctx);
            if (!ok) return;
            ov.* = .{ .event = h.io_event };
            if (ReadDirectoryChangesW(h.dir, &h.buf, h.buf.len, @intFromBool(h.recursive), filter, null, ov, null) == 0) return;
        }
    }
};
