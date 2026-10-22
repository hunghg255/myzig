const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const myzig = b.dependency("myzig", .{ .target = target, .optimize = optimize }).module("myzig");
    const mod = b.addModule("loading", .{
        .root_source_file = b.path("src/loading.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "myzig", .module = myzig }},
    });
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Test loading indicators offscreen").dependOn(&b.addRunArtifact(tests).step);
    b.step("check", "Compile the plugin tests for any target").dependOn(&tests.step);
}
