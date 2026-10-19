//! Copy and paste in the rich text editor. Copying puts plain text (or
//! Markdown) on the clipboard and keeps the selection itself, its blocks'
//! styles and its marks: pasting that text again pastes the copy whole, so
//! that text moves with its formats within the app. Text from elsewhere
//! pastes plain, or read as Markdown.
const std = @import("std");
const model = @import("model.zig");
const md_in = @import("markdown_in.zig");
const md_out = @import("markdown_out.zig");
const RichText = @import("editor.zig").RichText;
const Doc = model.Doc;
const Block = model.Block;
const Pos = model.Pos;

/// What copy wrote to the clipboard, and what it copied.
pub const Clip = struct {
    /// The blocks copied, with their own links.
    doc: ?Doc = null,
    /// The copy began at a block's start: pasted at a block's start, its
    /// first block brings its style.
    whole: bool = false,
    written: std.ArrayList(u8) = .empty,

    pub fn deinit(cl: *Clip, gpa: std.mem.Allocator) void {
        if (cl.doc) |*d| d.deinit();
        cl.written.deinit(gpa);
        cl.* = .{};
    }

    /// Whether `s`, pasted, is what this copy wrote.
    pub fn matches(cl: *const Clip, s: []const u8) bool {
        return cl.doc != null and cl.written.items.len > 0 and std.mem.eql(u8, s, cl.written.items);
    }
};

/// What copy writes, and what text from elsewhere pastes as.
pub const Format = enum { plain, markdown };

/// Blocks [lo, hi) of `d` as a document of their own.
pub fn copyRange(gpa: std.mem.Allocator, d: *const Doc, lo: Pos, hi: Pos) Doc {
    var out = Doc.init(gpa);
    out.blocks.clearRetainingCapacity();
    var i = lo.block;
    while (i <= hi.block) : (i += 1) {
        const src = d.block(i);
        var b: Block = .{ .style = src.style };
        b.appendFrom(gpa, src, if (i == lo.block) lo.off else 0, if (i == hi.block) hi.off else src.len());
        for (b.runs.items) |*r| if (r.marks.link != 0) {
            r.marks.link = out.link(d.url(r.marks.link));
        };
        out.blocks.append(gpa, b) catch @panic("OOM");
    }
    return out;
}

/// Block `i` of `src`, its links in `dst`'s.
fn cloneInto(dst: *Doc, src: *const Doc, i: usize) Block {
    var b = src.block(i).clone(dst.gpa);
    b.h_w = -1;
    for (b.runs.items) |*r| if (r.marks.link != 0) {
        r.marks.link = dst.link(src.url(r.marks.link));
    };
    return b;
}

/// Copies the selection to the clipboard of `write` (plain text or
/// Markdown), keeping it whole in `rt.clip`; returns what was written.
pub fn copy(rt: *RichText, format: Format) []const u8 {
    const gpa = rt.doc.gpa;
    rt.clip.deinit(gpa);
    var d = copyRange(gpa, &rt.doc, rt.sel.lo(), rt.sel.hi());
    const s = switch (format) {
        .plain => d.text(gpa),
        .markdown => md_out.write(gpa, &d),
    };
    defer gpa.free(s);
    rt.clip.written.appendSlice(gpa, s) catch @panic("OOM");
    rt.clip.whole = rt.sel.lo().off == 0;
    rt.clip.doc = d;
    return rt.clip.written.items;
}

/// Pastes the blocks of `src` in place of the selection, as one step of
/// undo. Its first block joins the block at the caret, and its last the
/// rest of it; those between come whole.
pub fn paste(rt: *RichText, src: *const Doc, whole: bool) void {
    rt.marked = null;
    const lo = rt.sel.lo();
    const hi = rt.sel.hi();
    rt.begin(.other, lo.block, hi.block + 1);
    if (!rt.sel.empty()) rt.doc.delete(lo, hi);
    const d = &rt.doc;
    const gpa = d.gpa;
    const n = src.count();
    const p = lo;
    if (n == 1) {
        var first = cloneInto(d, src, 0);
        defer first.deinit(gpa);
        const b = d.block(p.block);
        var at = p.off;
        var pos: usize = 0;
        for (first.runs.items) |r| {
            b.insert(gpa, at, first.text.items[pos .. pos + r.len], r.marks);
            at += r.len;
            pos += r.len;
        }
        // Text pasted at a block's start brings its own style.
        if (whole and p.off == 0) b.setStyle(first.style);
        rt.sel = .at(.{ .block = p.block, .off = at });
        return rt.end(p.block + 1);
    }
    d.split(p);
    {
        var first = cloneInto(d, src, 0);
        defer first.deinit(gpa);
        const head = d.block(p.block);
        if (p.off == 0 and (whole or head.len() == 0)) head.setStyle(first.style);
        head.appendFrom(gpa, &first, 0, first.len());
    }
    var k: usize = 1;
    while (k + 1 < n) : (k += 1) d.blocks.insert(gpa, p.block + k, cloneInto(d, src, k)) catch @panic("OOM");
    // The last block of the paste, then what followed the caret.
    var last = cloneInto(d, src, n - 1);
    const tail_i = p.block + n - 1;
    const tail = d.block(tail_i);
    const end_off = last.len();
    last.appendFrom(gpa, tail, 0, tail.len());
    tail.deinit(gpa);
    d.blocks.items[tail_i] = last;
    rt.sel = .at(.{ .block = tail_i, .off = end_off });
    rt.end(p.block + n);
}

/// Pastes plain text: its lines are blocks of the caret's style.
pub fn pastePlain(rt: *RichText, s: []const u8) void {
    const gpa = rt.doc.gpa;
    const marks = rt.typingMarks();
    var st = rt.doc.block(rt.sel.lo().block).style;
    st.checked = false;
    var d = Doc.init(gpa);
    defer d.deinit();
    d.blocks.clearRetainingCapacity();
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| d.append(st, std.mem.trimEnd(u8, line, "\r"), marks);
    paste(rt, &d, false);
}

/// Pastes Markdown with its formats.
pub fn pasteMarkdown(rt: *RichText, md: []const u8) void {
    var d = md_in.parse(rt.doc.gpa, md);
    defer d.deinit();
    // A paragraph alone takes the style of where it goes.
    paste(rt, &d, d.count() > 1 or d.block(0).style.kind != .paragraph);
}

/// Pastes text from the clipboard: the copy made here whole, else plain
/// text or Markdown.
pub fn pasteText(rt: *RichText, s: []const u8, format: Format) void {
    if (rt.clip.matches(s)) return paste(rt, &rt.clip.doc.?, rt.clip.whole);
    switch (format) {
        .plain => if (std.mem.indexOfScalar(u8, s, '\n') != null) pastePlain(rt, s) else rt.replaceSelection(s, rt.typingMarks(), .other),
        .markdown => pasteMarkdown(rt, s),
    }
}
