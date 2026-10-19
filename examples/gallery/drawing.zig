//! The gallery's drawings: paths filled and stroked on a canvas, with
//! gradients, dashes and transforms; SVG pictures; and charts.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const chart = ui.chart;
const card = @import("basics.zig").card;

const logo =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
    \\  <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
    \\    <stop offset="0" stop-color="#f7a41d"/><stop offset="1" stop-color="#ec5f1d"/>
    \\  </linearGradient></defs>
    \\  <rect x="4" y="4" width="56" height="56" rx="14" fill="url(#g)"/>
    \\  <path d="M18 20h28L22 44h24" fill="none" stroke="#fff" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/>
    \\</svg>
;

const gear =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
    \\  <circle cx="12" cy="12" r="3"/>
    \\  <path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M4.9 19.1L7 17M17 7l2.1-2.1"/>
    \\</svg>
;

const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun" };

pub const Drawing = struct {
    phase: f32 = 0,
    turn: f32 = 0,
    stacked: bool = true,
    hover: []const u8 = "",

    fn wave(s: *Drawing, p: *ui.Painter) void {
        const w = p.size.w;
        const h = p.size.h;
        // A filled area under a wave, a gradient down to clear.
        var area = p.path();
        var line = p.path();
        for (0..121) |i| {
            const x = w * @as(f32, @floatFromInt(i)) / 120;
            const y = h / 2 + h * 0.28 * @sin(@as(f32, @floatFromInt(i)) / 12 + s.phase);
            if (i == 0) {
                area.moveTo(x, y);
                line.moveTo(x, y);
            } else {
                area.lineTo(x, y);
                line.lineTo(x, y);
            }
        }
        area.lineTo(w, h);
        area.lineTo(0, h);
        area.close();
        const accent: ui.Color = .hex(0x0a84ff);
        p.fill(&area, .{ .linear = .{ .from = .{ 0, 0 }, .to = .{ 0, h }, .stops = &.{ .{ .offset = 0, .color = accent.alpha(0.45) }, .{ .offset = 1, .color = accent.alpha(0) } } } });
        p.stroke(&line, .color(accent), .{ .width = 2.5, .join = .round, .cap = .round });
        // A dashed baseline.
        var base = p.path();
        base.moveTo(0, h / 2);
        base.lineTo(w, h / 2);
        p.stroke(&base, .color(ui.Color.hex(0x8e8e93)), .{ .width = 1, .dash = &.{ 6, 4 } });
    }

    fn shapes(s: *Drawing, p: *ui.Painter) void {
        // A radial gradient in a circle, a star turned, rounded rectangles.
        p.fillCircle(50, 50, 40, .{ .radial = .{ .center = .{ 40, 40 }, .radius = 48, .stops = &.{ .{ .offset = 0, .color = .hex(0xffe066) }, .{ .offset = 1, .color = .hex(0xff6b35) } } } });
        p.save();
        p.rotate(s.turn * std.math.pi / 180, 150, 50);
        var star = p.path();
        for (0..10) |i| {
            const r: f32 = if (i % 2 == 0) 40 else 17;
            const a = -std.math.pi / 2.0 + @as(f32, @floatFromInt(i)) * std.math.pi / 5.0;
            if (i == 0) star.moveTo(150 + r * @cos(a), 50 + r * @sin(a)) else star.lineTo(150 + r * @cos(a), 50 + r * @sin(a));
        }
        star.close();
        p.fill(&star, .color(.hex(0xaf52de)));
        p.restore();
        p.fillRoundRect(.{ .x = 210, .y = 14, .w = 90, .h = 72 }, 14, .color(.hex(0x34c759)));
        p.strokeCircle(350, 50, 34, 6, .hex(0x5ac8fa));
        // A heart of curves.
        var heart = p.path();
        heart.moveTo(440, 86);
        heart.cubicTo(392, 60, 404, 14, 440, 32);
        heart.cubicTo(476, 14, 488, 60, 440, 86);
        heart.close();
        p.fill(&heart, .color(.hex(0xff375f)));
    }

    pub fn drawingPage(s: *Drawing, c: *ui.Context) void {
        const th = c.theme;
        ui.heading(c, "Drawing");
        {
            card(c, "A canvas of paths");
            defer ui.end(c);
            ui.text(c, "Filled and stroked paths, gradients, dashes and transforms, rasterized when they change.", .{ .wrap = true, .color = th.muted });
            _ = ui.canvas(c, .{ .w = 0, .h = 140 }, .{ .radius = 8 }, s, wave);
            _ = ui.slider(c, &s.phase, .{ .min = 0, .max = 6.28, .width = .{ .px = 240 }, .label = "Phase" });
            _ = ui.canvas(c, .{ .w = 500, .h = 100 }, .{}, s, shapes);
            ui.row(c, .{ .gap = 12, .align_items = .center });
            ui.text(c, "Turn the star", .{ .color = th.muted });
            _ = ui.slider(c, &s.turn, .{ .min = 0, .max = 72, .width = .{ .px = 200 } });
            ui.end(c);
        }
        {
            card(c, "SVG");
            defer ui.end(c);
            ui.row(c, .{ .gap = 16, .align_items = .center });
            defer ui.end(c);
            _ = ui.svg(c, logo, .{ .width = 64 });
            _ = ui.svg(c, logo, .{ .width = 32 });
            _ = ui.svg(c, gear, .{ .width = 32 });
            _ = ui.svg(c, gear, .{ .width = 32, .color = th.accent });
            ui.text(c, "Paths, gradients and currentColor, from SVG documents.", .{ .color = th.muted });
        }
    }

    pub fn chartsPage(s: *Drawing, c: *ui.Context) void {
        const th = c.theme;
        ui.heading(c, "Charts");
        {
            card(c, "Lines and areas");
            defer ui.end(c);
            const r = chart.lineChart(c, &.{
                .{ .name = "Visitors", .values = &.{ 120, 180, 150, 260, 240, 310 } },
                .{ .name = "Sign-ups", .values = &.{ 30, 42, 38, 70, 64, 95 } },
            }, .{ .labels = &months, .curve = .monotone, .points = true, .height = 200 });
            if (r.hover) |h| ui.text(c, c.print("{s}, {s}", .{ if (h.series == 0) "Visitors" else "Sign-ups", months[h.index] }), .{ .size = 12, .color = th.muted });
            _ = chart.areaChart(c, &.{
                .{ .name = "Desktop", .values = &.{ 40, 52, 48, 61, 70, 66 } },
                .{ .name = "Mobile", .values = &.{ 22, 30, 41, 38, 50, 62 } },
            }, .{ .labels = &months, .stacked = true, .curve = .monotone, .height = 180 });
        }
        {
            card(c, "Bars");
            defer ui.end(c);
            _ = ui.toggle(c, "Stacked", &s.stacked);
            _ = chart.barChart(c, &.{
                .{ .name = "Search", .values = &.{ 12, 19, 7, 15, 22, 18 } },
                .{ .name = "Direct", .values = &.{ 8, 4, 11, 9, 6, 12 } },
                .{ .name = "Social", .values = &.{ 5, 9, 6, 12, 10, 14 } },
            }, .{ .labels = &months, .stacked = s.stacked, .height = 200 });
        }
        {
            card(c, "Scatter and pie");
            defer ui.end(c);
            ui.row(c, .{ .width = .fill, .gap = 24, .align_items = .center });
            defer ui.end(c);
            var xs: [40]f64 = undefined;
            var ys: [40]f64 = undefined;
            for (&xs, &ys, 0..) |*x, *y, i| {
                const f: f64 = @floatFromInt(i);
                x.* = f;
                y.* = 20 + f * 1.5 + 12 * @sin(f * 1.7);
            }
            ui.column(c, .{ .grow = 1 });
            _ = chart.scatterChart(c, &.{.{ .name = "Samples", .xs = &xs, .ys = &ys }}, .{ .height = 200 });
            ui.end(c);
            _ = chart.pieChart(c, &.{
                .{ .label = "Zig", .value = 46 },
                .{ .label = "Go", .value = 28 },
                .{ .label = "Swift", .value = 16 },
                .{ .label = "Other", .value = 10 },
            }, .{ .size = 180, .inner = 0.55 });
        }
    }
};
