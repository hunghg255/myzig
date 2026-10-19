//! Watching files on Linux: inotify on the file's folder (which sees the
//! file written, replaced by a rename, renamed or deleted), read on the
//! main thread when GLib says its descriptor is readable. Nothing polls.
const std = @import("std");
const linux = std.os.linux;
const fdwatch = @import("fdwatch.zig");

pub const Handler = *const fn (ctx: ?*anyopaque) callconv(.c) void;

pub const Watch = struct {
    fd: i32,
    name: []u8,
    ctx: ?*anyopaque,
    handler: Handler,
    source: fdwatch.Watch,

    pub fn cancel(self: *Watch) void {
        self.source.cancel();
        _ = linux.close(self.fd);
        std.heap.c_allocator.free(self.name);
        std.heap.c_allocator.destroy(self);
    }
};

const IN_MODIFY = 0x2;
const IN_ATTRIB = 0x4;
const IN_CLOSE_WRITE = 0x8;
const IN_MOVED_FROM = 0x40;
const IN_MOVED_TO = 0x80;
const IN_CREATE = 0x100;
const IN_DELETE = 0x200;
const IN_DELETE_SELF = 0x400;
const IN_MOVE_SELF = 0x800;

/// Calls `handler(ctx)` on the main thread when `path` may have changed.
pub fn watch(path: []const u8, ctx: ?*anyopaque, handler: Handler) !*Watch {
    const a = std.heap.c_allocator;
    const fd_r = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
    if (linux.errno(fd_r) != .SUCCESS) return error.WatchFailed;
    const fd: i32 = @intCast(fd_r);
    errdefer _ = linux.close(fd);
    const dir = std.fs.path.dirname(path) orelse ".";
    const dir_buf = try a.alloc(u8, dir.len + 1);
    defer a.free(dir_buf);
    @memcpy(dir_buf[0..dir.len], dir);
    dir_buf[dir.len] = 0;
    const dir_z: [*:0]const u8 = dir_buf[0..dir.len :0];
    const mask = IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE | IN_DELETE | IN_DELETE_SELF | IN_MOVE_SELF;
    if (linux.errno(linux.inotify_add_watch(fd, dir_z, mask)) != .SUCCESS) return error.WatchFailed;
    const self = try a.create(Watch);
    errdefer a.destroy(self);
    self.* = .{ .fd = fd, .name = try a.dupe(u8, std.fs.path.basename(path)), .ctx = ctx, .handler = handler, .source = undefined };
    errdefer a.free(self.name);
    self.source = try fdwatch.readable(fd, self, onReadable);
    return self;
}

fn onReadable(ctx: ?*anyopaque) callconv(.c) void {
    const self: *Watch = @ptrCast(@alignCast(ctx));
    var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
    var hit = false;
    while (true) {
        const r = linux.read(self.fd, &buf, buf.len);
        if (linux.errno(r) != .SUCCESS or r == 0) break;
        var at: usize = 0;
        while (at + @sizeOf(linux.inotify_event) <= r) {
            const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[at]));
            const name_bytes = buf[at + @sizeOf(linux.inotify_event) ..][0..ev.len];
            const name = std.mem.sliceTo(name_bytes, 0);
            // The folder itself, or the file: renames over it come as the
            // new name's MOVED_TO.
            if (ev.len == 0 or std.mem.eql(u8, name, self.name)) hit = true;
            at += @sizeOf(linux.inotify_event) + ev.len;
        }
    }
    if (hit) self.handler(self.ctx);
}
