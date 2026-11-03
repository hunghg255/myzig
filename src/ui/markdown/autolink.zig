//! GitHub's autolinks without angle brackets: `www.example.com`,
//! `https://example.com/path` and `someone@example.com`, ending before
//! trailing punctuation and unbalanced parentheses.
const std = @import("std");

/// Whether an autolink may start at `s[i]`: at the start, or after a
/// space, `*`, `_`, `~` or `(`, and beyond ASCII after a space or
/// punctuation, such as “ or （.
pub fn boundary(s: []const u8, i: usize) bool {
    if (i == 0) return true;
    return switch (s[i - 1]) {
        ' ', '\t', '\n', '\r', '*', '_', '~', '(' => true,
        0x80...0xff => {
            var k = i - 1;
            while (k > 0 and s[k] & 0xc0 == 0x80) k -= 1;
            const cp = std.unicode.utf8Decode(s[k..i]) catch return false;
            return endsLink(cp);
        },
        else => false,
    };
}

/// The length of the character at `s[j]`, beyond ASCII, when it ends a
/// link: a space, or punctuation but dashes and connectors (which paths
/// such as Wikipedia's use), as the CJK ， and 。 or curly quotes that text
/// written without spaces puts right after a link. Null for others:
/// letters beyond ASCII, as in IDN hosts and paths, go on.
fn ending(s: []const u8, j: usize) ?usize {
    if (s[j] < 0x80) return null;
    const n = std.unicode.utf8ByteSequenceLength(s[j]) catch return null;
    if (j + n > s.len) return null;
    const cp = std.unicode.utf8Decode(s[j..][0..n]) catch return null;
    return if (endsLink(cp)) n else null;
}

/// Unicode's spaces (Zs, line and paragraph separators) and punctuation
/// (P*) but Pd and Pc, in the blocks text puts beside links.
fn endsLink(cp: u21) bool {
    return switch (cp) {
        0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        0xa1, 0xa7, 0xab, 0xb6, 0xb7, 0xbb, 0xbf => true,
        0x2016...0x2027, 0x2030...0x203e, 0x2041...0x2043, 0x2045...0x2051, 0x2053, 0x2055...0x205e => true,
        0x3001...0x3003, 0x3008...0x3011, 0x3014...0x301b, 0x301d...0x301f, 0x303d, 0x30fb => true,
        0xff01...0xff03, 0xff05...0xff0a, 0xff0c, 0xff0e, 0xff0f, 0xff1a, 0xff1b, 0xff1f, 0xff20 => true,
        0xff3b...0xff3d, 0xff5b, 0xff5d, 0xff5f...0xff65 => true,
        else => false,
    };
}

fn domainChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c >= 0x80;
}

/// The end of a valid domain at `s[i]`, or null: labels between periods,
/// without underscores in the last two; `need_dot` for www. links.
fn domain(s: []const u8, i: usize, need_dot: bool) ?usize {
    var j = i;
    var dots: usize = 0;
    var underscore_last: [2]bool = .{ false, false };
    var label_start = j;
    while (j < s.len) {
        const c = s[j];
        if (c == '.') {
            if (j == label_start) break;
            if (j + 1 >= s.len or !domainChar(s[j + 1])) break;
            dots += 1;
            underscore_last = .{ underscore_last[1], false };
            j += 1;
            label_start = j;
        } else if (domainChar(c) and ending(s, j) == null) {
            if (c == '_') underscore_last[1] = true;
            j += 1;
        } else break;
    }
    if (j == i or (need_dot and dots == 0)) return null;
    if (underscore_last[0] or underscore_last[1]) return null;
    return j;
}

/// The end of a www. or http(s):// link at `s[i]`, or null.
pub fn url(s: []const u8, i: usize) ?usize {
    const r = s[i..];
    var at: usize = undefined;
    var need_dot = true;
    if (std.mem.startsWith(u8, r, "www.")) {
        at = i;
    } else if (std.mem.startsWith(u8, r, "http://")) {
        at = i + 7;
        need_dot = false;
    } else if (std.mem.startsWith(u8, r, "https://")) {
        at = i + 8;
        need_dot = false;
    } else if (std.mem.startsWith(u8, r, "ftp://")) {
        at = i + 6;
        need_dot = false;
    } else return null;
    var j = domain(s, at, need_dot) orelse return null;
    while (j < s.len and !std.ascii.isWhitespace(s[j]) and s[j] != '<' and ending(s, j) == null) j += 1;
    return trimEnd(s, i, j);
}

/// The link's end without what follows it rather than belongs to it.
fn trimEnd(s: []const u8, start: usize, end_in: usize) usize {
    var end = end_in;
    while (end > start) {
        const c = s[end - 1];
        if (std.mem.indexOfScalar(u8, "?!.,:*_~'\"", c) != null) {
            end -= 1;
        } else if (c == ')') {
            const open = std.mem.count(u8, s[start..end], "(");
            const close = std.mem.count(u8, s[start..end], ")");
            if (close > open) end -= 1 else break;
        } else if (c == ';') {
            // An entity reference at the end: &hl;
            var k = end - 1;
            while (k > start and std.ascii.isAlphanumeric(s[k - 1])) k -= 1;
            if (k > start and s[k - 1] == '&' and k < end - 1) end = k - 1 else break;
        } else break;
    }
    return end;
}

fn localChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '+' or c == '_' or c == '-';
}

/// How many bytes at the end of `t` may be an address's local part.
pub fn localRun(t: []const u8) usize {
    var n: usize = 0;
    while (n < t.len and localChar(t[t.len - 1 - n])) n += 1;
    return n;
}

/// The end of an address whose `@` is at `s[at]`, after a local part of
/// `local` bytes.
pub fn email(s: []const u8, at: usize, local: usize) ?usize {
    if (local == 0) return null;
    var j = at + 1;
    var dots: usize = 0;
    var label = j;
    while (j < s.len) {
        const c = s[j];
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') {
            j += 1;
        } else if (c == '.' and j > label and j + 1 < s.len and (std.ascii.isAlphanumeric(s[j + 1]) or s[j + 1] == '-' or s[j + 1] == '_')) {
            dots += 1;
            j += 1;
            label = j;
        } else break;
    }
    if (dots == 0 or j == label) return null;
    const last = s[j - 1];
    if (last == '-' or last == '_') return null;
    return j;
}

test "autolinks" {
    const s = "see www.commonmark.org/he<lp";
    try std.testing.expectEqual(@as(?usize, 25), url(s, 4));
    try std.testing.expectEqual(@as(?usize, 22), url("Visit https://a.b/c(d)).", 6));
    try std.testing.expect(url("www.a_b.c_d", 0) == null);
    try std.testing.expectEqual(@as(?usize, 11), email("foo@bar.baz.", 3, 3));
}

test "autolinks end at punctuation beyond ASCII, not at letters" {
    const cjk = "见https://a.cn/x，然后";
    try std.testing.expectEqualStrings("https://a.cn/x", cjk[3..url(cjk, 3).?]);
    const quoted = "“www.a.org/b”";
    try std.testing.expectEqualStrings("www.a.org/b", quoted[3..url(quoted, 3).?]);
    try std.testing.expect(boundary(quoted, 3));
    try std.testing.expect(!boundary("见www.a.org", 3));
    const idn = "https://例子.cn/路径—二 x";
    try std.testing.expectEqualStrings("https://例子.cn/路径—二", idn[0..url(idn, 0).?]);
}
