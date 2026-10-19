const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const myzig = b.dependency("myzig", .{ .target = target, .optimize = optimize }).module("myzig");
    const mainthread = b.dependency("mainthread", .{ .target = target, .optimize = optimize }).module("mainthread");
    const mod = b.addModule("websocket", .{
        .root_source_file = b.path("src/websocket.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "myzig", .module = myzig }, .{ .name = "mainthread", .module = mainthread } },
    });
    // The example's local server, which the tests connect to too.
    const server = b.createModule(.{
        .root_source_file = b.path("example/server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "websocket", .module = mod }},
    });

    const filters = b.option([]const []const u8, "test-filter", "Run only the tests whose names contain this") orelse &.{};
    const tests = b.addTest(.{ .filters = filters, .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "websocket", .module = mod }, .{ .name = "server", .module = server } },
    }) });
    const test_step = b.step("test", "Run the tests (against an in-process server) and the example's page, hidden");
    // The modules own tests (codecs, parsers, the service compiled whole).
    const unit = b.addTest(.{ .filters = filters, .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(unit).step);
    const check = b.step("check", "Compile the tests without running them (any -Dtarget)");
    check.dependOn(&tests.step);
    check.dependOn(&unit.step);

    const example = b.addExecutable(.{
        .name = "websocket-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "myzig", .module = myzig }, .{ .name = "websocket", .module = mod }, .{ .name = "server", .module = server } },
        }),
    });
    b.installArtifact(example);
    const run = b.addRunArtifact(example);
    run.addPassthruArgs();
    b.step("run", "Run the example").dependOn(&run.step);

    const page = b.addRunArtifact(example);
    page.addArg("--myzig-eval=" ++ @embedFile("example/page_test.js"));
    page.addCheck(.{ .expect_stderr_match = "page: ok" });
    b.step("test-page", "Run the example's page hidden, through the real webview").dependOn(&page.step);
    if (b.option(bool, "page", "Also test the example's page in `test` (default true)") orelse true) test_step.dependOn(&page.step);
}
