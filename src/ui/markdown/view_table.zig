//! Tables: a grid of cells whose columns are as wide as their widest
//! text, up to `Options.max_column_width` (wider text wraps), aligned as
//! the delimiter row says, the header row shaded and bold, rows striped.
const types = @import("../types.zig");
const text_mod = @import("../text.zig");
const view = @import("view.zig");

fn cellStyle(v: *const view.V, header: bool, wrap: bool) types.TextStyle {
    var st = v.body();
    st.leading = 1.3;
    st.wrap = wrap;
    if (header) st.weight = .semibold;
    return st;
}

/// The width of a cell's text on one line.
fn natural(v: *view.V, cell: u32, header: bool) f32 {
    const r = v.rendered(cell);
    const st = cellStyle(v, header, false);
    const w = if (text_mod.rich.styled(r.spans)) text_mod.rich.layout(v.c.text, r.text, st, r.spans, 0).width else v.c.text.width(r.text, st);
    return @ceil(w);
}

pub fn block(v: *view.V, i: u32) void {
    const c = v.c;
    const d = v.d;
    const aligns = d.alignments(i);
    const columns = @min(aligns.len, 64);
    var widths: [64]f32 = @splat(0);
    var rows = d.children(i);
    while (rows.next()) |r| {
        var cells = d.children(r);
        var k: usize = 0;
        while (cells.next()) |cell| : (k += 1) if (k < columns) {
            widths[k] = @max(widths[k], natural(v, cell, d.block(r).header));
        };
    }
    const pad_x = v.em * 0.6;
    const pad_y = v.em * 0.35;
    _ = c.open(.{ .border = v.pal.border, .radius = 6, .clip = true }, null);
    defer c.end();
    rows = d.children(i);
    var row_i: usize = 0;
    while (rows.next()) |r| : (row_i += 1) {
        const header = d.block(r).header;
        if (row_i > 0) _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = v.pal.border }, .none, null);
        c.next_key_int = d.block(r).start;
        const bg = if (header) v.pal.header_bg else if (row_i % 2 == 0) v.pal.stripe_bg else null;
        _ = c.open(.{ .direction = .row, .background = bg }, null);
        var cells = d.children(r);
        var k: usize = 0;
        while (cells.next()) |cell| : (k += 1) {
            if (k >= columns) break;
            const wrap = widths[k] > v.opts.max_column_width;
            const w = @min(widths[k], v.opts.max_column_width) + 2 * pad_x;
            const al: types.Align = switch (aligns[k]) {
                .none, .left => .start,
                .center => .center,
                .right => .end,
            };
            _ = c.open(.{ .width = .{ .px = w }, .padding = .xy(pad_x, pad_y), .align_items = al }, null);
            const st = cellStyle(v, header, wrap);
            const rd = v.rendered(cell);
            const idx = v.textLeaf(rd.text, rd.spans, st, v.fg);
            if (rd.links.len > 0) v.links(idx, rd, st);
            c.end();
        }
        c.end();
    }
}
