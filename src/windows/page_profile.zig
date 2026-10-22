//! A headless WebView2 profile belongs to the run's temporary directories.
const std = @import("std");
const headless = @import("../headless.zig");

pub fn path(app: anytype, buf: []u8) ![]const u8 {
    if (headless.active()) {
        const cache = try @import("desktop.zig").path(app.gpa, .cache, app.options.name);
        defer app.gpa.free(cache);
        return std.fmt.bufPrint(buf, "{s}\\WebView2", .{cache});
    }
    const base = app.environ.get("LOCALAPPDATA") orelse app.environ.get("TEMP") orelse ".";
    return std.fmt.bufPrint(buf, "{s}\\{s}\\WebView2", .{ base, app.options.name });
}

test "headless WebView2 profile stays in its temporary run, even with LOCALAPPDATA set" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const temp = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(temp);
    headless.begin(t.io, temp);
    defer headless.end(t.io);
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("LOCALAPPDATA", "C:\\must-not-use-user-profile");
    const app = .{ .gpa = t.allocator, .environ = &env, .options = .{ .name = "ProfileTest" } };
    var buf: [2048]u8 = undefined;
    const actual = try path(app, &buf);
    try t.expect(std.mem.startsWith(u8, actual, temp));
    try t.expect(std.mem.endsWith(u8, actual, "\\ProfileTest\\cache\\WebView2"));
    var tiny: [1]u8 = undefined;
    try t.expectError(error.NoSpaceLeft, path(app, &tiny));
}
