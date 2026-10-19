//! The rich text editor's state, kept by the app: the document, the
//! selection, the marks typing gets, an input method's composition, the
//! history of undo, the clipboard's rich copy, and what the view keeps
//! between frames. Its methods edit the document as the editor's keys do.
//!
//!     var note = ui.RichText.initMarkdown(gpa, "# Groceries\n\n- [ ] Milk");
//!     defer note.deinit();
//!     // In the view:
//!     if (ui.richTextEditor(c, &note, .{}).changed) save(&note);
const std = @import("std");
const model = @import("model.zig");
const history_mod = @import("history.zig");
const commands = @import("commands.zig");
const clip_mod = @import("clipboard.zig");
const md_in = @import("markdown_in.zig");
const md_out = @import("markdown_out.zig");
const words = @import("../textarea.zig");
const utf8 = @import("../utf8.zig");
const Doc = model.Doc;
const Pos = model.Pos;
const Sel = model.Sel;
const Marks = model.Marks;
const Kind = history_mod.Kind;

/// What a press selects as it drags: characters, words or blocks.
pub const Unit = enum { char, word, block };

/// An input method's composition: bytes [a, b) of block `block`.
pub const Marked = struct { block: usize, a: usize, b: usize };

pub const RichText = struct {
    doc: Doc,
    sel: Sel = .{},
    history: history_mod.History = .{},
    marked: ?Marked = null,
    /// The marks the next text typed gets, when a format was toggled at
    /// the caret or text before it deleted; forgotten when the caret moves.
    typing: ?Marks = null,
    /// The x vertical moves keep to, in the content.
    goal_x: ?f32 = null,
    /// Keeps the caret in view in the next frame.
    reveal: bool = false,
    dragging: bool = false,
    drag_unit: Unit = .char,
    drag_from: [2]Pos = .{ .{}, .{} },
    /// What copy put on the clipboard, to paste whole.
    clip: clip_mod.Clip = .{},
    /// Typing `# `, `- `, `**bold**`… formats (the view sets it).
    markdown_shortcuts: bool = true,
    /// The ids of its box and of its scrolling box, from the last build.
    id: u64 = 0,
    scroll_id: u64 = 0,
    /// The blocks built in the last frame, first and last.
    shown: [2]usize = .{ 0, 0 },
    /// The frame's clock, for joining typing into steps of undo.
    time: f64 = 0,
    /// Edits since the app last looked (`takeChanged`).
    changed: bool = false,
    /// Bumped by every edit, undo and redo.
    version: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) RichText {
        return .{ .doc = .init(gpa) };
    }

    pub fn initMarkdown(gpa: std.mem.Allocator, md: []const u8) RichText {
        return .{ .doc = md_in.parse(gpa, md) };
    }

    pub fn deinit(rt: *RichText) void {
        rt.clip.deinit(rt.doc.gpa);
        rt.history.deinit(rt.doc.gpa);
        rt.doc.deinit();
    }

    /// Replaces the document with Markdown's, as opening another note:
    /// without history, the caret at the start.
    pub fn setMarkdown(rt: *RichText, md: []const u8) void {
        const gpa = rt.doc.gpa;
        rt.doc.deinit();
        rt.doc = md_in.parse(gpa, md);
        rt.history.clear(gpa);
        rt.sel = .{};
        rt.marked = null;
        rt.typing = null;
        rt.reveal = true;
        rt.version += 1;
    }

    /// The document as Markdown (CommonMark with GitHub's task lists and
    /// strikethrough; underlines as `<u>`), in memory of `gpa`.
    pub fn markdown(rt: *const RichText, gpa: std.mem.Allocator) []u8 {
        return md_out.write(gpa, &rt.doc);
    }

    /// The characters, blocks apart by newlines.
    pub fn text(rt: *const RichText, gpa: std.mem.Allocator) []u8 {
        return rt.doc.text(gpa);
    }

    pub fn selectedText(rt: *const RichText, gpa: std.mem.Allocator) []u8 {
        return rt.doc.plain(gpa, rt.sel.lo(), rt.sel.hi());
    }

    pub fn takeChanged(rt: *RichText) bool {
        defer rt.changed = false;
        return rt.changed;
    }

    /// Selects from `anchor` to `caret`; the typing marks are forgotten.
    pub fn select(rt: *RichText, anchor: Pos, caret: Pos) void {
        rt.sel = .{ .anchor = rt.doc.clamp(anchor), .caret = rt.doc.clamp(caret) };
        rt.goal_x = null;
        rt.typing = null;
        rt.marked = null;
        rt.reveal = true;
        rt.history.breakGroup();
    }

    pub fn collapse(rt: *RichText, p: Pos) void {
        rt.select(p, p);
    }

    pub fn selectAll(rt: *RichText) void {
        rt.select(.{}, rt.doc.end());
        rt.reveal = false;
    }

    pub fn canUndo(rt: *const RichText) bool {
        return rt.history.canUndo();
    }

    pub fn canRedo(rt: *const RichText) bool {
        return rt.history.canRedo();
    }

    pub fn undo(rt: *RichText) void {
        if (rt.history.undo(&rt.doc)) |s| rt.restore(s);
    }

    pub fn redo(rt: *RichText) void {
        if (rt.history.redo(&rt.doc)) |s| rt.restore(s);
    }

    fn restore(rt: *RichText, s: Sel) void {
        rt.sel = .{ .anchor = rt.doc.clamp(s.anchor), .caret = rt.doc.clamp(s.caret) };
        rt.marked = null;
        rt.typing = null;
        rt.goal_x = null;
        rt.reveal = true;
        rt.changed = true;
        rt.version += 1;
    }

    // Steps of undo: an edit says which blocks it replaces, and which they
    // are after it.

    /// Begins an edit of blocks [a, b).
    pub fn begin(rt: *RichText, kind: Kind, a: usize, b: usize) void {
        rt.history.begin(&rt.doc, kind, a, b, rt.sel, rt.time, rt.marked != null);
    }

    /// Ends it: the blocks begun as [a, b) are [a, new_end).
    pub fn end(rt: *RichText, new_end: usize) void {
        rt.history.end(new_end, rt.sel);
        rt.goal_x = null;
        rt.reveal = true;
        rt.changed = true;
        rt.version += 1;
    }

    /// The marks text typed at the caret gets.
    pub fn typingMarks(rt: *const RichText) Marks {
        if (rt.typing) |m| return m;
        const lo = rt.sel.lo();
        const b = rt.doc.block(lo.block);
        // In place of a selection: those of its first character.
        if (!rt.sel.empty() and lo.off < b.len()) return b.marksAt(lo.off);
        return b.typingMarks(lo.off);
    }

    /// Types `s` at the caret, as a keyboard does (characters in a row are
    /// one step of undo); newlines make blocks.
    pub fn insert(rt: *RichText, s: []const u8) void {
        if (std.mem.indexOfScalar(u8, s, '\n') != null) return clip_mod.pastePlain(rt, s);
        const typing = rt.sel.empty() and rt.marked == null and s.len <= 4;
        rt.replaceSelection(s, rt.typingMarks(), if (typing or rt.marked != null) .typing else .other);
        if (typing and rt.markdown_shortcuts) @import("shortcuts.zig").typed(rt);
    }

    /// Replaces the selection (or the composition) with `s` (no newlines)
    /// in `marks`; the caret goes after it.
    pub fn replaceSelection(rt: *RichText, s: []const u8, marks: Marks, kind: Kind) void {
        var lo = rt.sel.lo();
        var hi = rt.sel.hi();
        if (rt.marked) |m| {
            lo = .{ .block = m.block, .off = m.a };
            hi = .{ .block = m.block, .off = m.b };
        }
        rt.begin(kind, lo.block, hi.block + 1);
        if (hi.order(lo) == .gt) rt.doc.delete(lo, hi);
        rt.doc.block(lo.block).insert(rt.doc.gpa, lo.off, s, marks);
        rt.sel = .at(.{ .block = lo.block, .off = lo.off + s.len });
        rt.marked = null;
        rt.end(lo.block + 1);
    }

    /// Deletes the selection; false when it is empty.
    pub fn deleteSelection(rt: *RichText) bool {
        if (rt.sel.empty()) return false;
        const lo = rt.sel.lo();
        const hi = rt.sel.hi();
        rt.typing = rt.typingMarks();
        rt.begin(.other, lo.block, hi.block + 1);
        rt.doc.delete(lo, hi);
        rt.sel = .at(lo);
        rt.end(lo.block + 1);
        return true;
    }

    /// Deletes from the caret to `to` (or the selection).
    pub fn deleteTo(rt: *RichText, to_in: Pos) void {
        if (rt.deleteSelection()) return;
        const to = rt.doc.clamp(to_in);
        const lo = rt.sel.caret.min(to);
        const hi = rt.sel.caret.max(to);
        if (lo.eql(hi)) return;
        // Typing gets what was deleted before the caret, until it moves.
        const b = rt.doc.block(lo.block);
        if (lo.block == hi.block and to.order(rt.sel.caret) == .lt) rt.typing = b.marksAt(lo.off);
        rt.begin(.deleting, lo.block, hi.block + 1);
        rt.doc.delete(lo, hi);
        rt.sel = .at(lo);
        rt.end(lo.block + 1);
    }

    /// Backspace: at a block's start it takes its style away (a list's
    /// level first), then joins it to the block before.
    pub fn deleteBackward(rt: *RichText) void {
        if (rt.deleteSelection()) return;
        const p = rt.sel.caret;
        if (p.off > 0) return rt.deleteTo(rt.prevPos(p));
        const st = rt.doc.block(p.block).style;
        if (st.kind != .paragraph or st.indent > 0) {
            var n = st;
            if (st.kind.isList() and st.indent > 0) {
                n.indent -= 1;
            } else if (st.kind != .paragraph) {
                n = .{ .indent = if (st.kind.isList()) st.indent else 0 };
            } else n.indent -= 1;
            return commands.restyleBlock(rt, p.block, n);
        }
        if (p.block > 0) rt.deleteTo(rt.prevPos(p));
    }

    pub fn deleteForward(rt: *RichText) void {
        if (rt.deleteSelection()) return;
        rt.deleteTo(rt.nextPos(rt.sel.caret));
    }

    /// Enter: splits the block at the caret. On an empty item of a list
    /// (or line of a quotation) it leaves the list, a level at a time; at
    /// a heading's end the next block is a paragraph; an empty last line
    /// of code ends the code.
    pub fn newline(rt: *RichText) void {
        rt.marked = null;
        if (rt.markdown_shortcuts and @import("shortcuts.zig").fence(rt)) return;
        const lo = rt.sel.lo();
        const hi = rt.sel.hi();
        rt.begin(.other, lo.block, hi.block + 1);
        if (!rt.sel.empty()) rt.doc.delete(lo, hi);
        const p = lo;
        const d = &rt.doc;
        const b = d.block(p.block);
        const st = b.style;
        const last_code = st.kind == .code and p.block > 0 and d.block(p.block - 1).style.kind == .code and
            (p.block + 1 == d.count() or d.block(p.block + 1).style.kind != .code);
        if (b.len() == 0 and (st.kind.isList() or st.kind == .quote or last_code)) {
            b.setStyle(if (st.kind.isList() and st.indent > 0) .{ .kind = st.kind, .indent = st.indent - 1 } else .{});
            rt.sel = .at(p);
            return rt.end(p.block + 1);
        }
        const marks = rt.typingMarks();
        d.split(p);
        const head = d.block(p.block);
        const tail = d.block(p.block + 1);
        if (st.kind.isHeading() and tail.len() == 0) tail.setStyle(.{});
        if (st.kind.isHeading() and head.len() == 0 and tail.len() > 0) head.setStyle(.{});
        if (st.kind == .task) tail.style.checked = false;
        rt.sel = .at(.{ .block = p.block + 1 });
        rt.end(p.block + 2);
        // Typing keeps the marks typed before Enter.
        rt.typing = if (tail.len() == 0) marks else null;
    }

    /// An input method's composition replaces the last one (or the
    /// selection), with the selection inside it.
    pub fn setMarked(rt: *RichText, s: []const u8, sel_start: usize, sel_len: usize) void {
        const marks = rt.typingMarks();
        const at = if (rt.marked) |m| Pos{ .block = m.block, .off = m.a } else rt.sel.lo();
        rt.replaceSelection(s, marks, .typing);
        const n = s.len;
        rt.marked = if (n == 0) null else .{ .block = at.block, .a = at.off, .b = at.off + n };
        rt.sel = .{
            .anchor = .{ .block = at.block, .off = at.off + @min(sel_start, n) },
            .caret = .{ .block = at.block, .off = at.off + @min(sel_start + sel_len, n) },
        };
        rt.history.end(at.block + 1, rt.sel);
    }

    // Positions.

    pub fn prevPos(rt: *const RichText, p: Pos) Pos {
        if (p.off == 0) {
            if (p.block == 0) return p;
            return .{ .block = p.block - 1, .off = rt.doc.block(p.block - 1).len() };
        }
        const s = rt.doc.block(p.block).str();
        var j = p.off - 1;
        while (j > 0 and (s[j] & 0xc0) == 0x80) j -= 1;
        return .{ .block = p.block, .off = j };
    }

    pub fn nextPos(rt: *const RichText, p: Pos) Pos {
        const s = rt.doc.block(p.block).str();
        if (p.off >= s.len) {
            if (p.block + 1 >= rt.doc.count()) return p;
            return .{ .block = p.block + 1 };
        }
        return .{ .block = p.block, .off = @min(s.len, p.off + utf8.seqLen(s[p.off])) };
    }

    pub fn prevWord(rt: *const RichText, p: Pos) Pos {
        if (p.off == 0) return rt.prevPos(p);
        return .{ .block = p.block, .off = words.prevWordIn(rt.doc.block(p.block).str(), p.off) };
    }

    pub fn nextWord(rt: *const RichText, p: Pos) Pos {
        const s = rt.doc.block(p.block).str();
        if (p.off >= s.len) return rt.nextPos(p);
        return .{ .block = p.block, .off = words.nextWordIn(s, p.off) };
    }

    /// The word (or spaces, or one other character) at `p`.
    pub fn wordAt(rt: *const RichText, p: Pos) [2]Pos {
        const r = words.wordRangeIn(rt.doc.block(p.block).str(), p.off);
        return .{ .{ .block = p.block, .off = r[0] }, .{ .block = p.block, .off = r[1] } };
    }

    // Formats: see `commands.zig`.

    pub fn toggle(rt: *RichText, t: model.Toggle) void {
        commands.toggle(rt, t);
    }

    pub fn setMark(rt: *RichText, m: model.Mark) void {
        commands.setMark(rt, m);
    }

    pub fn setLink(rt: *RichText, url: []const u8) void {
        commands.setLink(rt, url);
    }

    pub fn setKind(rt: *RichText, kind: model.Kind) void {
        commands.setKind(rt, kind);
    }

    pub fn indent(rt: *RichText, delta: i8) void {
        commands.indent(rt, delta);
    }

    pub fn toggleChecked(rt: *RichText, block: usize) void {
        commands.toggleChecked(rt, block);
    }

    pub fn formatting(rt: *const RichText) commands.Formatting {
        return commands.formatting(rt);
    }

    /// Pastes Markdown at the caret, with its formats.
    pub fn pasteMarkdown(rt: *RichText, md: []const u8) void {
        clip_mod.pasteMarkdown(rt, md);
    }
};
