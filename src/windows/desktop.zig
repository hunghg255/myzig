//! The desktop around the app on Windows: the clipboard (as UTF-16 text),
//! opening URLs and files with the shell, the known folders, the theme.
const std = @import("std");
const w = @import("win32.zig");

const CF_UNICODETEXT = 13;

pub const clipboard = struct {
    pub fn readText(gpa: std.mem.Allocator) !?[]u8 {
        if (w.OpenClipboard(null) == 0) return null;
        defer _ = w.CloseClipboard();
        const mem = w.GetClipboardData(CF_UNICODETEXT) orelse return null;
        const p: [*:0]const u16 = @ptrCast(@alignCast(w.GlobalLock(mem) orelse return null));
        defer _ = w.GlobalUnlock(mem);
        return try std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.span(p));
    }

    pub fn writeText(text: []const u8) void {
        const n = std.unicode.calcUtf16LeLen(text) catch return;
        // GMEM_MOVEABLE: the clipboard owns it once set.
        const mem = w.GlobalAlloc(0x0002, (n + 1) * 2) orelse return;
        const p: [*]u16 = @ptrCast(@alignCast(w.GlobalLock(mem) orelse return));
        _ = std.unicode.utf8ToUtf16Le(p[0..n], text) catch {};
        p[n] = 0;
        _ = w.GlobalUnlock(mem);
        if (w.OpenClipboard(null) == 0) return;
        defer _ = w.CloseClipboard();
        _ = w.EmptyClipboard();
        _ = w.SetClipboardData(CF_UNICODETEXT, mem);
    }

    pub fn changeCount() isize {
        return 0;
    }

    const extra = @import("clipboard.zig");
    /// The clipboard's image as PNG, or null. Caller frees it.
    pub const readImage = extra.readImage;
    /// Puts a PNG image on the clipboard.
    pub const writeImage = extra.writeImage;
    /// The paths of the files on the clipboard, or null. Free with `dialog.freePaths`.
    pub const readFiles = extra.readFiles;
    pub const writeFiles = extra.writeFiles;
    /// The clipboard's HTML, or null. Caller frees it.
    pub const readHtml = extra.readHtml;
    /// Puts HTML on the clipboard, with plain text for other apps.
    pub const writeHtml = extra.writeHtml;

    const transfer_data = @import("transfer_win.zig");
    /// Replaces the clipboard's contents with `transfer.Data`: its items'
    /// formats as other apps read them.
    pub const writeData = @import("clipboard_lazy.zig").writeData;
    /// The MIME types the clipboard offers (`transfer.text`, ...), asking
    /// for no bytes. Free with `transfer.freeFormats`.
    pub const formats = transfer_data.formats;
    /// The bytes of one MIME type on the clipboard, or null. Caller frees them.
    pub const read = transfer_data.read;
};

fn shellOpen(target: []const u8) bool {
    var buf: [4096]u16 = undefined;
    const r = w.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), w.wide(&buf, target), null, null, 1);
    return @intFromPtr(r) > 32;
}

pub const shell = struct {
    pub fn openUrl(url: []const u8) bool {
        return shellOpen(url);
    }

    pub fn openPath(file: []const u8) bool {
        return shellOpen(file);
    }

    pub fn showInFolder(file: []const u8) void {
        _ = shellOpen(std.fs.path.dirname(file) orelse file);
    }

    /// Moves the file or folder at `file` (relative to the working
    /// directory, or absolute) to the recycle bin. Never deletes it for
    /// good: false, leaving it, where it cannot go to the recycle bin (an
    /// item too big for it, a drive without one, as network shares and
    /// many removable drives are).
    pub fn trash(file: []const u8) bool {
        @import("trash.zig").trash(file) catch return false;
        return true;
    }

    pub fn beep() void {}
};

pub const Directory = enum { data, cache, home, documents, downloads, desktop, temp };

fn env(gpa: std.mem.Allocator, comptime name: []const u8) ?[]u8 {
    var buf: [1024]u16 = undefined;
    const n = w.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(name), &buf, buf.len);
    if (n == 0 or n >= buf.len) return null;
    return std.unicode.utf16LeToUtf8Alloc(gpa, buf[0..n]) catch null;
}

pub fn path(gpa: std.mem.Allocator, dir: Directory, app_name: []const u8) ![]u8 {
    // A headless run's are its own, in a temporary directory.
    if ((dir == .data or dir == .cache or dir == .downloads) and @import("../headless.zig").active()) {
        const temp = env(gpa, "TEMP") orelse try gpa.dupe(u8, "C:\\Windows\\Temp");
        defer gpa.free(temp);
        if (try @import("../headless.zig").path(gpa, @tagName(dir), app_name, temp)) |p| return p;
    }
    const home = env(gpa, "USERPROFILE") orelse try gpa.dupe(u8, "C:\\");
    defer gpa.free(home);
    const io = std.Io.Threaded.global_single_threaded.io();
    switch (dir) {
        .home => return gpa.dupe(u8, home),
        .temp => return env(gpa, "TEMP") orelse gpa.dupe(u8, "C:\\Windows\\Temp"),
        .documents => return std.fs.path.join(gpa, &.{ home, "Documents" }),
        .downloads => return std.fs.path.join(gpa, &.{ home, "Downloads" }),
        .desktop => return std.fs.path.join(gpa, &.{ home, "Desktop" }),
        .data, .cache => {
            const base = (if (dir == .data) env(gpa, "APPDATA") else env(gpa, "LOCALAPPDATA")) orelse try gpa.dupe(u8, home);
            defer gpa.free(base);
            const full = try std.fs.path.join(gpa, &.{ base, app_name });
            std.Io.Dir.cwd().createDirPath(io, full) catch {};
            return full;
        },
    }
}

/// Whether the app shows dark: the app's choice (`App.setAppearance`),
/// else whether apps are asked for dark colors (Settings > Personalization > Colors).
pub fn isDark() bool {
    return @import("../appearance.zig").dark(systemDark());
}

fn systemDark() bool {
    const v = @import("registry.zig").getNumber("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize", "AppsUseLightTheme") orelse return false;
    return v == 0;
}

pub fn accentColor() [3]f32 {
    return .{ 0, 0.47, 0.84 };
}
