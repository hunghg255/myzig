//! Watching an app's files with the operating system, so that `myzig dev`
//! sleeps until something changes: ReadDirectoryChangesW on Windows (one
//! recursive watch), inotify on Linux (a watch per directory) and kqueue
//! on macOS (a vnode event per directory and file). Nothing polls.
const std = @import("std");
const builtin = @import("builtin");
const fsx = @import("fsx.zig");
const Ctx = fsx.Ctx;

/// Whether a path (relative to the root, forward slashes) is not watched.
pub const Ignore = struct {
    /// Directories and files, relative to the root.
    paths: []const []const u8 = &.{},

    /// Names never watched anywhere: build output, tools' directories, and
    /// the files the CLI writes itself.
    const names = [_][]const u8{ ".zig-cache", "zig-out", ".myzig", ".git", "node_modules", "myzig_assets.zig", "myzig.js", "myzig.d.ts" };

    pub fn skip(ig: Ignore, rel: []const u8) bool {
        var it = std.mem.tokenizeAny(u8, rel, "/\\");
        while (it.next()) |part| {
            for (names) |n| if (std.mem.eql(u8, part, n)) return true;
            // Editors' temporary files: foo.zig~, .foo.swp, 4913.
            if (std.mem.endsWith(u8, part, "~") or std.mem.endsWith(u8, part, ".swp") or std.mem.eql(u8, part, "4913")) return true;
        }
        for (ig.paths) |p| {
            if (p.len == 0) continue;
            if (std.mem.startsWith(u8, rel, p) and (rel.len == p.len or rel[p.len] == '/' or rel[p.len] == '\\')) return true;
        }
        return false;
    }
};

pub const Watcher = switch (builtin.os.tag) {
    .windows => @import("watch_windows.zig").Watcher,
    .linux => Inotify,
    .macos => Kqueue,
    else => Polling,
};

/// The directories under root (relative, root itself as ""), not ignored.
fn directories(ctx: Ctx, root: []const u8, ig: Ignore, out: *std.ArrayList([]const u8), rel: []const u8) !void {
    try out.append(ctx.gpa, rel);
    const abs = if (rel.len == 0) root else try ctx.join(&.{ root, rel });
    var d = std.Io.Dir.cwd().openDir(ctx.io, abs, .{ .iterate = true }) catch return;
    defer d.close(ctx.io);
    var it = d.iterate();
    while (try it.next(ctx.io)) |e| {
        if (e.kind != .directory) continue;
        const sub = if (rel.len == 0) try ctx.gpa.dupe(u8, e.name) else try ctx.fmt("{s}/{s}", .{ rel, e.name });
        if (ig.skip(sub)) continue;
        try directories(ctx, root, ig, out, sub);
    }
}

fn nulTerminated(gpa: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const z = try gpa.alloc(u8, s.len + 1);
    @memcpy(z[0..s.len], s);
    z[s.len] = 0;
    return z[0..s.len :0];
}

const Inotify = struct {
    ctx: Ctx,
    root: []const u8,
    ignore: Ignore,
    fd: i32,
    /// Watch descriptors to directories, relative to the root.
    dirs: std.AutoHashMapUnmanaged(i32, []const u8) = .empty,
    buf: [16 * 1024]u8 align(8) = undefined,
    const linux = std.os.linux;
    const mask: u32 = 0x2 | 0x4 | 0x8 | 0x40 | 0x80 | 0x100 | 0x200; // modify, attrib, close write, moves, create, delete
    const is_dir: u32 = 0x40000000;

    pub fn init(ctx: Ctx, root: []const u8, ignore: Ignore) !*Inotify {
        const rc = linux.inotify_init1(0x80000); // IN_CLOEXEC
        if (linux.errno(rc) != .SUCCESS) return error.WatchFailed;
        const w = try ctx.gpa.create(Inotify);
        w.* = .{ .ctx = ctx, .root = root, .ignore = ignore, .fd = @intCast(rc) };
        var list: std.ArrayList([]const u8) = .empty;
        try directories(ctx, root, ignore, &list, "");
        for (list.items) |rel| try w.add(rel);
        return w;
    }

    fn add(w: *Inotify, rel: []const u8) !void {
        const abs = try nulTerminated(w.ctx.gpa, if (rel.len == 0) w.root else try w.ctx.join(&.{ w.root, rel }));
        const rc = linux.inotify_add_watch(w.fd, abs, mask);
        if (linux.errno(rc) != .SUCCESS) return; // gone already, or too many watches
        try w.dirs.put(w.ctx.gpa, @intCast(rc), rel);
    }

    /// Waits up to `timeout_ms` (null: forever) for a change; returns the
    /// changed path, relative to the root, or null on timeout.
    pub fn wait(w: *Inotify, timeout_ms: ?u32) !?[]const u8 {
        while (true) {
            var fds = [_]linux.pollfd{.{ .fd = w.fd, .events = 0x001, .revents = 0 }};
            const pr = linux.poll(&fds, 1, if (timeout_ms) |t| @intCast(t) else -1);
            if (linux.errno(pr) == .INTR) continue;
            if (linux.errno(pr) != .SUCCESS) return error.WatchFailed;
            if (pr == 0) return null;
            const n = linux.read(w.fd, &w.buf, w.buf.len);
            if (linux.errno(n) != .SUCCESS) return error.WatchFailed;
            var at: usize = 0;
            var changed: ?[]const u8 = null;
            while (at + @sizeOf(linux.inotify_event) <= n) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(&w.buf[at]));
                const name = std.mem.sliceTo(w.buf[at + @sizeOf(linux.inotify_event) ..][0..ev.len], 0);
                at += @sizeOf(linux.inotify_event) + ev.len;
                const dir = w.dirs.get(ev.wd) orelse continue;
                const rel = if (dir.len == 0) try w.ctx.gpa.dupe(u8, name) else try w.ctx.fmt("{s}/{s}", .{ dir, name });
                if (w.ignore.skip(rel)) continue;
                // A new directory is watched too, and what it holds.
                if (ev.mask & is_dir != 0 and ev.mask & (0x100 | 0x80) != 0) {
                    var list: std.ArrayList([]const u8) = .empty;
                    try directories(w.ctx, w.root, w.ignore, &list, rel);
                    for (list.items) |r| try w.add(r);
                }
                changed = rel;
            }
            if (changed) |c| return c;
        }
    }

    pub fn deinit(w: *Inotify) void {
        _ = linux.close(w.fd);
    }
};

const Kqueue = struct {
    ctx: Ctx,
    root: []const u8,
    ignore: Ignore,
    kq: c_int,
    /// Open descriptors, and the paths they watch (relative).
    fds: std.ArrayList(c_int) = .empty,
    paths: std.ArrayList([]const u8) = .empty,

    const Kevent = extern struct { ident: usize, filter: i16, flags: u16, fflags: u32, data: isize, udata: usize };
    const Timespec = extern struct { sec: isize, nsec: isize };
    extern "c" fn kqueue() c_int;
    extern "c" fn kevent(kq: c_int, changes: [*]const Kevent, n: c_int, events: [*]Kevent, nevents: c_int, timeout: ?*const Timespec) c_int;
    extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" fn close(fd: c_int) c_int;
    const o_evtonly = 0x8000;
    const evfilt_vnode: i16 = -4;
    const ev_add_clear: u16 = 0x0001 | 0x0004 | 0x0020; // add, enable, clear
    const notes: u32 = 0x1 | 0x2 | 0x4 | 0x8 | 0x20; // delete, write, extend, attrib, rename
    /// Descriptors are a limited resource: past this many, files are not
    /// watched one by one (their directories still are).
    const max_fds = 4096;

    pub fn init(ctx: Ctx, root: []const u8, ignore: Ignore) !*Kqueue {
        const kq = kqueue();
        if (kq < 0) return error.WatchFailed;
        const w = try ctx.gpa.create(Kqueue);
        w.* = .{ .ctx = ctx, .root = root, .ignore = ignore, .kq = kq };
        try w.scan();
        return w;
    }

    fn watch(w: *Kqueue, rel: []const u8) !void {
        if (w.fds.items.len >= max_fds) return;
        const abs = try nulTerminated(w.ctx.gpa, if (rel.len == 0) w.root else try w.ctx.join(&.{ w.root, rel }));
        const fd = open(abs, o_evtonly);
        if (fd < 0) return;
        const change: Kevent = .{ .ident = @intCast(fd), .filter = evfilt_vnode, .flags = ev_add_clear, .fflags = notes, .data = 0, .udata = w.fds.items.len };
        var none: [1]Kevent = undefined;
        if (kevent(w.kq, @ptrCast(&change), 1, &none, 0, null) < 0) {
            _ = close(fd);
            return;
        }
        try w.fds.append(w.ctx.gpa, fd);
        try w.paths.append(w.ctx.gpa, rel);
    }

    /// Watches every directory and file again (after entries changed).
    fn scan(w: *Kqueue) !void {
        for (w.fds.items) |fd| _ = close(fd);
        w.fds.clearRetainingCapacity();
        w.paths.clearRetainingCapacity();
        var list: std.ArrayList([]const u8) = .empty;
        try directories(w.ctx, w.root, w.ignore, &list, "");
        for (list.items) |rel| {
            try w.watch(rel);
            const abs = if (rel.len == 0) w.root else try w.ctx.join(&.{ w.root, rel });
            var d = std.Io.Dir.cwd().openDir(w.ctx.io, abs, .{ .iterate = true }) catch continue;
            defer d.close(w.ctx.io);
            var it = d.iterate();
            while (try it.next(w.ctx.io)) |e| {
                if (e.kind != .file) continue;
                const f = if (rel.len == 0) try w.ctx.gpa.dupe(u8, e.name) else try w.ctx.fmt("{s}/{s}", .{ rel, e.name });
                if (!w.ignore.skip(f)) try w.watch(f);
            }
        }
    }

    pub fn wait(w: *Kqueue, timeout_ms: ?u32) !?[]const u8 {
        var events: [16]Kevent = undefined;
        const ts: Timespec = if (timeout_ms) |t| .{ .sec = @intCast(t / 1000), .nsec = @intCast(@as(u64, t % 1000) * 1_000_000) } else .{ .sec = 0, .nsec = 0 };
        const none: [0]Kevent = .{};
        const n = kevent(w.kq, &none, 0, &events, events.len, if (timeout_ms != null) &ts else null);
        if (n < 0) return error.WatchFailed;
        if (n == 0) return null;
        const first = w.paths.items[events[0].udata];
        // Entries added, removed or renamed: watch what is there now.
        try w.scan();
        return first;
    }

    pub fn deinit(w: *Kqueue) void {
        for (w.fds.items) |fd| _ = close(fd);
        _ = close(w.kq);
    }
};

/// Other systems: nothing is watched (myzig runs on macOS, Linux and Windows).
const Polling = struct {
    pub fn init(ctx: Ctx, root: []const u8, ignore: Ignore) !*Polling {
        _ = root;
        _ = ignore;
        return ctx.gpa.create(Polling);
    }
    pub fn wait(_: *Polling, _: ?u32) !?[]const u8 {
        return null;
    }
    pub fn deinit(_: *Polling) void {}
};

test Ignore {
    const ig: Ignore = .{ .paths = &.{ "dist", "frontend" } };
    try std.testing.expect(ig.skip(".zig-cache/o/x"));
    try std.testing.expect(ig.skip("src/.zig-cache"));
    try std.testing.expect(ig.skip("dist"));
    try std.testing.expect(ig.skip("frontend/index.html"));
    try std.testing.expect(ig.skip("src/main.zig~"));
    try std.testing.expect(!ig.skip("distance.zig"));
    try std.testing.expect(!ig.skip("src/main.zig"));
}

test "a change wakes the watcher" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx: Ctx = .{ .gpa = arena.allocator(), .io = std.testing.io, .env = undefined };
    const root = try std.fs.path.join(ctx.gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const abs = try fsx.absolute(ctx, root);
    try fsx.write(ctx.io, try ctx.join(&.{ abs, "src", "main.zig" }), "a");
    try fsx.makeDir(ctx.io, try ctx.join(&.{ abs, "zig-out" }));
    const w = try Watcher.init(ctx, abs, .{});
    defer w.deinit();
    // Nothing changed yet; ignored files don't count.
    try std.testing.expect(try w.wait(0) == null);
    try fsx.write(ctx.io, try ctx.join(&.{ abs, "zig-out", "x" }), "x");
    try std.testing.expect(try w.wait(0) == null);
    try fsx.write(ctx.io, try ctx.join(&.{ abs, "src", "main.zig" }), "b");
    // The event is the system's to deliver: wait for it (no timing).
    const changed = (try w.wait(null)).?;
    try std.testing.expect(std.mem.endsWith(u8, changed, "main.zig"));
}
