//! A terminal's frame in boxes of native UI: the rows of the render state
//! as runs of text of one style (the mono font, its colors, bold,
//! italic, faint), backgrounds merged along a row, underlines, lines
//! through and over, the selection, the cursor, and a scrollbar while the
//! scrollback shows. Every box is placed absolutely in the view's box.
const std = @import("std");
const ui = @import("myzig").ui;
const vt = @import("vt.zig");
const Theme = @import("theme.zig").Theme;

/// The geometry of the grid in the view's box, in points.
pub const Grid = struct {
    pad: f32,
    cell_w: f32,
    cell_h: f32,
    font_size: f32,
    /// The font's family, features and weight (`Options`).
    family: ?[]const u8 = null,
    features: []const u8 = "",
    weight: u16 = 0,
    cols: u16,
    rows: u16,
};

pub fn color(c: vt.Rgb) ui.Color {
    return .{ .r = @as(f32, @floatFromInt(c.r)) / 255, .g = @as(f32, @floatFromInt(c.g)) / 255, .b = @as(f32, @floatFromInt(c.b)) / 255 };
}

fn hexColor(v: u24) ui.Color {
    return .hex(v);
}

fn eqRgb(a: vt.Rgb, b: vt.Rgb) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b;
}

/// A style color in the frame's colors, or null for the default.
fn styleRgb(sc: vt.StyleColor, colors: *const vt.Colors) ?vt.Rgb {
    return switch (sc.tag) {
        vt.StyleColor.palette => colors.palette[sc.value[0]],
        vt.StyleColor.rgb => .{ .r = sc.value[0], .g = sc.value[1], .b = sc.value[2] },
        else => null,
    };
}

/// How a cell draws: its colors (the background null for the default)
/// and its text's look.
const Look = struct {
    fg: vt.Rgb,
    bg: ?vt.Rgb = null,
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    invisible: bool = false,
    underline: i32 = 0,
    underline_color: ?vt.Rgb = null,
    strike: bool = false,
    overline: bool = false,

    fn sameText(a: Look, b: Look) bool {
        return eqRgb(a.fg, b.fg) and a.bold == b.bold and a.italic == b.italic and a.faint == b.faint and a.invisible == b.invisible;
    }
};

fn look(r: *vt.Render, x: usize, cell: vt.Cell, colors: *const vt.Colors) Look {
    var l: Look = .{ .fg = colors.foreground };
    if (cell.style_id != 0) {
        const s = r.style(x);
        if (styleRgb(s.fg_color, colors)) |c| l.fg = c;
        l.bg = styleRgb(s.bg_color, colors);
        l.bold = s.bold;
        l.italic = s.italic;
        l.faint = s.faint;
        l.invisible = s.invisible;
        l.underline = s.underline;
        l.underline_color = styleRgb(s.underline_color, colors);
        l.strike = s.strikethrough;
        l.overline = s.overline;
        if (s.inverse) {
            const bg = l.bg orelse colors.background;
            l.bg = l.fg;
            l.fg = bg;
        }
    }
    if (cell.bg) |b| l.bg = if (cell.bg_palette) colors.palette[b.r] else b;
    return l;
}

fn rect(c: *ui.Context, x: f32, y: f32, w: f32, h: f32, col: ui.Color) void {
    _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = w }, .height = .{ .px = h }, .background = col }, .none, null);
}

fn border(c: *ui.Context, x: f32, y: f32, w: f32, h: f32, col: ui.Color) void {
    _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = w }, .height = .{ .px = h }, .border = col, .border_width = 1 }, .none, null);
}

fn textAt(c: *ui.Context, g: Grid, col: usize, row: usize, s: []const u8, l: Look) void {
    if (s.len == 0 or l.invisible) return;
    var fg = color(l.fg);
    if (l.faint) fg = fg.alpha(0.5);
    _ = c.leaf(.{
        .absolute = true,
        .offset = .{ .x = g.pad + @as(f32, @floatFromInt(col)) * g.cell_w, .y = g.pad + @as(f32, @floatFromInt(row)) * g.cell_h },
    }, .{ .text = .{
        .str = s,
        .style = .{
            .size = g.font_size,
            .mono = true,
            .weight = if (l.bold) .bold else .regular,
            // Bold is three hundred heavier than a weight of its own.
            .weight_value = if (g.weight == 0) 0 else if (l.bold) @min(900, g.weight + 300) else g.weight,
            .italic = l.italic,
            .family = g.family,
            .features = g.features,
        },
        .color = fg,
    } }, null);
}

/// What the cursor draws, which `draw` learns as it goes through the rows.
const CursorCell = struct { text: []const u8 = "", look: ?Look = null, wide: bool = false };

/// Draws the frame of `r` (updated from the terminal) in grid `g`.
/// `focused` draws a hollow cursor when false.
pub fn draw(c: *ui.Context, r: *vt.Render, g: Grid, theme: Theme, focused: bool, scrollbar: vt.Scrollbar) void {
    const arena = c.alloc();
    const colors = r.colors();
    const cur = r.cursor();
    const sel_bg: ui.Color = if (theme.selection) |s| hexColor(s) else color(colors.foreground).alpha(0.3);
    var cursor_cell: CursorCell = .{};
    var buf: std.ArrayList(u8) = .empty;
    var cps: [16]u32 = undefined;

    r.beginRows();
    var y: usize = 0;
    while (r.nextRow()) : (y += 1) {
        if (y >= g.rows) break;
        const raw = r.rowCells();
        const sel = r.rowSelection();
        const ry = g.pad + @as(f32, @floatFromInt(y)) * g.cell_h;
        // Backgrounds first, merged along the row.
        var bg_start: usize = 0;
        var bg_color: ?ui.Color = null;
        var looks = arena.alloc(Look, raw.len) catch return;
        var cells = arena.alloc(vt.Cell, raw.len) catch return;
        for (raw, 0..) |rc, x| {
            cells[x] = vt.decodeCell(rc);
            looks[x] = look(r, x, cells[x], &colors);
        }
        var x: usize = 0;
        while (x <= raw.len) : (x += 1) {
            const here: ?ui.Color = if (x == raw.len) null else blk: {
                if (sel) |s| if (x >= s[0] and x <= s[1]) break :blk sel_bg;
                break :blk if (looks[x].bg) |b| color(b) else null;
            };
            const same = if (here == null and bg_color == null) true else if (here != null and bg_color != null) std.meta.eql(here.?, bg_color.?) else false;
            if (!same) {
                if (bg_color) |bc| rect(c, g.pad + @as(f32, @floatFromInt(bg_start)) * g.cell_w, ry, @as(f32, @floatFromInt(x - bg_start)) * g.cell_w, g.cell_h, bc);
                bg_start = x;
                bg_color = here;
            }
        }
        // Then text: runs of one look, of narrow ASCII; others alone.
        var run_start: usize = 0;
        var run_look: ?Look = null;
        buf.clearRetainingCapacity();
        x = 0;
        while (x < raw.len) : (x += 1) {
            const cell = cells[x];
            var l = looks[x];
            if (sel) |s| if (x >= s[0] and x <= s[1]) if (theme.selection_text) |st| {
                l.fg = @import("theme.zig").rgb(st);
            };
            if (cell.wide == .spacer_tail or cell.wide == .spacer_head) continue;
            decorations(c, g, x, y, l, cell.wide == .wide);
            const ascii = cell.codepoint >= 0x20 and cell.codepoint < 0x7f and !cell.grapheme and cell.wide == .narrow;
            const empty = cell.codepoint == 0 or cell.codepoint == ' ';
            var one: []const u8 = "";
            if (!ascii and !empty) {
                var tmp: std.ArrayList(u8) = .empty;
                const gs = if (cell.grapheme) r.graphemes(x, &cps) else &[_]u32{cell.codepoint};
                for (gs) |cp| {
                    var e: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(cp), &e) catch continue;
                    tmp.appendSlice(arena, e[0..n]) catch {};
                }
                one = tmp.items;
            }
            if (cur.viewport_has_value and cur.viewport_y == y and cur.viewport_x == x) {
                cursor_cell = .{ .look = l, .wide = cell.wide == .wide, .text = if (ascii) (arena.dupe(u8, &.{@intCast(cell.codepoint)}) catch "") else one };
            }
            if (run_look) |rl| if (!(ascii or empty) or !rl.sameText(l)) {
                flush(c, g, run_start, y, &buf, rl, arena);
                run_look = null;
            };
            if (ascii or empty) {
                if (run_look == null) {
                    if (empty) continue;
                    run_start = x;
                    run_look = l;
                }
                buf.append(arena, if (empty) ' ' else @intCast(cell.codepoint)) catch {};
            } else textAt(c, g, x, y, one, l);
        }
        if (run_look) |rl| flush(c, g, run_start, y, &buf, rl, arena);
    }
    drawCursor(c, g, cur, colors, theme, focused, cursor_cell);
    if (scrollbar.total > scrollbar.len and scrollbar.len > 0) {
        const h = @as(f32, @floatFromInt(g.rows)) * g.cell_h;
        const total: f32 = @floatFromInt(scrollbar.total);
        const top = h * @as(f32, @floatFromInt(scrollbar.offset)) / total;
        const len = @max(h * @as(f32, @floatFromInt(scrollbar.len)) / total, 8);
        const w = g.pad + @as(f32, @floatFromInt(g.cols)) * g.cell_w;
        if (scrollbar.offset + scrollbar.len < scrollbar.total) rect(c, w - 4, g.pad + top, 3, len, color(colors.foreground).alpha(0.35));
    }
}

/// Draws a run of text and starts the next.
fn flush(c: *ui.Context, g: Grid, start: usize, row: usize, buf: *std.ArrayList(u8), l: Look, arena: std.mem.Allocator) void {
    const s = std.mem.trimEnd(u8, buf.items, " ");
    if (s.len > 0) textAt(c, g, start, row, arena.dupe(u8, s) catch return, l);
    buf.clearRetainingCapacity();
}

/// Underlines (single, double, curly, dotted and dashed drawn as one or
/// two lines), lines through and over a cell.
fn decorations(c: *ui.Context, g: Grid, x: usize, y: usize, l: Look, wide: bool) void {
    if (l.underline == 0 and !l.strike and !l.overline) return;
    const cx = g.pad + @as(f32, @floatFromInt(x)) * g.cell_w;
    const cy = g.pad + @as(f32, @floatFromInt(y)) * g.cell_h;
    const w = g.cell_w * @as(f32, if (wide) 2 else 1);
    const thick = @max(1, @round(g.font_size / 14));
    var fg = color(l.fg);
    if (l.faint) fg = fg.alpha(0.5);
    if (l.underline != 0) {
        const uc = if (l.underline_color) |u| color(u) else fg;
        const base = cy + g.cell_h - thick * 2;
        rect(c, cx, base, w, thick, uc);
        if (l.underline == 2) rect(c, cx, base - thick * 2, w, thick, uc);
    }
    if (l.strike) rect(c, cx, cy + g.cell_h / 2, w, thick, fg);
    if (l.overline) rect(c, cx, cy, w, thick, fg);
}

fn drawCursor(c: *ui.Context, g: Grid, cur: vt.Cursor, colors: vt.Colors, theme: Theme, focused: bool, cell: CursorCell) void {
    if (!cur.viewport_has_value or !cur.visible) return;
    if (cur.viewport_x >= g.cols or cur.viewport_y >= g.rows) return;
    const cc: ui.Color = if (colors.cursor_has_value) color(colors.cursor) else if (theme.cursor) |t| hexColor(t) else color(colors.foreground);
    const x = g.pad + @as(f32, @floatFromInt(cur.viewport_x)) * g.cell_w;
    const y = g.pad + @as(f32, @floatFromInt(cur.viewport_y)) * g.cell_h;
    const w = g.cell_w * @as(f32, if (cell.wide) 2 else 1);
    const style: vt.CursorStyle = if (!focused) .block_hollow else @enumFromInt(cur.visual_style);
    switch (style) {
        .bar => rect(c, x, y, @max(1, @round(g.font_size / 8)), g.cell_h, cc),
        .underline => rect(c, x, y + g.cell_h - 2, w, 2, cc),
        .block_hollow => border(c, x, y, w, g.cell_h, cc),
        .block => {
            rect(c, x, y, w, g.cell_h, cc);
            if (cell.look) |l| {
                var under = l;
                under.fg = if (theme.cursor_text) |t| @import("theme.zig").rgb(t) else colors.background;
                under.faint = false;
                textAt(c, g, cur.viewport_x, cur.viewport_y, cell.text, under);
            }
        },
    }
}
