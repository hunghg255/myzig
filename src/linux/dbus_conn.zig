//! A connection to the D-Bus session bus, in Zig alone: the Unix socket of
//! DBUS_SESSION_BUS_ADDRESS (or $XDG_RUNTIME_DIR/bus), EXTERNAL
//! authentication, calls that wait for their reply (a few seconds at
//! most), and signals passed to a handler once the main loop watches the
//! connection. One per app, opened when a feature first needs it.
const std = @import("std");
const c = std.c;
const dbus = @import("dbus.zig");

pub const Signal = *const fn (ctx: ?*anyopaque, msg: *dbus.Message) void;

pub const Bus = struct {
    gpa: std.mem.Allocator,
    fd: c.fd_t,
    serial: u32 = 0,
    /// Bytes read but not yet a whole message.
    pending: std.ArrayList(u8) = .empty,
    on_signal: ?Signal = null,
    signal_ctx: ?*anyopaque = null,
    /// The connection's unique name on the bus (":1.42"), from Hello.
    unique_buf: [64]u8 = undefined,
    unique_len: usize = 0,

    /// Connects to the session bus at `address` ("unix:path=..." or
    /// "unix:abstract=..."), authenticates and says Hello.
    pub fn open(gpa: std.mem.Allocator, address: []const u8) !*Bus {
        var addr: c.sockaddr.un = .{ .path = @splat(0) };
        var len: usize = 0;
        var it = std.mem.splitScalar(u8, address, ';');
        const first = it.next() orelse return error.BadAddress;
        if (!std.mem.startsWith(u8, first, "unix:")) return error.BadAddress;
        var params = std.mem.splitScalar(u8, first["unix:".len..], ',');
        while (params.next()) |p| {
            if (std.mem.startsWith(u8, p, "path=")) {
                const v = p["path=".len..];
                if (v.len >= addr.path.len) return error.BadAddress;
                @memcpy(addr.path[0..v.len], v);
                len = v.len + 1;
            } else if (std.mem.startsWith(u8, p, "abstract=")) {
                const v = p["abstract=".len..];
                if (v.len + 1 >= addr.path.len) return error.BadAddress;
                @memcpy(addr.path[1 .. 1 + v.len], v);
                len = v.len + 1;
            }
        }
        if (len == 0) return error.BadAddress;
        const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM | c.SOCK.CLOEXEC, 0);
        if (fd < 0) return error.Socket;
        errdefer _ = c.close(fd);
        const sa_len: c.socklen_t = @intCast(@offsetOf(c.sockaddr.un, "path") + len);
        if (c.connect(fd, @ptrCast(&addr), sa_len) != 0) return error.Connect;
        const self = try gpa.create(Bus);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .fd = fd };
        try self.auth();
        var reply = try self.call(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "Hello" }, "", "");
        defer reply.deinit(gpa);
        var m = try reply.message();
        const name = m.body.string() catch "";
        self.unique_len = @min(name.len, self.unique_buf.len);
        @memcpy(self.unique_buf[0..self.unique_len], name[0..self.unique_len]);
        return self;
    }

    /// The session bus of the user's desktop.
    pub fn session(gpa: std.mem.Allocator) !*Bus {
        if (c.getenv("DBUS_SESSION_BUS_ADDRESS")) |a| return open(gpa, std.mem.span(a));
        const dir = c.getenv("XDG_RUNTIME_DIR") orelse return error.NoBus;
        var buf: [256]u8 = undefined;
        return open(gpa, try std.fmt.bufPrint(&buf, "unix:path={s}/bus", .{std.mem.span(dir)}));
    }

    /// The connection's unique name (":1.42").
    pub fn uniqueName(self: *const Bus) []const u8 {
        return self.unique_buf[0..self.unique_len];
    }

    pub fn close(self: *Bus) void {
        _ = c.close(self.fd);
        self.pending.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn writeAll(self: *Bus, bytes: []const u8) !void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const n = c.write(self.fd, bytes[sent..].ptr, bytes.len - sent);
            if (n <= 0) return error.Write;
            sent += @intCast(n);
        }
    }

    /// Waits up to `ms` for bytes; false on timeout.
    fn wait(self: *Bus, ms: i32) bool {
        var fds = [_]c.pollfd{.{ .fd = self.fd, .events = c.POLL.IN, .revents = 0 }};
        return c.poll(&fds, 1, ms) > 0;
    }

    fn auth(self: *Bus) !void {
        var buf: [64]u8 = undefined;
        var uid_buf: [16]u8 = undefined;
        const uid = try std.fmt.bufPrint(&uid_buf, "{d}", .{c.getuid()});
        // The uid's decimal digits, each as two hex digits.
        var hex_buf: [32]u8 = undefined;
        for (uid, 0..) |ch, i| _ = std.fmt.bufPrint(hex_buf[i * 2 ..][0..2], "{x:0>2}", .{ch}) catch unreachable;
        const line = try std.fmt.bufPrint(&buf, "\x00AUTH EXTERNAL {s}\r\n", .{hex_buf[0 .. uid.len * 2]});
        try self.writeAll(line);
        var got: [256]u8 = undefined;
        var n: usize = 0;
        while (std.mem.indexOf(u8, got[0..n], "\r\n") == null) {
            if (n == got.len or !self.wait(3000)) return error.Auth;
            const r = c.read(self.fd, got[n..].ptr, got.len - n);
            if (r <= 0) return error.Auth;
            n += @intCast(r);
        }
        if (!std.mem.startsWith(u8, got[0..n], "OK ")) return error.Auth;
        try self.writeAll("BEGIN\r\n");
    }

    pub const Target = struct { destination: []const u8, path: []const u8, interface: []const u8, member: []const u8 };

    /// Sends a method call without waiting; returns its serial.
    pub fn send(self: *Bus, t: Target, signature: []const u8, body: []const u8, no_reply: bool) !u32 {
        self.serial += 1;
        const msg = try dbus.message(self.gpa, .{ .type = .method_call, .flags = if (no_reply) 1 else 0, .serial = self.serial, .destination = t.destination, .path = t.path, .interface = t.interface, .member = t.member, .signature = signature }, body);
        defer self.gpa.free(msg);
        try self.writeAll(msg);
        return self.serial;
    }

    /// A reply's bytes (owned): decode with `dbus.parse(reply.bytes)`.
    pub const Reply = struct {
        bytes: []u8,

        pub fn deinit(r: *Reply, gpa: std.mem.Allocator) void {
            gpa.free(r.bytes);
        }

        pub fn message(r: *Reply) !dbus.Message {
            return dbus.parse(r.bytes);
        }
    };

    /// Calls a method and waits for its reply; signals that arrive first
    /// go to the handler. An error reply is `error.Remote`.
    pub fn call(self: *Bus, t: Target, signature: []const u8, body: []const u8) !Reply {
        const serial = try self.send(t, signature, body, false);
        var tries: usize = 0;
        while (tries < 1000) : (tries += 1) {
            const bytes = (try self.next(3000)) orelse return error.Timeout;
            var m = dbus.parse(bytes) catch {
                self.gpa.free(bytes);
                continue;
            };
            if ((m.header.type == .method_return or m.header.type == .@"error") and m.header.reply_serial == serial) {
                if (m.header.type == .@"error") {
                    self.gpa.free(bytes);
                    self.flush();
                    return error.Remote;
                }
                // Signals read with the reply would wait for the socket's
                // next bytes: the handler gets them now.
                self.flush();
                return .{ .bytes = bytes };
            }
            defer self.gpa.free(bytes);
            if (m.header.type == .signal) if (self.on_signal) |f| f(self.signal_ctx, &m);
        }
        return error.Timeout;
    }

    /// The next whole message (owned), waiting up to `ms` for it; null on timeout.
    pub fn next(self: *Bus, ms: i32) !?[]u8 {
        while (true) {
            if (dbus.messageLen(self.pending.items)) |len| if (self.pending.items.len >= len) {
                const out = try self.gpa.dupe(u8, self.pending.items[0..len]);
                self.pending.replaceRangeAssumeCapacity(0, len, &.{});
                return out;
            };
            if (ms > 0 and !self.wait(ms)) return null;
            var buf: [4096]u8 = undefined;
            const n = c.read(self.fd, &buf, buf.len);
            if (n <= 0) return error.Closed;
            try self.pending.appendSlice(self.gpa, buf[0..@intCast(n)]);
            if (ms == 0) {
                if (dbus.messageLen(self.pending.items)) |len| if (self.pending.items.len >= len) continue;
                return null;
            }
        }
    }

    /// Handles the whole messages already read (signals), without reading.
    fn flush(self: *Bus) void {
        while (dbus.messageLen(self.pending.items)) |len| {
            if (self.pending.items.len < len) return;
            const bytes = self.next(0) catch return orelse return;
            defer self.gpa.free(bytes);
            var m = dbus.parse(bytes) catch continue;
            if (m.header.type == .signal) if (self.on_signal) |f| f(self.signal_ctx, &m);
        }
    }

    /// The connection has bytes (the main loop's watch): handles the
    /// signals among them.
    pub fn dispatch(self: *Bus) void {
        var first = true;
        while (true) {
            const bytes = (self.next(if (first) 0 else -1) catch return) orelse return;
            first = false;
            defer self.gpa.free(bytes);
            var m = dbus.parse(bytes) catch continue;
            if (m.header.type == .signal) if (self.on_signal) |f| f(self.signal_ctx, &m);
            // More may be buffered: only read again when there is no whole one.
            if (dbus.messageLen(self.pending.items)) |len| {
                if (self.pending.items.len < len) return;
            } else return;
        }
    }

    /// Asks the bus for the signals `rule` matches
    /// ("type='signal',interface='org.freedesktop.Notifications'").
    pub fn addMatch(self: *Bus, rule: []const u8) !void {
        var e: dbus.Encoder = .{ .gpa = self.gpa };
        defer e.deinit();
        try e.string(rule);
        _ = try self.send(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "AddMatch" }, "s", e.buf.items, true);
    }
};

test "the session bus answers, when there is one" {
    const gpa = std.testing.allocator;
    const bus = Bus.session(gpa) catch return error.SkipZigTest;
    defer bus.close();
    var reply = try bus.call(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "GetId" }, "", "");
    defer reply.deinit(gpa);
    var m = try reply.message();
    try std.testing.expectEqualStrings("s", m.header.signature);
    try std.testing.expectEqual(@as(usize, 32), (try m.body.string()).len);
    try std.testing.expect(std.mem.startsWith(u8, bus.uniqueName(), ":"));

    // A signal matched by a rule reaches the handler, before the reply of
    // a call made after it.
    const S = struct {
        got: usize = 0,
        fn on(ctx: ?*anyopaque, msg: *dbus.Message) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, msg.header.member, "Ping")) s.got += 1;
        }
    };
    var s: S = .{};
    bus.on_signal = S.on;
    bus.signal_ctx = &s;
    try bus.addMatch("type='signal',interface='org.myzig.Test'");
    var ping = try bus.call(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "GetId" }, "", "");
    ping.deinit(gpa);
    bus.serial += 1;
    const sig = try dbus.message(gpa, .{ .type = .signal, .serial = bus.serial, .path = "/org/myzig/Test", .interface = "org.myzig.Test", .member = "Ping" }, "");
    defer gpa.free(sig);
    try bus.writeAll(sig);
    var after = try bus.call(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "GetId" }, "", "");
    after.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), s.got);
}
