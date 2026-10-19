//! A multi-line text's commands: what one event asks of the focused text
//! (key combinations, the input system's operations, keys and characters)
//! as `Cmd`s, and what each does to a `TextArea`. The code editor sees the
//! commands first and leaves the ones it doesn't handle to `apply`.
const std = @import("std");
const builtin = @import("builtin");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const S = ctx_mod.Shortcut;
const TextArea = @import("textarea.zig").TextArea;
const layout = @import("textlayout.zig");
const Geo = layout.Geo;

const mac = builtin.os.tag == .macos;

pub const Motion = enum { left, right, word_left, word_right, line_start, line_end, up, down, page_up, page_down, doc_start, doc_end };

pub const Delete = enum { back, forward, word_back, word_forward, line_start };

pub const Cmd = union(enum) {
    insert: []const u8,
    set_marked: struct { text: []const u8, sel_start: usize, sel_len: usize },
    unmark,
    move: struct { motion: Motion, select: bool = false },
    delete: Delete,
    newline,
    /// Tab, with Shift when true.
    tab: bool,
    escape,
    select_all,
    copy,
    cut,
    undo,
    redo,
};

/// This event's commands for the focused text, in the frame's memory.
/// Key combinations it reads are taken (`Context.shortcut`); Tab only
/// with `tab`, else it moves the focus.
pub fn collect(c: *Context, tab: bool) []const Cmd {
    var out: std.ArrayList(Cmd) = .empty;
    const gpa = c.alloc();
    if (c.input.shortcut) |s| if (fromShortcut(s, tab)) |cmd| {
        c.input.shortcut = null;
        c.shortcut_taken = true;
        out.append(gpa, cmd) catch {};
    };
    for (c.input.ops) |op| {
        const cmd: ?Cmd = switch (op) {
            .insert => |t| .{ .insert = t },
            .set_marked => |m| .{ .set_marked = .{ .text = m.text, .sel_start = m.sel_start, .sel_len = m.sel_len } },
            .unmark => .unmark,
            .command => |k| switch (k) {
                .delete_backward => .{ .delete = .back },
                .delete_forward => .{ .delete = .forward },
                .delete_word_backward => .{ .delete = .word_back },
                .delete_to_line_start => .{ .delete = .line_start },
                .delete_word_forward => .{ .delete = .word_forward },
                .move_up => .{ .move = .{ .motion = .up } },
                .move_down => .{ .move = .{ .motion = .down } },
                .select_up => .{ .move = .{ .motion = .up, .select = true } },
                .select_down => .{ .move = .{ .motion = .down, .select = true } },
                .move_page_up => .{ .move = .{ .motion = .page_up } },
                .move_page_down => .{ .move = .{ .motion = .page_down } },
                .select_page_up => .{ .move = .{ .motion = .page_up, .select = true } },
                .select_page_down => .{ .move = .{ .motion = .page_down, .select = true } },
                .move_doc_start => .{ .move = .{ .motion = .doc_start } },
                .move_doc_end => .{ .move = .{ .motion = .doc_end } },
                .select_doc_start => .{ .move = .{ .motion = .doc_start, .select = true } },
                .select_doc_end => .{ .move = .{ .motion = .doc_end, .select = true } },
                .insert_backtab => if (tab) Cmd{ .tab = true } else null,
                .move_left => .{ .move = .{ .motion = .left } },
                .move_right => .{ .move = .{ .motion = .right } },
                .move_word_left => .{ .move = .{ .motion = .word_left } },
                .move_word_right => .{ .move = .{ .motion = .word_right } },
                .move_line_start => .{ .move = .{ .motion = .line_start } },
                .move_line_end => .{ .move = .{ .motion = .line_end } },
                .select_left => .{ .move = .{ .motion = .left, .select = true } },
                .select_right => .{ .move = .{ .motion = .right, .select = true } },
                .select_word_left => .{ .move = .{ .motion = .word_left, .select = true } },
                .select_word_right => .{ .move = .{ .motion = .word_right, .select = true } },
                .select_line_start => .{ .move = .{ .motion = .line_start, .select = true } },
                .select_line_end => .{ .move = .{ .motion = .line_end, .select = true } },
                .select_all => .select_all,
                .insert_newline => .newline,
                .insert_tab => if (tab) Cmd{ .tab = c.input.shift } else null,
                .cancel => .escape,
                .copy => .copy,
                .cut => .cut,
            },
        };
        if (cmd) |x| {
            if (x == .tab) c.shortcut_taken = true;
            out.append(gpa, x) catch {};
        }
    }
    if (c.input.chars.len > 0) out.append(gpa, .{ .insert = c.input.chars }) catch {};
    if (c.input.key) |k| {
        const sel = c.input.shift;
        // Control with a key that isn't offered as a combination (Linux,
        // Windows): by words, and to the text's ends.
        const ctrl = !mac and c.input.ctrl;
        const cmd: ?Cmd = switch (k) {
            .backspace => .{ .delete = if (ctrl) .word_back else .back },
            .delete => .{ .delete = if (ctrl) .word_forward else .forward },
            .left => .{ .move = .{ .motion = if (ctrl) .word_left else .left, .select = sel } },
            .right => .{ .move = .{ .motion = if (ctrl) .word_right else .right, .select = sel } },
            .up => .{ .move = .{ .motion = .up, .select = sel } },
            .down => .{ .move = .{ .motion = .down, .select = sel } },
            .home => .{ .move = .{ .motion = if (ctrl) .doc_start else .line_start, .select = sel } },
            .end => .{ .move = .{ .motion = if (ctrl) .doc_end else .line_end, .select = sel } },
            .page_up => .{ .move = .{ .motion = .page_up, .select = sel } },
            .page_down => .{ .move = .{ .motion = .page_down, .select = sel } },
            .enter => .newline,
            .tab => if (tab) Cmd{ .tab = sel } else null,
            .escape => .escape,
            else => null,
        };
        if (cmd) |x| {
            if (x == .tab) c.shortcut_taken = true;
            c.input.key = null;
            out.append(gpa, x) catch {};
        }
    }
    return out.items;
}

/// The command of a key combination, as the platform binds it.
fn fromShortcut(s: S, tab: bool) ?Cmd {
    const k = s.key;
    const primary = if (mac) s.cmd else s.ctrl;
    const plain = !s.cmd and !s.ctrl and !s.alt;
    if (k == S.up or k == S.down) {
        const up = k == S.up;
        if (primary) return .{ .move = .{ .motion = if (up) .doc_start else .doc_end, .select = s.shift } };
        if (plain or s.alt) return .{ .move = .{ .motion = if (up) .up else .down, .select = s.shift } };
        return null;
    }
    if (k == S.left or k == S.right) {
        const left = k == S.left;
        if (mac and s.cmd) return .{ .move = .{ .motion = if (left) .line_start else .line_end, .select = s.shift } };
        if (s.alt or (!mac and s.ctrl)) return .{ .move = .{ .motion = if (left) .word_left else .word_right, .select = s.shift } };
        if (plain) return .{ .move = .{ .motion = if (left) .left else .right, .select = s.shift } };
        return null;
    }
    if (primary and !s.alt) switch (k) {
        'z' => return if (s.shift) .redo else .undo,
        'y' => return if (!mac and !s.shift) .redo else null,
        'a' => return if (!s.shift) .select_all else null,
        'c' => return if (!s.shift) .copy else null,
        'x' => return if (!s.shift) .cut else null,
        else => {},
    };
    if (k == S.tab and tab and plain) return .{ .tab = s.shift };
    if (k == S.enter and plain and !s.shift) return .newline;
    return null;
}

pub const ApplyOptions = struct {
    read_only: bool = false,
    /// Home goes to the line's first character that isn't a space first.
    smart_home: bool = false,
    /// What Tab types.
    tab_text: []const u8 = "\t",
};

/// Does `cmd` to `ta`; true if the text changed.
pub fn apply(c: *Context, ta: *TextArea, g: Geo, cmd: Cmd, opts: ApplyOptions) bool {
    const ro = opts.read_only;
    const before = ta.doc.version;
    ta.time = c.time;
    switch (cmd) {
        .insert => |s| if (!ro) ta.insert(s),
        .set_marked => |m| if (!ro) {
            const range = ta.marked orelse .{ ta.sel.lo(), ta.sel.hi() };
            ta.replaceRange(range[0], range[1], m.text, .typing);
            const n = m.text.len;
            ta.marked = if (n == 0) null else .{ range[0], range[0] + n };
            ta.sel = .{ .anchor = range[0] + @min(m.sel_start, n), .caret = range[0] + @min(m.sel_start + m.sel_len, n) };
        },
        .unmark => ta.marked = null,
        .move => |mv| move(ta, g, mv.motion, mv.select, opts.smart_home),
        .delete => |d| if (!ro) {
            const at = ta.sel.caret;
            ta.deleteTo(switch (d) {
                .back => ta.prevChar(at),
                .forward => ta.nextChar(at),
                .word_back => ta.prevWord(at),
                .word_forward => ta.nextWord(at),
                .line_start => ta.doc.lineStart(ta.doc.lineOf(at)),
            });
        },
        .newline => if (!ro) ta.replaceSelection("\n", .other),
        .tab => if (!ro) ta.replaceSelection(opts.tab_text, .other),
        .escape => {
            if (!ta.sel.empty()) ta.collapse(ta.sel.caret) else c.focus = 0;
        },
        .select_all => {
            ta.select(0, ta.len());
            ta.reveal = false;
        },
        .copy, .cut => if (!ta.sel.empty()) {
            c.copy_done = true;
            const s = ta.selectedText(c.alloc());
            c.clipboard.write(c.clipboard.ctx, s);
            if (cmd == .cut and !ro) ta.replaceSelection("", .other);
        },
        .undo => if (!ro) ta.undo(),
        .redo => if (!ro) ta.redo(),
    }
    c.changed = true;
    return ta.doc.version != before;
}

/// Moves the caret (extends the selection with `select`) by `m`.
pub fn move(ta: *TextArea, g: Geo, m: Motion, select: bool, smart_home: bool) void {
    const at = ta.sel.caret;
    const collapsing = !select and !ta.sel.empty();
    var keep_goal = false;
    const to: usize = switch (m) {
        .left => if (collapsing) ta.sel.lo() else ta.prevChar(at),
        .right => if (collapsing) ta.sel.hi() else ta.nextChar(at),
        .word_left => ta.prevWord(at),
        .word_right => ta.nextWord(at),
        .line_start => rowStart(ta, g, at, smart_home),
        .line_end => rowEnd(ta, g, at),
        .up, .down, .page_up, .page_down => blk: {
            keep_goal = true;
            const n: usize = if (m == .up or m == .down) 1 else @max(1, g.page_rows);
            break :blk vertical(ta, g, at, n, m == .up or m == .page_up);
        },
        .doc_start => 0,
        .doc_end => ta.len(),
    };
    const goal = ta.goal_x;
    if (select) ta.select(ta.sel.anchor, to) else ta.collapse(to);
    if (keep_goal) ta.goal_x = goal;
    ta.marked = null;
}

/// The start of `at`'s row; with `smart`, of its line's text first.
fn rowStart(ta: *TextArea, g: Geo, at: usize, smart: bool) usize {
    const p = layout.posOf(g, &ta.doc, at);
    const l = layout.lineRows(g, &ta.doc, p.line);
    const row_start = l.start + l.rows[p.sub];
    if (!smart or p.sub > 0) return row_start;
    var first: usize = 0;
    while (first < l.str.len and (l.str[first] == ' ' or l.str[first] == '\t')) first += 1;
    return if (at == l.start + first) l.start else l.start + first;
}

fn rowEnd(ta: *TextArea, g: Geo, at: usize) usize {
    const p = layout.posOf(g, &ta.doc, at);
    const l = layout.lineRows(g, &ta.doc, p.line);
    return l.start + l.atX(p.sub, std.math.inf(f32));
}

/// `n` rows above (`up`) or below `at`, at the goal's x.
fn vertical(ta: *TextArea, g: Geo, at: usize, n: usize, up: bool) usize {
    const p = layout.posOf(g, &ta.doc, at);
    const goal = ta.goal_x orelse p.x;
    ta.goal_x = goal;
    var line = p.line;
    var sub = p.sub;
    var rows = layout.lineRows(g, &ta.doc, line).rows.len;
    for (0..n) |_| {
        if (up) {
            if (sub > 0) {
                sub -= 1;
            } else if (line > 0) {
                line -= 1;
                rows = layout.lineRows(g, &ta.doc, line).rows.len;
                sub = rows - 1;
            } else return 0;
        } else {
            if (sub + 1 < rows) {
                sub += 1;
            } else if (line + 1 < ta.doc.lineCount()) {
                line += 1;
                sub = 0;
                rows = layout.lineRows(g, &ta.doc, line).rows.len;
            } else return ta.len();
        }
    }
    const l = layout.lineRows(g, &ta.doc, line);
    return l.start + l.atX(sub, goal);
}
