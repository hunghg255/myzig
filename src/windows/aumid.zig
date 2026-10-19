//! The app's identity to the Windows shell: its AppUserModelID, set on
//! the process (the taskbar groups its windows by it, toasts name it),
//! and, for an app that is not packaged, the Start menu shortcut carrying
//! it (System.AppUserModel.ID), without which Windows shows none of the
//! app's toasts, and the CLSID of its toast activator
//! (System.AppUserModel.ToastActivatorCLSID), through which clicks reach
//! the app after it quit. Installers usually make the shortcut;
//! `ensureShortcut` makes it when there is none, or when it points at
//! another program.
const std = @import("std");
const w = @import("win32.zig");
const com = @import("com.zig");

extern "shell32" fn SetCurrentProcessExplicitAppUserModelID(id: [*:0]const u16) callconv(.winapi) com.HRESULT;
extern "kernel32" fn GetCurrentPackageFullName(len: *u32, name: ?[*]u16) callconv(.winapi) i32;
extern "kernel32" fn GetModuleFileNameW(module: ?*anyopaque, buf: [*]u16, size: u32) callconv(.winapi) u32;
extern "kernel32" fn GetFileAttributesW(path: [*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn DeleteFileW(path: [*:0]const u16) callconv(.winapi) w.BOOL;
extern "kernel32" fn CreateDirectoryW(path: [*:0]const u16, sa: ?*anyopaque) callconv(.winapi) w.BOOL;
extern "ole32" fn CoCreateInstance(clsid: *const com.GUID, outer: ?*anyopaque, ctx: u32, iid: *const com.GUID, out: *?com.Object) callconv(.winapi) com.HRESULT;
extern "ole32" fn PropVariantClear(v: *PROPVARIANT) callconv(.winapi) com.HRESULT;

const CLSID_ShellLink = com.GUID.parse("00021401-0000-0000-c000-000000000046");
const IID_IShellLinkW = com.GUID.parse("000214f9-0000-0000-c000-000000000046");
const IID_IPropertyStore = com.GUID.parse("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99");
const IID_IPersistFile = com.GUID.parse("0000010b-0000-0000-c000-000000000046");

const PROPERTYKEY = extern struct { fmtid: com.GUID, pid: u32 };
const PKEY_AppUserModel_ID: PROPERTYKEY = .{ .fmtid = com.GUID.parse("9f4c2855-9f79-4b39-a8d0-e1d42de1d5f3"), .pid = 5 };
const PKEY_AppUserModel_ToastActivatorCLSID: PROPERTYKEY = .{ .fmtid = com.GUID.parse("9f4c2855-9f79-4b39-a8d0-e1d42de1d5f3"), .pid = 26 };
const VT_LPWSTR = 31;
const VT_CLSID = 72;
/// PROPVARIANT holding a VT_LPWSTR or a VT_CLSID (a pointer either way).
const PROPVARIANT = extern struct { vt: u16 = VT_LPWSTR, r1: u16 = 0, r2: u16 = 0, r3: u16 = 0, ptr: ?*const anyopaque = null, pad: usize = 0 };

// IShellLinkW, IPropertyStore, IPersistFile.
const link_get_path = 3;
const link_set_description = 7;
const link_set_path = 20;
const store_get_value = 5;
const store_set_value = 6;
const store_commit = 7;
const persist_load = 5;
const persist_save = 6;

const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;
const APPMODEL_ERROR_NO_PACKAGE = 15700;

/// Sets the process's AppUserModelID: before the first window shows, so
/// that its taskbar button has it.
pub fn setForProcess(id: []const u8) bool {
    var buf: [130]u16 = undefined;
    return !com.failed(SetCurrentProcessExplicitAppUserModelID(w.wide(&buf, id)));
}

/// Whether the app runs from an MSIX package, which gives it an identity
/// (and its toasts) without a shortcut.
pub fn packaged() bool {
    var len: u32 = 0;
    return GetCurrentPackageFullName(&len, null) != APPMODEL_ERROR_NO_PACKAGE;
}

/// The path of the running program, in `buf`.
pub fn exePath(buf: *[1024]u16) []const u16 {
    const n = GetModuleFileNameW(null, buf, buf.len);
    return buf[0..@min(n, buf.len - 1)];
}

/// The Start menu's programs folder of the user (%APPDATA%\Microsoft\
/// Windows\Start Menu\Programs), UTF-8 in `gpa`; null without APPDATA.
pub fn startMenuPrograms(gpa: std.mem.Allocator) !?[]u8 {
    var buf: [1024]u16 = undefined;
    const n = w.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("APPDATA"), &buf, buf.len);
    if (n == 0 or n >= buf.len) return null;
    const base = try std.unicode.utf16LeToUtf8Alloc(gpa, buf[0..n]);
    defer gpa.free(base);
    return try std.fmt.allocPrint(gpa, "{s}\\Microsoft\\Windows\\Start Menu\\Programs", .{base});
}

/// The shortcut's file: `dir`\`name`.lnk, with characters a file name
/// cannot have replaced.
pub fn shortcutPath(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) ![:0]u16 {
    const clean = try gpa.dupe(u8, name);
    defer gpa.free(clean);
    for (clean) |*ch| if (std.mem.indexOfScalar(u8, "\\/:*?\"<>|", ch.*) != null or ch.* < 32) {
        ch.* = '_';
    };
    const path = try std.fmt.allocPrint(gpa, "{s}\\{s}.lnk", .{ dir, clean });
    defer gpa.free(path);
    return std.unicode.utf8ToUtf16LeAllocZ(gpa, path);
}

pub fn exists(path: [*:0]const u16) bool {
    return GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES;
}

/// What a shortcut says: its program and its AppUserModelID (UTF-16, in
/// `gpa`), and its toast activator's CLSID.
pub const Read = struct {
    target: []u16,
    id: []u16,
    activator: ?com.GUID = null,

    pub fn deinit(r: Read, gpa: std.mem.Allocator) void {
        gpa.free(r.target);
        gpa.free(r.id);
    }
};

fn shellLink() !com.Object {
    var out: ?com.Object = null;
    if (com.failed(CoCreateInstance(&CLSID_ShellLink, null, 1, &IID_IShellLinkW, &out))) return error.Com;
    return out orelse error.Com;
}

/// Reads the shortcut at `path`.
pub fn read(gpa: std.mem.Allocator, path: [*:0]const u16) !Read {
    const l = try shellLink();
    defer com.release(l);
    const file = com.query(l, &IID_IPersistFile) orelse return error.Com;
    defer com.release(file);
    if (com.failed(com.call(file, persist_load, .{ path, @as(u32, 0) }))) return error.NotFound; // STGM_READ
    var target: [1024]u16 = undefined;
    target[0] = 0;
    _ = com.call(l, link_get_path, .{ @as([*]u16, &target), @as(i32, target.len), @as(?*anyopaque, null), @as(u32, 0x4) }); // SLGP_RAWPATH
    const store = com.query(l, &IID_IPropertyStore) orelse return error.Com;
    defer com.release(store);
    var v: PROPVARIANT = .{ .vt = 0 };
    if (com.failed(com.call(store, store_get_value, .{ &PKEY_AppUserModel_ID, &v }))) return error.Com;
    defer _ = PropVariantClear(&v);
    const id: []const u16 = if (v.vt == VT_LPWSTR) if (v.ptr) |p| std.mem.span(@as([*:0]const u16, @ptrCast(@alignCast(p)))) else &.{} else &.{};
    var c: PROPVARIANT = .{ .vt = 0 };
    var activator: ?com.GUID = null;
    if (!com.failed(com.call(store, store_get_value, .{ &PKEY_AppUserModel_ToastActivatorCLSID, &c }))) {
        defer _ = PropVariantClear(&c);
        if (c.vt == VT_CLSID) if (c.ptr) |p| {
            activator = @as(*const com.GUID, @ptrCast(@alignCast(p))).*;
        };
    }
    const t = try gpa.dupe(u16, std.mem.sliceTo(&target, 0));
    errdefer gpa.free(t);
    return .{ .target = t, .id = try gpa.dupe(u16, id), .activator = activator };
}

/// Writes a shortcut at `path` to the program `exe`, carrying `id` (and
/// the CLSID of the app's toast activator).
pub fn write(gpa: std.mem.Allocator, path: [*:0]const u16, exe: []const u16, id: []const u8, activator: ?com.GUID, description: []const u8) !void {
    const l = try shellLink();
    defer com.release(l);
    const exe_z = try gpa.alloc(u16, exe.len + 1);
    defer gpa.free(exe_z);
    @memcpy(exe_z[0..exe.len], exe);
    exe_z[exe.len] = 0;
    if (com.failed(com.call(l, link_set_path, .{@as([*:0]const u16, @ptrCast(exe_z.ptr))}))) return error.Com;
    if (description.len > 0) {
        const d = try com.wide(gpa, description);
        defer gpa.free(d);
        _ = com.call(l, link_set_description, .{d.ptr});
    }
    const store = com.query(l, &IID_IPropertyStore) orelse return error.Com;
    defer com.release(store);
    const wid = try com.wide(gpa, id);
    defer gpa.free(wid);
    const v: PROPVARIANT = .{ .ptr = wid.ptr };
    if (com.failed(com.call(store, store_set_value, .{ &PKEY_AppUserModel_ID, &v }))) return error.Com;
    if (activator) |*clsid| {
        const c: PROPVARIANT = .{ .vt = VT_CLSID, .ptr = clsid };
        if (com.failed(com.call(store, store_set_value, .{ &PKEY_AppUserModel_ToastActivatorCLSID, &c }))) return error.Com;
    }
    if (com.failed(com.call(store, store_commit, .{}))) return error.Com;
    const file = com.query(l, &IID_IPersistFile) orelse return error.Com;
    defer com.release(file);
    if (com.failed(com.call(file, persist_save, .{ path, @as(w.BOOL, 1) }))) return error.Save;
}

pub const Ensured = enum { existed, created };

/// Makes sure `dir`\`name`.lnk runs this program with `id` (and
/// `activator`): writes it when missing or different.
pub fn ensureShortcut(gpa: std.mem.Allocator, dir: []const u8, name: []const u8, id: []const u8, activator: ?com.GUID) !Ensured {
    const path = try shortcutPath(gpa, dir, name);
    defer gpa.free(path);
    var exe_buf: [1024]u16 = undefined;
    const exe = exePath(&exe_buf);
    if (exists(path.ptr)) {
        if (read(gpa, path.ptr)) |r| {
            defer r.deinit(gpa);
            const wid = try com.wide(gpa, id);
            defer gpa.free(wid);
            const same_activator = if (activator) |a| (r.activator != null and r.activator.?.eql(a)) else r.activator == null;
            if (same_activator and std.mem.eql(u16, r.id, wid) and std.ascii.eqlIgnoreCase(std.mem.sliceAsBytes(r.target), std.mem.sliceAsBytes(exe))) return .existed;
        } else |_| {}
    } else {
        const dir_w = try com.wide(gpa, dir);
        defer gpa.free(dir_w);
        _ = CreateDirectoryW(dir_w.ptr, null);
    }
    try write(gpa, path.ptr, exe, id, activator, name);
    return .created;
}

/// Removes the shortcut `dir`\`name`.lnk.
pub fn removeShortcut(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) void {
    const path = shortcutPath(gpa, dir, name) catch return;
    defer gpa.free(path);
    _ = DeleteFileW(path.ptr);
}

test "a shortcut carries the app's id, made once, under a test name in %TEMP%" {
    if (@sizeOf(usize) == 8) try std.testing.expectEqual(@as(usize, 24), @sizeOf(PROPVARIANT));
    const gpa = std.testing.allocator;
    _ = com.CoInitializeEx(null, 0x2);
    var buf: [1024]u16 = undefined;
    const n = w.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("TEMP"), &buf, buf.len);
    if (n == 0) return error.SkipZigTest;
    const temp = try std.unicode.utf16LeToUtf8Alloc(gpa, buf[0..n]);
    defer gpa.free(temp);
    const name = "myzig-test-aumid: shortcut";
    const id = "com.myzig.test.aumid";
    defer removeShortcut(gpa, temp, name);
    try std.testing.expectEqual(Ensured.created, try ensureShortcut(gpa, temp, name, id, null));
    try std.testing.expectEqual(Ensured.existed, try ensureShortcut(gpa, temp, name, id, null));
    const path = try shortcutPath(gpa, temp, name);
    defer gpa.free(path);
    try std.testing.expect(std.mem.indexOf(u16, path, std.unicode.utf8ToUtf16LeStringLiteral("myzig-test-aumid_ shortcut.lnk")) != null);
    const r = try read(gpa, path.ptr);
    defer r.deinit(gpa);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral(id), r.id);
    try std.testing.expect(std.ascii.eqlIgnoreCase(std.mem.sliceAsBytes(r.target), std.mem.sliceAsBytes(exePath(&buf))));
    try std.testing.expect(r.activator == null);
    // The toast activator's CLSID: written again, then kept.
    const clsid = com.GUID.parse("0f1e2d3c-4b5a-5968-8776-a5b4c3d2e1f0");
    try std.testing.expectEqual(Ensured.created, try ensureShortcut(gpa, temp, name, id, clsid));
    try std.testing.expectEqual(Ensured.existed, try ensureShortcut(gpa, temp, name, id, clsid));
    const r2 = try read(gpa, path.ptr);
    defer r2.deinit(gpa);
    try std.testing.expect(r2.activator.?.eql(clsid));
    // Another id: written again.
    try std.testing.expectEqual(Ensured.created, try ensureShortcut(gpa, temp, name, "com.myzig.test.other", clsid));
    removeShortcut(gpa, temp, name);
    try std.testing.expect(!exists(path.ptr));
    try std.testing.expect(!packaged());
}
