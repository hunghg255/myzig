//! Running other programs: Zig, the platform's tools, the app's commands.
const std = @import("std");
const builtin = @import("builtin");
const fsx = @import("fsx.zig");
const Ctx = fsx.Ctx;

pub const Output = struct {
    ok: bool,
    stdout: []u8,
    stderr: []u8,
};

/// Runs `argv` in `cwd` (null: here), capturing its output.
pub fn capture(ctx: Ctx, argv: []const []const u8, cwd: ?[]const u8) !Output {
    const r = try std.process.run(ctx.gpa, ctx.io, .{
        .argv = argv,
        .cwd = if (cwd) |d| .{ .path = d } else .inherit,
    });
    return .{ .ok = r.term.success(), .stdout = r.stdout, .stderr = r.stderr };
}

/// Runs `argv` with this process's output, failing when it fails.
pub fn check(ctx: Ctx, argv: []const []const u8, cwd: ?[]const u8) !void {
    return checkEnv(ctx, argv, cwd, null);
}

pub fn checkEnv(ctx: Ctx, argv: []const []const u8, cwd: ?[]const u8, env: ?*const std.process.Environ.Map) !void {
    var child = std.process.spawn(ctx.io, .{
        .argv = argv,
        .cwd = if (cwd) |d| .{ .path = d } else .inherit,
        .environ_map = env,
        .stdin = .ignore,
    }) catch |e| {
        std.debug.print("error: could not run {s}: {t}\n", .{ argv[0], e });
        return error.CommandFailed;
    };
    const term = try child.wait(ctx.io);
    if (!term.success()) {
        std.debug.print("error: {s} failed ({f})\n", .{ argv[0], term });
        return error.CommandFailed;
    }
}

/// The argv that runs a command line through the system's shell.
pub fn shell(command: []const u8) [3][]const u8 {
    return if (builtin.os.tag == .windows) .{ "cmd.exe", "/C", command } else .{ "/bin/sh", "-c", command };
}

/// Finds a program on the PATH (with Windows' extensions), or null.
pub fn which(ctx: Ctx, name: []const u8) ?[]const u8 {
    if (std.fs.path.isAbsolute(name)) return if (fsx.isFile(ctx.io, name)) name else null;
    const path = ctx.env.get("PATH") orelse ctx.env.get("Path") orelse return null;
    const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
    const exts: []const []const u8 = if (builtin.os.tag == .windows) &.{ ".exe", ".cmd", ".bat", "" } else &.{""};
    var it = std.mem.tokenizeScalar(u8, path, sep);
    while (it.next()) |dir| for (exts) |ext| {
        const p = std.fmt.allocPrint(ctx.gpa, "{s}{c}{s}{s}", .{ dir, std.fs.path.sep, name, ext }) catch return null;
        if (fsx.isFile(ctx.io, p)) return p;
    };
    return null;
}

/// The first line a program prints for `args`, or null when it can't run.
pub fn firstLine(ctx: Ctx, argv: []const []const u8) ?[]const u8 {
    const r = capture(ctx, argv, null) catch return null;
    if (!r.ok) return null;
    const text = if (r.stdout.len > 0) r.stdout else r.stderr;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    return std.mem.trim(u8, lines.next() orelse "", " \t");
}

/// The project options a build.zig declares (`zig build --help`), so that
/// the CLI passes only those it knows: `-Dstrip`, `-Dfrontend`, ...
pub const BuildOptions = struct {
    help: []const u8,

    pub fn read(ctx: Ctx, root: []const u8) !BuildOptions {
        const r = try capture(ctx, &.{ ctx.zig, "build", "--help" }, root);
        if (!r.ok) {
            std.debug.print("{s}", .{r.stderr});
            return error.BuildFailed;
        }
        return .{ .help = r.stdout };
    }

    pub fn has(o: BuildOptions, comptime name: []const u8) bool {
        return std.mem.indexOf(u8, o.help, "-D" ++ name ++ "=") != null or
            std.mem.indexOf(u8, o.help, "-D" ++ name ++ " ") != null;
    }
};

/// The Zig target of a platform and architecture.
pub fn triple(gpa: std.mem.Allocator, platform: Platform, arch: Arch) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}-{s}{s}", .{ @tagName(arch), switch (platform) {
        .macos => "macos",
        .windows => "windows",
        .linux => "linux",
    }, switch (platform) {
        .macos => "",
        .windows, .linux => "-gnu",
    } });
}

pub const Platform = enum {
    macos,
    windows,
    linux,

    pub fn host() Platform {
        return switch (builtin.os.tag) {
            .macos => .macos,
            .windows => .windows,
            else => .linux,
        };
    }

    pub fn parse(s: []const u8) ?Platform {
        if (std.mem.eql(u8, s, "darwin") or std.mem.eql(u8, s, "mac")) return .macos;
        return std.meta.stringToEnum(Platform, s);
    }
};

pub const Arch = enum {
    x86_64,
    aarch64,
    /// 32-bit x86: Windows and Linux, not macOS.
    x86,

    pub fn host() Arch {
        return switch (builtin.cpu.arch) {
            .aarch64 => .aarch64,
            .x86 => .x86,
            else => .x86_64,
        };
    }

    /// Zig's, Go's and Debian's names.
    pub fn parse(s: []const u8) ?Arch {
        for ([_][]const u8{ "x86_64", "amd64", "x64" }) |n| if (std.mem.eql(u8, s, n)) return .x86_64;
        for ([_][]const u8{ "aarch64", "arm64" }) |n| if (std.mem.eql(u8, s, n)) return .aarch64;
        for ([_][]const u8{ "x86", "386", "i386" }) |n| if (std.mem.eql(u8, s, n)) return .x86;
        return null;
    }

    pub fn debian(a: Arch) []const u8 {
        return switch (a) {
            .x86_64 => "amd64",
            .aarch64 => "arm64",
            .x86 => "i386",
        };
    }

    /// The COFF machine of Windows resources.
    pub fn coffMachine(a: Arch) u16 {
        return switch (a) {
            .x86_64 => 0x8664,
            .aarch64 => 0xAA64,
            .x86 => 0x014c,
        };
    }
};

test triple {
    const gpa = std.testing.allocator;
    const t = try triple(gpa, .windows, .x86_64);
    defer gpa.free(t);
    try std.testing.expectEqualStrings("x86_64-windows-gnu", t);
    const m = try triple(gpa, .macos, .aarch64);
    defer gpa.free(m);
    try std.testing.expectEqualStrings("aarch64-macos", m);
    try std.testing.expectEqual(Arch.aarch64, Arch.parse("arm64").?);
    const w32 = try triple(gpa, .windows, Arch.parse("i386").?);
    defer gpa.free(w32);
    try std.testing.expectEqualStrings("x86-windows-gnu", w32);
    try std.testing.expectEqualStrings("i386", Arch.x86.debian());
    try std.testing.expectEqual(Platform.macos, Platform.parse("darwin").?);
}

test BuildOptions {
    const o: BuildOptions = .{ .help = "Project-Specific Options:\n  -Dstrip=[bool]  Strip\n  -Dfrontend=[string]\n" };
    try std.testing.expect(o.has("strip"));
    try std.testing.expect(o.has("frontend"));
    try std.testing.expect(!o.has("myzig-res"));
}
