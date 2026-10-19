//! What a watch saw: every entry under its root (a directory, and with
//! `recursive` the directories in it) with what tells a change: kind, size,
//! modification time and file id. Watches compare two snapshots, so events
//! say what is different, not every step that made it so.
const std = @import("std");
const Io = std.Io;

pub const Op = enum { create, write, remove, rename };

pub const Event = struct {
    op: Op,
    /// Relative to what is watched, separated by slashes; "." is itself.
    path: []const u8,
    /// Where a rename moved from.
    old_path: ?[]const u8 = null,
    is_dir: bool = false,
};

pub const Entry = struct {
    is_dir: bool,
    size: u64,
    mtime: i96,
    inode: u64,
};

pub const ScanOptions = struct {
    recursive: bool = false,
    /// Leaves out a path (relative, with slashes): an ignored directory is
    /// never opened and does not count.
    ignore: ?*const fn (ctx: ?*anyopaque, path: []const u8, is_dir: bool) bool = null,
    ignore_ctx: ?*anyopaque = null,
    max_entries: usize = 8192,
};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.StringArrayHashMapUnmanaged(Entry) = .empty,
    /// The root's own id: another id means it was replaced.
    root_inode: u64 = 0,

    pub fn deinit(s: *Snapshot) void {
        s.arena.deinit();
    }

    pub fn get(s: *const Snapshot, path: []const u8) ?Entry {
        return s.entries.get(path);
    }
};

pub const ScanError = error{ NotFound, TooManyEntries, NotADirectory, PathEncoding, OutOfMemory, Unexpected, Canceled };

/// Reads what is under `dir_path` now. What cannot be read (a directory
/// without permission) is left out rather than failing the scan.
pub fn scan(gpa: std.mem.Allocator, io: Io, dir_path: []const u8, options: ScanOptions) ScanError!Snapshot {
    var snap: Snapshot = .{ .arena = .init(gpa) };
    errdefer snap.deinit();
    const a = snap.arena.allocator();
    var root = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| return switch (err) {
        error.FileNotFound => error.NotFound,
        error.NotDir => error.NotADirectory,
        error.Canceled => error.Canceled,
        else => error.Unexpected,
    };
    defer root.close(io);
    const st = root.stat(io) catch return error.Unexpected;
    snap.root_inode = @truncate(@as(u128, @bitCast(@as(i128, st.inode))));
    try walk(&snap, a, io, root, "", options);
    return snap;
}

fn walk(snap: *Snapshot, a: std.mem.Allocator, io: Io, dir: Io.Dir, prefix: []const u8, options: ScanOptions) ScanError!void {
    var it = dir.iterate();
    while (it.next(io) catch |err| return if (err == error.Canceled) error.Canceled else {}) |e| {
        if (!std.unicode.utf8ValidateSlice(e.name)) return error.PathEncoding;
        const rel = if (prefix.len == 0) try a.dupe(u8, e.name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, e.name });
        const is_dir = e.kind == .directory;
        if (options.ignore) |ig| if (ig(options.ignore_ctx, rel, is_dir)) continue;
        if (snap.entries.count() >= options.max_entries) return error.TooManyEntries;
        // Symbolic links are entries themselves: never followed.
        const st = dir.statFile(io, e.name, .{ .follow_symlinks = false }) catch continue;
        try snap.entries.put(a, rel, .{
            .is_dir = is_dir,
            .size = if (is_dir) 0 else st.size,
            .mtime = if (is_dir) 0 else st.mtime.nanoseconds,
            .inode = @truncate(@as(u128, @bitCast(@as(i128, st.inode)))),
        });
        if (is_dir and options.recursive) {
            var sub = dir.openDir(io, e.name, .{ .iterate = true, .follow_symlinks = false }) catch continue;
            defer sub.close(io);
            try walk(snap, a, io, sub, rel, options);
        }
    }
}

/// The events that turn `old` into `new`, allocated with `gpa` (an arena
/// suits it), their paths too. A remove and a create of the same file id are a rename.
pub fn diff(gpa: std.mem.Allocator, old: *const Snapshot, new: *const Snapshot) ![]Event {
    var events: std.ArrayList(Event) = .empty;
    var renamed_from: std.StringHashMapUnmanaged(void) = .empty;
    defer renamed_from.deinit(gpa);
    var removed_by_inode: std.AutoHashMapUnmanaged(u64, []const u8) = .empty;
    defer removed_by_inode.deinit(gpa);
    for (old.entries.keys(), old.entries.values()) |path, e| {
        if (new.entries.contains(path)) continue;
        if (e.inode != 0) try removed_by_inode.put(gpa, e.inode, path);
    }
    for (new.entries.keys(), new.entries.values()) |path, e| {
        if (old.entries.get(path)) |o| {
            if (o.is_dir != e.is_dir) {
                // Replaced by something of another kind.
                try events.append(gpa, .{ .op = .remove, .path = path, .is_dir = o.is_dir });
                try events.append(gpa, .{ .op = .create, .path = path, .is_dir = e.is_dir });
            } else if (!e.is_dir and (o.size != e.size or o.mtime != e.mtime or o.inode != e.inode)) {
                // Written, or replaced as editors save.
                try events.append(gpa, .{ .op = .write, .path = path });
            }
            continue;
        }
        if (e.inode != 0) if (removed_by_inode.get(e.inode)) |from| {
            if (old.entries.get(from).?.is_dir == e.is_dir) {
                try renamed_from.put(gpa, from, {});
                try events.append(gpa, .{ .op = .rename, .path = path, .old_path = from, .is_dir = e.is_dir });
                // Written while it moved.
                const o = old.entries.get(from).?;
                if (!e.is_dir and (o.size != e.size or o.mtime != e.mtime)) try events.append(gpa, .{ .op = .write, .path = path });
                continue;
            }
        };
        try events.append(gpa, .{ .op = .create, .path = path, .is_dir = e.is_dir });
    }
    for (old.entries.keys(), old.entries.values()) |path, e| {
        if (new.entries.contains(path) or renamed_from.contains(path)) continue;
        // What was in a renamed directory moved with it.
        if (insideRenamed(path, &renamed_from)) continue;
        try events.append(gpa, .{ .op = .remove, .path = path, .is_dir = e.is_dir });
    }
    // Entries that moved with a renamed directory are not news either.
    var out: std.ArrayList(Event) = .empty;
    for (events.items) |ev| {
        if (ev.op == .create or ev.op == .rename) if (movedWithDir(ev.path, events.items)) continue;
        // Copies: the snapshots go before the events do.
        var c = ev;
        c.path = try gpa.dupe(u8, ev.path);
        if (ev.old_path) |o| c.old_path = try gpa.dupe(u8, o);
        try out.append(gpa, c);
    }
    events.deinit(gpa);
    return out.toOwnedSlice(gpa);
}

fn insideRenamed(path: []const u8, renamed: *const std.StringHashMapUnmanaged(void)) bool {
    var i = path.len;
    while (std.mem.lastIndexOfScalar(u8, path[0..i], '/')) |slash| : (i = slash) {
        if (renamed.contains(path[0..slash])) return true;
    }
    return false;
}

fn movedWithDir(path: []const u8, events: []const Event) bool {
    for (events) |ev| if (ev.op == .rename and ev.is_dir and path.len > ev.path.len and
        std.mem.startsWith(u8, path, ev.path) and path[ev.path.len] == '/') return true;
    return false;
}

test "diff: creates, writes, removes, renames, a directory renamed with what is in it" {
    const gpa = std.testing.allocator;
    var old: Snapshot = .{ .arena = .init(gpa) };
    defer old.deinit();
    var new: Snapshot = .{ .arena = .init(gpa) };
    defer new.deinit();
    const oa = old.arena.allocator();
    const na = new.arena.allocator();
    try old.entries.put(oa, "a.txt", .{ .is_dir = false, .size = 1, .mtime = 1, .inode = 10 });
    try old.entries.put(oa, "b.txt", .{ .is_dir = false, .size = 1, .mtime = 1, .inode = 11 });
    try old.entries.put(oa, "gone.txt", .{ .is_dir = false, .size = 1, .mtime = 1, .inode = 12 });
    try old.entries.put(oa, "dir", .{ .is_dir = true, .size = 0, .mtime = 0, .inode = 13 });
    try old.entries.put(oa, "dir/x", .{ .is_dir = false, .size = 1, .mtime = 1, .inode = 14 });
    try new.entries.put(na, "a.txt", .{ .is_dir = false, .size = 2, .mtime = 2, .inode = 10 });
    try new.entries.put(na, "c.txt", .{ .is_dir = false, .size = 1, .mtime = 1, .inode = 11 });
    try new.entries.put(na, "new.txt", .{ .is_dir = false, .size = 0, .mtime = 3, .inode = 20 });
    try new.entries.put(na, "moved", .{ .is_dir = true, .size = 0, .mtime = 0, .inode = 13 });
    try new.entries.put(na, "moved/x", .{ .is_dir = false, .size = 1, .mtime = 1, .inode = 14 });
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ev = try diff(arena.allocator(), &old, &new);
    const want = [_]Event{
        .{ .op = .write, .path = "a.txt" },
        .{ .op = .rename, .path = "c.txt", .old_path = "b.txt" },
        .{ .op = .create, .path = "new.txt" },
        .{ .op = .rename, .path = "moved", .old_path = "dir", .is_dir = true },
        .{ .op = .remove, .path = "gone.txt" },
    };
    try std.testing.expectEqual(want.len, ev.len);
    for (want, ev) |w, g| {
        try std.testing.expectEqual(w.op, g.op);
        try std.testing.expectEqualStrings(w.path, g.path);
        try std.testing.expectEqual(w.is_dir, g.is_dir);
        if (w.old_path) |o| try std.testing.expectEqualStrings(o, g.old_path.?);
    }
}
