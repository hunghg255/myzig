//! Watching a directory tree on Windows: one ReadDirectoryChangesW over
//! the whole tree, overlapped, so that waiting for it can time out.
const std = @import("std");
const fsx = @import("fsx.zig");
const Ignore = @import("watch.zig").Ignore;
const Ctx = fsx.Ctx;

const HANDLE = *anyopaque;
const BOOL = i32;
const invalid_handle: usize = std.math.maxInt(usize);

const OVERLAPPED = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: u32 = 0,
    offset_high: u32 = 0,
    event: ?HANDLE = null,
};

extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?HANDLE) callconv(.winapi) usize;
extern "kernel32" fn ReadDirectoryChangesW(dir: HANDLE, buf: *anyopaque, len: u32, subtree: BOOL, filter: u32, returned: ?*u32, overlapped: *OVERLAPPED, routine: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CreateEventW(security: ?*anyopaque, manual: BOOL, initial: BOOL, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn GetOverlappedResult(h: HANDLE, overlapped: *OVERLAPPED, transferred: *u32, wait: BOOL) callconv(.winapi) BOOL;
extern "kernel32" fn CancelIoEx(h: HANDLE, overlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;

const file_list_directory = 0x0001;
const share_all = 0x1 | 0x2 | 0x4;
const open_existing = 3;
const backup_semantics = 0x02000000;
const flag_overlapped = 0x40000000;
// File and directory names, sizes and writes.
const filter: u32 = 0x1 | 0x2 | 0x8 | 0x10;
const wait_timeout = 0x102;
const infinite = 0xFFFFFFFF;

pub const Watcher = struct {
    ctx: Ctx,
    ignore: Ignore,
    root: []const u8,
    dir: HANDLE,
    event: HANDLE,
    overlapped: OVERLAPPED = .{},
    buf: [64 * 1024]u8 align(4) = undefined,

    pub fn init(ctx: Ctx, root: []const u8, ignore: Ignore) !*Watcher {
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(ctx.gpa, root);
        const h = CreateFileW(wide, file_list_directory, share_all, null, open_existing, backup_semantics | flag_overlapped, null);
        if (h == invalid_handle or h == 0) return error.WatchFailed;
        const dir: HANDLE = @ptrFromInt(h);
        const event = CreateEventW(null, 1, 0, null) orelse {
            _ = CloseHandle(dir);
            return error.WatchFailed;
        };
        const w = try ctx.gpa.create(Watcher);
        w.* = .{ .ctx = ctx, .ignore = ignore, .root = root, .dir = dir, .event = event };
        try w.arm();
        return w;
    }

    /// Asks for the next changes; the system queues those that happen
    /// between two calls.
    fn arm(w: *Watcher) !void {
        w.overlapped = .{ .event = w.event };
        if (ReadDirectoryChangesW(w.dir, &w.buf, w.buf.len, 1, filter, null, &w.overlapped, null) == 0) return error.WatchFailed;
    }

    /// Waits up to `timeout_ms` (null: forever) for a change that is not
    /// ignored; returns its path, relative to the root, or null on timeout.
    pub fn wait(w: *Watcher, timeout_ms: ?u32) !?[]const u8 {
        while (true) {
            const r = WaitForSingleObject(w.event, timeout_ms orelse infinite);
            if (r == wait_timeout) return null;
            if (r != 0) return error.WatchFailed;
            var n: u32 = 0;
            if (GetOverlappedResult(w.dir, &w.overlapped, &n, 0) == 0) return error.WatchFailed;
            var changed: ?[]const u8 = null;
            // n == 0: the buffer overflowed and changes were lost; take it
            // as a change of everything.
            if (n == 0) changed = "";
            var at: usize = 0;
            while (n > 0 and at + 12 <= n) {
                const next = std.mem.readInt(u32, w.buf[at..][0..4], .little);
                const action = std.mem.readInt(u32, w.buf[at + 4 ..][0..4], .little);
                const len = std.mem.readInt(u32, w.buf[at + 8 ..][0..4], .little);
                // Entries are aligned on 4 bytes.
                const units: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, w.buf[at + 12 ..][0..len]));
                const name = try std.unicode.utf16LeToUtf8Alloc(w.ctx.gpa, units);
                std.mem.replaceScalar(u8, name, '\\', '/');
                // A directory "modified" is only its entries changing, which
                // come as their own changes.
                const dir_noise = action == 3 and fsx.isDir(w.ctx.io, try w.ctx.join(&.{ w.root, name }));
                if (!w.ignore.skip(name) and !dir_noise) changed = name;
                if (next == 0) break;
                at += next;
            }
            try w.arm();
            if (changed) |c| return c;
            // Only ignored files changed: wait on (with a timeout, from the
            // start again, which only makes it longer).
        }
    }

    pub fn deinit(w: *Watcher) void {
        _ = CancelIoEx(w.dir, &w.overlapped);
        var n: u32 = 0;
        _ = GetOverlappedResult(w.dir, &w.overlapped, &n, 1);
        _ = CloseHandle(w.event);
        _ = CloseHandle(w.dir);
    }
};
