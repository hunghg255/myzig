//! Selecting with the pointer, as in Ghostty: a drag selects cells, a
//! double click words and a triple click lines; the selection is kept by
//! the terminal (it follows its rows as output scrolls them) and copied
//! as Ghostty copies it. And the links under the pointer: hyperlinks
//! (OSC 8), then URLs and file paths printed as text. The callers hold
//! the terminal's lock.
const std = @import("std");
const vt = @import("vt.zig");
const links = @import("links.zig");

pub const Unit = enum { cell, word, line };

/// A selection being made: where it started, in the screen and its
/// scrollback (rows from the top of the scrollback), and by what unit.
pub const Drag = struct {
    x: u16,
    y: u32,
    unit: Unit,
};

/// The row of the screen and scrollback that row `row` of the viewport is.
pub fn screenRow(t: vt.Vt, row: u16) u32 {
    return @intCast(t.scrollbar().offset + row);
}

/// A row of the viewport as codepoints and their columns, into the
/// buffers: empty cells as spaces, wide characters once.
pub fn rowText(t: vt.Vt, row: u16, cols: u16, text: []u21, at: []u16) usize {
    var n: usize = 0;
    var cps: [8]u32 = undefined;
    var x: u16 = 0;
    while (x < cols and n < text.len) : (x += 1) {
        const ref = t.cellAt(x, row) orelse break;
        const cell = vt.decodeCell(t.rawCell(ref));
        if (cell.wide == .spacer_tail or cell.wide == .spacer_head) continue;
        const gs = t.graphemes(ref, &cps);
        if (gs.len == 0) {
            text[n] = ' ';
            at[n] = x;
            n += 1;
            continue;
        }
        for (gs) |cp| {
            if (n == text.len) break;
            text[n] = @intCast(@min(cp, 0x10FFFF));
            at[n] = x;
            n += 1;
        }
    }
    return n;
}

fn wordChar(c: u21) bool {
    return !(c == ' ' or c == '\t' or std.mem.indexOfScalar(u21, &.{ '"', '\'', '`', '|', ':', ';', ',', '(', ')', '[', ']', '{', '}', '<', '>' }, c) != null);
}

/// The columns of the word at column `x` of viewport row `row`.
fn wordAt(t: vt.Vt, row: u16, cols: u16, x: u16) [2]u16 {
    var text: [512]u21 = undefined;
    var at: [512]u16 = undefined;
    const n = rowText(t, row, cols, &text, &at);
    var i: usize = 0;
    while (i < n and at[i] < x) i += 1;
    if (i >= n or !wordChar(text[i])) return .{ x, x };
    var a = i;
    while (a > 0 and wordChar(text[a - 1])) a -= 1;
    var b = i;
    while (b + 1 < n and wordChar(text[b + 1])) b += 1;
    return .{ at[a], at[b] };
}

/// Selects from where `d` started to column `x` of viewport row `row`.
pub fn extend(t: vt.Vt, d: Drag, x: u16, row: u16, cols: u16) void {
    const sy = screenRow(t, row);
    var a: [2]u32 = .{ d.x, d.y };
    var b: [2]u32 = .{ x, sy };
    const forward = b[1] > a[1] or (b[1] == a[1] and b[0] >= a[0]);
    if (!forward) std.mem.swap([2]u32, &a, &b);
    switch (d.unit) {
        .cell => {},
        .line => {
            a[0] = 0;
            b[0] = cols -| 1;
        },
        .word => {
            // Words of rows in view: those that scrolled out keep their cell.
            const top = t.scrollbar().offset;
            if (a[1] >= top and a[1] - top < 0xFFFF) a[0] = wordAt(t, @intCast(a[1] - top), cols, @intCast(a[0]))[0];
            if (b[1] >= top and b[1] - top < 0xFFFF) b[0] = wordAt(t, @intCast(b[1] - top), cols, @intCast(b[0]))[1];
        },
    }
    const start = t.screenCell(a[0], a[1]) orelse return;
    const end = t.screenCell(b[0], b[1]) orelse return;
    const s: vt.Selection = .{ .start = start, .end = end };
    t.setSelection(&s);
}

pub fn clear(t: vt.Vt) void {
    t.setSelection(null);
}

/// The link at column `x` of viewport row `row`: a hyperlink, a URL, or
/// (`path`) a file path, into `buf`.
pub fn linkAt(t: vt.Vt, x: u16, row: u16, cols: u16, windows: bool, buf: []u8) ?struct { []const u8, bool } {
    const ref = t.cellAt(x, row) orelse return null;
    if (vt.decodeCell(t.rawCell(ref)).hyperlink) if (t.hyperlink(ref, buf)) |uri| return .{ uri, false };
    var text: [512]u21 = undefined;
    var at: [512]u16 = undefined;
    const n = rowText(t, row, cols, &text, &at);
    if (links.urlAt(text[0..n], at[0..n], x)) |r| return .{ encode(text[r[0]..r[1]], buf), false };
    if (links.pathAt(text[0..n], at[0..n], x, windows)) |r| return .{ encode(text[r[0]..r[1]], buf), true };
    return null;
}

/// The columns [first, last] of the link at cell `x` of `row`, as
/// `linkAt` finds it: a hyperlink's run of cells, or the URL or path
/// written there. Null when there is none.
pub fn linkSpanAt(t: vt.Vt, x: u16, row: u16, cols: u16, windows: bool) ?[2]u16 {
    const ref = t.cellAt(x, row) orelse return null;
    if (vt.decodeCell(t.rawCell(ref)).hyperlink) {
        var lo = x;
        while (lo > 0) : (lo -= 1) {
            const r = t.cellAt(lo - 1, row) orelse break;
            if (!vt.decodeCell(t.rawCell(r)).hyperlink) break;
        }
        var hi = x;
        while (hi + 1 < cols) : (hi += 1) {
            const r = t.cellAt(hi + 1, row) orelse break;
            if (!vt.decodeCell(t.rawCell(r)).hyperlink) break;
        }
        return .{ lo, hi };
    }
    var text: [512]u21 = undefined;
    var at: [512]u16 = undefined;
    const n = rowText(t, row, cols, &text, &at);
    const r = links.urlAt(text[0..n], at[0..n], x) orelse links.pathAt(text[0..n], at[0..n], x, windows) orelse return null;
    if (r[1] <= r[0]) return null;
    return .{ at[r[0]], at[r[1] - 1] };
}

fn encode(cps: []const u21, buf: []u8) []const u8 {
    var n: usize = 0;
    for (cps) |cp| {
        if (n + 4 > buf.len) break;
        n += std.unicode.utf8Encode(cp, buf[n..]) catch continue;
    }
    return buf[0..n];
}
