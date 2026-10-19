//! Linux packaging (after mygo's deb.go): the desktop entry, the MIME
//! types the app defines, and a Debian package holding the app in
//! /opt/<name>, its entry and icons, and a command in /usr/bin when
//! linux.command names one. myzig loads GTK 3 at run time (WebKitGTK for
//! pages), which the package depends on.
const std = @import("std");
const archive = @import("archive.zig");
const png = @import("png.zig");
const config = @import("config.zig");
const Config = config.Config;
const Arch = @import("proc.zig").Arch;

/// A semantic version as Debian's: a pre-release sorts before its release.
pub fn debVersion(gpa: std.mem.Allocator, v_in: []const u8) ![]u8 {
    const v = if (std.mem.startsWith(u8, v_in, "v")) v_in[1..] else v_in;
    const out = try gpa.dupe(u8, v);
    if (std.mem.indexOfScalar(u8, out, '-')) |i| {
        out[i] = '~';
        std.mem.replaceScalar(u8, out[i + 1 ..], '-', '.');
    }
    std.mem.replaceScalar(u8, out, '+', '~');
    return out;
}

fn desktopEscape(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '\n' => try w.writeAll("\\n"),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
}

/// The desktop entry of the app, run by `exec`, its icon named `icon`.
pub fn desktopEntry(gpa: std.mem.Allocator, c: Config, exec: []const u8, icon: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("[Desktop Entry]\nType=Application\nName=");
    try desktopEscape(w, c.name);
    try w.writeByte('\n');
    if (c.linux.comment.len > 0) {
        try w.writeAll("Comment=");
        try desktopEscape(w, c.linux.comment);
        try w.writeByte('\n');
    }
    // Exec quotes the path; %U passes opened files and URLs.
    const takes_args = c.file_associations.len > 0 or c.url_schemes.len > 0;
    try w.print("Exec=\"{s}\"{s}\nIcon={s}\nTerminal=false\n", .{ exec, if (takes_args) " %U" else "", icon });
    try w.writeAll("Categories=");
    for (c.linux.categories) |cat| try w.print("{s};", .{cat});
    try w.writeByte('\n');
    var types: std.ArrayList([]const u8) = .empty;
    for (c.file_associations) |fa| try types.append(gpa, (try c.mimeType(gpa, fa))[0]);
    for (c.url_schemes) |s| try types.append(gpa, try std.fmt.allocPrint(gpa, "x-scheme-handler/{s}", .{s}));
    if (types.items.len > 0) {
        try w.writeAll("MimeType=");
        for (types.items) |t| try w.print("{s};", .{t});
        try w.writeByte('\n');
    }
    try w.print("StartupWMClass={s}\n", .{c.executable});
    return out.toOwnedSlice();
}

/// The shared-mime-info package defining the types of the associations
/// without one, or null when they all have one.
pub fn mimePackage(gpa: std.mem.Allocator, c: Config) !?[]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    var any = false;
    for (c.file_associations) |fa| {
        const t, const defined = try c.mimeType(gpa, fa);
        if (!defined) continue;
        if (!any) try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<mime-info xmlns=\"http://www.freedesktop.org/standards/shared-mime-info\">\n");
        any = true;
        try w.print("  <mime-type type=\"{s}\">\n", .{t});
        if (fa.name.len > 0) {
            try w.writeAll("    <comment>");
            try @import("plist.zig").escape(w, fa.name);
            try w.writeAll("</comment>\n");
        }
        for (fa.ext) |e| try w.print("    <glob pattern=\"*.{s}\"/>\n", .{e});
        try w.writeAll("  </mime-type>\n");
    }
    if (!any) {
        out.deinit();
        return null;
    }
    try w.writeAll("</mime-info>\n");
    return try out.toOwnedSlice();
}

/// Writes the Debian package of the app: `app` are its files, relative to
/// its directory (the executable `exe` among them), `icon_png` the icon.
/// Allocates from `gpa` (an arena). Returns the package's bytes and name.
pub fn deb(gpa: std.mem.Allocator, c: Config, arch: Arch, exe: []const u8, app: []const archive.Entry, icon_png: ?[]const u8, mtime: u64) !struct { []u8, []u8 } {
    const name = c.executable;
    const opt = try std.fmt.allocPrint(gpa, "opt/{s}", .{name});
    var data: std.ArrayList(archive.Entry) = .empty;
    var md5sums: std.Io.Writer.Allocating = .init(gpa);
    var size: usize = 0;
    var dirs: std.ArrayList([]const u8) = .empty;
    const S = struct {
        fn dir(a: std.mem.Allocator, list: *std.ArrayList(archive.Entry), seen: *std.ArrayList([]const u8), p: []const u8) !void {
            for (seen.items) |s| if (std.mem.eql(u8, s, p)) return;
            if (std.fs.path.dirnamePosix(p)) |parent| try dir(a, list, seen, parent);
            try seen.append(a, p);
            try list.append(a, .{ .path = p, .kind = .dir, .mode = 0o755 });
        }
        fn file(a: std.mem.Allocator, list: *std.ArrayList(archive.Entry), seen: *std.ArrayList([]const u8), sums: *std.Io.Writer, total: *usize, e: archive.Entry) !void {
            if (std.fs.path.dirnamePosix(e.path)) |parent| try dir(a, list, seen, parent);
            try list.append(a, e);
            if (e.kind != .file) return;
            total.* += e.data.len;
            var h: [16]u8 = undefined;
            std.crypto.hash.Md5.hash(e.data, &h, .{});
            try sums.print("{x}  {s}\n", .{ &h, e.path });
        }
    };
    try S.dir(gpa, &data, &dirs, opt);
    for (app) |e| {
        var x = e;
        x.path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ opt, e.path });
        if (x.kind == .dir) try S.dir(gpa, &data, &dirs, x.path) else try S.file(gpa, &data, &dirs, &md5sums.writer, &size, x);
    }
    const exe_path = try std.fmt.allocPrint(gpa, "/{s}/{s}", .{ opt, exe });
    if (c.linux.command.len > 0) try S.file(gpa, &data, &dirs, &md5sums.writer, &size, .{
        .path = try std.fmt.allocPrint(gpa, "usr/bin/{s}", .{c.linux.command}),
        .kind = .symlink,
        .link = try std.fmt.allocPrint(gpa, "../..{s}", .{exe_path}),
        .mode = 0o777,
    });
    if (try mimePackage(gpa, c)) |xml| try S.file(gpa, &data, &dirs, &md5sums.writer, &size, .{ .path = try std.fmt.allocPrint(gpa, "usr/share/mime/packages/{s}.xml", .{name}), .data = xml });
    try S.file(gpa, &data, &dirs, &md5sums.writer, &size, .{
        .path = try std.fmt.allocPrint(gpa, "usr/share/applications/{s}.desktop", .{name}),
        .data = try desktopEntry(gpa, c, exe_path, name),
    });
    if (icon_png) |src_png| {
        const src = try png.Source.init(gpa, src_png);
        for ([_]u32{ 256, 512 }) |px| try S.file(gpa, &data, &dirs, &md5sums.writer, &size, .{
            .path = try std.fmt.allocPrint(gpa, "usr/share/icons/hicolor/{d}x{d}/apps/{s}.png", .{ px, px, name }),
            .data = try src.png(gpa, px),
        });
    }

    const version = try debVersion(gpa, c.version);
    var control: std.Io.Writer.Allocating = .init(gpa);
    const w = &control.writer;
    try w.print("Package: {s}\nVersion: {s}\nArchitecture: {s}\nMaintainer: {s}\nInstalled-Size: {d}\n", .{
        try config.slug(gpa, name, '-'), version, arch.debian(), c.linux.maintainer, (size + 1023) / 1024,
    });
    try w.writeAll("Depends: libgtk-3-0 | libgtk-3-0t64, libwebkit2gtk-4.1-0");
    for (c.linux.depends) |d| try w.print(", {s}", .{d});
    try w.print("\nSection: utils\nPriority: optional\nDescription: {s}\n {s} is a desktop application.\n", .{
        if (c.linux.comment.len > 0) c.linux.comment else c.name, c.name,
    });
    const tar_opts: archive.TarOptions = .{ .prefix = "./", .mtime = mtime };
    const control_tar = try archive.tarGz(gpa, &.{
        .{ .path = "control", .data = control.written() },
        .{ .path = "md5sums", .data = md5sums.written() },
    }, tar_opts);
    const data_tar = try archive.tarGz(gpa, data.items, tar_opts);
    const bytes = try archive.ar(gpa, &.{
        .{ "debian-binary", "2.0\n" },
        .{ "control.tar.gz", control_tar },
        .{ "data.tar.gz", data_tar },
    }, mtime);
    return .{ bytes, try std.fmt.allocPrint(gpa, "{s}_{s}_{s}.deb", .{ try config.slug(gpa, name, '-'), version, arch.debian() }) };
}

test debVersion {
    const gpa = std.testing.allocator;
    for ([_][2][]const u8{ .{ "v1.2.0", "1.2.0" }, .{ "1.2.0-beta-1", "1.2.0~beta.1" }, .{ "1.0+git", "1.0~git" } }) |c| {
        const v = try debVersion(gpa, c[0]);
        defer gpa.free(v);
        try std.testing.expectEqualStrings(c[1], v);
    }
}

/// Reads the members of an ar archive, and the entries of a tar (tests).
pub fn arMembers(gpa: std.mem.Allocator, a: []const u8) ![]const struct { []const u8, []const u8 } {
    if (!std.mem.startsWith(u8, a, "!<arch>\n")) return error.NotAr;
    var list: std.ArrayList(struct { []const u8, []const u8 }) = .empty;
    var at: usize = 8;
    while (at + 60 <= a.len) {
        const h = a[at..][0..60];
        if (!std.mem.eql(u8, h[58..60], "`\n")) return error.BadAr;
        const n = try std.fmt.parseInt(usize, std.mem.trim(u8, h[48..58], " "), 10);
        try list.append(gpa, .{ std.mem.trim(u8, h[0..16], " "), a[at + 60 ..][0..n] });
        at += 60 + n + n % 2;
    }
    return list.toOwnedSlice(gpa);
}

pub fn tarNames(gpa: std.mem.Allocator, t: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    while (at + 512 <= t.len and t[at] != 0) {
        const h = t[at..][0..512];
        const size = try std.fmt.parseInt(usize, std.mem.sliceTo(h[124..136], 0), 8);
        try list.append(gpa, std.mem.sliceTo(h[0..100], 0));
        at += 512 + std.mem.alignForward(usize, size, 512);
    }
    return list.toOwnedSlice(gpa);
}

test deb {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const c: Config = .{
        .root = "/a", .name = "My App", .identifier = "com.example.myapp", .version = "1.0.0-rc1", .executable = "my_app",
        .file_associations = &.{.{ .ext = &.{"note"}, .name = "Note & Co" }},
        .linux = .{ .maintainer = "Jane <j@example.com>", .command = "my-app", .depends = &.{"libfoo1"} },
    };
    const icon = try png.testIcon(gpa, 32, .{ 1, 2, 3 });
    const bytes, const name = try deb(gpa, c, .x86_64, "my_app", &.{
        .{ .path = "my_app", .data = "\x7fELF", .mode = 0o755 },
        .{ .path = "data", .kind = .dir, .mode = 0o755 },
        .{ .path = "data/a.txt", .data = "a" },
    }, icon, 1700000000);
    try std.testing.expectEqualStrings("my-app_1.0.0~rc1_amd64.deb", name);
    const members = try arMembers(gpa, bytes);
    try std.testing.expectEqual(@as(usize, 3), members.len);
    try std.testing.expectEqualStrings("debian-binary", members[0][0]);
    try std.testing.expectEqualStrings("2.0\n", members[0][1]);
    const compress = @import("compress.zig");
    const control = try compress.inflate(gpa, members[1][1], .gzip);
    const control_names = try tarNames(gpa, control);
    try std.testing.expectEqualStrings("./control", control_names[0]);
    const text = control[512..];
    for ([_][]const u8{ "Package: my-app\n", "Version: 1.0.0~rc1\n", "Architecture: amd64\n", "Maintainer: Jane <j@example.com>\n", "Depends: libgtk-3-0 | libgtk-3-0t64, libwebkit2gtk-4.1-0, libfoo1\n" }) |want|
        try std.testing.expect(std.mem.indexOf(u8, text, want) != null);
    const data = try compress.inflate(gpa, members[2][1], .gzip);
    const names = try tarNames(gpa, data);
    for ([_][]const u8{ "./opt/", "./opt/my_app/", "./opt/my_app/my_app", "./opt/my_app/data/a.txt", "./usr/bin/my-app", "./usr/share/mime/packages/my_app.xml", "./usr/share/applications/my_app.desktop", "./usr/share/icons/hicolor/512x512/apps/my_app.png" }) |want| {
        for (names) |n| {
            if (std.mem.eql(u8, n, want)) break;
        } else {
            std.debug.print("missing {s}\n", .{want});
            return error.TestUnexpectedResult;
        }
    }
    // Parents come before their files.
    try std.testing.expectEqualStrings("./opt/", names[0]);
}

test desktopEntry {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const c: Config = .{ .root = "/a", .name = "Notes", .executable = "notes", .url_schemes = &.{"notes"}, .linux = .{ .comment = "Take notes" } };
    const e = try desktopEntry(gpa, c, "/opt/notes/notes", "notes");
    try std.testing.expectEqualStrings(
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Notes
        \\Comment=Take notes
        \\Exec="/opt/notes/notes" %U
        \\Icon=notes
        \\Terminal=false
        \\Categories=Utility;
        \\MimeType=x-scheme-handler/notes;
        \\StartupWMClass=notes
        \\
    , e);
}
