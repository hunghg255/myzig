//! Watchers on temporary directories: each test changes files, then takes
//! batches until it saw what it expects (no sleeping: `next` waits for the
//! system's notifications, and debouncing is off).
const std = @import("std");
const watch = @import("watch");
const testing = std.testing;
const io = testing.io;
const Dir = std.Io.Dir;

const Fixture = struct {
    tmp: testing.TmpDir,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path: []const u8 = "",
    arena: std.heap.ArenaAllocator,

    fn init(f: *Fixture) !void {
        f.tmp = testing.tmpDir(.{});
        f.arena = .init(testing.allocator);
        const n = try f.tmp.dir.realPath(io, &f.path_buf);
        f.path = f.path_buf[0..n];
    }
    fn deinit(f: *Fixture) void {
        f.arena.deinit();
        f.tmp.cleanup();
    }
    fn sub(f: *Fixture, rel: []const u8) []const u8 {
        return std.fs.path.join(f.arena.allocator(), &.{ f.path, rel }) catch unreachable;
    }
    fn write(f: *Fixture, rel: []const u8, data: []const u8) !void {
        try f.tmp.dir.writeFile(io, .{ .sub_path = rel, .data = data });
    }
};

/// Takes batches until one has an event like `want`.
fn expectEvent(w: *watch.Watcher, f: *Fixture, op: watch.Op, path: []const u8, old: ?[]const u8) !void {
    for (0..50) |_| {
        const events = try w.next(f.arena.allocator());
        for (events) |e| if (e.op == op and std.mem.eql(u8, e.path, path)) {
            if (old) |o| try testing.expectEqualStrings(o, e.old_path.?);
            return;
        };
    }
    return error.EventNeverCame;
}

test "a directory: creates, writes, renames and removes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.write("old.txt", "x");
    const w = try watch.Watcher.init(testing.allocator, io, f.path, .{ .debounce_ms = -1 });
    defer w.deinit();
    try f.write("a.txt", "hello");
    try expectEvent(w, &f, .create, "a.txt", null);
    try f.write("a.txt", "hello, longer");
    try expectEvent(w, &f, .write, "a.txt", null);
    try f.tmp.dir.rename("a.txt", f.tmp.dir, "b.txt", io);
    try expectEvent(w, &f, .rename, "b.txt", "a.txt");
    try f.tmp.dir.deleteFile(io, "old.txt");
    try expectEvent(w, &f, .remove, "old.txt", null);
}

test "recursive watches see into directories, and ignore leaves some out" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const Ignore = struct {
        fn ignore(_: ?*anyopaque, p: []const u8, is_dir: bool) bool {
            return is_dir and std.mem.eql(u8, std.fs.path.basename(p), "node_modules");
        }
    };
    try f.tmp.dir.createDirPath(io, "node_modules");
    const w = try watch.Watcher.init(testing.allocator, io, f.path, .{ .recursive = true, .debounce_ms = -1, .ignore = Ignore.ignore });
    defer w.deinit();
    try f.tmp.dir.createDirPath(io, "src");
    try expectEvent(w, &f, .create, "src", null);
    try f.write("node_modules/x.js", "ignored");
    try f.write("src/main.zig", "pub fn main() void {}");
    // The ignored write never shows; the other does.
    for (0..50) |_| {
        const events = try w.next(f.arena.allocator());
        var found = false;
        for (events) |e| {
            try testing.expect(!std.mem.startsWith(u8, e.path, "node_modules"));
            if (e.op == .create and std.mem.eql(u8, e.path, "src/main.zig")) found = true;
        }
        if (found) break;
    } else return error.EventNeverCame;
}

test "a file: written is a write of '.', removed a remove, then the end" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.write("settings.json", "{}");
    try f.write("other.txt", "");
    const w = try watch.Watcher.init(testing.allocator, io, f.sub("settings.json"), .{ .debounce_ms = -1 });
    defer w.deinit();
    try f.write("settings.json", "{\"a\":1}");
    try expectEvent(w, &f, .write, ".", null);
    try f.tmp.dir.deleteFile(io, "settings.json");
    try expectEvent(w, &f, .remove, ".", null);
}

test "the directory removed: a last remove of '.', then EndOfStream" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.tmp.dir.createDirPath(io, "doomed");
    const w = try watch.Watcher.init(testing.allocator, io, f.sub("doomed"), .{ .debounce_ms = -1 });
    defer w.deinit();
    try f.tmp.dir.deleteTree(io, "doomed");
    try expectEvent(w, &f, .remove, ".", null);
    try testing.expectError(error.EndOfStream, w.next(f.arena.allocator()));
}

test "close ends a next waiting on another task" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const w = try watch.Watcher.init(testing.allocator, io, f.path, .{});
    defer w.deinit();
    var task = try io.concurrent(watch.Watcher.next, .{ w, f.arena.allocator() });
    w.close();
    try testing.expectError(error.EndOfStream, task.await(io));
}

test "too many entries, and what is missing" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    for (0..5) |i| {
        var name: [16]u8 = undefined;
        try f.write(try std.fmt.bufPrint(&name, "f{d}", .{i}), "");
    }
    try testing.expectError(error.TooManyEntries, watch.Watcher.init(testing.allocator, io, f.path, .{ .max_entries = 3 }));
    try testing.expectError(error.NotFound, watch.Watcher.init(testing.allocator, io, f.sub("nope"), .{}));
}

test {
    _ = watch;
}
