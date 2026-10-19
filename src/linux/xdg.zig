//! The XDG conventions on Linux: desktop entries that open URLs of the
//! app's schemes (made the default handler in the user's mimeapps.list, as
//! `xdg-mime default` does), and the autostart entry that opens the app at
//! login. Functions take their directories so tests use temporary ones.
const std = @import("std");

/// The user's data and config directories ($XDG_DATA_HOME,
/// $XDG_CONFIG_HOME, or under $HOME). Caller frees them.
pub const Dirs = struct {
    data: []u8,
    config: []u8,

    pub fn user(gpa: std.mem.Allocator) !Dirs {
        const home: []const u8 = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "/tmp";
        const data = if (std.c.getenv("XDG_DATA_HOME")) |d| try gpa.dupe(u8, std.mem.span(d)) else try std.fs.path.join(gpa, &.{ home, ".local", "share" });
        errdefer gpa.free(data);
        const config = if (std.c.getenv("XDG_CONFIG_HOME")) |d| try gpa.dupe(u8, std.mem.span(d)) else try std.fs.path.join(gpa, &.{ home, ".config" });
        return .{ .data = data, .config = config };
    }

    pub fn deinit(d: Dirs, gpa: std.mem.Allocator) void {
        gpa.free(d.data);
        gpa.free(d.config);
    }
};

/// The running executable's path. Caller frees it.
pub fn executable(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    var buf: [4096]u8 = undefined;
    const n = try std.Io.Dir.cwd().readLink(io, "/proc/self/exe", &buf);
    return gpa.dupe(u8, buf[0..n]);
}

/// A desktop entry's Exec value: the path quoted, as the specification asks.
fn quoted(w: *std.Io.Writer, exe: []const u8) !void {
    try w.writeByte('"');
    for (exe) |ch| {
        if (ch == '"' or ch == '`' or ch == '$' or ch == '\\') try w.writeByte('\\');
        try w.writeByte(ch);
    }
    try w.writeByte('"');
}

/// The hidden entry opening URLs of `schemes` with `exe`.
pub fn handlerEntry(gpa: std.mem.Allocator, name: []const u8, exe: []const u8, schemes: []const []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.print("[Desktop Entry]\nType=Application\nName={s}\nExec=", .{name});
    try quoted(w, exe);
    try w.writeAll(" %u\nNoDisplay=true\nTerminal=false\nMimeType=");
    for (schemes) |s| try w.print("x-scheme-handler/{s};", .{s});
    try w.writeAll("\n");
    return aw.toOwnedSlice();
}

/// The schemes an entry handles (slices of `text`).
pub fn entrySchemes(gpa: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "MimeType=")) continue;
        var it = std.mem.splitScalar(u8, line["MimeType=".len..], ';');
        while (it.next()) |m| if (std.mem.startsWith(u8, m, "x-scheme-handler/")) try out.append(gpa, m["x-scheme-handler/".len..]);
    }
    return out.toOwnedSlice(gpa);
}

/// `mimeapps.list` with `mime`'s default set to `desktop` (or removed when
/// it is `remove` there, `desktop` empty). Caller frees it.
pub fn setMimeDefault(gpa: std.mem.Allocator, text: []const u8, mime: []const u8, desktop: []const u8, remove: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    var in_defaults = false;
    var seen_defaults = false;
    var done = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (lines.index == null and line.len == 0) break;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0 and trimmed[0] == '[') {
            if (in_defaults and !done and desktop.len > 0) {
                try w.print("{s}={s};\n", .{ mime, desktop });
                done = true;
            }
            in_defaults = std.mem.eql(u8, trimmed, "[Default Applications]");
            if (in_defaults) seen_defaults = true;
        } else if (in_defaults and std.mem.startsWith(u8, trimmed, mime) and trimmed.len > mime.len and trimmed[mime.len] == '=') {
            const value = trimmed[mime.len + 1 ..];
            if (desktop.len > 0) {
                if (!done) try w.print("{s}={s};\n", .{ mime, desktop });
                done = true;
                continue;
            }
            // Removing: only our own entry.
            if (std.mem.indexOf(u8, value, remove) != null) continue;
        }
        try w.writeAll(line);
        try w.writeByte('\n');
    }
    if (desktop.len > 0 and !done) {
        if (!seen_defaults) try w.writeAll("[Default Applications]\n");
        try w.print("{s}={s};\n", .{ mime, desktop });
    }
    return aw.toOwnedSlice();
}

/// `mime`'s default desktop entry in `mimeapps.list`, the first listed.
pub fn mimeDefault(text: []const u8, mime: []const u8) ?[]const u8 {
    var in_defaults = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] == '[') in_defaults = std.mem.eql(u8, line, "[Default Applications]") else if (in_defaults and std.mem.startsWith(u8, line, mime) and line.len > mime.len and line[mime.len] == '=') {
            var it = std.mem.splitScalar(u8, line[mime.len + 1 ..], ';');
            return it.next();
        }
    }
    return null;
}

fn readOr(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => gpa.dupe(u8, ""),
        else => e,
    };
}

fn write(io: std.Io, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

/// Makes `exe` the user's handler of `scheme`'s URLs: its entry
/// (`<id>.url-handler.desktop`) lists the scheme, which mimeapps.list
/// gives to it.
pub fn registerScheme(gpa: std.mem.Allocator, io: std.Io, dirs: Dirs, id: []const u8, name: []const u8, exe: []const u8, scheme: []const u8) !void {
    var fb: [256]u8 = undefined;
    const file = try std.fmt.bufPrint(&fb, "{s}.url-handler.desktop", .{id});
    const path = try std.fs.path.join(gpa, &.{ dirs.data, "applications", file });
    defer gpa.free(path);
    const old = try readOr(gpa, io, path);
    defer gpa.free(old);
    const schemes = try entrySchemes(gpa, old);
    defer gpa.free(schemes);
    var all: std.ArrayList([]const u8) = .empty;
    defer all.deinit(gpa);
    try all.appendSlice(gpa, schemes);
    var known = false;
    for (schemes) |s| known = known or std.mem.eql(u8, s, scheme);
    if (!known) try all.append(gpa, scheme);
    const entry = try handlerEntry(gpa, name, exe, all.items);
    defer gpa.free(entry);
    try write(io, path, entry);
    try setDefault(gpa, io, dirs, scheme, file, "");
}

fn setDefault(gpa: std.mem.Allocator, io: std.Io, dirs: Dirs, scheme: []const u8, file: []const u8, remove: []const u8) !void {
    var mb: [256]u8 = undefined;
    const mime = try std.fmt.bufPrint(&mb, "x-scheme-handler/{s}", .{scheme});
    const list = try std.fs.path.join(gpa, &.{ dirs.config, "mimeapps.list" });
    defer gpa.free(list);
    const text = try readOr(gpa, io, list);
    defer gpa.free(text);
    const updated = try setMimeDefault(gpa, text, mime, file, remove);
    defer gpa.free(updated);
    try write(io, list, updated);
}

pub fn isSchemeRegistered(gpa: std.mem.Allocator, io: std.Io, dirs: Dirs, id: []const u8, scheme: []const u8) bool {
    var fb: [256]u8 = undefined;
    const file = std.fmt.bufPrint(&fb, "{s}.url-handler.desktop", .{id}) catch return false;
    var mb: [256]u8 = undefined;
    const mime = std.fmt.bufPrint(&mb, "x-scheme-handler/{s}", .{scheme}) catch return false;
    const list = std.fs.path.join(gpa, &.{ dirs.config, "mimeapps.list" }) catch return false;
    defer gpa.free(list);
    const text = readOr(gpa, io, list) catch return false;
    defer gpa.free(text);
    const d = mimeDefault(text, mime) orelse return false;
    return std.mem.eql(u8, d, file);
}

/// Removes `scheme` from the app's entry and its default if it is the app's.
pub fn unregisterScheme(gpa: std.mem.Allocator, io: std.Io, dirs: Dirs, id: []const u8, name: []const u8, exe: []const u8, scheme: []const u8) !void {
    var fb: [256]u8 = undefined;
    const file = try std.fmt.bufPrint(&fb, "{s}.url-handler.desktop", .{id});
    const path = try std.fs.path.join(gpa, &.{ dirs.data, "applications", file });
    defer gpa.free(path);
    const old = try readOr(gpa, io, path);
    defer gpa.free(old);
    const schemes = try entrySchemes(gpa, old);
    defer gpa.free(schemes);
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(gpa);
    for (schemes) |s| if (!std.mem.eql(u8, s, scheme)) try rest.append(gpa, s);
    if (rest.items.len == 0) std.Io.Dir.cwd().deleteFile(io, path) catch {} else {
        const entry = try handlerEntry(gpa, name, exe, rest.items);
        defer gpa.free(entry);
        try write(io, path, entry);
    }
    try setDefault(gpa, io, dirs, scheme, "", file);
}

/// The autostart entry (`<config>/autostart/<id>.desktop`) that opens
/// `exe` at login with `--myzig-login`, written or removed.
pub fn setAutostart(gpa: std.mem.Allocator, io: std.Io, dirs: Dirs, id: []const u8, name: []const u8, exe: []const u8, on: bool) !void {
    var fb: [256]u8 = undefined;
    const path = try std.fs.path.join(gpa, &.{ dirs.config, "autostart", try std.fmt.bufPrint(&fb, "{s}.desktop", .{id}) });
    defer gpa.free(path);
    if (!on) {
        std.Io.Dir.cwd().deleteFile(io, path) catch |e| if (e != error.FileNotFound) return e;
        return;
    }
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.print("[Desktop Entry]\nType=Application\nName={s}\nExec=", .{name});
    try quoted(&aw.writer, exe);
    try aw.writer.writeAll(" --myzig-login\nX-GNOME-Autostart-enabled=true\nTerminal=false\n");
    try write(io, path, aw.written());
}

pub fn autostart(gpa: std.mem.Allocator, io: std.Io, dirs: Dirs, id: []const u8) bool {
    var fb: [256]u8 = undefined;
    const path = std.fs.path.join(gpa, &.{ dirs.config, "autostart", std.fmt.bufPrint(&fb, "{s}.desktop", .{id}) catch return false }) catch return false;
    defer gpa.free(path);
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

test "mimeapps.list defaults set, read and removed" {
    const gpa = std.testing.allocator;
    const text = "[Added Associations]\nx=y;\n\n[Default Applications]\ntext/html=firefox.desktop;\nx-scheme-handler/notes=old.desktop;\n";
    const set = try setMimeDefault(gpa, text, "x-scheme-handler/notes", "notes.desktop", "");
    defer gpa.free(set);
    try std.testing.expectEqualStrings("notes.desktop", mimeDefault(set, "x-scheme-handler/notes").?);
    try std.testing.expectEqualStrings("firefox.desktop", mimeDefault(set, "text/html").?);
    const removed = try setMimeDefault(gpa, set, "x-scheme-handler/notes", "", "notes.desktop");
    defer gpa.free(removed);
    try std.testing.expect(mimeDefault(removed, "x-scheme-handler/notes") == null);
    try std.testing.expectEqualStrings("firefox.desktop", mimeDefault(removed, "text/html").?);
    const fresh = try setMimeDefault(gpa, "", "x-scheme-handler/a", "a.desktop", "");
    defer gpa.free(fresh);
    try std.testing.expectEqualStrings("[Default Applications]\nx-scheme-handler/a=a.desktop;\n", fresh);
}

test "URL handlers and autostart entries in temporary directories" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const dirs: Dirs = .{ .data = try std.fs.path.join(gpa, &.{ base, "data" }), .config = try std.fs.path.join(gpa, &.{ base, "config" }) };
    defer dirs.deinit(gpa);
    try std.testing.expect(!isSchemeRegistered(gpa, io, dirs, "com.example.notes", "notes"));
    try registerScheme(gpa, io, dirs, "com.example.notes", "Notes", "/opt/notes/notes app", "notes");
    try registerScheme(gpa, io, dirs, "com.example.notes", "Notes", "/opt/notes/notes app", "notes2");
    try std.testing.expect(isSchemeRegistered(gpa, io, dirs, "com.example.notes", "notes"));
    try std.testing.expect(isSchemeRegistered(gpa, io, dirs, "com.example.notes", "notes2"));
    try unregisterScheme(gpa, io, dirs, "com.example.notes", "Notes", "/opt/notes/notes app", "notes");
    try std.testing.expect(!isSchemeRegistered(gpa, io, dirs, "com.example.notes", "notes"));
    try std.testing.expect(isSchemeRegistered(gpa, io, dirs, "com.example.notes", "notes2"));
    try std.testing.expect(!autostart(gpa, io, dirs, "com.example.notes"));
    try setAutostart(gpa, io, dirs, "com.example.notes", "Notes", "/opt/notes/notes", true);
    try std.testing.expect(autostart(gpa, io, dirs, "com.example.notes"));
    try setAutostart(gpa, io, dirs, "com.example.notes", "Notes", "/opt/notes/notes", false);
    try std.testing.expect(!autostart(gpa, io, dirs, "com.example.notes"));
    const entry = try handlerEntry(gpa, "N", "/a \"b\"", &.{"x"});
    defer gpa.free(entry);
    try std.testing.expect(std.mem.indexOf(u8, entry, "Exec=\"/a \\\"b\\\"\" %u") != null);
}
