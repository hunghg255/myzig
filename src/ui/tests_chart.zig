//! Charts through `Tester`: axes and their ticks, legends, and the point
//! the pointer is nearest, marked and told in a tooltip.
const std = @import("std");
const ui = @import("ui.zig");
const chart = @import("chart/chart.zig");
const testing = std.testing;

const Kind = enum { line, bar, stacked, scatter, pie };

const Charts = struct {
    kind: Kind = .line,
    result: chart.Result = .{},
    fn view(s: *Charts, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .width = .fill });
        defer ui.end(c);
        const series = [_]chart.Series{
            .{ .name = "Revenue", .values = &.{ 10, 50, 87 } },
            .{ .name = "Costs", .values = &.{ 80, 20, 60 } },
        };
        const labels = &[_][]const u8{ "Jan", "Feb", "Mar" };
        s.result = switch (s.kind) {
            .line => chart.lineChart(c, &series, .{ .labels = labels, .height = 200 }),
            .bar => chart.barChart(c, &series, .{ .labels = labels, .height = 200 }),
            .stacked => chart.barChart(c, &series, .{ .labels = labels, .height = 200, .stacked = true }),
            .scatter => chart.scatterChart(c, &.{.{ .name = "Cars", .xs = &.{ 1, 2, 3 }, .ys = &.{ 10, 30, 20 } }}, .{ .height = 200 }),
            .pie => chart.pieChart(c, &.{ .{ .label = "macOS", .value = 50 }, .{ .label = "Linux", .value = 30 }, .{ .label = "Windows", .value = 20 } }, .{ .size = 160, .inner = 0.5 }),
        };
    }
};

fn open(s: *Charts, t: *ui.Tester) !void {
    try t.init(testing.allocator, .init(s, Charts.view), .{ .width = 480, .height = 320 });
    // Filling its parent's width: drawn once laid out.
    t.settle(1);
}

fn middle(r: ui.Rect) [2]f32 {
    return .{ r.x + r.w / 2, r.y + r.h / 2 };
}

/// Where a value is along the value axis, from where its 0 and 100 labels are.
fn yOf(t: *ui.Tester, v: f32) !f32 {
    const zero = middle(t.findText("0") orelse return error.NoAxis)[1];
    const hundred = middle(t.findText("100") orelse return error.NoAxis)[1];
    return zero + (hundred - zero) * v / 100;
}

test "a line chart: round ticks along its value axis, its labels, a legend" {
    var s: Charts = .{};
    var t: ui.Tester = undefined;
    try open(&s, &t);
    defer t.deinit();
    // 10 to 87 rounds out to 0 to 100, ticks every 20.
    for ([_][]const u8{ "0", "20", "40", "60", "80", "100" }) |tick| try testing.expect(t.hasText(tick));
    try testing.expect(!t.hasText("120"));
    for ([_][]const u8{ "Jan", "Feb", "Mar", "Revenue", "Costs" }) |l| try testing.expect(t.hasText(l));
    // Ticks go up the axis, labels along it.
    try testing.expect(t.findText("100").?.y < t.findText("0").?.y);
    try testing.expect(t.findText("Jan").?.x < t.findText("Feb").?.x);
    // The plot is drawn: a canvas picture.
    try testing.expectEqual(@as(usize, 1), t.text.images.decoded.count());
}

test "a line chart: the pointer picks the nearest point, marked, then a tooltip" {
    var s: Charts = .{};
    var t: ui.Tester = undefined;
    try open(&s, &t);
    defer t.deinit();
    const feb = middle(t.findText("Feb").?)[0];
    // At Feb, Costs (20) is nearer 25 than Revenue (50).
    t.moveTo(feb + 30, try yOf(&t, 25));
    try testing.expectEqual(chart.Hover{ .series = 1, .index = 1 }, s.result.hover.?);
    t.moveTo(feb - 10, try yOf(&t, 45));
    try testing.expectEqual(chart.Hover{ .series = 0, .index = 1 }, s.result.hover.?);
    const mar = middle(t.findText("Mar").?)[0];
    t.moveTo(mar - 5, try yOf(&t, 80));
    try testing.expectEqual(chart.Hover{ .series = 0, .index = 2 }, s.result.hover.?);
    try testing.expect(!t.hasText("Revenue: 87"));
    t.advance(0.7);
    try testing.expect(t.hasText("Revenue: 87"));
    try testing.expect(t.hasText("Costs: 60"));
    // Hovering draws marks over the plot, not the plot again.
    try testing.expectEqual(@as(usize, 1), t.text.images.decoded.count());
    // Off the plot, no point.
    t.moveTo(5, 5);
    try testing.expect(s.result.hover == null);
}

test "bars: side by side, the one under the pointer; stacked, the segment under it" {
    var s: Charts = .{ .kind = .bar };
    var t: ui.Tester = undefined;
    try open(&s, &t);
    defer t.deinit();
    const jan = middle(t.findText("Jan").?)[0];
    t.moveTo(jan + 8, try yOf(&t, 5));
    try testing.expectEqual(chart.Hover{ .series = 1, .index = 0 }, s.result.hover.?);
    t.moveTo(jan - 8, try yOf(&t, 5));
    try testing.expectEqual(chart.Hover{ .series = 0, .index = 0 }, s.result.hover.?);
    t.advance(0.7);
    try testing.expect(t.hasText("Revenue: 10"));
    try testing.expect(!t.hasText("Costs: 80"));

    s.kind = .stacked;
    t.moveTo(1, 1);
    t.settle(1);
    // Jan piles 10 then 80: up to 90, so the axis goes to 100.
    t.moveTo(jan, try yOf(&t, 50));
    try testing.expectEqual(chart.Hover{ .series = 1, .index = 0 }, s.result.hover.?);
    t.moveTo(jan, try yOf(&t, 5));
    try testing.expectEqual(chart.Hover{ .series = 0, .index = 0 }, s.result.hover.?);
}

test "scatter: the nearest point within reach; pie: the slice under the pointer" {
    var s: Charts = .{ .kind = .scatter };
    var t: ui.Tester = undefined;
    try open(&s, &t);
    defer t.deinit();
    // x from 1 to 3 and y from 10 to 30 round out to their own ends.
    const x2 = middle(t.findText("2.0").?)[0];
    const y30 = middle(t.findText("30").?)[1];
    t.moveTo(x2 + 6, y30 + 4);
    try testing.expectEqual(chart.Hover{ .series = 0, .index = 1 }, s.result.hover.?);
    t.advance(0.7);
    try testing.expect(t.hasText("2, 30"));

    s.kind = .pie;
    t.moveTo(1, 1);
    t.settle(1);
    try testing.expect(t.hasText("Windows"));
    const r = t.ctx.nodes.items[s.result.index].rect;
    // Right of the center: a quarter turn, in macOS's half.
    t.moveTo(r.x + r.w / 2 + 50, r.y + r.h / 2);
    try testing.expectEqual(@as(usize, 0), s.result.hover.?.index);
    // Up and left, at 0.9 of a turn: in Windows's fifth.
    t.moveTo(r.x + r.w / 2 - 29, r.y + r.h / 2 - 40);
    try testing.expectEqual(@as(usize, 2), s.result.hover.?.index);
    t.advance(0.7);
    try testing.expect(t.hasText("20 (20%)"));
    // In the donut's hole, none.
    t.moveTo(r.x + r.w / 2, r.y + r.h / 2);
    try testing.expect(s.result.hover == null);
}

const Stream = struct {
    samples: [5000]f64 = undefined,
    pointer: ?[2]f64 = null,
    drawn: usize = 0,
    plot: ui.Rect = .{},

    fn view(s: *Stream, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .width = .fill });
        defer ui.end(c);
        var a = chart.plotArea(c, .{ .x = .init(0, 5000), .y = .init(-1.2, 1.2), .nice = true, .height = 200, .key = "stream" });
        defer a.end();
        s.plot = a.rect();
        a.draw(s, draw);
        s.pointer = a.pointer();
    }

    fn draw(s: *Stream, p: *ui.Painter, a: *const chart.PlotArea) void {
        var out: [800][2]f64 = undefined;
        const pts = chart.downsampleValues(&s.samples, @intFromFloat(@max(1, p.size.w)), &out);
        s.drawn = pts.len;
        chart.strokeSeries(p, a, pts, ui.Color.hex(0x0a84ff), 1.5);
    }
};

test "a plot of your own: axes around it, values under the pointer, a long series drawn from its extremes" {
    var s: Stream = .{};
    for (&s.samples, 0..) |*v, i| v.* = @sin(@as(f64, @floatFromInt(i)) / 40);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Stream.view), .{ .width = 480, .height = 300 });
    defer t.deinit();
    t.settle(1);
    // Rounded out to its ticks: -1.5 to 1.5 up the side, 0 to 5000 along.
    for ([_][]const u8{ "-1.0", "0.0", "1.0", "0", "5000" }) |tick| try testing.expect(t.hasText(tick));
    try testing.expect(t.findText("1.0").?.y < t.findText("-1.0").?.y);
    // Five thousand samples, two a pixel column at most.
    try testing.expect(s.drawn > 0 and s.drawn <= 2 * @as(usize, @intFromFloat(s.plot.w)) + 2);
    try testing.expectEqual(@as(usize, 1), t.text.images.decoded.count());
    // The pointer in the middle of the plot is at the middle values.
    const zero = t.findText("0.0").?;
    t.moveTo(zero.x + zero.w + 8 + s.plot.w / 2, zero.y + zero.h / 2);
    const v = s.pointer orelse return error.NoPointer;
    try testing.expectApproxEqAbs(@as(f64, 2500), v[0], 60);
    try testing.expectApproxEqAbs(@as(f64, 0), v[1], 0.05);
}
