//! Headless runs (`--myzig-snapshot`, `--myzig-eval`, `--myzig-generate`,
//! tests) leave the user's state alone: the app's own directories
//! (`desktop.path`'s data, cache and downloads, `myzig.appPath`'s) are
//! made in a temporary directory of the run's instead, removed when the
//! app is destroyed. Documents' recovery copies, window state, recent
//! documents and an app's own store all live there.
const std = @import("std");
const builtin = @import("builtin");

var buf: [1024]u8 = undefined;
var root: ?[]const u8 = null;
var requested = false;

/// Whether this run is headless: an app asked (`request`), it began one
/// (`begin`), or it is a test.
pub fn active() bool {
    return requested or root != null or builtin.is_test;
}

/// Makes this run headless: an app started with `--myzig-snapshot`,
/// `--myzig-eval` or `--myzig-generate`. Its directory is made when first
/// asked for.
pub fn request() void {
    requested = true;
}

/// Starts a headless run: the app's directories go under a new directory
/// in `temp` (the system's temporary directory) until `end`.
pub fn begin(io: std.Io, temp: []const u8) void {
    if (root != null) return;
    var name: [12]u8 = undefined;
    @import("document_recovery.zig").randomName(io, &name);
    root = std.fmt.bufPrint(&buf, "{s}{c}myzig-headless-{s}", .{ temp, std.fs.path.sep, name }) catch return;
}

/// Ends a headless run, removing what it wrote.
pub fn end(io: std.Io) void {
    requested = false;
    const r = root orelse return;
    std.Io.Dir.cwd().deleteTree(io, r) catch {};
    root = null;
}

/// Where directory `kind` (`data`, `cache`, `config`, `logs`,
/// `downloads`) of the app named `app_name` is in a headless run, created;
/// null when the run is not headless. `temp` is the system's temporary
/// directory, for a test that began no run. Caller frees it.
pub fn path(gpa: std.mem.Allocator, kind: []const u8, app_name: []const u8, temp: []const u8) !?[]u8 {
    if (!active()) return null;
    const io = std.Io.Threaded.global_single_threaded.io();
    if (root == null) begin(io, temp);
    const r = root orelse return null;
    const full = try std.fs.path.join(gpa, &.{ r, app_name, kind });
    errdefer gpa.free(full);
    try std.Io.Dir.cwd().createDirPath(io, full);
    return full;
}

test "a headless run's directories are its own, in the temporary directory, removed at its end" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const temp = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(temp);
    end(io);
    begin(io, temp);
    defer end(io);
    const data = (try path(gpa, "data", "Notes", temp)).?;
    defer gpa.free(data);
    try std.testing.expect(std.mem.startsWith(u8, data, temp));
    try std.testing.expect(std.mem.endsWith(u8, data, "data"));
    try std.Io.Dir.cwd().access(io, data, .{});
    const base = root.?;
    var copy: [1024]u8 = undefined;
    @memcpy(copy[0..base.len], base);
    end(io);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, copy[0..base.len], .{}));
}
