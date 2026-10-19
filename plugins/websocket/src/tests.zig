//! `Conn` against the example's in-process server (example/server.zig).
const std = @import("std");
const ws = @import("websocket");
const Server = @import("server").Server;
const testing = std.testing;
const io = testing.io;

const Fixture = struct {
    server: Server = undefined,
    client: std.http.Client = undefined,
    buf: [128]u8 = undefined,

    fn init(f: *Fixture) !void {
        try f.server.start(io);
        f.client = .{ .allocator = testing.allocator, .io = io };
    }
    fn deinit(f: *Fixture) void {
        f.client.deinit();
        f.server.stop();
    }
    fn connect(f: *Fixture, path: []const u8, options: ws.Options) !*ws.Conn {
        return ws.Conn.connect(&f.client, testing.allocator, f.server.url(&f.buf, path), options);
    }
};

fn expectText(c: *ws.Conn, want: []const u8) !void {
    const m = try c.read(testing.allocator);
    defer switch (m) {
        .text, .binary => |b| testing.allocator.free(b),
        .close => |cl| testing.allocator.free(cl.reason),
    };
    try testing.expectEqualStrings(want, m.text);
}

test "echo: text and binary messages, small and large, then a clean close" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const c = try f.connect("/echo", .{});
    defer c.deinit();
    try c.send(.text, "hello");
    try expectText(c, "hello");
    const big = try testing.allocator.alloc(u8, 200_000);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i);
    try c.send(.binary, big);
    const m = try c.read(testing.allocator);
    defer testing.allocator.free(m.binary);
    try testing.expectEqualSlices(u8, big, m.binary);
    try testing.expectError(error.InvalidUtf8, c.send(.text, "\xff"));

    try c.close(1000, "done");
    const cl = try c.read(testing.allocator);
    defer testing.allocator.free(cl.close.reason);
    try testing.expectEqual(@as(u16, 1000), cl.close.code);
    try testing.expectEqualStrings("done", cl.close.reason);
    try testing.expectError(error.Closed, c.send(.text, "late"));
}

test "the handshake sends headers and subprotocols; the server's choice is kept" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const c = try f.connect("/hello", .{ .protocols = &.{ "v2", "v1" }, .headers = &.{.{ .name = "X-Token", .value = "secret" }} });
    defer c.deinit();
    try testing.expectEqualStrings("v2", c.protocol);
    try expectText(c, "token: secret");
    try expectText(c, "protocol: v2");
    // The server closes: its code and reason, and the close was echoed.
    const m = try c.read(testing.allocator);
    defer testing.allocator.free(m.close.reason);
    try testing.expectEqual(@as(u16, 4000), m.close.code);
    try testing.expectEqualStrings("bye", m.close.reason);
    try testing.expect(c.close_sent);
}

test "pings are answered with their payload" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const c = try f.connect("/ping", .{});
    defer c.deinit();
    try expectText(c, "pong: hi");
}

test "fragmented messages are reassembled, with a ping between their frames" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const c = try f.connect("/fragments", .{});
    defer c.deinit();
    try expectText(c, "hello");
}

test "a server that breaks the protocol fails the connection with 1002" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const c = try f.connect("/bad", .{});
    defer c.deinit();
    try testing.expectError(error.ProtocolError, c.read(testing.allocator));
    try testing.expectEqual(@as(?u16, 1002), ws.frame.failCode(error.ProtocolError));
}

test "messages over the limit fail with MessageTooBig" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const c = try f.connect("/echo", .{ .max_message_size = 10 });
    defer c.deinit();
    try c.send(.text, "more than ten bytes");
    try testing.expectError(error.MessageTooBig, c.read(testing.allocator));
}

test "a refused upgrade fails the handshake" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try testing.expectError(error.HandshakeRefused, f.connect("/nope", .{}));
    try testing.expectError(error.ReservedHeader, f.connect("/echo", .{ .headers = &.{.{ .name = "Sec-WebSocket-Key", .value = "x" }} }));
    try testing.expectError(error.UnsupportedUrlScheme, ws.Conn.connect(&f.client, testing.allocator, "ftp://127.0.0.1/", .{}));
}

test "shutdown stops a read blocked on a silent server" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const c = try f.connect("/deaf", .{});
    defer c.deinit();
    try c.close(1000, "");
    var task = try io.concurrent(readOne, .{c});
    c.shutdown();
    try testing.expect(std.meta.isError(task.await(io)));
}

fn readOne(c: *ws.Conn) !void {
    const m = try c.read(testing.allocator);
    switch (m) {
        .text, .binary => |b| testing.allocator.free(b),
        .close => |cl| testing.allocator.free(cl.reason),
    }
}

test {
    _ = ws;
}
