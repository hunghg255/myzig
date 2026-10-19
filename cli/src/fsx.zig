//! What every command shares: the allocator, I/O, environment and output,
//! and small file system helpers over `std.Io.Dir`.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = std.Io.Dir;

pub const Ctx = struct {
    /// The CLI is short lived: everything comes from one arena (the dev
    /// loop makes an arena per rebuild).
    gpa: std.mem.Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    /// The Zig compiler that builds apps: `ZIG`, else `zig` on the PATH.
    zig: []const u8 = "zig",
    /// Quiet: no progress lines (tests).
    quiet: bool = false,

    pub fn log(ctx: Ctx, comptime f: []const u8, args: anytype) void {
        if (ctx.quiet) return;
        std.debug.print(f ++ "\n", args);
    }

    pub fn warn(ctx: Ctx, comptime f: []const u8, args: anytype) void {
        _ = ctx;
        std.debug.print("warning: " ++ f ++ "\n", args);
    }

    pub fn fmt(ctx: Ctx, comptime f: []const u8, args: anytype) ![]u8 {
        return std.fmt.allocPrint(ctx.gpa, f, args);
    }

    pub fn join(ctx: Ctx, parts: []const []const u8) ![]u8 {
        return std.fs.path.join(ctx.gpa, parts);
    }
};

/// Writes to standard output (help, version, doctor).
pub fn out(io: Io, comptime f: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    w.interface.print(f, args) catch {};
    w.interface.flush() catch {};
}

pub fn exists(io: Io, path: []const u8) bool {
    Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn isDir(io: Io, path: []const u8) bool {
    const st = Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

pub fn isFile(io: Io, path: []const u8) bool {
    const st = Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

/// Whether a file is executable by its mode (always false on Windows,
/// whose files have none).
pub fn isExecutable(io: Io, path: []const u8) bool {
    if (builtin.os.tag == .windows) return false;
    const st = Dir.cwd().statFile(io, path, .{}) catch return false;
    return @intFromEnum(st.permissions) & 0o111 != 0;
}

pub fn read(ctx: Ctx, path: []const u8) ![]u8 {
    return Dir.cwd().readFileAlloc(ctx.io, path, ctx.gpa, .limited(1 << 30));
}

/// Writes a file, making its directories first.
pub fn write(io: Io, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try Dir.cwd().createDirPath(io, d);
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

/// Writes an executable file (mode 0755 where files have modes).
pub fn writeExecutable(io: Io, path: []const u8, data: []const u8) !void {
    try write(io, path, data);
    if (Io.File.Permissions.has_executable_bit)
        try Dir.cwd().setFilePermissions(io, path, .fromMode(0o755), .{});
}

pub fn makeDir(io: Io, path: []const u8) !void {
    try Dir.cwd().createDirPath(io, path);
}

pub fn remove(io: Io, path: []const u8) void {
    Dir.cwd().deleteTree(io, path) catch {};
}

pub fn copyFile(io: Io, src: []const u8, dst: []const u8) !void {
    if (std.fs.path.dirname(dst)) |d| try Dir.cwd().createDirPath(io, d);
    try Dir.cwd().copyFile(src, Dir.cwd(), dst, io, .{});
}

/// Copies a file or a directory tree to `dst`.
pub fn copyTree(ctx: Ctx, src: []const u8, dst: []const u8) !void {
    if (!isDir(ctx.io, src)) return copyFile(ctx.io, src, dst);
    try makeDir(ctx.io, dst);
    var dir = try Dir.cwd().openDir(ctx.io, src, .{ .iterate = true });
    defer dir.close(ctx.io);
    var walker = try dir.walk(ctx.gpa);
    defer walker.deinit();
    while (try walker.next(ctx.io)) |entry| {
        const to = try ctx.join(&.{ dst, entry.path });
        switch (entry.kind) {
            .directory => try makeDir(ctx.io, to),
            .file => try copyFile(ctx.io, try ctx.join(&.{ src, entry.path }), to),
            else => {},
        }
    }
}

/// The absolute form of `path`, which must exist.
pub fn absolute(ctx: Ctx, path: []const u8) ![]u8 {
    const z = try Dir.cwd().realPathFileAlloc(ctx.io, path, ctx.gpa);
    return z[0..z.len];
}

fn sepAt(c: u8) bool {
    return c == '/' or c == '\\';
}

fn componentEql(a: []const u8, b: []const u8) bool {
    return if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

/// The path of `to` relative to the directory `from`, both absolute, with
/// forward slashes (as build.zig.zon wants them), or null when there is
/// none: on Windows, paths on two drives.
pub fn relative(gpa: std.mem.Allocator, from: []const u8, to: []const u8) !?[]u8 {
    var fa: std.ArrayList([]const u8) = .empty;
    var ta: std.ArrayList([]const u8) = .empty;
    defer fa.deinit(gpa);
    defer ta.deinit(gpa);
    var it = std.mem.tokenizeAny(u8, from, "/\\");
    while (it.next()) |p| try fa.append(gpa, p);
    it = std.mem.tokenizeAny(u8, to, "/\\");
    while (it.next()) |p| try ta.append(gpa, p);
    if (builtin.os.tag == .windows and (fa.items.len == 0 or ta.items.len == 0 or !componentEql(fa.items[0], ta.items[0]))) return null;
    var common: usize = 0;
    while (common < fa.items.len and common < ta.items.len and componentEql(fa.items[common], ta.items[common])) common += 1;
    var outp: std.ArrayList(u8) = .empty;
    for (fa.items[common..]) |_| try outp.appendSlice(gpa, if (outp.items.len == 0) ".." else "/..");
    for (ta.items[common..]) |p| {
        if (outp.items.len > 0) try outp.append(gpa, '/');
        try outp.appendSlice(gpa, p);
    }
    if (outp.items.len == 0) try outp.append(gpa, '.');
    return try outp.toOwnedSlice(gpa);
}

/// Makes `s` usable as a file name on every platform.
pub fn fsName(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    const t = std.mem.trim(u8, s, " \t");
    const o = try gpa.dupe(u8, t);
    for (o) |*c| if (c.* < ' ' or std.mem.indexOfScalar(u8, "/\\:*?\"<>|", c.*) != null) {
        c.* = '-';
    };
    return o;
}

/// The seconds since 1970, for archives: SOURCE_DATE_EPOCH when set
/// (reproducible builds), else now.
pub fn epoch(ctx: Ctx) u64 {
    if (ctx.env.get("SOURCE_DATE_EPOCH")) |s| if (std.fmt.parseInt(u64, s, 10)) |v| return v else |_| {};
    const now = Io.Clock.real.now(ctx.io).toSeconds();
    return if (now > 0) @intCast(now) else 0;
}

/// The seconds since 1970, now (requests signed with the time).
pub fn nowSeconds(ctx: Ctx) u64 {
    const now = Io.Clock.real.now(ctx.io).toSeconds();
    return if (now > 0) @intCast(now) else 0;
}

/// `s` repeated `n` times, at compile time.
pub fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    return comptime blk: {
        var buf: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(buf[i * s.len ..][0..s.len], s);
        const final = buf;
        break :blk &final;
    };
}

test relative {
    const gpa = std.testing.allocator;
    const cases = if (builtin.os.tag == .windows) [_][3][]const u8{
        .{ "D:\\a\\b\\app", "D:\\a\\myzig", "../../myzig" },
        .{ "D:\\a", "D:\\a\\b", "b" },
        .{ "d:\\A", "D:\\a", "." },
    } else [_][3][]const u8{
        .{ "/a/b/app", "/a/myzig", "../../myzig" },
        .{ "/a", "/a/b", "b" },
        .{ "/a", "/a", "." },
    };
    for (cases) |c| {
        const r = (try relative(gpa, c[0], c[1])).?;
        defer gpa.free(r);
        try std.testing.expectEqualStrings(c[2], r);
    }
    if (builtin.os.tag == .windows) try std.testing.expect(try relative(gpa, "C:\\x", "D:\\y") == null);
}

test fsName {
    const n = try fsName(std.testing.allocator, " My: App/2 ");
    defer std.testing.allocator.free(n);
    try std.testing.expectEqualStrings("My- App-2", n);
}
