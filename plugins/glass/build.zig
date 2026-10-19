const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const myzig = b.dependency("myzig", .{ .target = target, .optimize = optimize }).module("myzig");
    const mod = b.addModule("glass", .{
        .root_source_file = b.path("src/glass.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "myzig", .module = myzig }},
    });

    const filters = b.option([]const []const u8, "test-filter", "Run only the tests whose names contain this") orelse &.{};
    const unit = b.addTest(.{ .filters = filters, .root_module = mod });
    const tests = b.addTest(.{ .filters = filters, .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "glass", .module = mod }, .{ .name = "myzig", .module = myzig } },
    }) });
    const test_step = b.step("test", "Run the tests (the effect over pixels, panes through ui.Tester)");
    const check = b.step("check", "Compile the tests without running them (any -Dtarget)");
    for ([_]*std.Build.Step.Compile{ unit, tests }) |t| {
        test_step.dependOn(&b.addRunArtifact(t).step);
        check.dependOn(&t.step);
    }
}
