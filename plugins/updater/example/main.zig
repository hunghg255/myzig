//! An update banner in a page: version 1.0.0 of an app checks a release
//! server (one the example runs on 127.0.0.1, releases.zig, publishing
//! 2.0.0), shows the release notes, downloads with a progress bar and
//! installs. So that it never replaces itself, the example updates a copy
//! in the temporary directory (`exe_path`); a real app leaves it null.
const std = @import("std");
const myzig = @import("myzig");
const updater = @import("updater");
const Releases = @import("releases").Server;

/// What the example's page shows about its pretend executable.
const Demo = struct {
    io: std.Io,
    exe: []const u8,

    /// The executable's content now: the new one once installed.
    pub fn installed(d: *Demo, call: *myzig.Call) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(d.io, d.exe, call.arena, .limited(1 << 20));
    }
};

const assets = [_]myzig.Asset{.{ .path = "/index.html", .data = @embedFile("index.html") }};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Updater" });
    defer app.destroy();
    const gpa = init.gpa;

    var releases: Releases = undefined;
    try releases.start(init.io, "2.0.0", "version 2.0.0 of the example app");
    defer releases.stop();

    // A pretend executable, and a fresh place for preferences.
    const temp = try myzig.path(gpa, .temp, "Updater");
    defer gpa.free(temp);
    var rnd: [6]u8 = undefined;
    init.io.random(&rnd);
    var name_buf: [64]u8 = undefined;
    const dir = try std.fs.path.join(gpa, &.{ temp, try std.fmt.bufPrint(&name_buf, "myzig-updater-{x}", .{rnd}) });
    defer gpa.free(dir);
    try std.Io.Dir.cwd().createDirPath(init.io, dir);
    defer std.Io.Dir.cwd().deleteTree(init.io, dir) catch {};
    const exe = try std.fs.path.join(gpa, &.{ dir, "app.exe" });
    defer gpa.free(exe);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = exe, .data = "version 1.0.0 of the example app" });

    var url_buf: [128]u8 = undefined;
    var service: updater.Service = try .init(gpa, app, .{
        .manifest_url = releases.url(&url_buf, "/latest.json"),
        .current = "1.0.0",
        .exe_path = exe,
        .prefs_dir = dir,
    });
    defer service.deinit();
    try app.bind(&service);
    try app.registerEvent(updater.StateEvent);
    var demo: Demo = .{ .io = init.io, .exe = exe };
    try app.bind(&demo);

    _ = try app.newWindow(.{
        .title = "Updater",
        .width = 560,
        .height = 420,
        .content = .{ .page = .{ .url = "/", .assets = &assets } },
    });
    try app.run();
}
