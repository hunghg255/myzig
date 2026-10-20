//! A page that fetches from Zig: the example runs a small API on
//! 127.0.0.1 (api.zig) and the page calls it with the plugin's `fetch`,
//! streaming a response as it arrives.
const std = @import("std");
const myzig = @import("myzig");
const fetch = @import("fetch");
const Api = @import("api").Server;

/// What the page needs to know about the example's server.
const Demo = struct {
    api: *Api,
    service: *fetch.Service,

    /// The requests the service keeps, for the page's check.
    pub fn requests(d: *Demo) usize {
        return d.service.tasks.items.len;
    }

    /// The API's base URL.
    pub fn base(d: *Demo, call: *myzig.Call) ![]const u8 {
        return std.fmt.allocPrint(call.arena, "http://127.0.0.1:{d}", .{d.api.port});
    }

    /// Lets /stream send its second chunk.
    pub fn openGate(d: *Demo) void {
        d.api.gate.set(d.api.io);
    }
};

const assets = [_]myzig.Asset{
    .{ .path = "/index.html", .data = @embedFile("index.html") },
    fetch.asset,
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Fetch" });
    defer app.destroy();

    var api: Api = undefined;
    try api.start(init.io);
    defer api.stop();

    var service: fetch.Service = try .init(init.gpa, init.io, .{});
    defer service.deinit();
    try app.bind(&service);
    try app.registerEvent(fetch.PartEvent);
    var demo: Demo = .{ .api = &api, .service = &service };
    try app.bind(&demo);

    _ = try app.newWindow(.{
        .title = "Fetch",
        .width = 600,
        .height = 480,
        .content = .{ .page = .{ .url = "/", .assets = &assets } },
    });
    try app.run();
}
