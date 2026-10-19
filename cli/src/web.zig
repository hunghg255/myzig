//! `myzig build --platform web`: the app of native UI built for browsers
//! (wasm32-wasi, ReleaseSmall unless told otherwise) and laid out in
//! `<out>/web` as a static site to serve from anywhere:
//!
//!   index.html, host.js, host_gl.js, host_wasi.js   the page and its host
//!   app.wasm                                        the app
//!   fonts/fonts.json, fonts/*.ttf                   the fonts it draws text with
//!
//! The fonts are the app's `fonts/` directory when it has one, else the
//! system's (see `site.zig` in myzig: check their licenses before
//! publishing). The app's build.zig sets `exe.rdynamic = true` for wasi:
//! the host calls the functions myzig exports.
const std = @import("std");
const fsx = @import("fsx.zig");
const proc = @import("proc.zig");
const config = @import("config.zig");
const appbuild = @import("appbuild.zig");
const site = @import("myzig_web_site");
const Ctx = fsx.Ctx;
const Options = @import("package.zig").Options;
const Result = @import("package.zig").Result;

pub const target = "wasm32-wasi";

pub fn run(ctx: Ctx, o: Options) !Result {
    const c = try config.load(ctx, o.dir);
    if (c.build_command.len > 0 and !o.skip_build_command) {
        ctx.log("Running {s}", .{c.build_command});
        const sh = proc.shell(c.build_command);
        try proc.check(ctx, &sh, c.root);
    }
    const declared = try proc.BuildOptions.read(ctx, c.root);
    const out_root = try c.path(ctx.gpa, if (o.out.len > 0) o.out else c.out);
    const dir = try ctx.join(&.{ out_root, "web" });
    fsx.remove(ctx.io, dir);
    try fsx.makeDir(ctx.io, dir);
    const prefix = try ctx.join(&.{ c.root, ".myzig", "build", "web" });
    try fsx.makeDir(ctx.io, prefix);

    ctx.log("Building {s} for browsers ({s})", .{ c.name, o.optimize });
    const argv = try appbuild.args(ctx, c, declared, .{
        .optimize = o.optimize,
        .target = target,
        .prefix = prefix,
        .strip = !std.mem.eql(u8, o.optimize, "debug"),
        .windows = false,
    });
    proc.check(ctx, argv, c.root) catch return error.BuildFailed;
    const wasm = try ctx.join(&.{ prefix, "bin", try ctx.fmt("{s}.wasm", .{c.executable}) });
    if (!fsx.isFile(ctx.io, wasm)) {
        std.debug.print("error: zig build installed no {s}: set .executable in myzig.zon to the name of the app's executable\n", .{wasm});
        return error.BuildFailed;
    }

    var files: std.ArrayList([]const u8) = .empty;
    for (site.files) |f| try put(ctx, dir, f.name, f.data, &files);
    try fsx.copyFile(ctx.io, wasm, try ctx.join(&.{ dir, "app.wasm" }));
    try files.append(ctx.gpa, try ctx.join(&.{ dir, "app.wasm" }));
    const fonts = try bundleFonts(ctx, c, try ctx.join(&.{ dir, "fonts" }));
    if (fonts.len == 0) ctx.warn("no fonts to bundle (put .ttf files in fonts/): text will not draw", .{});
    try put(ctx, dir, "fonts/fonts.json", try site.fontList(ctx.gpa, fonts), &files);
    for (fonts) |f| try files.append(ctx.gpa, try ctx.join(&.{ dir, "fonts", f }));

    ctx.log("Built {s} {s} for browsers (serve the directory over HTTP):", .{ c.name, c.version });
    for (files.items) |f| ctx.log("  {s}", .{f});
    return .{ .dir = dir, .files = files.items };
}

fn put(ctx: Ctx, dir: []const u8, name: []const u8, data: []const u8, files: *std.ArrayList([]const u8)) !void {
    const p = try ctx.join(&.{ dir, name });
    if (std.fs.path.dirname(p)) |d| try fsx.makeDir(ctx.io, d);
    try fsx.write(ctx.io, p, data);
    try files.append(ctx.gpa, p);
}

/// Copies the app's fonts (its `fonts/`), else the system's, into `to`;
/// their names.
fn bundleFonts(ctx: Ctx, c: config.Config, to: []const u8) ![]const []const u8 {
    try fsx.makeDir(ctx.io, to);
    var names: std.ArrayList([]const u8) = .empty;
    const own = try ctx.join(&.{ c.root, "fonts" });
    if (std.Io.Dir.cwd().openDir(ctx.io, own, .{ .iterate = true })) |d_| {
        var d = d_;
        defer d.close(ctx.io);
        var it = d.iterate();
        while (try it.next(ctx.io)) |e| {
            if (e.kind != .file or !site.isFont(e.name)) continue;
            const name = try ctx.gpa.dupe(u8, e.name);
            try fsx.copyFile(ctx.io, try ctx.join(&.{ own, name }), try ctx.join(&.{ to, name }));
            try names.append(ctx.gpa, name);
        }
    } else |_| {}
    if (names.items.len > 0) {
        std.mem.sort([]const u8, names.items, {}, lessThan);
        return names.items;
    }
    for (site.system_fonts) |set| {
        for (set) |p| if (fsx.isFile(ctx.io, p)) {
            const name = std.fs.path.basename(p);
            try fsx.copyFile(ctx.io, p, try ctx.join(&.{ to, name }));
            try names.append(ctx.gpa, name);
        };
        if (names.items.len > 0) {
            ctx.warn("bundling the system's fonts ({s}...): check their license before publishing, or put fonts in fonts/", .{names.items[0]});
            break;
        }
    }
    return names.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
