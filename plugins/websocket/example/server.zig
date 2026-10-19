//! A WebSocket server on 127.0.0.1 for the example's page and the plugin's
//! tests: std.http.Server makes the handshake, the plugin's own frame
//! codec (as a server) the rest.
//!
//!   /echo       echoes messages, answers pings, echoes the close
//!   /ping       pings "hi", then sends "pong: <what came back>"
//!   /hello      sends "token: <the X-Token header>", "protocol: <chosen>", then closes 4000 "bye"
//!   /fragments  sends "hel" + "lo" in two frames with a ping between them
//!   /bad        sends a masked frame, which a server must not
//!   /deaf       reads, never answers a close
//!   other       refuses the upgrade (404)
const std = @import("std");
const ws = @import("websocket");
const frame = ws.frame;
const Io = std.Io;

pub const Server = struct {
    io: Io,
    listener: Io.net.Server,
    port: u16,
    future: Io.Future(void) = undefined,
    group: Io.Group = .init,

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
        return std.fmt.bufPrint(buf, "ws://127.0.0.1:{d}{s}", .{ s.port, path }) catch unreachable;
    }

    fn serve(s: *Server) void {
        while (true) {
            const stream = s.listener.accept(s.io) catch return;
            s.group.concurrent(s.io, connection, .{ s, stream }) catch stream.close(s.io);
        }
    }

    fn connection(s: *Server, stream: Io.net.Stream) void {
        defer stream.close(s.io);
        s.handle(stream) catch {};
    }

    fn handle(s: *Server, stream: Io.net.Stream) !void {
        var in_buf: [16384]u8 = undefined;
        var out_buf: [16384]u8 = undefined;
        var reader = stream.reader(s.io, &in_buf);
        var writer = stream.writer(s.io, &out_buf);
        var http: std.http.Server = .init(&reader.interface, &writer.interface);
        var req = try http.receiveHead();
        const path = req.head.target;
        var token: [128]u8 = undefined;
        var token_len: usize = 0;
        var protocol: ?[]const u8 = null;
        var proto_buf: [64]u8 = undefined;
        var it = req.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "x-token")) {
                token_len = @min(h.value.len, token.len);
                @memcpy(token[0..token_len], h.value[0..token_len]);
            } else if (std.ascii.eqlIgnoreCase(h.name, "sec-websocket-protocol")) {
                // The first offered.
                const first = std.mem.trim(u8, std.mem.sliceTo(h.value, ','), " ");
                const n = @min(first.len, proto_buf.len);
                @memcpy(proto_buf[0..n], first[0..n]);
                protocol = proto_buf[0..n];
            }
        }
        const key = switch (req.upgradeRequested()) {
            .websocket => |k| k orelse return error.NoKey,
            else => return req.respond("not a websocket", .{ .status = .bad_request }),
        };
        const known = for ([_][]const u8{ "/echo", "/ping", "/hello", "/fragments", "/bad", "/deaf" }) |p| {
            if (std.mem.eql(u8, path, p)) break true;
        } else false;
        if (!known) return req.respond("no such socket", .{ .status = .not_found });
        var path_buf: [32]u8 = undefined;
        const route = path_buf[0..path.len];
        @memcpy(route, path);
        var key_buf: [64]u8 = undefined;
        @memcpy(key_buf[0..key.len], key);
        var extra: [1]std.http.Header = undefined;
        if (protocol) |p| extra[0] = .{ .name = "Sec-WebSocket-Protocol", .value = p };
        _ = try req.respondWebSocket(.{ .key = key_buf[0..key.len], .extra_headers = if (protocol != null) extra[0..1] else &.{} });
        try writer.interface.flush();

        var peer: Peer = .{ .r = &reader.interface, .w = &writer.interface };
        if (std.mem.eql(u8, route, "/echo")) return peer.echo();
        if (std.mem.eql(u8, route, "/ping")) {
            try peer.send(.ping, "hi");
            const pong = try peer.next();
            var out: [64]u8 = undefined;
            try peer.send(.text, try std.fmt.bufPrint(&out, "pong: {s}", .{pong.data}));
            return peer.echo();
        }
        if (std.mem.eql(u8, route, "/hello")) {
            var out: [256]u8 = undefined;
            try peer.send(.text, try std.fmt.bufPrint(&out, "token: {s}", .{token[0..token_len]}));
            try peer.send(.text, try std.fmt.bufPrint(&out, "protocol: {s}", .{protocol orelse ""}));
            var buf: [125]u8 = undefined;
            try peer.send(.close, frame.closePayload(&buf, 4000, "bye"));
            _ = peer.next() catch {}; // the echo
            return;
        }
        if (std.mem.eql(u8, route, "/fragments")) {
            try frame.write(peer.w, .text, false, "hel", null);
            try frame.write(peer.w, .ping, true, "", null);
            try frame.write(peer.w, .continuation, true, "lo", null);
            try peer.w.flush();
            return peer.echo();
        }
        if (std.mem.eql(u8, route, "/bad")) {
            try frame.write(peer.w, .text, true, "masked", .{ 1, 2, 3, 4 });
            try peer.w.flush();
            return peer.echo();
        }
        // /deaf: reads until the client goes.
        while (true) _ = try peer.next();
    }
};

const Peer = struct {
    r: *Io.Reader,
    w: *Io.Writer,
    buf: [1 << 20]u8 = undefined,

    const Msg = struct { op: frame.Opcode, data: []u8 };

    fn next(p: *Peer) !Msg {
        const h = try frame.readHeader(p.r, .server);
        if (h.len > p.buf.len) return error.MessageTooBig;
        const data = p.buf[0..@intCast(h.len)];
        try frame.readPayload(p.r, h, data);
        return .{ .op = h.opcode, .data = data };
    }

    fn send(p: *Peer, op: frame.Opcode, data: []const u8) !void {
        try frame.write(p.w, op, true, data, null);
        try p.w.flush();
    }

    fn echo(p: *Peer) !void {
        while (true) {
            const m = try p.next();
            switch (m.op) {
                .text, .binary => try p.send(m.op, m.data),
                .ping => try p.send(.pong, m.data),
                .close => return p.send(.close, m.data),
                else => {},
            }
        }
    }
};
