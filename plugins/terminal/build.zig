const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const myzig = b.dependency("myzig", .{ .target = target, .optimize = optimize }).module("myzig");
    const mainthread = b.dependency("mainthread", .{ .target = target, .optimize = optimize }).module("mainthread");
    const imports: []const std.Build.Module.Import = &.{ .{ .name = "myzig", .module = myzig }, .{ .name = "mainthread", .module = mainthread } };
    const mod = b.addModule("terminal", .{
        .root_source_file = b.path("src/terminal.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });

    const filters = b.option([]const []const u8, "test-filter", "Run only the tests whose names contain this") orelse &.{};
    const unit = b.addTest(.{ .filters = filters, .root_module = mod });
    const tests = b.addTest(.{ .filters = filters, .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "terminal", .module = mod }, .{ .name = "myzig", .module = myzig } },
    }) });
    const test_step = b.step("test", "Run the tests (libghostty-vt, a PTY, ui.Tester offscreen)");
    const check = b.step("check", "Compile the tests without running them (any -Dtarget)");
    for ([_]*std.Build.Step.Compile{ unit, tests }) |t| {
        test_step.dependOn(&b.addRunArtifact(t).step);
        check.dependOn(&t.step);
    }

    const example = b.addExecutable(.{
        .name = "terminal-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{ .{ .name = "myzig", .module = myzig }, .{ .name = "terminal", .module = mod }, .{ .name = "mainthread", .module = mainthread } },
        }),
    });
    b.installArtifact(example);
    check.dependOn(&example.step);
    const run = b.addRunArtifact(example);
    run.addPassthruArgs();
    b.step("run", "Run the example").dependOn(&run.step);

    // The example's first frames, rendered offscreen (no window is shown).
    const snap = b.addRunArtifact(example);
    _ = snap.addPrefixedOutputFileArg("--myzig-snapshot=", "terminal.png");
    snap.addArg("--myzig-script=live:1");
    b.step("snapshot", "Render the example offscreen (a PNG in the cache)").dependOn(&snap.step);
}
