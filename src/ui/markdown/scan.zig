//! Scanners of inline syntax, shared by the block and inline parsers:
//! characters' classes, entities and escapes, link destinations, titles
//! and labels, definitions, autolinks and raw HTML tags.
const std = @import("std");
const utf8 = @import("../utf8.zig");

pub fn isPunct(c: u8) bool {
    return switch (c) {
        '!'...'/', ':'...'@', '['...'`', '{'...'~' => true,
        else => false,
    };
}

pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

/// Unicode whitespace (Zs, tab, line endings, form feed).
pub fn isUnicodeSpace(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', '\r', 0x0c, 0xa0, 0x1680, 0x2000...0x200a, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

/// Unicode punctuation and symbols (P and S), approximated by their blocks.
pub fn isUnicodePunct(cp: u21) bool {
    if (cp < 0x80) return isPunct(@intCast(cp));
    return switch (cp) {
        0xa1...0xbf, 0xd7, 0xf7, 0x2010...0x2027, 0x2030...0x205e, 0x2070...0x209f, 0x20a0...0x20cf, 0x2100...0x2bff, 0x2e00...0x2e7f, 0x3001...0x3003, 0x3008...0x3020, 0x3030, 0xfe10...0xfe19, 0xfe30...0xfe6b, 0xff01...0xff0f, 0xff1a...0xff20, 0xff3b...0xff40, 0xff5b...0xff65 => true,
        else => false,
    };
}

/// The code point before byte `i` of `s` (a newline at the start).
pub fn cpBefore(s: []const u8, i: usize) u21 {
    if (i == 0) return '\n';
    var j = i - 1;
    while (j > 0 and s[j] & 0xC0 == 0x80 and i - j < 4) j -= 1;
    return utf8.decode(s[j..i]) catch s[i - 1];
}

/// The code point at byte `i` of `s` (a newline past the end).
pub fn cpAt(s: []const u8, i: usize) u21 {
    if (i >= s.len) return '\n';
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return s[i];
    if (i + n > s.len) return s[i];
    return utf8.decode(s[i .. i + n]) catch s[i];
}

const Entity = struct { name: []const u8, value: []const u8 };

/// The named entities read: those of prose, and the spec's examples. Others stay text.
const entities = [_]Entity{
    .{ .name = "amp", .value = "&" },           .{ .name = "lt", .value = "<" },                   .{ .name = "gt", .value = ">" },
    .{ .name = "quot", .value = "\"" },         .{ .name = "apos", .value = "'" },                 .{ .name = "nbsp", .value = "\u{a0}" },
    .{ .name = "copy", .value = "©" },          .{ .name = "reg", .value = "®" },                  .{ .name = "trade", .value = "™" },
    .{ .name = "hellip", .value = "…" },        .{ .name = "mdash", .value = "—" },                .{ .name = "ndash", .value = "–" },
    .{ .name = "lsquo", .value = "‘" },         .{ .name = "rsquo", .value = "’" },                .{ .name = "ldquo", .value = "“" },
    .{ .name = "rdquo", .value = "”" },         .{ .name = "laquo", .value = "«" },                .{ .name = "raquo", .value = "»" },
    .{ .name = "middot", .value = "·" },        .{ .name = "bull", .value = "•" },                 .{ .name = "deg", .value = "°" },
    .{ .name = "plusmn", .value = "±" },        .{ .name = "times", .value = "×" },                .{ .name = "divide", .value = "÷" },
    .{ .name = "frac12", .value = "½" },        .{ .name = "frac14", .value = "¼" },               .{ .name = "frac34", .value = "¾" },
    .{ .name = "para", .value = "¶" },          .{ .name = "sect", .value = "§" },                 .{ .name = "cent", .value = "¢" },
    .{ .name = "pound", .value = "£" },         .{ .name = "yen", .value = "¥" },                  .{ .name = "euro", .value = "€" },
    .{ .name = "auml", .value = "ä" },          .{ .name = "ouml", .value = "ö" },                 .{ .name = "uuml", .value = "ü" },
    .{ .name = "Auml", .value = "Ä" },          .{ .name = "Ouml", .value = "Ö" },                 .{ .name = "Uuml", .value = "Ü" },
    .{ .name = "szlig", .value = "ß" },         .{ .name = "eacute", .value = "é" },               .{ .name = "egrave", .value = "è" },
    .{ .name = "agrave", .value = "à" },        .{ .name = "ccedil", .value = "ç" },               .{ .name = "ntilde", .value = "ñ" },
    .{ .name = "larr", .value = "←" },          .{ .name = "rarr", .value = "→" },                 .{ .name = "uarr", .value = "↑" },
    .{ .name = "darr", .value = "↓" },          .{ .name = "harr", .value = "↔" },                 .{ .name = "AElig", .value = "Æ" },
    .{ .name = "Dcaron", .value = "Ď" },        .{ .name = "HilbertSpace", .value = "ℋ" },         .{ .name = "DifferentialD", .value = "ⅆ" },
    .{ .name = "ClockwiseContourIntegral", .value = "∲" }, .{ .name = "ngE", .value = "≧̸" }, .{ .name = "ouml", .value = "ö" },
};

/// The entity or numeric character reference at `s[i]` (an `&`): its
/// length and its text, written into `buf`.
pub fn entity(s: []const u8, i: usize, buf: *[8]u8) ?struct { len: usize, text: []const u8 } {
    if (i + 2 >= s.len or s[i] != '&') return null;
    if (s[i + 1] == '#') {
        var j = i + 2;
        const hex = j < s.len and (s[j] == 'x' or s[j] == 'X');
        if (hex) j += 1;
        const from = j;
        var v: u32 = 0;
        while (j < s.len and j - from < (if (hex) @as(usize, 6) else 7)) : (j += 1) {
            const d = std.fmt.charToDigit(s[j], if (hex) 16 else 10) catch break;
            v = v * (if (hex) @as(u32, 16) else 10) + d;
        }
        if (j == from or j >= s.len or s[j] != ';') return null;
        const cp: u21 = if (v == 0 or v > 0x10ffff or (v >= 0xd800 and v <= 0xdfff)) 0xfffd else @intCast(v);
        const n = std.unicode.utf8Encode(cp, buf[0..4]) catch return null;
        return .{ .len = j + 1 - i, .text = buf[0..n] };
    }
    var j = i + 1;
    while (j < s.len and j - i <= 32 and std.ascii.isAlphanumeric(s[j])) j += 1;
    if (j >= s.len or s[j] != ';' or j == i + 1) return null;
    const name = s[i + 1 .. j];
    for (entities) |e| if (std.mem.eql(u8, e.name, name)) return .{ .len = j + 1 - i, .text = e.value };
    return null;
}

/// `s` with its backslash escapes and entities resolved, appended to `out`.
pub fn unescapeInto(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len and isPunct(s[i + 1])) {
            try out.append(gpa, s[i + 1]);
            i += 2;
        } else if (s[i] == '&') {
            var buf: [8]u8 = undefined;
            if (entity(s, i, &buf)) |e| {
                try out.appendSlice(gpa, e.text);
                i += e.len;
            } else {
                try out.append(gpa, '&');
                i += 1;
            }
        } else {
            try out.append(gpa, s[i]);
            i += 1;
        }
    }
}

pub const Dest = struct { end: usize, raw: []const u8 };

/// A link destination at `s[i]`: `<…>`, or a run without spaces whose
/// parentheses balance.
pub fn linkDestination(s: []const u8, i: usize) ?Dest {
    if (i < s.len and s[i] == '<') {
        var j = i + 1;
        while (j < s.len) : (j += 1) switch (s[j]) {
            '\\' => {
                if (j + 1 < s.len and isPunct(s[j + 1])) j += 1;
            },
            '>' => return .{ .end = j + 1, .raw = s[i + 1 .. j] },
            '<', '\n', '\r' => return null,
            else => {},
        };
        return null;
    }
    var j = i;
    var depth: usize = 0;
    while (j < s.len) {
        const c = s[j];
        if (c == '\\' and j + 1 < s.len and isPunct(s[j + 1])) {
            j += 2;
        } else if (c == '(') {
            depth += 1;
            if (depth > 32) return null;
            j += 1;
        } else if (c == ')') {
            if (depth == 0) break;
            depth -= 1;
            j += 1;
        } else if (c <= 0x20 or c == 0x7f) break else j += 1;
    }
    if (depth != 0) return null;
    if (j == i and (j >= s.len or s[j] != ')')) return null;
    return .{ .end = j, .raw = s[i..j] };
}

/// A link title at `s[i]`, between quotes or parentheses: its end and what
/// is between them.
pub fn linkTitle(s: []const u8, i: usize) ?Dest {
    if (i >= s.len) return null;
    const close: u8 = switch (s[i]) {
        '"' => '"',
        '\'' => '\'',
        '(' => ')',
        else => return null,
    };
    var j = i + 1;
    while (j < s.len) : (j += 1) {
        const c = s[j];
        if (c == '\\' and j + 1 < s.len and isPunct(s[j + 1])) {
            j += 1;
        } else if (c == close) {
            return .{ .end = j + 1, .raw = s[i + 1 .. j] };
        } else if (close == ')' and c == '(') return null;
    }
    return null;
}

/// The end of a link label at `s[i]` (a `[`), after its `]`.
pub fn linkLabel(s: []const u8, i: usize) ?usize {
    if (i >= s.len or s[i] != '[') return null;
    var j = i + 1;
    while (j < s.len and j - i <= 1000) : (j += 1) switch (s[j]) {
        '\\' => {
            if (j + 1 < s.len and isPunct(s[j + 1])) j += 1;
        },
        '[' => return null,
        ']' => return j + 1,
        else => {},
    };
    return null;
}

/// Spaces and tabs, and at most one line ending, from `i`.
pub fn spnl(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
    if (j < s.len and s[j] == '\n') {
        j += 1;
        while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
    }
    return j;
}

pub const Definition = struct { end: usize, label: []const u8, dest: []const u8, title: ?[]const u8 };

/// A link reference definition at the start of `s[i..]`, to the end of its line.
pub fn definition(s: []const u8, i: usize) ?Definition {
    const le = linkLabel(s, i) orelse return null;
    if (le >= s.len or s[le] != ':') return null;
    const label = s[i + 1 .. le - 1];
    if (std.mem.trim(u8, label, " \t\r\n").len == 0) return null;
    var j = spnl(s, le + 1);
    const d = linkDestination(s, j) orelse return null;
    if (d.raw.len == 0 and s[j] != '<') return null;
    j = d.end;
    const before = j;
    const k = spnl(s, j);
    if (k > before) if (linkTitle(s, k)) |t| {
        if (lineEnd(s, t.end)) |e| return .{ .end = e, .label = label, .dest = d.raw, .title = t.raw };
    };
    const e = lineEnd(s, before) orelse return null;
    return .{ .end = e, .label = label, .dest = d.raw, .title = null };
}

/// After spaces and tabs from `i`, the end of the line (past its newline).
fn lineEnd(s: []const u8, i: usize) ?usize {
    var j = i;
    while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
    if (j == s.len) return j;
    if (s[j] == '\n') return j + 1;
    return null;
}

/// An autolink at `s[i]` (a `<`): its end and whether it is an email address.
pub fn autolink(s: []const u8, i: usize) ?struct { end: usize, email: bool } {
    var j = i + 1;
    // A URI: a scheme, a colon, then no spaces, < or >.
    if (j < s.len and std.ascii.isAlphabetic(s[j])) {
        var k = j + 1;
        while (k < s.len and (std.ascii.isAlphanumeric(s[k]) or s[k] == '+' or s[k] == '.' or s[k] == '-')) k += 1;
        if (k - j >= 2 and k - j <= 32 and k < s.len and s[k] == ':') {
            k += 1;
            while (k < s.len and s[k] > 0x20 and s[k] != '<' and s[k] != '>') k += 1;
            if (k < s.len and s[k] == '>') return .{ .end = k + 1, .email = false };
        }
    }
    // An email address.
    while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or std.mem.indexOfScalar(u8, ".!#$%&'*+/=?^_`{|}~-", s[j]) != null)) j += 1;
    if (j == i + 1 or j >= s.len or s[j] != '@') return null;
    j += 1;
    while (true) {
        const from = j;
        while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or s[j] == '-') and j - from < 63) j += 1;
        if (j == from or s[from] == '-' or s[j - 1] == '-') return null;
        if (j < s.len and s[j] == '.') {
            j += 1;
            continue;
        }
        if (j < s.len and s[j] == '>') return .{ .end = j + 1, .email = true };
        return null;
    }
}

fn skipSpaces(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and isSpace(s[j])) j += 1;
    return j;
}

fn tagName(s: []const u8, i: usize) usize {
    var j = i;
    if (j >= s.len or !std.ascii.isAlphabetic(s[j])) return i;
    while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or s[j] == '-')) j += 1;
    return j;
}

/// Attributes from `i`; returns where they end.
fn attributes(s: []const u8, i: usize) usize {
    var j = i;
    while (true) {
        const ws = skipSpaces(s, j);
        if (ws == j or ws >= s.len) return j;
        const c = s[ws];
        if (!(std.ascii.isAlphabetic(c) or c == '_' or c == ':')) return j;
        var k = ws + 1;
        while (k < s.len and (std.ascii.isAlphanumeric(s[k]) or s[k] == '_' or s[k] == '.' or s[k] == ':' or s[k] == '-')) k += 1;
        j = k;
        // A value.
        const eq = skipSpaces(s, k);
        if (eq < s.len and s[eq] == '=') {
            var v = skipSpaces(s, eq + 1);
            if (v >= s.len) return j;
            if (s[v] == '"' or s[v] == '\'') {
                const q = s[v];
                const close = std.mem.indexOfScalarPos(u8, s, v + 1, q) orelse return j;
                j = close + 1;
            } else {
                const from = v;
                while (v < s.len and !isSpace(s[v]) and std.mem.indexOfScalar(u8, "\"'=<>`", s[v]) == null) v += 1;
                if (v == from) return j;
                j = v;
            }
        }
    }
}

/// A raw HTML tag at `s[i]` (a `<`): its end.
pub fn htmlTag(s: []const u8, i: usize) ?usize {
    if (i + 1 >= s.len) return null;
    const c = s[i + 1];
    if (std.ascii.isAlphabetic(c)) {
        var j = attributes(s, tagName(s, i + 1));
        j = skipSpaces(s, j);
        if (j < s.len and s[j] == '/') j += 1;
        if (j < s.len and s[j] == '>') return j + 1;
        return null;
    }
    if (c == '/') {
        const n = tagName(s, i + 2);
        if (n == i + 2) return null;
        const j = skipSpaces(s, n);
        if (j < s.len and s[j] == '>') return j + 1;
        return null;
    }
    if (c == '?') {
        const e = std.mem.indexOfPos(u8, s, i + 2, "?>") orelse return null;
        return e + 2;
    }
    if (c == '!') {
        const rest = s[i + 2 ..];
        if (std.mem.startsWith(u8, rest, "--")) {
            if (std.mem.startsWith(u8, rest[2..], ">")) return i + 5;
            if (std.mem.startsWith(u8, rest[2..], "->")) return i + 6;
            const e = std.mem.indexOfPos(u8, s, i + 4, "-->") orelse return null;
            return e + 3;
        }
        if (std.mem.startsWith(u8, rest, "[CDATA[")) {
            const e = std.mem.indexOfPos(u8, s, i + 9, "]]>") orelse return null;
            return e + 3;
        }
        if (rest.len > 0 and std.ascii.isAlphabetic(rest[0])) {
            const e = std.mem.indexOfScalarPos(u8, s, i + 2, '>') orelse return null;
            return e + 1;
        }
    }
    return null;
}

test "entities and escapes" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try unescapeInto(std.testing.allocator, &out, "a\\*b &amp; &#35; &#x22; &bogus; &#0;");
    try std.testing.expectEqualStrings("a*b & # \" &bogus; \u{fffd}", out.items);
}

test "destinations, titles, labels" {
    try std.testing.expectEqualStrings("/a(b)", linkDestination("/a(b))", 0).?.raw);
    try std.testing.expectEqualStrings("a b", linkDestination("<a b>", 0).?.raw);
    try std.testing.expect(linkDestination("(a", 0) == null);
    try std.testing.expectEqualStrings("t", linkTitle("\"t\"", 0).?.raw);
    try std.testing.expectEqual(@as(?usize, 5), linkLabel("[foo]", 0));
    const d = definition("[Foo]: /url \"title\"\nrest", 0).?;
    try std.testing.expectEqualStrings("/url", d.dest);
    try std.testing.expectEqualStrings("title", d.title.?);
    try std.testing.expectEqual(@as(usize, 20), d.end);
    try std.testing.expect(autolink("<https://x.y>", 0).? .end == 13);
    try std.testing.expect(autolink("<a@b.c>", 0).?.email);
    try std.testing.expectEqual(@as(?usize, 13), htmlTag("<a href=\"x\">", 0).? + 1);
}
