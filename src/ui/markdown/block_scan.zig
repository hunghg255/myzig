//! Scanners of block syntax, on one line: the starts of headings, fences,
//! HTML blocks, thematic breaks, setext underlines, list markers, and the
//! rows of tables.
const std = @import("std");
const scan = @import("scan.zig");
const doc = @import("document.zig");

fn spaceOrTab(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn blankFrom(s: []const u8, i: usize) bool {
    for (s[@min(i, s.len)..]) |c| if (!spaceOrTab(c)) return false;
    return true;
}

/// An ATX heading's level at `s[i]`, or 0.
pub fn atxStart(s: []const u8, i: usize) u8 {
    var j = i;
    while (j < s.len and s[j] == '#' and j - i < 7) j += 1;
    const n = j - i;
    if (n == 0 or n > 6) return 0;
    if (j < s.len and !spaceOrTab(s[j])) return 0;
    return @intCast(n);
}

/// A heading's content without its closing sequence of #s.
pub fn atxContent(s: []const u8) []const u8 {
    var t = std.mem.trim(u8, s, " \t");
    var k = t.len;
    while (k > 0 and t[k - 1] == '#') k -= 1;
    if (k == 0) return "";
    if (k < t.len and spaceOrTab(t[k - 1])) t = std.mem.trimEnd(u8, t[0..k], " \t");
    return t;
}

/// The length of an opening code fence at `s[i]`, or 0.
pub fn fenceStart(s: []const u8, i: usize) usize {
    if (i >= s.len or (s[i] != '`' and s[i] != '~')) return 0;
    const c = s[i];
    var j = i;
    while (j < s.len and s[j] == c) j += 1;
    if (j - i < 3) return 0;
    if (c == '`' and std.mem.indexOfScalarPos(u8, s, j, '`') != null) return 0;
    return j - i;
}

/// The length of a closing fence of `c` at `s[i]`, or 0.
pub fn fenceClose(s: []const u8, i: usize, c: u8) usize {
    var j = i;
    while (j < s.len and s[j] == c) j += 1;
    if (j - i < 3 or !blankFrom(s, j)) return 0;
    return j - i;
}

/// A thematic break at `s[i]`.
pub fn thematicBreak(s: []const u8, i: usize) bool {
    if (i >= s.len) return false;
    const c = s[i];
    if (c != '*' and c != '-' and c != '_') return false;
    var n: usize = 0;
    for (s[i..]) |x| {
        if (x == c) n += 1 else if (!spaceOrTab(x)) return false;
    }
    return n >= 3;
}

/// A setext underline's level at `s[i]`, or 0.
pub fn setextLevel(s: []const u8, i: usize) u8 {
    if (i >= s.len or (s[i] != '=' and s[i] != '-')) return 0;
    const c = s[i];
    var j = i;
    while (j < s.len and s[j] == c) j += 1;
    if (!blankFrom(s, j)) return 0;
    return if (c == '=') 1 else 2;
}

pub const ListMarker = struct { len: usize, ordered: bool, marker: u8, number: u32 };

/// A list marker at `s[i]`; one interrupting a paragraph must have
/// content, and start at 1 if ordered.
pub fn listMarker(s: []const u8, i: usize, interrupts: bool) ?ListMarker {
    if (i >= s.len) return null;
    const c = s[i];
    if (c == '*' or c == '-' or c == '+') {
        if (i + 1 < s.len and !spaceOrTab(s[i + 1])) return null;
        if (interrupts and blankFrom(s, i + 1)) return null;
        return .{ .len = 1, .ordered = false, .marker = c, .number = 0 };
    }
    var j = i;
    var n: u32 = 0;
    while (j < s.len and std.ascii.isDigit(s[j]) and j - i < 9) : (j += 1) n = n * 10 + (s[j] - '0');
    if (j == i or j >= s.len or (s[j] != '.' and s[j] != ')')) return null;
    if (j + 1 < s.len and !spaceOrTab(s[j + 1])) return null;
    if (interrupts and (n != 1 or blankFrom(s, j + 1))) return null;
    return .{ .len = j + 1 - i, .ordered = true, .marker = s[j], .number = n };
}

const block_tags = [_][]const u8{
    "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col", "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p", "param", "search", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "title", "tr", "track", "ul",
};
const raw_tags = [_][]const u8{ "pre", "script", "style", "textarea" };

fn startsWithFold(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

/// The type (1 to 7) of an HTML block starting at `s[i]`, or 0. Type 7
/// cannot interrupt a paragraph.
pub fn htmlStart(s: []const u8, i: usize, in_paragraph: bool) u8 {
    if (i >= s.len or s[i] != '<') return 0;
    const r = s[i + 1 ..];
    for (raw_tags) |t| if (startsWithFold(r, t)) {
        const after = r[t.len..];
        if (after.len == 0 or after[0] == '>' or spaceOrTab(after[0])) return 1;
    };
    if (std.mem.startsWith(u8, r, "!--")) return 2;
    if (std.mem.startsWith(u8, r, "?")) return 3;
    if (std.mem.startsWith(u8, r, "![CDATA[")) return 5;
    if (r.len > 1 and r[0] == '!' and std.ascii.isAlphabetic(r[1])) return 4;
    const name_at: usize = if (r.len > 0 and r[0] == '/') 1 else 0;
    var e = name_at;
    while (e < r.len and std.ascii.isAlphanumeric(r[e])) e += 1;
    const name = r[name_at..e];
    for (block_tags) |t| if (std.ascii.eqlIgnoreCase(name, t)) {
        const after = r[e..];
        if (after.len == 0 or after[0] == '>' or spaceOrTab(after[0]) or std.mem.startsWith(u8, after, "/>")) return 6;
    };
    if (in_paragraph) return 0;
    // A complete open or closing tag alone on its line.
    for (raw_tags) |t| if (std.ascii.eqlIgnoreCase(name, t)) return 0;
    const end = scan.htmlTag(s, i) orelse return 0;
    if (s[i + 1] == '!' or s[i + 1] == '?') return 0;
    if (std.mem.indexOfScalar(u8, s[i..end], '\n') != null) return 0;
    return if (blankFrom(s, end)) 7 else 0;
}

/// Whether line `s` ends an HTML block of `kind`.
pub fn htmlEnds(s: []const u8, kind: u8) bool {
    return switch (kind) {
        1 => blk: {
            for (raw_tags) |t| {
                var k: usize = 0;
                while (std.mem.indexOfPos(u8, s, k, "</")) |at| : (k = at + 1) {
                    if (startsWithFold(s[at + 2 ..], t) and at + 2 + t.len < s.len and s[at + 2 + t.len] == '>') break :blk true;
                }
            }
            break :blk false;
        },
        2 => std.mem.indexOf(u8, s, "-->") != null,
        3 => std.mem.indexOf(u8, s, "?>") != null,
        4 => std.mem.indexOfScalar(u8, s, '>') != null,
        5 => std.mem.indexOf(u8, s, "]]>") != null,
        else => false,
    };
}

/// The cells of a table row: byte ranges of `s`, trimmed, split at pipes
/// not escaped, without the leading and trailing pipes.
pub fn rowCells(s: []const u8, out: *[64][2]usize) [][2]usize {
    var a: usize = 0;
    var b = s.len;
    while (a < b and spaceOrTab(s[a])) a += 1;
    while (b > a and spaceOrTab(s[b - 1])) b -= 1;
    if (a < b and s[a] == '|') a += 1;
    if (b > a and s[b - 1] == '|' and !(b >= 2 + a and s[b - 2] == '\\')) b -= 1;
    var n: usize = 0;
    var start = a;
    var i = a;
    while (i <= b) : (i += 1) {
        if (i < b and s[i] == '\\') {
            i += 1;
            continue;
        }
        if (i == b or s[i] == '|') {
            if (n == out.len) break;
            var x = start;
            var y = @min(i, b);
            while (x < y and spaceOrTab(s[x])) x += 1;
            while (y > x and spaceOrTab(s[y - 1])) y -= 1;
            out[n] = .{ x, y };
            n += 1;
            start = i + 1;
        }
    }
    return out[0..n];
}

/// A table's delimiter row: the alignment of each column, or null.
pub fn delimiterRow(s: []const u8, out: *[64]doc.Align) ?[]doc.Align {
    if (std.mem.indexOfScalar(u8, s, '|') == null and std.mem.indexOfScalar(u8, s, ':') == null) {
        // One column needs a pipe, or it is a setext underline.
        return null;
    }
    var cells_buf: [64][2]usize = undefined;
    const cells = rowCells(s, &cells_buf);
    if (cells.len == 0) return null;
    for (cells, 0..) |c, k| {
        const t = s[c[0]..c[1]];
        if (t.len == 0) return null;
        const left = t[0] == ':';
        const right = t[t.len - 1] == ':';
        const dashes = t[@intFromBool(left) .. t.len - @intFromBool(right and t.len > 1)];
        if (dashes.len == 0) return null;
        for (dashes) |x| if (x != '-') return null;
        out[k] = if (left and right) .center else if (left) .left else if (right) .right else .none;
    }
    return out[0..cells.len];
}

test "block starts" {
    try std.testing.expectEqual(@as(u8, 2), atxStart("## a", 0));
    try std.testing.expectEqual(@as(u8, 0), atxStart("#a", 0));
    try std.testing.expectEqualStrings("foo", atxContent(" foo ## "));
    try std.testing.expectEqualStrings("foo#", atxContent("foo#"));
    try std.testing.expectEqual(@as(usize, 3), fenceStart("```zig", 0));
    try std.testing.expect(thematicBreak("* * *", 0));
    try std.testing.expectEqual(@as(u8, 2), setextLevel("---  ", 0));
    try std.testing.expect(listMarker("10) x", 0, false).?.number == 10);
    try std.testing.expect(listMarker("2. x", 0, true) == null);
    try std.testing.expectEqual(@as(u8, 6), htmlStart("<div>", 0, true));
    try std.testing.expectEqual(@as(u8, 7), htmlStart("<a href=\"x\">", 0, false));
    var buf: [64][2]usize = undefined;
    try std.testing.expectEqual(@as(usize, 2), rowCells("| a | b \\| c |", &buf).len);
    var al: [64]doc.Align = undefined;
    const a = delimiterRow("|:-|-:|:-:|---|", &al).?;
    try std.testing.expectEqualSlices(doc.Align, &.{ .left, .right, .center, .none }, a);
}
