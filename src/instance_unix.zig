//! A single instance on macOS and Linux: the first instance listens on a
//! Unix socket named after the app (in XDG_RUNTIME_DIR, TMPDIR or /tmp);
//! a later one connects, writes its command line and exits. A socket left
//! by a crash answers nobody: it is replaced.
const std = @import("std");
const c = std.c;

pub const Listener = struct {
    fd: c.fd_t,
    path: [120:0]u8,

    /// Stops listening and removes the socket.
    pub fn release(l: *Listener) void {
        _ = c.close(l.fd);
        _ = c.unlink(&l.path);
    }

    /// Takes one waiting connection's message (blocking until its sender
    /// closed it, which it does right after writing). Caller frees it.
    pub fn accept(l: *Listener, gpa: std.mem.Allocator) !?[]u8 {
        const fd = c.accept(l.fd, null, null);
        if (fd < 0) return null;
        defer _ = c.close(fd);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var buf: [4096]u8 = undefined;
        while (out.items.len < 1 << 20) {
            const n = c.read(fd, &buf, buf.len);
            if (n <= 0) break;
            try out.appendSlice(gpa, buf[0..@intCast(n)]);
        }
        return try out.toOwnedSlice(gpa);
    }
};

pub const Result = union(enum) {
    first: Listener,
    forwarded,
};

fn address(name: []const u8) c.sockaddr.un {
    var a: c.sockaddr.un = .{ .path = @splat(0) };
    const dir = blk: {
        for ([_][*:0]const u8{ "XDG_RUNTIME_DIR", "TMPDIR" }) |v| if (c.getenv(v)) |d| {
            const s = std.mem.span(d);
            if (s.len > 0 and s.len + name.len + 24 < a.path.len) break :blk s;
        };
        break :blk "/tmp";
    };
    const sep = if (std.mem.endsWith(u8, dir, "/")) "" else "/";
    _ = std.fmt.bufPrint(&a.path, "{s}{s}{s}-{d}.sock", .{ dir, sep, name, c.getuid() }) catch {};
    return a;
}

fn socket() c.fd_t {
    return c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
}

/// Listens on the socket named `name`, or hands `message` to the
/// instance listening on it.
pub fn request(name: []const u8, message: []const u8) Result {
    const addr = address(name);
    var attempt: u32 = 0;
    while (attempt < 5) : (attempt += 1) {
        const client = socket();
        if (client < 0) break;
        if (c.connect(client, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) == 0) {
            var sent: usize = 0;
            while (sent < message.len) {
                const n = c.write(client, message[sent..].ptr, message.len - sent);
                if (n <= 0) break;
                sent += @intCast(n);
            }
            _ = c.close(client);
            return .forwarded;
        }
        _ = c.close(client);
        // Nobody answers: a stale socket, or none. Take it over; if another
        // instance wins the race, bind fails and the next attempt connects.
        _ = c.unlink(@ptrCast(&addr.path));
        const server = socket();
        if (server < 0) break;
        if (c.bind(server, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) == 0 and c.listen(server, 16) == 0) {
            var l: Listener = .{ .fd = server, .path = @splat(0) };
            @memcpy(l.path[0..addr.path.len], &addr.path);
            return .{ .first = l };
        }
        _ = c.close(server);
    }
    // Locking is not possible here (a read-only directory): the only instance.
    return .{ .first = .{ .fd = -1, .path = @splat(0) } };
}

test "the first instance listens; later ones hand their command line over" {
    const gpa = std.testing.allocator;
    var rnd: [4]u8 = undefined;
    std.Io.random(std.testing.io, &rnd);
    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "myzig-test-{x}", .{std.mem.readInt(u32, &rnd, .little)});
    var first = switch (request(name, "")) {
        .first => |l| l,
        .forwarded => return error.NotFirst,
    };
    defer first.release();
    try std.testing.expect(first.fd >= 0);
    try std.testing.expect(request(name, "/home\x00a.md\x00") == .forwarded);
    const got = (try first.accept(gpa)).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/home\x00a.md\x00", got);
}
