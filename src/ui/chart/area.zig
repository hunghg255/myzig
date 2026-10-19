//! A plot of your own: the frame the charts draw in (a box, the value
//! axis's labels on the left, the x axis's below, grid lines at their
//! ticks), around a plot area the app draws itself, on a canvas or with
//! boxes, through the two scales.
//!
//!     var a = ui.chart.plotArea(c, .{ .x = .init(0, 60), .y = .init(-1, 1), .height = 200 });
//!     defer a.end();
//!     a.draw(s, drawSignal); // fn (s, p: *ui.Painter, a: *const ui.chart.PlotArea) void
//!     if (a.pointer()) |v| s.cursor = v[0];
//!
//! In a drawing, `a.px(x)` and `a.py(y)` turn values into the painter's
//! points; `ui.chart.strokeSeries` draws a line through points (x, y),
//! as many as `ui.chart.downsampleMinMax` left of a long series.
const std = @import("std");
const types = @import("../types.zig");
const ctx_mod = @import("../context.zig");
const canvas = @import("../canvas.zig");
const scale = @import("scale.zig");
const plot = @import("plot.zig");
const Context = ctx_mod.Context;
const Color = types.Color;

pub const AreaOptions = struct {
    /// The domains along x and y: rounded out to their ticks when `nice`.
    x: scale.Linear,
    y: scale.Linear,
    nice: bool = false,
    /// About how many ticks each axis has (0: no axis).
    x_ticks: u32 = 5,
    y_ticks: u32 = 5,
    /// Ticks of your own along x (times, names), instead of the scale's.
    x_labels: ?[]const scale.Tick = null,
    grid: bool = true,
    /// Its size in points; a width of 0 fills its parent.
    width: f32 = 0,
    height: f32 = 220,
    key: ?[]const u8 = null,
};

/// The frame around a plot of your own: end it with `end`.
pub const PlotArea = struct {
    frame: plot.Frame,
    x: scale.Linear,
    y: scale.Linear,
    x_ticks: []const scale.Tick,
    y_ticks: []const scale.Tick,
    grid: ?Color,

    /// The plot's rect in the box's points (left of it, the value axis).
    pub fn rect(a: *const PlotArea) types.Rect {
        return a.frame.plot;
    }

    /// Where value x is across a drawing of the plot, in its points.
    pub fn px(a: *const PlotArea, v: f64) f32 {
        return a.x.at(v) * a.frame.plot.w;
    }

    /// Where value y is down a drawing of the plot, in its points.
    pub fn py(a: *const PlotArea, v: f64) f32 {
        return (1 - a.y.at(v)) * a.frame.plot.h;
    }

    /// The point (x, y) in the box's points, for boxes placed over the
    /// plot (`ui.chart.place`).
    pub fn at(a: *const PlotArea, vx: f64, vy: f64) types.Point {
        return a.frame.at(a.x.at(vx), a.y.at(vy));
    }

    /// The values under the pointer, while it is over the plot.
    pub fn pointer(a: *const PlotArea) ?[2]f64 {
        const p = a.frame.pointer orelse return null;
        return .{ a.x.invert(p[0]), a.y.invert(p[1]) };
    }

    /// Draws the plot on a canvas: the grid, then
    /// `draw_fn(ctx, painter, area)` in the plot's points (the painter's
    /// size), which may go a little past its edges. Drawn again only when
    /// what it records changes.
    pub fn draw(a: *PlotArea, ctx: anytype, comptime draw_fn: fn (@TypeOf(ctx), *canvas.Painter, *const PlotArea) void) void {
        const Wrap = struct {
            inner: @TypeOf(ctx),
            area: *const PlotArea,
            fn run(w: *const @This(), p: *canvas.Painter) void {
                if (w.area.grid) |g| {
                    plot.grid(p, w.area.y_ticks, g);
                    for (w.area.x_ticks) |t| {
                        const xx = @min(@round(t.at * p.size.w * p.scale) / p.scale + 0.5 / p.scale, p.size.w - 0.5 / p.scale);
                        p.line(xx, 0, xx, p.size.h, 1 / p.scale, g);
                    }
                }
                draw_fn(w.inner, p, w.area);
            }
        };
        const wrap: Wrap = .{ .inner = ctx, .area = a };
        a.frame.draw(&wrap, Wrap.run);
    }

    /// The axes' labels, and the box closed.
    pub fn end(a: *PlotArea) void {
        a.frame.yAxis(a.y_ticks);
        a.frame.xAxis(a.x_ticks);
        a.frame.end();
    }
};

/// Opens a plot's frame of axes around an area the app draws.
pub fn plotArea(c: *Context, opts: AreaOptions) PlotArea {
    const arena = c.alloc();
    var x = opts.x;
    var y = opts.y;
    if (x.lo == x.hi) x.hi = x.lo + 1;
    if (y.lo == y.hi) y.hi = y.lo + 1;
    if (opts.nice) {
        if (opts.x_labels == null) x = x.nice(opts.x_ticks);
        y = y.nice(opts.y_ticks);
    }
    const yt = if (opts.y_ticks > 0) y.ticks(arena, opts.y_ticks) catch &.{} else &.{};
    const xt = opts.x_labels orelse if (opts.x_ticks > 0) x.ticks(arena, opts.x_ticks) catch &.{} else &.{};
    return .{
        .frame = plot.Frame.begin(c, opts.width, opts.height, opts.key, yt, xt.len > 0),
        .x = x,
        .y = y,
        .x_ticks = xt,
        .y_ticks = yt,
        .grid = if (opts.grid) c.theme.border.alpha(0.7) else null,
    };
}

/// A line through points (x, y) of a plot, broken where y is NaN.
pub fn strokeSeries(p: *canvas.Painter, a: *const PlotArea, points: []const [2]f64, color: Color, width: f32) void {
    var line = p.path();
    var open = false;
    for (points) |pt| {
        if (std.math.isNan(pt[1]) or std.math.isNan(pt[0])) {
            open = false;
            continue;
        }
        if (open) line.lineTo(a.px(pt[0]), a.py(pt[1])) else line.moveTo(a.px(pt[0]), a.py(pt[1]));
        open = true;
    }
    p.stroke(&line, .color(color), .{ .width = width, .join = .round, .cap = .round });
}
