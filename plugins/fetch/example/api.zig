//! A small HTTP server on 127.0.0.1, for the example's page to fetch from
//! and for the plugin's tests: no request leaves the machine.
//!
//!   GET  /hello     "hello", with headers (and a Set-Cookie pages never see)
//!   ANY  /echo      the method, the X-Custom header and the body, a line each
//!   GET  /redirect  302 to /hello;  /loop  302 to itself
//!   GET  /stream    "one", then "two" once `gate` is set (chunked)
//!   GET  /big       3 MiB of "x"
const std = @import("std");
const Io = std.Io;

pub const Server = struct {
    io: Io,
    listener: Io.net.Server,
    port: u16,
    future: Io.Future(void) = undefined,
    /// The connections being served, each on a task of its own.
    group: Io.Group = .init,
    /// Lets /stream send its second chunk.
    gate: Io.Event = .unset,
    requests: std.atomic.Value(u32) = .init(0),
    redirect_target: ?[]const u8 = null,

    /// Listens on an ephemeral port of 127.0.0.1 and serves on a task of its own.
    pub fn start(s: *Server, io: Io) !void {
        const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const listener = try addr.listen(io, .{ .reuse_address = true });
        s.* = .{ .io = io, .listener = listener, .port = listener.socket.address.getPort() };
        s.future = try io.concurrent(serve, .{s});
    }

    pub fn stop(s: *Server) void {
        s.future.cancel(s.io);
        s.group.cancel(s.io);
        s.listener.deinit(s.io);
    }

    pub fn url(s: *const Server, buf: []u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ s.port, path }) catch unreachable;
    }

    fn serve(s: *Server) void {
        while (true) {
            const stream = s.listener.accept(s.io) catch return;
            s.group.concurrent(s.io, connection, .{ s, stream }) catch stream.close(s.io);
        }
    }

    fn connection(s: *Server, stream: Io.net.Stream) void {
        defer stream.close(s.io);
        s.serveConnection(stream) catch {};
    }

    fn serveConnection(s: *Server, stream: Io.net.Stream) !void {
        var in_buf: [8192]u8 = undefined;
        var out_buf: [8192]u8 = undefined;
        var reader = stream.reader(s.io, &in_buf);
        var writer = stream.writer(s.io, &out_buf);
        var http: std.http.Server = .init(&reader.interface, &writer.interface);
        while (true) {
            var req = http.receiveHead() catch return;
            _ = s.requests.fetchAdd(1, .monotonic);
            try s.handle(&req);
        }
    }

    fn handle(s: *Server, req: *std.http.Server.Request) !void {
        const target = req.head.target;
        if (std.mem.eql(u8, target, "/hello")) {
            return req.respond("hello", .{ .extra_headers = &.{
                .{ .name = "X-Test", .value = "1" },
                .{ .name = "Set-Cookie", .value = "secret=1" },
                .{ .name = "Content-Type", .value = "text/plain" },
            } });
        }
        if (std.mem.eql(u8, target, "/echo")) {
            var custom: []const u8 = "";
            var it = req.iterateHeaders();
            var custom_buf: [256]u8 = undefined;
            while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "x-custom")) {
                custom = custom_buf[0..@min(h.value.len, custom_buf.len)];
                @memcpy(@constCast(custom), h.value[0..custom.len]);
            };
            const method = @tagName(req.head.method);
            var body_buf: [4096]u8 = undefined;
            var body: []const u8 = "";
            if (req.head.method.requestHasBody()) {
                const r = try req.readerExpectContinue(&.{});
                const n = try r.readSliceShort(&body_buf);
                body = body_buf[0..n];
            }
            var out: [8192]u8 = undefined;
            const text = try std.fmt.bufPrint(&out, "{s}\n{s}\n{s}", .{ method, custom, body });
            return req.respond(text, .{});
        }
        if (std.mem.eql(u8, target, "/redirect")) {
            return req.respond("", .{ .status = .found, .extra_headers = &.{.{ .name = "Location", .value = "/hello" }} });
        }
        if (std.mem.eql(u8, target, "/loop")) {
            return req.respond("", .{ .status = .found, .extra_headers = &.{.{ .name = "Location", .value = "/loop" }} });
        }
        if (std.mem.eql(u8, target, "/blocked-redirect")) {
            return req.respond("", .{ .status = .found, .extra_headers = &.{.{ .name = "Location", .value = "/forbidden" }} });
        }
        if (std.mem.eql(u8, target, "/external-redirect")) {
            return req.respond("", .{ .status = .found, .extra_headers = &.{.{ .name = "Location", .value = s.redirect_target orelse "/hello" }} });
        }
        if (std.mem.eql(u8, target, "/stream")) {
            var buf: [256]u8 = undefined;
            var body = try req.respondStreaming(&buf, .{});
            try body.writer.writeAll("one");
            try body.writer.flush();
            try body.flush();
            try s.gate.wait(s.io);
            try body.writer.writeAll("two");
            return body.end();
        }
        if (std.mem.eql(u8, target, "/big")) {
            var buf: [4096]u8 = undefined;
            var body = try req.respondStreaming(&buf, .{ .content_length = 3 << 20 });
            const block: [4096]u8 = @splat('x');
            for (0..(3 << 20) / block.len) |_| try body.writer.writeAll(&block);
            return body.end();
        }
        return req.respond("not found", .{ .status = .not_found });
    }
};
