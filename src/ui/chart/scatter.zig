//! Scatter plots, and pies and donuts.
//!
//!     _ = ui.chart.scatterChart(c, &.{.{ .name = "Cars", .xs = s.weight, .ys = s.mpg }}, .{ .height = 240 });
//!     _ = ui.chart.pieChart(c, &.{ .{ .label = "macOS", .value = 52 }, .{ .label = "Linux", .value = 30 } }, .{ .inner = 0.6 });
const std = @import("std");
const types = @import("../types.zig");
const ctx_mod = @import("../context.zig");
const widgets = @import("../widgets.zig");
const canvas = @import("../canvas.zig");
const scale = @import("scale.zig");
const shape = @import("shape.zig");
const plot = @import("plot.zig");
const Context = ctx_mod.Context;
const Color = types.Color;

/// Points at (xs[i], ys[i]).
pub const PointSeries = struct {
    name: []const u8,
    xs: []const f64,
    ys: []const f64,
    color: ?Color = null,
};

pub const ScatterOptions = struct {
    width: f32 = 0,
    height: f32 = 220,
    ticks: u32 = 5,
    radius: f32 = 4,
    grid: bool = true,
    legend: bool = true,
    decimals: ?u8 = null,
    /// Farthest the pointer may be from a point to pick it, in points.
    reach: f32 = 24,
    key: ?[]const u8 = null,
};

const ScatterDrawing = struct {
    series: []const PointSeries,
    x: scale.Linear,
    y: scale.Linear,
    ticks: []const scale.Tick,
    x_ticks: []const scale.Tick,
    grid: ?Color,
    radius: f32,

    fn draw(d: *const ScatterDrawing, p: *canvas.Painter) void {
        if (d.grid) |g| {
            plot.grid(p, d.ticks, g);
            for (d.x_ticks) |t| {
                const xx = @min(@round(t.at * p.size.w * p.scale) / p.scale + 0.5 / p.scale, p.size.w - 0.5 / p.scale);
                p.line(xx, 0, xx, p.size.h, 1 / p.scale, g);
            }
        }
        const r: types.Rect = .{ .w = p.size.w, .h = p.size.h };
        for (d.series, 0..) |s, k| {
            const col = plot.colorOf(s.color, k);
            for (s.xs, 0..) |vx, i| {
                if (i >= s.ys.len or std.math.isNan(vx) or std.math.isNan(s.ys[i])) continue;
                p.fillCircle(shape.x(r, d.x.at(vx)), shape.y(r, d.y.at(s.ys[i])), d.radius, .color(col.alpha(0.8)));
            }
        }
    }
};

pub fn scatterChart(c: *Context, series: []const PointSeries, opts: ScatterOptions) plot.Result {
    const arena = c.alloc();
    var ex: [2]f64 = .{ std.math.inf(f64), -std.math.inf(f64) };
    var ey = ex;
    for (series) |s| {
        const a = scale.extent(s.xs);
        const b = scale.extent(s.ys);
        ex = .{ @min(ex[0], a[0]), @max(ex[1], a[1]) };
        ey = .{ @min(ey[0], b[0]), @max(ey[1], b[1]) };
    }
    if (series.len == 0) {
        ex = .{ 0, 1 };
        ey = .{ 0, 1 };
    }
    if (ex[0] == ex[1]) ex[1] += 1;
    if (ey[0] == ey[1]) ey[1] += 1;
    // A little room around the points, so none sits on an edge.
    const px = (ex[1] - ex[0]) * 0.04;
    const py = (ey[1] - ey[0]) * 0.04;
    const x = scale.Linear.init(ex[0] - px, ex[1] + px).nice(opts.ticks);
    const y = scale.Linear.init(ey[0] - py, ey[1] + py).nice(opts.ticks);
    const yt = y.ticks(arena, opts.ticks) catch &.{};
    const xt = x.ticks(arena, opts.ticks) catch &.{};
    widgets.column(c, .{ .width = if (opts.width > 0) .{ .px = opts.width } else .fill });
    defer widgets.end(c);
    if (opts.legend and series.len > 0) {
        const names = arena.alloc([]const u8, series.len) catch @panic("OOM");
        const cols = arena.alloc(Color, series.len) catch @panic("OOM");
        for (series, 0..) |s, i| {
            names[i] = s.name;
            cols[i] = plot.colorOf(s.color, i);
        }
        plot.legend(c, names, cols);
    }
    var f = plot.Frame.begin(c, opts.width, opts.height, opts.key, yt, true);
    defer f.end();
    const d: ScatterDrawing = .{
        .series = series,
        .x = x,
        .y = y,
        .ticks = yt,
        .x_ticks = xt,
        .grid = if (opts.grid) c.theme.border.alpha(0.7) else null,
        .radius = opts.radius,
    };
    f.draw(&d, ScatterDrawing.draw);
    f.yAxis(yt);
    f.xAxis(xt);
    var result: plot.Result = .{ .index = f.index };
    const ptr = f.pointer orelse return result;
    // The nearest point, in points on the screen.
    var best: ?plot.Hover = null;
    var best_d = opts.reach;
    for (series, 0..) |s, k| for (s.xs, 0..) |vx, i| {
        if (i >= s.ys.len) break;
        const dx = (x.at(vx) - ptr[0]) * f.plot.w;
        const dy = (y.at(s.ys[i]) - ptr[1]) * f.plot.h;
        const dist = std.math.hypot(dx, dy);
        if (dist <= best_d) {
            best_d = dist;
            best = .{ .series = k, .index = i };
        }
    };
    const h = best orelse return result;
    result.hover = h;
    const s = series[h.series];
    const col = plot.colorOf(s.color, h.series);
    const anchor = f.mark(x.at(s.xs[h.index]), y.at(s.ys[h.index]), col, false);
    const xd = opts.decimals;
    const yd = opts.decimals;
    const text = std.fmt.allocPrint(arena, "{s}, {s}", .{ scale.formatValue(arena, s.xs[h.index], xd) catch "?", scale.formatValue(arena, s.ys[h.index], yd) catch "?" }) catch "";
    f.tip(anchor, s.name, &.{.{ .color = col, .text = text }});
    return result;
}

pub const PieSlice = struct {
    label: []const u8,
    value: f64,
    color: ?Color = null,
};

pub const PieOptions = struct {
    /// The pie's side, in points.
    size: f32 = 200,
    /// The hole of a donut, as a fraction of the radius (0: a pie).
    inner: f32 = 0,
    /// Radians between slices.
    pad: f64 = 0.02,
    legend: bool = true,
    decimals: ?u8 = null,
    key: ?[]const u8 = null,
};

const PieDrawing = struct {
    slices: []const shape.Slice,
    data: []const PieSlice,
    inner: f32,
    hover: ?usize,

    fn draw(d: *const PieDrawing, p: *canvas.Painter) void {
        const cx = p.size.w / 2;
        const cy = p.size.h / 2;
        const outer = @min(cx, cy) - 4;
        for (d.slices, 0..) |s, i| {
            var path = p.path();
            const grow: f32 = if (d.hover == i) 4 else 0;
            shape.sector(&path, cx, cy, d.inner * outer, outer + grow, s);
            p.fill(&path, .color(plot.colorOf(d.data[i].color, i)));
        }
    }
};

/// A pie (or a donut, with `inner`) of shares; the slice under the
/// pointer grows and tells its value and share.
pub fn pieChart(c: *Context, data: []const PieSlice, opts: PieOptions) plot.Result {
    const arena = c.alloc();
    const values = arena.alloc(f64, data.len) catch @panic("OOM");
    var sum: f64 = 0;
    for (values, data) |*v, s| {
        v.* = s.value;
        if (s.value > 0) sum += s.value;
    }
    const slices = shape.pie(arena, values, opts.pad) catch @panic("OOM");
    widgets.row(c, .{ .gap = 16, .align_items = .center });
    defer widgets.end(c);
    const index = c.open(.{ .width = .{ .px = opts.size }, .height = .{ .px = opts.size } }, opts.key);
    const inter = c.interact(index, .{});
    var result: plot.Result = .{ .index = index };
    const outer = opts.size / 2 - 4;
    if (inter.hovered) if (inter.rect) |r| {
        c.wants_moves = true;
        if (c.hot == inter.id) c.cursor_hand = false;
        const dx = c.input.mouse.x - r.x - opts.size / 2;
        const dy = c.input.mouse.y - r.y - opts.size / 2;
        if (shape.sliceAt(slices, dx, dy, opts.inner * outer, outer + 4)) |i| result.hover = .{ .series = 0, .index = i };
    };
    const hi: ?usize = if (result.hover) |h| h.index else null;
    const d: PieDrawing = .{ .slices = slices, .data = data, .inner = opts.inner, .hover = hi };
    _ = canvas.canvas(c, .{ .w = opts.size, .h = opts.size }, .{}, &d, PieDrawing.draw);
    if (hi) |i| if (inter.rect) |r| {
        // The tooltip by the slice's middle, outside it.
        const at = shape.polar(r.x + opts.size / 2, r.y + opts.size / 2, outer * (1 + opts.inner) / 2, slices[i].mid());
        var a = inter;
        a.rect = .{ .x = at[0] - 1, .y = at[1] - 1, .w = 2, .h = 2 };
        if (@import("../popover.zig").tooltipBase(c, a)) |_| {
            const fg = c.theme.background;
            const share = if (sum > 0) @max(0, data[i].value) / sum * 100 else 0;
            widgets.text(c, data[i].label, .{ .size = 12, .weight = .semibold, .color = fg });
            const v = scale.formatValue(arena, data[i].value, opts.decimals) catch "?";
            widgets.text(c, std.fmt.allocPrint(arena, "{s} ({d:.0}%)", .{ v, share }) catch "", .{ .size = 12, .color = fg });
            @import("../popover.zig").tooltipEnd(c, a);
        }
    };
    widgets.end(c);
    if (opts.legend) {
        widgets.column(c, .{ .gap = 6 });
        defer widgets.end(c);
        for (data, 0..) |s, i| {
            widgets.row(c, .{ .gap = 6, .align_items = .center });
            _ = c.leaf(.{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .radius = 3, .background = plot.colorOf(s.color, i) }, .none, null);
            widgets.text(c, s.label, .{ .size = 12, .color = c.theme.muted });
            widgets.end(c);
        }
    }
    return result;
}
