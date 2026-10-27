const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("signals", .{
        .root_source_file = b.path("src/signals.zig"),
        .target = target,
        .optimize = optimize,
    });

    const filters = b.option([]const []const u8, "test-filter", "Run only the tests whose names contain this") orelse &.{};
    const tests = b.addTest(.{ .filters = filters, .root_module = mod });
    const test_step = b.step("test", "Run the tests and snapshot the example, hidden");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // Type-checks for another target: zig build check -Dtarget=x86_64-linux-gnu
    const check = b.step("check", "Compile the tests without running them (any -Dtarget)");
    check.dependOn(&tests.step);

    // The example needs myzig; the module itself doesn't.
    const myzig = b.dependency("myzig", .{ .target = target, .optimize = optimize });
    const example = b.addExecutable(.{
        .name = "signals-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "myzig", .module = myzig.module("myzig") }, .{ .name = "signals", .module = mod } },
        }),
    });
    b.installArtifact(example);
    const run = b.addRunArtifact(example);
    run.addPassthruArgs();
    b.step("run", "Run the example").dependOn(&run.step);

    // The example after two clicks, rendered offscreen (no window is shown).
    const snap = b.addRunArtifact(example);
    _ = snap.addPrefixedOutputFileArg("--myzig-snapshot=", "signals.png");
    snap.addArg("--myzig-script=click:Add;click:Add");
    // Kept, not shown: the build runner prints a step's stderr as if it failed.
    _ = snap.captureStdErr(.{});
    b.step("snapshot", "Render the example offscreen (a PNG in the cache)").dependOn(&snap.step);
    test_step.dependOn(&snap.step);
}
