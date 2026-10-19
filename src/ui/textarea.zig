//! A multi-line text's editing state, kept by the app: the document, the
//! selection, the composition of an input method, and what the view keeps
//! between frames (the rows of wrapped lines, the horizontal scroll, the
//! column vertical moves aim for). `ui.textArea` and `ui.codeEditor` edit
//! one.
//!
//!     var notes = ui.TextArea.init(gpa, "Hello");
//!     defer notes.deinit();
//!     // In the view:
//!     _ = ui.textArea(c, &notes, .{ .placeholder = "Notes", .lines = .{ 3, 12 } });
const std = @import("std");
const utf8 = @import("utf8.zig");
const doc_mod = @import("textdoc.zig");
const TextDoc = doc_mod.TextDoc;
const Sel = doc_mod.Sel;
const Kind = doc_mod.Kind;
const WrapCache = @import("textlayout.zig").WrapCache;

/// What a press selects as it drags: characters, words or lines.
pub const Unit = enum { char, word, line };

pub const TextArea = struct {
    doc: TextDoc,
    sel: Sel = .{},
    /// What an input method composes, underlined, in the text already.
    marked: ?[2]usize = null,
    /// The x vertical moves keep to, in the row.
    goal_x: ?f32 = null,
    /// How far long lines are scrolled left (when they don't wrap).
    scroll_x: f32 = 0,
    /// The widest line shown so far, for the horizontal scroll bar.
    content_w: f32 = 0,
    wrap: WrapCache = .{},
    /// Its long lines, laid out a frame's budget at a time
    /// (`textlayout_long.zig`).
    long: @import("textlayout_long.zig").LongLines = .{},
    /// Keeps the caret in view in the next frame.
    reveal: bool = false,
    /// A press selecting by `drag_unit` from `drag_from`.
    dragging: bool = false,
    drag_unit: Unit = .char,
    drag_from: [2]usize = .{ 0, 0 },
    /// Where the horizontal scroll bar was grabbed.
    thumb_grab: ?f32 = null,
    /// The ids of its box and of its scrolling box, from the last build.
    id: u64 = 0,
    scroll_id: u64 = 0,
    /// The frame's clock, for joining typing into steps of undo.
    time: f64 = 0,
    /// Edits since the app last looked (`takeChanged`).
    changed: bool = false,

    pub fn init(gpa: std.mem.Allocator, s: []const u8) TextArea {
        return .{ .doc = .init(gpa, s) };
    }

    pub fn deinit(ta: *TextArea) void {
        ta.wrap.deinit(ta.doc.gpa);
        ta.long.deinit();
        ta.doc.deinit();
    }

    /// The whole text, in memory of `gpa`.
    pub fn text(ta: *const TextArea, gpa: std.mem.Allocator) []u8 {
        return ta.doc.text(gpa);
    }

    pub fn len(ta: *const TextArea) usize {
        return ta.doc.len();
    }

    /// Replaces the text as an edit, which undo takes back; the caret goes
    /// to its end.
    pub fn setText(ta: *TextArea, s: []const u8) void {
        ta.doc.begin(.other, ta.sel, ta.time);
        ta.doc.edit(0, ta.doc.len(), s);
        ta.collapse(ta.doc.len());
        ta.doc.end(ta.sel);
        ta.marked = null;
        ta.changed = true;
    }

    /// Replaces the text as a new document, without history.
    pub fn reset(ta: *TextArea, s: []const u8) void {
        ta.doc.reset(s);
        ta.sel = .{};
        ta.marked = null;
        ta.scroll_x = 0;
        ta.content_w = 0;
        ta.reveal = true;
    }

    /// Selects from `anchor` to `caret` (bytes).
    pub fn select(ta: *TextArea, anchor: usize, caret: usize) void {
        ta.sel = .{ .anchor = @min(anchor, ta.len()), .caret = @min(caret, ta.len()) };
        ta.goal_x = null;
        ta.reveal = true;
        ta.doc.breakGroup();
    }

    pub fn collapse(ta: *TextArea, at: usize) void {
        ta.select(at, at);
    }

    pub fn selectedText(ta: *const TextArea, gpa: std.mem.Allocator) []u8 {
        return ta.doc.slice(gpa, ta.sel.lo(), ta.sel.hi());
    }

    /// The line the caret is on, from 0.
    pub fn caretLine(ta: *const TextArea) usize {
        return ta.doc.lineOf(ta.sel.caret);
    }

    /// Replaces the selection (or the composition) with `s`, as a step of
    /// `kind`; the caret goes after it.
    pub fn replaceSelection(ta: *TextArea, s: []const u8, kind: Kind) void {
        const range = ta.marked orelse .{ ta.sel.lo(), ta.sel.hi() };
        ta.replaceRange(range[0], range[1], s, kind);
    }

    /// Replaces [a, b) with `s`; the caret goes after it.
    pub fn replaceRange(ta: *TextArea, a: usize, b: usize, s: []const u8, kind: Kind) void {
        ta.doc.begin(kind, ta.sel, ta.time);
        ta.doc.edit(a, b, s);
        ta.sel = .at(a + s.len);
        ta.doc.end(ta.sel);
        ta.marked = null;
        ta.goal_x = null;
        ta.reveal = true;
        ta.changed = true;
    }

    /// Types `s` at the caret, as a keyboard does: characters in a row are
    /// one step of undo.
    pub fn insert(ta: *TextArea, s: []const u8) void {
        const typing = ta.sel.empty() and ta.marked == null and s.len <= 4 and std.mem.indexOfScalar(u8, s, '\n') == null;
        ta.replaceSelection(s, if (typing or ta.marked != null) .typing else .other);
    }

    /// Deletes the selection, or from the caret to `to`.
    pub fn deleteTo(ta: *TextArea, to: usize) void {
        if (!ta.sel.empty()) return ta.replaceSelection("", .other);
        const a = @min(ta.sel.caret, to);
        const b = @max(ta.sel.caret, to);
        if (a == b) return;
        ta.replaceRange(a, b, "", .deleting);
    }

    pub fn undo(ta: *TextArea) void {
        if (ta.doc.undo()) |s| ta.restore(s);
    }

    pub fn redo(ta: *TextArea) void {
        if (ta.doc.redo()) |s| ta.restore(s);
    }

    fn restore(ta: *TextArea, s: Sel) void {
        ta.sel = .{ .caret = @min(s.caret, ta.len()), .anchor = @min(s.anchor, ta.len()) };
        ta.marked = null;
        ta.goal_x = null;
        ta.reveal = true;
        ta.changed = true;
    }

    /// Whether the text changed since the last call.
    pub fn takeChanged(ta: *TextArea) bool {
        defer ta.changed = false;
        return ta.changed;
    }

    // Logical positions, by the bytes of the text.

    /// The character boundary before `i`.
    pub fn prevChar(ta: *const TextArea, i: usize) usize {
        if (i == 0) return 0;
        var j = i - 1;
        while (j > 0 and (ta.doc.byteAt(j) & 0xc0) == 0x80) j -= 1;
        return j;
    }

    pub fn nextChar(ta: *const TextArea, i: usize) usize {
        if (i >= ta.len()) return ta.len();
        return @min(ta.len(), i + utf8.seqLen(ta.doc.byteAt(i)));
    }

    /// The line of `at` and where it starts, read into `gpa`'s memory.
    fn lineAround(ta: *const TextArea, gpa: std.mem.Allocator, at: usize) struct { start: usize, str: []u8 } {
        const line = ta.doc.lineOf(at);
        return .{ .start = ta.doc.lineStart(line), .str = ta.doc.line(gpa, line) };
    }

    /// The start of the word before `i`; a line's start goes to the end of
    /// the line before.
    pub fn prevWord(ta: *const TextArea, i: usize) usize {
        const gpa = ta.doc.gpa;
        const l = ta.lineAround(gpa, i);
        defer gpa.free(l.str);
        const in = i - l.start;
        if (in == 0) return ta.prevChar(i);
        return l.start + prevWordIn(l.str, in);
    }

    pub fn nextWord(ta: *const TextArea, i: usize) usize {
        const gpa = ta.doc.gpa;
        const l = ta.lineAround(gpa, i);
        defer gpa.free(l.str);
        const in = i - l.start;
        if (in >= l.str.len) return ta.nextChar(i);
        return l.start + nextWordIn(l.str, in);
    }

    /// The word (or run of spaces, or one other character) at `i`.
    pub fn wordAt(ta: *const TextArea, i: usize) [2]usize {
        const gpa = ta.doc.gpa;
        const l = ta.lineAround(gpa, i);
        defer gpa.free(l.str);
        const r = wordRangeIn(l.str, i - l.start);
        return .{ l.start + r[0], l.start + r[1] };
    }

    /// Line `line` with its newline.
    pub fn lineRange(ta: *const TextArea, line: usize) [2]usize {
        const end = if (line + 1 < ta.doc.lineCount()) ta.doc.lineStart(line + 1) else ta.len();
        return .{ ta.doc.lineStart(line), end };
    }
};

pub fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

pub fn prevWordIn(s: []const u8, i: usize) usize {
    var j = i;
    while (j > 0 and !isWordByte(s[j - 1])) j -= 1;
    while (j > 0 and isWordByte(s[j - 1])) j -= 1;
    return j;
}

pub fn nextWordIn(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and !isWordByte(s[j])) j += 1;
    while (j < s.len and isWordByte(s[j])) j += 1;
    return j;
}

/// The run around byte `i` of `s`: a word, spaces, or one other character.
pub fn wordRangeIn(s: []const u8, i_in: usize) [2]usize {
    if (s.len == 0) return .{ 0, 0 };
    // At a word's end, the word before.
    var i = @min(i_in, s.len - 1);
    if (i_in == s.len or (!isWordByte(s[i]) and i > 0 and isWordByte(s[i - 1]))) i = if (i_in > 0) i_in - 1 else 0;
    i = @min(i, s.len - 1);
    const Class = enum { word, space, other };
    const classOf = struct {
        fn f(b: u8) Class {
            if (isWordByte(b)) return .word;
            if (b == ' ' or b == '\t') return .space;
            return .other;
        }
    }.f;
    const k = classOf(s[i]);
    if (k == .other) return .{ i, @min(s.len, i + utf8.seqLen(s[i])) };
    var a = i;
    var b = i;
    while (a > 0 and classOf(s[a - 1]) == k) a -= 1;
    while (b < s.len and classOf(s[b]) == k) b += 1;
    return .{ a, b };
}

test "words" {
    try std.testing.expectEqual(@as(usize, 4), prevWordIn("foo bar", 7));
    try std.testing.expectEqual(@as(usize, 3), nextWordIn("foo bar", 0));
    try std.testing.expectEqual([2]usize{ 4, 7 }, wordRangeIn("foo bar", 5));
    try std.testing.expectEqual([2]usize{ 4, 7 }, wordRangeIn("foo bar", 7));
    try std.testing.expectEqual([2]usize{ 0, 3 }, wordRangeIn("foo(bar", 3));
    try std.testing.expectEqual([2]usize{ 4, 5 }, wordRangeIn("foo((bar", 4));
}
