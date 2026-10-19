//! What the system does for apps in a browser: the user's languages
//! (`navigator.languages`). Recent documents are the app's own list only
//! (`system.zig` keeps it in the WASI file system, for the page's life).
const std = @import("std");
const js = @import("js.zig");

fn list(buf: []u8) []const u8 {
    const n = js.languages(buf.ptr, buf.len);
    return buf[0..@min(n, buf.len)];
}

/// The browser's first language ("en-US").
pub fn locale(gpa: std.mem.Allocator) ![]u8 {
    var buf: [256]u8 = undefined;
    var it = std.mem.splitScalar(u8, list(&buf), ',');
    const first = it.next() orelse "";
    return gpa.dupe(u8, if (first.len > 0) first else "en-US");
}

/// The region of the first language that has one ("US"), else "".
pub fn region(gpa: std.mem.Allocator) ![]u8 {
    var buf: [256]u8 = undefined;
    var it = std.mem.splitScalar(u8, list(&buf), ',');
    while (it.next()) |tag| {
        const dash = std.mem.lastIndexOfScalar(u8, tag, '-') orelse continue;
        if (tag.len - dash - 1 == 2) return gpa.dupe(u8, tag[dash + 1 ..]);
    }
    return gpa.dupe(u8, "");
}

/// The browser's languages, most preferred first. Free with `freeList`.
pub fn languages(gpa: std.mem.Allocator) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeList(gpa, out.items);
    var buf: [256]u8 = undefined;
    var it = std.mem.splitScalar(u8, list(&buf), ',');
    while (it.next()) |tag| if (tag.len > 0) try out.append(gpa, try gpa.dupe(u8, tag));
    if (out.items.len == 0) try out.append(gpa, try gpa.dupe(u8, "en-US"));
    return out.toOwnedSlice(gpa);
}

pub fn freeList(gpa: std.mem.Allocator, items: []const []u8) void {
    for (items) |s| gpa.free(s);
    gpa.free(items);
}

/// No system list of recent documents in a browser.
pub fn addRecentDocument(_: []const u8) void {}
pub fn removeRecentDocument(_: []const u8) void {}
pub fn clearRecentDocuments() void {}
