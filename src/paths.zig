//! The app's own directories, where each system wants them: its data,
//! settings, caches and logs (mygo's PathUserData, PathCache, PathLogs).
//!
//!     const dir = try myzig.appPath(gpa, .logs, "Notes");
//!     defer gpa.free(dir);
const std = @import("std");
const builtin = @import("builtin");

pub const AppDir = enum {
    /// What the app keeps for the user: %APPDATA%\Name, ~/Library/Application
    /// Support/Name, $XDG_DATA_HOME/Name (~/.local/share/Name).
    data,
    /// Its settings: %APPDATA%\Name, ~/Library/Application Support/Name,
    /// $XDG_CONFIG_HOME/Name (~/.config/Name).
    config,
    /// What it can make again: %LOCALAPPDATA%\Name\Cache, ~/Library/Caches/Name,
    /// $XDG_CACHE_HOME/Name (~/.cache/Name).
    cache,
    /// Its logs: %LOCALAPPDATA%\Name\Logs, ~/Library/Logs/Name,
    /// $XDG_STATE_HOME/Name/logs (~/.local/state/Name/logs).
    logs,
    /// The system's temporary directory (not the app's own, not created).
    temp,
};

/// Looks an environment variable up; null when it is unset or empty.
pub const Env = *const fn (name: []const u8, buf: []u8) ?[]const u8;

/// The directory `dir` of the app named `app_name` on `os`, given its
/// environment: pure, for every system from any one.
pub fn resolve(gpa: std.mem.Allocator, os: std.Target.Os.Tag, dir: AppDir, app_name: []const u8, env: Env) ![]u8 {
    var b1: [1024]u8 = undefined;
    var b2: [1024]u8 = undefined;
    switch (os) {
        .windows => {
            const home = env("USERPROFILE", &b2) orelse "C:\\";
            if (dir == .temp) return gpa.dupe(u8, env("TEMP", &b1) orelse env("TMP", &b1) orelse "C:\\Windows\\Temp");
            const roaming = dir == .data or dir == .config;
            const base = (if (roaming) env("APPDATA", &b1) else env("LOCALAPPDATA", &b1)) orelse home;
            return switch (dir) {
                .cache => std.fs.path.join(gpa, &.{ base, app_name, "Cache" }),
                .logs => std.fs.path.join(gpa, &.{ base, app_name, "Logs" }),
                else => std.fs.path.join(gpa, &.{ base, app_name }),
            };
        },
        .macos => {
            if (dir == .temp) return gpa.dupe(u8, std.mem.trimEnd(u8, env("TMPDIR", &b1) orelse "/tmp", "/"));
            const home = env("HOME", &b2) orelse "/";
            return switch (dir) {
                .cache => std.fs.path.join(gpa, &.{ home, "Library", "Caches", app_name }),
                .logs => std.fs.path.join(gpa, &.{ home, "Library", "Logs", app_name }),
                else => std.fs.path.join(gpa, &.{ home, "Library", "Application Support", app_name }),
            };
        },
        else => {
            if (dir == .temp) return gpa.dupe(u8, env("TMPDIR", &b1) orelse "/tmp");
            const home = env("HOME", &b2) orelse "/";
            const xdg: struct { []const u8, []const u8, []const u8 } = switch (dir) {
                .data => .{ "XDG_DATA_HOME", ".local/share", "" },
                .config => .{ "XDG_CONFIG_HOME", ".config", "" },
                .cache => .{ "XDG_CACHE_HOME", ".cache", "" },
                .logs => .{ "XDG_STATE_HOME", ".local/state", "logs" },
                .temp => unreachable,
            };
            // The specification wants absolute paths; others are ignored.
            if (env(xdg[0], &b1)) |base| if (std.fs.path.isAbsolutePosix(base))
                return std.fs.path.join(gpa, &.{ base, app_name, xdg[2] });
            return std.fs.path.join(gpa, &.{ home, xdg[1], app_name, xdg[2] });
        },
    }
}

/// The process's environment variable `name`.
fn processEnv(name: []const u8, buf: []u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        const k32 = struct {
            extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: ?[*]u16, size: u32) callconv(.winapi) u32;
        };
        var wname: [64]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(wname[0 .. wname.len - 1], name) catch return null;
        wname[n] = 0;
        var wbuf: [1024]u16 = undefined;
        const len = k32.GetEnvironmentVariableW(@ptrCast(&wname), &wbuf, wbuf.len);
        if (len == 0 or len >= wbuf.len) return null;
        const m = std.unicode.utf16LeToUtf8(buf, wbuf[0..len]) catch return null;
        return buf[0..m];
    }
    if (builtin.os.tag == .wasi) return null;
    var zname: [64]u8 = undefined;
    if (name.len >= zname.len) return null;
    @memcpy(zname[0..name.len], name);
    zname[name.len] = 0;
    const v = std.c.getenv(@ptrCast(&zname)) orelse return null;
    const s = std.mem.span(v);
    if (s.len == 0 or s.len > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

/// The app's directory `dir` on this system, created (but `temp`) if it
/// is not there. Caller frees it.
pub fn appPath(gpa: std.mem.Allocator, dir: AppDir, app_name: []const u8) ![]u8 {
    // A headless run's are its own, in a temporary directory.
    if (dir != .temp and builtin.os.tag != .wasi and @import("headless.zig").active()) {
        const temp = try resolve(gpa, builtin.os.tag, .temp, app_name, processEnv);
        defer gpa.free(temp);
        if (try @import("headless.zig").path(gpa, @tagName(dir), app_name, temp)) |p| return p;
    }
    const p = try resolve(gpa, builtin.os.tag, dir, app_name, processEnv);
    errdefer gpa.free(p);
    if (dir != .temp and builtin.os.tag != .wasi) {
        const io = std.Io.Threaded.global_single_threaded.io();
        try std.Io.Dir.cwd().createDirPath(io, p);
    }
    return p;
}

fn fakeEnv(name: []const u8, _: []u8) ?[]const u8 {
    const table = .{
        .{ "USERPROFILE", "C:\\Users\\ada" },
        .{ "APPDATA", "C:\\Users\\ada\\AppData\\Roaming" },
        .{ "LOCALAPPDATA", "C:\\Users\\ada\\AppData\\Local" },
        .{ "HOME", "/home/ada" },
        .{ "XDG_CACHE_HOME", "/var/cache/ada" },
        .{ "XDG_CONFIG_HOME", "relative/ignored" },
    };
    inline for (table) |e| if (std.mem.eql(u8, name, e[0])) return e[1];
    return null;
}

test "each system's directories for the app" {
    const gpa = std.testing.allocator;
    const cases = .{
        .{ std.Target.Os.Tag.windows, AppDir.data, "C:\\Users\\ada\\AppData\\Roaming\\Notes" },
        .{ std.Target.Os.Tag.windows, AppDir.logs, "C:\\Users\\ada\\AppData\\Local\\Notes\\Logs" },
        .{ std.Target.Os.Tag.windows, AppDir.cache, "C:\\Users\\ada\\AppData\\Local\\Notes\\Cache" },
        .{ std.Target.Os.Tag.macos, AppDir.config, "/home/ada/Library/Application Support/Notes" },
        .{ std.Target.Os.Tag.macos, AppDir.logs, "/home/ada/Library/Logs/Notes" },
        .{ std.Target.Os.Tag.macos, AppDir.temp, "/tmp" },
        .{ std.Target.Os.Tag.linux, AppDir.data, "/home/ada/.local/share/Notes" },
        .{ std.Target.Os.Tag.linux, AppDir.config, "/home/ada/.config/Notes" },
        .{ std.Target.Os.Tag.linux, AppDir.cache, "/var/cache/ada/Notes" },
        .{ std.Target.Os.Tag.linux, AppDir.logs, "/home/ada/.local/state/Notes/logs" },
    };
    inline for (cases) |c| {
        const p = try resolve(gpa, c[0], c[1], "Notes", fakeEnv);
        defer gpa.free(p);
        // Joined with the separator of the system running the test.
        var want: [128]u8 = undefined;
        const w = want[0..c[2].len];
        @memcpy(w, c[2]);
        for (w) |*ch| if (ch.* == '/' or ch.* == '\\') {
            ch.* = std.fs.path.sep;
        };
        for (p) |*ch| if (ch.* == '/' or ch.* == '\\') {
            ch.* = std.fs.path.sep;
        };
        try std.testing.expectEqualStrings(w, p);
    }
}

test "the app's directory is there once asked for" {
    const gpa = std.testing.allocator;
    const p = try appPath(gpa, .temp, "myzig-test");
    defer gpa.free(p);
    try std.testing.expect(p.len > 0);
}
