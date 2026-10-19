//! Builds an app of native UI for browsers: compiled for wasm32-wasi (no
//! libc: Zig's standard library talks WASI, which `host_wasi.js` answers),
//! and laid out as a static site to serve from anywhere:
//!
//!     index.html  host.js  host_gl.js  host_wasi.js  app.wasm
//!     fonts/fonts.json  fonts/*.ttf
//!
//! Text is myzig's own TrueType, drawn from the fonts the site bundles:
//! the host fetches them into the WASI file system (/usr/share/fonts),
//! where the font database finds them. They come from `fonts` (a
//! directory of .ttf/.ttc files), else from the families `site.zig` lists
//! found in the system's font folders (check their licenses before
//! publishing).
//!
//! From build.zig:
//!
//!     const web = @import("src/web/build.zig");
//!     const app = web.addSite(b, .{ .name = "counter", .main = b.path("examples/counter/main.zig"), .myzig = b.path("src") });
//!     b.step("web", "...").dependOn(app.step);
const std = @import("std");
const site = @import("site.zig");

pub const Options = struct {
    name: []const u8,
    /// The app's main file.
    main: std.Build.LazyPath,
    /// myzig's `src` directory.
    myzig: std.Build.LazyPath,
    optimize: std.builtin.OptimizeMode = .ReleaseSmall,
    /// A directory of fonts to bundle (.ttf, .ttc).
    fonts: ?[]const u8 = null,
    /// Where the site goes, under the install prefix.
    install_subdir: ?[]const u8 = null,
};

pub const Site = struct {
    /// Installs the site (`zig-out/web/<name>` by default).
    step: *std.Build.Step,
    /// The site's directory, before it is installed.
    dir: std.Build.LazyPath,
    wasm: *std.Build.Step.Compile,
};

pub fn addSite(b: *std.Build, opts: Options) Site {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const options = b.addOptions();
    options.addOption(bool, "portable", true);
    const myzig = b.createModule(.{
        .root_source_file = opts.myzig.path(b, "myzig.zig"),
        .target = target,
        .optimize = opts.optimize,
    });
    myzig.addOptions("build_options", options);
    const exe = b.addExecutable(.{
        .name = opts.name,
        .root_module = b.createModule(.{
            .root_source_file = opts.main,
            .target = target,
            .optimize = opts.optimize,
            .imports = &.{.{ .name = "myzig", .module = myzig }},
        }),
    });
    // The host calls the functions `web/exports.zig` exports.
    exe.rdynamic = true;
    exe.stack_size = 8 << 20;

    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(exe.getEmittedBin(), "app.wasm");
    for (site.files) |f| _ = wf.addCopyFile(opts.myzig.path(b, b.fmt("web/{s}", .{f.name})), f.name);
    var names: std.ArrayList([]const u8) = .empty;
    if (opts.fonts) |dir| {
        bundleDir(b, wf, dir, &names);
    } else for (site.system_fonts) |set| {
        for (set) |p| if (exists(b, p)) {
            const base = std.fs.path.basename(p);
            _ = wf.addCopyFile(.{ .cwd_relative = p }, b.fmt("fonts/{s}", .{base}));
            names.append(b.allocator, base) catch @panic("OOM");
        };
        if (names.items.len > 0) break;
    }
    if (names.items.len == 0) std.log.warn("myzig web: no fonts to bundle (-Dweb-fonts=DIR): text will not draw", .{});
    _ = wf.add("fonts/fonts.json", site.fontList(b.allocator, names.items) catch @panic("OOM"));

    const install = b.addInstallDirectory(.{
        .source_dir = wf.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = opts.install_subdir orelse b.fmt("web/{s}", .{opts.name}),
    });
    return .{ .step = &install.step, .dir = wf.getDirectory(), .wasm = exe };
}

fn exists(b: *std.Build, path: []const u8) bool {
    std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch return false;
    return true;
}

fn bundleDir(b: *std.Build, wf: *std.Build.Step.WriteFile, dir_path: []const u8, names: *std.ArrayList([]const u8)) void {
    const io = b.graph.io;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| std.debug.panic("myzig web: fonts {s}: {s}", .{ dir_path, @errorName(e) });
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        if (!site.isFont(e.name)) continue;
        const name = b.dupe(e.name);
        _ = wf.addCopyFile(.{ .cwd_relative = b.pathJoin(&.{ dir_path, name }) }, b.fmt("fonts/{s}", .{name}));
        names.append(b.allocator, name) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
}

/// A step that runs the app headless under Node (`test_node.mjs`): a frame
/// draws, nothing draws while idle, and clicking the text `click` shows
/// the text `expect`. Needs `node` on the PATH.
pub fn addNodeTest(b: *std.Build, app: Site, myzig_src: std.Build.LazyPath, click: []const u8, expect: []const u8) *std.Build.Step {
    const run = b.addSystemCommand(&.{"node"});
    run.addFileArg(myzig_src.path(b, "web/test_node.mjs"));
    run.addFileArg(app.wasm.getEmittedBin());
    run.addDirectoryArg(app.dir.path(b, "fonts"));
    run.addArgs(&.{ click, expect });
    run.addCheck(.{ .expect_stdout_match = "web: ok" });
    // Node has no WebGL 2: the CPU draws (said on stderr, every run).
    run.addCheck(.{ .expect_stderr_match = "frames are drawn on the CPU" });
    return &run.step;
}
