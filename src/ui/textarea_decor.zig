//! What a text view draws besides the text: text after a line's end (a
//! blame, a note), indent guides, with the indentation they follow, and
//! the spaces and tabs of the selection.
const std = @import("std");
const Color = @import("types.zig").Color;
const Context = @import("context.zig").Context;
const TextDoc = @import("textdoc.zig").TextDoc;

pub const After = struct { text: []const u8, color: Color };

/// A line built and its top (`Result.lines`).
pub const LineTop = struct { line: usize, y: f32 };

/// Lines at each level of a line's indentation.
pub const Guides = struct {
    color: Color,
    /// Columns a level is (the indentation unit's width).
    unit: usize = 4,
    /// Columns a tab is.
    tab: usize = 4,
};

/// The columns a line's indentation takes, or null for a blank line.
pub fn indentCols(s: []const u8, tab: usize) ?usize {
    var n: usize = 0;
    for (s) |ch| switch (ch) {
        ' ' => n += 1,
        '\t' => n += tab - n % tab,
        '\r', '\n' => {},
        else => return n,
    };
    return null;
}

/// The indentation of the last line with text above `line` (within 200
/// lines), which blank lines under it take.
pub fn colsAbove(arena: std.mem.Allocator, doc: *const TextDoc, line: usize, tab: usize) usize {
    var up = line;
    while (up > 0 and line - up < 200) {
        up -= 1;
        if (indentCols(doc.line(arena, up), tab)) |n| return n;
    }
    return 0;
}

/// The spaces and tabs selected on row `sub` of `lr` (bytes `a` to `b` of
/// its line), faint: a dot for a space, an arrow as wide as a tab.
pub fn selectedWhitespace(c: *Context, lr: anytype, sub: usize, a: usize, b: usize, x0: f32, y: f32, row_h: f32, color: Color) void {
    const cy = @round(y + row_h / 2);
    var i = a;
    while (i < b and i < lr.str.len) : (i += 1) {
        const ch = lr.str[i];
        if (ch != ' ' and ch != '\t') continue;
        const xa = x0 + lr.xIn(sub, i);
        const xb = x0 + lr.xIn(sub, i + 1);
        if (ch == ' ') {
            dot(c, (xa + xb) / 2 - 1, cy - 1, 2, 2, color);
            continue;
        }
        // An arrow: its shaft, then its head a pixel a step back.
        const l = xa + 3;
        const r = xb - 4;
        if (r - l < 4) continue;
        dot(c, l, cy, r - l, 1, color);
        for (1..4) |k| {
            const fk: f32 = @floatFromInt(k);
            dot(c, r - fk, cy - fk, 1, 1, color);
            dot(c, r - fk, cy + fk, 1, 1, color);
        }
    }
}

fn dot(c: *Context, x: f32, y: f32, w: f32, h: f32, color: Color) void {
    _ = c.leaf(.{ .absolute = true, .width = .{ .px = w }, .height = .{ .px = h }, .background = color, .offset = .{ .x = x, .y = y } }, .none, null);
}

test indentCols {
    try std.testing.expectEqual(@as(?usize, 8), indentCols("\t    x", 4));
    try std.testing.expectEqual(@as(?usize, null), indentCols("   \r", 4));
}
