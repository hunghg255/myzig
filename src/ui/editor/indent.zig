//! What the code editor does as code is typed: Tab and Shift+Tab indent
//! and outdent the selected lines, Enter keeps the line's indentation (one
//! level more after an opening bracket, and between a pair), brackets and
//! quotes close as they are typed and wrap the selection, Backspace takes
//! an empty pair, lines are commented out, and the bracket at the caret is
//! matched with its partner.
const std = @import("std");
const TextArea = @import("../textarea.zig").TextArea;
const Sel = @import("../textdoc.zig").Sel;

pub const Indent = struct {
    /// What one level of indentation is: spaces, or "\t".
    unit: []const u8 = "    ",
    tab_size: usize = 4,
};

fn leading(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return i;
}

/// The lines a selection covers: a selection ending at a line's start
/// leaves that line out.
fn lineSpan(ta: *const TextArea) [2]usize {
    const a = ta.doc.lineOf(ta.sel.lo());
    var b = ta.doc.lineOf(ta.sel.hi());
    if (b > a and ta.sel.hi() == ta.doc.lineStart(b)) b -= 1;
    return .{ a, b };
}

/// A position as a line and a column, to put back after the lines' edits.
const LineCol = struct { line: usize, col: isize };

fn lineCol(ta: *const TextArea, at: usize) LineCol {
    const line = ta.doc.lineOf(at);
    return .{ .line = line, .col = @intCast(at - ta.doc.lineStart(line)) };
}

fn fromLineCol(ta: *const TextArea, p: LineCol) usize {
    const start = ta.doc.lineStart(p.line);
    const len = ta.doc.lineEnd(p.line) - start;
    return start + @as(usize, @intCast(std.math.clamp(p.col, 0, @as(isize, @intCast(len)))));
}

/// Indents (or with `back`, outdents) the lines of the selection by a
/// level, as one step of undo; the selection moves with its text.
pub fn indentLines(ta: *TextArea, ind: Indent, back: bool) void {
    const span = lineSpan(ta);
    var caret = lineCol(ta, ta.sel.caret);
    var anchor = lineCol(ta, ta.sel.anchor);
    ta.doc.begin(.other, ta.sel, ta.time);
    var line = span[0];
    while (line <= span[1]) : (line += 1) {
        const start = ta.doc.lineStart(line);
        const str = ta.doc.line(ta.doc.gpa, line);
        defer ta.doc.gpa.free(str);
        var delta: isize = 0;
        if (back) {
            var n: usize = 0;
            if (str.len > 0 and str[0] == '\t') n = 1 else while (n < ind.tab_size and n < str.len and str[n] == ' ') n += 1;
            if (n == 0) continue;
            ta.doc.edit(start, start + n, "");
            delta = -@as(isize, @intCast(n));
        } else {
            // Empty lines stay empty.
            if (str.len == 0 and span[0] != span[1]) continue;
            ta.doc.edit(start, start, ind.unit);
            delta = @intCast(ind.unit.len);
        }
        if (caret.line == line) caret.col += delta;
        if (anchor.line == line) anchor.col += delta;
    }
    ta.sel = .{ .caret = fromLineCol(ta, caret), .anchor = fromLineCol(ta, anchor) };
    ta.doc.end(ta.sel);
    ta.reveal = true;
    ta.changed = true;
}

/// Tab: indents the lines of a selection across lines, else types spaces
/// to the next tab stop (or a tab).
pub fn tab(ta: *TextArea, ind: Indent, back: bool) void {
    const span = lineSpan(ta);
    if (back or span[0] != span[1]) return indentLines(ta, ind, back);
    if (std.mem.eql(u8, ind.unit, "\t")) return ta.replaceSelection("\t", .other);
    const col = ta.sel.lo() - ta.doc.lineStart(span[0]);
    const n = ind.tab_size - col % ind.tab_size;
    const spaces = "                ";
    ta.replaceSelection(spaces[0..@min(n, spaces.len)], .other);
}

const pairs = [_][2]u8{ .{ '(', ')' }, .{ '[', ']' }, .{ '{', '}' }, .{ '"', '"' }, .{ '\'', '\'' }, .{ '`', '`' } };

fn closerOf(open: u8) ?u8 {
    for (pairs) |p| if (p[0] == open) return p[1];
    return null;
}

fn isCloser(b: u8) bool {
    return b == ')' or b == ']' or b == '}' or b == '"' or b == '\'' or b == '`';
}

fn wordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

/// Enter: a new line at the indentation of the caret's, a level deeper
/// after an opening bracket (or Python's colon), and between a pair the
/// closing bracket on a line of its own.
pub fn newline(ta: *TextArea, ind: Indent, gpa: std.mem.Allocator) void {
    const line = ta.doc.lineOf(ta.sel.lo());
    const start = ta.doc.lineStart(line);
    const str = ta.doc.line(gpa, line);
    defer gpa.free(str);
    const col = ta.sel.lo() - start;
    const indent = str[0..@min(leading(str), col)];
    const before = std.mem.trimEnd(u8, str[0..col], " \t");
    const after_at = ta.sel.hi() - start;
    const after: u8 = if (after_at < str.len) str[after_at] else 0;
    const last: u8 = if (before.len > 0) before[before.len - 1] else 0;
    const opens = last == '{' or last == '(' or last == '[' or last == ':';
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.append(gpa, '\n') catch return;
    out.appendSlice(gpa, indent) catch return;
    if (opens) out.appendSlice(gpa, ind.unit) catch return;
    const caret_off = out.items.len;
    if (opens and last != ':' and after == closerOf(last)) {
        out.append(gpa, '\n') catch return;
        out.appendSlice(gpa, indent) catch return;
    }
    const lo = ta.sel.lo();
    ta.replaceSelection(out.items, .other);
    ta.collapse(lo + caret_off);
}

/// A character typed: closes brackets and quotes, wraps the selection in
/// them, and types over the closing one already there. True if handled.
pub fn typed(ta: *TextArea, s: []const u8) bool {
    if (s.len != 1 or ta.marked != null) return false;
    const ch = s[0];
    const at = ta.sel.caret;
    const next: u8 = if (at < ta.len()) ta.doc.byteAt(at) else 0;
    const prev: u8 = if (at > 0) ta.doc.byteAt(at - 1) else 0;
    // Over the closing one typed already.
    if (isCloser(ch) and ta.sel.empty() and next == ch) {
        ta.collapse(at + 1);
        return true;
    }
    const close = closerOf(ch) orelse return false;
    const quote = ch == close;
    if (!ta.sel.empty()) {
        const lo = ta.sel.lo();
        const hi = ta.sel.hi();
        ta.doc.begin(.other, ta.sel, ta.time);
        ta.doc.edit(hi, hi, &.{close});
        ta.doc.edit(lo, lo, &.{ch});
        ta.sel = .{ .anchor = lo + 1, .caret = hi + 1 };
        ta.doc.end(ta.sel);
        ta.changed = true;
        ta.reveal = true;
        return true;
    }
    // Quotes pair only between words; brackets before space or a closer.
    if (quote and (wordByte(prev) or wordByte(next))) return false;
    if (!quote and next != 0 and next != ' ' and next != '\t' and !isCloser(next) and next != ';' and next != ',') return false;
    ta.replaceSelection(&.{ ch, close }, .typing);
    ta.collapse(at + 1);
    return true;
}

/// Backspace between an empty pair takes both; in the indentation, back
/// to the tab stop before. True if handled.
pub fn backspace(ta: *TextArea, ind: Indent) bool {
    if (!ta.sel.empty() or ta.marked != null) return false;
    const at = ta.sel.caret;
    if (at == 0) return false;
    const prev = ta.doc.byteAt(at - 1);
    if (at < ta.len()) if (closerOf(prev)) |close| if (ta.doc.byteAt(at) == close) {
        ta.replaceRange(at - 1, at + 1, "", .deleting);
        return true;
    };
    if (prev != ' ' or ind.unit[0] != ' ') return false;
    const start = ta.doc.lineStart(ta.doc.lineOf(at));
    const col = at - start;
    var n = (col - 1) % ind.tab_size + 1;
    var k: usize = 0;
    while (k < n) : (k += 1) if (ta.doc.byteAt(at - 1 - k) != ' ') break;
    n = k;
    if (n <= 1) return false;
    ta.replaceRange(at - n, at, "", .deleting);
    return true;
}

/// Comments the selected lines out with `prefix`, or back in when every
/// one of them is.
pub fn toggleComment(ta: *TextArea, prefix: []const u8) void {
    if (prefix.len == 0) return;
    const span = lineSpan(ta);
    const gpa = ta.doc.gpa;
    var all = true;
    var min_indent: usize = std.math.maxInt(usize);
    var line = span[0];
    while (line <= span[1]) : (line += 1) {
        const str = ta.doc.line(gpa, line);
        defer gpa.free(str);
        const lead = leading(str);
        if (lead == str.len) continue;
        min_indent = @min(min_indent, lead);
        if (!std.mem.startsWith(u8, str[lead..], prefix)) all = false;
    }
    if (min_indent == std.math.maxInt(usize)) return;
    var caret = lineCol(ta, ta.sel.caret);
    var anchor = lineCol(ta, ta.sel.anchor);
    ta.doc.begin(.other, ta.sel, ta.time);
    line = span[0];
    while (line <= span[1]) : (line += 1) {
        const start = ta.doc.lineStart(line);
        const str = ta.doc.line(gpa, line);
        defer gpa.free(str);
        const lead = leading(str);
        if (lead == str.len) continue;
        var delta: isize = 0;
        if (all) {
            var n = prefix.len;
            if (lead + n < str.len and str[lead + n] == ' ') n += 1;
            ta.doc.edit(start + lead, start + lead + n, "");
            delta = -@as(isize, @intCast(n));
        } else {
            ta.doc.edit(start + min_indent, start + min_indent, prefix);
            ta.doc.edit(start + min_indent + prefix.len, start + min_indent + prefix.len, " ");
            delta = @intCast(prefix.len + 1);
        }
        if (caret.line == line) caret.col += delta;
        if (anchor.line == line) anchor.col += delta;
    }
    ta.sel = .{ .caret = fromLineCol(ta, caret), .anchor = fromLineCol(ta, anchor) };
    ta.doc.end(ta.sel);
    ta.changed = true;
}

/// How far a bracket's partner is looked for, in bytes as well as lines:
/// a few long lines are a whole file, scanned on every caret move (Zed
/// bounds its queries by bytes too).
pub const bracket_scan_bytes = 64 << 10;

/// The bracket next to the caret and its partner, searched for as far
/// as `limit` lines and `bracket_scan_bytes`.
pub fn matchBracket(ta: *const TextArea, gpa: std.mem.Allocator, limit: usize) ?[2]usize {
    const at = ta.sel.caret;
    const brackets = "()[]{}";
    var pos: ?usize = null;
    if (at < ta.len() and std.mem.indexOfScalar(u8, brackets, ta.doc.byteAt(at)) != null) pos = at else if (at > 0 and std.mem.indexOfScalar(u8, brackets, ta.doc.byteAt(at - 1)) != null) pos = at - 1;
    const p = pos orelse return null;
    const b = ta.doc.byteAt(p);
    const idx = std.mem.indexOfScalar(u8, brackets, b).?;
    const forward = idx % 2 == 0;
    const partner = brackets[if (forward) idx + 1 else idx - 1];
    var depth: usize = 0;
    var line = ta.doc.lineOf(p);
    const first_line = line;
    while (true) {
        const start = ta.doc.lineStart(line);
        const str = ta.doc.line(gpa, line);
        defer gpa.free(str);
        if (forward) {
            var i: usize = if (line == first_line) p - start else 0;
            while (i < str.len) : (i += 1) {
                if (str[i] == b) depth += 1 else if (str[i] == partner) {
                    depth -= 1;
                    if (depth == 0) return .{ p, start + i };
                }
            }
            line += 1;
            if (line >= ta.doc.lineCount() or line - first_line > limit) return null;
            if (ta.doc.lineStart(line) - p > bracket_scan_bytes) return null;
        } else {
            var i: usize = if (line == first_line) p - start + 1 else str.len;
            while (i > 0) {
                i -= 1;
                if (str[i] == b) depth += 1 else if (str[i] == partner) {
                    depth -= 1;
                    if (depth == 0) return .{ p, start + i };
                }
            }
            if (line == 0 or first_line - line >= limit) return null;
            if (p - start > bracket_scan_bytes) return null;
            line -= 1;
        }
    }
}
