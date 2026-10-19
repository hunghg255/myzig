//! URL schemes and file types on Windows, registered for the current user
//! under HKEY_CURRENT_USER\Software\Classes: the scheme's (or the file
//! type's ProgID's) shell\open\command runs the executable with the URL or
//! the file as its argument, which the app gets as a launch argument (or
//! from a later instance, with the single instance lock).
const std = @import("std");
const w = @import("win32.zig");
const reg = @import("registry.zig");

extern "kernel32" fn GetModuleFileNameW(module: ?w.HINSTANCE, buf: [*]u16, size: u32) callconv(.winapi) u32;
extern "shell32" fn SHChangeNotify(event: i32, flags: u32, a: ?*const anyopaque, b: ?*const anyopaque) callconv(.winapi) void;

/// Where classes are registered: the user's, or a test's own key.
pub const default_root = "Software\\Classes";

/// The path of the running executable. Caller frees it.
pub fn executable(gpa: std.mem.Allocator) ![]u8 {
    var buf: [32768]u16 = undefined;
    const n = GetModuleFileNameW(null, &buf, buf.len);
    if (n == 0) return error.NoExecutable;
    return std.unicode.utf16LeToUtf8Alloc(gpa, buf[0..n]);
}

/// `"exe" "%1"`: the command that opens a URL or file with `exe`.
pub fn openCommand(gpa: std.mem.Allocator, exe: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "\"{s}\" \"%1\"", .{exe});
}

fn key(buf: []u8, root: []const u8, parts: []const []const u8) ![]const u8 {
    var wr: std.Io.Writer = .fixed(buf);
    try wr.writeAll(root);
    for (parts) |p| {
        try wr.writeByte('\\');
        try wr.writeAll(p);
    }
    return wr.buffered();
}

/// Makes `exe` the handler of `scheme`'s URLs.
pub fn registerScheme(gpa: std.mem.Allocator, root: []const u8, scheme: []const u8, app_name: []const u8, exe: []const u8) !void {
    const cmd = try openCommand(gpa, exe);
    defer gpa.free(cmd);
    var kb: [512]u8 = undefined;
    var vb: [512]u8 = undefined;
    try reg.setString(try key(&kb, root, &.{scheme}), "", try std.fmt.bufPrint(&vb, "URL:{s}", .{app_name}));
    try reg.setString(try key(&kb, root, &.{scheme}), "URL Protocol", "");
    try reg.setString(try key(&kb, root, &.{ scheme, "DefaultIcon" }), "", try std.fmt.bufPrint(&vb, "\"{s}\",0", .{exe}));
    try reg.setString(try key(&kb, root, &.{ scheme, "shell", "open", "command" }), "", cmd);
}

/// Whether `exe` handles `scheme`'s URLs.
pub fn isSchemeRegistered(gpa: std.mem.Allocator, root: []const u8, scheme: []const u8, exe: []const u8) bool {
    const cmd = openCommand(gpa, exe) catch return false;
    defer gpa.free(cmd);
    var kb: [512]u8 = undefined;
    const got = (reg.getString(gpa, key(&kb, root, &.{ scheme, "shell", "open", "command" }) catch return false, "") catch return false) orelse return false;
    defer gpa.free(got);
    return std.ascii.eqlIgnoreCase(got, cmd);
}

/// Removes the scheme's registration if it is `exe`'s (not another app's).
pub fn unregisterScheme(gpa: std.mem.Allocator, root: []const u8, scheme: []const u8, exe: []const u8) !void {
    if (!isSchemeRegistered(gpa, root, scheme, exe)) return;
    var kb: [512]u8 = undefined;
    try reg.deleteTree(try key(&kb, root, &.{scheme}));
}

/// Lets `exe` open files of `ext` ("md"): a ProgID ("<prog_id>") with its
/// open command, offered in the extension's Open with list (the user
/// picks the default app on Windows 10 and later).
pub fn registerFileType(gpa: std.mem.Allocator, root: []const u8, ext: []const u8, prog_id: []const u8, description: []const u8, exe: []const u8) !void {
    const cmd = try openCommand(gpa, exe);
    defer gpa.free(cmd);
    var kb: [512]u8 = undefined;
    var vb: [512]u8 = undefined;
    var eb: [64]u8 = undefined;
    const dotted = try std.fmt.bufPrint(&eb, ".{s}", .{if (ext.len > 0 and ext[0] == '.') ext[1..] else ext});
    try reg.setString(try key(&kb, root, &.{prog_id}), "", description);
    try reg.setString(try key(&kb, root, &.{ prog_id, "DefaultIcon" }), "", try std.fmt.bufPrint(&vb, "\"{s}\",0", .{exe}));
    try reg.setString(try key(&kb, root, &.{ prog_id, "shell", "open", "command" }), "", cmd);
    try reg.setString(try key(&kb, root, &.{ dotted, "OpenWithProgids" }), prog_id, "");
    if (std.mem.eql(u8, root, default_root)) SHChangeNotify(0x08000000, 0, null, null); // SHCNE_ASSOCCHANGED
}

pub fn unregisterFileType(root: []const u8, ext: []const u8, prog_id: []const u8) !void {
    var kb: [512]u8 = undefined;
    var eb: [64]u8 = undefined;
    const dotted = try std.fmt.bufPrint(&eb, ".{s}", .{if (ext.len > 0 and ext[0] == '.') ext[1..] else ext});
    try reg.deleteValue(try key(&kb, root, &.{ dotted, "OpenWithProgids" }), prog_id);
    try reg.deleteTree(try key(&kb, root, &.{prog_id}));
    if (std.mem.eql(u8, root, default_root)) SHChangeNotify(0x08000000, 0, null, null);
}

test "URL schemes and file types registered under a test key, then removed" {
    const gpa = std.testing.allocator;
    var tk: reg.TestKey = .{};
    tk.init();
    defer tk.cleanup();
    var rb: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&rb, "{s}\\Classes", .{tk.path()});
    const exe = try executable(gpa);
    defer gpa.free(exe);
    try std.testing.expect(!isSchemeRegistered(gpa, root, "myzig-test", exe));
    try registerScheme(gpa, root, "myzig-test", "Test", exe);
    try std.testing.expect(isSchemeRegistered(gpa, root, "myzig-test", exe));
    try std.testing.expect(!isSchemeRegistered(gpa, root, "myzig-test", "C:\\other.exe"));
    var kb: [256]u8 = undefined;
    const proto = (try reg.getString(gpa, try key(&kb, root, &.{"myzig-test"}), "URL Protocol")).?;
    gpa.free(proto);
    // Another app's registration stays.
    try unregisterScheme(gpa, root, "myzig-test", "C:\\other.exe");
    try std.testing.expect(isSchemeRegistered(gpa, root, "myzig-test", exe));
    try unregisterScheme(gpa, root, "myzig-test", exe);
    try std.testing.expect(!isSchemeRegistered(gpa, root, "myzig-test", exe));

    try registerFileType(gpa, root, "mzt", "MyZig.Test.mzt", "Test Document", exe);
    const cmd = (try reg.getString(gpa, try key(&kb, root, &.{ "MyZig.Test.mzt", "shell", "open", "command" }), "")).?;
    defer gpa.free(cmd);
    try std.testing.expect(std.mem.endsWith(u8, cmd, "\" \"%1\""));
    const listed = (try reg.getString(gpa, try key(&kb, root, &.{ ".mzt", "OpenWithProgids" }), "MyZig.Test.mzt")).?;
    gpa.free(listed);
    try unregisterFileType(root, "mzt", "MyZig.Test.mzt");
    try std.testing.expect((try reg.getString(gpa, try key(&kb, root, &.{ ".mzt", "OpenWithProgids" }), "MyZig.Test.mzt")) == null);
}
