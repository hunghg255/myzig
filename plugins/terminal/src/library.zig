//! Where the terminal's native libraries are: libghostty-vt everywhere,
//! and on Windows the Windows Terminal team's ConPTY (conpty.dll with its
//! console host, OpenConsole.exe), as `myzig-plugin.json` names their
//! builds by platform with their SHA-256. A library is looked for, in
//! order:
//!
//! - in the file `$MYZIG_GHOSTTY_VT` (`$MYZIG_CONPTY`) names, or mygo's
//!   `$MYGO_GHOSTTY_VT` (`$MYGO_CONPTY`);
//! - next to the executable, where an app ships it;
//! - in the user's cache, `<cache>/myzig/natives/<sha256>/<name>`, where
//!   `download.zig` puts it, then mygo's `<cache>/mygo/natives/…`, where
//!   mygo's CLI does (the same builds).
//!
//! Nothing here downloads: an app that wants it calls `download.fetch`.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const ghostty = @import("ghostty.zig");

pub const manifest = @embedFile("myzig-plugin.json");

/// A build of a library for one platform.
pub const File = struct { name: []const u8, url: []const u8, sha256: []const u8 };

/// This platform as the manifest names it ("windows-amd64").
pub const platform: []const u8 = (switch (builtin.os.tag) {
    .windows => "windows",
    .macos => "darwin",
    else => "linux",
}) ++ "-" ++ switch (builtin.cpu.arch) {
    .aarch64 => "arm64",
    .x86 => "386",
    else => "amd64",
};

/// The build of library `name` ("libghostty-vt", "conpty", "openconsole")
/// for this platform, its strings in `arena`.
pub fn build(arena: std.mem.Allocator, name: []const u8) !File {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, manifest, .{});
    const libs = v.object.get("libraries") orelse return error.BadManifest;
    for (libs.array.items) |lib| {
        const n = lib.object.get("name") orelse continue;
        if (!std.mem.eql(u8, n.string, name)) continue;
        const files = lib.object.get("files") orelse return error.BadManifest;
        const f = files.object.get(platform) orelse return error.NoBuildForPlatform;
        return .{
            .name = (f.object.get("name") orelse return error.BadManifest).string,
            .url = (f.object.get("url") orelse return error.BadManifest).string,
            .sha256 = (f.object.get("sha256") orelse return error.BadManifest).string,
        };
    }
    return error.NoBuildForPlatform;
}

/// The variables that name library `name`, myzig's then mygo's.
fn envNames(name: []const u8) [2][]const u8 {
    if (std.mem.eql(u8, name, "conpty")) return .{ "MYZIG_CONPTY", "MYGO_CONPTY" };
    if (std.mem.eql(u8, name, "openconsole")) return .{ "MYZIG_OPENCONSOLE", "MYGO_OPENCONSOLE" };
    return .{ "MYZIG_GHOSTTY_VT", "MYGO_GHOSTTY_VT" };
}

/// The path of library `name` for this platform, or null when it is
/// nowhere it is looked for. Allocated with `gpa`.
pub fn find(gpa: std.mem.Allocator, io: Io, name: []const u8) !?[:0]u8 {
    for (envNames(name)) |e| if (try env(gpa, e)) |p| return p;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const f = try build(arena, name);
    var dirs: std.ArrayList([]const u8) = .empty;
    var exe_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    if (std.process.executableDirPath(io, &exe_buf)) |n| try dirs.append(arena, exe_buf[0..n]) else |_| {}
    for ([_][]const u8{ "myzig", "mygo" }) |owner| {
        if (try cacheDir(arena, owner)) |c| try dirs.append(arena, try std.fs.path.join(arena, &.{ c, f.sha256 }));
    }
    for (dirs.items) |d| {
        const p = try std.fs.path.joinZ(gpa, &.{ d, f.name });
        if (Io.Dir.cwd().access(io, p, .{})) |_| return p else |_| gpa.free(p);
    }
    return null;
}

/// `<cache>/<owner>/natives`: the user's cache directory of natives.
pub fn cacheDir(arena: std.mem.Allocator, owner: []const u8) !?[]const u8 {
    const base: []const u8 = switch (builtin.os.tag) {
        .windows => (try env(arena, "LOCALAPPDATA")) orelse return null,
        .macos => try std.fs.path.join(arena, &.{ (try env(arena, "HOME")) orelse return null, "Library", "Caches" }),
        else => if (try env(arena, "XDG_CACHE_HOME")) |x| x else try std.fs.path.join(arena, &.{ (try env(arena, "HOME")) orelse return null, ".cache" }),
    };
    return try std.fs.path.join(arena, &.{ base, owner, "natives" });
}

/// Loads libghostty-vt, once: `error.GhosttyMissing` when it is nowhere
/// `find` looks (an app ships it next to its executable, or calls
/// `download.fetch` first).
pub fn load(gpa: std.mem.Allocator, io: Io) !void {
    if (ghostty.loaded()) return;
    const path = (try find(gpa, io, "libghostty-vt")) orelse return error.GhosttyMissing;
    defer gpa.free(path);
    try ghostty.load(path);
}

/// The ConPTY to load (Windows): conpty.dll, with OpenConsole.exe beside
/// it, where conpty.dll looks for its host. Null when it is missing,
/// which falls back to Windows' own ConPTY.
pub fn conpty(gpa: std.mem.Allocator, io: Io) !?[:0]u8 {
    const dll = (try find(gpa, io, "conpty")) orelse return null;
    errdefer gpa.free(dll);
    const dir = std.fs.path.dirname(dll) orelse return dll;
    const host = try std.fs.path.join(gpa, &.{ dir, "OpenConsole.exe" });
    defer gpa.free(host);
    if (Io.Dir.cwd().access(io, host, .{})) |_| return dll else |_| {}
    // In a cache each file has a folder of its own: the host joins it.
    const exe = (try find(gpa, io, "openconsole")) orelse {
        gpa.free(dll);
        return null;
    };
    defer gpa.free(exe);
    Io.Dir.copyFile(Io.Dir.cwd(), exe, Io.Dir.cwd(), host, io, .{}) catch {
        gpa.free(dll);
        return null;
    };
    return dll;
}

/// An environment variable, or null when it is unset or empty.
pub fn env(gpa: std.mem.Allocator, name: []const u8) !?[:0]u8 {
    if (builtin.os.tag == .windows) {
        var wname: [64:0]u16 = undefined;
        const wn = try std.unicode.utf8ToUtf16Le(&wname, name);
        wname[wn] = 0;
        var wide: [4096]u16 = undefined;
        const n = win.GetEnvironmentVariableW(wname[0..wn :0], &wide, wide.len);
        if (n == 0 or n >= wide.len) return null;
        const s = try std.unicode.utf16LeToUtf8AllocZ(gpa, wide[0..n]);
        return s;
    }
    var buf: [256]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const v = std.c.getenv(buf[0..name.len :0]) orelse return null;
    const s = std.mem.span(v);
    if (s.len == 0) return null;
    const out = try gpa.allocSentinel(u8, s.len, 0);
    @memcpy(out, s);
    return out;
}

const win = struct {
    extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: [*]u16, size: u32) callconv(.winapi) u32;
};

test "the manifest names libghostty-vt for this platform" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const f = try build(arena.allocator(), "libghostty-vt");
    try std.testing.expect(std.mem.indexOf(u8, f.name, "ghostty-vt") != null);
    try std.testing.expectEqual(@as(usize, 64), f.sha256.len);
    if (builtin.os.tag == .windows) _ = try build(arena.allocator(), "conpty");
}
