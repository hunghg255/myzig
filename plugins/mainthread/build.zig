const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("mainthread", .{
        .root_source_file = b.path("src/mainthread.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (target.result.os.tag == .macos) mod.linkFramework("CoreFoundation", .{});
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);
    // Type-checks for another target: zig build check -Dtarget=x86_64-linux-gnu
    b.step("check", "Compile the tests without running them").dependOn(&tests.step);
}
