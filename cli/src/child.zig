//! The processes `myzig dev` runs (the app, the dev server): started with
//! this process's output, asked whether they ended without blocking, and
//! stopped (SIGTERM, then SIGKILL; TerminateProcess on Windows).
const std = @import("std");
const builtin = @import("builtin");
const fsx = @import("fsx.zig");
const Ctx = fsx.Ctx;

const windows = builtin.os.tag == .windows;

extern "kernel32" fn WaitForSingleObject(h: *anyopaque, ms: u32) callconv(.winapi) u32;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;

pub const Running = struct {
    child: std.process.Child,
    done: bool = false,
    /// The exit code, once it exited normally.
    code: ?u8 = null,

    pub fn start(ctx: Ctx, argv: []const []const u8, cwd: []const u8, env: ?*const std.process.Environ.Map) !Running {
        const child = try std.process.spawn(ctx.io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .environ_map = env,
            .stdin = .ignore,
        });
        return .{ .child = child };
    }

    /// Whether the process ended, without waiting for it.
    pub fn exited(r: *Running, ctx: Ctx) bool {
        if (r.done) return true;
        const id = r.child.id orelse return true;
        if (windows) {
            if (WaitForSingleObject(id, 0) != 0) return false;
            if (r.child.wait(ctx.io)) |term| switch (term) {
                .exited => |c| r.code = c,
                else => {},
            } else |_| {}
        } else {
            var status: c_int = 0;
            if (!reap(id, &status, true)) return false;
            r.child.id = null; // reaped here, not by std
            if (status & 0x7f == 0) r.code = @intCast((status >> 8) & 0xff);
        }
        r.done = true;
        return true;
    }

    fn reap(pid: std.process.Child.Id, status: *c_int, nohang: bool) bool {
        if (builtin.os.tag == .linux and !builtin.link_libc) {
            var s: i32 = 0;
            const rc = std.os.linux.syscall4(.wait4, @bitCast(@as(isize, pid)), @intFromPtr(&s), @intFromBool(nohang), 0);
            status.* = s;
            return @as(isize, @bitCast(rc)) == pid;
        }
        return waitpid(@intCast(pid), status, @intFromBool(nohang)) == pid;
    }

    fn signal(pid: std.process.Child.Id, sig: c_int) void {
        if (builtin.os.tag == .linux and !builtin.link_libc) {
            _ = std.os.linux.syscall2(.kill, @bitCast(@as(isize, pid)), @intCast(sig));
        } else _ = kill(@intCast(pid), sig);
    }

    /// Stops the process and waits for it: asked to quit first (SIGTERM),
    /// which lets an app release what it holds, killed after 5 seconds.
    pub fn stop(r: *Running, ctx: Ctx) void {
        if (r.exited(ctx)) return;
        if (windows) {
            r.child.kill(ctx.io);
            r.done = true;
            return;
        }
        const pid = r.child.id.?;
        signal(pid, 15);
        var waited: u32 = 0;
        while (waited < 5000) : (waited += 50) {
            if (r.exited(ctx)) return;
            std.Io.sleep(ctx.io, .fromMilliseconds(50), .awake) catch {};
        }
        signal(pid, 9);
        var status: c_int = 0;
        _ = reap(pid, &status, false);
        r.child.id = null;
        r.done = true;
    }
};

/// Waits until a TCP server answers at the host and port of an http(s)
/// URL, or `while_running` ends; up to two minutes.
pub fn waitForServer(ctx: Ctx, url: []const u8, while_running: ?*Running) !void {
    const https = std.mem.startsWith(u8, url, "https://");
    const rest = url[if (https) 8 else 7..];
    const host_port = rest[0 .. std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len];
    var host = host_port;
    var port: u16 = if (https) 443 else 80;
    if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |i| if (std.mem.indexOfScalar(u8, host_port, ']') == null or i > std.mem.indexOfScalar(u8, host_port, ']').?) {
        host = host_port[0..i];
        port = std.fmt.parseInt(u16, host_port[i + 1 ..], 10) catch port;
    };
    host = std.mem.trim(u8, host, "[]");
    const literal = if (std.mem.eql(u8, host, "localhost")) "127.0.0.1" else host;
    const addresses = [_][]const u8{ literal, "::1" };
    var tries: usize = 0;
    while (tries < 480) : (tries += 1) {
        for (addresses, 0..) |a, k| {
            if (k == 1 and !std.mem.eql(u8, host, "localhost")) break;
            const addr = std.Io.net.IpAddress.parse(a, port) catch return error.BadDevUrl;
            if (addr.connect(ctx.io, .{ .mode = .stream })) |s| {
                s.close(ctx.io);
                return;
            } else |_| {}
        }
        if (while_running) |r| if (r.exited(ctx)) return error.DevCommandExited;
        std.Io.sleep(ctx.io, .fromMilliseconds(250), .awake) catch {};
    }
    return error.DevServerTimeout;
}
