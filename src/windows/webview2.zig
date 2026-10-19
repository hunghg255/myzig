//! The Microsoft Edge WebView2 Runtime: found as WebView2Loader.dll finds
//! it (a fixed version named by WEBVIEW2_BROWSER_EXECUTABLE_FOLDER, else
//! the installed channels, most stable first), and the one environment
//! every page's web view comes from, created once, on first use.
const std = @import("std");
const builtin = @import("builtin");
const com = @import("com.zig");

pub const download = "https://go.microsoft.com/fwlink/p/?LinkId=2124703";

const channels = [_][]const u8{
    "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}", // Stable (Evergreen)
    "{2CD8A007-E189-409D-A2C8-9AF4EF3C72AA}", // Beta
    "{0D50BFEC-CD6A-4F9A-964C-C7416E3ACB10}", // Dev
    "{65C35B14-6C1D-4122-AC46-7148CC9D6497}", // Canary
};

const arch_dir = switch (builtin.cpu.arch) {
    .aarch64 => "arm64",
    .x86 => "x86",
    else => "x64",
};

const HKEY = *opaque {};
const hkey_current_user: HKEY = @ptrFromInt(0x80000001);
const hkey_local_machine: HKEY = @ptrFromInt(0x80000002);
extern "advapi32" fn RegOpenKeyExW(key: HKEY, sub: [*:0]const u16, opts: u32, sam: u32, out: *?HKEY) callconv(.winapi) i32;
extern "advapi32" fn RegQueryValueExW(key: HKEY, name: [*:0]const u16, reserved: ?*u32, typ: ?*u32, data: ?[*]u8, size: *u32) callconv(.winapi) i32;
extern "advapi32" fn RegCloseKey(key: HKEY) callconv(.winapi) i32;
extern "kernel32" fn GetFileAttributesW(path: [*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn LoadLibraryW(path: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetModuleFileNameW(module: ?*anyopaque, buf: [*]u16, n: u32) callconv(.winapi) u32;

/// A string value of the 32-bit view of the registry, where EdgeUpdate
/// records its clients, as UTF-16 in `buf`.
fn regString(machine: bool, path: []const u8, name: []const u8, buf: []u16) ?[]const u16 {
    var p: [256]u16 = undefined;
    var n: [64]u16 = undefined;
    const pl = std.unicode.utf8ToUtf16Le(&p, path) catch return null;
    p[pl] = 0;
    const nl = std.unicode.utf8ToUtf16Le(&n, name) catch return null;
    n[nl] = 0;
    var key: ?HKEY = null;
    if (RegOpenKeyExW(if (machine) hkey_local_machine else hkey_current_user, p[0..pl :0], 0, 0x0001 | 0x0200, &key) != 0) return null;
    defer _ = RegCloseKey(key.?);
    var size: u32 = @intCast(buf.len * 2);
    var typ: u32 = 0;
    if (RegQueryValueExW(key.?, n[0..nl :0], null, &typ, @ptrCast(buf.ptr), &size) != 0 or size < 2) return null;
    var len: usize = size / 2;
    while (len > 0 and buf[len - 1] == 0) len -= 1;
    return buf[0..len];
}

fn exists(path: []const u16) bool {
    var z: [1024]u16 = undefined;
    if (path.len >= z.len) return false;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    return GetFileAttributesW(z[0..path.len :0]) != 0xFFFFFFFF;
}

/// The runtime's client library in `dir` (UTF-16), written to `out`, or
/// null when `dir` holds no runtime: its browser process must be there
/// too, as Edge keeps a library of the name beside itself that fails.
fn clientDll(dir: []const u16, out: []u16) ?[:0]const u16 {
    const exe = std.unicode.utf8ToUtf16LeStringLiteral("\\msedgewebview2.exe");
    const dll = std.unicode.utf8ToUtf16LeStringLiteral("\\EBWebView\\" ++ arch_dir ++ "\\EmbeddedBrowserWebView.dll");
    if (dir.len + dll.len + 1 > out.len) return null;
    @memcpy(out[0..dir.len], dir);
    @memcpy(out[dir.len..][0..exe.len], exe);
    if (!exists(out[0 .. dir.len + exe.len])) return null;
    @memcpy(out[dir.len..][0..dll.len], dll);
    out[dir.len + dll.len] = 0;
    if (!exists(out[0 .. dir.len + dll.len])) return null;
    return out[0 .. dir.len + dll.len :0];
}

pub const Found = struct {
    /// The client library to load.
    dll: [:0]const u16,
    /// A fixed version runtime rather than an installed one.
    fixed: bool,
};

/// Finds the runtime; its library's path is written into `buf`.
pub fn find(environ: *const std.process.Environ.Map, buf: []u16) ?Found {
    if (environ.get("WEBVIEW2_BROWSER_EXECUTABLE_FOLDER")) |fixed| {
        var d: [512]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&d, fixed) catch return null;
        const dll = clientDll(d[0..n], buf) orelse return null;
        return .{ .dll = dll, .fixed = true };
    }
    var value: [512]u16 = undefined;
    for (channels) |channel| for ([_]bool{ true, false }) |machine| {
        var path: [128]u8 = undefined;
        const p = std.fmt.bufPrint(&path, "SOFTWARE\\Microsoft\\EdgeUpdate\\ClientState\\{s}", .{channel}) catch continue;
        const dir = regString(machine, p, "EBWebView", &value) orelse continue;
        if (clientDll(dir, buf)) |dll| return .{ .dll = dll, .fixed = false };
    };
    return null;
}

/// Whether a page can have a web view: a loader beside the executable,
/// or a runtime found.
pub fn available(environ: *const std.process.Environ.Map) bool {
    if (loaderProc() != null) return true;
    var buf: [1024]u16 = undefined;
    return find(environ, &buf) != null;
}

const CreateWithOptions = *const fn (folder: ?*anyopaque, user_data: ?[*:0]const u16, options: ?*anyopaque, handler: com.Object) callconv(.winapi) com.HRESULT;
const CreateInternal = *const fn (check: u32, runtime_type: u32, user_data: ?[*:0]const u16, options: ?*anyopaque, handler: com.Object) callconv(.winapi) com.HRESULT;

/// The official loader's entry point, beside the executable, if any.
fn loaderProc() ?CreateWithOptions {
    var path: [1024]u16 = undefined;
    const n = GetModuleFileNameW(null, &path, path.len);
    if (n == 0 or n >= path.len) return null;
    var end: usize = n;
    while (end > 0 and path[end - 1] != '\\') end -= 1;
    const name = std.unicode.utf8ToUtf16LeStringLiteral("WebView2Loader.dll");
    if (end + name.len + 1 > path.len) return null;
    @memcpy(path[end..][0..name.len], name);
    path[end + name.len] = 0;
    if (!exists(path[0 .. end + name.len])) return null;
    const lib = LoadLibraryW(path[0 .. end + name.len :0]) orelse return null;
    return @ptrCast(@alignCast(GetProcAddress(lib, "CreateCoreWebView2EnvironmentWithOptions") orelse return null));
}

/// The environment, once created, and those waiting for it.
pub const Environment = struct {
    env: ?com.Object = null,
    failed: bool = false,
    started: bool = false,
    waiters: std.ArrayList(Waiter) = .empty,
    gpa: std.mem.Allocator = std.heap.page_allocator,

    pub const Waiter = struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque, env: ?com.Object) void };

    /// Calls `w` with the environment (null if there is none), at once if
    /// it exists, else once it is created; creating it if it was not.
    pub fn get(e: *Environment, environ: *const std.process.Environ.Map, user_data: []const u8, w: Waiter) void {
        if (e.env != null or e.failed) return w.func(w.ctx, e.env);
        e.waiters.append(e.gpa, w) catch return w.func(w.ctx, null);
        if (e.started) return;
        e.started = true;
        const hr = e.start(environ, user_data);
        if (com.failed(hr)) {
            std.log.err("myzig: cannot create the WebView2 environment (HRESULT 0x{x:0>8}); get the runtime from {s}", .{ @as(u32, @bitCast(hr)), download });
            e.finish(null);
        }
    }

    fn start(e: *Environment, environ: *const std.process.Environ.Map, user_data: []const u8) com.HRESULT {
        const dir = com.wide(e.gpa, user_data) catch return com.E_FAIL;
        defer e.gpa.free(dir);
        if (loaderProc()) |create| return com.withHandler(e, completed, create, .{ null, dir.ptr, null });
        var buf: [1024]u16 = undefined;
        const found = find(environ, &buf) orelse return com.E_FAIL;
        const lib = LoadLibraryW(found.dll) orelse return com.E_FAIL;
        const create: CreateInternal = @ptrCast(@alignCast(GetProcAddress(lib, "CreateWebViewEnvironmentWithOptionsInternal") orelse return com.E_FAIL));
        return com.withHandler(e, completed, create, .{ @as(u32, 1), @as(u32, if (found.fixed) 1 else 0), dir.ptr, null });
    }

    fn completed(ctx: ?*anyopaque, hr: usize, env: usize) void {
        const e: *Environment = @ptrCast(@alignCast(ctx));
        const result: com.HRESULT = @bitCast(@as(u32, @truncate(hr)));
        if (com.failed(result) or env == 0) {
            std.log.err("myzig: creating the WebView2 environment failed (HRESULT 0x{x:0>8})", .{@as(u32, @bitCast(result))});
            return e.finish(null);
        }
        const obj: com.Object = @ptrFromInt(env);
        com.addRef(obj);
        e.finish(obj);
    }

    fn finish(e: *Environment, env: ?com.Object) void {
        e.env = env;
        e.failed = env == null;
        const waiting = e.waiters.toOwnedSlice(e.gpa) catch &.{};
        defer e.gpa.free(waiting);
        for (waiting) |w| w.func(w.ctx, env);
    }
};

pub var environment: Environment = .{};
