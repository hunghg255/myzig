//! The code editor's bars over its text: finding (and replacing), with
//! the count of matches, the previous and next ones, and the toggles of
//! case, whole words and regular expressions; and going to a line. Enter
//! in the query goes to the next match (Shift+Enter the previous), in the
//! replacement replaces it; Escape closes the bar and gives the keyboard
//! back to the text.
const std = @import("std");
const types = @import("../types.zig");
const ctx_mod = @import("../context.zig");
const Context = ctx_mod.Context;
const S = ctx_mod.Shortcut;
const widgets = @import("../widgets.zig");
const textfield = @import("../textfield.zig");
const CodeEditor = @import("editor.zig").CodeEditor;

/// Escape, as a key, an operation or a key combination, for a bar's field.
fn escaped(c: *Context, id: u64) bool {
    if (id == 0 or c.focus != id) return false;
    if (c.input.key == .escape) return true;
    for (c.input.ops) |op| if (op == .command and op.command == .cancel) return true;
    return c.shortcut(.{ .key = S.escape });
}

/// A field of a bar, focused when `focus` asks; its id goes to `id`.
fn barField(c: *Context, buf: *textfield.TextBuffer, id: *u64, focus: bool, placeholder: []const u8, width: f32) textfield.Result {
    id.* = c.peekId(null);
    if (focus) {
        c.focus = id.*;
        c.changed = true;
    }
    return textfield.textField(c, buf, .{ .placeholder = placeholder, .width = .{ .px = width }, .size = 13 });
}

fn toggle(c: *Context, label: []const u8, on: *bool) void {
    if (widgets.button(c, label, .{ .variant = if (on.*) .primary else .ghost, .size = 12 }).clicked) on.* = !on.*;
}

pub fn findBar(c: *Context, ed: *CodeEditor) void {
    const th = c.theme;
    const f = &ed.find;
    const ta = &ed.area;
    widgets.column(c, .{ .width = .fill, .padding = .xy(8, 6), .gap = 6, .background = th.surface, .border = th.border });
    defer widgets.end(c);
    widgets.row(c, .{ .width = .fill, .gap = 6, .align_items = .center });
    if (escaped(c, ed.query_id) or escaped(c, ed.replacement_id)) {
        widgets.end(c);
        ed.closeBars();
        return;
    }
    const want_query = ed.focus_next == .query;
    if (want_query) ed.focus_next = .none;
    const q = barField(c, &f.query, &ed.query_id, want_query, "Find", 200);
    if (q.changed) {
        // As the query is typed, the first match from the selection.
        f.update(ta.doc.gpa, &ta.doc);
        f.current = null;
        if (f.matches.items.len > 0) {
            const at = ta.sel.lo();
            ta.collapse(at);
            f.step(ta, false);
        }
    }
    if (q.submitted) {
        f.update(ta.doc.gpa, &ta.doc);
        f.step(ta, c.input.shift);
    }
    const n = f.matches.items.len;
    const status = if (f.bad_pattern)
        "Invalid pattern"
    else if (f.query.len == 0)
        ""
    else if (n == 0)
        "No results"
    else if (f.current) |i|
        c.print("{d} of {d}{s}", .{ i + 1, n, if (n >= f.limit) "+" else "" })
    else
        c.print("{d} matches", .{n});
    widgets.text(c, status, .{ .size = 12, .color = if (f.bad_pattern) th.danger else th.muted });
    widgets.spacer(c);
    toggle(c, "Aa", &f.flags.case);
    toggle(c, "W", &f.flags.word);
    toggle(c, ".*", &f.flags.regex);
    if (widgets.button(c, "Prev", .{ .variant = .ghost, .size = 12, .disabled = n == 0 }).clicked) f.step(ta, true);
    if (widgets.button(c, "Next", .{ .variant = .ghost, .size = 12, .disabled = n == 0 }).clicked) f.step(ta, false);
    if (widgets.button(c, if (f.replacing) "Find only" else "Replace…", .{ .variant = .ghost, .size = 12 }).clicked) f.replacing = !f.replacing;
    if (widgets.button(c, "Done", .{ .variant = .ghost, .size = 12 }).clicked) {
        widgets.end(c);
        ed.closeBars();
        return;
    }
    widgets.end(c);
    if (!f.replacing) return;
    widgets.row(c, .{ .width = .fill, .gap = 6, .align_items = .center });
    defer widgets.end(c);
    const want_rep = ed.focus_next == .replacement;
    if (want_rep) ed.focus_next = .none;
    const r = barField(c, &f.replacement, &ed.replacement_id, want_rep, "Replace", 200);
    if (r.submitted and !ed.read_only) f.replaceOne(ta.doc.gpa, ta);
    if (widgets.button(c, "Replace", .{ .size = 12, .disabled = n == 0 or ed.read_only }).clicked) f.replaceOne(ta.doc.gpa, ta);
    if (widgets.button(c, "All", .{ .size = 12, .disabled = n == 0 or ed.read_only }).clicked) _ = f.replaceAll(ta.doc.gpa, ta);
}

pub fn gotoBar(c: *Context, ed: *CodeEditor) void {
    const th = c.theme;
    widgets.row(c, .{ .width = .fill, .padding = .xy(8, 6), .gap = 8, .align_items = .center, .background = th.surface, .border = th.border });
    defer widgets.end(c);
    if (escaped(c, ed.goto_id)) return ed.closeBars();
    widgets.text(c, "Go to line", .{ .size = 12, .color = th.muted });
    const want = ed.focus_next == .goto;
    if (want) ed.focus_next = .none;
    const r = barField(c, &ed.goto, &ed.goto_id, want, "", 90);
    const count = ed.area.doc.lineCount();
    widgets.text(c, c.print("1 – {d}", .{count}), .{ .size = 12, .color = th.muted });
    if (r.submitted) {
        const t = std.mem.trim(u8, ed.goto.text(), " ");
        const line = std.fmt.parseInt(usize, t, 10) catch 0;
        if (line > 0) {
            ed.goToLine(line);
            ed.goto_open = false;
        }
    }
}
