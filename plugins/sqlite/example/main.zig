//! Notes kept in SQLite: a page that opens a database through the plugin's
//! client (/plugins/sqlite.js) and the bound `Sqlite` service.
const std = @import("std");
const myzig = @import("myzig");
const sqlite = @import("sqlite");

const assets = [_]myzig.Asset{
    .{ .path = "/index.html", .data = @embedFile("index.html") },
    sqlite.asset,
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "SQLite Notes" });
    defer app.destroy();

    var service: sqlite.Service = .init(init.gpa, .{});
    defer service.deinit();
    try app.bind(&service);

    _ = try app.newWindow(.{
        .title = "SQLite Notes",
        .width = 560,
        .height = 520,
        .content = .{ .page = .{ .url = "/", .assets = &assets } },
    });
    try app.run();
}
