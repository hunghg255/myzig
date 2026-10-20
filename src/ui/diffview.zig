//! The diff viewer of native UI, after mygo's `editor.DiffView`: the
//! changes between two texts, unified (the deleted lines over the added
//! ones) or split (side by side, lines aligned), with each side's numbers,
//! syntax colors, the words that changed within a changed line marked,
//! and the unchanged lines between changes collapsed into a row that a
//! click expands. Only the rows in view are built.
//!
//!     var d = try ui.DiffView.init(gpa, before, after, "main.zig");
//!     defer d.deinit();
//!     // In the view:
//!     ui.diffView(c, &d, .{});
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const widgets = @import("widgets.zig");
const list = @import("list.zig");
const diff = @import("diff.zig");
const row_text = @import("textarea_rows.zig");
const hl = @import("markdown/highlight.zig");
const model = @import("diffview_model.zig");
const DiffView = model.DiffView;
const Kind = model.Kind;
const Color = types.Color;

pub const Options = struct {
    width: types.Length = .fill,
    height: types.Length = .fill,
    size: f32 = 13,
    /// Changed lines less alike than this aren't marked word by word.
    min_same: f32 = 0.3,
    /// The tokens' colors; the light or dark default when null.
    colors: ?hl.Colors = null,
    /// The digits of the line numbers' column (0: as many as the texts need).
    digits: usize = 0,
    /// The text's family (the theme's monospaced one when null), OpenType
    /// features and weight, as `ui.TextStyle` takes them.
    family: ?[]const u8 = null,
    features: []const u8 = "",
    weight_value: u16 = 0,
};

const Palette = struct {
    added: Color,
    added_word: Color,
    deleted: Color,
    deleted_word: Color,
    gap: Color,
    number: Color,

    fn of(th: @import("theme.zig").Theme) Palette {
        return .{
            .added = th.success.alpha(if (th.dark) 0.16 else 0.12),
            .added_word = th.success.alpha(if (th.dark) 0.38 else 0.32),
            .deleted = th.danger.alpha(if (th.dark) 0.16 else 0.1),
            .deleted_word = th.danger.alpha(if (th.dark) 0.38 else 0.28),
            .gap = th.accent.alpha(0.08),
            .number = th.muted.alpha(0.8),
        };
    }
};

const Ctx = struct {
    c: *Context,
    dv: *DiffView,
    style: types.TextStyle,
    num_w: f32,
    row_h: f32,
    pal: Palette,
    opts: Options,
    /// Of a line wrapped at `cols` characters, the piece shown (0: none wrap).
    part: usize = 0,
    cols: usize = 0,
};

/// Bytes of piece `part` of `str` wrapped at `cols` characters.
fn piece(str: []const u8, part: usize, cols: usize) [2]usize {
    if (cols == 0) return .{ 0, str.len };
    var i: usize = 0;
    var n: usize = 0;
    var start: usize = str.len;
    while (i < str.len) : (n += 1) {
        if (n == part * cols) start = i;
        if (n == (part + 1) * cols) return .{ @min(start, i), i };
        i += std.unicode.utf8ByteSequenceLength(str[i]) catch 1;
    }
    return .{ @min(start, str.len), str.len };
}

/// The pieces a row of `dv` takes wrapped at `cols` characters a side.
pub fn rowParts(dv: *const DiffView, i: usize, cols: usize) usize {
    const r = dv.rows.items[i];
    if (cols == 0 or (r.kind == .gap and r.hidden > 0)) return 1;
    var most: usize = 1;
    if (r.old) |o| most = @max(most, (count(dv.old_lines[o]) + cols - 1) / cols);
    if (r.new) |n| most = @max(most, (count(dv.new_lines[n]) + cols - 1) / cols);
    return most;
}

fn count(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// How many characters a side has room for in a diff `width` wide.
pub fn wrapColumns(c: *Context, dv: *DiffView, opts: Options, width: f32, split: bool) usize {
    const x = context(c, dv, opts);
    const side = (if (split) (width - 1) / 2 else width) - x.num_w * (if (split) @as(f32, 1) else 2) - 14 - 8;
    const cw = c.text.width("0", x.style);
    if (cw <= 0) return 0;
    return @max(@as(usize, @intFromFloat(@max(side, 0) / cw)), 8);
}

fn backgroundOf(p: Palette, k: Kind) ?Color {
    return switch (k) {
        .added => p.added,
        .deleted => p.deleted,
        .gap, .empty => p.gap,
        .same => null,
    };
}

/// A line's number, right-aligned in its column.
fn number(x: *const Ctx, line: ?u32) void {
    const c = x.c;
    const ns: types.TextStyle = .{ .size = x.style.size * 0.9, .mono = true };
    _ = c.open(.{ .direction = .row, .width = .{ .px = x.num_w }, .height = .fill, .justify = .end, .align_items = .center, .padding = .xy(6, 0) }, null);
    if (line) |l| _ = c.leaf(.{}, .{ .text = .{ .str = c.print("{d}", .{l + 1}), .style = ns, .color = x.pal.number } }, null);
    c.end();
}

/// The text of a line, colored, with the words that changed marked.
fn lineText(x: *const Ctx, old_side: bool, line: u32, pair: ?u32, kind: Kind) void {
    const c = x.c;
    const dv = x.dv;
    const full = if (old_side) dv.old_lines[line] else dv.new_lines[line];
    const pc = piece(full, x.part, x.cols);
    const str = full[pc[0]..pc[1]];
    const shift = if (pc[0] > 0) c.text.caretX(full, x.style, pc[0]) else 0;
    _ = c.open(.{ .grow = 1, .height = .fill, .clip = true, .align_items = .center, .direction = .row, .padding = .{ .left = 4 } }, null);
    defer c.end();
    if (pair) |p| {
        const other = if (old_side) dv.new_lines[p] else dv.old_lines[p];
        const a = if (old_side) str else other;
        const b = if (old_side) other else str;
        const w = diff.words(c.alloc(), a, b) catch null;
        if (w) |ws| if (ws.same >= x.opts.min_same) {
            const color = if (kind == .added) x.pal.added_word else x.pal.deleted_word;
            for (if (old_side) ws.a else ws.b) |r| {
                if (r.end <= pc[0] or r.start >= pc[1]) continue;
                const x0 = c.text.caretX(full, x.style, @max(r.start, pc[0])) - shift;
                const x1 = c.text.caretX(full, x.style, @min(r.end, pc[1])) - shift;
                if (x1 > x0) _ = c.leaf(.{ .absolute = true, .width = .{ .px = x1 - x0 }, .height = .{ .px = x.row_h - 4 }, .radius = 3, .background = color, .offset = .{ .x = 4 + x0, .y = 2 } }, .none, null);
            }
        };
    }
    var spans: []const types.Span = &.{};
    if (dv.language) |lang| {
        var out: std.ArrayList(types.Span) = .empty;
        const st = if (old_side) dv.old_states[line] else dv.new_states[line];
        _ = hl.line(c.alloc(), lang, full, st, 0, x.opts.colors orelse hl.Colors.of(c.theme.dark), &out);
        for (out.items) |*sp| sp.italic = false;
        spans = if (pc[0] == 0 and pc[1] == full.len) out.items else row_text.clipSpans(c.alloc(), out.items, pc[0], pc[1]);
    }
    if (str.len > 0) _ = c.leaf(.{}, .{ .text = .{ .str = str, .style = x.style, .color = c.theme.text, .spans = spans } }, null);
}

fn sign(x: *const Ctx, kind: Kind) void {
    const s: []const u8 = switch (kind) {
        .added => "+",
        .deleted => "-",
        else => " ",
    };
    _ = x.c.open(.{ .width = .{ .px = 14 }, .height = .fill, .justify = .center, .align_items = .center }, null);
    _ = x.c.leaf(.{}, .{ .text = .{ .str = s, .style = x.style, .color = x.pal.number } }, null);
    x.c.end();
}

fn gapRow(x: *const Ctx, r: model.Row) void {
    const c = x.c;
    const it = widgets.pressable(c, .{ .direction = .row, .width = .fill, .height = .{ .px = x.row_h }, .align_items = .center, .padding = .xy(12, 0), .gap = 8, .background = x.pal.gap }, c.theme.accent.alpha(0.16));
    defer c.end();
    _ = c.leaf(.{}, .{ .text = .{
        .str = c.print("⋯ {d} unchanged line{s}", .{ r.hidden, if (r.hidden == 1) "" else "s" }),
        .style = .{ .size = x.style.size * 0.9 },
        .color = c.theme.muted,
    } }, null);
    if (it.clicked) {
        x.dv.expand(r.run);
        c.changed = true;
    }
}

fn unifiedRow(x: *const Ctx, r: model.Row) void {
    const c = x.c;
    _ = c.open(.{ .direction = .row, .width = .fill, .height = .{ .px = x.row_h }, .background = backgroundOf(x.pal, r.kind) }, null);
    defer c.end();
    number(x, if (x.part == 0) r.old else null);
    number(x, if (x.part == 0) r.new else null);
    sign(x, if (x.part == 0) r.kind else .same);
    if (r.kind == .deleted) lineText(x, true, r.old.?, r.pair, r.kind) else lineText(x, false, r.new.?, r.pair, r.kind);
}

fn splitRow(x: *const Ctx, r: model.Row) void {
    const c = x.c;
    _ = c.open(.{ .direction = .row, .width = .fill, .height = .{ .px = x.row_h } }, null);
    defer c.end();
    const paired = r.old != null and r.new != null and r.kind == .deleted and r.new_kind == .added;
    inline for (.{ true, false }) |old_side| {
        const kind = if (old_side) r.kind else r.new_kind;
        const line = if (old_side) r.old else r.new;
        _ = c.open(.{ .direction = .row, .grow = 1, .width = .{ .px = 0 }, .height = .fill, .background = backgroundOf(x.pal, kind), .clip = true }, null);
        number(x, if (x.part == 0) line else null);
        sign(x, if (x.part == 0) kind else .same);
        if (line) |l| lineText(x, old_side, l, if (paired) (if (old_side) r.new else r.old) else null, kind);
        c.end();
        if (old_side) _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = c.theme.border }, .none, null);
    }
}

/// The height of a diff's rows.
pub fn rowHeight(c: *Context, opts: Options) f32 {
    return c.text.lineHeight(.{ .size = opts.size, .mono = true, .leading = 1.4, .family = opts.family, .weight_value = opts.weight_value });
}

fn context(c: *Context, dv: *DiffView, opts: Options) Ctx {
    const style: types.TextStyle = .{ .size = opts.size, .mono = true, .leading = 1.4, .family = opts.family, .features = opts.features, .weight_value = opts.weight_value };
    var digits: usize = 1;
    var n = @max(dv.old_lines.len, dv.new_lines.len);
    while (n >= 10) : (n /= 10) digits += 1;
    if (opts.digits > 0) digits = opts.digits;
    return .{
        .c = c,
        .dv = dv,
        .style = style,
        .num_w = @as(f32, @floatFromInt(@max(digits, 2))) * c.text.width("0", .{ .size = opts.size * 0.9, .mono = true }) + 14,
        .row_h = rowHeight(c, opts),
        .pal = .of(c.theme),
        .opts = opts,
    };
}

/// Row `i` of a diff (after `dv.build()`), for a list of the app's own
/// that shows several diffs, or rows between them: a row `rowHeight` tall.
pub fn diffRow(c: *Context, dv: *DiffView, i: usize, opts: Options) void {
    diffRowPart(c, dv, i, opts, 0, 0);
}

/// Piece `part` of row `i`, its lines wrapped at `cols` characters a side
/// (`wrapColumns`; `rowParts` tells how many pieces it takes): the
/// numbers and the sign on the first.
pub fn diffRowPart(c: *Context, dv: *DiffView, i: usize, opts: Options, part: usize, cols: usize) void {
    var x = context(c, dv, opts);
    x.part = part;
    x.cols = cols;
    const r = dv.rows.items[i];
    if (r.kind == .gap and r.hidden > 0) gapRow(&x, r) else switch (dv.mode) {
        .unified => unifiedRow(&x, r),
        .split => splitRow(&x, r),
    }
}

/// The diff of `dv`: give it a size, or let it fill its parent.
pub fn diffView(c: *Context, dv: *DiffView, opts: Options) void {
    dv.build();
    const th = c.theme;
    const x = context(c, dv, opts);
    const row_h = x.row_h;
    _ = c.open(.{ .direction = .column, .width = opts.width, .height = opts.height, .background = if (th.dark) Color.hex(0x1e1f22) else Color.white, .clip = true }, null);
    defer c.end();
    const to: ?f32 = if (dv.scroll_to) |r| @as(f32, @floatFromInt(r)) * row_h else null;
    dv.scroll_to = null;
    var rows = list.list(c, .{ .count = dv.rows.items.len, .row_height = row_h, .scroll_to = to });
    while (rows.next()) |i| {
        const r = dv.rows.items[i];
        if (r.kind == .gap and r.hidden > 0) gapRow(&x, r) else switch (dv.mode) {
            .unified => unifiedRow(&x, r),
            .split => splitRow(&x, r),
        }
    }
    rows.end();
}

test piece {
    try std.testing.expectEqual([2]usize{ 0, 3 }, piece("abcdefg", 0, 3));
    try std.testing.expectEqual([2]usize{ 6, 7 }, piece("abcdefg", 2, 3));
    try std.testing.expectEqual([2]usize{ 0, 7 }, piece("abcdefg", 0, 0));
}
