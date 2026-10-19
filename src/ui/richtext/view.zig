//! The rich text editor's view: its blocks in a scrolling box, built only
//! where in view (a document of a hundred thousand paragraphs builds what
//! a screenful does), with list markers, task check boxes, quotation bars
//! and backgrounds of code; the selection across blocks, the caret and an
//! input method's composition; and the pointer's presses and drags (a
//! double click selects a word, a triple click a block).
const std = @import("std");
const types = @import("../types.zig");
const ctx_mod = @import("../context.zig");
const model = @import("model.zig");
const layout = @import("layout.zig");
const keys = @import("keys.zig");
const clip = @import("clipboard.zig");
const editor = @import("editor.zig");
const RichText = editor.RichText;
const Context = ctx_mod.Context;
const Pos = model.Pos;
const Geo = layout.Geo;

pub const Options = struct {
    width: types.Length = .fill,
    height: types.Length = .fill,
    /// The body's font size; headings and code scale from it.
    size: f32 = 15,
    placeholder: []const u8 = "",
    /// Selectable, copyable and its links clickable, not editable.
    read_only: bool = false,
    /// No box of its own (border, fill, focus ring).
    bare: bool = false,
    padding: types.Edges = .xy(16, 12),
    /// Typing `# `, `- `, `**bold**`… formats.
    markdown_shortcuts: bool = true,
    /// What copy writes besides the rich copy kept within the app, and
    /// what text from elsewhere pastes as.
    clipboard: clip.Format = .plain,
};

pub const Result = struct {
    /// The user edited the text in this frame.
    changed: bool = false,
    focused: bool = false,
    /// The blocks built, first and last.
    first_block: usize = 0,
    last_block: usize = 0,
    /// A link was clicked (with ⌘ or Ctrl while editable): its URL.
    link_clicked: ?[]const u8 = null,
    /// ⌘K asked for a link: show a field, then `RichText.setLink`.
    link_requested: bool = false,
};

const overscan: f32 = 200;

/// The content's origin on screen.
const Frame = struct {
    view: types.Rect,
    scroll: f32,
    pad: types.Edges,

    fn x(f: Frame) f32 {
        return f.view.x + f.pad.left;
    }

    fn y(f: Frame) f32 {
        return f.view.y + f.pad.top - f.scroll;
    }
};

fn unitAt(rt: *const RichText, unit: editor.Unit, p: Pos) [2]Pos {
    return switch (unit) {
        .char => .{ p, p },
        .word => rt.wordAt(p),
        .block => .{ .{ .block = p.block }, .{ .block = p.block, .off = rt.doc.block(p.block).len() } },
    };
}

fn pointer(c: *Context, rt: *RichText, g: Geo, f: Frame, it: ctx_mod.Interaction, opts: Options, out: *Result) void {
    const m = c.input.mouse;
    if (c.input.pressed and c.hot == it.id) {
        const at = layout.posAt(g, m.x - f.x(), m.y - f.y());
        rt.drag_unit = if (c.input.click_count >= 3) .block else if (c.input.click_count == 2) .word else .char;
        rt.drag_from = unitAt(rt, rt.drag_unit, at);
        if (c.input.shift and rt.drag_unit == .char) {
            rt.drag_from = .{ rt.sel.anchor, rt.sel.anchor };
            rt.select(rt.sel.anchor, at);
        } else rt.select(rt.drag_from[0], rt.drag_from[1]);
        rt.dragging = true;
        c.selection.blocked = true;
        c.changed = true;
        // A link opens with ⌘ (Ctrl), or with a click where nothing edits.
        const b = rt.doc.block(at.block);
        if (rt.drag_unit == .char and (opts.read_only or c.input.adding()) and at.off < b.len()) {
            const link = b.marksAt(at.off).link;
            if (link != 0) out.link_clicked = rt.doc.url(link);
        }
    } else if (rt.dragging and c.input.down) {
        var y = m.y;
        const bottom = f.view.y + f.view.h;
        if (m.y < f.view.y or m.y > bottom) {
            // Past the top or the bottom: the view scrolls toward the pointer.
            const d = if (m.y < f.view.y) m.y - f.view.y else m.y - bottom;
            const s = @max(0, f.scroll + std.math.clamp(d, -60, 60));
            c.scroll.put(c.gpa, rt.scroll_id, s) catch {};
            y = std.math.clamp(m.y, f.view.y, bottom - 1) + (s - f.scroll);
            c.animationFrame();
        }
        const at = layout.posAt(g, m.x - f.x(), y - f.y());
        const u = unitAt(rt, rt.drag_unit, at);
        const sel = if (at.order(rt.drag_from[0]) == .lt) [2]Pos{ rt.drag_from[1], u[0] } else [2]Pos{ rt.drag_from[0], u[1].max(rt.drag_from[1]) };
        if (!sel[0].eql(rt.sel.anchor) or !sel[1].eql(rt.sel.caret)) {
            const keep = rt.reveal;
            rt.select(sel[0], sel[1]);
            rt.reveal = keep;
            c.changed = true;
        }
    }
    if (!c.input.down) rt.dragging = false;
}

/// Keeps the caret in view.
fn reveal(c: *Context, rt: *RichText, g: Geo, f: Frame, caret_y: f32) void {
    const w = g.where(rt.sel.caret);
    const row_h = g.rowH(rt.doc.block(rt.sel.caret.block).style.kind);
    const top = caret_y + @as(f32, @floatFromInt(w.sub)) * row_h;
    var s = f.scroll;
    if (top < s) s = top;
    if (top + row_h + f.pad.vertical() > s + f.view.h) s = top + row_h + f.pad.vertical() - f.view.h;
    s = @max(0, s);
    if (s != f.scroll) c.scroll.put(c.gpa, rt.scroll_id, s) catch {};
}

/// Builds the editor of `rt` in a box of style `box` (sized by the caller).
pub fn view(c: *Context, rt: *RichText, box: types.Style, opts: Options) Result {
    const th = c.theme;
    var outer = box;
    outer.clip = true;
    outer.direction = .column;
    const oi = c.open(outer, null);
    defer c.end();
    const it = c.interact(oi, .{ .focusable = true });
    rt.id = it.id;
    rt.markdown_shortcuts = opts.markdown_shortcuts;
    if (it.hovered and c.hot == it.id) c.cursor_text = true;
    const scroll_id = c.peekId(null);
    rt.scroll_id = scroll_id;
    const pad = opts.padding;
    const view_rect = c.rects.get(scroll_id) orelse types.Rect{
        .w = if (box.width == .px) box.width.px else c.size.w,
        .h = if (box.height == .px) box.height.px else c.size.h,
    };
    var f: Frame = .{ .view = view_rect, .scroll = c.scroll.get(scroll_id) orelse 0, .pad = pad };
    var g: Geo = .{
        .ts = c.text,
        .arena = c.alloc(),
        .doc = &rt.doc,
        .size = opts.size,
        .width = @max(40, view_rect.w - pad.horizontal() - 6),
        .pal = .of(th),
        .page = @max(40, view_rect.h - 40),
    };
    g.measureRows();
    rt.sel = .{ .anchor = rt.doc.clamp(rt.sel.anchor), .caret = rt.doc.clamp(rt.sel.caret) };

    var result: Result = .{};
    const version = rt.version;
    const focused = it.focused;
    if (focused) {
        pointer(c, rt, g, f, it, opts, &result);
        const o = keys.handle(c, rt, g, .{ .read_only = opts.read_only, .clipboard = opts.clipboard });
        result.link_requested = o.link_requested;
    } else {
        rt.marked = null;
        rt.dragging = false;
    }
    result.changed = rt.version != version;

    // One pass over the blocks finds those in view and the caret; a
    // second only when keeping the caret in view scrolled.
    var sc = layout.scan(g, f.scroll - pad.top - overscan, rt.sel.caret.block);
    if (rt.reveal) {
        reveal(c, rt, g, f, sc.caret_y);
        rt.reveal = false;
        const s = c.scroll.get(scroll_id) orelse 0;
        if (s != f.scroll) {
            f.scroll = s;
            sc = layout.scan(g, f.scroll - pad.top - overscan, rt.sel.caret.block);
        }
    }

    const si = c.open(.{ .scroll = true, .width = .fill, .grow = 1 }, null);
    std.debug.assert(c.node(si).id == scroll_id);
    var total = sc.total;
    const max_scroll = @max(0, total + pad.vertical() - view_rect.h);
    if (f.scroll > max_scroll + 1) {
        f.scroll = max_scroll;
        c.scroll.put(c.gpa, scroll_id, max_scroll) catch {};
    }
    const ci = c.open(.{ .absolute = true, .width = .{ .px = view_rect.w }, .offset = .{ .x = pad.left, .y = pad.top } }, null);
    const end_y = f.scroll + view_rect.h + overscan;
    var y = sc.first_y;
    var i = sc.first;
    result.first_block = i;
    var caret_rect: ?types.Rect = null;
    if (rt.doc.count() == 1 and rt.doc.block(0).len() == 0 and opts.placeholder.len > 0) {
        const st = rt.doc.block(0).style;
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = g.indentX(st), .y = g.gapBefore(0) } }, .{ .text = .{ .str = opts.placeholder, .style = g.style(st.kind), .color = th.muted } }, null);
    }
    while (i < rt.doc.count() and y < end_y) : (i += 1) {
        const old_h = g.height(i);
        const gap = g.gapBefore(i);
        const top = y + gap;
        const l = g.lines(i);
        total += l.height() - old_h;
        drawBlock(c, rt, g, i, y, top, l, focused and !opts.read_only, .{ .x = f.x(), .y = f.y() }, &caret_rect);
        result.last_block = i;
        y = top + l.height();
    }
    rt.shown = .{ result.first_block, result.last_block };
    c.node(ci).style.height = .{ .px = total };
    c.end();
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = total + pad.vertical() } }, .none, "rich-extent");
    c.end();

    if (focused) {
        const b = rt.doc.block(rt.sel.caret.block);
        const rel = struct {
            fn in(p: Pos, bi: usize, n: usize) usize {
                if (p.block < bi) return 0;
                if (p.block > bi) return n;
                return @min(p.off, n);
            }
        }.in;
        const bi = rt.sel.caret.block;
        c.focused_text = .{
            .id = it.id,
            .text = c.alloc().dupe(u8, b.str()) catch "",
            .caret = rel(rt.sel.caret, bi, b.len()),
            .anchor = rel(rt.sel.anchor, bi, b.len()),
            .marked = if (rt.marked) |mk| .{ mk.a, mk.b } else null,
            .caret_rect = caret_rect orelse .{ .x = view_rect.x, .y = view_rect.y, .w = 1.5, .h = g.rowH(.paragraph) },
            .multiline = true,
        };
    }
    result.focused = focused;
    return result;
}

/// Block `i`: its decorations, the selection, its rows, the composition
/// and the caret. `y` is where its room above starts, `top` its text.
fn drawBlock(c: *Context, rt: *RichText, g: Geo, i: usize, y: f32, top: f32, l: layout.Lines, caret_on: bool, origin: types.Point, caret_rect: *?types.Rect) void {
    const th = c.theme;
    const b = rt.doc.block(i);
    const st = b.style;
    const h = l.height();
    const lv: f32 = @floatFromInt(st.indent);
    const base_x = lv * g.step();
    switch (st.kind) {
        .code => {
            const first = i == 0 or rt.doc.block(i - 1).style.kind != .code;
            const last = i + 1 == rt.doc.count() or rt.doc.block(i + 1).style.kind != .code;
            const y0 = if (first) top - layout.code_pad else top;
            const y1 = if (last) top + h + layout.code_pad else top + h;
            _ = c.leaf(.{ .absolute = true, .width = .{ .px = @max(1, g.width - base_x) }, .height = .{ .px = y1 - y0 }, .background = g.pal.block_bg, .offset = .{ .x = base_x, .y = y0 } }, .none, null);
        },
        .quote => {
            const y0 = if (i > 0 and rt.doc.block(i - 1).style.kind == .quote) y else top;
            _ = c.leaf(.{ .absolute = true, .width = .{ .px = 3 }, .height = .{ .px = top + h - y0 }, .background = g.pal.border, .offset = .{ .x = base_x + 1, .y = y0 } }, .none, null);
        },
        .bullet => {
            const d: f32 = @round(g.size * 0.36);
            const cx = l.x0 - g.step() * 0.55;
            const style: types.Style = .{ .absolute = true, .width = .{ .px = d }, .height = .{ .px = d }, .offset = .{ .x = cx - d / 2, .y = top + (l.row_h - d) / 2 } };
            var s = style;
            switch (st.indent % 3) {
                0 => {
                    s.radius = d / 2;
                    s.background = th.text;
                },
                1 => {
                    s.radius = d / 2;
                    s.border = th.text;
                    s.border_width = 1.2;
                },
                else => s.background = th.text,
            }
            _ = c.leaf(s, .none, null);
        },
        .numbered => {
            const label = layout.numberLabel(c.alloc(), layout.numberOf(&rt.doc, i), st.indent);
            const w = c.text.width(label, l.style);
            _ = c.leaf(.{ .absolute = true, .offset = .{ .x = l.x0 - w - g.size * 0.4, .y = top } }, .{ .text = .{ .str = label, .style = l.style, .color = th.muted } }, null);
        },
        .task => {
            const s: f32 = @round(g.size * 0.95);
            c.next_key_int = i;
            const box = c.leaf(.{
                .absolute = true,
                .width = .{ .px = s },
                .height = .{ .px = s },
                .radius = 3,
                .border = if (st.checked) th.accent else th.border.mix(th.text, 0.25),
                .background = if (st.checked) th.accent else null,
                .control = true,
                .offset = .{ .x = l.x0 - g.step() * 0.55 - s / 2, .y = top + (l.row_h - s) / 2 },
            }, .none, null);
            const cb = c.interact(box, .{});
            if (cb.pressed and c.input.pressed) c.focus = rt.id;
            if (cb.clicked) {
                rt.toggleChecked(i);
                c.changed = true;
            }
            if (st.checked) _ = c.leaf(.{ .absolute = true, .offset = .{ .x = l.x0 - g.step() * 0.55 - s * 0.32, .y = top + (l.row_h - s) / 2 - s * 0.08 } }, .{ .text = .{ .str = "✓", .style = .{ .size = s * 0.8, .weight = .bold }, .color = th.accent_text } }, null);
        },
        else => {},
    }

    const lo = rt.sel.lo();
    const hi = rt.sel.hi();
    const focused = c.focus == rt.id;
    const sel_color = th.accent.alpha(if (focused) 0.28 else 0.14);
    const space_w = c.text.width(" ", l.style);
    const rows = l.rows;
    for (0..l.count()) |sub| {
        const ry = top + @as(f32, @floatFromInt(sub)) * l.row_h;
        const r = rows.row(sub);
        // The selection, under the text.
        if (!rt.sel.empty() and lo.block <= i and hi.block >= i) {
            const a = @max(if (lo.block == i) lo.off else 0, r[0]);
            const e = @min(if (hi.block == i) hi.off else b.len(), r[1]);
            // A selection going on past the block takes its newline.
            const past_end = hi.block > i and sub + 1 == l.count();
            if (e > a or (past_end and a <= r[1])) {
                const xa = rows.xIn(sub, a);
                var xb = rows.xIn(sub, @max(a, e));
                if (past_end) xb += space_w;
                if (xb > xa) _ = c.leaf(.{ .absolute = true, .width = .{ .px = xb - xa }, .height = .{ .px = l.row_h }, .background = sel_color, .offset = .{ .x = l.x0 + xa, .y = ry } }, .none, null);
            }
        }
        if (r[1] > r[0]) {
            const lh = c.text.lineHeight(l.style);
            _ = c.leaf(.{ .absolute = true, .offset = .{ .x = l.x0, .y = ry + (l.row_h - lh) / 2 } }, .{ .text = .{
                .str = rows.str[r[0]..r[1]],
                .style = l.style,
                .color = if (st.kind == .quote) th.muted else th.text,
                .spans = rowSpans(c, l.spans, r[0], r[1]),
            } }, null);
        }
        if (focused) if (rt.marked) |mk| if (mk.block == i and mk.b > r[0] and mk.a < r[1]) {
            const xa = rows.xIn(sub, @max(mk.a, r[0]));
            const xb = rows.xIn(sub, @min(mk.b, r[1]));
            _ = c.leaf(.{ .absolute = true, .width = .{ .px = @max(1, xb - xa) }, .height = .{ .px = 1.5 }, .background = th.text, .offset = .{ .x = l.x0 + xa, .y = ry + l.row_h - 2 } }, .none, null);
        };
        const cp = rt.sel.caret;
        if (cp.block == i and rows.rowOf(cp.off) == sub) {
            const xc = l.x0 + rows.xIn(sub, cp.off);
            caret_rect.* = .{ .x = origin.x + xc, .y = origin.y + ry, .w = 1.5, .h = l.row_h };
            if (caret_on and focused and rt.sel.empty())
                _ = c.leaf(.{ .absolute = true, .width = .{ .px = 1.5 }, .height = .{ .px = l.row_h }, .background = th.accent, .offset = .{ .x = xc, .y = ry } }, .none, null);
        }
    }
}

/// The spans of a block clipped to its row [a, b), from the row's start.
fn rowSpans(c: *Context, spans: []const types.Span, a: usize, b: usize) []const types.Span {
    if (spans.len == 0) return &.{};
    var out: std.ArrayList(types.Span) = .empty;
    for (spans) |sp| {
        if (sp.end <= a or sp.start >= b) continue;
        var s = sp;
        s.start = @intCast(@max(sp.start, a) - a);
        s.end = @intCast(@min(sp.end, b) - a);
        out.append(c.alloc(), s) catch break;
    }
    return out.items;
}

/// The rich text editor with the look of a text area: a surface, a
/// border and corners, and a focus ring.
pub fn richTextEditor(c: *Context, rt: *RichText, opts: Options) Result {
    const th = c.theme;
    const focus_t = c.animate(rt.id, 0, if (rt.id != 0 and c.focus == rt.id) 1 else 0, 20);
    var box: types.Style = .{ .width = opts.width, .height = opts.height, .radius = 8 };
    if (!opts.bare) {
        box.background = th.surface;
        box.border = th.border.mix(th.accent, focus_t);
        box.border_width = 1 + focus_t;
    }
    return view(c, rt, box, opts);
}
