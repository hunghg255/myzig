//! Links printed as text, which Ctrl+click (Command+click on macOS) opens
//! as it does hyperlinks (OSC 8): URLs, and file paths, absolute, from ~,
//! ./ or ../, with a slash, or a file name with a :line, each may end in
//! :line or :line:col. On Windows also those with a drive (C:\dir\file,
//! C:/dir/file) or with backslashes (dir\file, .\file), as mygo finds
//! them. Matching is leftmost-first over a row's codepoints, as mygo's
//! regular expressions match; what likely ends the sentence (punctuation,
//! a closing bracket the link did not open) is left out.
const std = @import("std");
const builtin = @import("builtin");

pub const Range = [2]usize;

fn space(c: u21) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

/// What a URL may hold: not spaces, quotes, angle brackets, backquotes or
/// controls.
fn urlChar(c: u21) bool {
    return !space(c) and c >= 0x20 and c != '"' and c != '\'' and c != '<' and c != '>' and c != '`';
}

/// What a path's name may hold: as a URL, and not ':' (which starts :line).
fn nameChar(c: u21) bool {
    return urlChar(c) and c != ':';
}

fn word(c: u21) bool {
    return c < 0x80 and (std.ascii.isAlphanumeric(@intCast(c)) or c == '_');
}

/// A character of a path's segment: [\w.@+-].
fn seg(c: u21) bool {
    return word(c) or c == '.' or c == '@' or c == '+' or c == '-';
}

fn digit(c: u21) bool {
    return c >= '0' and c <= '9';
}

fn startsWith(s: []const u21, i: usize, prefix: []const u8) bool {
    if (i + prefix.len > s.len) return false;
    for (prefix, 0..) |p, k| if (s[i + k] != p) return false;
    return true;
}

/// The end of a URL starting at `i`, or null.
fn url(s: []const u21, i: usize) ?usize {
    inline for (.{ "https://", "http://", "ftp://", "file://", "mailto:" }) |scheme| {
        if (startsWith(s, i, scheme)) {
            var e = i + scheme.len;
            const begin = e;
            while (e < s.len and urlChar(s[e])) e += 1;
            if (e > begin) return e;
        }
    }
    return null;
}

/// After `i`, an optional `:\d+(:\d+)?`.
fn lineSuffix(s: []const u21, i: usize) usize {
    var e = i;
    if (e + 1 < s.len and s[e] == ':' and digit(s[e + 1])) {
        e += 1;
        while (e < s.len and digit(s[e])) e += 1;
        if (e + 1 < s.len and s[e] == ':' and digit(s[e + 1])) {
            e += 1;
            while (e < s.len and digit(s[e])) e += 1;
        }
    }
    return e;
}

/// `(~|\.{1,2})?SEP name line` at `i`: a path from the root, home, or here.
fn rooted(s: []const u21, i: usize, sep: u21, prefix_needed: bool) ?usize {
    var prefixes: [3]usize = undefined;
    var n: usize = 0;
    if (i < s.len and s[i] == '~') {
        prefixes[n] = 1;
        n += 1;
    }
    if (i < s.len and s[i] == '.') {
        if (i + 1 < s.len and s[i + 1] == '.') {
            prefixes[n] = 2;
            n += 1;
        }
        prefixes[n] = 1;
        n += 1;
    }
    if (!prefix_needed) {
        prefixes[n] = 0;
        n += 1;
    }
    for (prefixes[0..n]) |p| {
        const at = i + p;
        if (at >= s.len or s[at] != sep) continue;
        var e = at + 1;
        while (e < s.len and nameChar(s[e])) e += 1;
        if (e > at + 1) return lineSuffix(s, e);
    }
    return null;
}

/// `[\w.@+-]+(?:SEP[\w.@+-]+)+SEP? line` at `i`: segments joined by `sep`.
fn segments(s: []const u21, i: usize, sep: u21) ?usize {
    var e = i;
    while (e < s.len and seg(s[e])) e += 1;
    if (e == i) return null;
    var parts: usize = 0;
    while (e + 1 < s.len and s[e] == sep and seg(s[e + 1])) {
        e += 1;
        while (e < s.len and seg(s[e])) e += 1;
        parts += 1;
    }
    if (parts == 0) return null;
    if (e < s.len and s[e] == sep) e += 1;
    return lineSuffix(s, e);
}

/// `[\w@+-][\w.@+-]*\.\w+:\d+(?::\d+)?` at `i`: a file name with a line.
fn fileLine(s: []const u21, i: usize) ?usize {
    if (i >= s.len or !(word(s[i]) or s[i] == '@' or s[i] == '+' or s[i] == '-')) return null;
    var e = i + 1;
    while (e < s.len and seg(s[e])) e += 1;
    // The extension is the last dot's: \w+ up to the ':' that follows.
    var d = e;
    while (d > i + 1 and s[d - 1] != '.') d -= 1;
    if (d <= i + 1 or d == e) return null;
    for (s[d..e]) |c| if (!word(c)) return null;
    if (e + 1 >= s.len or s[e] != ':' or !digit(s[e + 1])) return null;
    return lineSuffix(s, e);
}

/// A drive's path, `[A-Za-z]:[\\/]name line`.
fn drive(s: []const u21, i: usize) ?usize {
    if (i + 2 >= s.len or s[i] >= 0x80 or !std.ascii.isAlphabetic(@intCast(s[i])) or s[i + 1] != ':') return null;
    if (s[i + 2] != '\\' and s[i + 2] != '/') return null;
    var e = i + 3;
    while (e < s.len and nameChar(s[e])) e += 1;
    if (e == i + 3) return null;
    return lineSuffix(s, e);
}

fn path(s: []const u21, i: usize, windows: bool) ?usize {
    if (windows) {
        if (drive(s, i)) |e| return e;
        if (rooted(s, i, '\\', true)) |e| return e;
        if (segments(s, i, '\\')) |e| return e;
    }
    if (rooted(s, i, '/', false)) |e| return e;
    if (segments(s, i, '/')) |e| return e;
    return fileLine(s, i);
}

/// `[start, end)` without what likely ends the sentence around it.
fn trim(s: []const u21, start: usize, end_in: usize) usize {
    var end = end_in;
    while (end > start) {
        const last = s[end - 1];
        switch (last) {
            '.', ',', ';', ':', '!', '?' => end -= 1,
            ')', ']', '}' => {
                const open: u21 = switch (last) {
                    ')' => '(',
                    ']' => '[',
                    else => '{',
                };
                var opens: usize = 0;
                var closes: usize = 0;
                for (s[start..end]) |c| {
                    if (c == open) opens += 1;
                    if (c == last) closes += 1;
                }
                if (opens >= closes) return end;
                end -= 1;
            },
            else => return end,
        }
    }
    return end;
}

fn matchAt(s: []const u21, cols: []const u16, col: u16, comptime kind: enum { url, path }, windows: bool) ?Range {
    var i: usize = 0;
    while (i < s.len) {
        const m = switch (kind) {
            .url => url(s, i),
            .path => path(s, i, windows),
        };
        const e = m orelse {
            i += 1;
            continue;
        };
        const end = trim(s, i, e);
        if (end > i and cols[i] <= col and col <= cols[end - 1]) return .{ i, end };
        i = e;
    }
    return null;
}

/// The URL of a row's text (codepoints in columns `cols`) at column `col`.
pub fn urlAt(text: []const u21, cols: []const u16, col: u16) ?Range {
    return matchAt(text, cols, col, .url, false);
}

/// The file path at column `col`, as `urlAt`; with Windows' paths when
/// `windows` is set (`native` is this platform's).
pub fn pathAt(text: []const u21, cols: []const u16, col: u16, windows: bool) ?Range {
    return matchAt(text, cols, col, .path, windows);
}

pub const native = builtin.os.tag == .windows;

fn expectAt(row: []const u8, col: u16, want: []const u8, comptime kind: enum { url, path }, windows: bool) !void {
    var text: [128]u21 = undefined;
    var cols: [128]u16 = undefined;
    var n: usize = 0;
    var it = (try std.unicode.Utf8View.init(row)).iterator();
    while (it.nextCodepoint()) |cp| : (n += 1) {
        text[n] = cp;
        cols[n] = @intCast(n);
    }
    const r = switch (kind) {
        .url => urlAt(text[0..n], cols[0..n], col),
        .path => pathAt(text[0..n], cols[0..n], col, windows),
    };
    var got: [256]u8 = undefined;
    var len: usize = 0;
    if (r) |range| for (text[range[0]..range[1]]) |cp| {
        len += try std.unicode.utf8Encode(cp, got[len..]);
    };
    try std.testing.expectEqualStrings(want, got[0..len]);
}

test "URLs printed as text" {
    const row = "see https://example.com/a_(b)?q=1. and (http://x.org/y), mailto:me@x.org!";
    try expectAt(row, 0, "", .url, false);
    try expectAt(row, 4, "https://example.com/a_(b)?q=1", .url, false);
    try expectAt(row, 20, "https://example.com/a_(b)?q=1", .url, false);
    try expectAt(row, 33, "", .url, false);
    try expectAt(row, 40, "http://x.org/y", .url, false);
    try expectAt(row, 58, "mailto:me@x.org", .url, false);
}

test "file paths printed as text" {
    try expectAt("Updated internal/app/embed.go:51 and more", 10, "internal/app/embed.go:51", .path, false);
    try expectAt("  ⎿  Read /Users/me/repo/main.go (12 lines)", 12, "/Users/me/repo/main.go", .path, false);
    try expectAt("see ./notes/todo.txt.", 8, "./notes/todo.txt", .path, false);
    try expectAt("open ~/Downloads/clip.mp4", 10, "~/Downloads/clip.mp4", .path, false);
    try expectAt("main.go:250:3: undefined: x", 2, "main.go:250:3", .path, false);
    try expectAt("(src/a.go)", 3, "src/a.go", .path, false);
    try expectAt("just words here", 5, "", .path, false);
    try expectAt("version 1.2.3 ok", 9, "", .path, false);
}

test "Windows' paths: with a drive or backslashes" {
    try expectAt("  ⎿  Read D:\\projects\\mycode\\main.go (12 lines)", 20, "D:\\projects\\mycode\\main.go", .path, true);
    try expectAt("C:\\src\\app\\main.go:250:3: undefined: x", 5, "C:\\src\\app\\main.go:250:3", .path, true);
    try expectAt("see C:/Users/me/notes.txt.", 8, "C:/Users/me/notes.txt", .path, true);
    try expectAt("Updated cmd\\mayoi\\panel.go:51 and more", 10, "cmd\\mayoi\\panel.go:51", .path, true);
    try expectAt("run .\\build\\app.exe", 6, ".\\build\\app.exe", .path, true);
    try expectAt("go to ..\\other\\x.go", 8, "..\\other\\x.go", .path, true);
    try expectAt("PS D:\\projects\\mycode> git status", 8, "D:\\projects\\mycode", .path, true);
    try expectAt("Updated internal/app/embed.go:51 and more", 10, "internal/app/embed.go:51", .path, true);
    try expectAt("main.go:250:3: undefined: x", 2, "main.go:250:3", .path, true);
    try expectAt("just words here", 5, "", .path, true);
    // Elsewhere a backslash is no separator.
    try expectAt("cmd\\mayoi\\panel.go", 5, "", .path, false);
}
