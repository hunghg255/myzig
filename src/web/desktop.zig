//! The desktop around the app in a browser: the clipboard's text (the
//! browser's, written through `navigator.clipboard`; read back is what the
//! app copied last, as a browser hands its clipboard only to a paste),
//! opening URLs in a tab, directories in the WASI file system, and the
//! browser's appearance.
const std = @import("std");
const js = @import("js.zig");

/// What the app copied last.
var copied: std.ArrayList(u8) = .empty;

pub const clipboard = struct {
    pub fn readText(gpa: std.mem.Allocator) !?[]u8 {
        if (copied.items.len == 0) return null;
        return try gpa.dupe(u8, copied.items);
    }

    pub fn writeText(text: []const u8) void {
        copied.clearRetainingCapacity();
        copied.appendSlice(std.heap.wasm_allocator, text) catch {};
        js.clipboard_write(text.ptr, text.len);
    }

    pub fn changeCount() isize {
        return 0;
    }

    pub fn readImage(_: std.mem.Allocator) !?[]u8 {
        return null;
    }

    pub fn writeImage(_: std.mem.Allocator, _: []const u8) !void {
        return error.Unsupported;
    }

    pub fn readFiles(_: std.mem.Allocator) !?[][]u8 {
        return null;
    }

    pub fn writeFiles(_: std.mem.Allocator, _: []const []const u8) !void {
        return error.Unsupported;
    }

    pub fn readHtml(_: std.mem.Allocator) !?[]u8 {
        return null;
    }

    /// The text only: the browser's clipboard API takes text here.
    pub fn writeHtml(_: std.mem.Allocator, _: []const u8, text: []const u8) !void {
        writeText(text);
    }

    /// The data's text only: the browser's clipboard API takes text here.
    pub fn writeData(gpa: std.mem.Allocator, data: *@import("../transfer.zig").Data) !void {
        const t = try data.read(gpa, @import("../transfer.zig").text);
        defer gpa.free(t);
        writeText(t);
    }

    /// Text, when the app copied some.
    pub fn formats(gpa: std.mem.Allocator) ![][]u8 {
        if (copied.items.len == 0) return gpa.alloc([]u8, 0);
        const out = try gpa.alloc([]u8, 1);
        out[0] = try gpa.dupe(u8, @import("../transfer.zig").text);
        return out;
    }

    pub fn read(gpa: std.mem.Allocator, format: []const u8) !?[]u8 {
        if (!std.mem.eql(u8, format, @import("../transfer.zig").text)) return null;
        return readText(gpa);
    }
};

pub const shell = struct {
    /// Opens a tab (the browser may block it outside a click).
    pub fn openUrl(url: []const u8) bool {
        return js.open_url(url.ptr, url.len);
    }

    pub fn openPath(_: []const u8) bool {
        return false;
    }

    pub fn showInFolder(_: []const u8) void {}

    pub fn trash(_: []const u8) bool {
        return false;
    }

    pub fn beep() void {
        js.beep();
    }
};

pub const Directory = enum { data, cache, home, documents, downloads, desktop, temp };

/// A directory of the host's WASI file system (in memory, for the page's
/// life): `/home`, `/tmp`, and the app's own under `/home/.local/share`.
pub fn path(gpa: std.mem.Allocator, dir: Directory, app_name: []const u8) ![]u8 {
    return switch (dir) {
        .temp => gpa.dupe(u8, "/tmp"),
        .home => gpa.dupe(u8, "/home"),
        .documents => gpa.dupe(u8, "/home/Documents"),
        .downloads => gpa.dupe(u8, "/home/Downloads"),
        .desktop => gpa.dupe(u8, "/home/Desktop"),
        .data => std.fs.path.join(gpa, &.{ "/home/.local/share", app_name }),
        .cache => std.fs.path.join(gpa, &.{ "/home/.cache", app_name }),
    };
}

/// The browser's `prefers-color-scheme`, or the page's own choice
/// (`data-myzig-theme="dark"` or `"light"` on its root element).
pub fn isDark() bool {
    return @import("../appearance.zig").dark(js.is_dark());
}

pub fn accentColor() [3]f32 {
    return .{ 0, 0.48, 1 };
}
