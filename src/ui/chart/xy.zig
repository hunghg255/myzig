//! Line, area and bar charts: series of values along labeled points,
//! a value axis with round ticks and grid lines, a legend, and the point
//! nearest the pointer marked and told in a tooltip.
//!
//!     const r = ui.chart.lineChart(c, &.{
//!         .{ .name = "Revenue", .values = s.revenue },
//!         .{ .name = "Costs", .values = s.costs },
//!     }, .{ .labels = s.months, .height = 200, .curve = .monotone });
//!     if (r.hover) |h| s.month = h.index;
const std = @import("std");
const types = @import("../types.zig");
const ctx_mod = @import("../context.zig");
const canvas = @import("../canvas.zig");
const scale = @import("scale.zig");
const shape = @import("shape.zig");
const plot = @import("plot.zig");
const Context = ctx_mod.Context;
const Color = types.Color;
const Series = plot.Series;
const Options = plot.Options;
const Result = plot.Result;

const Kind = enum { line, area, bar };

pub fn lineChart(c: *Context, series: []const Series, opts: Options) Result {
    return xyChart(c, .line, series, opts);
}

pub fn areaChart(c: *Context, series: []const Series, opts: Options) Result {
    return xyChart(c, .area, series, opts);
}

/// Bars side by side in each band, or piled up when `stacked`.
pub fn barChart(c: *Context, series: []const Series, opts: Options) Result {
    return xyChart(c, .bar, series, opts);
}

/// What the plot's canvas draws.
const Drawing = struct {
    kind: Kind,
    series: []const Series,
    opts: Options,
    n: usize,
    xs: []const f32,
    y: scale.Linear,
    band: scale.Band,
    stacks: ?[][]shape.Segment,
    ticks: []const scale.Tick,
    grid: Color,
    zero: f32,

    fn colorOf(d: *const Drawing, s: usize) Color {
        return plot.colorOf(d.series[s].color, s);
    }

    /// Where the s-th series' i-th value is (its stack's top when stacked).
    fn top(d: *const Drawing, s: usize, i: usize) f32 {
        if (d.stacks) |st| return d.y.at(st[s][i].hi);
        const v = d.series[s].values;
        if (i >= v.len or std.math.isNan(v[i])) return std.math.nan(f32);
        return d.y.at(v[i]);
    }

    fn bottom(d: *const Drawing, s: usize, i: usize) f32 {
        if (d.stacks) |st| return d.y.at(st[s][i].lo);
        return d.zero;
    }

    /// The s-th series' bar in the i-th band, along x.
    fn bar(d: *const Drawing, s: usize, i: usize) scale.Span {
        const b = d.band.band(i);
        if (d.stacks != null or d.series.len <= 1) return b;
        const inner = scale.Band.init(d.series.len).padding(0.08, 0);
        const sb = inner.band(s);
        return .{ .lo = b.lo + sb.lo * (b.hi - b.lo), .hi = b.lo + sb.hi * (b.hi - b.lo) };
    }

    fn draw(d: *const Drawing, p: *canvas.Painter) void {
        const r: types.Rect = .{ .w = p.size.w, .h = p.size.h };
        if (d.opts.grid) plot.grid(p, d.ticks, d.grid);
        const arena = p.arena;
        for (d.series, 0..) |_, s| {
            const color = d.colorOf(s);
            switch (d.kind) {
                .bar => for (0..d.n) |i| {
                    const t = d.top(s, i);
                    if (std.math.isNan(t)) continue;
                    const lo = d.bottom(s, i);
                    const xs = d.bar(s, i);
                    const y0 = shape.y(r, @max(t, lo));
                    const y1 = shape.y(r, @min(t, lo));
                    const rect: types.Rect = .{ .x = shape.x(r, xs.lo), .y = y0, .w = (xs.hi - xs.lo) * r.w, .h = y1 - y0 };
                    p.fillRoundRect(rect, @min(3, rect.w / 4), .color(color));
                },
                .line, .area => {
                    const tops = arena.alloc(f32, d.n) catch @panic("OOM");
                    for (tops, 0..) |*t, i| t.* = d.top(s, i);
                    if (d.kind == .area) {
                        const lows = arena.alloc(f32, d.n) catch @panic("OOM");
                        for (lows, 0..) |*l, i| l.* = d.bottom(s, i);
                        var a = p.path();
                        shape.area(&a, r, d.xs, lows, tops, d.opts.curve);
                        p.fill(&a, .color(color.alpha(if (d.stacks != null) 0.55 else 0.22)));
                    }
                    var l = p.path();
                    shape.line(&l, r, d.xs, tops, d.opts.curve);
                    p.stroke(&l, .color(color), .{ .width = d.opts.line_width, .join = .round, .cap = .round });
                    if (d.opts.points) for (tops, 0..) |t, i| {
                        if (!std.math.isNan(t)) p.fillCircle(shape.x(r, d.xs[i]), shape.y(r, t), d.opts.line_width + 1.5, .color(color));
                    };
                },
            }
        }
    }
};

fn xyChart(c: *Context, kind: Kind, series: []const Series, opts: Options) Result {
    const arena = c.alloc();
    var n: usize = opts.labels.len;
    for (series) |s| n = @max(n, s.values.len);
    // The value axis: the data's extent (from 0 for bars and areas), or the stacks'.
    const stacked = opts.stacked and kind != .line;
    var stacks: ?[][]shape.Segment = null;
    var lo = std.math.inf(f64);
    var hi = -std.math.inf(f64);
    if (stacked) {
        const vals = arena.alloc([]const f64, series.len) catch @panic("OOM");
        for (vals, series) |*v, s| v.* = s.values;
        stacks = shape.stack(arena, vals, .standard) catch @panic("OOM");
        for (stacks.?) |st| for (st) |seg| {
            lo = @min(lo, seg.lo);
            hi = @max(hi, seg.hi);
        };
    } else for (series) |s| {
        const e = scale.extent(s.values);
        lo = @min(lo, e[0]);
        hi = @max(hi, e[1]);
    }
    if (lo > hi) {
        lo = 0;
        hi = 1;
    }
    if (kind != .line) {
        lo = @min(lo, 0);
        hi = @max(hi, 0);
    }
    if (lo == hi) hi = lo + 1;
    var y = scale.Linear.init(opts.min orelse lo, opts.max orelse hi);
    if (opts.min == null or opts.max == null) {
        const nice = y.nice(opts.ticks);
        if (opts.min == null) y.lo = nice.lo;
        if (opts.max == null) y.hi = nice.hi;
    }
    const ticks = y.ticks(arena, opts.ticks) catch &.{};
    // Along x: points spread edge to edge, or bands.
    const band = scale.Band.init(n).padding(0.25, 0.12);
    const xs = arena.alloc(f32, n) catch @panic("OOM");
    for (xs, 0..) |*x, i| x.* = if (kind == .bar) band.at(i) else if (n <= 1) 0.5 else @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n - 1));
    const x_ticks = arena.alloc(scale.Tick, @min(n, opts.labels.len)) catch @panic("OOM");
    for (x_ticks, 0..) |*t, i| t.* = .{ .at = xs[i], .value = @floatFromInt(i), .label = opts.labels[i] };

    widgets_column(c, opts);
    defer @import("../widgets.zig").end(c);
    if (opts.legend and series.len > 0) {
        const names = arena.alloc([]const u8, series.len) catch @panic("OOM");
        const cols = arena.alloc(Color, series.len) catch @panic("OOM");
        for (series, 0..) |s, i| {
            names[i] = s.name;
            cols[i] = plot.colorOf(s.color, i);
        }
        plot.legend(c, names, cols);
    }
    var f = plot.Frame.begin(c, opts.width, opts.height, opts.key, ticks, x_ticks.len > 0);
    defer f.end();
    const d: Drawing = .{
        .kind = kind,
        .series = series,
        .opts = opts,
        .n = n,
        .xs = xs,
        .y = y,
        .band = band,
        .stacks = stacks,
        .ticks = ticks,
        .grid = c.theme.border.alpha(0.7),
        .zero = y.at(0),
    };
    f.draw(&d, Drawing.draw);
    f.yAxis(ticks);
    f.xAxis(x_ticks);
    var result: Result = .{ .index = f.index };
    const ptr = f.pointer orelse return result;
    if (n == 0 or series.len == 0) return result;
    const hover = pick(&d, ptr) orelse return result;
    result.hover = hover;
    // The marks and the tooltip of the point.
    const s = hover.series;
    const i = hover.index;
    const fy = d.top(s, i);
    const fx = if (kind == .bar) d.bar(s, i).mid() else xs[i];
    const anchor = f.mark(fx, if (std.math.isNan(fy)) 0 else fy, d.colorOf(s), kind != .bar);
    const dec = opts.decimals;
    var lines: std.ArrayList(plot.TipLine) = .empty;
    for (series, 0..) |sr, k| {
        if (kind == .bar and !stacked and k != s and series.len > 1) continue;
        const v = if (i < sr.values.len) sr.values[i] else std.math.nan(f64);
        if (std.math.isNan(v)) continue;
        const val = scale.formatValue(arena, v, dec) catch "?";
        const text = std.fmt.allocPrint(arena, "{s}: {s}", .{ sr.name, val }) catch "";
        lines.append(arena, .{ .color = d.colorOf(k), .text = text }) catch {};
    }
    f.tip(anchor, if (i < opts.labels.len) opts.labels[i] else "", lines.items);
    return result;
}

fn widgets_column(c: *Context, opts: Options) void {
    @import("../widgets.zig").column(c, .{ .width = if (opts.width > 0) .{ .px = opts.width } else .fill });
}

/// The point nearest the pointer: along x the nearest point (or the band
/// under it), then the series whose value there is nearest along y.
fn pick(d: *const Drawing, ptr: [2]f32) ?plot.Hover {
    const i = if (d.kind == .bar) d.band.index(ptr[0]) orelse return null else shape.nearest(d.xs, ptr[0]) orelse return null;
    if (d.kind == .bar and d.stacks == null and d.series.len > 1) {
        // Side by side: the bar under the pointer, or the nearest.
        var best: ?usize = null;
        var best_d = std.math.inf(f32);
        for (0..d.series.len) |s| {
            if (std.math.isNan(d.top(s, i))) continue;
            const b = d.bar(s, i);
            const dist = @abs(b.mid() - ptr[0]);
            if (dist < best_d) {
                best_d = dist;
                best = s;
            }
        }
        return .{ .series = best orelse return null, .index = i };
    }
    if (d.stacks) |st| {
        // Piled up: the segment under the pointer, else the nearest.
        var best: ?usize = null;
        var best_d = std.math.inf(f32);
        for (st, 0..) |seg, s| {
            const a = d.y.at(seg[i].lo);
            const b = d.y.at(seg[i].hi);
            const dist = if (ptr[1] >= @min(a, b) and ptr[1] <= @max(a, b)) 0 else @min(@abs(ptr[1] - a), @abs(ptr[1] - b));
            if (dist < best_d) {
                best_d = dist;
                best = s;
            }
        }
        return .{ .series = best orelse return null, .index = i };
    }
    var best: ?usize = null;
    var best_d = std.math.inf(f32);
    for (0..d.series.len) |s| {
        const t = d.top(s, i);
        if (std.math.isNan(t)) continue;
        if (@abs(t - ptr[1]) < best_d) {
            best_d = @abs(t - ptr[1]);
            best = s;
        }
    }
    return .{ .series = best orelse return null, .index = i };
}
