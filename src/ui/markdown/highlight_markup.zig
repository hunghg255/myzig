//! The highlighter's languages that aren't code: markup (HTML, XML, SVG,
//! Vue and Svelte: tags, attributes and their values, comments, entities,
//! and the code of `<script>` and the rules of `<style>` in their own
//! languages), Markdown (headings, quotes, list marks, emphasis, code and
//! links, fenced blocks) and diffs (lines added, removed, hunks, headers),
//! a line at a time from the state the line before left.
const std = @import("std");
const hl = @import("highlight.zig");
const types = @import("../types.zig");
const Span = types.Span;
const Language = hl.Language;
const State = hl.State;
const Colors = hl.Colors;
const H = hl.H;

pub fn line(gpa: std.mem.Allocator, lang: *const Language, s: []const u8, state: State, base: usize, colors: Colors, out: *std.ArrayList(Span)) State {
    var h: H = .{ .gpa = gpa, .out = out, .base = base, .colors = colors };
    return switch (lang.mode) {
        .markup => markup(&h, s, state),
        .markdown => markdown(&h, s, state),
        .diff => diff(&h, s),
        .code => state,
    };
}

fn nameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == ':' or c == '.' or c == '@' or c == '#' or c >= 0x80;
}

/// The code of a script or the rules of a style, as far as their closing
/// tag (or the line's end), in their language; the state that leaves.
fn embedded(h: *H, s: []const u8, from: usize, state: State) struct { at: usize, state: State } {
    const script = state == .markup_script or state == .markup_script_comment or state == .markup_script_backtick;
    const close = if (script) "</script" else "</style";
    const end = indexOfIgnoreCase(s, from, close) orelse s.len;
    const lang = hl.language(if (script) "js" else "css").?;
    const inner: State = switch (state) {
        .markup_script_comment, .markup_style_comment => .comment,
        .markup_script_backtick => .backtick,
        else => .none,
    };
    const left = hl.line(h.gpa, lang, s[from..end], inner, h.base + from, h.colors, h.out);
    if (end < s.len) return .{ .at = end, .state = .none };
    return .{ .at = end, .state = switch (left) {
        .comment => if (script) .markup_script_comment else .markup_style_comment,
        .backtick => .markup_script_backtick,
        else => if (script) .markup_script else .markup_style,
    } };
}

fn indexOfIgnoreCase(s: []const u8, from: usize, needle: []const u8) ?usize {
    if (s.len < needle.len) return null;
    var i = from;
    while (i + needle.len <= s.len) : (i += 1) if (std.ascii.eqlIgnoreCase(s[i..][0..needle.len], needle)) return i;
    return null;
}

fn markup(h: *H, s: []const u8, state_in: State) State {
    const c = h.colors;
    var i: usize = 0;
    var state = state_in;
    // The tag whose attributes go on, and whether it opens a script or a style.
    var opens: State = .none;
    while (true) {
        switch (state) {
            .markup_comment => {
                const e = std.mem.indexOfPos(u8, s, i, "-->") orelse {
                    h.span(i, s.len, c.comment, true);
                    return .markup_comment;
                };
                h.span(i, e + 3, c.comment, true);
                i = e + 3;
                state = .none;
            },
            .markup_script, .markup_script_comment, .markup_script_backtick, .markup_style, .markup_style_comment => {
                const r = embedded(h, s, i, state);
                i = r.at;
                state = r.state;
                if (state != .none) return state;
            },
            .markup_tag => {
                // Attributes: names, = and their values, to the tag's end.
                while (i < s.len and s[i] != '>') {
                    const ch = s[i];
                    if (ch == '"' or ch == '\'') {
                        const e = std.mem.indexOfScalarPos(u8, s, i + 1, ch) orelse s.len - 1;
                        h.span(i, e + 1, c.string, false);
                        i = e + 1;
                    } else if (nameChar(ch) or ch == '[' or ch == '(' or ch == '*') {
                        var j = i + 1;
                        while (j < s.len and (nameChar(s[j]) or s[j] == ']' or s[j] == ')')) j += 1;
                        h.span(i, j, c.type, false);
                        i = j;
                    } else if (ch == '{') {
                        // Svelte's and JSX's expressions.
                        const e = std.mem.indexOfScalarPos(u8, s, i, '}') orelse s.len - 1;
                        h.span(i, e + 1, c.function, false);
                        i = e + 1;
                    } else i += 1;
                }
                if (i >= s.len) return .markup_tag;
                h.span(i, i + 1, c.keyword, false);
                i += 1;
                state = if (i >= 2 and s[i - 2] == '/') .none else opens;
                opens = .none;
            },
            else => {
                // Text, with tags, comments and entities.
                while (i < s.len and s[i] != '<' and s[i] != '&') i += 1;
                if (i >= s.len) return .none;
                if (s[i] == '&') {
                    const e = std.mem.indexOfScalarPos(u8, s, i, ';');
                    if (e) |k| if (k - i < 12) {
                        h.span(i, k + 1, c.number, false);
                        i = k + 1;
                        continue;
                    };
                    i += 1;
                    continue;
                }
                if (std.mem.startsWith(u8, s[i..], "<!--")) {
                    state = .markup_comment;
                    continue;
                }
                // A tag: its name, then its attributes.
                var j = i + 1;
                if (j < s.len and (s[j] == '/' or s[j] == '!' or s[j] == '?')) j += 1;
                const name_at = j;
                while (j < s.len and nameChar(s[j])) j += 1;
                if (j == name_at) {
                    i += 1;
                    continue;
                }
                h.span(i, name_at, c.keyword, false);
                h.span(name_at, j, c.keyword, false);
                const name = s[name_at..j];
                const closing = s[i + 1] == '/';
                opens = if (closing) .none else if (std.ascii.eqlIgnoreCase(name, "script")) .markup_script else if (std.ascii.eqlIgnoreCase(name, "style")) .markup_style else .none;
                i = j;
                state = .markup_tag;
            },
        }
        if (i >= s.len) return state;
    }
}

fn markdown(h: *H, s: []const u8, state: State) State {
    const c = h.colors;
    const t = std.mem.trimStart(u8, s, " \t");
    const lead = s.len - t.len;
    // Fenced blocks: their lines as code, their fences faint.
    if (std.mem.startsWith(u8, t, "```") or std.mem.startsWith(u8, t, "~~~")) {
        h.span(lead, s.len, c.comment, false);
        return if (state == .md_fence) .none else .md_fence;
    }
    if (state == .md_fence) {
        h.span(0, s.len, c.string, false);
        return .md_fence;
    }
    if (state == .markup_comment or std.mem.startsWith(u8, t, "<!--")) {
        const from: usize = if (state == .markup_comment) 0 else lead;
        const e = std.mem.indexOfPos(u8, s, from, "-->") orelse {
            h.span(from, s.len, c.comment, true);
            return .markup_comment;
        };
        h.span(from, e + 3, c.comment, true);
        return .none;
    }
    if (t.len > 0 and t[0] == '#') {
        h.span(lead, s.len, c.keyword, false);
        return .none;
    }
    if (t.len > 0 and t[0] == '>') {
        h.span(lead, s.len, c.comment, true);
        return .none;
    }
    if (lead >= 4) {
        h.span(0, s.len, c.string, false);
        return .none;
    }
    var i: usize = lead;
    // A list's mark: -, *, + or a number and a dot.
    if (t.len > 1 and (t[0] == '-' or t[0] == '*' or t[0] == '+') and t[1] == ' ') {
        h.span(lead, lead + 1, c.keyword, false);
        i += 2;
    } else {
        var j = lead;
        while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
        if (j > lead and j + 1 < s.len and (s[j] == '.' or s[j] == ')') and s[j + 1] == ' ') {
            h.span(lead, j + 1, c.keyword, false);
            i = j + 2;
        }
    }
    // Inline: code, emphasis, links.
    while (i < s.len) {
        const ch = s[i];
        if (ch == '`') {
            const e = std.mem.indexOfScalarPos(u8, s, i + 1, '`') orelse break;
            h.span(i, e + 1, c.string, false);
            i = e + 1;
        } else if ((ch == '*' or ch == '_') and i + 1 < s.len and s[i + 1] == ch) {
            const close = [2]u8{ ch, ch };
            const e = std.mem.indexOfPos(u8, s, i + 2, &close) orelse break;
            h.span(i, e + 2, c.type, false);
            i = e + 2;
        } else if ((ch == '*' or ch == '_') and i + 1 < s.len and s[i + 1] != ' ' and (i == 0 or !std.ascii.isAlphanumeric(s[i - 1]))) {
            const e = std.mem.indexOfScalarPos(u8, s, i + 1, ch) orelse {
                i += 1;
                continue;
            };
            h.span(i, e + 1, c.type, true);
            i = e + 1;
        } else if (ch == '[' or (ch == '!' and i + 1 < s.len and s[i + 1] == '[')) {
            const open = if (ch == '!') i + 1 else i;
            const close = std.mem.indexOfScalarPos(u8, s, open, ']') orelse break;
            if (close + 1 < s.len and s[close + 1] == '(') {
                const end = std.mem.indexOfScalarPos(u8, s, close, ')') orelse s.len - 1;
                h.span(i, close + 1, c.function, false);
                h.span(close + 1, end + 1, c.string, false);
                i = end + 1;
            } else i = close + 1;
        } else i += 1;
    }
    return .none;
}

fn diff(h: *H, s: []const u8) State {
    const c = h.colors;
    if (std.mem.startsWith(u8, s, "+++") or std.mem.startsWith(u8, s, "---") or std.mem.startsWith(u8, s, "diff ") or std.mem.startsWith(u8, s, "index ")) {
        h.span(0, s.len, c.keyword, false);
    } else if (std.mem.startsWith(u8, s, "@@")) {
        h.span(0, s.len, c.function, false);
    } else if (std.mem.startsWith(u8, s, "+")) {
        h.span(0, s.len, c.string, false);
    } else if (std.mem.startsWith(u8, s, "-")) {
        h.span(0, s.len, c.key, false);
    }
    return .none;
}

test "markup: tags, attributes, a script's code, a comment going on" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(Span) = .empty;
    defer out.deinit(gpa);
    const colors = Colors.of(false);
    const html = hl.language("html").?;
    try std.testing.expectEqual(State.none, line(gpa, html, "<a href=\"x\">hi</a>", .none, 0, colors, &out));
    try std.testing.expectEqual(colors.keyword, out.items[0].color.?);
    out.clearRetainingCapacity();
    try std.testing.expectEqual(State.markup_tag, line(gpa, html, "<div class=\"a\"", .none, 0, colors, &out));
    try std.testing.expectEqual(State.markup_script, line(gpa, html, "<script setup>", .none, 0, colors, &out));
    out.clearRetainingCapacity();
    try std.testing.expectEqual(State.markup_script, line(gpa, html, "const x = 1", .markup_script, 0, colors, &out));
    try std.testing.expectEqual(colors.keyword, out.items[0].color.?);
    try std.testing.expectEqual(State.none, line(gpa, html, "</script>", .markup_script, 0, colors, &out));
    try std.testing.expectEqual(State.markup_comment, line(gpa, html, "<!-- a", .none, 0, colors, &out));
}

test "markdown: fences, headings, code" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(Span) = .empty;
    defer out.deinit(gpa);
    const colors = Colors.of(false);
    const md = hl.language("md").?;
    try std.testing.expectEqual(State.md_fence, line(gpa, md, "```zig", .none, 0, colors, &out));
    try std.testing.expectEqual(State.md_fence, line(gpa, md, "const x = 1;", .md_fence, 0, colors, &out));
    try std.testing.expectEqual(State.none, line(gpa, md, "```", .md_fence, 0, colors, &out));
    out.clearRetainingCapacity();
    _ = line(gpa, md, "Some `code` here", .none, 0, colors, &out);
    try std.testing.expectEqual(colors.string, out.items[0].color.?);
}
