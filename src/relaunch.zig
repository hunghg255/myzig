//! `App.relaunch`: once the app quit and `destroy` freed it (its windows
//! closed, its single instance lock released), its executable starts
//! again with the launch's arguments in the launch's working directory.
//! Under `myzig dev` the build exits with `dev_exit_code` instead, and
//! `myzig dev` starts it again. Only `App.relaunch` reaches this file, so
//! apps that never relaunch don't link it.
const std = @import("std");
const builtin = @import("builtin");
const app_common = @import("app_common.zig");

/// The exit code with which a development build asks `myzig dev` to
/// start it again.
pub const dev_exit_code: u8 = 75;

/// What `destroy` calls once the app is freed, set by `App.relaunch`.
pub const Restart = *const fn (gpa: std.mem.Allocator, io: std.Io, l: app_common.Launch) void;

/// Starts the app again with `l`'s arguments (errors are dropped: the app
/// has quit either way), or exits for `myzig dev` to start it.
pub fn start(gpa: std.mem.Allocator, io: std.Io, l: app_common.Launch) void {
    if (l.dev) std.process.exit(dev_exit_code);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const exe = exePath(io, arena.allocator()) catch return;
    _ = spawn(io, arena.allocator(), exe, l.args, l.cwd) catch return;
}

/// Starts `exe` with `args` in `cwd` (the current directory when empty),
/// its output where the app's goes (GUI executables on Windows have
/// none), and returns it: nobody waits for it, it outlives the app.
pub fn spawn(io: std.Io, arena: std.mem.Allocator, exe: []const u8, args: []const []const u8, cwd: []const u8) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = try command(arena, exe, args),
        .cwd = if (cwd.len > 0) .{ .path = cwd } else .inherit,
        .stdin = .ignore,
    });
}

/// The command line that starts the app again: `exe`, then `args` (the
/// launch's, without myzig's own flags: a relaunch is not a login launch).
pub fn command(arena: std.mem.Allocator, exe: []const u8, args: []const []const u8) ![]const []const u8 {
    const argv = try arena.alloc([]const u8, args.len + 1);
    argv[0] = exe;
    @memcpy(argv[1..], args);
    return argv;
}

/// The path of the running executable: an update that replaced the file
/// starts the new one. Linux names a replaced executable "path (deleted)".
pub fn exePath(io: std.Io, arena: std.mem.Allocator) ![]const u8 {
    const p = try std.process.executablePathAlloc(io, arena);
    return if (builtin.os.tag == .linux) withoutDeleted(p) else p;
}

pub fn withoutDeleted(p: []const u8) []const u8 {
    const suffix = " (deleted)";
    return if (std.mem.endsWith(u8, p, suffix)) p[0 .. p.len - suffix.len] else p;
}

test "the command line starts the executable with the launch's arguments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const argv = try command(arena.allocator(), "/Applications/Notes.app/Contents/MacOS/Notes", &.{ "notes://1", "a b.md" });
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("/Applications/Notes.app/Contents/MacOS/Notes", argv[0]);
    try std.testing.expectEqualStrings("notes://1", argv[1]);
    try std.testing.expectEqualStrings("a b.md", argv[2]);
    try std.testing.expectEqual(@as(usize, 1), (try command(arena.allocator(), "notes", &.{})).len);
    try std.testing.expectEqualStrings("/opt/notes/notes", withoutDeleted("/opt/notes/notes (deleted)"));
    try std.testing.expectEqualStrings("/opt/notes/notes", withoutDeleted("/opt/notes/notes"));
}

test "the launch's arguments and directory reach the started process" {
    // A shell stands in for the app (cmd.exe on Windows): it writes the
    // arguments it got to a file in the working directory it started in.
    if (builtin.os.tag != .windows and builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    var child = if (builtin.os.tag == .windows)
        try spawn(io, a, "cmd.exe", &.{ "/d", "/c", "echo", "one", "two words", ">", "out.txt" }, dir)
    else try spawn(io, a, "/bin/sh", &.{ "-c", "printf '%s|' \"$@\" > out.txt", "sh", "one", "two words" }, dir);
    _ = try child.wait(io);
    const out = try tmp.dir.readFileAlloc(io, "out.txt", a, .limited(256));
    const want = if (builtin.os.tag == .windows) "one \"two words\"" else "one|two words|";
    try std.testing.expect(std.mem.startsWith(u8, out, want));
}
