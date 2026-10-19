const std = @import("std");
/// Builds apps for browsers: `@import("myzig").web.addSite(b, ...)` in an app's build.zig.
pub const web = @import("src/web/build.zig");

const examples = [_][]const u8{ "hello", "counter", "gallery", "markdown-chat", "code-editor", "pages", "notes", "todo", "clipboard", "documents", "drag-drop", "chart-streaming", "confetti", "piano", "native", "text-buffer", "text-input", "timeline", "blackhole", "chat-glow", "wind", "effort-slider", "mayoi", "embed-webview" };
/// Examples whose views have Tester tests of their own.
const tested_examples = [_][]const u8{ "blackhole", "chat-glow", "wind", "effort-slider", "mayoi" };
const frameworks = [_][]const u8{ "AppKit", "WebKit", "Metal", "QuartzCore", "CoreText", "CoreGraphics", "CoreFoundation", "Foundation", "ImageIO", "UniformTypeIdentifiers" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const portable = b.option(bool, "portable", "Use myzig's own text and CPU renderer on macOS too (to test that path)") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "portable", portable);
    options.addOption(bool, "inspector", b.option(bool, "inspector", "Native UI's inspector (F12): on in Debug builds") orelse std.ascii.eqlIgnoreCase(optimizeName(optimize), "debug"));

    const myzig = b.addModule("myzig", .{
        .root_source_file = b.path("src/myzig.zig"),
        .target = target,
        .optimize = optimize,
        // Browsers (wasm32-wasi) have no libc: the standard library talks WASI.
        .link_libc = target.result.os.tag != .wasi,
    });
    myzig.addOptions("build_options", options);
    // The name it had before (nanoui), for apps that still import it.
    b.modules.put(b.graph.arena, "nanoui", myzig) catch @panic("OOM");
    const os = target.result.os.tag;
    if (os == .macos) {
        for (frameworks) |f| myzig.linkFramework(f, .{});
        myzig.linkSystemLibrary("objc", .{});
    }
    // Elsewhere GTK is loaded when the app starts (dlopen): nothing to link.

    const test_pages = b.step("test-pages", "Run pages hidden: hello calling Zig, and the pages test (examples/pages)");
    for (examples) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "myzig", .module = myzig }},
            }),
            // Zig's own x86_64 backend miscompiles calls into WebKitGTK's
            // JavaScriptCore (a crash at the first call): LLVM on Linux.
            .use_llvm = if (os == .linux) true else null,
        });
        // Windows 8+ in the manifest: caption buttons as layered child windows.
        if (os == .windows) exe.win32_manifest = b.path("src/windows/myzig.manifest");
        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        b.step(b.fmt("run-{s}", .{name}), b.fmt("Run the {s} example", .{name})).dependOn(&run.step);

        if (std.mem.eql(u8, name, "hello")) {
            // The page, hidden: calls, errors and an event, through the
            // real web view and bridge (`--myzig-eval`).
            const page = b.addRunArtifact(exe);
            page.addArg("--myzig-eval=" ++ page_test);
            page.addCheck(.{ .expect_stderr_match = "page: ok" });
            test_pages.dependOn(&page.step);

            const gen = b.addRunArtifact(exe);
            gen.addArg("--myzig-generate=examples/hello/frontend");
            b.step("gen", "Write the hello example's generated client").dependOn(&gen.step);
        }
        if (std.mem.eql(u8, name, "pages")) {
            // A hidden page and Zig checking each other: schemes, channels,
            // events, permissions, downloads, eval, find, PDF, cookies, trust.
            const page = b.addRunArtifact(exe);
            page.addArg("--myzig-hidden");
            page.addCheck(.{ .expect_stderr_match = "page: ok" });
            test_pages.dependOn(&page.step);
        }
        // Web views in native UI, hidden: pages calling Zig, following the
        // layout, hidden when cut away. Hidden windows of native UI draw
        // frames on Windows only (Linux: run it in the container, shown in Xvfb).
        if (std.mem.eql(u8, name, "embed-webview") and os == .windows) {
            const page = b.addRunArtifact(exe);
            page.addArgs(&.{ "--check", "--myzig-hidden" });
            page.addCheck(.{ .expect_stderr_match = "page: ok" });
            test_pages.dependOn(&page.step);
        }
    }

    const tests = b.addTest(.{ .root_module = myzig });
    if (os == .windows) tests.win32_manifest = b.path("src/windows/myzig.manifest");
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    for (tested_examples) |name| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "myzig", .module = myzig }},
        }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    // The tests as a program, for another machine (Linux in a container).
    const test_bin = b.addInstallArtifact(tests, .{ .dest_sub_path = if (os == .windows) "myzig-tests.exe" else "myzig-tests" });
    b.step("test-bin", "Install the unit tests as zig-out/bin/myzig-tests").dependOn(&test_bin.step);

    // Browsers: counter and gallery as static sites, and their test under Node.
    const web_fonts = b.option([]const u8, "web-fonts", "Fonts browser builds bundle: a directory of .ttf files (default: the system's)");
    const web_step = b.step("web", "Build counter and gallery for browsers into zig-out/web/<name>");
    const web_test = b.step("test-web", "Run counter and gallery built for browsers, headless under Node");
    for ([_][3][]const u8{ .{ "counter", "Increment", "1" }, .{ "gallery", "Tasks", "2 of 3 left" } }) |e| {
        const app = web.addSite(b, .{ .name = e[0], .main = b.path(b.fmt("examples/{s}/main.zig", .{e[0]})), .myzig = b.path("src"), .fonts = web_fonts });
        web_step.dependOn(app.step);
        web_test.dependOn(web.addNodeTest(b, app, b.path("src"), e[1], e[2]));
    }

    const lines = b.addExecutable(.{
        .name = "lines",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/lines.zig"),
            .target = b.graph.host,
        }),
    });
    const check = b.addRunArtifact(lines);
    check.setCwd(b.path("."));
    b.step("lines", "Check that every file is at most 600 lines").dependOn(&check.step);

    // Metal's sources, type-checked by clang against a stand-in metal_stdlib
    // (no Mac needed): `zig build check-msl`.
    @import("tools/msl/steps.zig").add(b);
}

/// The optimize mode's name (optional in newer Zig, where null is Debug).
fn optimizeName(optimize: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(optimize))) {
        .optional => if (optimize) |o| @tagName(o) else "debug",
        else => @tagName(optimize),
    };
}

/// What `test-pages` runs in the hello example's page.
const page_test =
    \\(async () => {
    \\  const expect = (ok, what) => { if (!ok) throw new Error(what); };
    \\  expect(["macos", "linux", "windows"].includes(myzig.platform), "platform " + myzig.platform);
    \\  expect((await myzig.call("Greeter.greet", "Ada")).startsWith("Hello, Ada!"), "greet");
    \\  const t = await myzig.call("Todos.add", "Write tests");
    \\  expect(t.title === "Write tests" && !t.done, "add");
    \\  expect((await myzig.call("Todos.toggle", t.id)).done, "toggle");
    \\  expect((await myzig.call("Todos.list")).length === 3, "list");
    \\  let err = "";
    \\  try { await myzig.call("Todos.add", " "); } catch (e) { err = String(e); }
    \\  expect(err.includes("EmptyTitle"), "error " + err);
    \\  try { await myzig.call("Nope.method"); } catch (e) { err = String(e); }
    \\  expect(err.includes("UnknownService"), "unknown " + err);
    \\  const tick = await new Promise((r) => myzig.once("tick", r));
    \\  expect(tick.todos === 3, "tick " + JSON.stringify(tick));
    \\  const mod = await import("/myzig.js");
    \\  expect(typeof mod.Greeter.greet === "function" && typeof mod.onTick === "function", "client");
    \\  myzig.log("ok");
    \\})().catch((e) => myzig.log("FAIL", String(e))).finally(() => myzig.window.close());
;
