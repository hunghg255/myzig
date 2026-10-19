//! The static site of an app for browsers, as `zig build web` (`build.zig`
//! here) and `myzig build --platform web` lay it out: the page and its host
//! embedded, the app's WebAssembly, and its fonts with their list.
//!
//!     index.html  host.js  host_gl.js  host_wasi.js  app.wasm
//!     fonts/fonts.json  fonts/*.ttf
const std = @import("std");

pub const File = struct { name: []const u8, data: []const u8 };

/// The page and the host, beside the app's `app.wasm`.
pub const files = [_]File{
    .{ .name = "index.html", .data = @embedFile("index.html") },
    .{ .name = "host.js", .data = @embedFile("host.js") },
    .{ .name = "host_gl.js", .data = @embedFile("host_gl.js") },
    .{ .name = "host_wasi.js", .data = @embedFile("host_wasi.js") },
};

/// Fonts to bundle where the app gives none, the first set found: free
/// families first, then the system's own UI fonts (check their licenses
/// before publishing a site with them).
pub const system_fonts = [_][]const []const u8{
    &.{ "/usr/share/fonts/truetype/inter/Inter-Regular.ttf", "/usr/share/fonts/truetype/inter/Inter-Bold.ttf" },
    &.{ "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" },
    &.{ "/usr/share/fonts/TTF/DejaVuSans.ttf", "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf" },
    &.{ "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf", "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf" },
    &.{ "C:\\Windows\\Fonts\\segoeui.ttf", "C:\\Windows\\Fonts\\seguisb.ttf", "C:\\Windows\\Fonts\\segoeuib.ttf" },
    &.{ "/System/Library/Fonts/Supplemental/Arial.ttf", "/System/Library/Fonts/Supplemental/Arial Bold.ttf" },
};

/// Whether a file is a font the host loads (TrueType, or a collection).
pub fn isFont(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    return std.ascii.eqlIgnoreCase(ext, ".ttf") or std.ascii.eqlIgnoreCase(ext, ".ttc");
}

/// `fonts/fonts.json`: the files the host fetches, as a JSON array.
pub fn fontList(gpa: std.mem.Allocator, names: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(names, .{}, &out.writer);
    return out.toOwnedSlice();
}

test fontList {
    const gpa = std.testing.allocator;
    const s = try fontList(gpa, &.{ "Inter-Regular.ttf", "a \"b\".ttf" });
    defer gpa.free(s);
    try std.testing.expectEqualStrings("[\"Inter-Regular.ttf\",\"a \\\"b\\\".ttf\"]", s);
    try std.testing.expect(isFont("X.TTF") and isFont("y.ttc") and !isFont("z.otf"));
}
