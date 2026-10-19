//! The farm, a package of its own: it needs the game plugin
//! (plugins/game), which myzig's own build doesn't build.
//!
//!     cd examples/farm && zig build run
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const myzig = b.dependency("myzig", .{ .target = target, .optimize = optimize }).module("myzig");
    const plugin = b.dependency("myzig_game", .{ .target = target, .optimize = optimize });
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "myzig", .module = myzig },
        .{ .name = "game", .module = plugin.module("game") },
        .{ .name = "gamepad", .module = plugin.module("gamepad") },
    };
    const exe = b.addExecutable(.{
        .name = "farm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the farm").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) });
    b.step("test", "Run the world's tests").dependOn(&b.addRunArtifact(tests).step);

    // The first frames, rendered offscreen (no window is shown).
    const snap = b.addRunArtifact(exe);
    _ = snap.addPrefixedOutputFileArg("--myzig-snapshot=", "farm.png");
    b.step("snapshot", "Render the farm offscreen (a PNG in the cache)").dependOn(&snap.step);
}
