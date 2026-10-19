//! What every platform's App does the same way: the command line it was
//! started with, and handing URLs, files and later instances' command
//! lines to the app's handlers.
const std = @import("std");
const app_types = @import("app_types.zig");
const launch = @import("launch.zig");

/// The launch's arguments, without the program and myzig's own flags, and
/// its working directory; in the process's arena.
pub const Launch = struct {
    args: []const []const u8 = &.{},
    cwd: []const u8 = "",
    /// Started by `myzig dev` (`MYZIG_DEV`), which starts it again when it
    /// exits to relaunch (`relaunch.zig`).
    dev: bool = false,

    pub fn of(init: std.process.Init) Launch {
        const arena = init.arena.allocator();
        const all = init.minimal.args.toSlice(arena) catch return .{};
        var args: std.ArrayList([]const u8) = .empty;
        for (all[@min(1, all.len)..]) |a| if (!launch.isOwnFlag(a)) args.append(arena, a) catch {};
        const cwd = std.process.currentPathAlloc(init.io, arena) catch "";
        return .{ .args = args.items, .cwd = cwd, .dev = init.environ_map.get("MYZIG_DEV") != null };
    }

    /// Whether the system started the app at login (the autostart entry
    /// passes `--myzig-login`).
    pub fn atLogin(init: std.process.Init) bool {
        const all = init.minimal.args.toSlice(init.arena.allocator()) catch return false;
        for (all) |a| if (std.mem.eql(u8, a, "--myzig-login")) return true;
        return false;
    }
};

/// Hands the URLs of the app's schemes among `args` to `on_open_url`, and
/// the files of its types that exist to `on_open_file`.
pub fn deliver(gpa: std.mem.Allocator, io: std.Io, options: app_types.Options, args: []const []const u8, cwd: []const u8) void {
    for (args) |a| {
        if (launch.urlOf(a, options.url_schemes)) |url| {
            if (options.on_open_url) |h| h.call(url);
            continue;
        }
        const h = options.on_open_file orelse continue;
        const file = (launch.fileOf(gpa, a, cwd, options.file_extensions) catch null) orelse continue;
        defer gpa.free(file);
        const stat = std.Io.Dir.cwd().statFile(io, file, .{}) catch continue;
        if (stat.kind == .file) h.call(file);
    }
}

/// A later instance's message (`launch.encodeMessage`) arrived.
pub fn secondInstance(gpa: std.mem.Allocator, io: std.Io, options: app_types.Options, bytes: []const u8) void {
    const m = launch.decodeMessage(gpa, bytes) catch return;
    defer m.deinit(gpa);
    if (options.on_second_instance) |h| h.call(.{ .args = m.args, .working_dir = m.working_dir });
    deliver(gpa, io, options, m.args, m.working_dir);
}

test "URLs and files reach their handlers" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.md", .data = "# A" });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const S = struct {
        urls: usize = 0,
        files: usize = 0,
        seconds: usize = 0,
        fn url(s: *@This(), u: []const u8) void {
            std.testing.expectEqualStrings("notes://1", u) catch unreachable;
            s.urls += 1;
        }
        fn file(s: *@This(), f: []const u8) void {
            std.testing.expect(std.mem.endsWith(u8, f, "a.md")) catch unreachable;
            s.files += 1;
        }
        fn second(s: *@This(), si: app_types.SecondInstance) void {
            std.testing.expectEqual(@as(usize, 4), si.args.len) catch unreachable;
            s.seconds += 1;
        }
    };
    var s: S = .{};
    const H = app_types.Handler;
    const options: app_types.Options = .{
        .url_schemes = &.{"notes"},
        .file_extensions = &.{"md"},
        .on_open_url = H([]const u8).of(&s, S.url),
        .on_open_file = H([]const u8).of(&s, S.file),
        .on_second_instance = H(app_types.SecondInstance).of(&s, S.second),
    };
    deliver(gpa, io, options, &.{ "notes://1", "a.md", "missing.md", "other://x" }, dir);
    try std.testing.expectEqual(@as(usize, 1), s.urls);
    try std.testing.expectEqual(@as(usize, 1), s.files);
    const msg = try launch.encodeMessage(gpa, dir, &.{ "notes://1", "a.md", "missing.md", "-v" });
    defer gpa.free(msg);
    secondInstance(gpa, io, options, msg);
    try std.testing.expectEqual(@as(usize, 1), s.seconds);
    try std.testing.expectEqual(@as(usize, 2), s.urls);
    try std.testing.expectEqual(@as(usize, 2), s.files);
}
