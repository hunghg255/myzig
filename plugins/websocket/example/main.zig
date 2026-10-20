//! A page with a WebSocket that Zig connects: the example runs a small
//! WebSocket server on 127.0.0.1 (server.zig), and the page talks to its
//! echo, sending a token in a header of the handshake.
const std = @import("std");
const myzig = @import("myzig");
const websocket = @import("websocket");
const Server = @import("server").Server;

/// Where the example's server listens, for the page.
const Demo = struct {
    server: *Server,
    service: *websocket.Service,

    /// The connections the service keeps, for the page's check.
    pub fn connections(d: *Demo) usize {
        return d.service.tasks.items.len;
    }

    pub fn base(d: *Demo, call: *myzig.Call) ![]const u8 {
        return std.fmt.allocPrint(call.arena, "ws://127.0.0.1:{d}", .{d.server.port});
    }
};

const assets = [_]myzig.Asset{
    .{ .path = "/index.html", .data = @embedFile("index.html") },
    websocket.asset,
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "WebSocket" });
    defer app.destroy();

    var server: Server = undefined;
    try server.start(init.io);
    defer server.stop();

    var service: websocket.Service = try .init(init.gpa, init.io, .{});
    defer service.deinit();
    try app.bind(&service);
    try app.registerEvent(websocket.PartEvent);
    var demo: Demo = .{ .server = &server, .service = &service };
    try app.bind(&demo);

    _ = try app.newWindow(.{
        .title = "WebSocket",
        .width = 600,
        .height = 480,
        .content = .{ .page = .{ .url = "/", .assets = &assets } },
    });
    try app.run();
}
