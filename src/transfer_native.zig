//! The names transfer formats (MIME types, `transfer.zig`) have in each
//! system's clipboard and drag and drop, both ways: Windows' clipboard
//! formats, GTK's targets (X11 and Wayland atoms) and macOS's pasteboard
//! types (UTIs). A MIME type the system has no name for travels under
//! its own name (Windows, GTK) or as `dev.myzig.mime.` and its hex (macOS),
//! which myzig reads back as the MIME type.
const std = @import("std");
const transfer = @import("transfer.zig");

pub const CF_TEXT = 1;
pub const CF_DIB = 8;
pub const CF_UNICODETEXT = 13;
pub const CF_HDROP = 15;

/// The registered Windows format a MIME type travels as ("PNG", "HTML
/// Format", else its own name); text and files have standard formats.
pub fn windowsName(format: []const u8) []const u8 {
    if (std.mem.eql(u8, format, transfer.png)) return "PNG";
    if (std.mem.eql(u8, format, transfer.html)) return "HTML Format";
    if (std.mem.eql(u8, format, transfer.uri_list)) return "text/uri-list";
    return format;
}

/// The MIME type of a Windows clipboard format (`name` for registered
/// ones), or null for formats myzig doesn't read (bitmaps, locales...).
pub fn ofWindows(cf: u32, name: []const u8) ?[]const u8 {
    switch (cf) {
        CF_TEXT, CF_UNICODETEXT => return transfer.text,
        CF_HDROP => return transfer.file_list,
        CF_DIB => return transfer.png,
        else => {},
    }
    if (cf < 0xC000) return null;
    if (std.mem.eql(u8, name, "PNG")) return transfer.png;
    if (std.mem.eql(u8, name, "HTML Format")) return transfer.html;
    if (std.mem.eql(u8, name, "UniformResourceLocatorW") or std.mem.eql(u8, name, "UniformResourceLocator")) return transfer.uri_list;
    return if (isMime(name)) name else null;
}

/// GTK's targets for a MIME type, the most specific first.
pub fn gtkTargets(format: []const u8) []const [:0]const u8 {
    if (std.mem.eql(u8, format, transfer.text)) return &.{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING", "TEXT" };
    if (std.mem.eql(u8, format, transfer.file_list)) return &.{ "text/uri-list", "x-special/gnome-copied-files" };
    if (std.mem.eql(u8, format, transfer.markdown)) return &.{"text/markdown"};
    return &.{};
}

/// The MIME type of a GTK target, or null for GTK's own (TARGETS,
/// TIMESTAMP...) and names that aren't MIME types.
pub fn ofGtk(target: []const u8) ?[]const u8 {
    for ([_][]const u8{ "UTF8_STRING", "STRING", "TEXT", "COMPOUND_TEXT", "text/plain", "text/plain;charset=utf-8" }) |t| if (std.mem.eql(u8, t, target)) return transfer.text;
    if (std.mem.eql(u8, target, "x-special/gnome-copied-files")) return transfer.file_list;
    if (std.mem.eql(u8, target, "text/x-moz-url")) return transfer.uri_list;
    if (std.mem.startsWith(u8, target, "text/plain;")) return transfer.text;
    return if (isMime(target)) target else null;
}

/// The pasteboard type of a MIME type (in `a`'s memory when made).
pub fn macType(a: std.mem.Allocator, format: []const u8) ![]const u8 {
    if (std.mem.eql(u8, format, transfer.text)) return "public.utf8-plain-text";
    if (std.mem.eql(u8, format, transfer.html)) return "public.html";
    if (std.mem.eql(u8, format, transfer.png)) return "public.png";
    if (std.mem.eql(u8, format, transfer.file_list)) return "public.file-url";
    if (std.mem.eql(u8, format, transfer.uri_list)) return "public.url";
    if (std.mem.eql(u8, format, transfer.markdown)) return "net.daringfireball.markdown";
    if (std.mem.eql(u8, format, "application/pdf")) return "com.adobe.pdf";
    if (std.mem.eql(u8, format, "image/jpeg")) return "public.jpeg";
    if (std.mem.eql(u8, format, "image/tiff")) return "public.tiff";
    if (std.mem.eql(u8, format, "text/rtf")) return "public.rtf";
    return std.fmt.allocPrint(a, "dev.myzig.mime.{x}", .{format});
}

/// The MIME type of a pasteboard type (in `a`'s memory when made), or
/// null for types myzig doesn't read.
pub fn ofMac(a: std.mem.Allocator, t: []const u8) !?[]const u8 {
    const known = [_][2][]const u8{
        .{ "public.utf8-plain-text", transfer.text },
        .{ "public.utf16-plain-text", transfer.text },
        .{ "NSStringPboardType", transfer.text },
        .{ "public.html", transfer.html },
        .{ "public.png", transfer.png },
        .{ "public.file-url", transfer.file_list },
        .{ "NSFilenamesPboardType", transfer.file_list },
        .{ "public.url", transfer.uri_list },
        .{ "net.daringfireball.markdown", transfer.markdown },
        .{ "com.adobe.pdf", "application/pdf" },
        .{ "public.jpeg", "image/jpeg" },
        .{ "public.tiff", "image/tiff" },
        .{ "public.rtf", "text/rtf" },
    };
    for (known) |k| if (std.mem.eql(u8, k[0], t)) return k[1];
    const prefix = "dev.myzig.mime.";
    if (std.mem.startsWith(u8, t, prefix)) {
        const hex = t[prefix.len..];
        if (hex.len == 0 or hex.len % 2 != 0) return null;
        const out = try a.alloc(u8, hex.len / 2);
        return std.fmt.hexToBytes(out, hex) catch null;
    }
    return null;
}

/// Whether a name is a MIME type ("type/subtype", no spaces).
pub fn isMime(name: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, name, '/') orelse return false;
    if (slash == 0 or slash + 1 >= name.len) return false;
    return std.mem.indexOfAny(u8, name, " \t\r\n\x00") == null;
}

/// Adds `format` to `list` unless it is there.
pub fn addUnique(a: std.mem.Allocator, list: *std.ArrayList([]const u8), format: []const u8) !void {
    for (list.items) |f| if (std.mem.eql(u8, f, format)) return;
    try list.append(a, format);
}

/// "copy" and the URIs, a line each: GNOME's copied files.
pub fn gnomeCopied(a: std.mem.Allocator, uri_list: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "copy");
    var it = std.mem.tokenizeAny(u8, uri_list, "\r\n");
    while (it.next()) |line| {
        if (line[0] == '#') continue;
        try out.append(a, '\n');
        try out.appendSlice(a, line);
    }
    return out.toOwnedSlice(a);
}

/// A URI list (CRLF) of the URLs of `paths`.
pub fn uriListOf(a: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (paths) |p| {
        try out.appendSlice(a, try transfer.urlOfPath(a, p));
        try out.appendSlice(a, "\r\n");
    }
    return out.toOwnedSlice(a);
}

test "formats travel under each system's names and come back as MIME types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("PNG", windowsName(transfer.png));
    try std.testing.expectEqualStrings("application/x-note", windowsName("application/x-note"));
    try std.testing.expectEqualStrings(transfer.text, ofWindows(CF_UNICODETEXT, "").?);
    try std.testing.expectEqualStrings(transfer.file_list, ofWindows(CF_HDROP, "").?);
    try std.testing.expectEqualStrings(transfer.html, ofWindows(0xC100, "HTML Format").?);
    try std.testing.expectEqualStrings("application/x-note", ofWindows(0xC101, "application/x-note").?);
    try std.testing.expect(ofWindows(0xC102, "Ole Private Data") == null);
    try std.testing.expect(ofWindows(2, "") == null);

    try std.testing.expectEqualStrings(transfer.text, ofGtk("UTF8_STRING").?);
    try std.testing.expectEqualStrings(transfer.text, ofGtk("text/plain;charset=utf-8").?);
    try std.testing.expectEqualStrings(transfer.file_list, ofGtk("x-special/gnome-copied-files").?);
    try std.testing.expectEqualStrings("text/html", ofGtk("text/html").?);
    try std.testing.expect(ofGtk("TARGETS") == null);
    try std.testing.expect(gtkTargets(transfer.text).len > 1);

    for ([_][]const u8{ transfer.text, transfer.html, transfer.png, transfer.file_list, transfer.uri_list, "application/vnd.example.note+json" }) |f| {
        const t = try macType(a, f);
        try std.testing.expectEqualStrings(f, (try ofMac(a, t)).?);
    }
    try std.testing.expect((try ofMac(a, "com.apple.flat-rtfd")) == null);
    try std.testing.expect((try ofMac(a, "dev.myzig.mime.zz")) == null);

    try std.testing.expectEqualStrings("copy\nfile:///a\nfile:///b", try gnomeCopied(a, "file:///a\r\n# c\r\nfile:///b\r\n"));
    try std.testing.expect(isMime("text/x-y") and !isMime("TARGETS") and !isMime("a b/c"));
}

/// `s` and a NUL after it, in `a`'s memory.
pub fn dupeZ(a: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const out = try a.alloc(u8, s.len + 1);
    @memcpy(out[0..s.len], s);
    out[s.len] = 0;
    return out[0..s.len :0];
}
