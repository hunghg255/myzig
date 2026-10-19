//! The rich text editor's keys: the formats' key combinations, as word
//! processors bind them (Command on the Mac, Control elsewhere), Tab and
//! Shift+Tab in lists, and the text's commands (`textarea_keys.collect`)
//! done to the document: movement by characters, words, rows, pages and
//! the whole text, deleting, Enter, the clipboard, undo and the input
//! method's composition.
const std = @import("std");
const builtin = @import("builtin");
const ctx_mod = @import("../context.zig");
const tkeys = @import("../textarea_keys.zig");
const model = @import("model.zig");
const layout = @import("layout.zig");
const clip = @import("clipboard.zig");
const RichText = @import("editor.zig").RichText;
const Context = ctx_mod.Context;
const S = ctx_mod.Shortcut;
const Pos = model.Pos;
const Geo = layout.Geo;

const mac = builtin.os.tag == .macos;

pub const Config = struct {
    read_only: bool = false,
    clipboard: clip.Format = .plain,
};

pub const Outcome = struct {
    /// ⌘K: the app asks for a link's URL (`RichText.setLink`).
    link_requested: bool = false,
};

const Action = union(enum) {
    toggle: model.Toggle,
    kind: model.Kind,
    indent: i8,
    link,
};

const Binding = struct { s: S, a: Action };

/// `.cmd` is Command on the Mac and Control elsewhere (`Shortcut.native`).
const bindings = [_]Binding{
    .{ .s = .{ .key = 'b', .cmd = true }, .a = .{ .toggle = .bold } },
    .{ .s = .{ .key = 'i', .cmd = true }, .a = .{ .toggle = .italic } },
    .{ .s = .{ .key = 'u', .cmd = true }, .a = .{ .toggle = .underline } },
    .{ .s = .{ .key = 'x', .cmd = true, .shift = true }, .a = .{ .toggle = .strike } },
    .{ .s = if (mac) .{ .key = 'e', .cmd = true } else .{ .key = 'e', .cmd = true, .shift = true }, .a = .{ .toggle = .code } },
    .{ .s = .{ .key = 'k', .cmd = true }, .a = .link },
    .{ .s = .{ .key = '1', .cmd = true, .alt = true }, .a = .{ .kind = .heading1 } },
    .{ .s = .{ .key = '2', .cmd = true, .alt = true }, .a = .{ .kind = .heading2 } },
    .{ .s = .{ .key = '3', .cmd = true, .alt = true }, .a = .{ .kind = .heading3 } },
    .{ .s = .{ .key = '0', .cmd = true, .alt = true }, .a = .{ .kind = .paragraph } },
    .{ .s = .{ .key = '7', .cmd = true, .shift = true }, .a = .{ .kind = .numbered } },
    .{ .s = .{ .key = '8', .cmd = true, .shift = true }, .a = .{ .kind = .bullet } },
    .{ .s = .{ .key = 'l', .cmd = true, .shift = true }, .a = .{ .kind = .task } },
    .{ .s = .{ .key = '9', .cmd = true, .shift = true }, .a = .{ .kind = .quote } },
    .{ .s = .{ .key = 'c', .cmd = true, .alt = true }, .a = .{ .kind = .code } },
    .{ .s = .{ .key = ']', .cmd = true }, .a = .{ .indent = 1 } },
    .{ .s = .{ .key = '[', .cmd = true }, .a = .{ .indent = -1 } },
};

/// The selection is in a list: Tab nests its items.
fn inList(rt: *const RichText) bool {
    for (rt.doc.blocks.items[rt.sel.lo().block .. rt.sel.hi().block + 1]) |b| if (!b.style.kind.isList()) return false;
    return true;
}

/// Does what this event's keys ask of the focused editor.
pub fn handle(c: *Context, rt: *RichText, g: Geo, cfg: Config) Outcome {
    var out: Outcome = .{};
    rt.time = c.time;
    if (!cfg.read_only) {
        for (bindings) |bd| if (c.shortcut(bd.s)) switch (bd.a) {
            .toggle => |t| rt.toggle(t),
            .kind => |k| rt.setKind(k),
            .indent => |d| rt.indent(d),
            .link => out.link_requested = true,
        };
        if (inList(rt)) if (c.tabPressed()) |back| {
            c.shortcut_taken = true;
            c.input.shortcut = null;
            if (c.input.key == .tab) c.input.key = null;
            rt.indent(if (back) -1 else 1);
            c.changed = true;
        };
    }
    for (tkeys.collect(c, false)) |cmd| apply(c, rt, g, cmd, cfg);
    return out;
}

fn apply(c: *Context, rt: *RichText, g: Geo, cmd: tkeys.Cmd, cfg: Config) void {
    const ro = cfg.read_only;
    c.changed = true;
    switch (cmd) {
        .insert => |s| if (!ro) {
            if (s.len > 1 and rt.clip.matches(s)) {
                clip.pasteText(rt, s, cfg.clipboard);
            } else if (std.mem.indexOfScalar(u8, s, '\n') != null) {
                clip.pasteText(rt, s, cfg.clipboard);
            } else rt.insert(s);
        },
        .set_marked => |m| if (!ro) rt.setMarked(m.text, m.sel_start, m.sel_len),
        .unmark => rt.marked = null,
        .move => |mv| move(rt, g, mv.motion, mv.select),
        .delete => |d| if (!ro) switch (d) {
            .back => rt.deleteBackward(),
            .forward => rt.deleteForward(),
            .word_back => rt.deleteTo(rt.prevWord(rt.sel.caret)),
            .word_forward => rt.deleteTo(rt.nextWord(rt.sel.caret)),
            .line_start => rt.deleteTo(rowEdge(rt, g, rt.sel.caret, false)),
        },
        .newline => if (!ro) rt.newline(),
        .tab => {},
        .escape => if (!rt.sel.empty()) rt.collapse(rt.sel.caret) else {
            c.focus = 0;
        },
        .select_all => rt.selectAll(),
        .copy, .cut => if (!rt.sel.empty()) {
            const s = clip.copy(rt, cfg.clipboard);
            c.copy_done = true;
            c.clipboard.write(c.clipboard.ctx, s);
            if (cmd == .cut and !ro) _ = rt.deleteSelection();
        },
        .undo => if (!ro) rt.undo(),
        .redo => if (!ro) rt.redo(),
    }
}

/// Moves the caret (extends the selection with `select`) by `m`.
pub fn move(rt: *RichText, g: Geo, m: tkeys.Motion, select: bool) void {
    const at = rt.sel.caret;
    const collapsing = !select and !rt.sel.empty();
    var keep_goal = false;
    const to: Pos = switch (m) {
        .left => if (collapsing) rt.sel.lo() else rt.prevPos(at),
        .right => if (collapsing) rt.sel.hi() else rt.nextPos(at),
        .word_left => rt.prevWord(at),
        .word_right => rt.nextWord(at),
        .line_start => rowEdge(rt, g, at, false),
        .line_end => rowEdge(rt, g, at, true),
        .up, .down => blk: {
            keep_goal = true;
            break :blk vertical(rt, g, at, 1, m == .up);
        },
        .page_up, .page_down => blk: {
            keep_goal = true;
            const rows: usize = @intFromFloat(@max(1, g.page / g.rowH(.paragraph)));
            break :blk vertical(rt, g, at, rows, m == .page_up);
        },
        .doc_start => .{},
        .doc_end => rt.doc.end(),
    };
    const goal = rt.goal_x;
    if (select) rt.select(rt.sel.anchor, to) else rt.collapse(to);
    if (keep_goal) rt.goal_x = goal;
}

/// The start (or the end) of `p`'s row.
fn rowEdge(rt: *const RichText, g: Geo, p: Pos, end: bool) Pos {
    _ = rt;
    const l = g.lines(p.block);
    const sub = l.rows.rowOf(p.off);
    if (!end) return .{ .block = p.block, .off = l.rows.rows[sub] };
    return .{ .block = p.block, .off = l.rows.atX(sub, std.math.inf(f32)) };
}

/// `n` rows above (`up`) or below `p`, at the goal's x, across blocks.
fn vertical(rt: *RichText, g: Geo, p: Pos, n: usize, up: bool) Pos {
    const w = g.where(p);
    const goal = rt.goal_x orelse w.x;
    rt.goal_x = goal;
    var block = p.block;
    var sub = w.sub;
    var rows = g.lines(block).count();
    for (0..n) |_| {
        if (up) {
            if (sub > 0) {
                sub -= 1;
            } else if (block > 0) {
                block -= 1;
                rows = g.lines(block).count();
                sub = rows - 1;
            } else return .{};
        } else {
            if (sub + 1 < rows) {
                sub += 1;
            } else if (block + 1 < rt.doc.count()) {
                block += 1;
                sub = 0;
                rows = g.lines(block).count();
            } else return rt.doc.end();
        }
    }
    return g.atRow(block, sub, goal);
}
