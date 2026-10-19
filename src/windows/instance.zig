//! A single instance on Windows: a named mutex is the lock, and the first
//! instance's hidden window, titled with the lock's name, receives later
//! instances' command lines (WM_COPYDATA).
const std = @import("std");
const w = @import("win32.zig");
const appwnd = @import("appwnd.zig");

extern "kernel32" fn CreateMutexW(attrs: ?*anyopaque, owner: w.BOOL, name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn CloseHandle(h: *anyopaque) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "user32" fn GetWindowThreadProcessId(hwnd: w.HWND, pid: ?*u32) callconv(.winapi) u32;
extern "user32" fn AllowSetForegroundWindow(pid: u32) callconv(.winapi) w.BOOL;

const ERROR_ALREADY_EXISTS = 183;
/// WM_COPYDATA's dwData for a later instance's command line ("MZ").
pub const copy_kind: usize = 0x4D5A;

pub const Lock = struct {
    mutex: *anyopaque,

    pub fn release(l: Lock) void {
        _ = CloseHandle(l.mutex);
    }
};

pub const Result = union(enum) {
    /// This is the first instance: it holds the lock until released.
    first: Lock,
    /// Another instance holds it and got `message`.
    forwarded,
};

/// Takes the lock named `name`, or hands `message` to the instance that
/// holds it (whose hidden window is titled `name`).
pub fn request(name: []const u8, message: []const u8) Result {
    var buf: [96]u16 = undefined;
    var full: [96]u8 = undefined;
    const qualified = std.fmt.bufPrint(&full, "Local\\{s}", .{name}) catch name;
    const mutex = CreateMutexW(null, 0, w.wide(&buf, qualified)) orelse return .{ .first = undefined };
    if (GetLastError() != ERROR_ALREADY_EXISTS) return .{ .first = .{ .mutex = mutex } };
    _ = CloseHandle(mutex);
    // The first instance may still be starting: its window comes soon.
    var attempt: u32 = 0;
    while (attempt < 20) : (attempt += 1) {
        if (appwnd.find(name)) |hwnd| {
            var pid: u32 = 0;
            _ = GetWindowThreadProcessId(hwnd, &pid);
            // It may bring its window to the front.
            _ = AllowSetForegroundWindow(pid);
            var cds: appwnd.COPYDATASTRUCT = .{ .dwData = copy_kind, .cbData = @intCast(message.len), .lpData = message.ptr };
            // SMTO_ABORTIFHUNG
            _ = appwnd.SendMessageTimeoutW(hwnd, appwnd.WM_COPYDATA, 0, @bitCast(@intFromPtr(&cds)), 0x0002, 5000, null);
            return .forwarded;
        }
        Sleep(50);
    }
    return .forwarded;
}

test "the first instance holds the lock; later ones hand their command line over" {
    const S = struct {
        got: [64]u8 = undefined,
        len: usize = 0,
        fn copy(ctx: *anyopaque, kind: usize, bytes: []const u8) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            if (kind != copy_kind) return;
            @memcpy(s.got[0..bytes.len], bytes);
            s.len = bytes.len;
        }
    };
    var s: S = .{};
    var name_buf: [48]u8 = undefined;
    var rnd: [4]u8 = undefined;
    std.Io.random(std.testing.io, &rnd);
    const name = try std.fmt.bufPrint(&name_buf, "myzig-test-{x}", .{std.mem.readInt(u32, &rnd, .little)});
    const first = request(name, "");
    try std.testing.expect(first == .first);
    defer first.first.release();
    const hooks: appwnd.Hooks = .{ .ctx = &s, .copy_data = S.copy };
    const hwnd = try appwnd.create(name, &hooks);
    defer appwnd.destroy(hwnd);
    try std.testing.expect(request(name, "/tmp\x00a.md\x00") == .forwarded);
    try std.testing.expectEqualStrings("/tmp\x00a.md\x00", s.got[0..s.len]);
}
