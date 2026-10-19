//! Finding and replacing in the code editor: the query's matches in the
//! document, a line at a time (plain text with or without case, whole
//! words, or a regular expression), found again only when the query, its
//! options or the text change; going through them, and replacing one or
//! all of them (with a regular expression's groups, $1 to $9).
const std = @import("std");
const TextBuffer = @import("../textfield.zig").TextBuffer;
const TextArea = @import("../textarea.zig").TextArea;
const TextDoc = @import("../textdoc.zig").TextDoc;
const Regex = @import("regex.zig").Regex;
const isWord = @import("regex.zig").isWord;

pub const Flags = struct {
    case: bool = false,
    word: bool = false,
    regex: bool = false,
};

pub const Find = struct {
    open: bool = false,
    replacing: bool = false,
    query: TextBuffer = .{},
    replacement: TextBuffer = .{},
    flags: Flags = .{},
    /// The matches, in order, as byte ranges of the text.
    matches: std.ArrayList([2]usize) = .empty,
    /// The match the selection is on, or the next one after it.
    current: ?usize = null,
    /// The query is not a regular expression.
    bad_pattern: bool = false,
    /// What the matches were found for.
    key: u64 = 0,
    /// Matches found at most.
    limit: usize = 100_000,

    pub fn deinit(f: *Find, gpa: std.mem.Allocator) void {
        f.matches.deinit(gpa);
    }

    fn keyOf(f: *const Find, doc: *const TextDoc) u64 {
        var h = std.hash.Wyhash.init(doc.version);
        h.update(f.query.text());
        h.update(&.{ @intFromBool(f.flags.case), @intFromBool(f.flags.word), @intFromBool(f.flags.regex), 1 });
        return h.final();
    }

    /// Finds the matches again if the query, the flags or the text changed.
    pub fn update(f: *Find, gpa: std.mem.Allocator, doc: *const TextDoc) void {
        const k = f.keyOf(doc);
        if (k == f.key) return;
        f.key = k;
        f.matches.clearRetainingCapacity();
        f.bad_pattern = false;
        const q = f.query.text();
        if (q.len == 0) return;
        var re: ?Regex = null;
        if (f.flags.regex) re = Regex.compile(gpa, q, !f.flags.case) catch {
            f.bad_pattern = true;
            return;
        };
        defer if (re) |*r| r.deinit();
        var it = doc.rope.lines(gpa, 0);
        defer it.deinit();
        var start: usize = 0;
        while (it.next()) |line| : (start += line.len + 1) {
            var from: usize = 0;
            while (from <= line.len) {
                const m = (if (re) |*r| (if (r.find(line, from)) |g| g[0] else null) else f.plain(line, from)) orelse break;
                if (!f.flags.word or wholeWord(line, m)) {
                    f.matches.append(gpa, .{ start + m[0], start + m[1] }) catch return;
                    if (f.matches.items.len >= f.limit) return;
                }
                from = if (m[1] > m[0]) m[1] else m[0] + 1;
            }
        }
    }

    fn plain(f: *const Find, line: []const u8, from: usize) ?[2]usize {
        const q = f.query.text();
        const at = if (f.flags.case) std.mem.indexOfPos(u8, line, from, q) else indexIgnoringCase(line, from, q);
        return if (at) |a| .{ a, a + q.len } else null;
    }

    fn indexIgnoringCase(s: []const u8, from: usize, q: []const u8) ?usize {
        if (q.len > s.len) return null;
        var i = from;
        while (i + q.len <= s.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(s[i .. i + q.len], q)) return i;
        }
        return null;
    }

    fn wholeWord(line: []const u8, m: [2]usize) bool {
        if (m[0] > 0 and isWord(line[m[0] - 1]) and m[1] > m[0] and isWord(line[m[0]])) return false;
        if (m[1] < line.len and isWord(line[m[1]]) and m[1] > m[0] and isWord(line[m[1] - 1])) return false;
        return true;
    }

    /// The matches inside [a, b).
    pub fn within(f: *const Find, a: usize, b: usize) []const [2]usize {
        const items = f.matches.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (items[mid][1] <= a and items[mid][0] < a) lo = mid + 1 else hi = mid;
        }
        var end = lo;
        while (end < items.len and items[end][0] < b) end += 1;
        return items[lo..end];
    }

    /// The first match at or after `at`, round the end.
    fn after(f: *const Find, at: usize) ?usize {
        if (f.matches.items.len == 0) return null;
        for (f.matches.items, 0..) |m, i| if (m[0] >= at) return i;
        return 0;
    }

    /// Follows the selection: the match it is on, or the next.
    pub fn track(f: *Find, ta: *const TextArea) void {
        f.current = f.after(ta.sel.lo());
    }

    fn show(f: *Find, ta: *TextArea, i: usize) void {
        f.current = i;
        const m = f.matches.items[i];
        ta.select(m[0], m[1]);
    }

    /// Selects the match after the selection (before it, with `back`).
    pub fn step(f: *Find, ta: *TextArea, back: bool) void {
        const n = f.matches.items.len;
        if (n == 0) return;
        if (!back) {
            const at = if (ta.sel.empty()) ta.sel.lo() else ta.sel.lo() + 1;
            return f.show(ta, f.after(at) orelse 0);
        }
        var i = n;
        while (i > 0) {
            i -= 1;
            if (f.matches.items[i][0] < ta.sel.lo()) return f.show(ta, i);
        }
        f.show(ta, n - 1);
    }

    /// The text a match is replaced with: the replacement, with groups.
    fn expand(f: *const Find, gpa: std.mem.Allocator, doc: *const TextDoc, m: [2]usize, re: ?*const Regex) []const u8 {
        const rep = f.replacement.text();
        const r = re orelse return gpa.dupe(u8, rep) catch "";
        const line_no = doc.lineOf(m[0]);
        const start = doc.lineStart(line_no);
        const line = doc.line(gpa, line_no);
        defer gpa.free(line);
        const groups = r.find(line, m[0] - start) orelse return gpa.dupe(u8, rep) catch "";
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < rep.len) : (i += 1) {
            if (rep[i] == '$' and i + 1 < rep.len and std.ascii.isDigit(rep[i + 1])) {
                if (groups[rep[i + 1] - '0']) |g| out.appendSlice(gpa, line[g[0]..g[1]]) catch {};
                i += 1;
            } else if (rep[i] == '$' and i + 1 < rep.len and rep[i + 1] == '$') {
                out.append(gpa, '$') catch {};
                i += 1;
            } else out.append(gpa, rep[i]) catch {};
        }
        return out.toOwnedSlice(gpa) catch "";
    }

    fn compiled(f: *const Find, gpa: std.mem.Allocator) ?Regex {
        if (!f.flags.regex) return null;
        return Regex.compile(gpa, f.query.text(), !f.flags.case) catch null;
    }

    /// Replaces the selected match and selects the next; selects the
    /// next match first when the selection isn't one.
    pub fn replaceOne(f: *Find, gpa: std.mem.Allocator, ta: *TextArea) void {
        f.update(gpa, &ta.doc);
        const sel = [2]usize{ ta.sel.lo(), ta.sel.hi() };
        var on: ?[2]usize = null;
        for (f.matches.items) |m| if (m[0] == sel[0] and m[1] == sel[1]) {
            on = m;
        };
        const m = on orelse return f.step(ta, false);
        var re = f.compiled(gpa);
        defer if (re) |*r| r.deinit();
        const text = f.expand(gpa, &ta.doc, m, if (re) |*r| r else null);
        defer gpa.free(text);
        ta.replaceRange(m[0], m[1], text, .other);
        f.update(gpa, &ta.doc);
        if (f.after(m[0] + text.len)) |i| f.show(ta, i);
    }

    /// Replaces every match, as one step of undo; returns how many.
    pub fn replaceAll(f: *Find, gpa: std.mem.Allocator, ta: *TextArea) usize {
        f.update(gpa, &ta.doc);
        const n = f.matches.items.len;
        if (n == 0) return 0;
        var re = f.compiled(gpa);
        defer if (re) |*r| r.deinit();
        ta.doc.begin(.other, ta.sel, ta.time);
        var i = n;
        var caret: usize = 0;
        while (i > 0) {
            i -= 1;
            const m = f.matches.items[i];
            const text = f.expand(gpa, &ta.doc, m, if (re) |*r| r else null);
            defer gpa.free(text);
            ta.doc.edit(m[0], m[1], text);
            if (i == 0) caret = m[0] + text.len;
        }
        ta.sel = .at(@min(caret, ta.len()));
        ta.doc.end(ta.sel);
        ta.changed = true;
        ta.reveal = true;
        f.update(gpa, &ta.doc);
        return n;
    }
};
