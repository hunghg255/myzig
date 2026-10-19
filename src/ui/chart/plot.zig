//! What the charts share: their options and series, the palette, the
//! plot's frame (a box of a fixed or filling size, the area inside its
//! axes, the canvas drawn there), the labels of the axes and the legend,
//! and the hover: the pointer's place in the plot, the marks of the point
//! it is nearest, and its tooltip (`ui.tooltipBase`).
const std = @import("std");
const types = @import("../types.zig");
const ctx_mod = @import("../context.zig");
const widgets = @import("../widgets.zig");
const canvas = @import("../canvas.zig");
const popover = @import("../popover.zig");
const scale = @import("scale.zig");
const shape = @import("shape.zig");
const Context = ctx_mod.Context;
const Color = types.Color;
const Rect = types.Rect;

/// A series of values, one for each point along x (NaN: none there).
pub const Series = struct {
    name: []const u8,
    values: []const f64,
    /// Null: the palette's, by its place.
    color: ?Color = null,
};

pub const Options = struct {
    /// Its size in points; a width of 0 fills its parent.
    width: f32 = 0,
    height: f32 = 220,
    /// Labels along x, one for each point (or each bar).
    labels: []const []const u8 = &.{},
    /// About how many ticks the value axis has.
    ticks: u32 = 5,
    /// The value axis's ends; null: the data's, rounded out to its ticks.
    min: ?f64 = null,
    max: ?f64 = null,
    grid: bool = true,
    legend: bool = true,
    curve: shape.Curve = .linear,
    /// Series piled up (bars, areas), not side by side.
    stacked: bool = false,
    line_width: f32 = 2,
    /// Dots at the points of lines.
    points: bool = false,
    /// Decimals of values in the tooltip; null: up to two.
    decimals: ?u8 = null,
    key: ?[]const u8 = null,
};

/// The point the pointer is nearest: which series, which point.
pub const Hover = struct { series: usize, index: usize };

pub const Result = struct {
    hover: ?Hover = null,
    /// The chart's box, for `c.interact` and tests.
    index: u32 = 0,
};

pub const palette = [_]Color{
    .hex(0x0a84ff), .hex(0xff9f0a), .hex(0x30d158), .hex(0xbf5af2),
    .hex(0xff453a), .hex(0x64d2ff), .hex(0xffd60a), .hex(0xff375f),
};

pub fn colorOf(color: ?Color, i: usize) Color {
    return color orelse palette[i % palette.len];
}

pub const label_size: f32 = 11;

/// Room a plot's canvas keeps around the plot, in points.
const bleed: f32 = 8;

/// A chart's box and the plot inside its axes, in the box's own points.
pub const Frame = struct {
    c: *Context,
    index: u32,
    id: u64,
    size: types.Size,
    plot: Rect,
    /// Where the pointer is in the plot (fractions: x from the left, y
    /// from the bottom), while it is over the box.
    pointer: ?[2]f32 = null,
    /// The box's place in the window, in the last layout.
    origin: types.Point = .{},
    inter: ctx_mod.Interaction = undefined,

    /// Opens the box (end with `end`), sized by `opts` and the labels of
    /// the value axis `y_labels` (left) and the x axis (below, if any).
    pub fn begin(c: *Context, width: f32, height: f32, key: ?[]const u8, y_labels: []const scale.Tick, x_axis: bool) Frame {
        const id = c.peekId(key);
        const size = canvas.resolve(c, id, .{ .w = width, .h = height });
        const index = c.open(.{
            .width = if (width > 0) .{ .px = width } else .fill,
            .height = .{ .px = height },
        }, key);
        const ts: types.TextStyle = .{ .size = label_size };
        var axis_w: f32 = 0;
        for (y_labels) |t| axis_w = @max(axis_w, c.text.width(t.label, ts));
        if (y_labels.len > 0) axis_w += 8;
        const lh = c.text.lineHeight(ts);
        const top = if (y_labels.len > 0) @ceil(lh / 2) else 4;
        const bottom = if (x_axis) lh + 6 else 4;
        var f: Frame = .{
            .c = c,
            .index = index,
            .id = id,
            .size = size,
            .plot = .{ .x = axis_w, .y = top, .w = @max(0, size.w - axis_w - 8), .h = @max(0, size.h - top - bottom) },
        };
        const inter = c.interact(index, .{});
        f.inter = inter;
        // Over the plot the pointer stays an arrow.
        if (c.hot == inter.id) c.cursor_hand = false;
        if (inter.rect) |r| {
            f.origin = .{ .x = r.x, .y = r.y };
            if (inter.hovered and f.plot.w > 0 and f.plot.h > 0) {
                const mx = c.input.mouse.x - r.x - f.plot.x;
                const my = c.input.mouse.y - r.y - f.plot.y;
                if (mx >= 0 and my >= 0 and mx <= f.plot.w and my <= f.plot.h) f.pointer = .{ mx / f.plot.w, 1 - my / f.plot.h };
                // Every move inside draws a frame, for the marks to follow.
                c.wants_moves = true;
            }
        }
        return f;
    }

    pub fn end(f: *Frame) void {
        widgets.end(f.c);
    }

    /// The plot's canvas: `draw(ctx, painter)` in the plot's points (the
    /// painter's size), with room around it for what goes past its edges:
    /// a dot on its last point, a line's width on its top.
    pub fn draw(f: *Frame, ctx: anytype, comptime draw_fn: fn (@TypeOf(ctx), *canvas.Painter) void) void {
        if (!(f.plot.w > 0 and f.plot.h > 0)) return;
        const Wrap = struct {
            inner: @TypeOf(ctx),
            size: types.Size,
            fn run(w: *const @This(), p: *canvas.Painter) void {
                p.translate(bleed, bleed);
                p.size = w.size;
                draw_fn(w.inner, p);
            }
        };
        const wrap: Wrap = .{ .inner = ctx, .size = .{ .w = f.plot.w, .h = f.plot.h } };
        const i = canvas.canvas(f.c, .{ .w = f.plot.w + 2 * bleed, .h = f.plot.h + 2 * bleed }, .{}, &wrap, Wrap.run);
        place(f.c, i, f.plot.x - bleed, f.plot.y - bleed);
    }

    /// Labels of the value axis, right-aligned left of the plot.
    pub fn yAxis(f: *Frame, ticks: []const scale.Tick) void {
        const c = f.c;
        const ts: types.TextStyle = .{ .size = label_size, .color = c.theme.muted };
        const lh = c.text.lineHeight(ts);
        for (ticks) |t| {
            const w = c.text.width(t.label, ts);
            widgets.text(c, t.label, ts);
            place(c, last(c), f.plot.x - 8 - w, f.plot.y + (1 - t.at) * f.plot.h - lh / 2);
        }
    }

    /// Labels along x, centered under their ticks, every k-th when they
    /// would crowd.
    pub fn xAxis(f: *Frame, ticks: []const scale.Tick) void {
        const c = f.c;
        const ts: types.TextStyle = .{ .size = label_size, .color = c.theme.muted };
        var widest: f32 = 0;
        for (ticks) |t| widest = @max(widest, c.text.width(t.label, ts));
        const n: f32 = @floatFromInt(ticks.len);
        const every: usize = @intFromFloat(@max(1, @ceil(n * (widest + 8) / @max(1, f.plot.w))));
        for (ticks, 0..) |t, i| {
            if (i % every != 0) continue;
            const w = c.text.width(t.label, ts);
            widgets.text(c, t.label, ts);
            place(c, last(c), f.plot.x + t.at * f.plot.w - w / 2, f.plot.y + f.plot.h + 4);
        }
    }

    /// A point of the plot (fractions) in the box's points.
    pub fn at(f: *const Frame, fx: f32, fy: f32) types.Point {
        return .{ .x = f.plot.x + fx * f.plot.w, .y = f.plot.y + (1 - fy) * f.plot.h };
    }

    /// The marks of a hovered point: a rule across the plot at it (when
    /// `rule`), and a dot on it; returns the dot's rect in the window.
    pub fn mark(f: *Frame, fx: f32, fy: f32, color: Color, rule: bool) Rect {
        const c = f.c;
        const p = f.at(fx, fy);
        if (rule) {
            _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .{ .px = f.plot.h }, .background = c.theme.muted.alpha(0.6) }, .none, null);
            place(c, last(c), @round(p.x) - 0.5, f.plot.y);
        }
        const d: f32 = 10;
        _ = c.leaf(.{ .width = .{ .px = d }, .height = .{ .px = d }, .radius = d / 2, .background = color, .border = c.theme.surface, .border_width = 2 }, .none, null);
        place(c, last(c), p.x - d / 2, p.y - d / 2);
        return .{ .x = f.origin.x + p.x - d / 2, .y = f.origin.y + p.y - d / 2, .w = d, .h = d };
    }

    /// The tooltip of the hovered point, over `anchor`: a title and a
    /// line for each value.
    pub fn tip(f: *Frame, anchor: Rect, title: []const u8, lines: []const TipLine) void {
        const c = f.c;
        var a = f.inter;
        a.rect = anchor;
        _ = popover.tooltipBase(c, a) orelse return;
        const fg = c.theme.background;
        if (title.len > 0) widgets.text(c, title, .{ .size = 12, .weight = .semibold, .color = fg });
        for (lines) |l| {
            widgets.row(c, .{ .gap = 6, .align_items = .center });
            _ = c.leaf(.{ .width = .{ .px = 8 }, .height = .{ .px = 8 }, .radius = 4, .background = l.color }, .none, null);
            widgets.text(c, l.text, .{ .size = 12, .color = fg });
            widgets.end(c);
        }
        popover.tooltipEnd(c, a);
    }
};

pub const TipLine = struct { color: Color, text: []const u8 };

/// A row of swatches and names.
pub fn legend(c: *Context, names: []const []const u8, colors: []const Color) void {
    widgets.row(c, .{ .gap = 14, .align_items = .center, .padding = .{ .bottom = 6 } });
    defer widgets.end(c);
    for (names, colors) |n, col| {
        widgets.row(c, .{ .gap = 6, .align_items = .center });
        _ = c.leaf(.{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .radius = 3, .background = col }, .none, null);
        widgets.text(c, n, .{ .size = 12, .color = c.theme.muted });
        widgets.end(c);
    }
}

/// The last box added.
fn last(c: *Context) u32 {
    return @intCast(c.nodes.items.len - 1);
}

/// Takes a box out of the flow, at (x, y) in its parent.
pub fn place(c: *Context, index: u32, x: f32, y: f32) void {
    const n = c.node(index);
    n.style.absolute = true;
    n.style.offset = .{ .x = x, .y = y };
}

/// Grid lines across the plot at the ticks, in a canvas's painter.
pub fn grid(p: *canvas.Painter, ticks: []const scale.Tick, color: Color) void {
    for (ticks) |t| {
        const yy = @min(@round((1 - t.at) * p.size.h * p.scale) / p.scale + 0.5 / p.scale, p.size.h - 0.5 / p.scale);
        p.line(0, yy, p.size.w, yy, 1 / p.scale, color);
    }
}
