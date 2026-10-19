//! Pseudo-terminals on macOS and Linux, through libc: posix_openpt,
//! grantpt, unlockpt and ptsname for the pair, then a child in a session
//! of its own whose controlling terminal is the slave.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Options = @import("pty.zig").Options;

const mac = builtin.os.tag == .macos;
const O_RDONLY: c_int = 0;
const O_RDWR: c_int = 2;
const O_NOCTTY: c_int = if (mac) 0x20000 else 0o400;
const O_CLOEXEC: c_int = if (mac) 0x1000000 else 0o2000000;
const TIOCSWINSZ: c_ulong = if (mac) 0x80087467 else 0x5414;
const TIOCSCTTY: c_ulong = if (mac) 0x20007461 else 0x540E;
const SIGKILL: c_int = 9;
const EINTR: c_int = 4;

const Winsize = extern struct { row: u16, col: u16, xpixel: u16, ypixel: u16 };

const c = struct {
    pub extern "c" fn posix_openpt(flags: c_int) c_int;
    pub extern "c" fn grantpt(fd: c_int) c_int;
    pub extern "c" fn unlockpt(fd: c_int) c_int;
    pub extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
    pub extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    pub extern "c" fn close(fd: c_int) c_int;
    pub extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
    pub extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
    pub extern "c" fn ioctl(fd: c_int, req: c_ulong, ...) c_int;
    pub extern "c" fn fork() c_int;
    pub extern "c" fn setsid() c_int;
    pub extern "c" fn dup2(a: c_int, b: c_int) c_int;
    pub extern "c" fn chdir(path: [*:0]const u8) c_int;
    pub extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
    pub extern "c" fn _exit(code: c_int) noreturn;
    pub extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
    pub extern "c" fn kill(pid: c_int, sig: c_int) c_int;
    pub extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
    pub extern "c" fn __errno_location() *c_int;
    pub extern "c" fn __error() *c_int;
    pub extern "c" fn _NSGetEnviron() *[*:null]?[*:0]u8;
};

fn errno() c_int {
    return if (mac) c.__error().* else c.__errno_location().*;
}

pub const Pty = struct {
    master: c_int,
    pid: c_int,

    pub fn start(gpa: std.mem.Allocator, _: Io, o: Options) !Pty {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        // Everything the child needs is made before it forks: after fork
        // it only calls what is safe there.
        const path = try resolve(arena, o.argv[0]);
        const argv = try arena.allocSentinel(?[*:0]const u8, o.argv.len, null);
        for (o.argv, 0..) |a, i| argv[i] = try zstr(arena, a);
        const envp = try environment(arena, o.env);
        const dir: ?[*:0]const u8 = if (o.dir) |d| try zstr(arena, d) else null;

        const master = c.posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC);
        if (master < 0) return error.PtyFailed;
        errdefer _ = c.close(master);
        if (c.grantpt(master) != 0 or c.unlockpt(master) != 0) return error.PtyFailed;
        const name = c.ptsname(master) orelse return error.PtyFailed;
        const slave = c.open(name, O_RDWR | O_NOCTTY);
        if (slave < 0) return error.PtyFailed;
        defer _ = c.close(slave); // the child has its own copies
        var ws: Winsize = .{ .row = o.rows, .col = o.cols, .xpixel = o.width, .ypixel = o.height };
        _ = c.ioctl(master, TIOCSWINSZ, &ws);

        const pid = c.fork();
        if (pid < 0) return error.SpawnFailed;
        if (pid == 0) {
            // A session of its own, whose controlling terminal is the
            // slave, so that the terminal's signals reach its foreground.
            _ = c.setsid();
            _ = c.ioctl(slave, TIOCSCTTY, @as(c_int, 0));
            _ = c.dup2(slave, 0);
            _ = c.dup2(slave, 1);
            _ = c.dup2(slave, 2);
            if (slave > 2) _ = c.close(slave);
            if (dir) |d| _ = c.chdir(d);
            _ = c.execve(path, argv.ptr, envp.ptr);
            c._exit(127);
        }
        return .{ .master = master, .pid = pid };
    }

    /// Reads the program's output: 0 once no process has the terminal
    /// open any more (Linux reports EIO then).
    pub fn read(p: *Pty, buf: []u8) usize {
        while (true) {
            const n = c.read(p.master, buf.ptr, buf.len);
            if (n > 0) return @intCast(n);
            if (n < 0 and errno() == EINTR) continue;
            return 0;
        }
    }

    /// Types `bytes` into the terminal.
    pub fn write(p: *Pty, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0) {
            const n = c.write(p.master, rest.ptr, rest.len);
            if (n < 0) {
                if (errno() == EINTR) continue;
                return error.Closed;
            }
            rest = rest[@intCast(n)..];
        }
    }

    /// Sets the size of the terminal, which sends the program SIGWINCH.
    pub fn resize(p: *Pty, cols: u16, rows: u16, width: u16, height: u16) void {
        var ws: Winsize = .{ .row = rows, .col = cols, .xpixel = width, .ypixel = height };
        _ = c.ioctl(p.master, TIOCSWINSZ, &ws);
    }

    /// Waits for the program to exit: its exit code, 128 plus the signal
    /// that ended it.
    pub fn wait(p: *Pty) u32 {
        var status: c_int = 0;
        while (c.waitpid(p.pid, &status, 0) < 0) {
            if (errno() != EINTR) return 1;
        }
        const s: u32 = @bitCast(status);
        if (s & 0x7f == 0) return (s >> 8) & 0xff;
        return 128 + (s & 0x7f);
    }

    /// Hangs up nothing here: the reader ends as the last process with the
    /// terminal open closes it. Kill the process group with `kill`.
    pub fn hangUp(_: *Pty) void {}

    /// Kills the program and its process group, which it leads.
    pub fn kill(p: *Pty) void {
        if (c.kill(-p.pid, SIGKILL) != 0) _ = c.kill(p.pid, SIGKILL);
    }

    /// Closes the terminal, which hangs up the processes that have it.
    pub fn deinit(p: *Pty) void {
        _ = c.close(p.master);
    }
};

fn zstr(arena: std.mem.Allocator, s: []const u8) ![*:0]const u8 {
    const out = try arena.allocSentinel(u8, s.len, 0);
    @memcpy(out, s);
    return out.ptr;
}

/// The path of program `name`: as given with a slash, else on the PATH.
fn resolve(arena: std.mem.Allocator, name: []const u8) ![*:0]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return zstr(arena, name);
    const path = std.mem.span(std.c.getenv("PATH") orelse "/usr/bin:/bin");
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ dir, name }, 0);
        if (c.access(full.ptr, 1) == 0) return full.ptr; // X_OK
    }
    return error.ProgramNotFound;
}

/// This process's environment with `extra` ("KEY=value") set.
fn environment(arena: std.mem.Allocator, extra: []const []const u8) ![:null]?[*:0]const u8 {
    var out: std.ArrayList(?[*:0]const u8) = .empty;
    for (try current(arena)) |e| {
        const entry = std.mem.span(e);
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse entry.len;
        var set = false;
        for (extra) |kv| {
            const k = kv[0 .. std.mem.indexOfScalar(u8, kv, '=') orelse kv.len];
            if (std.mem.eql(u8, k, entry[0..eq])) set = true;
        }
        if (!set) try out.append(arena, e);
    }
    for (extra) |kv| try out.append(arena, try zstr(arena, kv));
    return out.toOwnedSliceSentinel(arena, null);
}

/// This process's environment. Not through `environ`, which an executable
/// reads from a copy that glibc's start never sets (a copy relocation of
/// the alias): macOS's _NSGetEnviron, Linux's /proc/self/environ.
fn current(arena: std.mem.Allocator) ![]const [*:0]const u8 {
    var out: std.ArrayList([*:0]const u8) = .empty;
    if (mac) {
        const env = c._NSGetEnviron().*;
        var i: usize = 0;
        while (env[i]) |e| : (i += 1) try out.append(arena, e);
        return out.items;
    }
    const fd = c.open("/proc/self/environ", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return out.items;
    defer _ = c.close(fd);
    var data: std.ArrayList(u8) = .empty;
    var buf: [16 << 10]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        try data.appendSlice(arena, buf[0..@intCast(n)]);
    }
    try data.append(arena, 0);
    var start: usize = 0;
    for (data.items, 0..) |ch, i| if (ch == 0) {
        if (i > start) try out.append(arena, data.items[start..i :0].ptr);
        start = i + 1;
    };
    return out.items;
}

/// The user's shell: $SHELL, else /bin/zsh on macOS and /bin/sh elsewhere.
pub fn defaultShell(gpa: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("SHELL")) |s| if (s[0] != 0) return gpa.dupe(u8, std.mem.span(s));
    return gpa.dupe(u8, if (mac) "/bin/zsh" else "/bin/sh");
}
