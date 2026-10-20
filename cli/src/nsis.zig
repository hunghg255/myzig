//! The Windows installer's NSIS script (after mygo's nsis.go): a per-user
//! install in %LOCALAPPDATA%\Programs, a Start menu shortcut, a desktop
//! shortcut the finish page offers, file associations and URL schemes, and
//! an uninstaller that Settings > Apps lists. `myzig build` compiles it
//! with makensis when it is installed.
const std = @import("std");
const Config = @import("config.zig").Config;

/// Escapes text for an NSIS string in double quotes.
pub fn escape(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '$' => try w.writeAll("$$"),
        '"' => try w.writeAll("$\\\""),
        '\n' => try w.writeAll("$\\n"),
        '\r' => try w.writeAll("$\\r"),
        '\t' => try w.writeAll("$\\t"),
        else => try w.writeByte(c),
    };
}

fn quoted(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    try escape(w, s);
    try w.writeByte('"');
}

pub const Files = struct {
    /// Absolute paths of the app's files and directories to install.
    paths: []const []const u8,
    /// The executable's file name.
    exe: []const u8,
    /// The installer's file, its icon (an .ico) or "".
    out: []const u8,
    ico: []const u8 = "",
};

/// "<Name> Setup <version> <arch>.exe".
pub fn installerName(gpa: std.mem.Allocator, name: []const u8, version: []const u8, arch: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s} Setup {s} {s}.exe", .{ name, version, arch });
}

pub fn script(gpa: std.mem.Allocator, c: Config, dir_name: []const u8, f: Files, dirs: []const bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    const key = try std.fmt.allocPrint(gpa, "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{s}", .{c.identifier});
    defer gpa.free(key);
    try w.writeAll("Unicode true\nManifestDPIAware true\nSetCompressor /SOLID lzma\nName ");
    try quoted(w, c.name);
    try w.writeAll("\nOutFile ");
    try quoted(w, f.out);
    try w.writeAll("\nInstallDir \"$LOCALAPPDATA\\Programs\\");
    try escape(w, dir_name);
    try w.writeAll("\"\nRequestExecutionLevel user\nBrandingText \" \"\n");
    if (f.ico.len > 0) {
        try w.writeAll("!define MUI_ICON ");
        try quoted(w, f.ico);
        try w.writeAll("\n!define MUI_UNICON ");
        try quoted(w, f.ico);
        try w.writeByte('\n');
    }
    try w.writeAll("!define MUI_FINISHPAGE_RUN \"$INSTDIR\\");
    try escape(w, f.exe);
    try w.writeAll(
        \\"
        \\!define MUI_FINISHPAGE_SHOWREADME
        \\!define MUI_FINISHPAGE_SHOWREADME_TEXT "Create a desktop shortcut"
        \\!define MUI_FINISHPAGE_SHOWREADME_FUNCTION CreateDesktopShortcut
        \\!include "MUI2.nsh"
        \\!insertmacro MUI_PAGE_DIRECTORY
        \\!insertmacro MUI_PAGE_INSTFILES
        \\!insertmacro MUI_PAGE_FINISH
        \\!insertmacro MUI_UNPAGE_CONFIRM
        \\!insertmacro MUI_UNPAGE_INSTFILES
        \\!insertmacro MUI_LANGUAGE "English"
        \\
        \\Section
        \\  SetOutPath "$INSTDIR"
        \\
    );
    for (f.paths, dirs) |p, is_dir| {
        try w.writeAll(if (is_dir) "  File /r " else "  File ");
        try quoted(w, p);
        try w.writeByte('\n');
    }
    try w.writeAll("  WriteUninstaller \"$INSTDIR\\Uninstall.exe\"\n  CreateShortCut \"$SMPROGRAMS\\");
    try escape(w, dir_name);
    try w.writeAll(".lnk\" \"$INSTDIR\\");
    try escape(w, f.exe);
    try w.writeAll("\"\n");
    const values = [_][2][]const u8{
        .{ "DisplayName", c.name },
        .{ "DisplayVersion", c.version },
    };
    for (values) |v| {
        try w.writeAll("  WriteRegStr HKCU ");
        try quoted(w, key);
        try w.print(" \"{s}\" ", .{v[0]});
        try quoted(w, v[1]);
        try w.writeByte('\n');
    }
    const raw = [_][2][]const u8{
        .{ "DisplayIcon", "\"$INSTDIR\\EXE\"" },
        .{ "InstallLocation", "\"$INSTDIR\"" },
        .{ "UninstallString", "'\"$INSTDIR\\Uninstall.exe\"'" },
        .{ "QuietUninstallString", "'\"$INSTDIR\\Uninstall.exe\" /S'" },
    };
    for (raw) |v| {
        try w.writeAll("  WriteRegStr HKCU ");
        try quoted(w, key);
        try w.print(" \"{s}\" ", .{v[0]});
        if (std.mem.indexOf(u8, v[1], "EXE")) |i| {
            try w.writeAll(v[1][0..i]);
            try escape(w, f.exe);
            try w.writeAll(v[1][i + 3 ..]);
        } else try w.writeAll(v[1]);
        try w.writeByte('\n');
    }
    for ([_][]const u8{ "NoModify", "NoRepair" }) |v| {
        try w.writeAll("  WriteRegDWORD HKCU ");
        try quoted(w, key);
        try w.print(" \"{s}\" 1\n", .{v});
    }
    var unreg: std.Io.Writer.Allocating = .init(gpa);
    defer unreg.deinit();
    try associations(gpa, c, f.exe, w, &unreg.writer);
    try w.writeAll("SectionEnd\n\n; The finish page offers it, so silent installs (/S) make none.\nFunction CreateDesktopShortcut\n  SetOutPath \"$INSTDIR\"\n  CreateShortCut \"$DESKTOP\\");
    try escape(w, dir_name);
    try w.writeAll(".lnk\" \"$INSTDIR\\");
    try escape(w, f.exe);
    try w.writeAll("\"\nFunctionEnd\n\nSection \"Uninstall\"\n");
    // The app undoes what it set up itself, before its files go.
    if (c.windows.uninstall_run.len > 0) {
        try w.writeAll("  ExecWait '\"$INSTDIR\\");
        try escape(w, f.exe);
        try w.writeAll("\" ");
        try escape(w, c.windows.uninstall_run);
        try w.writeAll("'\n");
    }
    try w.writeAll("  Delete \"$SMPROGRAMS\\");
    try escape(w, dir_name);
    try w.writeAll(".lnk\"\n  Delete \"$DESKTOP\\");
    try escape(w, dir_name);
    try w.writeAll(".lnk\"\n  DeleteRegKey HKCU ");
    try quoted(w, key);
    try w.writeByte('\n');
    try w.writeAll(unreg.written());
    try w.writeAll("  RMDir /r \"$INSTDIR\"\n");
    // The data too, once asked; a silent uninstall keeps it.
    if (c.windows.uninstall_data.len > 0) {
        try w.writeAll("  IfSilent keep_data\n  MessageBox MB_YESNO|MB_ICONQUESTION ");
        const ask = try std.fmt.allocPrint(gpa, "Also delete {s}'s settings and data?", .{c.name});
        defer gpa.free(ask);
        try quoted(w, ask);
        try w.writeAll(" /SD IDNO IDNO keep_data\n");
        for (c.windows.uninstall_data) |d| {
            try w.writeAll("  RMDir /r \"");
            try w.writeAll(d);
            try w.writeAll("\"\n");
        }
        try w.writeAll("  keep_data:\n");
    }
    try w.writeAll("SectionEnd\n");
    return out.toOwnedSlice();
}

/// The commands that register (to `reg`) and unregister (to `unreg`) the
/// file associations and URL schemes for the user.
fn associations(gpa: std.mem.Allocator, c: Config, exe: []const u8, reg: *std.Io.Writer, unreg: *std.Io.Writer) !void {
    var prefix: std.ArrayList(u8) = .empty;
    defer prefix.deinit(gpa);
    for (c.identifier) |ch| if (std.ascii.isAlphanumeric(ch) or ch == '.') try prefix.append(gpa, ch);
    var open: std.Io.Writer.Allocating = .init(gpa);
    defer open.deinit();
    try open.writer.writeAll("'\"$INSTDIR\\");
    try escape(&open.writer, exe);
    try open.writer.writeAll("\" \"%1\"'");
    var any = false;
    for (c.file_associations) |fa| for (fa.ext) |ext| {
        any = true;
        const lower = try std.ascii.allocLowerString(gpa, ext);
        defer gpa.free(lower);
        const class = try std.fmt.allocPrint(gpa, "Software\\Classes\\{s}.{s}", .{ prefix.items, lower });
        defer gpa.free(class);
        const prog = class["Software\\Classes\\".len..];
        try reg.writeAll("  WriteRegStr HKCU ");
        try quoted(reg, class);
        try reg.writeAll(" \"\" ");
        try quoted(reg, if (fa.name.len > 0) fa.name else ext);
        try reg.print("\n  WriteRegStr HKCU \"{s}\\DefaultIcon\" \"\" \"$INSTDIR\\", .{class});
        try escape(reg, exe);
        try reg.print(",0\"\n  WriteRegStr HKCU \"{s}\\shell\\open\\command\" \"\" {s}\n", .{ class, open.written() });
        try reg.print("  WriteRegStr HKCU \"Software\\Classes\\.{s}\\OpenWithProgids\" \"{s}\" \"\"\n", .{ ext, prog });
        try unreg.print("  DeleteRegKey HKCU \"{s}\"\n", .{class});
        try unreg.print("  DeleteRegValue HKCU \"Software\\Classes\\.{s}\\OpenWithProgids\" \"{s}\"\n", .{ ext, prog });
    };
    for (c.url_schemes) |s| {
        any = true;
        try reg.print("  WriteRegStr HKCU \"Software\\Classes\\{s}\" \"\" ", .{s});
        try quoted(reg, try std.fmt.allocPrint(gpa, "URL:{s}", .{c.name}));
        try reg.print("\n  WriteRegStr HKCU \"Software\\Classes\\{s}\" \"URL Protocol\" \"\"\n", .{s});
        try reg.print("  WriteRegStr HKCU \"Software\\Classes\\{s}\\shell\\open\\command\" \"\" {s}\n", .{ s, open.written() });
        try unreg.print("  DeleteRegKey HKCU \"Software\\Classes\\{s}\"\n", .{s});
    }
    if (any) {
        // Tell Explorer the associations changed.
        const notify = "  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'\n";
        try reg.writeAll(notify);
        try unreg.writeAll(notify);
    }
}

test script {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const c: Config = .{
        .root = "/a", .name = "My \"App\" $1", .identifier = "com.example.my-app", .version = "1.2.0",
        .file_associations = &.{.{ .ext = &.{"MD"}, .name = "Markdown" }}, .url_schemes = &.{"myapp"},
    };
    const s = try script(gpa, c, "My App", .{ .paths = &.{ "C:\\b\\my_app.exe", "C:\\b\\data" }, .exe = "my_app.exe", .out = "C:\\b\\My App Setup 1.2.0 x86_64.exe", .ico = "C:\\w\\i.ico" }, &.{ false, true });
    for ([_][]const u8{
        "Name \"My $\\\"App$\\\" $$1\"\n",
        "OutFile \"C:\\b\\My App Setup 1.2.0 x86_64.exe\"\n",
        "InstallDir \"$LOCALAPPDATA\\Programs\\My App\"\n",
        "!define MUI_ICON \"C:\\w\\i.ico\"\n",
        "  File \"C:\\b\\my_app.exe\"\n  File /r \"C:\\b\\data\"\n",
        "CreateShortCut \"$SMPROGRAMS\\My App.lnk\" \"$INSTDIR\\my_app.exe\"\n",
        "\"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\com.example.my-app\" \"DisplayVersion\" \"1.2.0\"\n",
        "\"UninstallString\" '\"$INSTDIR\\Uninstall.exe\"'\n",
        "WriteRegStr HKCU \"Software\\Classes\\com.example.myapp.md\\shell\\open\\command\" \"\" '\"$INSTDIR\\my_app.exe\" \"%1\"'\n",
        "\"Software\\Classes\\.MD\\OpenWithProgids\" \"com.example.myapp.md\" \"\"\n",
        "WriteRegStr HKCU \"Software\\Classes\\myapp\" \"URL Protocol\" \"\"\n",
        "  DeleteRegKey HKCU \"Software\\Classes\\myapp\"\n",
        "  RMDir /r \"$INSTDIR\"\nSectionEnd\n",
    }) |want| if (std.mem.indexOf(u8, s, want) == null) {
        std.debug.print("missing:\n{s}\nin:\n{s}\n", .{ want, s });
        return error.TestUnexpectedResult;
    };
}

test "the uninstaller runs the app, and offers to delete its data" {
    const gpa = std.testing.allocator;
    var c: Config = .{ .root = "/x", .name = "My App", .identifier = "com.example.my-app", .version = "1.0.0" };
    c.windows.uninstall_run = "--uninstall-shell";
    c.windows.uninstall_data = &.{"$APPDATA\\My App"};
    const s = try script(gpa, c, "My App", .{ .paths = &.{}, .exe = "My App.exe", .out = "setup.exe" }, &.{});
    defer gpa.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "ExecWait '\"$INSTDIR\\My App.exe\" --uninstall-shell'") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "IfSilent keep_data") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "RMDir /r \"$APPDATA\\My App\"") != null);
}
