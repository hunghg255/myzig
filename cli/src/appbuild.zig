//! Building an app with `zig build`: into a prefix of the CLI's own, for a
//! target, with the options its build.zig declares; and the generated
//! client, which the app writes itself (`--myzig-generate=<dir>`).
const std = @import("std");
const builtin = @import("builtin");
const fsx = @import("fsx.zig");
const proc = @import("proc.zig");
const assets = @import("assets.zig");
const Config = @import("config.zig").Config;
const Ctx = fsx.Ctx;

pub const Options = struct {
    /// "debug", or a release: "small", "fast" or "safe" (`--release=`).
    optimize: []const u8 = "debug",
    /// A Windows app without a console (`-Dwindows-gui`).
    gui: bool = false,
    /// A Zig target triple, or null for this machine.
    target: ?[]const u8 = null,
    /// Where `zig build` installs (its --prefix), absolute.
    prefix: []const u8,
    strip: bool = false,
    /// A .res file for Windows (`-Dwin32-res`).
    res: ?[]const u8 = null,
    /// Whether the executable is a Windows one (.exe).
    windows: bool = builtin.os.tag == .windows,
};

/// Lists the frontend's files in its assets module, when the app embeds
/// one. Returns whether the module changed.
pub fn prepareFrontend(ctx: Ctx, c: Config) !bool {
    if (c.frontend_dist.len == 0) return false;
    const dist = try c.path(ctx.gpa, c.frontend_dist);
    if (!fsx.isDir(ctx.io, dist)) return false;
    return assets.write(ctx, dist);
}

/// The executable that `zig build --prefix prefix` installs.
pub fn exePath(ctx: Ctx, c: Config, prefix: []const u8, windows: bool) ![]u8 {
    return ctx.join(&.{ prefix, "bin", try ctx.fmt("{s}{s}", .{ c.executable, if (windows) ".exe" else "" }) });
}

/// The arguments of `zig build` for `o`, with only the options the app's
/// build.zig declares.
pub fn args(ctx: Ctx, c: Config, declared: proc.BuildOptions, o: Options) ![]const []const u8 {
    var a: std.ArrayList([]const u8) = .empty;
    try a.appendSlice(ctx.gpa, &.{ ctx.zig, "build", "--prefix", o.prefix });
    if (!std.mem.eql(u8, o.optimize, "debug")) try a.append(ctx.gpa, try ctx.fmt("--release={s}", .{o.optimize}));
    if (o.gui and declared.has("windows-gui")) try a.append(ctx.gpa, "-Dwindows-gui=true");
    if (o.target) |t| try a.append(ctx.gpa, try ctx.fmt("-Dtarget={s}", .{t}));
    if (o.strip and declared.has("strip")) try a.append(ctx.gpa, "-Dstrip=true");
    if (o.res) |r| if (declared.has("win32-res")) try a.append(ctx.gpa, try ctx.fmt("-Dwin32-res={s}", .{r}));
    if (c.frontend_dist.len > 0 and declared.has("frontend")) try a.append(ctx.gpa, try ctx.fmt("-Dfrontend={s}", .{c.frontend_dist}));
    return a.items;
}

/// Builds the app; returns its executable, or error.BuildFailed (Zig's
/// errors are printed).
pub fn build(ctx: Ctx, c: Config, declared: proc.BuildOptions, o: Options) ![]u8 {
    const argv = try args(ctx, c, declared, o);
    proc.check(ctx, argv, c.root) catch return error.BuildFailed;
    const exe = try exePath(ctx, c, o.prefix, o.windows);
    if (!fsx.isFile(ctx.io, exe)) {
        std.debug.print("error: zig build installed no {s}: set .executable in myzig.zon to the name of the app's executable\n", .{exe});
        return error.BuildFailed;
    }
    return exe;
}

/// Where the generated client goes: the frontend's sources.
pub fn clientDir(ctx: Ctx, c: Config) !?[]u8 {
    if (c.frontend.len == 0) return null;
    return try c.path(ctx.gpa, c.frontend);
}

/// Runs the built app to write the client into `dir`; nothing is shown.
pub fn writeClient(ctx: Ctx, exe: []const u8, dir: []const u8) !void {
    try fsx.makeDir(ctx.io, dir);
    const flag = try ctx.fmt("--myzig-generate={s}", .{dir});
    const r = proc.capture(ctx, &.{ exe, flag }, null) catch |e| {
        std.debug.print("error: could not run {s}: {t}\n", .{ exe, e });
        return error.GenerateFailed;
    };
    if (!r.ok) {
        std.debug.print("{s}{s}error: {s} {s} failed\n", .{ r.stdout, r.stderr, exe, flag });
        return error.GenerateFailed;
    }
    const dts = try ctx.join(&.{ dir, "myzig.d.ts" });
    if (!fsx.isFile(ctx.io, dts)) {
        std.debug.print("error: the app wrote no {s}: does it call app.run()?\n", .{dts});
        return error.GenerateFailed;
    }
}

/// `myzig generate`: builds the app for this machine and writes its client.
pub fn generate(ctx: Ctx, c: Config) !void {
    const dir = (try clientDir(ctx, c)) orelse {
        std.debug.print("error: the app has no frontend to write a client for: set .frontend in myzig.zon\n", .{});
        return error.NoFrontend;
    };
    _ = try prepareFrontend(ctx, c);
    const declared = try proc.BuildOptions.read(ctx, c.root);
    const prefix = try ctx.join(&.{ c.root, ".myzig", "generate" });
    const exe = try build(ctx, c, declared, .{ .prefix = prefix });
    try writeClient(ctx, exe, dir);
    ctx.log("Wrote {s}{c}myzig.js and myzig.d.ts", .{ dir, std.fs.path.sep });
}

test args {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: Ctx = .{ .gpa = arena.allocator(), .io = std.testing.io, .env = undefined };
    const c: Config = .{ .root = "/a", .frontend_dist = "frontend/dist" };
    const declared: proc.BuildOptions = .{ .help = "  -Dstrip=[bool]\n  -Dfrontend=[string]\n" };
    const a = try args(ctx, c, declared, .{ .optimize = "small", .target = "x86_64-linux-gnu", .prefix = "/p", .strip = true, .res = "/r.res", .gui = true });
    const want = [_][]const u8{ "zig", "build", "--prefix", "/p", "--release=small", "-Dtarget=x86_64-linux-gnu", "-Dstrip=true", "-Dfrontend=frontend/dist" };
    try std.testing.expectEqual(want.len, a.len);
    for (want, a) |x, y| try std.testing.expectEqualStrings(x, y);
}
