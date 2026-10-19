const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Measures release code unless told otherwise.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default fast)") orelse .fast;

    const myzig = b.dependency("myzig", .{ .target = target, .optimize = optimize }).module("myzig");
    const exe = b.addExecutable(.{
        .name = "inputlatency",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "myzig", .module = myzig }},
        }),
    });
    b.installArtifact(exe);

    // Shows a window and types into it: a person runs it, in a desktop
    // session (README.md).
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Measure input latency (shows a window; see README.md)").dependOn(&run.step);

    // The parts that need no window: figures, plans, the recorder, the probe.
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .debug,
        .imports = &.{.{ .name = "myzig", .module = myzig }},
    }) });
    b.step("test", "Test the tool's statistics, plans and recorder").dependOn(&b.addRunArtifact(tests).step);
}
