//! `perform` against the example's local server (example/api.zig), started
//! in the test: no request leaves the machine.
const std = @import("std");
const fetch = @import("fetch");
const Api = @import("api").Server;
const testing = std.testing;
const io = testing.io;

/// What a sink saw.
const Seen = struct {
    head: ?fetch.Head = null,
    body: std.ArrayList(u8) = .empty,
    chunks: usize = 0,
    arena: std.mem.Allocator,
    /// Set with the first chunk; the test sets `gate` once it saw it.
    first: Io.Event = .unset,
    const Io = std.Io;

    fn sink(s: *Seen) fetch.Sink {
        return .{ .ctx = s, .head = onHead, .chunk = onChunk };
    }
    fn onHead(ctx: *anyopaque, head: fetch.Head) !void {
        const s: *Seen = @ptrCast(@alignCast(ctx));
        s.head = head;
    }
    fn onChunk(ctx: *anyopaque, bytes: []const u8) !void {
        const s: *Seen = @ptrCast(@alignCast(ctx));
        try s.body.appendSlice(s.arena, bytes);
        s.chunks += 1;
        s.first.set(io);
    }
    fn header(s: *const Seen, name: []const u8) ?[]const u8 {
        for (s.head.?.headers) |h| if (std.mem.eql(u8, h.name, name)) return h.value;
        return null;
    }
};

const Fixture = struct {
    api: Api = undefined,
    client: std.http.Client = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    buf: [128]u8 = undefined,

    fn init(f: *Fixture) !void {
        try f.api.start(io);
        f.client = .{ .allocator = testing.allocator, .io = io };
        f.arena = .init(testing.allocator);
    }
    fn deinit(f: *Fixture) void {
        f.client.deinit();
        f.api.stop();
        f.arena.deinit();
    }
    fn url(f: *Fixture, path: []const u8) []const u8 {
        return f.api.url(&f.buf, path);
    }
    fn get(f: *Fixture, req: fetch.Request) !Seen {
        var seen: Seen = .{ .arena = f.arena.allocator() };
        try fetch.perform(&f.client, f.arena.allocator(), req, seen.sink());
        return seen;
    }
};

test "a GET: status, lower-case headers without Set-Cookie, the body" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const seen = try f.get(.{ .url = f.url("/hello") });
    try testing.expectEqual(@as(u16, 200), seen.head.?.status);
    try testing.expectEqualStrings("OK", seen.head.?.status_text);
    try testing.expectEqualStrings("1", seen.header("x-test").?);
    try testing.expectEqualStrings("text/plain", seen.header("content-type").?);
    try testing.expectEqual(null, seen.header("set-cookie"));
    try testing.expect(!seen.head.?.redirected);
    try testing.expectEqualStrings("hello", seen.body.items);
}

test "a POST sends its method, headers and body" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const seen = try f.get(.{
        .url = f.url("/echo"),
        .method = "post",
        .headers = &.{ .{ .name = "X-Custom", .value = "abc" }, .{ .name = "Content-Type", .value = "text/plain" } },
        .body = "the body",
    });
    try testing.expectEqualStrings("POST\nabc\nthe body", seen.body.items);
    try testing.expectError(error.BodyNotAllowed, f.get(.{ .url = f.url("/echo"), .body = "x" }));
    try testing.expectError(error.InvalidHeader, f.get(.{ .url = f.url("/echo"), .headers = &.{.{ .name = "X", .value = "a\r\nInjected: 1" }} }));
    try testing.expectError(error.UnsupportedMethod, f.get(.{ .url = f.url("/echo"), .method = "BREW" }));
    try testing.expectError(error.UnsupportedUrlScheme, f.get(.{ .url = "ftp://127.0.0.1/" }));
}

test "redirects: followed, returned as they are, or refused" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const followed = try f.get(.{ .url = f.url("/redirect") });
    try testing.expectEqual(@as(u16, 200), followed.head.?.status);
    try testing.expect(followed.head.?.redirected);
    try testing.expect(std.mem.endsWith(u8, followed.head.?.url, "/hello"));
    try testing.expectEqualStrings("hello", followed.body.items);

    const manual = try f.get(.{ .url = f.url("/redirect"), .redirect = .manual });
    try testing.expectEqual(@as(u16, 302), manual.head.?.status);
    try testing.expectEqualStrings("/hello", manual.header("location").?);

    try testing.expectError(error.Redirected, f.get(.{ .url = f.url("/redirect"), .redirect = .@"error" }));
    try testing.expectError(error.TooManyRedirects, f.get(.{ .url = f.url("/loop"), .max_redirects = 5 }));
}

test "the body streams: the first chunk arrives before the server sends the second" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var seen: Seen = .{ .arena = f.arena.allocator() };
    var task = try io.concurrent(fetch.perform, .{ &f.client, f.arena.allocator(), fetch.Request{ .url = f.url("/stream") }, seen.sink() });
    // The server holds "two" until the first chunk reached the sink.
    try seen.first.wait(io);
    try testing.expectEqualStrings("one", seen.body.items);
    f.api.gate.set(io);
    try task.await(io);
    try testing.expectEqualStrings("onetwo", seen.body.items);
    try testing.expect(seen.chunks >= 2);
}

test "canceling a request stops it while it waits for the server" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var seen: Seen = .{ .arena = f.arena.allocator() };
    var task = try io.concurrent(fetch.perform, .{ &f.client, f.arena.allocator(), fetch.Request{ .url = f.url("/stream") }, seen.sink() });
    try seen.first.wait(io);
    // The server never sends "two" (the gate stays shut): cancel.
    try testing.expectError(error.Canceled, task.cancel(io));
    try testing.expectEqualStrings("one", seen.body.items);
    f.api.gate.set(io);
}

test "a large body comes in chunks of at most chunk_size" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const seen = try f.get(.{ .url = f.url("/big") });
    try testing.expectEqual(@as(usize, 3 << 20), seen.body.items.len);
    try testing.expect(seen.chunks >= (3 << 20) / fetch.chunk_size);
}

test "an unreachable server fails the request" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    // A port nothing listens on: the one of a server just stopped.
    var other: Api = undefined;
    try other.start(io);
    var buf: [128]u8 = undefined;
    const dead = try std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}/", .{other.port});
    other.stop();
    try testing.expect(std.meta.isError(f.get(.{ .url = dead })));
}

test "a HEAD has a head and no body" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const seen = try f.get(.{ .url = f.url("/hello"), .method = "HEAD" });
    try testing.expectEqual(@as(u16, 200), seen.head.?.status);
    try testing.expectEqual(@as(usize, 0), seen.body.items.len);
}

test {
    _ = fetch;
}
