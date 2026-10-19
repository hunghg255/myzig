//! Charts in native UI (`ui.chart`), after mygo's `ui/chart`: the parts
//! (scales that map data onto a plot and pick round ticks, paths of
//! lines, areas and pie slices, stacks, the nearest point), and charts
//! made of them, drawn on a canvas (`ui.canvas`) with their axes, grid
//! lines, legends and a tooltip of the point nearest the pointer.
//!
//!     const r = ui.chart.barChart(c, &.{
//!         .{ .name = "Search", .values = &.{ 12, 19, 7 } },
//!         .{ .name = "Direct", .values = &.{ 8, 4, 11 } },
//!     }, .{ .labels = &.{ "Jan", "Feb", "Mar" }, .stacked = true });
//!
//! Positions on a plot are fractions of it, from 0 to 1: along x from its
//! left edge, and along y from its bottom up, the way values grow; `x`
//! and `y` turn them into points in a plot's rect, for drawings of your
//! own on a `ui.canvas`. A plot of your own gets the same frame of axes
//! from `plotArea`, and long series fewer points from `downsampleMinMax`.
const scale = @import("scale.zig");
const shape = @import("shape.zig");
const plot = @import("plot.zig");
const xy = @import("xy.zig");
const scatter = @import("scatter.zig");
const area_mod = @import("area.zig");
const downsample = @import("downsample.zig");

pub const Span = scale.Span;
pub const Tick = scale.Tick;
pub const Linear = scale.Linear;
pub const Band = scale.Band;
pub const extent = scale.extent;
pub const format = scale.format;

pub const Curve = shape.Curve;
pub const x = shape.x;
pub const y = shape.y;
pub const line = shape.line;
pub const area = shape.area;
pub const nearest = shape.nearest;
pub const Slice = shape.Slice;
pub const pie = shape.pie;
pub const polar = shape.polar;
pub const sector = shape.sector;
pub const sliceAt = shape.sliceAt;
pub const Segment = shape.Segment;
pub const Stacking = shape.Stacking;
pub const stack = shape.stack;

pub const Series = plot.Series;
pub const Options = plot.Options;
pub const Hover = plot.Hover;
pub const Result = plot.Result;
pub const palette = plot.palette;
pub const legend = plot.legend;

pub const lineChart = xy.lineChart;
pub const areaChart = xy.areaChart;
pub const barChart = xy.barChart;
pub const PointSeries = scatter.PointSeries;
pub const ScatterOptions = scatter.ScatterOptions;
pub const scatterChart = scatter.scatterChart;
pub const PieSlice = scatter.PieSlice;
pub const PieOptions = scatter.PieOptions;
pub const pieChart = scatter.pieChart;

pub const AreaOptions = area_mod.AreaOptions;
pub const PlotArea = area_mod.PlotArea;
pub const plotArea = area_mod.plotArea;
pub const strokeSeries = area_mod.strokeSeries;
pub const grid = plot.grid;
pub const place = plot.place;
pub const downsampleMinMax = downsample.downsampleMinMax;
pub const downsampleValues = downsample.downsampleValues;

test {
    _ = scale;
    _ = shape;
    _ = downsample;
}
