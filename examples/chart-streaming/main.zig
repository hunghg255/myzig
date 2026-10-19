//! Three rolling waveforms of 15 000 samples each, 1 000 new samples a
//! second, reduced to the extremes of each pixel column before they are
//! stroked (`--mode=raw` strokes every sample).
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const chart = ui.chart;

const samples = 15_000;
const colors = [3]ui.Color{ .hex(0x288cf0), .hex(0xf06446), .hex(0x32be6e) };

/// A sample of series `s`: deterministic noise and isolated spikes, which
/// the reduction keeps.
fn value(i: i64, s: usize) f32 {
    const x: f64 = @as(f64, @floatFromInt(i)) / 1000;
    const sf: f64 = @floatFromInt(s);
    const n = @as(u64, @bitCast(i)) *% 6364136223846793005 +% (@as(u64, s) + 1) *% 1442695040888963407;
    var v = 0.22 * @sin(x * (sf + 1) * 7) + 0.08 * (@as(f64, @floatFromInt(n >> 48)) / 65535 - 0.5);
    if (@mod(i, 997) == @as(i64, @intCast(s * 31))) v += 0.22;
    return @floatCast(0.2 + sf * 0.3 + v * 0.55);
}

const Waveform = struct {
    data: [3][samples]f32 = undefined,
    next: i64 = samples,
    xs: [samples]f32 = undefined,
    ys: [3][samples]f32 = undefined,
    /// The reduced series, made again every frame into the same memory.
    bucket_x: [3]std.ArrayList(f32) = @splat(.empty),
    bucket_y: [3]std.ArrayList(f32) = @splat(.empty),
    gpa: std.mem.Allocator,
    raw: bool = false,

    fn init(w: *Waveform) void {
        for (0..3) |k| for (0..samples) |i| {
            w.data[k][i] = value(@intCast(i), k);
        };
    }

    fn deinit(w: *Waveform) void {
        for (&w.bucket_x, &w.bucket_y) |*a, *b| {
            a.deinit(w.gpa);
            b.deinit(w.gpa);
        }
    }

    /// Fills the ring with the samples due by `seconds`, and lays out the
    /// latest 15 000 as fractions of the plot.
    fn update(w: *Waveform, seconds: f64) void {
        const ms: i64 = @intFromFloat(seconds * 1000);
        const target: i64 = samples + ms;
        // After a long frame, only the samples still visible are made.
        var i = @max(w.next, target - samples);
        while (i < target) : (i += 1) for (0..3) |k| {
            w.data[k][@intCast(@mod(i, samples))] = value(i, k);
        };
        w.next = target;
        const phase: f32 = @floatCast(seconds * 1000 - @floor(seconds * 1000));
        for (0..samples) |j| {
            w.xs[j] = (@as(f32, @floatFromInt(j)) - phase) / (samples - 1);
            for (0..3) |k| w.ys[k][j] = w.data[k][@intCast(@mod(target - samples + @as(i64, @intCast(j)), samples))];
        }
    }

    /// Keeps the lowest and highest sample of each of `columns` columns,
    /// in the order they come.
    fn minMax(w: *Waveform, k: usize, columns: usize) void {
        const bx = &w.bucket_x[k];
        const by = &w.bucket_y[k];
        bx.clearRetainingCapacity();
        by.clearRetainingCapacity();
        const ys = &w.ys[k];
        var start: usize = 0;
        for (0..columns) |col| {
            const end = @min(samples, (col + 1) * samples / columns);
            if (end <= start) continue;
            var lo = start;
            var hi = start;
            for (start..end) |j| {
                if (ys[j] < ys[lo]) lo = j;
                if (ys[j] > ys[hi]) hi = j;
            }
            const a = @min(lo, hi);
            const b = @max(lo, hi);
            bx.append(w.gpa, w.xs[a]) catch return;
            by.append(w.gpa, ys[a]) catch return;
            if (b != a) {
                bx.append(w.gpa, w.xs[b]) catch return;
                by.append(w.gpa, ys[b]) catch return;
            }
            start = end;
        }
    }

    fn draw(w: *Waveform, p: *ui.Painter) void {
        const r: ui.Rect = .{ .w = p.size.w, .h = p.size.h };
        const th_border: ui.Color = .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 0.3 };
        for (0..6) |t| {
            const yy = chart.y(r, @as(f32, @floatFromInt(t)) / 5);
            p.line(0, yy, r.w, yy, 1, th_border);
        }
        p.clipRect(r);
        const columns: usize = @intFromFloat(@ceil(r.w * p.scale));
        for (0..3) |k| {
            var path = p.path();
            if (w.raw) {
                chart.line(&path, r, &w.xs, &w.ys[k], .linear);
            } else {
                w.minMax(k, columns);
                chart.line(&path, r, w.bucket_x[k].items, w.bucket_y[k].items, .linear);
            }
            p.stroke(&path, .color(colors[k]), .{ .width = 2, .join = .round });
        }
    }

    fn view(w: *Waveform, c: *ui.Context) void {
        w.update(c.time);
        c.animationFrame();
        const th = c.theme;
        const ts: ui.TextStyle = .{ .size = 11 };
        const lh = c.text.lineHeight(ts);
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(8), .gap = 8 });
        defer ui.end(c);
        ui.text(c, "Three live waveforms", .{ .weight = .semibold });
        ui.text(c, "15 seconds at 1000 samples per second per series", .{ .size = 12, .color = th.muted });
        // The plot, with room for the axes' labels left of it and below.
        const area = c.open(.{ .width = .fill, .grow = 1, .padding = .{ .left = 40, .bottom = lh + 6, .top = 6, .right = 8 } }, "plot");
        defer c.end();
        const r = c.rects.get(c.node(area).id) orelse ui.Rect{};
        const pw = @max(0, r.w - 48);
        const ph = @max(0, r.h - lh - 12);
        _ = ui.canvas(c, .{}, .{}, w, draw);
        const y_ticks = chart.Linear.init(0, 1).ticks(c.alloc(), 5) catch &.{};
        for (y_ticks) |t| {
            const tw = c.text.width(t.label, ts);
            _ = c.leaf(.{ .absolute = true, .offset = .{ .x = -tw - 8, .y = ph * (1 - t.at) - lh / 2 } }, .{ .text = .{ .str = t.label, .style = ts, .color = th.muted } }, null);
        }
        const x_ticks = chart.Linear.init(-15, 0).ticks(c.alloc(), 5) catch &.{};
        for (x_ticks) |t| {
            const tw = c.text.width(t.label, ts);
            _ = c.leaf(.{ .absolute = true, .offset = .{ .x = pw * t.at - tw / 2, .y = ph + 6 } }, .{ .text = .{ .str = t.label, .style = ts, .color = th.muted } }, null);
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Streaming chart" });
    defer app.destroy();
    const w = try init.gpa.create(Waveform);
    defer init.gpa.destroy(w);
    w.* = .{ .gpa = init.gpa };
    defer w.deinit();
    for (try init.minimal.args.toSlice(init.arena.allocator())) |arg| {
        if (std.mem.eql(u8, arg, "--mode=raw")) w.raw = true;
    }
    w.init();
    _ = try app.newWindow(.{
        .title = "Streaming chart",
        .width = 1000,
        .height = 600,
        .content = .{ .view = .init(w, Waveform.view) },
    });
    try app.run();
}
