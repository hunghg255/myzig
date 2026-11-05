//! A text's other carets (`TextArea.extra`), next to its selection: adding
//! them (a caret a line above or below, the next match of the selection,
//! a click with Ctrl or Cmd), and the commands that act at every caret (typing,
//! deleting, moving) as one step of undo.
const std = @import("std");
const TextArea = @import("textarea.zig").TextArea;
const Sel = @import("textdoc.zig").Sel;
const keys = @import("textarea_keys.zig");
const layout = @import("textlayout.zig");
const Geo = layout.Geo;
const Context = @import("context.zig").Context;

/// Every selection, the main one included, in the frame's memory, by
/// position.
pub fn all(ta: *const TextArea, gpa: std.mem.Allocator) []Sel {
    const out = gpa.alloc(Sel, ta.extra.items.len + 1) catch return @constCast(&[_]Sel{});
    out[0] = ta.sel;
    @memcpy(out[1..], ta.extra.items);
    std.mem.sort(Sel, out, {}, lessSel);
    return out;
}

fn lessSel(_: void, a: Sel, b: Sel) bool {
    return a.lo() < b.lo();
}

/// Adds a caret (or selection) beside the main one, which moves to `s`.
pub fn add(ta: *TextArea, s: Sel) void {
    ta.extra.append(ta.doc.gpa, ta.sel) catch return;
    ta.sel = .{ .caret = @min(s.caret, ta.len()), .anchor = @min(s.anchor, ta.len()) };
    ta.reveal = true;
    merge(ta);
}

pub fn clear(ta: *TextArea) void {
    ta.extra.clearRetainingCapacity();
}

/// Joins selections that touch or overlap; drops ones past the end.
pub fn merge(ta: *TextArea) void {
    var i: usize = 0;
    while (i < ta.extra.items.len) {
        const e = &ta.extra.items[i];
        e.caret = @min(e.caret, ta.len());
        e.anchor = @min(e.anchor, ta.len());
        if (overlaps(e.*, ta.sel)) {
            ta.sel = join(ta.sel, e.*);
            _ = ta.extra.swapRemove(i);
            i = 0;
            continue;
        }
        var j: usize = i + 1;
        var joined = false;
        while (j < ta.extra.items.len) : (j += 1) if (overlaps(ta.extra.items[i], ta.extra.items[j])) {
            ta.extra.items[i] = join(ta.extra.items[i], ta.extra.items[j]);
            _ = ta.extra.swapRemove(j);
            joined = true;
            break;
        };
        if (!joined) i += 1;
    }
}

fn overlaps(a: Sel, b: Sel) bool {
    if (a.empty() and b.empty()) return a.caret == b.caret;
    return a.lo() < b.hi() and b.lo() < a.hi() or a.caret == b.caret;
}

fn join(main: Sel, other: Sel) Sel {
    const lo = @min(main.lo(), other.lo());
    const hi = @max(main.hi(), other.hi());
    return if (main.caret >= main.anchor) .{ .anchor = lo, .caret = hi } else .{ .anchor = hi, .caret = lo };
}

/// A caret on the row above (`up`) or below the topmost or bottommost one.
pub fn addVertical(ta: *TextArea, g: Geo, up: bool) void {
    const sels = all(ta, ta.doc.gpa);
    defer ta.doc.gpa.free(sels);
    if (sels.len == 0) return;
    const edge = if (up) sels[0] else sels[sels.len - 1];
    const p = layout.posOf(g, &ta.doc, edge.caret);
    const line = if (up) (if (p.line == 0) return else p.line - 1) else (if (p.line + 1 >= ta.doc.lineCount()) return else p.line + 1);
    const l = layout.lineRows(g, &ta.doc, line);
    const at = l.start + l.atX(0, p.x);
    const goal = ta.goal_x;
    add(ta, .at(at));
    ta.goal_x = goal;
}

/// Selects the word at the caret, or else the next match of the selection
/// (after the last one), as another selection.
pub fn addNext(ta: *TextArea) void {
    if (ta.sel.empty()) {
        const w = ta.wordAt(ta.sel.caret);
        if (w[1] > w[0]) ta.select(w[0], w[1]);
        return;
    }
    const gpa = ta.doc.gpa;
    const needle = ta.selectedText(gpa);
    defer gpa.free(needle);
    const hay = ta.text(gpa);
    defer gpa.free(hay);
    const sels = all(ta, gpa);
    defer gpa.free(sels);
    const from = sels[sels.len - 1].hi();
    const at = std.mem.indexOfPos(u8, hay, from, needle) orelse std.mem.indexOf(u8, hay, needle) orelse return;
    for (sels) |s| if (s.lo() == at) return; // Every match is taken.
    add(ta, .{ .anchor = at, .caret = at + needle.len });
}

/// Whether `cmd` acts at every caret here (the rest act on the main one).
pub fn handles(ta: *const TextArea, cmd: keys.Cmd) bool {
    if (ta.extra.items.len == 0) return false;
    return switch (cmd) {
        .insert, .delete, .newline, .tab, .move, .escape, .cut => true,
        else => false,
    };
}

/// Does `cmd` at every caret, as one step of undo.
pub fn apply(c: *Context, ta: *TextArea, g: Geo, cmd: keys.Cmd, opts: keys.ApplyOptions) void {
    ta.time = c.time;
    c.changed = true;
    switch (cmd) {
        .escape => clear(ta),
        .move => |mv| {
            for (ta.extra.items) |*e| {
                const main = ta.sel;
                ta.sel = e.*;
                ta.goal_x = null;
                keys.move(ta, g, mv.motion, mv.select, opts.smart_home);
                e.* = ta.sel;
                ta.sel = main;
            }
            ta.goal_x = null;
            keys.move(ta, g, mv.motion, mv.select, opts.smart_home);
            ta.goal_x = null;
            merge(ta);
        },
        .insert => |s| if (!opts.read_only) edit(ta, s, null),
        .newline => if (!opts.read_only) edit(ta, "\n", null),
        .tab => if (!opts.read_only) edit(ta, opts.tab_text, null),
        .delete => |d| if (!opts.read_only) edit(ta, "", d),
        .cut => {
            const gpa = c.alloc();
            var out: std.ArrayList(u8) = .empty;
            for (all(ta, gpa)) |s| if (!s.empty()) {
                if (out.items.len > 0) out.append(gpa, '\n') catch {};
                out.appendSlice(gpa, ta.doc.slice(gpa, s.lo(), s.hi())) catch {};
            };
            if (out.items.len == 0) return;
            c.copy_done = true;
            c.clipboard.write(c.clipboard.ctx, out.items);
            if (!opts.read_only) edit(ta, "", null);
        },
        else => {},
    }
}

/// Replaces each selection (or, empty, the span `del` names from its
/// caret) with `s`, from the first to the last.
fn edit(ta: *TextArea, s: []const u8, del: ?keys.Delete) void {
    const gpa = ta.doc.gpa;
    const sels = all(ta, gpa);
    defer gpa.free(sels);
    const main_lo = ta.sel.lo();
    ta.doc.begin(.other, ta.sel, ta.time);
    var shift: isize = 0;
    var out: std.ArrayList(Sel) = .empty;
    defer out.deinit(gpa);
    var main: Sel = ta.sel;
    var last_end: usize = 0;
    for (sels) |sel| {
        var a = sel.lo();
        var b = sel.hi();
        if (sel.empty()) if (del) |d| {
            const to = switch (d) {
                .back => ta.prevChar(a),
                .forward => ta.nextChar(a),
                .word_back => ta.prevWord(a),
                .word_forward => ta.nextWord(a),
                .line_start => ta.doc.lineStart(ta.doc.lineOf(a)),
            };
            a = @min(a, to);
            b = @max(b, to);
        };
        // Spans of carets side by side don't cross.
        a = @max(a, last_end);
        b = @max(a, b);
        last_end = b;
        const at: usize = @intCast(@as(isize, @intCast(a)) + shift);
        ta.doc.edit(at, at + (b - a), s);
        const caret = at + s.len;
        if (sel.lo() == main_lo) main = .at(caret) else out.append(gpa, .at(caret)) catch {};
        shift += @as(isize, @intCast(s.len)) - @as(isize, @intCast(b - a));
    }
    ta.sel = main;
    ta.extra.clearRetainingCapacity();
    ta.extra.appendSlice(gpa, out.items) catch {};
    ta.doc.end(ta.sel);
    ta.doc.breakGroup();
    ta.marked = null;
    ta.goal_x = null;
    ta.reveal = true;
    ta.changed = true;
    merge(ta);
}
