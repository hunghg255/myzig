const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Benchmarks measure release code unless told otherwise.
    const optimize = b.option(std.lang.Optimize, "optimize", "Optimization mode (default fast)") orelse .fast;

    const myzig = b.dependency("myzig", .{ .target = target, .optimize = optimize }).module("myzig");
    const exe = b.addExecutable(.{
        .name = "hillclimb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "myzig", .module = myzig }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    b.step("run", "Run the hill-climb benchmarks (headless)").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("test", "Check timing buffers and history comparability").dependOn(&b.addRunArtifact(tests).step);
}
