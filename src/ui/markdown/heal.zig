//! Healing: what the end of a document still being written leaves open in
//! its last block's inlines is completed, from the parser's own
//! delimiters, so that `**bol` shows bold, an unclosed code span as code,
//! and `[the docs](https://ex` as a link not to follow yet. The source
//! never changes: the text parsed is the block's with closers added.
const std = @import("std");
const inl = @import("inlines.zig");

/// Parses `s` completed into `p`'s tree; `tmp` holds the completed text.
pub fn complete(p: *inl.Parser, s_in: []const u8, tmp: *std.ArrayList(u8)) void {
    const gpa = p.gpa;
    const s = trimTrailingMarkers(s_in);
    tmp.clearRetainingCapacity();
    tmp.appendSlice(gpa, s) catch @panic("OOM");
    p.heal_from = s.len;
    // A link whose destination is being written: [text](http…
    tmp.appendSlice(gpa, pendingLink(s)) catch @panic("OOM");
    // A code span not closed.
    const ticks = openCodeSpan(tmp.items);
    if (ticks > 0) {
        var run: usize = 0;
        while (run < tmp.items.len and tmp.items[tmp.items.len - 1 - run] == '`') run += 1;
        if (run >= ticks) run = 0;
        tmp.appendNTimes(gpa, '`', ticks - run) catch @panic("OOM");
    }
    // The closing tildes of strikethrough half written: ~~struck~.
    const t = tmp.items;
    if (t.len > 0 and t[t.len - 1] == '~' and !std.mem.endsWith(u8, t, "~~") and std.mem.indexOf(u8, t, "~~") != null) tmp.append(gpa, '~') catch @panic("OOM");

    p.run(tmp.items);
    // Emphasis and strikethrough not closed, innermost first.
    var open: std.ArrayList([2]u32) = .empty;
    defer open.deinit(gpa);
    for (p.leftover.items) |dl| {
        if (dl.c == '*' and wordInside(tmp.items, dl.at, dl.orig)) continue; // 2*3
        if (dl.c == '~' and dl.orig == 1) continue; // ~200, about
        open.append(gpa, .{ dl.at, (@as(u32, dl.c) << 8) | dl.n }) catch @panic("OOM");
    }
    if (open.items.len > 0) {
        std.mem.sort([2]u32, open.items, {}, struct {
            fn later(_: void, a: [2]u32, b: [2]u32) bool {
                return a[0] > b[0];
            }
        }.later);
        for (open.items) |o| tmp.appendNTimes(gpa, @intCast(o[1] >> 8), o[1] & 0xff) catch @panic("OOM");
        p.run(tmp.items);
    }
    // The text of a link being written shows without its bracket.
    if (p.brackets.items.len > 0) {
        const br = p.brackets.items[p.brackets.items.len - 1];
        const x = &p.nodes.items[br.node];
        x.b = x.a;
    }
}

/// Whether a run of `n` delimiters at `i` has letters or digits on both
/// sides, as 2*3, which is not emphasis being written.
fn wordInside(s: []const u8, i: usize, n: usize) bool {
    if (i == 0 or i + n >= s.len) return false;
    return std.ascii.isAlphanumeric(s[i - 1]) and std.ascii.isAlphanumeric(s[i + n]);
}

/// `s` without what its end may be starting, with nothing after it yet: a
/// run of delimiters opening emphasis or a code span, a bracket, a backslash.
pub fn trimTrailingMarkers(s_in: []const u8) []const u8 {
    var s = s_in;
    while (true) {
        const t = std.mem.trimEnd(u8, s, " \t");
        if (t.len == 0) return t;
        const c = t[t.len - 1];
        var k = t.len;
        while (k > 0 and t[k - 1] == c) k -= 1;
        const run = t.len - k;
        const opening = k == 0 or t[k - 1] == ' ' or t[k - 1] == '\t' or t[k - 1] == '\n';
        var next: []const u8 = t;
        if (std.mem.endsWith(u8, t, "![")) {
            next = t[0 .. t.len - 2];
        } else if (c == '[') {
            next = t[0..k];
        } else if ((c == '*' or c == '_' or c == '~') and opening) {
            next = t[0..k];
        } else if (c == '`' and openCodeSpan(t[0..k]) != run) {
            next = t[0..k];
        } else if (c == '\\' and run % 2 == 1) {
            next = t[0 .. t.len - 1];
        } else return t;
        s = next;
    }
}

/// What closes the destination of a link being written at the end of
/// `s`, after `](`: the parentheses it opened and the link's, or `>)`.
pub fn pendingLink(s: []const u8) []const u8 {
    const k = std.mem.lastIndexOf(u8, s, "](") orelse return "";
    if (std.mem.indexOfScalar(u8, s[0..k], '[') == null) return "";
    if (std.mem.count(u8, s[0..k], "`") % 2 == 1) return "";
    const rest = s[k + 2 ..];
    if (rest.len > 0 and rest[0] == '<') {
        if (std.mem.indexOfAny(u8, rest, ">\n") != null) return "";
        return ">)";
    }
    var depth: usize = 0;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) switch (rest[i]) {
        '\\' => i += 1,
        '(' => depth += 1,
        ')' => {
            if (depth == 0) return "";
            depth -= 1;
        },
        ' ', '\t', '\n' => return "",
        else => {},
    };
    const closers = "))))))))))))))))))))))))))))))))))";
    return closers[0..@min(closers.len, depth + 1)];
}

/// The length of the run of backticks opening a code span that `s` leaves
/// open, or 0.
pub fn openCodeSpan(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len) : (i += 1) switch (s[i]) {
        '\\' => i += 1,
        '`' => {
            var j = i;
            while (j < s.len and s[j] == '`') j += 1;
            const n = j - i;
            var k = j;
            var found = false;
            while (std.mem.indexOfScalarPos(u8, s, k, '`')) |m| {
                var e = m;
                while (e < s.len and s[e] == '`') e += 1;
                if (e - m == n) {
                    found = true;
                    i = e - 1;
                    break;
                }
                k = e;
            }
            if (!found) return if (j == s.len) 0 else n;
        },
        else => {},
    };
    return 0;
}

test "trailing markers and pending links" {
    try std.testing.expectEqualStrings("a", trimTrailingMarkers("a **"));
    try std.testing.expectEqualStrings("a", trimTrailingMarkers("a ["));
    try std.testing.expectEqualStrings("a **b**", trimTrailingMarkers("a **b**"));
    try std.testing.expectEqualStrings(")", pendingLink("[a](http://x"));
    try std.testing.expectEqualStrings("", pendingLink("[a](x) b"));
    try std.testing.expectEqual(@as(usize, 1), openCodeSpan("a `b"));
    try std.testing.expectEqual(@as(usize, 0), openCodeSpan("a `b`"));
}
