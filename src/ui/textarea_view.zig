//! The view of a multi-line text: its rows in a scrolling box, built only
//! where in view (a text of a hundred thousand lines builds what a
//! screenful does), the selection, the caret and an input method's
//! composition, the pointer's presses and drags (a double click selects a
//! word, a triple click a line), long lines scrolled sideways, and an
//! optional gutter of line numbers. `ui.textArea` and `ui.codeEditor` are
//! built with it.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const TextArea = @import("textarea.zig").TextArea;
const keys = @import("textarea_keys.zig");
const layout = @import("textlayout.zig");
const Geo = layout.Geo;
const access = @import("access.zig");
const access_text = @import("access_text.zig");
const Color = types.Color;

/// A background behind bytes [start, end) of a line (a match, a bracket).
pub const Mark = struct { start: u32, end: u32, color: Color };

/// What a view adds to the lines it shows, as each is built.
pub const Decor = struct {
    ctx: *anyopaque,
    /// The colored runs of a line (syntax), in the frame's memory.
    spans: ?*const fn (ctx: *anyopaque, c: *Context, line: usize, str: []const u8) []const types.Span = null,
    /// Backgrounds of a line's runs; `start` is its byte in the text.
    marks: ?*const fn (ctx: *anyopaque, c: *Context, line: usize, start: usize, str: []const u8) []const Mark = null,
};

/// Sees each command first; true when it handled it.
pub const Hook = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, c: *Context, ta: *TextArea, g: Geo, cmd: keys.Cmd) bool,
};

pub const Gutter = struct {
    width: f32,
    color: Color,
    active: Color,
    background: Color,
};

pub const Config = struct {
    style: types.TextStyle,
    wrap: bool = true,
    read_only: bool = false,
    placeholder: []const u8 = "",
    padding: types.Edges = .xy(10, 7),
    gutter: ?Gutter = null,
    /// Fills the caret's row.
    current_line: ?Color = null,
    decor: ?Decor = null,
    hook: ?Hook = null,
    /// Tab is the text's (else it moves the focus).
    tab: bool = false,
    apply: keys.ApplyOptions = .{},
    /// Another part (a find bar) has the keyboard: no caret, no input.
    passive: bool = false,
};

pub const Result = struct {
    /// The text changed in this frame.
    changed: bool = false,
    focused: bool = false,
    /// The lines built, first and last.
    first_line: usize = 0,
    last_line: usize = 0,
};

const overscan = 3;

/// The text's origin on screen and what is in view, from the last layout.
const Frame = struct {
    view: types.Rect,
    scroll: f32,
    gutter_w: f32,
    pad: types.Edges,
    text_w: f32,

    fn originX(f: Frame, ta: *const TextArea) f32 {
        return f.view.x + f.gutter_w + f.pad.left - ta.scroll_x;
    }

    fn originY(f: Frame) f32 {
        return f.view.y + f.pad.top - f.scroll;
    }
};

/// The byte at the point (x, y) on screen.
fn offsetAt(ta: *TextArea, g: Geo, f: Frame, x: f32, y: f32) usize {
    const total = ta.wrap.totalRows(&ta.doc);
    const fy = (y - f.originY()) / g.row_h;
    if (fy < 0) return 0;
    const row: usize = @intFromFloat(@floor(fy));
    if (row >= total) return ta.len();
    const at = ta.wrap.lineAt(&ta.doc, row);
    const l = layout.lineRows(g, &ta.doc, at.line);
    const sub = @min(at.sub, l.rows.len - 1);
    return l.start + l.atX(sub, x - f.originX(ta));
}

fn pointer(c: *Context, ta: *TextArea, g: Geo, f: Frame, it: ctx_mod.Interaction) void {
    const m = c.input.mouse;
    if (c.input.pressed and c.hot == it.id) {
        const in_gutter = f.gutter_w > 0 and m.x < f.view.x + f.gutter_w;
        const at = offsetAt(ta, g, f, if (in_gutter) f.view.x + f.gutter_w else m.x, m.y);
        ta.drag_unit = if (in_gutter or c.input.click_count >= 3) .line else if (c.input.click_count == 2) .word else .char;
        ta.drag_from = unitAt(ta, ta.drag_unit, at);
        if (c.input.shift and ta.drag_unit == .char) {
            // Extends the selection from its anchor, dragging on from there.
            ta.drag_from = .{ ta.sel.anchor, ta.sel.anchor };
            ta.select(ta.sel.anchor, at);
        } else ta.select(ta.drag_from[0], ta.drag_from[1]);
        ta.marked = null;
        ta.dragging = true;
        c.selection.blocked = true;
        c.changed = true;
    } else if (ta.dragging and c.input.down) {
        // Past the top or the bottom: the view scrolls toward the pointer.
        var y = m.y;
        const bottom = f.view.y + f.view.h;
        if (m.y < f.view.y or m.y > bottom) {
            const d = if (m.y < f.view.y) m.y - f.view.y else m.y - bottom;
            const s = @max(0, f.scroll + std.math.clamp(d, -g.row_h * 3, g.row_h * 3));
            c.scroll.put(c.gpa, ta.scroll_id, s) catch {};
            y = std.math.clamp(m.y, f.view.y, bottom - 1) + (s - f.scroll);
            c.animationFrame();
        }
        const at = offsetAt(ta, g, f, m.x, y);
        const u = unitAt(ta, ta.drag_unit, at);
        const sel = if (at < ta.drag_from[0]) [2]usize{ ta.drag_from[1], u[0] } else [2]usize{ ta.drag_from[0], @max(u[1], ta.drag_from[1]) };
        if (sel[0] != ta.sel.anchor or sel[1] != ta.sel.caret) {
            const keep = ta.reveal;
            ta.select(sel[0], sel[1]);
            ta.reveal = keep;
            c.changed = true;
        }
    }
    if (!c.input.down) ta.dragging = false;
}

/// The run of `unit` at `at`: the byte itself, its word, or its line.
fn unitAt(ta: *const TextArea, unit: @import("textarea.zig").Unit, at: usize) [2]usize {
    return switch (unit) {
        .char => .{ at, at },
        .word => ta.wordAt(at),
        .line => ta.lineRange(ta.doc.lineOf(at)),
    };
}

/// Keeps the caret in view.
fn reveal(c: *Context, ta: *TextArea, g: Geo, f: Frame, caret_row: usize, caret_x: f32) void {
    const top = f.pad.top + @as(f32, @floatFromInt(caret_row)) * g.row_h;
    var s = f.scroll;
    if (top < s + f.pad.top) s = top - f.pad.top;
    if (top + g.row_h > s + f.view.h - f.pad.bottom) s = top + g.row_h - f.view.h + f.pad.bottom;
    s = @max(0, s);
    if (s != f.scroll) c.scroll.put(c.gpa, ta.scroll_id, s) catch {};
    if (g.wrap == 0 and f.text_w > 0) {
        const room = f.text_w - f.pad.horizontal();
        if (caret_x - ta.scroll_x > room - 2) ta.scroll_x = caret_x - room + 2;
        if (caret_x - ta.scroll_x < 0) ta.scroll_x = @max(0, caret_x - room / 3);
    }
}

/// Builds the view of `ta` in a box of style `box` (sized by the caller).
pub fn view(c: *Context, ta: *TextArea, box: types.Style, cfg: Config) Result {
    const th = c.theme;
    var outer = box;
    outer.clip = true;
    outer.direction = .column;
    const oi = c.open(outer, null);
    defer c.end();
    const it = c.interact(oi, .{ .focusable = true });
    ta.id = it.id;
    if (it.hovered and c.hot == it.id) c.cursor_text = true;
    const scroll_id = c.peekId(null);
    ta.scroll_id = scroll_id;

    const row_h = c.text.lineHeight(cfg.style);
    const gutter_w: f32 = if (cfg.gutter) |gt| gt.width else 0;
    const pad = cfg.padding;
    const view_rect = c.rects.get(scroll_id) orelse types.Rect{
        .w = if (box.width == .px) box.width.px else c.size.w,
        .h = if (box.height == .px) box.height.px else c.size.h,
    };
    const text_w = @max(1, view_rect.w - gutter_w);
    const wrap_w: f32 = if (cfg.wrap) @max(20, text_w - pad.horizontal() - 6) else 0;
    var f: Frame = .{ .view = view_rect, .scroll = c.scroll.get(scroll_id) orelse 0, .gutter_w = gutter_w, .pad = pad, .text_w = text_w };
    ta.long.beginFrame(ta.doc.gpa, c.frame);
    const g: Geo = .{
        .ts = c.text,
        .style = cfg.style,
        .wrap = wrap_w,
        .row_h = row_h,
        .page_rows = @intFromFloat(@max(1, @floor(view_rect.h / row_h) - 1)),
        .arena = c.alloc(),
        .long = &ta.long,
    };
    const char_w = c.text.width("0", cfg.style);
    ta.wrap.sync(ta.doc.gpa, &ta.doc, wrap_w, char_w);
    // Assistive technology moved the caret or the selection.
    if (access.selectRequest(c, it.id)) |sel| {
        ta.select(@min(sel[0], ta.len()), @min(sel[1], ta.len()));
        ta.marked = null;
    }
    ta.sel.caret = @min(ta.sel.caret, ta.len());
    ta.sel.anchor = @min(ta.sel.anchor, ta.len());
    // The rows in view, for assistive technology, from the box's top left.
    var rows: std.ArrayList(access.TextRow) = .empty;
    const box_at = it.rect orelse view_rect;

    var result: Result = .{};
    const version = ta.doc.version;
    const focused = it.focused and !cfg.passive;
    if (focused) {
        pointer(c, ta, g, f, it);
        const cmds = keys.collect(c, cfg.tab);
        for (cmds) |cmd| {
            if (cfg.hook) |h| if (h.run(h.ctx, c, ta, g, cmd)) {
                c.changed = true;
                continue;
            };
            var opts = cfg.apply;
            opts.read_only = cfg.read_only;
            _ = keys.apply(c, ta, g, cmd, opts);
        }
    } else if (!it.focused) {
        ta.marked = null;
        ta.dragging = false;
    }
    result.changed = ta.doc.version != version;

    const caret_pos = layout.posOf(g, &ta.doc, ta.sel.caret);
    const caret_row = ta.wrap.rowOf(&ta.doc, caret_pos.line) + caret_pos.sub;
    if (ta.reveal) {
        reveal(c, ta, g, f, caret_row, caret_pos.x);
        ta.reveal = false;
        f.scroll = c.scroll.get(scroll_id) orelse 0;
    }

    // The rows in view.
    const si = c.open(.{ .scroll = true, .width = .fill, .grow = 1 }, null);
    std.debug.assert(c.node(si).id == scroll_id);
    var total = ta.wrap.totalRows(&ta.doc);
    const max_scroll = @max(0, @as(f32, @floatFromInt(total)) * row_h + pad.vertical() - view_rect.h);
    if (f.scroll > max_scroll) {
        f.scroll = max_scroll;
        c.scroll.put(c.gpa, scroll_id, max_scroll) catch {};
    }
    const first_row = @as(usize, @intFromFloat(@max(0, @floor((f.scroll - pad.top) / row_h)))) -| overscan;
    const end_y = f.scroll + view_rect.h + row_h * overscan;
    const fill_line = if (cfg.current_line != null and focused and ta.sel.empty()) cfg.current_line else null;
    if (fill_line) |col| _ = c.leaf(.{
        .absolute = true,
        .width = .fill,
        .height = .{ .px = row_h },
        .background = col,
        .offset = .{ .y = pad.top + @as(f32, @floatFromInt(caret_row)) * row_h },
    }, .none, null);

    const ci = c.open(.{ .absolute = true, .width = .{ .px = text_w }, .clip = true, .offset = .{ .x = gutter_w } }, null);
    const x0 = pad.left - ta.scroll_x;
    const sel_color = th.accent.alpha(if (focused) 0.28 else 0.14);
    const space_w = c.text.width(" ", cfg.style);
    const Number = struct { line: usize, y: f32 };
    var numbers: std.ArrayList(Number) = .empty;
    const start = ta.wrap.lineAt(&ta.doc, first_row);
    var line = start.line;
    var row = ta.wrap.rowOf(&ta.doc, line);
    result.first_line = line;
    var caret_rect: ?types.Rect = null;
    var widest: f32 = 0;
    if (ta.doc.len() == 0 and cfg.placeholder.len > 0) {
        var ps = cfg.style;
        ps.wrap = cfg.wrap;
        _ = c.leaf(.{ .absolute = true, .width = .{ .px = @max(1, text_w - pad.horizontal()) }, .offset = .{ .x = pad.left, .y = pad.top } }, .{ .text = .{ .str = cfg.placeholder, .style = ps, .color = th.muted } }, null);
    }
    while (line < ta.doc.lineCount()) : (line += 1) {
        const y_line = pad.top + @as(f32, @floatFromInt(row)) * row_h;
        if (y_line > end_y) break;
        const lr = layout.lineRows(g, &ta.doc, line);
        if (cfg.wrap) ta.wrap.measured(&ta.doc, line, lr.rows.len);
        if (!cfg.wrap) widest = @max(widest, lr.lay.width + pad.horizontal() + 4);
        result.last_line = line;
        numbers.append(c.alloc(), .{ .line = line, .y = y_line }) catch {};
        const spans: []const types.Span = if (cfg.decor) |d| if (d.spans) |fs| fs(d.ctx, c, line, lr.str) else &.{} else &.{};
        const marks: []const Mark = if (cfg.decor) |d| if (d.marks) |fm| fm(d.ctx, c, line, lr.start, lr.str) else &.{} else &.{};
        for (0..lr.rows.len) |sub| {
            const y = y_line + @as(f32, @floatFromInt(sub)) * row_h;
            const r = lr.row(sub);
            const a_abs = lr.start + r[0];
            const b_abs = lr.start + r[1];
            if (y + row_h < f.scroll - row_h * overscan or y > end_y) continue;
            // The selection, and what the view marks, under the text.
            const lo = ta.sel.lo();
            const hi = ta.sel.hi();
            if (hi > lo and hi > a_abs and lo <= b_abs and !(lo == b_abs and sub + 1 < lr.rows.len)) {
                const a = @max(lo, a_abs) - lr.start;
                const b = @min(hi, b_abs) - lr.start;
                const xa = lr.xIn(sub, a);
                var xb = lr.xIn(sub, b);
                if (hi > b_abs and sub + 1 == lr.rows.len) xb += space_w;
                if (xb > xa) _ = c.leaf(.{ .absolute = true, .width = .{ .px = xb - xa }, .height = .{ .px = row_h }, .background = sel_color, .offset = .{ .x = x0 + xa, .y = y } }, .none, null);
            }
            for (marks) |mk| {
                const a = @max(mk.start, r[0]);
                const b = @min(mk.end, r[1]);
                if (b <= a and !(mk.start == mk.end and mk.start == r[0])) continue;
                const xa = lr.xIn(sub, a);
                const xb = @max(lr.xIn(sub, b), xa + 2);
                _ = c.leaf(.{ .absolute = true, .width = .{ .px = xb - xa }, .height = .{ .px = row_h }, .radius = 2, .background = mk.color, .offset = .{ .x = x0 + xa, .y = y } }, .none, null);
            }
            if (c.access.enabled) {
                const xs = access_text.rowXs(c.alloc(), lr.lay, r[0], r[1], layout.xAt(lr.lay, lr.rows[sub]));
                rows.append(c.alloc(), .{
                    .start = @intCast(a_abs),
                    .end = @intCast(b_abs),
                    .rect = .{ .x = view_rect.x - box_at.x + gutter_w + x0, .y = view_rect.y - box_at.y + y - f.scroll, .w = if (xs.len > 0) xs[xs.len - 1] else 0, .h = row_h },
                    .xs = xs,
                }) catch {};
            }
            if (r[1] > r[0]) {
                // Of a long row (a line that does not wrap), what shows.
                const v = if (r[1] - r[0] > 1024) shownBytes(lr, sub, r, ta.scroll_x - 64, ta.scroll_x + text_w + 64) else r;
                _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x0 + if (v[0] == r[0]) 0 else lr.xIn(sub, v[0]), .y = y } }, .{ .text = .{
                    .str = lr.str[v[0]..v[1]],
                    .style = cfg.style,
                    .color = th.text,
                    .spans = rowSpans(c, spans, v[0], v[1]),
                } }, null);
            }
            if (focused) if (ta.marked) |mk| if (mk[1] > a_abs and mk[0] < b_abs) {
                const xa = lr.xIn(sub, @max(mk[0], a_abs) - lr.start);
                const xb = lr.xIn(sub, @min(mk[1], b_abs) - lr.start);
                _ = c.leaf(.{ .absolute = true, .width = .{ .px = @max(1, xb - xa) }, .height = .{ .px = 1.5 }, .background = th.text, .offset = .{ .x = x0 + xa, .y = y + row_h - 2 } }, .none, null);
            };
            if (line == caret_pos.line and sub == caret_pos.sub) {
                const xc = x0 + caret_pos.x;
                caret_rect = .{ .x = view_rect.x + gutter_w + xc, .y = view_rect.y + y - f.scroll, .w = 1.5, .h = row_h };
                if (focused and !cfg.read_only and ta.sel.empty())
                    _ = c.leaf(.{ .absolute = true, .width = .{ .px = 1.5 }, .height = .{ .px = row_h }, .background = th.accent, .offset = .{ .x = xc, .y = y } }, .none, null);
            }
        }
        row += lr.rows.len;
    }
    // A long line in view is not laid out to its end: the next frame goes on.
    if (ta.long.pending) c.animationFrame();
    total = ta.wrap.totalRows(&ta.doc);
    const content_h = @as(f32, @floatFromInt(total)) * row_h + pad.vertical();
    c.node(ci).style.height = .{ .px = content_h };
    c.end();

    if (cfg.gutter) |gt| {
        _ = c.open(.{ .absolute = true, .width = .{ .px = gt.width }, .height = .{ .px = content_h }, .background = gt.background }, null);
        const ns: types.TextStyle = .{ .size = cfg.style.size * 0.92, .mono = true, .leading = cfg.style.leading };
        const nh = c.text.lineHeight(ns);
        for (numbers.items) |n| {
            const label = c.print("{d}", .{n.line + 1});
            const w = c.text.width(label, ns);
            _ = c.leaf(.{ .absolute = true, .offset = .{ .x = gt.width - w - 10, .y = n.y + (row_h - nh) / 2 } }, .{ .text = .{
                .str = label,
                .style = ns,
                .color = if (n.line == caret_pos.line) gt.active else gt.color,
            } }, null);
        }
        c.end();
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = content_h } }, .none, "text-extent");
    c.end();

    // Sideways, as far as the widest line in view goes.
    ta.content_w = widest;
    if (!cfg.wrap) horizontalBar(c, ta, f, view_rect);
    ta.scroll_x = std.math.clamp(ta.scroll_x, 0, @max(0, ta.content_w - text_w));

    if (focused) {
        const lstart = ta.doc.lineStart(caret_pos.line);
        const lend = ta.doc.lineEnd(caret_pos.line);
        const rel = struct {
            fn in(v: usize, a: usize, b: usize) usize {
                return @min(@max(v, a), b) - a;
            }
        }.in;
        c.focused_text = .{
            .id = it.id,
            .text = ta.doc.slice(c.alloc(), lstart, lend),
            .caret = rel(ta.sel.caret, lstart, lend),
            .anchor = rel(ta.sel.anchor, lstart, lend),
            .marked = if (ta.marked) |mk| .{ rel(mk[0], lstart, lend), rel(mk[1], lstart, lend) } else null,
            .caret_rect = caret_rect orelse .{ .x = view_rect.x, .y = view_rect.y, .w = 1.5, .h = row_h },
            .multiline = true,
        };
    }
    // A field of many lines to assistive technology: its whole text, its
    // selection, the rows in view; named by its label, not by its text.
    if (c.access.enabled) c.describe(it.id, .{
        .role = .text_field,
        .label = "",
        .value = ta.doc.slice(c.alloc(), 0, ta.len()),
        .placeholder = cfg.placeholder,
        .multiline = true,
        .read_only = cfg.read_only,
        .selection = .{ @intCast(ta.sel.anchor), @intCast(ta.sel.caret) },
        .rows = rows.items,
    });
    result.focused = it.focused;
    return result;
}

/// The bytes of row `sub` (bytes `r`) of `lr` whose glyphs lie between
/// `lo` and `hi` (in the row's coordinates), at the glyphs' boundaries.
fn shownBytes(lr: layout.LineRows, sub: usize, r: [2]usize, lo: f32, hi: f32) [2]usize {
    const gs = lr.lay.glyphs;
    const x0 = layout.xAt(lr.lay, r[0]);
    const first = struct {
        fn f(g: []const @import("text.zig").Glyph, x: f32) usize {
            var a: usize = 0;
            var b: usize = g.len;
            while (a < b) {
                const m = (a + b) / 2;
                if (g[m].x < x) a = m + 1 else b = m;
            }
            return a;
        }
    }.f;
    _ = sub;
    const i = first(gs, x0 + lo) -| 1;
    const j = first(gs, x0 + hi);
    const a = if (i < gs.len) std.math.clamp(gs[i].index, r[0], r[1]) else r[1];
    const b = if (j < gs.len) std.math.clamp(gs[j].index, a, r[1]) else r[1];
    return .{ a, b };
}

/// The spans of a line clipped to its row [a, b), from the row's start.
/// The spans are sorted: those of the row are a run of them, given as
/// they are where the row starts the line and holds them whole (a line
/// that does not wrap), else clipped in one allocation of frame memory.
fn rowSpans(c: *Context, spans: []const types.Span, a: usize, b: usize) []const types.Span {
    return clipSpans(c.alloc(), spans, a, b);
}

fn clipSpans(arena: std.mem.Allocator, spans: []const types.Span, a: usize, b: usize) []const types.Span {
    var i: usize = 0;
    while (i < spans.len and spans[i].end <= a) i += 1;
    var j = i;
    while (j < spans.len and spans[j].start < b) j += 1;
    const run = spans[i..j];
    if (run.len == 0) return &.{};
    var whole = a == 0;
    for (run) |sp| whole = whole and sp.end <= b and sp.end > sp.start;
    if (whole) return run;
    const out = arena.alloc(types.Span, run.len) catch return &.{};
    var n: usize = 0;
    for (run) |sp| {
        if (sp.end <= a or sp.start >= b) continue;
        var s = sp;
        s.start = @intCast(@max(sp.start, a) - a);
        s.end = @intCast(@min(sp.end, b) - a);
        out[n] = s;
        n += 1;
    }
    return out[0..n];
}

test "a row's spans: the line's own where it does not wrap, clipped where it does" {
    const spans = [_]types.Span{ .{ .start = 0, .end = 3 }, .{ .start = 4, .end = 9 }, .{ .start = 12, .end = 14 } };
    // A row of the whole line allocates nothing.
    var none: std.heap.FixedBufferAllocator = .init(&.{});
    const all = clipSpans(none.allocator(), &spans, 0, 14);
    try std.testing.expectEqual(@as([*]const types.Span, &spans), all.ptr);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    // A row from byte 5: the second clipped, the third moved.
    var buf: [256]u8 = undefined;
    var fb: std.heap.FixedBufferAllocator = .init(&buf);
    const rest = clipSpans(fb.allocator(), &spans, 5, 14);
    try std.testing.expectEqual(@as(usize, 2), rest.len);
    try std.testing.expectEqual(@as(u32, 0), rest[0].start);
    try std.testing.expectEqual(@as(u32, 4), rest[0].end);
    try std.testing.expectEqual(@as(u32, 7), rest[1].start);
}

/// The bar of a text wider than its view, dragged to scroll it sideways.
fn horizontalBar(c: *Context, ta: *TextArea, f: Frame, view_rect: types.Rect) void {
    const room = f.text_w;
    if (ta.content_w <= room + 0.5) {
        ta.thumb_grab = null;
        return;
    }
    const thumb_w = @max(24, room * room / ta.content_w);
    const span = @max(1, room - thumb_w);
    const t = std.math.clamp(ta.scroll_x / (ta.content_w - room), 0, 1);
    const i = c.leaf(.{
        .absolute = true,
        .width = .{ .px = thumb_w },
        .height = .{ .px = 6 },
        .radius = 3,
        .background = c.theme.muted.alpha(0.45),
        .offset = .{ .x = f.gutter_w + span * t, .y = @max(0, view_rect.h - 8) },
    }, .none, "hbar");
    const it = c.interact(i, .{});
    if (it.pressed) {
        if (ta.thumb_grab) |gx| {
            ta.scroll_x = std.math.clamp(ta.scroll_x + (c.input.mouse.x - gx) * (ta.content_w - room) / span, 0, ta.content_w - room);
            c.changed = c.changed or c.input.mouse.x != gx;
        }
        ta.thumb_grab = c.input.mouse.x;
    } else ta.thumb_grab = null;
}

pub const Options = struct {
    width: types.Length = .fill,
    height: types.Length = .{ .px = 140 },
    /// Grows with its text from `lines[0]` rows to `lines[1]`, past which
    /// it scrolls, as a message field does (in place of `height`).
    lines: ?[2]u16 = null,
    size: f32 = 14,
    mono: bool = false,
    wrap: bool = true,
    placeholder: []const u8 = "",
    /// Selectable and copyable, not editable.
    read_only: bool = false,
    /// Tab types a tab, rather than moving the focus.
    tab: bool = false,
    /// No box of its own (border, fill, focus ring).
    bare: bool = false,
};

/// A multi-line text field editing `ta`: wrapped (or scrolled sideways),
/// with the platform's keys, the pointer, the clipboard, undo and input
/// methods.
pub fn textArea(c: *Context, ta: *TextArea, opts: Options) Result {
    const th = c.theme;
    const style: types.TextStyle = .{ .size = opts.size, .mono = opts.mono, .leading = 1.2 };
    const pad: types.Edges = if (opts.bare) .xy(2, 2) else .xy(10, 7);
    var height = opts.height;
    if (opts.lines) |ln| {
        const rows = std.math.clamp(ta.wrap.totalRows(&ta.doc), ln[0], @max(ln[0], ln[1]));
        height = .{ .px = @as(f32, @floatFromInt(rows)) * c.text.lineHeight(style) + pad.vertical() + 2 };
    }
    const focus_t = c.animate(ta.id, 0, if (ta.id != 0 and c.focus == ta.id) 1 else 0, 20);
    var box: types.Style = .{ .width = opts.width, .height = height, .radius = 8 };
    if (!opts.bare) {
        box.background = th.surface;
        box.border = th.border.mix(th.accent, focus_t);
        box.border_width = 1 + focus_t;
        if (focus_t > 0.01) box.shadow = .{ .color = th.accent.alpha(0.25 * focus_t), .blur = 6, .y = 0 };
    }
    return view(c, ta, box, .{
        .style = style,
        .wrap = opts.wrap,
        .read_only = opts.read_only,
        .placeholder = opts.placeholder,
        .padding = pad,
        .tab = opts.tab,
    });
}
