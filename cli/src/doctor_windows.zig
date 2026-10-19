//! The WebView2 Runtime, found as myzig's backend finds it
//! (src/windows/webview2.zig): a fixed version named by
//! WEBVIEW2_BROWSER_EXECUTABLE_FOLDER, else the installed channels that
//! EdgeUpdate records, most stable first, whose files are there.
const std = @import("std");
const fsx = @import("fsx.zig");
const Ctx = fsx.Ctx;

const HKEY = *opaque {};
const hkey_current_user: HKEY = @ptrFromInt(0x80000001);
const hkey_local_machine: HKEY = @ptrFromInt(0x80000002);
extern "advapi32" fn RegOpenKeyExW(key: HKEY, sub: [*:0]const u16, opts: u32, sam: u32, out: *?HKEY) callconv(.winapi) i32;
extern "advapi32" fn RegQueryValueExW(key: HKEY, name: [*:0]const u16, reserved: ?*u32, typ: ?*u32, data: ?[*]u8, size: *u32) callconv(.winapi) i32;
extern "advapi32" fn RegCloseKey(key: HKEY) callconv(.winapi) i32;

const channels = [_]struct { []const u8, []const u8 }{
    .{ "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}", "stable" },
    .{ "{2CD8A007-E189-409D-A2C8-9AF4EF3C72AA}", "beta" },
    .{ "{0D50BFEC-CD6A-4F9A-964C-C7416E3ACB10}", "dev" },
    .{ "{65C35B14-6C1D-4122-AC46-7148CC9D6497}", "canary" },
};

/// A string value of the registry's 32-bit view, where EdgeUpdate records
/// its clients.
fn regString(ctx: Ctx, machine: bool, path: []const u8, name: []const u8) ?[]u8 {
    const p = std.unicode.utf8ToUtf16LeAllocZ(ctx.gpa, path) catch return null;
    const n = std.unicode.utf8ToUtf16LeAllocZ(ctx.gpa, name) catch return null;
    var key: ?HKEY = null;
    // KEY_QUERY_VALUE | KEY_WOW64_32KEY
    if (RegOpenKeyExW(if (machine) hkey_local_machine else hkey_current_user, p, 0, 0x0001 | 0x0200, &key) != 0) return null;
    defer _ = RegCloseKey(key.?);
    var buf: [1024]u16 = undefined;
    var size: u32 = buf.len * 2;
    if (RegQueryValueExW(key.?, n, null, null, @ptrCast(&buf), &size) != 0 or size < 2) return null;
    var len: usize = size / 2;
    while (len > 0 and buf[len - 1] == 0) len -= 1;
    return std.unicode.utf16LeToUtf8Alloc(ctx.gpa, buf[0..len]) catch null;
}

/// Whether `dir` holds a runtime: its browser process and client library.
fn runtimeIn(ctx: Ctx, dir: []const u8) bool {
    const arch = if (@import("builtin").cpu.arch == .aarch64) "arm64" else "x64";
    const exe = ctx.join(&.{ dir, "msedgewebview2.exe" }) catch return false;
    const dll = ctx.join(&.{ dir, "EBWebView", arch, "EmbeddedBrowserWebView.dll" }) catch return false;
    return fsx.exists(ctx.io, exe) and fsx.exists(ctx.io, dll);
}

/// The runtime's directory and channel, or null when there is none.
pub fn webview2(ctx: Ctx) ?[]const u8 {
    if (ctx.env.get("WEBVIEW2_BROWSER_EXECUTABLE_FOLDER")) |fixed| {
        if (runtimeIn(ctx, fixed)) return ctx.fmt("{s} (fixed version)", .{fixed}) catch null;
        return null;
    }
    for (channels) |ch| for ([_]bool{ true, false }) |machine| {
        const path = ctx.fmt("SOFTWARE\\Microsoft\\EdgeUpdate\\ClientState\\{s}", .{ch[0]}) catch continue;
        const dir = regString(ctx, machine, path, "EBWebView") orelse continue;
        if (runtimeIn(ctx, dir)) return ctx.fmt("{s} ({s})", .{ dir, ch[1] }) catch null;
    };
    return null;
}
