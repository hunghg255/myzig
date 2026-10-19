//! A watch of a directory (with `recursive`, the directories in it) or a
//! file: the system's notifications (hints.zig) say that something changed,
//! the watch waits for quiet, looks again (snapshot.zig) and reports what is
//! different, in a batch. It does not look again until the last batch was
//! taken, so nothing is lost and nothing piles up while the app is busy.
//!
//!     const w = try Watcher.init(gpa, io, "/path/to/project", .{ .recursive = true });
//!     defer w.deinit();
//!     while (true) {
//!         const events = w.next(arena) catch break; // error.EndOfStream once closed or removed
//!         for (events) |e| std.log.info("{t} {s}", .{ e.op, e.path });
//!     }
const std = @import("std");
const snapshot = @import("snapshot.zig");
const hints = @import("hints.zig");
const Io = std.Io;

pub const Event = snapshot.Event;
pub const Op = snapshot.Op;

pub const Options = struct {
    recursive: bool = false,
    ignore: ?*const fn (ctx: ?*anyopaque, path: []const u8, is_dir: bool) bool = null,
    ignore_ctx: ?*anyopaque = null,
    /// The most files and directories a watch covers (65536 on macOS, whose
    /// watches cost no descriptor per directory).
    max_entries: usize = if (@import("builtin").os.tag == .macos) 65536 else 8192,
    /// Quiet to wait for before reporting, ms: 0 is 50, negative reports at once.
    debounce_ms: i32 = 0,
    /// The longest changes wait while more keep coming, ms.
    max_delay_ms: u32 = 500,
};

pub const Watcher = struct {
    gpa: std.mem.Allocator,
    io: Io,
    options: Options,
    /// The directory scanned: what is watched, or the directory of a file.
    dir_path: []u8,
    /// For a file watched: its name in `dir_path`.
    file_name: ?[]u8,
    seen: snapshot.Snapshot,
    hint: *hints.Hints,
    lock: Io.Mutex = .init,
    cond: Io.Condition = .init,
    hinted: bool = false,
    closed: bool = false,
    ended: bool = false,

    /// Watches `path` (a directory, or a file through its directory) and
    /// returns once everything is watched. What is there now is not reported.
    pub fn init(gpa: std.mem.Allocator, io: Io, path: []const u8, options: Options) !*Watcher {
        const st = Io.Dir.cwd().statFile(io, path, .{}) catch |err| return switch (err) {
            error.FileNotFound => error.NotFound,
            else => err,
        };
        const w = try gpa.create(Watcher);
        errdefer gpa.destroy(w);
        var opts = options;
        const is_dir = st.kind == .directory;
        if (!is_dir) opts.recursive = false;
        const dir_path = try gpa.dupe(u8, if (is_dir) path else std.fs.path.dirname(path) orelse ".");
        errdefer gpa.free(dir_path);
        const file_name = if (is_dir) null else try gpa.dupe(u8, std.fs.path.basename(path));
        errdefer if (file_name) |f| gpa.free(f);
        w.* = .{ .gpa = gpa, .io = io, .options = opts, .dir_path = dir_path, .file_name = file_name, .seen = undefined, .hint = undefined };
        w.seen = try w.scan();
        errdefer w.seen.deinit();
        w.hint = try hints.Hints.start(gpa, io, dir_path, opts.recursive, .{ .ctx = w, .func = onHint });
        w.hint.refresh(w.dirs());
        return w;
    }

    /// Stops the watch; call once nothing waits in `next` (`close` first).
    pub fn deinit(w: *Watcher) void {
        w.hint.stop();
        w.seen.deinit();
        w.gpa.free(w.dir_path);
        if (w.file_name) |f| w.gpa.free(f);
        w.gpa.destroy(w);
    }

    /// Makes `next` return error.EndOfStream, from any thread.
    pub fn close(w: *Watcher) void {
        w.lock.lockUncancelable(w.io);
        defer w.lock.unlock(w.io);
        w.closed = true;
        w.cond.broadcast(w.io);
    }

    fn onHint(ctx: ?*anyopaque) void {
        const w: *Watcher = @ptrCast(@alignCast(ctx));
        w.lock.lockUncancelable(w.io);
        defer w.lock.unlock(w.io);
        w.hinted = true;
        w.cond.broadcast(w.io);
    }

    fn scan(w: *Watcher) !snapshot.Snapshot {
        return snapshot.scan(w.gpa, w.io, w.dir_path, .{
            .recursive = w.options.recursive,
            .ignore = w.options.ignore,
            .ignore_ctx = w.options.ignore_ctx,
            .max_entries = w.options.max_entries,
        });
    }

    /// The directories seen, for systems that watch each (inotify).
    fn dirs(w: *Watcher) []const []const u8 {
        if (!w.options.recursive) return &.{};
        const a = w.seen.arena.allocator();
        var list: std.ArrayList([]const u8) = .empty;
        for (w.seen.entries.keys(), w.seen.entries.values()) |p, e| if (e.is_dir) list.append(a, p) catch {};
        return list.items;
    }

    /// Waits for the next changes and returns them (allocated with
    /// `gpa`), never empty. When what is watched (or the directory of a
    /// file watched) was removed or replaced, the last batch has a `remove`
    /// of "."; then, and once closed, error.EndOfStream. Cancelable.
    pub fn next(w: *Watcher, gpa: std.mem.Allocator) ![]Event {
        while (true) {
            if (w.ended) return error.EndOfStream;
            try w.waitForChanges();
            var fresh = w.scan() catch |err| switch (err) {
                error.NotFound, error.NotADirectory => return w.end(gpa),
                else => return err,
            };
            if (fresh.root_inode != w.seen.root_inode) {
                fresh.deinit();
                return w.end(gpa);
            }
            const all = try snapshot.diff(gpa, &w.seen, &fresh);
            w.seen.deinit();
            w.seen = fresh;
            w.hint.refresh(w.dirs());
            const events = if (w.file_name) |name| try onlyFile(gpa, all, name) else all;
            if (events.len > 0) return events;
        }
    }

    fn end(w: *Watcher, gpa: std.mem.Allocator) ![]Event {
        w.ended = true;
        const out = try gpa.alloc(Event, 1);
        out[0] = .{ .op = .remove, .path = ".", .is_dir = w.file_name == null };
        return out;
    }

    fn waitForChanges(w: *Watcher) !void {
        const io = w.io;
        try w.lock.lock(io);
        defer w.lock.unlock(io);
        while (!w.hinted and !w.closed) try w.cond.wait(io, &w.lock);
        if (w.closed) return error.EndOfStream;
        const quiet: i64 = if (w.options.debounce_ms == 0) 50 else w.options.debounce_ms;
        if (quiet > 0) {
            const first = Io.Clock.awake.now(io);
            while (true) {
                w.hinted = false;
                const waited = first.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
                const left = @as(i64, w.options.max_delay_ms) - waited;
                if (left <= 0) break;
                w.cond.waitTimeout(io, &w.lock, .{ .duration = .{ .raw = .fromMilliseconds(@min(quiet, left)), .clock = .awake } }) catch |err| switch (err) {
                    error.Timeout => if (!w.hinted) break,
                    error.Canceled => return error.Canceled,
                };
                if (w.closed) return error.EndOfStream;
            }
        }
        w.hinted = false;
    }
};

/// A file watched: its own events, as ".".
fn onlyFile(gpa: std.mem.Allocator, all: []const Event, name: []const u8) ![]Event {
    var out: std.ArrayList(Event) = .empty;
    for (all) |e| {
        if (std.mem.eql(u8, e.path, name)) {
            var c = e;
            c.path = ".";
            c.old_path = null;
            try out.append(gpa, c);
        } else if (e.op == .rename and std.mem.eql(u8, e.old_path.?, name)) {
            try out.append(gpa, .{ .op = .remove, .path = "." });
        }
    }
    return out.toOwnedSlice(gpa);
}
