//! Recovery copies of documents: what a document's unsaved changes are,
//! written a moment after the user stops editing, as VS Code's backups
//! and Zed's database keep them, so that a crash, a forced quit or a quit
//! that keeps documents loses nothing. The next launch opens them again,
//! edited; a file that changed meanwhile is in conflict, as its stamp says.
//!
//! Each kind of documents keeps them in `<data>/Recovery/<kind>`, in a
//! session of the running instance which a locked file tells is alive:
//! another instance leaves it alone, and the next launch takes the
//! sessions no instance holds. A session's `index` lists its copies, one
//! a line: `id \t path \t name \t mtime \t size`.
const std = @import("std");
const file = @import("document_file.zig");

pub const Entry = struct {
    /// The copy's file name in the session: digits and letters only.
    id: []const u8,
    /// The document's file; empty for an untitled document.
    path: []const u8 = "",
    /// The name of an untitled document.
    name: []const u8 = "",
    stamp: file.Stamp = .{},
};

/// A copy no running instance holds, claimed by this one.
pub const Orphan = struct {
    entry: Entry,
    /// The copy's bytes, as the document's `write` made them.
    bytes: []u8,
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The kind's directory: `<data>/Recovery/<kind>`.
    root: []u8,
    /// This instance's session, made with the first copy.
    session: ?[]u8 = null,
    lock: ?std.Io.File = null,
    entries: std.ArrayList(Entry) = .empty,

    /// `data` is the app's data directory, `kind` names the kind of
    /// documents (any characters: those not safe in a file name become -).
    pub fn init(gpa: std.mem.Allocator, io: std.Io, data: []const u8, kind: []const u8) !Store {
        const safe = try gpa.dupe(u8, kind);
        defer gpa.free(safe);
        for (safe) |*ch| if (!std.ascii.isAlphanumeric(ch.*) and ch.* != '-') {
            ch.* = '-';
        };
        return .{ .gpa = gpa, .io = io, .root = try std.fs.path.join(gpa, &.{ data, "Recovery", safe }) };
    }

    /// Unlocks the session, removing it when it keeps no copy (at quit).
    pub fn deinit(s: *Store) void {
        if (s.lock) |l| l.close(s.io);
        if (s.session) |dir| {
            if (s.entries.items.len == 0) std.Io.Dir.cwd().deleteTree(s.io, dir) catch {};
            s.gpa.free(dir);
        }
        for (s.entries.items) |e| freeEntry(s.gpa, e);
        s.entries.deinit(s.gpa);
        s.gpa.free(s.root);
    }

    /// The session's directory, made and locked the first time.
    fn sessionDir(s: *Store) ![]const u8 {
        if (s.session) |d| return d;
        var name: [12]u8 = undefined;
        randomName(s.io, &name);
        const dir = try std.fs.path.join(s.gpa, &.{ s.root, &name });
        errdefer s.gpa.free(dir);
        try std.Io.Dir.cwd().createDirPath(s.io, dir);
        const lock_path = try std.fs.path.join(s.gpa, &.{ dir, "lock" });
        defer s.gpa.free(lock_path);
        s.lock = try std.Io.Dir.cwd().createFile(s.io, lock_path, .{ .lock = .exclusive, .lock_nonblocking = true, .truncate = false });
        s.session = dir;
        return dir;
    }

    /// Writes the copy of a document (`bytes`) and its entry.
    pub fn save(s: *Store, e: Entry, bytes: []const u8) !void {
        if (!validId(e.id)) return error.BadId;
        const dir = try s.sessionDir();
        const path = try std.fs.path.join(s.gpa, &.{ dir, e.id });
        defer s.gpa.free(path);
        try file.writeAppFile(s.gpa, s.io, path, bytes);
        const owned = try dupeEntry(s.gpa, e);
        if (s.find(e.id)) |i| {
            freeEntry(s.gpa, s.entries.items[i]);
            s.entries.items[i] = owned;
        } else try s.entries.append(s.gpa, owned);
        try s.writeIndex();
    }

    /// Forgets the copy `id` (saved, reverted, closed without saving).
    pub fn remove(s: *Store, id: []const u8) void {
        const i = s.find(id) orelse return;
        freeEntry(s.gpa, s.entries.orderedRemove(i));
        s.writeIndex() catch {};
        const dir = s.session orelse return;
        const path = std.fs.path.join(s.gpa, &.{ dir, id }) catch return;
        defer s.gpa.free(path);
        std.Io.Dir.cwd().deleteFile(s.io, path) catch {};
    }

    pub fn has(s: *Store, id: []const u8) bool {
        return s.find(id) != null;
    }

    fn find(s: *Store, id: []const u8) ?usize {
        for (s.entries.items, 0..) |e, i| if (std.mem.eql(u8, e.id, id)) return i;
        return null;
    }

    fn writeIndex(s: *Store) !void {
        const dir = s.session orelse return;
        var aw: std.Io.Writer.Allocating = .init(s.gpa);
        defer aw.deinit();
        for (s.entries.items) |e| try aw.writer.print("{s}\t{s}\t{s}\t{d}\t{d}\n", .{ e.id, e.path, e.name, e.stamp.mtime, e.stamp.size });
        const path = try std.fs.path.join(s.gpa, &.{ dir, "index" });
        defer s.gpa.free(path);
        try file.writeAppFile(s.gpa, s.io, path, aw.written());
    }

    /// Takes the sessions no instance holds (a crash's, a quit's that kept
    /// documents): their copies, which the caller opens and then frees
    /// with `freeOrphans`. The sessions are removed: the documents opened
    /// from them keep their copies in this session.
    pub fn claim(s: *Store) ![]Orphan {
        var out: std.ArrayList(Orphan) = .empty;
        errdefer freeOrphans(s.gpa, out.items);
        const cwd = std.Io.Dir.cwd();
        var root = cwd.openDir(s.io, s.root, .{ .iterate = true }) catch return out.toOwnedSlice(s.gpa);
        defer root.close(s.io);
        var claimed: std.ArrayList([]u8) = .empty;
        defer {
            for (claimed.items) |d| s.gpa.free(d);
            claimed.deinit(s.gpa);
        }
        var it = root.iterate();
        while (try it.next(s.io)) |ent| {
            if (ent.kind != .directory) continue;
            const dir = try std.fs.path.join(s.gpa, &.{ s.root, ent.name });
            if (s.session) |own| if (std.mem.eql(u8, own, dir)) {
                s.gpa.free(dir);
                continue;
            };
            try claimed.append(s.gpa, dir);
        }
        for (claimed.items) |dir| {
            const lock_path = try std.fs.path.join(s.gpa, &.{ dir, "lock" });
            defer s.gpa.free(lock_path);
            // Alive: another instance holds its lock.
            const lock = cwd.createFile(s.io, lock_path, .{ .lock = .exclusive, .lock_nonblocking = true, .truncate = false }) catch continue;
            defer {
                lock.close(s.io);
                cwd.deleteTree(s.io, dir) catch {};
            }
            const index_path = try std.fs.path.join(s.gpa, &.{ dir, "index" });
            defer s.gpa.free(index_path);
            const index = file.readAll(s.gpa, s.io, index_path, 1 << 20) catch continue;
            defer s.gpa.free(index);
            var lines = std.mem.splitScalar(u8, index, '\n');
            while (lines.next()) |line| {
                const e = parseLine(line) orelse continue;
                const copy_path = try std.fs.path.join(s.gpa, &.{ dir, e.id });
                defer s.gpa.free(copy_path);
                const bytes = file.readAll(s.gpa, s.io, copy_path, 1 << 30) catch continue;
                errdefer s.gpa.free(bytes);
                try out.append(s.gpa, .{ .entry = try dupeEntry(s.gpa, e), .bytes = bytes });
            }
        }
        return out.toOwnedSlice(s.gpa);
    }
};

pub fn freeOrphans(gpa: std.mem.Allocator, orphans: []const Orphan) void {
    for (orphans) |o| {
        freeEntry(gpa, o.entry);
        gpa.free(o.bytes);
    }
    gpa.free(orphans);
}

fn parseLine(line: []const u8) ?Entry {
    var f = std.mem.splitScalar(u8, line, '\t');
    const id = f.next() orelse return null;
    if (!validId(id)) return null;
    const path = f.next() orelse return null;
    const name = f.next() orelse return null;
    const mtime = std.fmt.parseInt(i96, f.next() orelse return null, 10) catch return null;
    const size = std.fmt.parseInt(u64, f.next() orelse return null, 10) catch return null;
    return .{ .id = id, .path = path, .name = name, .stamp = .{ .mtime = mtime, .size = size } };
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |ch| if (!std.ascii.isAlphanumeric(ch)) return false;
    return !std.mem.eql(u8, id, "index") and !std.mem.eql(u8, id, "lock");
}

fn dupeEntry(gpa: std.mem.Allocator, e: Entry) !Entry {
    // Tabs and newlines would break the index: paths keep neither.
    for ([_][]const u8{ e.path, e.name }) |s| if (std.mem.indexOfAny(u8, s, "\t\n") != null) return error.BadName;
    const id = try gpa.dupe(u8, e.id);
    errdefer gpa.free(id);
    const path = try gpa.dupe(u8, e.path);
    errdefer gpa.free(path);
    return .{ .id = id, .path = path, .name = try gpa.dupe(u8, e.name), .stamp = e.stamp };
}

fn freeEntry(gpa: std.mem.Allocator, e: Entry) void {
    gpa.free(e.id);
    gpa.free(e.path);
    gpa.free(e.name);
}

var name_counter: std.atomic.Value(u64) = .init(0);

/// A name no other session has: the clock and a counter, in base 36.
pub fn randomName(io: std.Io, out: []u8) void {
    const now: u64 = @truncate(@as(u96, @bitCast(std.Io.Timestamp.now(io, .real).nanoseconds)));
    var x = now ^ (name_counter.fetchAdd(1, .monotonic) *% 0x9e3779b97f4a7c15);
    x = std.hash.Wyhash.hash(x, std.mem.asBytes(&x));
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    for (out) |*ch| {
        ch.* = digits[x % 36];
        x = x / 36 ^ std.hash.Wyhash.hash(x, "n");
    }
}

test "recovery copies survive a crash and are claimed once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(data);

    // A session that crashed: its copies stay, its lock is gone.
    {
        var crashed = try Store.init(gpa, io, data, "Markdown Document-md");
        try crashed.save(.{ .id = "a1", .path = "/x/notes.md", .stamp = .{ .mtime = 5, .size = 3 } }, "edited");
        try crashed.save(.{ .id = "b2", .name = "Untitled 2" }, "new");
        try crashed.save(.{ .id = "c3", .name = "Untitled 3" }, "gone");
        crashed.remove("c3");
        // A crash leaves without deinit: unlock it as the system would.
        crashed.lock.?.close(io);
        crashed.lock = null;
        for (crashed.entries.items) |e| freeEntry(gpa, e);
        crashed.entries.clearRetainingCapacity();
        crashed.entries.deinit(gpa);
        gpa.free(crashed.session.?);
        gpa.free(crashed.root);
    }
    // A running instance's session is left alone.
    var alive = try Store.init(gpa, io, data, "Markdown Document-md");
    defer alive.deinit();
    try alive.save(.{ .id = "z9", .name = "Untitled" }, "mine");

    var next = try Store.init(gpa, io, data, "Markdown Document-md");
    defer next.deinit();
    const orphans = try next.claim();
    defer freeOrphans(gpa, orphans);
    try std.testing.expectEqual(@as(usize, 2), orphans.len);
    for (orphans) |o| {
        if (std.mem.eql(u8, o.entry.id, "a1")) {
            try std.testing.expectEqualStrings("/x/notes.md", o.entry.path);
            try std.testing.expectEqualStrings("edited", o.bytes);
            try std.testing.expectEqual(@as(u64, 3), o.entry.stamp.size);
        } else {
            try std.testing.expectEqualStrings("b2", o.entry.id);
            try std.testing.expectEqualStrings("Untitled 2", o.entry.name);
        }
    }
    const again = try next.claim();
    defer freeOrphans(gpa, again);
    try std.testing.expectEqual(@as(usize, 0), again.len);
}
