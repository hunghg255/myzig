//! SIGINT and SIGTERM on macOS and Linux: the handler only writes a byte
//! to a pipe, whose reading end the main loop watches (`fdwatch`), so the
//! app quits on the main thread. A second signal exits at once, the main
//! thread may be what hangs. Signals the parent ignored (a background
//! job's SIGINT) stay ignored.
const std = @import("std");
const c = std.c;

var pipe_fds: [2]c.fd_t = .{ -1, -1 };
var seen = std.atomic.Value(u32).init(0);

fn handler(sig: c.SIG) callconv(.c) void {
    const n: u8 = @intCast(@intFromEnum(sig));
    if (seen.fetchAdd(1, .monotonic) > 0) c._exit(128 + @as(c_int, n));
    const b: [1]u8 = .{n};
    _ = c.write(pipe_fds[1], &b, 1);
}

/// Installs the handlers; the file descriptor the main loop watches.
pub fn install() !c.fd_t {
    if (pipe_fds[0] >= 0) return pipe_fds[0];
    var fds: [2]c.fd_t = undefined;
    if (c.pipe(&fds) != 0) return error.Pipe;
    for (fds) |fd| _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    _ = c.fcntl(fds[1], c.F.SETFL, @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
    pipe_fds = fds;
    inline for (.{ c.SIG.INT, c.SIG.TERM }) |sig| {
        var old: c.Sigaction = undefined;
        _ = c.sigaction(sig, null, &old);
        if (old.handler.handler != c.SIG.IGN) {
            var act: c.Sigaction = .{ .handler = .{ .handler = handler }, .mask = std.mem.zeroes(c.sigset_t), .flags = c.SA.RESTART };
            _ = c.sigaction(sig, &act, null);
        }
    }
    return fds[0];
}

/// Reads what the handler wrote: the signal, once the watch fired.
pub fn take() ?u8 {
    var b: [1]u8 = undefined;
    const n = c.read(pipe_fds[0], &b, 1);
    return if (n == 1) b[0] else null;
}

/// Puts the default handlers back.
pub fn uninstall() void {
    if (pipe_fds[0] < 0) return;
    inline for (.{ c.SIG.INT, c.SIG.TERM }) |sig| {
        var old: c.Sigaction = undefined;
        _ = c.sigaction(sig, null, &old);
        if (old.handler.handler == &handler) {
            var act: c.Sigaction = .{ .handler = .{ .handler = c.SIG.DFL }, .mask = std.mem.zeroes(c.sigset_t), .flags = 0 };
            _ = c.sigaction(sig, &act, null);
        }
    }
    _ = c.close(pipe_fds[0]);
    _ = c.close(pipe_fds[1]);
    pipe_fds = .{ -1, -1 };
    seen.store(0, .monotonic);
}

test "SIGTERM becomes a byte for the main loop" {
    const fd = try install();
    defer uninstall();
    try std.testing.expect(fd >= 0);
    // What the system does on SIGTERM: call the handler.
    handler(c.SIG.TERM);
    try std.testing.expectEqual(@as(?u8, @intCast(@intFromEnum(c.SIG.TERM))), take());
    try std.testing.expect(seen.load(.monotonic) == 1);
}
