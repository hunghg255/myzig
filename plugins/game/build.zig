const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const myzig = b.dependency("myzig", .{ .target = target, .optimize = optimize }).module("myzig");
    const mod = b.addModule("game", .{
        .root_source_file = b.path("src/game.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "myzig", .module = myzig }},
    });
    // Controllers, with no ui: XInput, evdev.
    const gamepad = b.addModule("gamepad", .{
        .root_source_file = b.path("src/gamepad/gamepad.zig"),
        .target = target,
        .optimize = optimize,
    });

    const filters = b.option([]const []const u8, "test-filter", "Run only the tests whose names contain this") orelse &.{};
    const tests = b.addTest(.{ .filters = filters, .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "game", .module = mod }, .{ .name = "myzig", .module = myzig } },
    }) });
    const unit = b.addTest(.{ .filters = filters, .root_module = mod });
    const pads = b.addTest(.{ .filters = filters, .root_module = gamepad });
    const test_step = b.step("test", "Run the tests (ui.Tester, offscreen) and snapshot the example, hidden");
    const check = b.step("check", "Compile the tests without running them (any -Dtarget)");
    for ([_]*std.Build.Step.Compile{ tests, unit, pads }) |t| {
        test_step.dependOn(&b.addRunArtifact(t).step);
        check.dependOn(&t.step);
    }

    const example = b.addExecutable(.{
        .name = "game-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "myzig", .module = myzig }, .{ .name = "game", .module = mod }, .{ .name = "gamepad", .module = gamepad } },
        }),
    });
    b.installArtifact(example);
    const run = b.addRunArtifact(example);
    run.addPassthruArgs();
    b.step("run", "Run the example").dependOn(&run.step);

    // The example's first frame, rendered offscreen (no window is shown).
    const snap = b.addRunArtifact(example);
    _ = snap.addPrefixedOutputFileArg("--myzig-snapshot=", "game.png");
    snap.addArg("--myzig-script=type:dddd");
    b.step("snapshot", "Render the example offscreen (a PNG in the cache)").dependOn(&snap.step);
    test_step.dependOn(&snap.step);
}
