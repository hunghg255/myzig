//! Documents' files: what a file was when a document last read or wrote it
//! (its stamp), writing a file whole or not at all, and the names of
//! documents. The same on every platform.
const std = @import("std");
const builtin = @import("builtin");

/// A file's modification time and size, as a document last read or wrote
/// it: another app changed the file when they differ.
pub const Stamp = struct {
    mtime: i96 = 0,
    size: u64 = 0,
    /// The file's identity, by which a document finds its file where
    /// another app renamed it (`findRenamed`). It says nothing of the
    /// content: `eql` ignores it, and recovery doesn't keep it.
    file: ?Identity = null,

    pub fn eql(a: Stamp, b: Stamp) bool {
        return a.mtime == b.mtime and a.size == b.size;
    }
};

/// A file's identity, as the file system knows it: its inode (its file
/// index on Windows) within its folder's volume, with its kind, as a file
/// never changes kind but a file system such as ext4 gives a freed inode
/// to the next file made, so that a directory removed and a link made in
/// its place can share an inode.
pub const Identity = struct {
    inode: std.Io.File.INode,
    kind: std.Io.File.Kind,

    pub fn of(st: std.Io.File.Stat) ?Identity {
        // Zero where the file system has no such numbers.
        if (st.inode == 0) return null;
        return .{ .inode = st.inode, .kind = st.kind };
    }

    pub fn eql(a: Identity, b: Identity) bool {
        return a.inode == b.inode and a.kind == b.kind;
    }
};

/// The stamp of `path`, or null when it doesn't exist (or isn't a file).
pub fn stampOf(io: std.Io, path: []const u8) ?Stamp {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    if (st.kind == .directory) return null;
    return .{ .mtime = st.mtime.nanoseconds, .size = st.size, .file = Identity.of(st) };
}

/// The path of the file in `dir` that is `id`, or null: where another app
/// renamed a document's file. Caller frees it.
pub fn findRenamed(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8, id: Identity) ?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return null) |entry| {
        // Entries carry no inode everywhere: each is looked at.
        const st = dir.statFile(io, entry.name, .{}) catch continue;
        const other = Identity.of(st) orelse continue;
        if (other.eql(id)) return std.fs.path.join(gpa, &.{ dir_path, entry.name }) catch null;
    }
    return null;
}

/// Whether the user may write `path` (false for read-only files).
pub fn writable(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{ .write = true }) catch return false;
    return true;
}

/// Reads the whole file (at most `limit` bytes). Caller frees.
pub fn readAll(gpa: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(limit));
}

var sibling_counter: std.atomic.Value(u32) = .init(0);

/// Writes `bytes` to `path` as `NSDocument` and GIO do: into a new file
/// next to it, flushed to the disk, which then replaces it, so that a
/// crash or a full disk never leaves half a file. Where no file can be
/// created beside it (a folder the user can't add to), it is written in
/// place. Returns the new stamp.
pub fn writeSafely(gpa: std.mem.Allocator, io: std.Io, path: []const u8, bytes: []const u8) !Stamp {
    const dir = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    const cwd = std.Io.Dir.cwd();
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        const n = sibling_counter.fetchAdd(1, .monotonic);
        const tmp_name = try std.fmt.allocPrint(gpa, ".{s}.myzig-{d}", .{ base, n });
        defer gpa.free(tmp_name);
        const tmp = try std.fs.path.join(gpa, &.{ dir, tmp_name });
        defer gpa.free(tmp);
        if (writeAndSync(io, tmp, bytes, true)) {
            cwd.rename(tmp, cwd, path, io) catch |err| {
                cwd.deleteFile(io, tmp) catch {};
                return err;
            };
        } else |err| switch (err) {
            // Left by another instance, or a crash: another name.
            error.PathAlreadyExists => if (attempt < 100) continue else return err,
            error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => try writeAndSync(io, path, bytes, false),
            else => return err,
        }
        break;
    }
    return stampOf(io, path) orelse error.FileNotFound;
}

fn writeAndSync(io: std.Io, path: []const u8, bytes: []const u8, exclusive: bool) !void {
    const f = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = exclusive });
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
    f.sync(io) catch {};
}

/// A file of the app's own (an index, a recovery copy): written whole,
/// in a folder that is made if it is missing.
pub fn writeAppFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
    _ = try writeSafely(gpa, io, path, bytes);
}

/// The name a document shows: its file's name, or its untitled name.
pub fn displayName(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

/// "Untitled", "Untitled 2"… (`base` is the localized "Untitled").
pub fn untitledName(buf: []u8, base: []const u8, n: u32) []const u8 {
    if (n <= 1) return base;
    return std.fmt.bufPrint(buf, "{s} {d}", .{ base, n }) catch base;
}

/// The number of an untitled name ("Untitled 3" is 3, "Untitled" 1), or 0.
pub fn untitledNumber(name: []const u8, base: []const u8) u32 {
    if (!std.mem.startsWith(u8, name, base)) return 0;
    const rest = name[base.len..];
    if (rest.len == 0) return 1;
    if (rest[0] != ' ') return 0;
    return std.fmt.parseInt(u32, rest[1..], 10) catch 0;
}

/// The title of a document's window: the name on macOS; elsewhere, as
/// Notepad and gedit show it, "*name - App" while it has unsaved changes.
pub fn windowTitle(buf: []u8, name: []const u8, app: []const u8, edited: bool) []const u8 {
    if (builtin.os.tag == .macos) return name;
    const mark: []const u8 = if (edited) "*" else "";
    if (app.len == 0) return std.fmt.bufPrint(buf, "{s}{s}", .{ mark, name }) catch name;
    return std.fmt.bufPrint(buf, "{s}{s} - {s}", .{ mark, name, app }) catch name;
}

/// `name` with `ext` (without the dot) unless it has an extension already.
pub fn withExtension(gpa: std.mem.Allocator, name: []const u8, ext: []const u8) ![]u8 {
    if (ext.len == 0 or std.fs.path.extension(name).len > 0) return gpa.dupe(u8, name);
    return std.fmt.allocPrint(gpa, "{s}.{s}", .{ name, ext });
}

/// Whether `path` has one of `exts` (lower case, without dots).
pub fn hasExtension(path: []const u8, exts: []const []const u8) bool {
    const e = std.fs.path.extension(path);
    if (e.len < 2) return false;
    for (exts) |x| if (std.ascii.eqlIgnoreCase(e[1..], x)) return true;
    return false;
}

test "writing a file whole, its stamp, names" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "notes.md" });
    defer gpa.free(path);
    try std.testing.expect(stampOf(io, path) == null);
    const s1 = try writeSafely(gpa, io, path, "one");
    try std.testing.expectEqual(@as(u64, 3), s1.size);
    const s2 = try writeSafely(gpa, io, path, "three");
    try std.testing.expect(!s1.eql(s2));
    try std.testing.expect(s2.eql(stampOf(io, path).?));
    const back = try readAll(gpa, io, path, 1 << 20);
    defer gpa.free(back);
    try std.testing.expectEqualStrings("three", back);
    // No temporary file is left beside it.
    var it = tmp.dir.iterate();
    var count: usize = 0;
    while (try it.next(io)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Untitled", untitledName(&buf, "Untitled", 1));
    try std.testing.expectEqualStrings("Untitled 3", untitledName(&buf, "Untitled", 3));
    try std.testing.expectEqual(@as(u32, 3), untitledNumber("Untitled 3", "Untitled"));
    try std.testing.expectEqual(@as(u32, 1), untitledNumber("Untitled", "Untitled"));
    try std.testing.expectEqual(@as(u32, 0), untitledNumber("Notes", "Untitled"));
    try std.testing.expect(hasExtension("a/b.MD", &.{"md"}));
    try std.testing.expect(!hasExtension("a/b.txt", &.{"md"}));
    const named = try withExtension(gpa, "Notes", "md");
    defer gpa.free(named);
    try std.testing.expectEqualStrings("Notes.md", named);
    if (builtin.os.tag != .macos) try std.testing.expectEqualStrings("*Notes.md - Editor", windowTitle(&buf, "Notes.md", "Editor", true));
}

test "a file's identity: its inode and its kind, which a reused inode changes" {
    const a: Identity = .{ .inode = 2, .kind = .directory };
    const b: Identity = .{ .inode = 2, .kind = .sym_link };
    try std.testing.expect(!a.eql(b));
    try std.testing.expect(a.eql(.{ .inode = 2, .kind = .directory }));
    // The stamps of one content are equal whatever their files.
    try std.testing.expect((Stamp{ .mtime = 1, .size = 2, .file = a }).eql(.{ .mtime = 1, .size = 2 }));
}
