//! Dialogs on Windows: message boxes and the common file dialogs (the
//! Explorer's open dialog, `filedialog.zig`, first), modal
//! on the main thread.
const std = @import("std");
const w = @import("win32.zig");
const dialog_types = @import("../dialog_types.zig");

pub const OpenOptions = dialog_types.OpenOptions;
pub const SaveOptions = dialog_types.SaveOptions;
pub const MessageKind = dialog_types.MessageKind;
pub const MessageOptions = dialog_types.MessageOptions;
pub const MessageResult = dialog_types.MessageResult;
pub const freePaths = dialog_types.freePaths;

const BROWSEINFOW = extern struct {
    hwndOwner: ?*anyopaque = null,
    pidlRoot: ?*anyopaque = null,
    pszDisplayName: ?[*]u16 = null,
    lpszTitle: ?[*:0]const u16 = null,
    ulFlags: u32 = 0,
    lpfn: ?*anyopaque = null,
    lParam: isize = 0,
    iImage: i32 = 0,
};
extern "shell32" fn SHBrowseForFolderW(bi: *BROWSEINFOW) callconv(.winapi) ?*anyopaque;
extern "shell32" fn SHGetPathFromIDListW(pidl: ?*anyopaque, path: [*]u16) callconv(.winapi) i32;
extern "ole32" fn CoTaskMemFree(p: ?*anyopaque) callconv(.winapi) void;
extern "user32" fn GetActiveWindow() callconv(.winapi) ?*anyopaque;

/// A folder, with the shell's folder browser (folders only, an edit box,
/// a New Folder button).
fn openFolder(gpa: std.mem.Allocator, opts: OpenOptions) !?[][]u8 {
    var name: [260]u16 = @splat(0);
    var title: [256]u16 = undefined;
    var bi: BROWSEINFOW = .{
        .hwndOwner = GetActiveWindow(),
        .pszDisplayName = &name,
        .lpszTitle = if (opts.title.len > 0) w.wide(&title, opts.title) else null,
        // Only file system folders, an edit box, the new dialog style.
        .ulFlags = 0x0001 | 0x0010 | 0x0040,
    };
    const pidl = SHBrowseForFolderW(&bi) orelse return null;
    defer CoTaskMemFree(pidl);
    var path: [1024]u16 = @splat(0);
    if (SHGetPathFromIDListW(pidl, &path) == 0) return null;
    const out = try gpa.alloc([]u8, 1);
    errdefer gpa.free(out);
    out[0] = try std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.sliceTo(&path, 0));
    return out;
}

pub fn open(gpa: std.mem.Allocator, opts: OpenOptions) !?[][]u8 {
    // The Explorer's dialog; the older ones where COM can't make it.
    switch (try @import("filedialog.zig").open(gpa, opts)) {
        .chosen => |paths| return paths,
        .cancelled => return null,
        .unavailable => {},
    }
    if (opts.directories and !opts.files) return openFolder(gpa, opts);
    var file: [4096]u16 = @splat(0);
    var title: [256]u16 = undefined;
    var ofn: w.OPENFILENAMEW = .{ .lpstrFile = &file, .nMaxFile = file.len, .lpstrTitle = if (opts.title.len > 0) w.wide(&title, opts.title) else null, .Flags = 0x00080000 | 0x00001000 }; // explorer, file must exist
    if (w.GetOpenFileNameW(&ofn) == 0) return null;
    const out = try gpa.alloc([]u8, 1);
    errdefer gpa.free(out);
    out[0] = try std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.sliceTo(&file, 0));
    return out;
}

pub fn save(gpa: std.mem.Allocator, opts: SaveOptions) !?[]u8 {
    var file: [4096]u16 = @splat(0);
    _ = w.wide(&file, opts.name);
    var title: [256]u16 = undefined;
    var ofn: w.OPENFILENAMEW = .{ .lpstrFile = &file, .nMaxFile = file.len, .lpstrTitle = if (opts.title.len > 0) w.wide(&title, opts.title) else null, .Flags = 0x00080000 | 0x00000002 }; // explorer, ask to overwrite
    if (w.GetSaveFileNameW(&ofn) == 0) return null;
    return try std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.sliceTo(&file, 0));
}

/// A message box: OK, OK/Cancel or Yes/No/Cancel for one to three buttons
/// (the labels are the system's).
pub fn message(opts: MessageOptions) MessageResult {
    var text: [2048]u16 = undefined;
    var buf: [1024]u8 = undefined;
    const body = if (opts.detail.len > 0) std.fmt.bufPrint(&buf, "{s}\n\n{s}", .{ opts.title, opts.detail }) catch opts.title else opts.title;
    const icon: u32 = switch (opts.kind) {
        .info => 0x40,
        .warning => 0x30,
        .critical => 0x10,
    };
    const n = opts.buttons.len;
    const kind: u32 = if (n >= 3) 3 else if (n == 2) 1 else 0;
    const r = w.MessageBoxW(null, w.wide(&text, body), std.unicode.utf8ToUtf16LeStringLiteral("myzig"), kind | icon);
    // IDOK 1, IDCANCEL 2, IDYES 6, IDNO 7.
    const button: usize = switch (r) {
        1, 6 => 0,
        7 => 1,
        2 => if (n >= 3) 2 else 1,
        else => 0,
    };
    return .{ .button = button };
}
