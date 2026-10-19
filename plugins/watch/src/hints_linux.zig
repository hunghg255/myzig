//! Hints on Linux: an inotify instance per watch with a watch on the
//! directory and, when recursive, on each directory seen (`refresh`), read
//! on a thread that polls it and an eventfd that stops it.
const std = @import("std");
const linux = std.os.linux;
const Notify = @import("hints.zig").Notify;

// IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO |
// IN_CREATE | IN_DELETE | IN_DELETE_SELF | IN_MOVE_SELF | IN_ONLYDIR
const mask: u32 = 0x2 | 0x4 | 0x8 | 0x40 | 0x80 | 0x100 | 0x200 | 0x400 | 0x800 | 0x01000000;

pub const Hints = struct {
    gpa: std.mem.Allocator,
    fd: i32,
    stop_fd: i32,
    root: []u8,
    notify: Notify,
    thread: std.Thread,

    pub fn start(gpa: std.mem.Allocator, io: std.Io, path: []const u8, recursive: bool, notify: Notify) !*Hints {
        _ = io;
        _ = recursive;
        const fd_rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (linux.errno(fd_rc) != .SUCCESS) return error.InotifyUnavailable;
        const fd: i32 = @intCast(fd_rc);
        errdefer _ = linux.close(fd);
        const ev_rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(ev_rc) != .SUCCESS) return error.Unexpected;
        const stop_fd: i32 = @intCast(ev_rc);
        errdefer _ = linux.close(stop_fd);
        const h = try gpa.create(Hints);
        errdefer gpa.destroy(h);
        h.* = .{ .gpa = gpa, .fd = fd, .stop_fd = stop_fd, .root = try gpa.dupe(u8, path), .notify = notify, .thread = undefined };
        errdefer gpa.free(h.root);
        if (!h.add("")) return error.NotFound;
        h.thread = try std.Thread.spawn(.{}, run, .{h});
        return h;
    }

    /// Watches the directories seen (relative to the root); watching one
    /// twice is the same watch, and removed ones drop out on their own.
    pub fn refresh(h: *Hints, dirs: []const []const u8) void {
        for (dirs) |d| _ = h.add(d);
    }

    fn add(h: *Hints, rel: []const u8) bool {
        var buf: [4096]u8 = undefined;
        const p = (if (rel.len == 0) std.fmt.bufPrint(&buf, "{s}\x00", .{h.root}) else std.fmt.bufPrint(&buf, "{s}/{s}\x00", .{ h.root, rel })) catch return false;
        const rc = linux.inotify_add_watch(h.fd, @ptrCast(p.ptr), mask);
        return linux.errno(rc) == .SUCCESS;
    }

    pub fn stop(h: *Hints) void {
        const one: u64 = 1;
        _ = linux.write(h.stop_fd, std.mem.asBytes(&one), 8);
        h.thread.join();
        _ = linux.close(h.fd);
        _ = linux.close(h.stop_fd);
        h.gpa.free(h.root);
        h.gpa.destroy(h);
    }

    fn run(h: *Hints) void {
        var buf: [16384]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            var fds = [_]linux.pollfd{
                .{ .fd = h.fd, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = h.stop_fd, .events = linux.POLL.IN, .revents = 0 },
            };
            const rc = linux.poll(&fds, fds.len, -1);
            if (linux.errno(rc) == .INTR) continue;
            if (linux.errno(rc) != .SUCCESS or fds[1].revents != 0) return;
            // Drain what is there; what it says matters less than that it came.
            while (linux.errno(linux.read(h.fd, &buf, buf.len)) == .SUCCESS) {}
            h.notify.func(h.notify.ctx);
        }
    }
};
