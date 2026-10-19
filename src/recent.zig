//! The app's recent documents, newest first, ten at most: kept in
//! `recent-documents.txt` in the app's data directory (one path a line),
//! besides the system's own list (`system.addRecentDocument`).
const std = @import("std");

pub const max = 10;

/// `lines` (one path a line) with `path` first, without its older place,
/// cut to `max`. Caller frees it.
pub fn push(gpa: std.mem.Allocator, lines: []const u8, path: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try aw.writer.print("{s}\n", .{path});
    var n: usize = 1;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or std.mem.eql(u8, line, path)) continue;
        if (n == max) break;
        try aw.writer.print("{s}\n", .{line});
        n += 1;
    }
    return aw.toOwnedSlice();
}

fn file(gpa: std.mem.Allocator, dir: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ dir, "recent-documents.txt" });
}

/// Records `path` in the list in `dir` (the app's data directory).
pub fn add(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, path: []const u8) !void {
    const f = try file(gpa, dir);
    defer gpa.free(f);
    const old = std.Io.Dir.cwd().readFileAlloc(io, f, gpa, .limited(1 << 20)) catch try gpa.dupe(u8, "");
    defer gpa.free(old);
    const new = try push(gpa, old, path);
    defer gpa.free(new);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = f, .data = new });
}

/// The recent documents that still exist, newest first. Free with `freeList`.
pub fn list(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) ![][]u8 {
    const f = try file(gpa, dir);
    defer gpa.free(f);
    const text = std.Io.Dir.cwd().readFileAlloc(io, f, gpa, .limited(1 << 20)) catch return gpa.alloc([]u8, 0);
    defer gpa.free(text);
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeList(gpa, out.items);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        _ = std.Io.Dir.cwd().statFile(io, line, .{}) catch continue;
        try out.append(gpa, try gpa.dupe(u8, line));
    }
    return out.toOwnedSlice(gpa);
}

pub fn clear(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) void {
    const f = file(gpa, dir) catch return;
    defer gpa.free(f);
    std.Io.Dir.cwd().deleteFile(io, f) catch {};
}

pub fn freeList(gpa: std.mem.Allocator, l: []const []u8) void {
    for (l) |s| gpa.free(s);
    gpa.free(l);
}

test "recent documents: newest first, no repeats, ten at most, existing only" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    var names: [12][]u8 = undefined;
    for (&names, 0..) |*n, i| {
        var b: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&b, "doc{d}.md", .{i});
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "x" });
        n.* = try std.fs.path.join(gpa, &.{ dir, name });
    }
    defer for (names) |n| gpa.free(n);
    for (names) |n| try add(gpa, io, dir, n);
    try add(gpa, io, dir, names[5]);
    try tmp.dir.deleteFile(io, "doc11.md");
    const l = try list(gpa, io, dir);
    defer freeList(gpa, l);
    try std.testing.expectEqual(@as(usize, 9), l.len);
    try std.testing.expectEqualStrings(names[5], l[0]);
    try std.testing.expectEqualStrings(names[10], l[1]);
    clear(gpa, io, dir);
    const empty = try list(gpa, io, dir);
    defer freeList(gpa, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}
