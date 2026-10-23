const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // myzig itself: its PNG decoder reads app icons, and the end-to-end
    // test makes apps that depend on this checkout.
    const myzig = b.dependency("myzig", .{});
    const png_decode = b.createModule(.{ .root_source_file = myzig.path("src/png_module.zig") });
    // The page and host of apps built for browsers (`myzig build --platform web`).
    const web_site = b.createModule(.{ .root_source_file = myzig.path("src/web/site.zig") });

    const options = b.addOptions();
    options.addOption([]const u8, "version", "0.1.9");
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "png_decode", .module = png_decode }, .{ .name = "myzig_web_site", .module = web_site } },
    });
    root.addOptions("build_options", options);

    const exe = b.addExecutable(.{ .name = "myzig", .root_module = root });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the myzig CLI").dependOn(&run.step);

    // Unit tests: configuration, bundles, archives, resources.
    const tests = b.addTest(.{ .root_module = root });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path("."));
    b.step("test", "Run the CLI's unit tests").dependOn(&run_tests.step);

    // End to end: `myzig init` makes apps (in .zig-cache/tmp) that `zig
    // build` compiles against this checkout of myzig.
    const e2e_options = b.addOptions();
    e2e_options.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    // The checkout this CLI is in, from the test's directory (cli/).
    e2e_options.addOption([]const u8, "myzig_root", "..");
    const e2e_root = b.createModule(.{
        .root_source_file = b.path("src/e2e_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "png_decode", .module = png_decode },
            .{ .name = "myzig_web_site", .module = web_site },
            .{ .name = "e2e_options", .module = e2e_options.createModule() },
        },
    });
    e2e_root.addOptions("build_options", options);
    const e2e = b.addTest(.{ .root_module = e2e_root });
    const run_e2e = b.addRunArtifact(e2e);
    run_e2e.setCwd(b.path("."));
    run_e2e.has_side_effects = true;
    b.step("e2e", "Make apps with `myzig init` and build them with `zig build`").dependOn(&run_e2e.step);
}
