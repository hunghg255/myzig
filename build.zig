const std = @import("std");
/// Builds apps for browsers: `@import("myzig").web.addSite(b, ...)` in an app's build.zig.
pub const web = @import("src/web/build.zig");

const examples = [_][]const u8{ "hello", "counter", "gallery", "markdown-chat", "code-editor", "pages", "notes", "todo", "clipboard", "documents", "drag-drop", "chart-streaming", "confetti", "piano", "native", "text-buffer", "text-input", "timeline", "blackhole", "chat-glow", "wind", "effort-slider", "mayoi", "embed-webview", "loading", "gestures" };
/// Examples whose views have Tester tests of their own.
const tested_examples = [_][]const u8{ "blackhole", "chat-glow", "wind", "effort-slider", "mayoi", "loading" };
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
    const loading = b.createModule(.{
        .root_source_file = b.path("plugins/loading/src/loading.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "myzig", .module = myzig }},
    });
    // The name it had before (nanoui), for apps that still import it.
    b.modules.put(b.graph.arena, "nanoui", myzig) catch @panic("OOM");
    const os = target.result.os.tag;
    // Plugins that apps depending on myzig's release take from it, as its
    // `mainthread` and `updater` modules: the package ships their sources.
    const mainthread = b.addModule("mainthread", .{
        .root_source_file = b.path("plugins/mainthread/src/mainthread.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (os == .macos) mainthread.linkFramework("CoreFoundation", .{});
    _ = b.addModule("updater", .{
        .root_source_file = b.path("plugins/updater/src/updater.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "myzig", .module = myzig }, .{ .name = "mainthread", .module = mainthread } },
    });
    if (os == .macos) {
        for (frameworks) |f| myzig.linkFramework(f, .{});
        myzig.linkSystemLibrary("objc", .{});
    }
    // Elsewhere GTK is loaded when the app starts (dlopen): nothing to link.

    // Documentation images use the Gallery's real views, rendered offscreen.
    const docs_images = b.addExecutable(.{
        .name = "docs-ui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/gallery/snapshots.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "myzig", .module = myzig }},
        }),
    });
    const render_docs = b.addRunArtifact(docs_images);
    const image_dir = render_docs.addOutputDirectoryArg("ui");
    const install_images = b.addInstallDirectory(.{
        .source_dir = image_dir,
        .install_dir = .prefix,
        .install_subdir = "docs-ui",
    });
    b.step("docs-ui", "Render UI documentation images offscreen into zig-out/docs-ui").dependOn(&install_images.step);

    const test_pages = b.step("test-pages", "Run pages hidden: hello calling Zig, and the pages test (examples/pages)");
    const test_memory = b.step("test-page-memory", "Probe hidden WebView2 memory transitions and IPC recovery (Windows)");
    const test_ipc = b.step("test-page-ipc", "Check hidden IPC batches with ASCII, Unicode and large payloads");
    const size = b.step("size", "Build counter and hello for binary-size checks");
    for (examples) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{ .{ .name = "myzig", .module = myzig }, .{ .name = "loading", .module = loading } },
            }),
            // Zig's own x86_64 backend miscompiles calls into WebKitGTK's
            // JavaScriptCore (a crash at the first call): LLVM on Linux.
            .use_llvm = if (os == .linux) true else null,
        });
        // Windows 8+ in the manifest: caption buttons as layered child windows.
        if (os == .windows) exe.win32_manifest = b.path("src/windows/myzig.manifest");
        // One install per example, shared by `zig build`, `build-<name>` and `size`.
        const install = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install.step);
        b.step(b.fmt("build-{s}", .{name}), b.fmt("Build the {s} example without running it", .{name})).dependOn(&install.step);
        if (std.mem.eql(u8, name, "counter") or std.mem.eql(u8, name, "hello")) size.dependOn(&install.step);
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
            const ipc_probe = b.addRunArtifact(exe);
            ipc_probe.has_side_effects = true;
            ipc_probe.addArg("--myzig-hidden");
            ipc_probe.setEnvironmentVariable("MYZIG_MEMORY_PROBE", "ipc");
            ipc_probe.addCheck(.{ .expect_stderr_match = "page: ipc-probe: ok" });
            test_ipc.dependOn(&ipc_probe.step);
            // A hidden page and Zig checking each other: schemes, channels,
            // events, permissions, downloads, eval, find, PDF, cookies, trust.
            const page = b.addRunArtifact(exe);
            page.addArg("--myzig-hidden");
            page.addCheck(.{ .expect_stderr_match = "page: ok" });
            test_pages.dependOn(&page.step);
            if (os == .windows) {
                var previous: ?*std.Build.Step = null;
                for ([_][]const u8{ "normal", "restore", "restore", "normal" }, 0..) |mode, i| {
                    const probe = b.addRunArtifact(exe);
                    probe.has_side_effects = true;
                    probe.addArg("--myzig-hidden");
                    probe.setEnvironmentVariable("MYZIG_MEMORY_PROBE", mode);
                    // Distinct run identities also prevent equivalent-step merging.
                    probe.setEnvironmentVariable("MYZIG_MEMORY_PROBE_RUN", b.fmt("{d}", .{i}));
                    probe.addCheck(.{ .expect_stderr_match = "page: memory-probe: ok" });
                    if (previous) |step| probe.step.dependOn(step);
                    const log = probe.captureStdErr(.{});
                    const save = b.addInstallFile(log, b.fmt("memory-probe/{d}-{s}.log", .{ i, mode }));
                    test_memory.dependOn(&save.step);
                    previous = &probe.step;
                }
            }
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
    const test_loading = b.step("test-loading", "Run the loading plugin and gallery offscreen tests");
    const loading_tests = b.addRunArtifact(b.addTest(.{ .root_module = loading }));
    test_loading.dependOn(&loading_tests.step);
    test_step.dependOn(&loading_tests.step);
    for (tested_examples) |name| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "myzig", .module = myzig }, .{ .name = "loading", .module = loading } },
        }) });
        const run_test = b.addRunArtifact(t);
        test_step.dependOn(&run_test.step);
        if (std.mem.eql(u8, name, "loading")) {
            test_loading.dependOn(&run_test.step);
        }
    }
    // The tests as a program, for another machine (Linux in a container).
    const test_bin = b.addInstallArtifact(tests, .{ .dest_sub_path = if (os == .windows) "myzig-tests.exe" else "myzig-tests" });
    b.step("test-bin", "Install the unit tests as zig-out/bin/myzig-tests").dependOn(&test_bin.step);

    // Browsers: counter and gallery as static sites, and their test under Node.
    const web_fonts = b.option([]const u8, "web-fonts", "Fonts browser builds bundle: a directory of .ttf files (default: the system's)");
    const web_step = b.step("web", "Build counter and gallery for browsers into zig-out/web/<name>");
    const web_test = b.step("test-web", "Run counter and gallery built for browsers, headless under Node");
    const web_browser = b.option([]const u8, "web-browser", "Headless Chrome/Edge executable for DOM gesture tests");
    for ([_][3][]const u8{ .{ "counter", "Increment", "1" }, .{ "gallery", "Tasks", "2 of 3 left" }, .{ "gestures", "Zoom in", "Scale 2.00" } }) |e| {
        const app = web.addSite(b, .{ .name = e[0], .main = b.path(b.fmt("examples/{s}/main.zig", .{e[0]})), .myzig = b.path("src"), .fonts = web_fonts });
        web_step.dependOn(app.step);
        web_test.dependOn(web.addNodeTest(b, app, b.path("src"), e[1], e[2]));
        if (web_browser) |browser| if (std.mem.eql(u8, e[0], "gestures")) {
            const dom = b.addSystemCommand(&.{"node"});
            dom.addFileArg(b.path("src/web/test_browser_run.mjs"));
            dom.addArg(browser);
            dom.addDirectoryArg(app.dir);
            dom.addArg("gestures=1&webgl=0");
            web_test.dependOn(&dom.step);
        };
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
