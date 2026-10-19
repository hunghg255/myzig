//! What the system does for apps on Windows: opening them at login (the
//! user's Run key), their recent documents (the shell's Recent list),
//! keeping the system or the display awake (power requests), and the
//! user's locale and region.
const std = @import("std");
const w = @import("win32.zig");
const reg = @import("registry.zig");

pub const run_key = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";

/// Opens `exe` at login (with `--myzig-login`) under the value `name` of
/// `key` (`run_key`, or a test's), or stops doing so.
pub fn setOpenAtLogin(gpa: std.mem.Allocator, key: []const u8, name: []const u8, exe: []const u8, on: bool) !void {
    if (!on) return reg.deleteValue(key, name);
    const cmd = try std.fmt.allocPrint(gpa, "\"{s}\" --myzig-login", .{exe});
    defer gpa.free(cmd);
    try reg.setString(key, name, cmd);
}

pub fn openAtLogin(gpa: std.mem.Allocator, key: []const u8, name: []const u8, exe: []const u8) bool {
    const got = (reg.getString(gpa, key, name) catch return false) orelse return false;
    defer gpa.free(got);
    return std.mem.startsWith(u8, got, "\"") and std.ascii.startsWithIgnoreCase(got[1..], exe);
}

extern "shell32" fn SHAddToRecentDocs(flags: u32, pv: ?*const anyopaque) callconv(.winapi) void;

/// Adds `path` to the shell's recent documents (and the app's jump list's
/// Recent category, for the file types it is registered to open).
pub fn addRecentDocument(path: []const u8) void {
    var buf: [32768]u16 = undefined;
    SHAddToRecentDocs(3, w.wide(&buf, path)); // SHARD_PATHW
}

/// Clears the shell's recent documents of the app.
pub fn clearRecentDocuments() void {
    SHAddToRecentDocs(3, null);
}

const REASON_CONTEXT = extern struct {
    Version: u32 = 0,
    Flags: u32 = 1, // POWER_REQUEST_CONTEXT_SIMPLE_STRING
    reason: ?[*:0]const u16,
};
extern "kernel32" fn PowerCreateRequest(ctx: *const REASON_CONTEXT) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn PowerSetRequest(h: *anyopaque, kind: u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn PowerClearRequest(h: *anyopaque, kind: u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn CloseHandle(h: *anyopaque) callconv(.winapi) w.BOOL;

pub const Awake = enum {
    /// The system does not sleep; the display may turn off.
    system,
    /// Nor does the display.
    display,
};

/// A power request keeping the system (and the display) awake until released.
pub const Blocker = struct {
    handle: *anyopaque,
    kinds: [2]bool,

    pub fn release(b: Blocker) void {
        if (b.kinds[0]) _ = PowerClearRequest(b.handle, 1); // PowerRequestSystemRequired
        if (b.kinds[1]) _ = PowerClearRequest(b.handle, 0); // PowerRequestDisplayRequired
        _ = CloseHandle(b.handle);
    }
};

/// Keeps the system awake (`reason` shows in `powercfg /requests`).
pub fn preventSleep(reason: []const u8, what: Awake) !Blocker {
    var buf: [256]u16 = undefined;
    const ctx: REASON_CONTEXT = .{ .reason = w.wide(&buf, reason) };
    const h = PowerCreateRequest(&ctx) orelse return error.PowerRequest;
    errdefer _ = CloseHandle(h);
    var b: Blocker = .{ .handle = h, .kinds = .{ false, false } };
    if (PowerSetRequest(h, 1) == 0) return error.PowerRequest;
    b.kinds[0] = true;
    if (what == .display) {
        if (PowerSetRequest(h, 0) == 0) {
            b.release();
            return error.PowerRequest;
        }
        b.kinds[1] = true;
    }
    return b;
}

extern "kernel32" fn GetUserDefaultLocaleName(buf: [*]u16, size: i32) callconv(.winapi) i32;
extern "kernel32" fn GetUserDefaultGeoName(buf: [*]u16, size: i32) callconv(.winapi) i32;
extern "kernel32" fn GetUserPreferredUILanguages(flags: u32, count: *u32, buf: ?[*]u16, size: *u32) callconv(.winapi) w.BOOL;

/// The user's locale as a BCP 47 tag ("en-US"). Caller frees it.
pub fn locale(gpa: std.mem.Allocator) ![]u8 {
    var buf: [85]u16 = undefined;
    const n = GetUserDefaultLocaleName(&buf, buf.len);
    if (n <= 1) return gpa.dupe(u8, "en-US");
    return std.unicode.utf16LeToUtf8Alloc(gpa, buf[0..@intCast(n - 1)]);
}

/// The user's region, two letters ("US"), from Windows' location setting.
pub fn region(gpa: std.mem.Allocator) ![]u8 {
    var buf: [16]u16 = undefined;
    const n = GetUserDefaultGeoName(&buf, buf.len);
    if (n > 1) return std.unicode.utf16LeToUtf8Alloc(gpa, buf[0..@intCast(n - 1)]);
    const loc = try locale(gpa);
    defer gpa.free(loc);
    const dash = std.mem.lastIndexOfScalar(u8, loc, '-') orelse return gpa.dupe(u8, "");
    return gpa.dupe(u8, loc[dash + 1 ..]);
}

/// The user's display languages, most preferred first ("fr-FR", "en-US").
/// Free with `freeList`.
pub fn languages(gpa: std.mem.Allocator) ![][]u8 {
    var count: u32 = 0;
    var size: u32 = 0;
    // MUI_LANGUAGE_NAME
    if (GetUserPreferredUILanguages(0x8, &count, null, &size) == 0 or size == 0) return gpa.alloc([]u8, 0);
    const buf = try gpa.alloc(u16, size);
    defer gpa.free(buf);
    if (GetUserPreferredUILanguages(0x8, &count, buf.ptr, &size) == 0) return gpa.alloc([]u8, 0);
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeList(gpa, out.items);
    var it = std.mem.splitScalar(u16, buf[0..size], 0);
    while (it.next()) |l| if (l.len > 0) try out.append(gpa, try std.unicode.utf16LeToUtf8Alloc(gpa, l));
    return out.toOwnedSlice(gpa);
}

pub fn freeList(gpa: std.mem.Allocator, list: []const []u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

test "open at login: a Run value under a test key" {
    const gpa = std.testing.allocator;
    var tk: reg.TestKey = .{};
    tk.init();
    defer tk.cleanup();
    try std.testing.expect(!openAtLogin(gpa, tk.path(), "Notes", "C:\\Apps\\notes.exe"));
    try setOpenAtLogin(gpa, tk.path(), "Notes", "C:\\Apps\\notes.exe", true);
    try std.testing.expect(openAtLogin(gpa, tk.path(), "Notes", "C:\\Apps\\notes.exe"));
    try std.testing.expect(!openAtLogin(gpa, tk.path(), "Notes", "C:\\Other\\notes.exe"));
    try setOpenAtLogin(gpa, tk.path(), "Notes", "C:\\Apps\\notes.exe", false);
    try std.testing.expect(!openAtLogin(gpa, tk.path(), "Notes", "C:\\Apps\\notes.exe"));
}

test "a power request is made and released; the locale and region read" {
    const gpa = std.testing.allocator;
    const b = try preventSleep("myzig test", .system);
    b.release();
    const loc = try locale(gpa);
    defer gpa.free(loc);
    try std.testing.expect(loc.len >= 2);
    const r = try region(gpa);
    defer gpa.free(r);
    const langs = try languages(gpa);
    defer freeList(gpa, langs);
    try std.testing.expect(langs.len >= 1);
}
