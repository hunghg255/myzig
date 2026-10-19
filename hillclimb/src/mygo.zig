//! mygo's twin: two files copied into a clone of mygo (hillclimb/.mygo),
//! built with the myzig_hillclimb tag as a Go test binary, which runs
//! each scene through mygo's frames and offscreen Metal renderer (its CPU
//! renderer where there is no Metal).
const std = @import("std");
const builtin = @import("builtin");
const main = @import("main.zig");
const scenes = @import("scenes.zig");

const clone = ".mygo";
const binary = if (builtin.os.tag == .windows) "out/mygo.test.exe" else "out/mygo.test";
/// Where the clone comes from, unless `--mygo` names another repository (a
/// URL or a local checkout).
pub var url: []const u8 = "https://github.com/egoist/mygo.git";

/// The twin's files: (in hillclimb, in the clone).
const files = [_][2][]const u8{
    .{ "mygo/zz_myzig_hillclimb.go", "internal/gpu/metal/zz_myzig_hillclimb.go" },
    .{ "mygo/zz_myzig_hillclimb_test.go", "ui/zz_myzig_hillclimb_test.go" },
    .{ "mygo/zz_myzig_hillclimb_darwin_test.go", "ui/zz_myzig_hillclimb_darwin_test.go" },
    .{ "mygo/zz_myzig_hillclimb_other_test.go", "ui/zz_myzig_hillclimb_other_test.go" },
    .{ "mygo/zz_myzig_hillclimb_unix_test.go", "ui/zz_myzig_hillclimb_unix_test.go" },
    .{ "mygo/zz_myzig_hillclimb_windows_test.go", "ui/zz_myzig_hillclimb_windows_test.go" },
};

pub var ready = false;

fn env(init: std.process.Init, extra: []const [2][]const u8) !std.process.Environ.Map {
    var map = try init.environ_map.clone(init.gpa);
    try map.put("GOTOOLCHAIN", "auto");
    try map.put("CGO_ENABLED", "0");
    for (extra) |kv| try map.put(kv[0], kv[1]);
    return map;
}

fn exec(init: std.process.Init, argv: []const []const u8, cwd: []const u8, map: *const std.process.Environ.Map) ![]u8 {
    const r = try std.process.run(init.gpa, init.io, .{ .argv = argv, .cwd = .{ .path = cwd }, .environ_map = map });
    defer init.gpa.free(r.stderr);
    if (!r.term.success()) {
        std.debug.print("{s}\n", .{r.stderr});
        init.gpa.free(r.stdout);
        return error.CommandFailed;
    }
    return r.stdout;
}

fn copy(init: std.process.Init, from: []const u8, to: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const data = try cwd.readFileAlloc(init.io, from, init.gpa, .limited(1 << 20));
    defer init.gpa.free(data);
    try cwd.writeFile(init.io, .{ .sub_path = to, .data = data });
}

pub fn build(init: std.process.Init) !void {
    const cwd = std.Io.Dir.cwd();
    var map = try env(init, &.{});
    defer map.deinit();
    cwd.access(init.io, clone, .{}) catch {
        init.gpa.free(try exec(init, &.{ "git", "clone", "--depth", "1", url, clone }, ".", &map));
    };
    for (files) |f| try copy(init, f[0], try std.fmt.allocPrint(init.arena.allocator(), clone ++ "/{s}", .{f[1]}));
    try cwd.createDirPath(init.io, "out");
    init.gpa.free(try exec(init, &.{ "go", "test", "-c", "-tags", "myzig_hillclimb", "-o", "../" ++ binary, "./ui" }, clone, &map));
    ready = true;
}

pub fn run(init: std.process.Init, scene: scenes.Scene, frames: usize) !main.Result {
    var buf: [32]u8 = undefined;
    var map = try env(init, &.{
        .{ "HILLCLIMB_SCENE", @tagName(scene) },
        .{ "HILLCLIMB_FRAMES", try std.fmt.bufPrint(&buf, "{d}", .{frames}) },
    });
    defer map.deinit();
    const out = try exec(init, &.{ binary, "-test.run", "TestMyzigHillclimb" }, ".", &map);
    defer init.gpa.free(out);
    const marker = "HILLCLIMB ";
    const at = std.mem.indexOf(u8, out, marker) orelse return error.NoResult;
    const line_end = std.mem.indexOfScalarPos(u8, out, at, '\n') orelse out.len;
    const arena = init.arena.allocator();
    const r = try std.json.parseFromSliceLeaky(main.Result, arena, out[at + marker.len .. line_end], .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    return r;
}
