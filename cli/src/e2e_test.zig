//! End to end (`zig build e2e`): apps made by `myzig init` in temporary
//! directories, depending on this checkout of myzig, build with plain
//! `zig build`; the web template writes its client; `myzig build`
//! packages the native one for each platform. Nothing is shown: the app
//! runs only headless (`--myzig-snapshot`, `--myzig-generate`).
const std = @import("std");
const builtin = @import("builtin");
const e2e = @import("e2e_options");
const fsx = @import("fsx.zig");
const proc = @import("proc.zig");
const init = @import("init.zig");
const config = @import("config.zig");
const package = @import("package.zig");
const linux = @import("linux.zig");
const compress = @import("compress.zig");
const Ctx = fsx.Ctx;

var env: std.process.Environ.Map = undefined;

fn setup(arena: std.mem.Allocator) !Ctx {
    env = try std.testing.environ.createMap(arena);
    // Archives made here are the same from run to run.
    try env.put("SOURCE_DATE_EPOCH", "1700000000");
    return .{ .gpa = arena, .io = std.testing.io, .env = &env, .zig = e2e.zig_exe };
}

fn tmpPath(ctx: Ctx, tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    const rel = try std.fs.path.join(ctx.gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    return ctx.join(&.{ try fsx.absolute(ctx, rel), name });
}

fn expectFile(ctx: Ctx, path: []const u8) !void {
    if (!fsx.exists(ctx.io, path)) {
        std.debug.print("missing {s}\n", .{path});
        return error.TestUnexpectedResult;
    }
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "init native, zig build, a headless snapshot, and myzig build for every platform" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx = try setup(arena.allocator());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(ctx, &tmp, "Hello Native");

    try init.run(ctx, .{ .dir = dir, .myzig = e2e.myzig_root });
    for ([_][]const u8{ "build.zig", "build.zig.zon", "myzig.zon", "src/main.zig", "resources/icon.png", ".gitignore" }) |f|
        try expectFile(ctx, try ctx.join(&.{ dir, f }));
    const zon = try fsx.read(ctx, try ctx.join(&.{ dir, "build.zig.zon" }));
    try std.testing.expect(contains(zon, ".name = .hello_native,"));
    try std.testing.expect(contains(zon, ".myzig = .{ .path = \"../../../../..\" }"));
    const c = try config.load(ctx, dir);
    try std.testing.expectEqualStrings("Hello Native", c.name);
    try std.testing.expectEqualStrings("hello_native", c.executable);
    try std.testing.expectEqualStrings("resources/icon.png", c.icon);

    // Plain Zig builds it.
    try proc.check(ctx, &.{ ctx.zig, "build" }, dir);
    const exe = try ctx.join(&.{ dir, "zig-out", "bin", if (builtin.os.tag == .windows) "hello_native.exe" else "hello_native" });
    try expectFile(ctx, exe);
    // Its window, rendered offscreen: nothing appears on the screen.
    const shot = try ctx.join(&.{ dir, "shot.png" });
    try proc.check(ctx, &.{ exe, try ctx.fmt("--myzig-snapshot={s}", .{shot}), "--myzig-script=click:Increment" }, dir);
    const w, _ = try @import("png.zig").size(try fsx.read(ctx, shot));
    try std.testing.expect(w > 0);

    // The release of this platform and the others, cross-compiled. Linking
    // for macOS needs its SDK's frameworks: on a Mac only (macos.zig tests
    // the bundle elsewhere).
    const host = proc.Platform.host();
    for ([_]proc.Platform{ host, .linux, .macos, .windows }, 0..) |p, i| {
        if (i > 0 and p == host) continue;
        if (p == .macos and host != .macos) continue;
        const r = try package.run(ctx, .{ .dir = dir, .platform = p, .arch = .x86_64, .skip_dmg = true });
        try checkPackage(ctx, c, p, r);
    }

    // 32-bit Windows: an i386 executable, with its resources and packages.
    const r32 = try package.run(ctx, .{ .dir = dir, .platform = .windows, .arch = .x86, .skip_dmg = true });
    const bin32 = try fsx.read(ctx, try ctx.join(&.{ r32.dir, "Hello Native", "Hello Native.exe" }));
    const pe = std.mem.readInt(u32, bin32[0x3c..][0..4], .little);
    try std.testing.expectEqual(proc.Arch.x86.coffMachine(), std.mem.readInt(u16, bin32[pe + 4 ..][0..2], .little));
    try std.testing.expect(contains(bin32, "PerMonitorV2"));
    try std.testing.expect(contains(bin32, "asInvoker"));
    try expectFile(ctx, try ctx.join(&.{ r32.dir, "Hello Native Portable 0.1.0 x86.zip" }));
    if (package.makensisPath(ctx) != null) try expectFile(ctx, try ctx.join(&.{ r32.dir, "Hello Native Setup 0.1.0 x86.exe" }));
}

fn checkPackage(ctx: Ctx, c: config.Config, p: proc.Platform, r: package.Result) !void {
    switch (p) {
        .windows => {
            const exe = try ctx.join(&.{ r.dir, "Hello Native", "Hello Native.exe" });
            const bin = try fsx.read(ctx, exe);
            try std.testing.expect(std.mem.startsWith(u8, bin, "MZ"));
            // The version resource, linked from the .res: its UTF-16 strings.
            const id = try std.unicode.utf8ToUtf16LeAlloc(ctx.gpa, "MyzigIdentifier");
            try std.testing.expect(contains(bin, std.mem.sliceAsBytes(id)));
            const ident = try std.unicode.utf8ToUtf16LeAlloc(ctx.gpa, c.identifier);
            try std.testing.expect(contains(bin, std.mem.sliceAsBytes(ident)));
            try std.testing.expect(contains(bin, "PerMonitorV2"));
            // The portable zip, and the installer where NSIS is installed.
            try expectFile(ctx, try ctx.join(&.{ r.dir, "Hello Native Portable 0.1.0 x86_64.zip" }));
            const nsi = try fsx.read(ctx, try ctx.join(&.{ c.root, ".myzig", "build", "windows-x86_64", "installer.nsi" }));
            try std.testing.expect(contains(nsi, "Hello Native.exe"));
            if (package.makensisPath(ctx) != null) try expectFile(ctx, try ctx.join(&.{ r.dir, "Hello Native Setup 0.1.0 x86_64.exe" }));
        },
        .linux => {
            const deb = try fsx.read(ctx, try ctx.join(&.{ r.dir, "hello-native_0.1.0_amd64.deb" }));
            const members = try linux.arMembers(ctx.gpa, deb);
            try std.testing.expectEqual(@as(usize, 3), members.len);
            const data = try compress.inflate(ctx.gpa, members[2][1], .gzip);
            const names = try linux.tarNames(ctx.gpa, data);
            var found: usize = 0;
            for (names) |n| {
                if (std.mem.eql(u8, n, "./opt/hello_native/hello_native")) found += 1;
                if (std.mem.eql(u8, n, "./usr/share/applications/hello_native.desktop")) found += 1;
                if (std.mem.eql(u8, n, "./usr/share/icons/hicolor/256x256/apps/hello_native.png")) found += 1;
            }
            try std.testing.expectEqual(@as(usize, 3), found);
            const elf = try fsx.read(ctx, try ctx.join(&.{ r.dir, "hello_native", "hello_native" }));
            try std.testing.expect(std.mem.startsWith(u8, elf, "\x7fELF"));
            try expectFile(ctx, try ctx.join(&.{ r.dir, "hello_native-0.1.0-linux-x86_64.tar.gz" }));
        },
        .macos => {
            const app = try ctx.join(&.{ r.dir, "Hello Native.app", "Contents" });
            const plist = try fsx.read(ctx, try ctx.join(&.{ app, "Info.plist" }));
            try std.testing.expect(contains(plist, "<key>CFBundleExecutable</key>\n\t<string>Hello Native</string>"));
            try std.testing.expect(contains(plist, "<string>com.example.hellonative</string>"));
            const icns = try fsx.read(ctx, try ctx.join(&.{ app, "Resources", "icon.icns" }));
            try std.testing.expect(std.mem.startsWith(u8, icns, "icns"));
            const macho = try fsx.read(ctx, try ctx.join(&.{ app, "MacOS", "Hello Native" }));
            try std.testing.expectEqual(@as(u32, 0xfeedfacf), std.mem.readInt(u32, macho[0..4], .little));
            if (builtin.os.tag != .macos) try expectFile(ctx, try ctx.join(&.{ r.dir, "Hello Native-0.1.0-macos-x86_64.zip" }));
        },
    }
}

test "init web: zig build, and the client written by the app" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx = try setup(arena.allocator());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(ctx, &tmp, "hello-web");

    // init builds the app to write its client (generate).
    try init.run(ctx, .{ .dir = dir, .template = .web, .myzig = e2e.myzig_root });
    const fe = try ctx.join(&.{ dir, "frontend" });
    for ([_][]const u8{ "index.html", "main.js", "style.css", "myzig_assets.zig", "myzig.js", "myzig.d.ts" }) |f|
        try expectFile(ctx, try ctx.join(&.{ fe, f }));
    const dts = try fsx.read(ctx, try ctx.join(&.{ fe, "myzig.d.ts" }));
    try std.testing.expect(contains(dts, "Greeter"));
    try std.testing.expect(contains(dts, "greet(name: string): Promise<string>"));
    const assets = try fsx.read(ctx, try ctx.join(&.{ fe, "myzig_assets.zig" }));
    try std.testing.expect(contains(assets, "@embedFile(\"index.html\")"));
    try std.testing.expect(!contains(assets, "myzig.d.ts"));

    // A new page is listed again, and plain Zig still builds the app.
    try fsx.write(ctx.io, try ctx.join(&.{ fe, "about.html" }), "<p>About</p>");
    const c = try config.load(ctx, dir);
    try std.testing.expect(try @import("appbuild.zig").prepareFrontend(ctx, c));
    try std.testing.expect(!try @import("appbuild.zig").prepareFrontend(ctx, c));
    try proc.check(ctx, &.{ ctx.zig, "build" }, dir);
}

/// A console program standing in for an app (no window): it appends its
/// version to .myzig/ran.txt, then waits to be stopped, or quits.
fn fakeApp(comptime v: []const u8, comptime quit: bool) []const u8 {
    return
        \\const std = @import("std");
        \\pub fn main(init: std.process.Init) !void {
        \\    const cwd = std.Io.Dir.cwd();
        \\    const old = cwd.readFileAlloc(init.io, ".myzig/ran.txt", init.arena.allocator(), .limited(1 << 16)) catch "";
        \\    const new = try std.mem.concat(init.arena.allocator(), u8, &.{ old, "
    ++ v ++
        \\\n" });
        \\    try cwd.writeFile(init.io, .{ .sub_path = ".myzig/ran.txt", .data = new });
        \\
    ++ (if (quit) "" else "    try std.Io.sleep(init.io, .fromSeconds(3600), .awake);\n") ++
        \\}
        \\
    ;
}

const fake_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const exe = b.addExecutable(.{ .name = "fake", .root_module = b.createModule(.{
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target = b.standardTargetOptions(.{}),
    \\    }) });
    \\    b.installArtifact(exe);
    \\}
    \\
;

fn devThread(ctx: Ctx, dir: []const u8, result: *?anyerror) void {
    @import("dev.zig").run(ctx, .{ .dir = dir }) catch |e| {
        result.* = e;
    };
}

/// Waits for `path` to hold `want`. The guard only turns a hang into a
/// failure (a minute of tries); no result depends on how long it takes.
fn waitFor(ctx: Ctx, path: []const u8, want: []const u8) !void {
    var tries: usize = 0;
    while (tries < 1200) : (tries += 1) {
        const got = fsx.read(ctx, path) catch "";
        if (std.mem.eql(u8, got, want)) return;
        std.Io.sleep(ctx.io, .fromMilliseconds(50), .awake) catch {};
    }
    std.debug.print("{s} never held {s}\n", .{ path, want });
    return error.TestUnexpectedResult;
}

test "dev rebuilds and restarts the app when its source changes, and ends when it quits" {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const ctx = try setup(arena.allocator());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(ctx, &tmp, "fake");
    try fsx.write(ctx.io, try ctx.join(&.{ dir, "build.zig" }), fake_build);
    try fsx.write(ctx.io, try ctx.join(&.{ dir, "myzig.zon" }), ".{ .name = \"Fake\", .executable = \"fake\" }");
    try fsx.write(ctx.io, try ctx.join(&.{ dir, "src", "main.zig" }), fakeApp("v1", false));
    // In .myzig, which dev ignores: writing it is no change to rebuild for.
    const ran = try ctx.join(&.{ dir, ".myzig", "ran.txt" });

    var result: ?anyerror = null;
    var quiet = ctx;
    quiet.quiet = true;
    const t = try std.Thread.spawn(.{}, devThread, .{ quiet, dir, &result });
    try waitFor(ctx, ran, "v1\n");
    // The change stops v1 and starts v2, which quits: dev ends.
    try fsx.write(ctx.io, try ctx.join(&.{ dir, "src", "main.zig" }), fakeApp("v2", true));
    t.join();
    try std.testing.expect(result == null);
    try std.testing.expectEqualStrings("v1\nv2\n", try fsx.read(ctx, ran));
}

/// A console program standing in for an app that relaunches once under
/// dev: the first run writes "1" and exits with dev's relaunch code (75),
/// the second appends "2" and quits.
const relaunching_app =
    \\const std = @import("std");
    \\pub fn main(init: std.process.Init) !void {
    \\    const a = init.arena.allocator();
    \\    const cwd = std.Io.Dir.cwd();
    \\    const old = cwd.readFileAlloc(init.io, ".myzig/ran.txt", a, .limited(1 << 16)) catch "";
    \\    const first = old.len == 0;
    \\    const new = try std.mem.concat(a, u8, &.{ old, if (first) "1\n" else "2\n" });
    \\    try cwd.writeFile(init.io, .{ .sub_path = ".myzig/ran.txt", .data = new });
    \\    if (first) std.process.exit(75);
    \\}
    \\
;

test "dev starts the app again when it relaunches (exit code 75), and ends when it quits" {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const ctx = try setup(arena.allocator());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(ctx, &tmp, "relaunching");
    try fsx.write(ctx.io, try ctx.join(&.{ dir, "build.zig" }), fake_build);
    try fsx.write(ctx.io, try ctx.join(&.{ dir, "myzig.zon" }), ".{ .name = \"Fake\", .executable = \"fake\" }");
    try fsx.write(ctx.io, try ctx.join(&.{ dir, "src", "main.zig" }), relaunching_app);
    const ran = try ctx.join(&.{ dir, ".myzig", "ran.txt" });

    var result: ?anyerror = null;
    var quiet = ctx;
    quiet.quiet = true;
    const t = try std.Thread.spawn(.{}, devThread, .{ quiet, dir, &result });
    t.join();
    try std.testing.expect(result == null);
    try std.testing.expectEqualStrings("1\n2\n", try fsx.read(ctx, ran));
}
