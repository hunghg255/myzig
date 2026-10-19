//! A page that watches a folder: the example makes a sandbox directory in
//! the system's temporary one, names it "sandbox" for pages, and lets the
//! page create, write and remove files there through Zig, to see the watch
//! report them.
const std = @import("std");
const myzig = @import("myzig");
const watch = @import("watch");

/// Changes the sandbox, as another program would.
const Sandbox = struct {
    io: std.Io,
    dir: []const u8,

    pub const myzig_params = .{ .write = .{ "name", "text" }, .remove = .{"name"}, .mkdir = .{"name"} };

    pub fn write(s: *Sandbox, call: *myzig.Call, name: []const u8, text: []const u8) !void {
        const p = try std.fs.path.join(call.arena, &.{ s.dir, name });
        try std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = p, .data = text });
    }

    pub fn remove(s: *Sandbox, call: *myzig.Call, name: []const u8) !void {
        const p = try std.fs.path.join(call.arena, &.{ s.dir, name });
        try std.Io.Dir.cwd().deleteTree(s.io, p);
    }

    pub fn mkdir(s: *Sandbox, call: *myzig.Call, name: []const u8) !void {
        const p = try std.fs.path.join(call.arena, &.{ s.dir, name });
        try std.Io.Dir.cwd().createDirPath(s.io, p);
    }
};

const assets = [_]myzig.Asset{
    .{ .path = "/index.html", .data = @embedFile("index.html") },
    watch.asset,
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Watch" });
    defer app.destroy();

    // A fresh sandbox each run.
    const temp = try myzig.path(init.gpa, .temp, "Watch");
    defer init.gpa.free(temp);
    var name_buf: [64]u8 = undefined;
    var rnd: [6]u8 = undefined;
    init.io.random(&rnd);
    const dir = try std.fs.path.join(init.gpa, &.{ temp, try std.fmt.bufPrint(&name_buf, "myzig-watch-{x}", .{rnd}) });
    defer init.gpa.free(dir);
    try std.Io.Dir.cwd().createDirPath(init.io, dir);
    defer std.Io.Dir.cwd().deleteTree(init.io, dir) catch {};

    var service: watch.Service = try .init(init.gpa, init.io, .{ .roots = &.{
        .{ .name = "sandbox", .path = dir, .recursive = true },
    } });
    defer service.deinit();
    try app.bind(&service);
    try app.registerEvent(watch.BatchEvent);
    var sandbox: Sandbox = .{ .io = init.io, .dir = dir };
    try app.bind(&sandbox);

    _ = try app.newWindow(.{
        .title = "Watch",
        .width = 600,
        .height = 480,
        .content = .{ .page = .{ .url = "/", .assets = &assets } },
    });
    try app.run();
}
