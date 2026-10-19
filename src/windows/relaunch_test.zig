//! `App.relaunch` on Windows, in an app whose windows never show: it
//! passes the foreground on before quitting, and once `destroy` freed the
//! app, a process starts with the launch's arguments in its directory. A
//! shell (cmd.exe) stands in for the app's executable, writing what it got
//! to a file, so no app (nor this test binary) starts again.
const std = @import("std");
const App = @import("app.zig").App;
const app_extras = @import("app_extras.zig");
const app_common = @import("../app_common.zig");
const relaunch = @import("../relaunch.zig");

const t = std.testing;

/// What the stand-in restart saw: the foreground passed on by then, and
/// the process it started.
var started: ?struct { allowed: usize, child: std.process.Child } = null;
var arena_state: std.heap.ArenaAllocator = undefined;

fn standIn(_: std.mem.Allocator, io: std.Io, l: app_common.Launch) void {
    const child = relaunch.spawn(io, arena_state.allocator(), "cmd.exe", l.args, l.cwd) catch return;
    started = .{ .allowed = app_extras.foreground_allowed, .child = child };
}

test "a relaunch passes the foreground on, then starts the app with its arguments" {
    const io = t.io;
    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    arena_state = .init(t.allocator);
    defer arena_state.deinit();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena_state.allocator());

    const app = try App.createHidden(t.allocator, io, &env, .{ .name = "myzig-relaunch-tests", .quit_on_signal = false });
    // As a shown app's launch: cmd.exe's arguments stand in for the app's.
    app.flags.hidden = false;
    app.launch = .{ .args = &.{ "/d", "/c", "echo", "notes://1", "a b.md", ">", "args.txt" }, .cwd = dir };
    const before = app_extras.foreground_allowed;
    app.relaunch();
    try t.expect(app.stopping);
    try t.expectEqual(before + 1, app_extras.foreground_allowed);
    try t.expect(app.restart.? == relaunch.start);
    // A second relaunch while quitting does nothing.
    app.relaunch();
    try t.expectEqual(before + 1, app_extras.foreground_allowed);

    app.restart = standIn;
    started = null;
    app.destroy();
    const s = started orelse return error.NotStarted;
    try t.expectEqual(before + 1, s.allowed);
    var child = s.child;
    _ = try child.wait(io);
    const out = try tmp.dir.readFileAlloc(io, "args.txt", arena_state.allocator(), .limited(256));
    try t.expect(std.mem.startsWith(u8, out, "notes://1 \"a b.md\""));
}

test "a hidden app's relaunch only quits" {
    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    const app = try App.createHidden(t.allocator, t.io, &env, .{ .name = "myzig-relaunch-tests", .quit_on_signal = false });
    defer app.destroy();
    app.relaunch();
    try t.expect(app.stopping);
    try t.expect(app.restart == null);
}
