//! GitHub's autolinks without angle brackets: `www.example.com`,
//! `https://example.com/path` and `someone@example.com`, ending before
//! trailing punctuation and unbalanced parentheses.
const std = @import("std");

/// Whether an autolink may start at `s[i]`: at the start, or after a
/// space, `*`, `_`, `~` or `(`.
pub fn boundary(s: []const u8, i: usize) bool {
    if (i == 0) return true;
    return switch (s[i - 1]) {
        ' ', '\t', '\n', '\r', '*', '_', '~', '(' => true,
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
        } else if (domainChar(c)) {
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
    while (j < s.len and !std.ascii.isWhitespace(s[j]) and s[j] != '<') j += 1;
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
