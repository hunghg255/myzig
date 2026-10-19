//! Where the rich text editor's blocks go: each block's style of text,
//! its runs as spans, its rows wrapped at the width left by its indent,
//! the room between blocks, and positions to rows and x and back. Heights
//! of blocks laid out are kept on them; others are estimated from their
//! length, so that a view finds the blocks in view without laying out
//! those above them.
const std = @import("std");
const types = @import("../types.zig");
const text = @import("../text.zig");
const tl = @import("../textlayout.zig");
const Theme = @import("../theme.zig").Theme;
const model = @import("model.zig");
const Doc = model.Doc;
const Pos = model.Pos;
const Kind = model.Kind;
const Color = types.Color;
const Span = types.Span;
const TextStyle = types.TextStyle;

pub const Palette = struct {
    text: Color,
    muted: Color,
    link: Color,
    code: Color,
    code_bg: Color,
    block_bg: Color,
    accent: Color,
    border: Color,

    pub fn of(t: Theme) Palette {
        return .{
            .text = t.text,
            .muted = t.muted,
            .link = t.accent,
            .code = if (t.dark) Color.hex(0xe6a8a8) else Color.hex(0xb3304c),
            .code_bg = t.text.alpha(0.07),
            .block_bg = if (t.dark) Color.hex(0x232326) else Color.hex(0xf0f0f3),
            .accent = t.accent,
            .border = t.border,
        };
    }
};

/// Room around a block of code, inside its background.
pub const code_pad: f32 = 8;

/// What laying out blocks takes, for one frame.
pub const Geo = struct {
    ts: *text.TextSystem,
    arena: std.mem.Allocator,
    doc: *Doc,
    /// The body's font size.
    size: f32,
    /// The width of the content.
    width: f32,
    pal: Palette,
    /// How far Page Up and Page Down move.
    page: f32 = 300,
    /// The height of a row of each kind of block (`measureRows`).
    row_hs: [kinds]f32 = @splat(0),

    const kinds = std.enums.values(Kind).len;

    /// Measures the rows of each kind once, for the frame's passes over
    /// every block.
    pub fn measureRows(g: *Geo) void {
        for (std.enums.values(Kind), 0..) |k, i| g.row_hs[i] = @ceil(g.ts.lineHeight(g.style(k)));
    }

    pub fn style(g: Geo, kind: Kind) TextStyle {
        return switch (kind) {
            .heading1 => .{ .size = g.size * 1.75, .weight = .bold, .leading = 1.2 },
            .heading2 => .{ .size = g.size * 1.4, .weight = .bold, .leading = 1.2 },
            .heading3 => .{ .size = g.size * 1.18, .weight = .semibold, .leading = 1.2 },
            .code => .{ .size = g.size * 0.9, .mono = true, .leading = 1.35 },
            else => .{ .size = g.size, .leading = 1.4 },
        };
    }

    pub fn rowH(g: Geo, kind: Kind) f32 {
        const h = g.row_hs[@backingInt(kind)];
        return if (h > 0) h else @ceil(g.ts.lineHeight(g.style(kind)));
    }

    /// One level of a list's (or a paragraph's) indent.
    pub fn step(g: Geo) f32 {
        return @round(g.size * 1.6);
    }

    /// Where a block's text starts, from the content's left.
    pub fn indentX(g: Geo, st: model.BlockStyle) f32 {
        const lv: f32 = @floatFromInt(st.indent);
        return switch (st.kind) {
            .bullet, .numbered, .task => (lv + 1) * g.step(),
            .quote => lv * g.step() + @round(g.size * 0.9),
            .code => lv * g.step() + code_pad + 2,
            else => lv * g.step(),
        };
    }

    pub fn wrapW(g: Geo, st: model.BlockStyle) f32 {
        const right: f32 = if (st.kind == .code) code_pad + 2 else 0;
        return @max(20, g.width - g.indentX(st) - right);
    }

    /// The room above block `i`, after the one before it.
    pub fn gapBefore(g: Geo, i: usize) f32 {
        if (i == 0) return if (g.doc.block(0).style.kind == .code) code_pad else 0;
        const prev = g.doc.block(i - 1).style.kind;
        const cur = g.doc.block(i).style.kind;
        var gap: f32 = @round(g.size * 0.45);
        if (prev.isList() and cur.isList()) gap = @round(g.size * 0.2);
        if (prev == .quote and cur == .quote) gap = 0;
        if (prev == .code and cur == .code) return 0;
        if (cur.isHeading()) gap = @round(g.size * (if (cur == .heading1) @as(f32, 1.1) else 0.8));
        if (cur == .code) gap += code_pad;
        if (prev == .code) gap += code_pad;
        return gap;
    }

    /// The room below the last block.
    pub fn gapAfter(g: Geo) f32 {
        return if (g.doc.block(g.doc.count() - 1).style.kind == .code) code_pad else 0;
    }

    /// Block `i`'s rows' height: as laid out last at this width, or
    /// estimated from its length.
    pub fn height(g: Geo, i: usize) f32 {
        const b = g.doc.block(i);
        const w = g.wrapW(b.style);
        if (b.h_w == w) return b.h;
        const st = g.style(b.style.kind);
        const per_row = @max(1, w / (st.size * 0.52));
        const rows = @max(1, @ceil(@as(f32, @floatFromInt(b.len())) / per_row));
        return rows * g.rowH(b.style.kind);
    }

    /// Block `i`'s runs as spans: marks drawn their own way.
    pub fn spans(g: Geo, i: usize) []const Span {
        const b = g.doc.block(i);
        const checked = b.style.kind == .task and b.style.checked;
        var out: std.ArrayList(Span) = .empty;
        var pos: u32 = 0;
        for (b.runs.items) |r| {
            defer pos += r.len;
            const m = r.marks;
            const sp: Span = .{
                .start = pos,
                .end = pos + r.len,
                .color = if (checked) g.pal.muted else if (m.link != 0) g.pal.link else if (m.code) g.pal.code else m.color,
                .weight = if (m.bold) .bold else null,
                .italic = m.italic,
                .mono = m.code and b.style.kind != .code,
                .background = m.highlight orelse if (m.code and b.style.kind != .code) g.pal.code_bg else null,
                .underline = m.underline or m.link != 0,
                .strike = m.strike or checked,
            };
            if (std.meta.eql(sp, Span{ .start = sp.start, .end = sp.end })) continue;
            out.append(g.arena, sp) catch break;
        }
        return out.items;
    }

    /// Block `i` laid out; its height is kept on it.
    pub fn lines(g: Geo, i: usize) Lines {
        const b = g.doc.block(i);
        const st = g.style(b.style.kind);
        const sp = g.spans(i);
        const str = b.str();
        const lay = if (text.rich.styled(sp)) text.rich.layout(g.ts, str, st, sp, 0) else g.ts.layout(str, st);
        const w = g.wrapW(b.style);
        var rows = tl.breakRows(g.arena, lay, str, w);
        if (rows.len == 0) {
            rows = g.arena.alloc(u32, 1) catch unreachable;
            rows[0] = 0;
        }
        const row_h = g.rowH(b.style.kind);
        b.h = @as(f32, @floatFromInt(rows.len)) * row_h;
        b.h_w = w;
        return .{
            .rows = .{ .start = 0, .str = str, .lay = lay, .rows = rows },
            .style = st,
            .spans = sp,
            .row_h = row_h,
            .x0 = g.indentX(b.style),
        };
    }

    /// Where `p` is drawn: its row in its block, and its x in the content.
    pub fn where(g: Geo, p: Pos) struct { sub: usize, x: f32 } {
        const l = g.lines(p.block);
        const sub = l.rows.rowOf(p.off);
        return .{ .sub = sub, .x = l.x0 + l.rows.xIn(sub, p.off) };
    }

    /// The position nearest content x `x` in row `sub` of block `i`.
    pub fn atRow(g: Geo, i: usize, sub: usize, x: f32) Pos {
        const l = g.lines(i);
        const s = @min(sub, l.rows.rows.len - 1);
        return .{ .block = i, .off = l.rows.atX(s, x - l.x0) };
    }
};

pub const Lines = struct {
    rows: tl.LineRows,
    style: TextStyle,
    spans: []const Span,
    row_h: f32,
    /// Where the text starts, from the content's left.
    x0: f32,

    pub fn count(l: Lines) usize {
        return l.rows.rows.len;
    }

    pub fn height(l: Lines) f32 {
        return @as(f32, @floatFromInt(l.count())) * l.row_h;
    }
};

/// What a pass over the blocks finds: the first one reaching `from`
/// (y in the content), where it starts, and the content's height.
pub const Scan = struct { first: usize, first_y: f32, total: f32, caret_y: f32 };

pub fn scan(g: Geo, from: f32, caret_block: usize) Scan {
    var r: Scan = .{ .first = g.doc.count() - 1, .first_y = 0, .total = 0, .caret_y = 0 };
    var found = false;
    var y: f32 = 0;
    for (0..g.doc.count()) |i| {
        const top = y;
        y += g.gapBefore(i);
        if (i == caret_block) r.caret_y = y;
        y += g.height(i);
        if (!found and y >= from) {
            found = true;
            r.first = i;
            r.first_y = top;
        }
    }
    if (!found) r.first_y = y - g.height(r.first) - g.gapBefore(r.first);
    r.total = y + g.gapAfter();
    return r;
}

/// The block at content y `y` and the y its text starts at.
pub fn blockAt(g: Geo, y: f32) struct { block: usize, top: f32 } {
    var at: f32 = 0;
    for (0..g.doc.count()) |i| {
        const top = at + g.gapBefore(i);
        at = top + g.height(i);
        if (y < at or i + 1 == g.doc.count()) return .{ .block = i, .top = top };
    }
    return .{ .block = 0, .top = 0 };
}

/// The position at content point (x, y).
pub fn posAt(g: Geo, x: f32, y: f32) Pos {
    if (y < 0) return .{};
    const hit = blockAt(g, y);
    const l = g.lines(hit.block);
    const fy = (y - hit.top) / l.row_h;
    if (fy >= @as(f32, @floatFromInt(l.count()))) {
        if (hit.block + 1 == g.doc.count()) return g.doc.end();
    }
    const sub: usize = if (fy < 0) 0 else @min(l.count() - 1, @as(usize, @intFromFloat(@floor(fy))));
    return .{ .block = hit.block, .off = l.rows.atX(sub, x - l.x0) };
}

/// The y of block `i`'s text in the content.
pub fn topOf(g: Geo, i: usize) f32 {
    var y: f32 = 0;
    for (0..i + 1) |k| {
        y += g.gapBefore(k);
        if (k < i) y += g.height(k);
    }
    return y;
}

/// Numbers of a numbered list: 1, 2, 3 at the first level, a, b, c at
/// the second, i, ii, iii at the third, and around again.
pub fn numberOf(doc: *const Doc, i: usize) u32 {
    const lv = doc.block(i).style.indent;
    var n: u32 = 1;
    var k = i;
    while (k > 0) {
        k -= 1;
        const st = doc.block(k).style;
        if (!st.kind.isList() or st.indent < lv) break;
        if (st.indent > lv) continue;
        if (st.kind != .numbered) break;
        n += 1;
    }
    return n;
}

pub fn numberLabel(arena: std.mem.Allocator, n: u32, indent: u8) []const u8 {
    return switch (indent % 3) {
        0 => std.fmt.allocPrint(arena, "{d}.", .{n}) catch "",
        1 => blk: {
            var buf: [8]u8 = undefined;
            var len: usize = 0;
            var v = n;
            while (v > 0 and len < buf.len) : (v = (v - 1) / 26) {
                buf[len] = @intCast('a' + (v - 1) % 26);
                len += 1;
            }
            std.mem.reverse(u8, buf[0..len]);
            break :blk std.fmt.allocPrint(arena, "{s}.", .{buf[0..len]}) catch "";
        },
        else => blk: {
            const vals = [_]u32{ 1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1 };
            const syms = [_][]const u8{ "m", "cm", "d", "cd", "c", "xc", "l", "xl", "x", "ix", "v", "iv", "i" };
            var out: std.ArrayList(u8) = .empty;
            var v = n;
            for (vals, syms) |val, sym| while (v >= val) : (v -= val) out.appendSlice(arena, sym) catch {};
            out.append(arena, '.') catch {};
            break :blk out.items;
        },
    };
}

test "numbers of nested lists" {
    const gpa = std.testing.allocator;
    var d = Doc.init(gpa);
    defer d.deinit();
    d.block(0).setStyle(.{ .kind = .numbered });
    d.append(.{ .kind = .numbered, .indent = 1 }, "", .{});
    d.append(.{ .kind = .numbered, .indent = 1 }, "", .{});
    d.append(.{ .kind = .numbered }, "", .{});
    try std.testing.expectEqual(@as(u32, 1), numberOf(&d, 0));
    try std.testing.expectEqual(@as(u32, 2), numberOf(&d, 2));
    try std.testing.expectEqual(@as(u32, 2), numberOf(&d, 3));
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try std.testing.expectEqualStrings("b.", numberLabel(arena.allocator(), 2, 1));
    try std.testing.expectEqualStrings("iv.", numberLabel(arena.allocator(), 4, 2));
    try std.testing.expectEqualStrings("aa.", numberLabel(arena.allocator(), 27, 1));
}
