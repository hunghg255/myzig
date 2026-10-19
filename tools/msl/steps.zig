//! The `check-msl` step (`check.zig`), added by the repository's build.zig:
//!
//!     @import("tools/msl/steps.zig").add(b);
//!
//! The checker runs on the build's machine, with myzig built for it, the
//! examples' modules (for their shaders) and the GPU tests' shaders.
const std = @import("std");

/// Examples whose shaders are checked: module name, directory.
const examples = [_][2][]const u8{
    .{ "blackhole", "blackhole" },
    .{ "chat_glow", "chat-glow" },
    .{ "effort_slider", "effort-slider" },
    .{ "mayoi", "mayoi" },
    .{ "wind", "wind" },
};

pub fn add(b: *std.Build) void {
    const host = b.graph.host;
    const options = b.addOptions();
    options.addOption(bool, "portable", false);
    options.addOption(bool, "inspector", false);
    const myzig = b.createModule(.{
        .root_source_file = b.path("src/myzig.zig"),
        .target = host,
        .link_libc = true,
    });
    myzig.addOptions("build_options", options);
    const with_myzig: []const std.Build.Module.Import = &.{.{ .name = "myzig", .module = myzig }};

    // The GPU tests' shaders, their import of shader.zig made myzig's.
    const rehome = b.addExecutable(.{ .name = "msl-rehome", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/msl/rehome.zig"),
        .target = host,
    }) });
    const run_rehome = b.addRunArtifact(rehome);
    run_rehome.addFileArg(b.path("src/ui/shader/tests_shaders.zig"));
    const test_shaders = run_rehome.addOutputFileArg("tests_shaders.zig");

    const check = b.createModule(.{
        .root_source_file = b.path("tools/msl/check.zig"),
        .target = host,
        .imports = with_myzig,
    });
    check.addImport("test_shaders", b.createModule(.{ .root_source_file = test_shaders, .imports = with_myzig }));
    check.addImport("glass", b.createModule(.{ .root_source_file = b.path("plugins/glass/src/shader.zig"), .imports = with_myzig }));
    for (examples) |e| check.addImport(e[0], b.createModule(.{
        .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{e[1]})),
        .imports = with_myzig,
    }));
    const exe = b.addExecutable(.{ .name = "msl-check", .root_module = check });
    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    run.addArg(b.graph.zig_exe);
    _ = run.addOutputDirectoryArg("msl");
    // It reads the Metal sources itself: run it every time.
    run.has_side_effects = true;
    b.step("check-msl", "Check the Metal shaders with clang, against tools/msl/metal_stdlib").dependOn(&run.step);
}
