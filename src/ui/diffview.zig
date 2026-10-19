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
};

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
    const str = if (old_side) dv.old_lines[line] else dv.new_lines[line];
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
                const x0 = c.text.caretX(str, x.style, r.start);
                const x1 = c.text.caretX(str, x.style, r.end);
                if (x1 > x0) _ = c.leaf(.{ .absolute = true, .width = .{ .px = x1 - x0 }, .height = .{ .px = x.row_h - 4 }, .radius = 3, .background = color, .offset = .{ .x = 4 + x0, .y = 2 } }, .none, null);
            }
        };
    }
    var spans: []const types.Span = &.{};
    if (dv.language) |lang| {
        var out: std.ArrayList(types.Span) = .empty;
        const st = if (old_side) dv.old_states[line] else dv.new_states[line];
        _ = hl.line(c.alloc(), lang, str, st, 0, hl.Colors.of(c.theme.dark), &out);
        for (out.items) |*sp| sp.italic = false;
        spans = out.items;
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
    number(x, r.old);
    number(x, r.new);
    sign(x, r.kind);
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
        number(x, line);
        sign(x, kind);
        if (line) |l| lineText(x, old_side, l, if (paired) (if (old_side) r.new else r.old) else null, kind);
        c.end();
        if (old_side) _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = c.theme.border }, .none, null);
    }
}

/// The diff of `dv`: give it a size, or let it fill its parent.
pub fn diffView(c: *Context, dv: *DiffView, opts: Options) void {
    dv.build();
    const th = c.theme;
    const style: types.TextStyle = .{ .size = opts.size, .mono = true, .leading = 1.4 };
    const row_h = c.text.lineHeight(style);
    var digits: usize = 1;
    var n = @max(dv.old_lines.len, dv.new_lines.len);
    while (n >= 10) : (n /= 10) digits += 1;
    const x: Ctx = .{
        .c = c,
        .dv = dv,
        .style = style,
        .num_w = @as(f32, @floatFromInt(@max(digits, 2))) * c.text.width("0", .{ .size = opts.size * 0.9, .mono = true }) + 14,
        .row_h = row_h,
        .pal = .of(th),
        .opts = opts,
    };
    _ = c.open(.{ .direction = .column, .width = opts.width, .height = opts.height, .background = if (th.dark) Color.hex(0x1e1f22) else Color.white, .clip = true }, null);
    defer c.end();
    var rows = list.list(c, .{ .count = dv.rows.items.len, .row_height = row_h });
    while (rows.next()) |i| {
        const r = dv.rows.items[i];
        if (r.kind == .gap and r.hidden > 0) gapRow(&x, r) else switch (dv.mode) {
            .unified => unifiedRow(&x, r),
            .split => splitRow(&x, r),
        }
    }
    rows.end();
}
