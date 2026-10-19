//! How a grid (`grid.zig`) sizes its tracks and places its children in
//! them, for `layout.zig`: fixed tracks at their size, fitting ones as
//! large as what they hold (spanning children spread what they lack over
//! the fitting tracks they span), shares (`fr`) of the room left, or of
//! their content where the grid's size is not set.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const grid = @import("grid.zig");
const layout = @import("layout.zig");
const Context = ctx_mod.Context;
const none = ctx_mod.none;
const Track = grid.Track;
const Placed = grid.Placed;
const max = grid.max_tracks;

/// Track sizes along both axes, and how far down in its row each item
/// lined up by its baseline goes (`lift`, by child, or none).
const Solved = struct {
    cols: [max]f32 = @splat(0),
    rows: [max]f32 = @splat(0),
    n_cols: usize = 0,
    n_rows: usize = 0,
    lift: []f32 = &.{},

    fn span(sizes: []const f32, start: usize, n: usize, gap: f32) f32 {
        var s: f32 = 0;
        for (sizes[start..@min(sizes.len, start + n)]) |v| s += v;
        return s + gap * @as(f32, @floatFromInt(n -| 1));
    }

    fn total(sizes: []const f32, gap: f32) f32 {
        return span(sizes, 0, sizes.len, gap);
    }
};

/// The content size of grid `index` given `avail_w` points of width (its
/// children measured on the way).
pub fn measure(c: *Context, index: u32, spec: *const grid.Spec, avail_w: f32) types.Size {
    var s: Solved = .{};
    solve(c, index, spec, avail_w, null, &s);
    return .{
        .w = Solved.total(s.cols[0..s.n_cols], spec.gap_x),
        .h = Solved.total(s.rows[0..s.n_rows], spec.gap_y),
    };
}

/// Places the children of grid `index` in its content box `inner`;
/// `fixed_h`: its height is set, which rows of `fr` share.
pub fn arrange(c: *Context, index: u32, spec: *const grid.Spec, inner: types.Rect, fixed_h: bool) void {
    var s: Solved = .{};
    solve(c, index, spec, inner.w, if (fixed_h) inner.h else null, &s);
    var xs: [max + 1]f32 = undefined;
    var ys: [max + 1]f32 = undefined;
    xs[0] = 0;
    for (0..s.n_cols) |i| xs[i + 1] = xs[i] + s.cols[i] + spec.gap_x;
    ys[0] = 0;
    for (0..s.n_rows) |i| ys[i + 1] = ys[i] + s.rows[i] + spec.gap_y;
    const cells = spec.cells();
    var child = c.node(index).first_child;
    var k: usize = 0;
    while (child != none) : ({
        child = c.node(child).next;
        k += 1;
    }) {
        const ch = c.node(child);
        if (ch.style.absolute or k >= cells.len) {
            const w = if (ch.style.width == .fill) inner.w else ch.measured.w;
            const h = if (ch.style.height == .fill) inner.h else ch.measured.h;
            layout.arrangeBox(c, child, .{ .x = inner.x, .y = inner.y, .w = w, .h = h });
            continue;
        }
        const p = cells[k];
        const col = @min(p.col, s.n_cols - 1);
        const row = @min(p.row, s.n_rows - 1);
        const cw = Solved.span(s.cols[0..s.n_cols], col, p.col_span, spec.gap_x);
        const rh = Solved.span(s.rows[0..s.n_rows], row, p.row_span, spec.gap_y);
        const w = sizeIn(p.justify, ch.style.width, ch.measured.w, cw);
        const h = sizeIn(p.@"align", ch.style.height, ch.measured.h, rh);
        const lift: ?f32 = if (k < s.lift.len and s.lift[k] >= 0) s.lift[k] else null;
        layout.arrangeBox(c, child, .{
            .x = inner.x + xs[col] + offsetIn(p.justify, w, cw),
            .y = inner.y + ys[row] + (lift orelse offsetIn(p.@"align", h, rh)),
            .w = w,
            .h = h,
        });
    }
}

fn sizeIn(a: grid.Align, len: types.Length, measured: f32, room: f32) f32 {
    return switch (len) {
        .px => |v| v,
        .fill => room,
        .auto => if (a == .stretch) room else @min(measured, room),
    };
}

fn offsetIn(a: grid.Align, size: f32, room: f32) f32 {
    return switch (a) {
        .stretch, .start, .baseline => 0,
        .center => @max(0, room - size) / 2,
        .end => @max(0, room - size),
    };
}

/// Whether sizing the columns reads what child `p` asks of them: of one
/// spanning a fitting column, or a share of a grid whose width is not
/// known. The others (in fixed columns, or shares of a known width, as
/// CSS's minmax(0, 1fr)) are measured only at the width their cell gives.
fn contributes(spec: *const grid.Spec, p: Placed, n_cols: usize, finite_w: bool) bool {
    const start = @min(p.col, n_cols - 1);
    for (start..@min(n_cols, start + p.col_span)) |i| switch (spec.column(i)) {
        .fit => return true,
        .fr => if (!finite_w) return true,
        .px => {},
    };
    return false;
}

fn solve(c: *Context, index: u32, spec: *const grid.Spec, avail_w: f32, avail_h: ?f32, s: *Solved) void {
    s.n_cols = @min(max, spec.n_cols);
    s.n_rows = @min(max, @max(1, spec.n_rows));
    const cells = spec.cells();
    const finite_w = std.math.isFinite(avail_w);

    // Each child the columns read as wide as it would be.
    var child = c.node(index).first_child;
    var k: usize = 0;
    while (child != none) : ({
        child = c.node(child).next;
        k += 1;
    }) {
        const out = c.node(child).style.absolute or k >= cells.len;
        if (out or contributes(spec, cells[k], s.n_cols, finite_w)) _ = layout.measure(c, child, avail_w);
    }

    // Columns.
    var tracks: [max]Track = undefined;
    for (0..s.n_cols) |i| tracks[i] = spec.column(i);
    sizeAxis(c, index, cells, tracks[0..s.n_cols], s.cols[0..s.n_cols], spec.gap_x, if (finite_w) avail_w else null, .col, &.{});

    // Each child measured at the width its cell gives: the others, and
    // wrapping text again, for its height.
    var baselines = false;
    child = c.node(index).first_child;
    k = 0;
    while (child != none) : ({
        child = c.node(child).next;
        k += 1;
    }) {
        const ch = c.node(child);
        if (ch.style.absolute or k >= cells.len) continue;
        const p = cells[k];
        const col = @min(p.col, s.n_cols - 1);
        const cw = Solved.span(s.cols[0..s.n_cols], col, p.col_span, spec.gap_x);
        if (!contributes(spec, p, s.n_cols, finite_w)) _ = layout.measure(c, child, cw);
        baselines = baselines or (p.@"align" == .baseline and p.row_span == 1);
        const m = c.node(child);
        if (!m.flexible) continue;
        const w = sizeIn(p.justify, m.style.width, m.measured.w, cw);
        if (@abs(w - m.measured.w) > 0.5) _ = layout.measure(c, child, w);
    }
    if (baselines) s.lift = lifts(c, index, cells, s.n_rows);

    // Rows.
    for (0..s.n_rows) |i| tracks[i] = spec.row(i);
    sizeAxis(c, index, cells, tracks[0..s.n_rows], s.rows[0..s.n_rows], spec.gap_y, avail_h, .row, s.lift);
}

/// How far down in its row each item lined up by its baseline goes, so
/// that the baselines of a row's items meet (-1 for the others): the row
/// is as high as the highest baseline above and the deepest below take.
fn lifts(c: *Context, index: u32, cells: []const Placed, n_rows: usize) []f32 {
    const out = c.alloc().alloc(f32, cells.len) catch return &.{};
    @memset(out, -1);
    var line: [max]f32 = @splat(0);
    var pass: usize = 0;
    while (pass < 2) : (pass += 1) {
        var child = c.node(index).first_child;
        var k: usize = 0;
        while (child != none and k < cells.len) : ({
            child = c.node(child).next;
            k += 1;
        }) {
            const p = cells[k];
            if (c.node(child).style.absolute or p.@"align" != .baseline or p.row_span != 1) continue;
            const row = @min(p.row, n_rows - 1);
            const b = @import("layout_baseline.zig").of(c, child, false) orelse c.node(child).measured.h;
            if (pass == 0) line[row] = @max(line[row], b) else out[k] = line[row] - b;
        }
    }
    return out;
}

const Axis = enum { col, row };

fn startOf(p: Placed, axis: Axis) usize {
    return if (axis == .col) p.col else p.row;
}

fn spanOf(p: Placed, axis: Axis) usize {
    return if (axis == .col) p.col_span else p.row_span;
}

fn sizeOf(c: *Context, child: u32, axis: Axis) f32 {
    const m = c.node(child).measured;
    return if (axis == .col) m.w else m.h;
}

/// Sizes `tracks` from the children's measured sizes, sharing `avail`
/// (null: unknown) among the `fr` ones.
fn sizeAxis(c: *Context, index: u32, cells: []const Placed, tracks: []const Track, sizes: []f32, gap: f32, avail: ?f32, axis: Axis, lift: []const f32) void {
    const n = tracks.len;
    if (n == 0) return;
    for (tracks, sizes) |t, *v| v.* = switch (t) {
        .px => |p| p,
        else => 0,
    };
    var fr_sum: f32 = 0;
    for (tracks) |t| if (t == .fr) {
        fr_sum += t.fr;
    };

    // What one child asks of the fitting track it is in; then what those
    // spanning several lack, spread over the fitting tracks they span.
    var unit: f32 = 0; // points per share, from content, without room
    for (0..2) |pass| {
        var child = c.node(index).first_child;
        var k: usize = 0;
        while (child != none) : ({
            child = c.node(child).next;
            k += 1;
        }) {
            if (c.node(child).style.absolute or k >= cells.len) continue;
            const p = cells[k];
            const start = @min(startOf(p, axis), n - 1);
            const span = @min(spanOf(p, axis), n - start);
            const want = sizeOf(c, child, axis) + (if (k < lift.len) @max(0, lift[k]) else 0);
            const ts = tracks[start .. start + span];
            if (pass == 0) {
                if (span != 1) continue;
                switch (ts[0]) {
                    .fit => sizes[start] = @max(sizes[start], want),
                    .fr => |f| if (f > 0) {
                        unit = @max(unit, want / f);
                    },
                    .px => {},
                }
                continue;
            }
            if (span == 1) continue;
            var fits: f32 = 0;
            var frs: f32 = 0;
            for (ts) |t| switch (t) {
                .fit => fits += 1,
                .fr => |f| frs += f,
                .px => {},
            };
            const have = Solved.span(sizes, start, span, gap);
            if (want <= have) continue;
            if (frs > 0) {
                // Shares grow with the content where there is no room.
                var fixed: f32 = 0;
                for (ts, start..) |t, i| if (t != .fr) {
                    fixed += sizes[i];
                };
                const room = want - fixed - gap * @as(f32, @floatFromInt(span - 1));
                unit = @max(unit, room / frs);
            } else if (fits > 0) {
                for (ts, start..) |t, i| if (t == .fit) {
                    sizes[i] += (want - have) / fits;
                };
            }
        }
    }

    if (fr_sum == 0) return;
    var used: f32 = gap * @as(f32, @floatFromInt(n - 1));
    for (tracks, sizes) |t, v| if (t != .fr) {
        used += v;
    };
    const per = if (avail) |a| @max(0, a - used) / fr_sum else unit;
    for (tracks, sizes) |t, *v| if (t == .fr) {
        v.* = per * t.fr;
    };
}
