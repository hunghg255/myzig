//! myzig, the command line tool of myzig apps (after mygo's cmd/mygo): it
//! makes apps, runs them as you edit them, writes their TypeScript client,
//! and builds their releases and packages.
const std = @import("std");
const build_options = @import("build_options");
const fsx = @import("fsx.zig");
const config = @import("config.zig");
const proc = @import("proc.zig");
const Ctx = fsx.Ctx;

pub const version = build_options.version;

const usage =
    \\myzig is the tool for myzig desktop apps.
    \\
    \\Usage:
    \\
    \\  myzig <command> [arguments]
    \\
    \\Commands:
    \\
    \\  init <dir>      create an app (native UI, or a web frontend with --template web)
    \\  dev [dir]       run the app, rebuilding and restarting it as its files change
    \\  build [dir]     build the release and its packages (.app/.dmg, .exe/.zip, .deb/.tar.gz)
    \\  generate [dir]  write the TypeScript client of the app's bound services
    \\  icon <png>      render a PNG as .icns, .ico and the sizes platforms want
    \\  keygen          create the key pair that signs updates
    \\  doctor          check that this machine can build and run myzig apps
    \\  version         print the version
    \\
    \\Run "myzig <command> --help" for a command's flags. Apps are configured
    \\in myzig.zon (or myzig.json); ZIG names the Zig to build them with.
    \\
;

const Command = struct {
    name: []const u8,
    args: []const u8,
    summary: []const u8,
    flags: []const u8 = "",
};

const commands = [_]Command{
    .{ .name = "init", .args = "<dir>", .summary = "Creates an app in a new or empty directory: build.zig, build.zig.zon depending on myzig,\nsrc/main.zig, myzig.zon and an icon. The web template adds frontend/ and writes its client.", .flags =
    \\  --template native|web  native UI drawn by myzig (default), or a web page calling Zig
    \\  --name NAME            the app's name (default: the directory's)
    \\  --myzig PATH|URL       a checkout of myzig (a path dependency), or what `zig fetch` fetches
    \\                         (default: MYZIG_ROOT, else the myzig repository)
    \\  --skip-generate        don't build the web template to write its client
    },
    .{ .name = "dev", .args = "[dir] [-- app arguments]", .summary = "Builds the app, writes its client, runs it, and rebuilds and restarts it when its files\nchange (watched by the system: nothing polls). With dev_command and dev_url, runs the dev\nserver first and points the app at it (MYZIG_DEV_URL). Quitting the app ends it.", .flags =
    \\  --skip-dev-command     don't run dev_command (its server already runs)
    },
    .{ .name = "build", .args = "[dir]", .summary = "Builds the release (stripped) and packages it in <out>/<platform>-<arch>: a .app (and a .dmg\non a Mac), a Windows .exe with its icon and version resources and a .zip (and an installer\nwith NSIS), or a Linux directory, .tar.gz and .deb.", .flags =
    \\  --platform macos|windows|linux|web  the system to build for (default: this one); web: a
    \\                                  static site for browsers in <out>/web (native UI only)
    \\  --arch x86_64|aarch64|universal  the architecture (default: this one; universal: macOS, both)
    \\  --optimize small|fast|safe      ReleaseSmall (default), ReleaseFast or ReleaseSafe
    \\  --out DIR                       the output directory (default: out of myzig.zon, dist)
    \\  --skip-build-command            don't run build_command
    \\  --skip-dmg                      don't make the macOS disk image
    \\  --upload                        upload the packages and signed updates where updates points
    \\                                  (updates.s3, else a draft release of updates.github)
    },
    .{ .name = "keygen", .args = "[--out DIR] [--force]", .summary = "Creates the Ed25519 key pair that signs updates: myzig-update.key, the secret, and\nmyzig-update.pub. Put the contents of myzig-update.pub in updates.public_key of myzig.zon,\nand keep myzig-update.key out of the repository (a password manager, the\nMYZIG_UPDATER_PRIVATE_KEY secret of CI): installed apps only accept updates signed with it.", .flags =
    \\  --out DIR    where to write the keys (default: <config>/myzig/update-keys)
    \\  --force      replace keys that are there
    },
    .{ .name = "generate", .args = "[dir]", .summary = "Builds the app and runs it with --myzig-generate to write myzig.js and myzig.d.ts, the\nclient of its bound services and events, into its frontend directory." },
    .{ .name = "icon", .args = "<png> [--out DIR]", .summary = "Renders a square PNG as icon.icns, icon.ico and PNGs of 16 to 1024 pixels in DIR\n(default: the PNG's directory). `myzig icon --new FILE` writes myzig's default icon.", .flags =
    \\  --out DIR    where to write them
    \\  --new FILE   write the default icon to FILE instead
    },
    .{ .name = "doctor", .args = "", .summary = "Checks Zig, the platform's SDK and libraries (macOS SDK; GTK 3 and WebKitGTK; the WebView2\nRuntime) and the tools of optional features." },
    .{ .name = "version", .args = "", .summary = "Prints the version of the CLI." },
};

fn help(io: std.Io, cmd: Command) void {
    fsx.out(io, "Usage: myzig {s} {s}\n\n{s}\n", .{ cmd.name, cmd.args, cmd.summary });
    if (cmd.flags.len > 0) fsx.out(io, "\nFlags:\n{s}\n", .{cmd.flags});
}

/// The arguments of a command: flags (`--name value`, `--name=value`)
/// and the rest.
const Args = struct {
    list: []const []const u8,
    i: usize = 0,
    /// After `--`: arguments for the app.
    rest: []const []const u8 = &.{},

    fn next(a: *Args) ?[]const u8 {
        if (a.i >= a.list.len) return null;
        if (std.mem.eql(u8, a.list[a.i], "--")) {
            a.rest = a.list[a.i + 1 ..];
            a.i = a.list.len;
            return null;
        }
        defer a.i += 1;
        return a.list[a.i];
    }

    /// The value of `--flag` when `arg` is it.
    fn value(a: *Args, arg: []const u8, comptime flag: []const u8) !?[]const u8 {
        if (std.mem.startsWith(u8, arg, flag ++ "=")) return arg[flag.len + 1 ..];
        if (!std.mem.eql(u8, arg, flag)) return null;
        if (a.i >= a.list.len) {
            std.debug.print("error: {s} needs a value\n", .{flag});
            return error.Usage;
        }
        defer a.i += 1;
        return a.list[a.i];
    }
};

fn unknown(arg: []const u8) error{Usage} {
    std.debug.print("error: unknown flag or value {s}\n", .{arg});
    return error.Usage;
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    var ctx: Ctx = .{ .gpa = arena, .io = init.io, .env = init.environ_map };
    if (init.environ_map.get("ZIG")) |z| ctx.zig = z;
    if (argv.len < 2) {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }
    const name = argv[1];
    if (isHelp(name) or std.mem.eql(u8, name, "help")) return fsx.out(init.io, "{s}", .{usage});
    if (std.mem.eql(u8, name, "version") or std.mem.eql(u8, name, "--version") or std.mem.eql(u8, name, "-v"))
        return fsx.out(init.io, "myzig {s}\n", .{version});
    const cmd = for (commands) |c| {
        if (std.mem.eql(u8, c.name, name)) break c;
    } else {
        std.debug.print("error: unknown command {s}\n\n{s}", .{ name, usage });
        std.process.exit(2);
    };
    var args: Args = .{ .list = argv[2..] };
    dispatch(ctx, cmd, &args) catch |e| {
        switch (e) {
            error.Help => return,
            error.Usage => help(init.io, cmd),
            error.ConfigInvalid => std.debug.print("error: {s}\n", .{config.message}),
            // Already told.
            error.BuildFailed, error.CommandFailed, error.GenerateFailed, error.ChecksFailed, error.NotEmpty, error.NotMyzig, error.NoFrontend, error.MissingResource => {},
            else => std.debug.print("error: {t}\n", .{e}),
        }
        std.process.exit(1);
    };
}

fn dispatch(ctx: Ctx, cmd: Command, args: *Args) !void {
    var positional: std.ArrayList([]const u8) = .empty;
    if (std.mem.eql(u8, cmd.name, "init")) {
        var o: @import("init.zig").Options = .{ .dir = "" };
        while (args.next()) |a| {
            if (isHelp(a)) return helpOut(ctx, cmd);
            if (try args.value(a, "--template")) |t| {
                o.template = std.meta.stringToEnum(@import("templates.zig").Template, t) orelse return unknown(t);
            } else if (try args.value(a, "--name")) |v| {
                o.name = v;
            } else if (try args.value(a, "--myzig")) |v| {
                o.myzig = v;
            } else if (std.mem.eql(u8, a, "--skip-generate")) {
                o.skip_generate = true;
            } else if (std.mem.startsWith(u8, a, "-")) return unknown(a) else try positional.append(ctx.gpa, a);
        }
        if (positional.items.len != 1) return error.Usage;
        o.dir = positional.items[0];
        return @import("init.zig").run(ctx, o);
    }
    if (std.mem.eql(u8, cmd.name, "dev")) {
        var o: @import("dev.zig").Options = .{};
        while (args.next()) |a| {
            if (isHelp(a)) return helpOut(ctx, cmd);
            if (std.mem.eql(u8, a, "--skip-dev-command")) {
                o.skip_dev_command = true;
            } else if (std.mem.startsWith(u8, a, "-")) return unknown(a) else try positional.append(ctx.gpa, a);
        }
        o.app_args = args.rest;
        if (positional.items.len > 1) return error.Usage;
        if (positional.items.len == 1) o.dir = positional.items[0];
        return @import("dev.zig").run(ctx, o);
    }
    if (std.mem.eql(u8, cmd.name, "build")) {
        var o: @import("package.zig").Options = .{};
        var web = false;
        while (args.next()) |a| {
            if (isHelp(a)) return helpOut(ctx, cmd);
            if (try args.value(a, "--platform")) |v| {
                if (std.mem.eql(u8, v, "web")) {
                    web = true;
                    continue;
                }
                o.platform = proc.Platform.parse(v) orelse return unknown(v);
            } else if (try args.value(a, "--arch")) |v| {
                if (std.mem.eql(u8, v, "universal")) o.universal = true else o.arch = proc.Arch.parse(v) orelse return unknown(v);
            } else if (try args.value(a, "--optimize")) |v| {
                o.optimize = optimizeMode(v) orelse return unknown(v);
            } else if (try args.value(a, "--out")) |v| {
                o.out = v;
            } else if (std.mem.eql(u8, a, "--skip-build-command")) {
                o.skip_build_command = true;
            } else if (std.mem.eql(u8, a, "--skip-dmg")) {
                o.skip_dmg = true;
            } else if (std.mem.eql(u8, a, "--upload")) {
                o.upload = true;
            } else if (std.mem.startsWith(u8, a, "-")) return unknown(a) else try positional.append(ctx.gpa, a);
        }
        if (o.universal and o.platform != .macos) {
            std.debug.print("error: --arch universal is for macOS\n", .{});
            return error.Usage;
        }
        if (positional.items.len > 1) return error.Usage;
        if (positional.items.len == 1) o.dir = positional.items[0];
        if (web) {
            _ = try @import("web.zig").run(ctx, o);
            return;
        }
        _ = try @import("package.zig").run(ctx, o);
        return;
    }
    if (std.mem.eql(u8, cmd.name, "generate")) {
        while (args.next()) |a| {
            if (isHelp(a)) return helpOut(ctx, cmd);
            if (std.mem.startsWith(u8, a, "-")) return unknown(a) else try positional.append(ctx.gpa, a);
        }
        if (positional.items.len > 1) return error.Usage;
        const c = try config.load(ctx, if (positional.items.len == 1) positional.items[0] else ".");
        return @import("appbuild.zig").generate(ctx, c);
    }
    if (std.mem.eql(u8, cmd.name, "icon")) {
        var out_dir: []const u8 = "";
        var new: []const u8 = "";
        while (args.next()) |a| {
            if (isHelp(a)) return helpOut(ctx, cmd);
            if (try args.value(a, "--out")) |v| {
                out_dir = v;
            } else if (try args.value(a, "--new")) |v| {
                new = v;
            } else if (std.mem.startsWith(u8, a, "-")) return unknown(a) else try positional.append(ctx.gpa, a);
        }
        if (new.len > 0) {
            try fsx.write(ctx.io, new, try @import("templates.zig").defaultIcon(ctx.gpa));
            return ctx.log("Wrote {s}", .{new});
        }
        if (positional.items.len != 1) return error.Usage;
        return icons(ctx, positional.items[0], out_dir);
    }
    if (std.mem.eql(u8, cmd.name, "keygen")) {
        var out_dir: []const u8 = "";
        var force = false;
        while (args.next()) |a| {
            if (isHelp(a)) return helpOut(ctx, cmd);
            if (try args.value(a, "--out")) |v| {
                out_dir = v;
            } else if (std.mem.eql(u8, a, "--force")) {
                force = true;
            } else return unknown(a);
        }
        return @import("updates.zig").keygen(ctx, out_dir, force);
    }
    if (std.mem.eql(u8, cmd.name, "doctor")) {
        while (args.next()) |a| if (isHelp(a)) return helpOut(ctx, cmd) else return unknown(a);
        return @import("doctor.zig").run(ctx);
    }
    unreachable;
}

fn optimizeMode(v: []const u8) ?[]const u8 {
    const modes = [_][2][]const u8{ .{ "ReleaseSmall", "small" }, .{ "ReleaseFast", "fast" }, .{ "ReleaseSafe", "safe" }, .{ "Debug", "debug" } };
    for (modes) |m| if (std.mem.eql(u8, v, m[0]) or std.mem.eql(u8, v, m[1])) return m[1];
    return null;
}

fn helpOut(ctx: Ctx, cmd: Command) error{Help} {
    help(ctx.io, cmd);
    return error.Help;
}

/// `myzig icon`: the icon's files beside it, or in `out_dir`.
fn icons(ctx: Ctx, src_path: []const u8, out_dir: []const u8) !void {
    const icon = @import("icon.zig");
    const png = @import("png.zig");
    const src = try fsx.read(ctx, src_path);
    png.validateIcon(src) catch |e| {
        std.debug.print("error: {s} is not a square PNG ({t})\n", .{ src_path, e });
        return error.CommandFailed;
    };
    const dir = if (out_dir.len > 0) out_dir else std.fs.path.dirname(src_path) orelse ".";
    try fsx.write(ctx.io, try ctx.join(&.{ dir, "icon.icns" }), try icon.icns(ctx.gpa, src));
    try fsx.write(ctx.io, try ctx.join(&.{ dir, "icon.ico" }), try icon.ico(ctx.gpa, src));
    const s = try png.Source.init(ctx.gpa, src);
    for ([_]u32{ 16, 32, 48, 64, 128, 256, 512, 1024 }) |n|
        try fsx.write(ctx.io, try ctx.join(&.{ dir, try ctx.fmt("icon-{d}.png", .{n}) }), try s.png(ctx.gpa, n));
    ctx.log("Wrote icon.icns, icon.ico and icon-16.png to icon-1024.png in {s}", .{dir});
}

test {
    _ = @import("fsx.zig");
    _ = @import("zon.zig");
    _ = @import("config.zig");
    _ = @import("compress.zig");
    _ = @import("png.zig");
    _ = @import("icon.zig");
    _ = @import("plist.zig");
    _ = @import("dsstore.zig");
    _ = @import("macos.zig");
    _ = @import("winres.zig");
    _ = @import("archive.zig");
    _ = @import("proc.zig");
    _ = @import("linux.zig");
    _ = @import("nsis.zig");
    _ = @import("templates.zig");
    _ = @import("assets.zig");
    _ = @import("appbuild.zig");
    _ = @import("init.zig");
    _ = @import("watch.zig");
    _ = @import("child.zig");
    _ = @import("dev.zig");
    _ = @import("package.zig");
    _ = @import("doctor.zig");
    _ = @import("updates.zig");
    _ = @import("s3.zig");
    _ = @import("publish.zig");
}

test Args {
    var a: Args = .{ .list = &.{ "--name", "X", "--template=web", "dir", "--", "--app-flag" } };
    try std.testing.expectEqualStrings("X", (try a.value(a.next().?, "--name")).?);
    try std.testing.expectEqualStrings("web", (try a.value(a.next().?, "--template")).?);
    try std.testing.expectEqualStrings("dir", a.next().?);
    try std.testing.expect(a.next() == null);
    try std.testing.expectEqualStrings("--app-flag", a.rest[0]);
}

test optimizeMode {
    try std.testing.expectEqualStrings("fast", optimizeMode("fast").?);
    try std.testing.expectEqualStrings("small", optimizeMode("ReleaseSmall").?);
    try std.testing.expect(optimizeMode("turbo") == null);
}
