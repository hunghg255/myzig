//! The rich text editor's formats, as its shortcuts and toolbar apply
//! them. On a range they change its runs or blocks as one step of undo; on
//! a caret, character formats change only the marks typing gets, which the
//! next move of the caret forgets, as ⌘B does in NSTextView.
const std = @import("std");
const model = @import("model.zig");
const RichText = @import("editor.zig").RichText;
const Mark = model.Mark;
const Marks = model.Marks;
const Kind = model.Kind;
const BlockStyle = model.BlockStyle;

pub const State = enum { off, on, mixed };

/// The selection's formats, for a toolbar.
pub const Formatting = struct {
    bold: State = .off,
    italic: State = .off,
    underline: State = .off,
    strike: State = .off,
    code: State = .off,
    /// The link the selection (or the caret) is in.
    link: ?[]const u8 = null,
    /// The style of the first block selected.
    style: BlockStyle = .{},

    pub fn of(f: Formatting, t: model.Toggle) State {
        return switch (t) {
            .bold => f.bold,
            .italic => f.italic,
            .underline => f.underline,
            .strike => f.strike,
            .code => f.code,
        };
    }
};

fn state(all: bool, any: bool) State {
    return if (all) .on else if (any) .mixed else .off;
}

pub fn formatting(rt: *const RichText) Formatting {
    const lo = rt.sel.lo();
    const hi = rt.sel.hi();
    var f: Formatting = .{ .style = rt.doc.block(lo.block).style };
    if (rt.sel.empty()) {
        const m = rt.typingMarks();
        f.bold = state(m.bold, false);
        f.italic = state(m.italic, false);
        f.underline = state(m.underline, false);
        f.strike = state(m.strike, false);
        f.code = state(m.code, false);
        const b = rt.doc.block(lo.block);
        const at = b.marksAt(if (lo.off > 0) lo.off - 1 else lo.off).link;
        if (b.len() > 0 and at != 0) f.link = rt.doc.url(at);
        return f;
    }
    var all: [5]bool = @splat(true);
    var any: [5]bool = @splat(false);
    var link: ?u32 = null;
    var i = lo.block;
    while (i <= hi.block) : (i += 1) {
        const b = rt.doc.block(i);
        const a = if (i == lo.block) lo.off else 0;
        const e = if (i == hi.block) hi.off else b.len();
        var pos: usize = 0;
        for (b.runs.items) |r| {
            defer pos += r.len;
            if (pos + r.len <= a or pos >= e) continue;
            const v = [_]bool{ r.marks.bold, r.marks.italic, r.marks.underline, r.marks.strike, r.marks.code };
            for (v, 0..) |on, k| {
                all[k] = all[k] and on;
                any[k] = any[k] or on;
            }
            if (link == null) link = r.marks.link else if (link.? != r.marks.link) link = 0;
        }
    }
    f.bold = state(all[0] and any[0], any[0]);
    f.italic = state(all[1] and any[1], any[1]);
    f.underline = state(all[2] and any[2], any[2]);
    f.strike = state(all[3] and any[3], any[3]);
    f.code = state(all[4] and any[4], any[4]);
    if (link) |l| if (l != 0) {
        f.link = rt.doc.url(l);
    };
    return f;
}

/// Sets `m` over the selection, as one step of undo; at a caret, in the
/// marks typing gets.
pub fn setMark(rt: *RichText, m: Mark) void {
    if (rt.sel.empty()) {
        var t = rt.typingMarks();
        m.apply(&t);
        rt.typing = t;
        rt.changed = true;
        return;
    }
    const lo = rt.sel.lo();
    const hi = rt.sel.hi();
    const keep = rt.sel;
    rt.begin(.other, lo.block, hi.block + 1);
    var i = lo.block;
    while (i <= hi.block) : (i += 1) {
        const b = rt.doc.block(i);
        b.format(rt.doc.gpa, if (i == lo.block) lo.off else 0, if (i == hi.block) hi.off else b.len(), m);
    }
    rt.sel = keep;
    rt.end(hi.block + 1);
}

/// Turns a format on over the selection, or off when all of it has it.
pub fn toggle(rt: *RichText, t: model.Toggle) void {
    const on = formatting(rt).of(t) != .on;
    setMark(rt, model.toggleMark(t, on));
}

/// Links the selection to `url`, or the link at the caret; at a caret
/// outside links, inserts `url` linked. An empty `url` takes links away.
pub fn setLink(rt: *RichText, url: []const u8) void {
    const id: u32 = if (url.len == 0) 0 else rt.doc.link(url);
    if (!rt.sel.empty()) return setMark(rt, .{ .link = id });
    const p = rt.sel.caret;
    const b = rt.doc.block(p.block);
    const here = if (b.len() == 0) 0 else b.marksAt(if (p.off > 0) p.off - 1 else 0).link;
    if (here != 0) {
        const ext = b.linkExtent(if (p.off > 0) p.off - 1 else 0, here);
        rt.begin(.other, p.block, p.block + 1);
        b.format(rt.doc.gpa, ext[0], ext[1], .{ .link = id });
        rt.end(p.block + 1);
        return;
    }
    if (id == 0) return;
    var m = b.typingMarks(p.off);
    m.link = id;
    rt.replaceSelection(url, m, .other);
}

/// Restyles block `i` as one step of undo.
pub fn restyleBlock(rt: *RichText, i: usize, st: BlockStyle) void {
    rt.begin(.other, i, i + 1);
    rt.doc.block(i).setStyle(st);
    rt.end(i + 1);
}

/// Gives the blocks selected `kind`, or makes them paragraphs when all
/// of them have it already. Items keep their levels; others lose them.
pub fn setKind(rt: *RichText, kind: Kind) void {
    const lo = rt.sel.lo().block;
    const hi = rt.sel.hi().block;
    var all = true;
    for (rt.doc.blocks.items[lo .. hi + 1]) |b| all = all and b.style.kind == kind;
    const to: Kind = if (all) .paragraph else kind;
    const keep = rt.sel;
    rt.begin(.other, lo, hi + 1);
    for (rt.doc.blocks.items[lo .. hi + 1]) |*b| {
        const was = b.style;
        b.setStyle(.{
            .kind = to,
            .indent = if (to.isList() and was.kind.isList()) was.indent else 0,
            .checked = to == .task and was.checked,
        });
    }
    rt.sel = keep;
    rt.end(hi + 1);
}

/// Moves the blocks selected `delta` levels in (out when negative).
pub fn indent(rt: *RichText, delta: i8) void {
    const lo = rt.sel.lo().block;
    const hi = rt.sel.hi().block;
    const keep = rt.sel;
    rt.begin(.other, lo, hi + 1);
    for (rt.doc.blocks.items[lo .. hi + 1]) |*b| {
        var st = b.style;
        const n: i16 = @as(i16, st.indent) + delta;
        st.indent = @intCast(std.math.clamp(n, 0, model.max_indent));
        b.setStyle(st);
    }
    rt.sel = keep;
    rt.end(hi + 1);
}

/// Checks (or unchecks) the task in block `i`.
pub fn toggleChecked(rt: *RichText, i: usize) void {
    if (i >= rt.doc.count()) return;
    var st = rt.doc.block(i).style;
    if (st.kind != .task) return;
    st.checked = !st.checked;
    const keep = rt.sel;
    restyleBlock(rt, i, st);
    rt.sel = keep;
}
