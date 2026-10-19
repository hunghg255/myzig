//! What the system does for apps on Linux: the user's locale, region and
//! languages (from LC_ALL, LC_MESSAGES, LANG and LANGUAGE), and recent
//! documents (GTK's recently used files, the Recent of file choosers).
const std = @import("std");
const gtk = @import("gtk.zig");

/// "en_US.UTF-8@euro" as a BCP 47 tag: "en-US". "C" and "POSIX" are "en-US".
pub fn bcp47(buf: []u8, posix: []const u8) []const u8 {
    var s = posix;
    if (std.mem.indexOfAny(u8, s, ".@")) |i| s = s[0..i];
    if (s.len == 0 or std.mem.eql(u8, s, "C") or std.mem.eql(u8, s, "POSIX")) return "en-US";
    const n = @min(s.len, buf.len);
    for (s[0..n], 0..) |ch, i| buf[i] = if (ch == '_') '-' else ch;
    return buf[0..n];
}

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = std.mem.span(std.c.getenv(name) orelse return null);
    return if (v.len > 0) v else null;
}

/// The user's locale as a BCP 47 tag ("en-US"). Caller frees it.
pub fn locale(gpa: std.mem.Allocator) ![]u8 {
    const raw = env("LC_ALL") orelse env("LC_MESSAGES") orelse env("LANG") orelse "C";
    var buf: [64]u8 = undefined;
    return gpa.dupe(u8, bcp47(&buf, raw));
}

/// The user's region, two letters ("US"), from LC_ALL, LC_TIME or LANG.
pub fn region(gpa: std.mem.Allocator) ![]u8 {
    const raw = env("LC_ALL") orelse env("LC_TIME") orelse env("LANG") orelse "C";
    var buf: [64]u8 = undefined;
    const tag = bcp47(&buf, raw);
    const dash = std.mem.lastIndexOfScalar(u8, tag, '-') orelse return gpa.dupe(u8, "");
    return gpa.dupe(u8, tag[dash + 1 ..]);
}

/// The user's languages, most preferred first (LANGUAGE "fr:en", else the
/// locale's). Free with `freeList`.
pub fn languages(gpa: std.mem.Allocator) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeList(gpa, out.items);
    if (env("LANGUAGE")) |list| {
        var it = std.mem.splitScalar(u8, list, ':');
        while (it.next()) |l| if (l.len > 0) {
            var buf: [64]u8 = undefined;
            try out.append(gpa, try gpa.dupe(u8, bcp47(&buf, l)));
        };
    }
    if (out.items.len == 0) try out.append(gpa, try locale(gpa));
    return out.toOwnedSlice(gpa);
}

pub fn freeList(gpa: std.mem.Allocator, list: []const []u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

const Recent = struct {
    gtk_recent_manager_get_default: *const fn () callconv(.c) ?*anyopaque,
    gtk_recent_manager_add_item: *const fn (m: *anyopaque, uri: [*:0]const u8) callconv(.c) c_int,
    gtk_recent_manager_remove_item: *const fn (m: *anyopaque, uri: [*:0]const u8, err: ?*anyopaque) callconv(.c) c_int,
    g_filename_to_uri: *const fn (path: [*:0]const u8, host: ?[*:0]const u8, err: ?*anyopaque) callconv(.c) ?[*:0]u8,
};
var recent: Recent = undefined;
var recent_loaded = false;

fn loadRecent() bool {
    if (recent_loaded) return true;
    if (!gtk.load()) return false;
    const lib = std.c.dlopen("libgtk-3.so.0", .{ .NOW = true, .GLOBAL = true }) orelse return false;
    inline for (@typeInfo(Recent).@"struct".field_names) |name| {
        const sym = std.c.dlsym(lib, name) orelse return false;
        @field(recent, name) = @ptrCast(@alignCast(sym));
    }
    recent_loaded = true;
    return true;
}

fn withUri(path: []const u8, comptime f: fn (*anyopaque, [*:0]const u8) void) void {
    if (!loadRecent()) return;
    const m = recent.gtk_recent_manager_get_default() orelse return;
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const uri = recent.g_filename_to_uri(@ptrCast(&buf), null, null) orelse return;
    defer gtk.api.g_free(uri);
    f(m, uri);
}

/// Adds `path` (absolute) to the user's recently used files.
pub fn addRecentDocument(path: []const u8) void {
    withUri(path, struct {
        fn f(m: *anyopaque, uri: [*:0]const u8) void {
            _ = recent.gtk_recent_manager_add_item(m, uri);
        }
    }.f);
}

/// Removes `path` from the user's recently used files (the user's other
/// recent files stay).
pub fn removeRecentDocument(path: []const u8) void {
    withUri(path, struct {
        fn f(m: *anyopaque, uri: [*:0]const u8) void {
            _ = recent.gtk_recent_manager_remove_item(m, uri, null);
        }
    }.f);
}

test "POSIX locales as BCP 47 tags" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("en-US", bcp47(&buf, "en_US.UTF-8"));
    try std.testing.expectEqualStrings("de-DE", bcp47(&buf, "de_DE@euro"));
    try std.testing.expectEqualStrings("fr", bcp47(&buf, "fr"));
    try std.testing.expectEqualStrings("en-US", bcp47(&buf, "C.UTF-8"));
    try std.testing.expectEqualStrings("en-US", bcp47(&buf, "POSIX"));
}
