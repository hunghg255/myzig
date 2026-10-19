//! The registry of the current user (HKEY_CURRENT_USER): strings and
//! numbers read and written, keys deleted with what they hold. URL
//! schemes, file types, the Run key and the theme live there.
const std = @import("std");
const w = @import("win32.zig");

pub const HKEY = *opaque {};
pub const HKCU: HKEY = @ptrFromInt(0x80000001);

extern "advapi32" fn RegSetKeyValueW(key: HKEY, sub: ?[*:0]const u16, name: ?[*:0]const u16, kind: u32, data: ?*const anyopaque, size: u32) callconv(.winapi) i32;
extern "advapi32" fn RegGetValueW(key: HKEY, sub: ?[*:0]const u16, name: ?[*:0]const u16, flags: u32, kind: ?*u32, data: ?*anyopaque, size: ?*u32) callconv(.winapi) i32;
extern "advapi32" fn RegDeleteTreeW(key: HKEY, sub: ?[*:0]const u16) callconv(.winapi) i32;
extern "advapi32" fn RegDeleteKeyValueW(key: HKEY, sub: ?[*:0]const u16, name: ?[*:0]const u16) callconv(.winapi) i32;

const REG_SZ = 1;
const REG_DWORD = 4;
const RRF_RT_REG_SZ = 0x2;
const RRF_RT_REG_DWORD = 0x10;
const ERROR_FILE_NOT_FOUND = 2;

/// Sets the string `name` (the key's default value when empty) of `key`,
/// creating the key.
pub fn setString(key: []const u8, name: []const u8, value: []const u8) !void {
    var kb: [512]u16 = undefined;
    var nb: [256]u16 = undefined;
    const v = try std.unicode.utf8ToUtf16LeAlloc(std.heap.page_allocator, value);
    defer std.heap.page_allocator.free(v);
    const terminated = try std.heap.page_allocator.alloc(u16, v.len + 1);
    defer std.heap.page_allocator.free(terminated);
    @memcpy(terminated[0..v.len], v);
    terminated[v.len] = 0;
    const r = RegSetKeyValueW(HKCU, w.wide(&kb, key), if (name.len > 0) w.wide(&nb, name) else null, REG_SZ, terminated.ptr, @intCast(terminated.len * 2));
    if (r != 0) return error.RegistryWrite;
}

pub fn setNumber(key: []const u8, name: []const u8, value: u32) !void {
    var kb: [512]u16 = undefined;
    var nb: [256]u16 = undefined;
    const r = RegSetKeyValueW(HKCU, w.wide(&kb, key), if (name.len > 0) w.wide(&nb, name) else null, REG_DWORD, &value, 4);
    if (r != 0) return error.RegistryWrite;
}

/// The string `name` of `key` (UTF-8), or null when there is none. Caller frees it.
pub fn getString(gpa: std.mem.Allocator, key: []const u8, name: []const u8) !?[]u8 {
    var kb: [512]u16 = undefined;
    var nb: [256]u16 = undefined;
    var buf: [2048]u16 = undefined;
    var size: u32 = @sizeOf(@TypeOf(buf));
    const r = RegGetValueW(HKCU, w.wide(&kb, key), if (name.len > 0) w.wide(&nb, name) else null, RRF_RT_REG_SZ, null, &buf, &size);
    if (r != 0) return null;
    var n: usize = size / 2;
    if (n > 0 and buf[n - 1] == 0) n -= 1;
    return try std.unicode.utf16LeToUtf8Alloc(gpa, buf[0..n]);
}

pub fn getNumber(key: []const u8, name: []const u8) ?u32 {
    var kb: [512]u16 = undefined;
    var nb: [256]u16 = undefined;
    var v: u32 = 0;
    var size: u32 = 4;
    const r = RegGetValueW(HKCU, w.wide(&kb, key), if (name.len > 0) w.wide(&nb, name) else null, RRF_RT_REG_DWORD, null, &v, &size);
    return if (r == 0) v else null;
}

/// Deletes `key` and everything under it; missing is fine.
pub fn deleteTree(key: []const u8) !void {
    var kb: [512]u16 = undefined;
    const r = RegDeleteTreeW(HKCU, w.wide(&kb, key));
    if (r != 0 and r != ERROR_FILE_NOT_FOUND) return error.RegistryDelete;
    // RegDeleteTreeW empties the key; the key itself goes with RegDeleteKeyW.
    _ = RegDeleteKeyW(HKCU, w.wide(&kb, key));
}

extern "advapi32" fn RegDeleteKeyW(key: HKEY, sub: [*:0]const u16) callconv(.winapi) i32;

/// Deletes the value `name` of `key`; missing is fine.
pub fn deleteValue(key: []const u8, name: []const u8) !void {
    var kb: [512]u16 = undefined;
    var nb: [256]u16 = undefined;
    const r = RegDeleteKeyValueW(HKCU, w.wide(&kb, key), w.wide(&nb, name));
    if (r != 0 and r != ERROR_FILE_NOT_FOUND) return error.RegistryDelete;
}

/// A key of its own under HKCU\Software for a test, deleted by `cleanup`.
pub const TestKey = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,

    pub fn init(k: *TestKey) void {
        var rnd: [4]u8 = undefined;
        std.Io.random(std.Io.Threaded.global_single_threaded.io(), &rnd);
        k.len = (std.fmt.bufPrint(&k.buf, "Software\\myzig-test-{x}", .{std.mem.readInt(u32, &rnd, .little)}) catch unreachable).len;
    }

    pub fn path(k: *const TestKey) []const u8 {
        return k.buf[0..k.len];
    }

    pub fn cleanup(k: *const TestKey) void {
        deleteTree(k.path()) catch {};
    }
};

test "strings and numbers written, read back and deleted under a test key" {
    const gpa = std.testing.allocator;
    var key: TestKey = .{};
    key.init();
    defer key.cleanup();
    var sub_buf: [128]u8 = undefined;
    const sub = try std.fmt.bufPrint(&sub_buf, "{s}\\a\\b", .{key.path()});
    try setString(sub, "", "héllo");
    try setString(sub, "Name", "x");
    try setNumber(sub, "N", 42);
    const v = (try getString(gpa, sub, "")).?;
    defer gpa.free(v);
    try std.testing.expectEqualStrings("héllo", v);
    try std.testing.expectEqual(@as(?u32, 42), getNumber(sub, "N"));
    try deleteValue(sub, "Name");
    try std.testing.expect((try getString(gpa, sub, "Name")) == null);
    try deleteTree(key.path());
    try std.testing.expect((try getString(gpa, sub, "")) == null);
}
