//! Runs spec examples: each parsed whole must give the HTML cmark writes,
//! and so must the same text appended a byte at a time and in chunks,
//! with the end healed while it streams and read exactly once it is done.
const std = @import("std");
const doc = @import("document.zig");
const html = @import("html.zig");

pub const Example = struct { n: u32, md: []const u8, html: []const u8 };

pub const Ext = enum { commonmark, gfm };

fn streamed(gpa: std.mem.Allocator, md: []const u8, ext: doc.Extensions, step: usize, streaming: bool) []u8 {
    var d = doc.Document.init(gpa, ext);
    defer d.deinit();
    d.setStreaming(streaming);
    var i: usize = 0;
    while (i < md.len) {
        const e = @min(md.len, i + step);
        d.append(md[i..e]);
        // Inlines asked for as a view asks for them, healed at the end.
        for (0..d.len()) |k| switch (d.block(@intCast(k)).kind) {
            .paragraph, .heading, .table_cell => _ = d.inlines(@intCast(k)),
            else => {},
        };
        i = e;
    }
    d.setStreaming(false);
    var out: std.ArrayList(u8) = .empty;
    html.render(&d, gpa, &out);
    return out.toOwnedSlice(gpa) catch @panic("OOM");
}

pub fn run(examples: []const Example, which: Ext) !void {
    const gpa = std.testing.allocator;
    const ext: doc.Extensions = if (which == .gfm) .gfm else .commonmark;
    var failed: usize = 0;
    for (examples) |ex| {
        const got = html.toHtml(gpa, ex.md, ext);
        defer gpa.free(got);
        if (!std.mem.eql(u8, got, ex.html)) {
            failed += 1;
            std.debug.print("example {d}:\n{s}\ngot  {s}\nwant {s}\n", .{ ex.n, ex.md, got, ex.html });
            continue;
        }
        for ([_]usize{ 1, 5 }) |step| for ([_]bool{ false, true }) |streaming| {
            const s = streamed(gpa, ex.md, ext, step, streaming);
            defer gpa.free(s);
            if (!std.mem.eql(u8, s, ex.html)) {
                failed += 1;
                std.debug.print("example {d} appended {d} at a time (streaming {}):\n{s}\ngot  {s}\nwant {s}\n", .{ ex.n, step, streaming, ex.md, s, ex.html });
            }
        };
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}
