//! A WebSocket client connection: the opening handshake through
//! std.http.Client (so wss: is TLS with the system's certificates), then
//! messages over the connection it upgraded. Reading and writing may run
//! on two threads at once; writes are serialized, pings answered.
//!
//!     const c = try Conn.connect(&client, gpa, "wss://example.com/live", .{ .protocols = &.{"v1"} });
//!     defer c.deinit();
//!     try c.send(.text, "hello");
//!     switch (try c.read(gpa)) { .text => |t| ..., .binary => |b| ..., .close => |cl| ... }
const std = @import("std");
const frame = @import("frame.zig");
const Io = std.Io;
const http = std.http;

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Options = struct {
    /// Subprotocols to offer; the server picks one (`Conn.protocol`).
    protocols: []const []const u8 = &.{},
    /// Headers of the opening handshake (Authorization, Cookie, Origin…).
    headers: []const Header = &.{},
    /// The most bytes a message from the server may have.
    max_message_size: usize = 64 << 20,
};

pub const Message = union(enum) {
    text: []u8,
    binary: []u8,
    /// The server closed: its code (1005 for none) and reason.
    close: frame.Close,
};

pub const Kind = enum { text, binary };

const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Conn = struct {
    gpa: std.mem.Allocator,
    io: Io,
    req: http.Client.Request,
    /// The subprotocol the server chose, or "".
    protocol: []const u8 = "",
    max_message_size: usize,
    write_lock: Io.Mutex = .init,
    rng: std.Random.DefaultPrng,
    /// Set once a close frame went out; then nothing else may.
    close_sent: bool = false,
    url_buf: []u8 = &.{},

    /// Connects to a ws:, wss:, http: or https: URL and upgrades.
    pub fn connect(client: *http.Client, gpa: std.mem.Allocator, url: []const u8, options: Options) !*Conn {
        const c = try gpa.create(Conn);
        errdefer gpa.destroy(c);
        var seed: [8]u8 = undefined;
        try client.io.randomSecure(&seed);
        c.* = .{ .gpa = gpa, .io = client.io, .req = undefined, .max_message_size = options.max_message_size, .rng = .init(std.mem.readInt(u64, &seed, .little)) };
        c.url_buf = try gpa.dupe(u8, url);
        errdefer gpa.free(c.url_buf);
        var uri = try std.Uri.parse(c.url_buf);
        if (std.ascii.eqlIgnoreCase(uri.scheme, "ws")) uri.scheme = "http" //
        else if (std.ascii.eqlIgnoreCase(uri.scheme, "wss")) uri.scheme = "https" //
        else if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.UnsupportedUrlScheme;
        if (uri.fragment != null) return error.UrlHasFragment;

        var key_bytes: [16]u8 = undefined;
        try client.io.randomSecure(&key_bytes);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &key_bytes);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        var extra: std.ArrayList(http.Header) = .empty;
        try extra.appendSlice(a, &.{
            .{ .name = "Upgrade", .value = "websocket" },
            .{ .name = "Sec-WebSocket-Version", .value = "13" },
            .{ .name = "Sec-WebSocket-Key", .value = &key },
        });
        if (options.protocols.len > 0) {
            for (options.protocols) |p| if (!token(p)) return error.InvalidProtocol;
            try extra.append(a, .{ .name = "Sec-WebSocket-Protocol", .value = try std.mem.join(a, ", ", options.protocols) });
        }
        var std_headers: http.Client.Request.Headers = .{
            .connection = .{ .override = "Upgrade" },
            .accept_encoding = .omit,
            .user_agent = .{ .override = "myzig" },
        };
        for (options.headers) |h| {
            if (!token(h.name) or std.mem.indexOfAny(u8, h.value, "\r\n\x00") != null) return error.InvalidHeader;
            if (std.ascii.startsWithIgnoreCase(h.name, "sec-websocket-") or eql(h.name, "upgrade") or eql(h.name, "connection") or eql(h.name, "content-length")) return error.ReservedHeader;
            if (eql(h.name, "host")) std_headers.host = .{ .override = h.value } //
            else if (eql(h.name, "authorization")) std_headers.authorization = .{ .override = h.value } //
            else if (eql(h.name, "user-agent")) std_headers.user_agent = .{ .override = h.value } //
            else try extra.append(a, .{ .name = h.name, .value = h.value });
        }

        c.req = try client.request(.GET, uri, .{
            .headers = std_headers,
            .extra_headers = extra.items,
            .redirect_behavior = .unhandled,
            .keep_alive = false,
        });
        errdefer c.req.deinit();
        try c.req.sendBodiless();
        const res = try c.req.receiveHead(&.{});
        if (res.head.status != .switching_protocols) return error.HandshakeRefused;

        var upgrade = false;
        var connection = false;
        var accept_ok = false;
        var chosen: ?[]const u8 = null;
        var it = res.head.iterateHeaders();
        while (it.next()) |h| {
            if (eql(h.name, "upgrade")) upgrade = eql(h.value, "websocket") //
            else if (eql(h.name, "connection")) connection = containsToken(h.value, "upgrade") //
            else if (eql(h.name, "sec-websocket-accept")) accept_ok = std.mem.eql(u8, h.value, &acceptKey(&key)) //
            else if (eql(h.name, "sec-websocket-protocol")) chosen = h.value //
            else if (eql(h.name, "sec-websocket-extensions")) return error.HandshakeInvalid; // none were offered
        }
        if (!upgrade or !connection or !accept_ok) return error.HandshakeInvalid;
        if (chosen) |p| {
            for (options.protocols) |o| {
                if (std.mem.eql(u8, o, p)) break;
            } else return error.HandshakeInvalid;
            c.protocol = try gpa.dupe(u8, p);
        }
        return c;
    }

    /// Closes the socket (if `shutdown` did not) and frees the connection.
    pub fn deinit(c: *Conn) void {
        c.req.deinit();
        if (c.protocol.len > 0) c.gpa.free(c.protocol);
        c.gpa.free(c.url_buf);
        c.gpa.destroy(c);
    }

    fn reader(c: *Conn) *Io.Reader {
        return c.req.connection.?.reader();
    }

    /// Reads the next message, answering pings on the way. A close from
    /// the server is answered (unless one was sent) and returned; after it,
    /// read no more. Errors `frame.failCode` maps should fail the
    /// connection with that code (`fail`).
    pub fn read(c: *Conn, gpa: std.mem.Allocator) !Message {
        var msg: std.ArrayList(u8) = .empty;
        errdefer msg.deinit(gpa);
        var kind: ?frame.Opcode = null;
        while (true) {
            const h = try frame.readHeader(c.reader(), .client);
            if (h.opcode.isControl()) {
                var buf: [125]u8 = undefined;
                const payload = buf[0..@intCast(h.len)];
                try frame.readPayload(c.reader(), h, payload);
                switch (h.opcode) {
                    .ping => try c.writeFrame(.pong, payload),
                    .pong => {},
                    .close => {
                        const cl = try frame.parseClose(payload);
                        // Echo the code, as the closing handshake asks.
                        c.close(cl.code, "") catch {};
                        msg.deinit(gpa);
                        return .{ .close = .{ .code = cl.code, .reason = try gpa.dupe(u8, cl.reason) } };
                    },
                    else => unreachable,
                }
                continue;
            }
            switch (h.opcode) {
                .continuation => if (kind == null) return error.ProtocolError,
                else => {
                    if (kind != null) return error.ProtocolError;
                    kind = h.opcode;
                },
            }
            if (msg.items.len + h.len > c.max_message_size) return error.MessageTooBig;
            const start = msg.items.len;
            try msg.resize(gpa, start + @as(usize, @intCast(h.len)));
            try frame.readPayload(c.reader(), h, msg.items[start..]);
            if (!h.fin) continue;
            const bytes = try msg.toOwnedSlice(gpa);
            if (kind.? == .text) {
                if (!std.unicode.utf8ValidateSlice(bytes)) {
                    gpa.free(bytes);
                    return error.InvalidUtf8;
                }
                return .{ .text = bytes };
            }
            return .{ .binary = bytes };
        }
    }

    /// Sends one message, whole.
    pub fn send(c: *Conn, kind: Kind, data: []const u8) !void {
        if (kind == .text and !std.unicode.utf8ValidateSlice(data)) return error.InvalidUtf8;
        try c.writeFrame(if (kind == .text) .text else .binary, data);
    }

    pub fn ping(c: *Conn, data: []const u8) !void {
        if (data.len > 125) return error.PayloadTooLarge;
        try c.writeFrame(.ping, data);
    }

    /// Sends a close frame (once): then wait for the server's in `read`.
    pub fn close(c: *Conn, code: u16, reason: []const u8) !void {
        c.write_lock.lockUncancelable(c.io);
        defer c.write_lock.unlock(c.io);
        if (c.close_sent) return;
        c.close_sent = true;
        var buf: [125]u8 = undefined;
        try c.writeLocked(.close, frame.closePayload(&buf, code, reason));
    }

    /// Fails the connection: a close frame with `code`, best effort.
    pub fn fail(c: *Conn, code: u16) void {
        c.close(code, "") catch {};
    }

    /// Stops the connection at once, from any thread: a `read` blocked on
    /// the server returns.
    pub fn shutdown(c: *Conn) void {
        if (c.req.connection) |conn| conn.stream_reader.stream.shutdown(c.io, .both) catch {};
    }

    fn writeFrame(c: *Conn, op: frame.Opcode, payload: []const u8) !void {
        c.write_lock.lockUncancelable(c.io);
        defer c.write_lock.unlock(c.io);
        if (c.close_sent) return error.Closed;
        try c.writeLocked(op, payload);
    }

    fn writeLocked(c: *Conn, op: frame.Opcode, payload: []const u8) !void {
        var mask: [4]u8 = undefined;
        c.rng.random().bytes(&mask);
        const conn = c.req.connection.?;
        try frame.write(conn.writer(), op, true, payload, mask);
        try conn.flush();
    }
};

/// What the server answers a key with: base64(SHA-1(key ++ GUID)).
pub fn acceptKey(key: []const u8) [28]u8 {
    var sha: std.crypto.hash.Sha1 = .init(.{});
    sha.update(key);
    sha.update(guid);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &digest);
    return out;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn token(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (ch <= ' ' or ch >= 0x7f or std.mem.indexOfScalar(u8, "()<>@,;:\\\"/[]?={}", ch) != null) return false;
    return true;
}

fn containsToken(list: []const u8, want: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, ", \t");
    while (it.next()) |t| if (eql(t, want)) return true;
    return false;
}

test acceptKey {
    // RFC 6455, section 1.3.
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &acceptKey("dGhlIHNhbXBsZSBub25jZQ=="));
}
