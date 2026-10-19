const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const myzig = b.dependency("myzig", .{ .target = target, .optimize = optimize }).module("myzig");
    const mod = b.addModule("sqlite", .{
        .root_source_file = b.path("src/sqlite.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "myzig", .module = myzig }},
    });

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the tests (against the system's SQLite) and the example's page, hidden");
    test_step.dependOn(&run_tests.step);
    b.step("check", "Compile the tests without running them (any -Dtarget)").dependOn(&tests.step);

    const example = b.addExecutable(.{
        .name = "sqlite-notes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "myzig", .module = myzig }, .{ .name = "sqlite", .module = mod } },
        }),
    });
    b.installArtifact(example);
    const run = b.addRunArtifact(example);
    run.addPassthruArgs();
    b.step("run", "Run the example (a notes page)").dependOn(&run.step);

    // The example's page, hidden: it opens a database, writes and reads
    // through the service and the page's client.
    const page = b.addRunArtifact(example);
    page.addArg("--myzig-eval=" ++ @embedFile("example/page_test.js"));
    page.addCheck(.{ .expect_stderr_match = "page: ok" });
    b.step("test-page", "Run the example's page hidden, through the real webview").dependOn(&page.step);
    if (b.option(bool, "page", "Also test the example's page in `test` (default true)") orelse true) test_step.dependOn(&page.step);
}
