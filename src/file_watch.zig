//! Watching a file for other apps' changes: its handler runs on the main
//! thread when the file may have changed (written, replaced, renamed,
//! deleted; a folder's other files can wake it too, so the handler looks
//! at the file itself). inotify on Linux, kqueue on macOS, change
//! notifications on Windows; nothing in browsers. Nothing polls.
//!
//!     const w = try myzig.file_watch.watch(path, &doc, Doc.onChange);
//!     defer w.cancel();
const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .macos => @import("file_watch_mac.zig"),
    .linux => @import("linux/file_watch.zig"),
    .windows => @import("windows/file_watch.zig"),
    else => Unsupported,
};

const Unsupported = struct {
    pub const Handler = HandlerFn;
    pub const Watch = NoWatch;
    pub fn watch(_: []const u8, _: ?*anyopaque, _: HandlerFn) !*NoWatch {
        return error.Unsupported;
    }
};
const HandlerFn = *const fn (ctx: ?*anyopaque) callconv(.c) void;
const NoWatch = struct {
    pub fn cancel(_: *NoWatch) void {}
};

pub const Handler = impl.Handler;
pub const Watch = impl.Watch;
pub const watch = impl.watch;

test "a watch sees the file written by another app" {
    if (builtin.os.tag != .windows) return error.SkipZigTest; // needs the loop: runFor
    const std = @import("std");
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "w.txt", .data = "1" });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "w.txt" });
    defer gpa.free(path);
    const S = struct {
        fn on(ctx: ?*anyopaque) callconv(.c) void {
            const n: *usize = @ptrCast(@alignCast(ctx));
            n.* += 1;
        }
    };
    var hits: usize = 0;
    const w = try watch(path, &hits, S.on);
    defer w.cancel();
    try tmp.dir.writeFile(io, .{ .sub_path = "w.txt", .data = "22" });
    // Waits for the event, not for a time: the guard only ends a hang.
    var turns: usize = 0;
    while (hits == 0 and turns < 3000) : (turns += 1) @import("platform.zig").runFor(0.01);
    try std.testing.expect(hits > 0);
}
