//! `myzig build`: the release build of the app (ReleaseSmall unless told
//! otherwise, stripped) and its packages, in `<out>/<platform>-<arch>`:
//!
//!   macOS    <Name>.app (Info.plist, icon.icns), and on a Mac signed (ad
//!            hoc by default) with a .dmg; elsewhere a .zip of the bundle
//!   Windows  <Name>/<Name>.exe with its icon, manifest and version
//!            resources, a .zip of it, installer.nsi, and the installer
//!            when makensis is installed
//!   Linux    <name>/ (the executable, its desktop entry and icon), a
//!            .tar.gz of it and a Debian package
const std = @import("std");
const builtin = @import("builtin");
const fsx = @import("fsx.zig");
const proc = @import("proc.zig");
const config = @import("config.zig");
const appbuild = @import("appbuild.zig");
const archive = @import("archive.zig");
const macos = @import("macos.zig");
const winres = @import("winres.zig");
const nsis = @import("nsis.zig");
const icon = @import("icon.zig");
const linux = @import("linux.zig");
const updates = @import("updates.zig");
const publish = @import("publish.zig");
const Config = config.Config;
const Platform = proc.Platform;
const Arch = proc.Arch;
const Ctx = fsx.Ctx;

pub const Options = struct {
    dir: []const u8 = ".",
    platform: Platform = Platform.host(),
    /// null: this machine's; `universal` on macOS is both.
    arch: ?Arch = null,
    universal: bool = false,
    /// "small" (ReleaseSmall), "fast", "safe" or "debug".
    optimize: []const u8 = "small",
    /// The output directory (default: `out` of the configuration).
    out: []const u8 = "",
    skip_build_command: bool = false,
    skip_dmg: bool = false,
    /// Upload the packages and signed updates where `updates` points.
    upload: bool = false,
};

/// What `myzig build` made, for the summary and tests.
pub const Result = struct {
    dir: []const u8,
    files: []const []const u8,
};

pub fn run(ctx: Ctx, o: Options) !Result {
    const c = try config.load(ctx, o.dir);
    if (o.platform == .macos and macos.profileNeedsIdentity(c)) {
        // Before building anything, as codesign would.
        std.debug.print("error: {s}\n", .{macos.profile_ad_hoc});
        return error.CommandFailed;
    }
    // Before building: where to, and the key, or installed apps could not update.
    if (o.upload) try publish.checkUpload(ctx, c);
    if (c.build_command.len > 0 and !o.skip_build_command) {
        ctx.log("Running {s}", .{c.build_command});
        const sh = proc.shell(c.build_command);
        try proc.check(ctx, &sh, c.root);
    }
    _ = try appbuild.prepareFrontend(ctx, c);
    if (c.icon.len > 0) {
        const src = fsx.read(ctx, try c.path(ctx.gpa, c.icon)) catch |e| {
            std.debug.print("error: icon {s}: {t}\n", .{ c.icon, e });
            return e;
        };
        @import("png.zig").validateIcon(src) catch |e| {
            std.debug.print("error: icon {s} is not a square PNG ({t})\n", .{ c.icon, e });
            return e;
        };
    }
    const declared = try proc.BuildOptions.read(ctx, c.root);
    const arch = o.arch orelse Arch.host();
    const arch_name = if (o.universal) "universal" else @tagName(arch);
    const out_root = try c.path(ctx.gpa, if (o.out.len > 0) o.out else c.out);
    const dir = try ctx.join(&.{ out_root, try ctx.fmt("{t}-{s}", .{ o.platform, arch_name }) });
    fsx.remove(ctx.io, dir);
    try fsx.makeDir(ctx.io, dir);
    const work = try ctx.join(&.{ c.root, ".myzig", "build", try ctx.fmt("{t}-{s}", .{ o.platform, arch_name }) });
    try fsx.makeDir(ctx.io, work);

    var res: ?[]const u8 = null;
    if (o.platform == .windows and declared.has("win32-res")) {
        const p = try ctx.join(&.{ work, "app.res" });
        const png_bytes = if (c.icon.len > 0) try fsx.read(ctx, try c.path(ctx.gpa, c.icon)) else null;
        try fsx.write(ctx.io, p, try winres.resources(ctx.gpa, c, try fsx.fsName(ctx.gpa, c.name), png_bytes));
        res = p;
    } else if (o.platform == .windows) ctx.warn("build.zig declares no -Dwin32-res: the executable gets no icon or version resources", .{});

    const archs: []const Arch = if (o.universal) &.{ .aarch64, .x86_64 } else &.{arch};
    var exes: std.ArrayList([]const u8) = .empty;
    for (archs) |a| {
        ctx.log("Building {s} for {t} {t} ({s})", .{ c.name, o.platform, a, o.optimize });
        try exes.append(ctx.gpa, try appbuild.build(ctx, c, declared, .{
            .optimize = o.optimize,
            .target = try proc.triple(ctx.gpa, o.platform, a),
            .prefix = try ctx.join(&.{ work, @tagName(a) }),
            .strip = !std.mem.eql(u8, o.optimize, "debug"),
            .gui = o.platform == .windows and !std.mem.eql(u8, o.optimize, "debug"),
            .res = res,
            .windows = o.platform == .windows,
        }));
    }
    var exe = exes.items[0];
    if (o.universal) {
        exe = try ctx.join(&.{ work, "universal" });
        const slices = try ctx.gpa.alloc([]const u8, exes.items.len);
        for (exes.items, slices) |e, *s| s.* = try fsx.read(ctx, e);
        try fsx.writeExecutable(ctx.io, exe, try macos.universal(ctx.gpa, slices));
    }
    const resources = try resourcePaths(ctx, c);
    var files: std.ArrayList([]const u8) = .empty;
    switch (o.platform) {
        .macos => try packageMac(ctx, c, o, dir, exe, resources, arch_name, &files),
        .windows => try packageWindows(ctx, c, dir, work, exe, resources, arch_name, &files),
        .linux => try packageLinux(ctx, c, dir, exe, resources, arch, &files),
    }
    if (c.updates != null) {
        // The executable as installed, which the updater replaces.
        const name = try fsx.fsName(ctx.gpa, c.name);
        const installed = switch (o.platform) {
            .macos => try ctx.join(&.{ files.items[0], "Contents", "MacOS", name }),
            .windows => try ctx.join(&.{ dir, name, try ctx.fmt("{s}.exe", .{name}) }),
            .linux => try ctx.join(&.{ dir, c.executable, c.executable }),
        };
        try files.appendSlice(ctx.gpa, try updates.writeUpdate(ctx, c, dir, try ctx.fmt("{t}-{s}", .{ o.platform, arch_name }), installed));
    }
    ctx.log("Built {s} {s}:", .{ c.name, c.version });
    for (files.items) |f| ctx.log("  {s}", .{f});
    if (o.upload) try publish.publish(ctx, c, files.items);
    return .{ .dir = dir, .files = files.items };
}

/// The files shipped beside the app: `resources` of the configuration,
/// and what the resources directory holds but the icon.
fn resourcePaths(ctx: Ctx, c: Config) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (c.resources) |r| {
        const p = try c.path(ctx.gpa, r);
        if (!fsx.exists(ctx.io, p)) {
            std.debug.print("error: resource {s} does not exist\n", .{r});
            return error.MissingResource;
        }
        try list.append(ctx.gpa, p);
    }
    const dir = try ctx.join(&.{ c.root, "resources" });
    const icon_path = if (c.icon.len > 0) try c.path(ctx.gpa, c.icon) else "";
    var d = std.Io.Dir.cwd().openDir(ctx.io, dir, .{ .iterate = true }) catch return list.items;
    defer d.close(ctx.io);
    var it = d.iterate();
    while (try it.next(ctx.io)) |e| {
        const p = try ctx.join(&.{ dir, e.name });
        if (sameFile(p, icon_path)) continue;
        try list.append(ctx.gpa, p);
    }
    return list.items;
}

fn sameFile(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const nx = if (x == '\\') '/' else x;
        const ny = if (y == '\\') '/' else y;
        if (nx != ny) return false;
    }
    return true;
}

fn packageMac(ctx: Ctx, c: Config, o: Options, dir: []const u8, exe: []const u8, resources: []const []const u8, arch: []const u8, files: *std.ArrayList([]const u8)) !void {
    const app = try macos.writeBundle(ctx, c, dir, exe, resources);
    try files.append(ctx.gpa, app);
    if (builtin.os.tag == .macos) {
        try macos.codesign(ctx, c, app);
        if (!o.skip_dmg) try files.append(ctx.gpa, try macos.diskImage(ctx, c, app, dir, arch));
        return;
    }
    // Off a Mac: the bundle zipped, keeping its executable's mode.
    var entries: std.ArrayList(archive.Entry) = .empty;
    const base = std.fs.path.basename(app);
    try entries.append(ctx.gpa, .{ .path = base, .kind = .dir, .mode = 0o755 });
    const name = try fsx.fsName(ctx.gpa, c.name);
    try archive.collect(ctx, &entries, app, base, &.{try ctx.fmt("Contents/MacOS/{s}", .{name})});
    const zip = try ctx.join(&.{ dir, try ctx.fmt("{s}-{s}-macos-{s}.zip", .{ name, c.version, arch }) });
    try fsx.write(ctx.io, zip, try archive.zip(ctx.gpa, entries.items, fsx.epoch(ctx)));
    try files.append(ctx.gpa, zip);
    ctx.warn("made no .dmg: disk images are made on macOS (hdiutil)", .{});
}

fn packageWindows(ctx: Ctx, c: Config, dir: []const u8, work: []const u8, exe: []const u8, resources: []const []const u8, arch: []const u8, files: *std.ArrayList([]const u8)) !void {
    const name = try fsx.fsName(ctx.gpa, c.name);
    const stage = try ctx.join(&.{ dir, name });
    const exe_name = try ctx.fmt("{s}.exe", .{name});
    try fsx.copyFile(ctx.io, exe, try ctx.join(&.{ stage, exe_name }));
    var installed: std.ArrayList([]const u8) = .empty;
    var is_dir: std.ArrayList(bool) = .empty;
    try installed.append(ctx.gpa, try ctx.join(&.{ stage, exe_name }));
    try is_dir.append(ctx.gpa, false);
    for (resources) |r| {
        const to = try ctx.join(&.{ stage, std.fs.path.basename(r) });
        try fsx.copyTree(ctx, r, to);
        try installed.append(ctx.gpa, to);
        try is_dir.append(ctx.gpa, fsx.isDir(ctx.io, r));
    }
    try files.append(ctx.gpa, stage);
    var entries: std.ArrayList(archive.Entry) = .empty;
    try entries.append(ctx.gpa, .{ .path = name, .kind = .dir, .mode = 0o755 });
    try archive.collect(ctx, &entries, stage, name, &.{exe_name});
    const zip = try ctx.join(&.{ dir, try ctx.fmt("{s}-{s}-windows-{s}.zip", .{ name, c.version, arch }) });
    try fsx.write(ctx.io, zip, try archive.zip(ctx.gpa, entries.items, fsx.epoch(ctx)));
    try files.append(ctx.gpa, zip);

    if (!c.windows.installer) return;
    var ico: []const u8 = "";
    if (c.icon.len > 0) {
        ico = try ctx.join(&.{ work, "installer.ico" });
        try fsx.write(ctx.io, ico, try icon.ico(ctx.gpa, try fsx.read(ctx, try c.path(ctx.gpa, c.icon))));
    }
    const setup = try ctx.join(&.{ dir, try nsis.installerName(ctx.gpa, name, try fsx.fsName(ctx.gpa, c.version), arch) });
    const script = try nsis.script(ctx.gpa, c, name, .{ .paths = installed.items, .exe = exe_name, .out = setup, .ico = ico }, is_dir.items);
    const nsi = try ctx.join(&.{ work, "installer.nsi" });
    try fsx.write(ctx.io, nsi, script);
    const makensis = makensisPath(ctx) orelse {
        ctx.log("Wrote {s}; install NSIS (makensis) to make the installer", .{nsi});
        return;
    };
    ctx.log("Making {s}", .{std.fs.path.basename(setup)});
    try proc.check(ctx, &.{ makensis, "-V2", nsi }, null);
    try files.append(ctx.gpa, setup);
}

/// The NSIS compiler: on the PATH, or where its installer puts it.
pub fn makensisPath(ctx: Ctx) ?[]const u8 {
    if (proc.which(ctx, "makensis")) |p| return p;
    if (builtin.os.tag == .windows) for ([_][]const u8{ "ProgramFiles(x86)", "ProgramFiles" }) |v| {
        const base = ctx.env.get(v) orelse continue;
        const p = ctx.join(&.{ base, "NSIS", "makensis.exe" }) catch continue;
        if (fsx.isFile(ctx.io, p)) return p;
    };
    return null;
}

fn packageLinux(ctx: Ctx, c: Config, dir: []const u8, exe: []const u8, resources: []const []const u8, arch: Arch, files: *std.ArrayList([]const u8)) !void {
    const name = c.executable;
    const stage = try ctx.join(&.{ dir, name });
    try fsx.writeExecutable(ctx.io, try ctx.join(&.{ stage, name }), try fsx.read(ctx, exe));
    for (resources) |r| try fsx.copyTree(ctx, r, try ctx.join(&.{ stage, std.fs.path.basename(r) }));
    // The app's files, for the package (before the entry and icon, which
    // the package installs where desktops look for them).
    var app: std.ArrayList(archive.Entry) = .empty;
    try archive.collect(ctx, &app, stage, "", &.{name});
    const icon_png = if (c.icon.len > 0) try fsx.read(ctx, try c.path(ctx.gpa, c.icon)) else null;
    // The tarball runs from where it is unpacked: its entry runs the app
    // beside it, as install scripts rewrite it.
    try fsx.write(ctx.io, try ctx.join(&.{ stage, try ctx.fmt("{s}.desktop", .{name}) }), try linux.desktopEntry(ctx.gpa, c, try ctx.fmt("./{s}", .{name}), name));
    if (icon_png) |p| {
        const src = try @import("png.zig").Source.init(ctx.gpa, p);
        try fsx.write(ctx.io, try ctx.join(&.{ stage, try ctx.fmt("{s}.png", .{name}) }), try src.png(ctx.gpa, 512));
    }
    try files.append(ctx.gpa, stage);
    var entries: std.ArrayList(archive.Entry) = .empty;
    try entries.append(ctx.gpa, .{ .path = name, .kind = .dir, .mode = 0o755 });
    try archive.collect(ctx, &entries, stage, name, &.{name});
    const tgz = try ctx.join(&.{ dir, try ctx.fmt("{s}-{s}-linux-{t}.tar.gz", .{ name, c.version, arch }) });
    try fsx.write(ctx.io, tgz, try archive.tarGz(ctx.gpa, entries.items, .{ .mtime = fsx.epoch(ctx), .owner = "" }));
    try files.append(ctx.gpa, tgz);
    const bytes, const deb_name = try linux.deb(ctx.gpa, c, arch, name, app.items, icon_png, fsx.epoch(ctx));
    const deb = try ctx.join(&.{ dir, deb_name });
    try fsx.write(ctx.io, deb, bytes);
    try files.append(ctx.gpa, deb);
}
