//! Greedy line breaking over a shaped paragraph where myzig lays text out:
//! at spaces (or, for a word wider than the line, between characters) and
//! at newlines, measuring characters in logical order, so that a paragraph
//! of mixed directions breaks as its text reads; each line is then laid
//! out, and reordered, on its own.
const std = @import("std");
const runs = @import("text_runs.zig");
const caret = @import("text_caret.zig");
const utf8 = @import("utf8.zig");

pub fn breakLines(gpa: std.mem.Allocator, lines: *std.ArrayList(runs.Line), s: []const u8, lay: runs.Layout, max: f32) !void {
    const xs = try gpa.alloc(f32, s.len + 1);
    defer gpa.free(xs);
    caret.logicalX(lay, s, xs);
    var start: usize = 0;
    while (start < s.len) {
        const x0 = xs[start];
        var end = start;
        var last_break: ?usize = null;
        var i = start;
        while (i < s.len) {
            if (s[i] == '\n') {
                end = i;
                break;
            }
            const n = utf8.seqLen(s[i]);
            const next = @min(s.len, i + n);
            // A character that ends past the line, unless it is a space.
            if (s[i] != ' ' and xs[next] - x0 > max and i > start) {
                end = last_break orelse i;
                break;
            }
            if (s[i] == ' ' or s[i] == '-' or s[i] == '/') last_break = next;
            i = next;
            end = i;
        }
        const trimmed = std.mem.trimEnd(u8, s[start..end], " \t\r");
        try lines.append(gpa, .{ .start = start, .end = start + trimmed.len, .width = xs[start + trimmed.len] - x0 });
        var next_start = end;
        if (next_start < s.len and s[next_start] == '\n') next_start += 1;
        while (next_start < s.len and s[next_start] == ' ') next_start += 1;
        if (next_start == start) next_start += 1;
        start = next_start;
        if (start == s.len and end < s.len and s[end] == '\n') try lines.append(gpa, .{ .start = s.len, .end = s.len, .width = 0 });
    }
}
