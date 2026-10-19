//! `myzig_assets.zig`: the Zig module listing the files of a built
//! frontend, each embedded with @embedFile, which the web template's
//! build.zig imports as "assets". The CLI writes it whenever the files
//! change (generate, dev, build), so that adding a page needs no Zig.
const std = @import("std");
const fsx = @import("fsx.zig");
const Ctx = fsx.Ctx;

pub const file_name = "myzig_assets.zig";

/// Files that are not assets: this module, the generated client (the app
/// serves its own /myzig.js) and what tools leave around.
pub fn skipped(rel: []const u8) bool {
    const base = std.fs.path.basenamePosix(rel);
    for ([_][]const u8{ file_name, "myzig.js", "myzig.d.ts" }) |s| if (std.mem.eql(u8, rel, s)) return true;
    if (base.len > 0 and base[0] == '.') return true;
    var it = std.mem.tokenizeScalar(u8, rel, '/');
    while (it.next()) |part| if (std.mem.eql(u8, part, "node_modules") or (part.len > 0 and part[0] == '.')) return true;
    return false;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The module's source for files (relative paths, forward slashes).
pub fn source(gpa: std.mem.Allocator, files: []const []const u8) ![]u8 {
    const sorted = try gpa.dupe([]const u8, files);
    defer gpa.free(sorted);
    std.mem.sort([]const u8, sorted, {}, lessThan);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(
        \\//! The files of this directory, embedded into the app. Written by the
        \\//! myzig CLI (`myzig generate`, `dev` and `build`): don't edit it.
        \\const myzig = @import("myzig");
        \\
        \\pub const files = [_]myzig.Asset{
        \\
    );
    for (sorted) |f| {
        try w.writeAll("    .{ .path = \"/");
        try zigEscape(w, f);
        try w.writeAll("\", .data = @embedFile(\"");
        try zigEscape(w, f);
        try w.writeAll("\") },\n");
    }
    try w.writeAll("};\n");
    return out.toOwnedSlice();
}

fn zigEscape(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '\\', '"' => {
            try w.writeByte('\\');
            try w.writeByte(c);
        },
        else => if (c < ' ') try w.print("\\x{x:0>2}", .{c}) else try w.writeByte(c),
    };
}

/// Writes the module of the directory `dir` when it changed; returns
/// whether it did.
pub fn write(ctx: Ctx, dir: []const u8) !bool {
    var files: std.ArrayList([]const u8) = .empty;
    var d = try std.Io.Dir.cwd().openDir(ctx.io, dir, .{ .iterate = true });
    defer d.close(ctx.io);
    var walker = try d.walk(ctx.gpa);
    defer walker.deinit();
    while (try walker.next(ctx.io)) |e| {
        if (e.kind != .file) continue;
        const rel = try ctx.gpa.dupe(u8, e.path);
        std.mem.replaceScalar(u8, rel, '\\', '/');
        if (!skipped(rel)) try files.append(ctx.gpa, rel);
    }
    const src = try source(ctx.gpa, files.items);
    const path = try ctx.join(&.{ dir, file_name });
    const old = fsx.read(ctx, path) catch "";
    if (std.mem.eql(u8, old, src)) return false;
    try fsx.write(ctx.io, path, src);
    return true;
}

test source {
    const gpa = std.testing.allocator;
    const s = try source(gpa, &.{ "style.css", "index.html", "img/a \"b\".png" });
    defer gpa.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s,
        \\    .{ .path = "/img/a \"b\".png", .data = @embedFile("img/a \"b\".png") },
        \\    .{ .path = "/index.html", .data = @embedFile("index.html") },
        \\    .{ .path = "/style.css", .data = @embedFile("style.css") },
        \\};
    ) != null);
}

test skipped {
    try std.testing.expect(skipped("myzig.d.ts"));
    try std.testing.expect(skipped("myzig_assets.zig"));
    try std.testing.expect(skipped("node_modules/x/y.js"));
    try std.testing.expect(skipped(".DS_Store"));
    try std.testing.expect(!skipped("index.html"));
    try std.testing.expect(!skipped("js/myzig.js"));
}
