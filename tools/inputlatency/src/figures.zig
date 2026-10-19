//! A run's figures: how a run hands them to the parent process (a line of
//! `name=value`), and the statistics of the runs (medians, percentiles).
const std = @import("std");

/// A run's figures, in milliseconds but `refresh` (Hz), `events` (a
/// count) and the percentages.
pub const Figures = struct {
    refresh: f64 = 0,
    events: f64 = 0,
    mean: f64 = 0,
    p50: f64 = 0,
    p90: f64 = 0,
    p99: f64 = 0,
    /// Means of what the latency is made of: waiting for the main thread,
    /// handling the event, from then to the frame's present, from the
    /// present to the screen.
    queue: f64 = 0,
    handle: f64 = 0,
    to_present: f64 = 0,
    to_screen: f64 = 0,
    /// The frames': the main thread's wait for drawables a frame (macOS),
    /// the percent of frames it waited over 4 ms, the percent of refreshes
    /// showing a new frame, and of frames presented and never shown.
    main_wait: f64 = 0,
    blocked: f64 = 0,
    new_frames: f64 = 0,
    not_shown: f64 = 0,

    pub const names = std.meta.fieldNames(Figures);

    /// The line a run prints: "figures refresh=120.000 events=300.000 ...".
    pub fn write(f: Figures, w: *std.Io.Writer) !void {
        try w.writeAll("figures");
        inline for (comptime names) |n| try w.print(" {s}={d:.3}", .{ n, @field(f, n) });
        try w.writeAll("\n");
    }

    /// The figures of the first "figures" line of a run's output.
    pub fn parse(out: []const u8) !Figures {
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (!std.mem.startsWith(u8, line, "figures ")) continue;
            var f: Figures = .{};
            var fields = std.mem.tokenizeScalar(u8, line["figures ".len..], ' ');
            while (fields.next()) |field| {
                const eq = std.mem.indexOfScalar(u8, field, '=') orelse return error.BadFigure;
                const v = std.fmt.parseFloat(f64, field[eq + 1 ..]) catch return error.BadFigure;
                if (!set(&f, field[0..eq], v)) return error.BadFigure;
            }
            return f;
        }
        return error.NoFigures;
    }

    fn set(f: *Figures, name: []const u8, v: f64) bool {
        inline for (comptime names) |n| if (std.mem.eql(u8, n, name)) {
            @field(f, n) = v;
            return true;
        };
        return false;
    }

    /// The summary a person reads.
    pub fn format(f: Figures, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("mean {d:5.1}  p50 {d:5.1}  p90 {d:5.1}  p99 {d:5.1} ms | queue {d:3.1}  handle {d:3.1}  to present {d:4.1}  to screen {d:4.1}", .{
            f.mean, f.p50, f.p90, f.p99, f.queue, f.handle, f.to_present, f.to_screen,
        });
        try w.print(" | main waits {d:4.2} ms a frame, {d:4.1}% over 4 ms | {d:5.1}% of refreshes new, {d:3.1}% not shown | {d:.0} Hz, {d:.0} events", .{
            f.main_wait, f.blocked, f.new_frames, f.not_shown, f.refresh, f.events,
        });
    }

    /// Each figure the median of the runs'.
    pub fn medianOf(all: []const Figures, scratch: []f64) Figures {
        var m: Figures = .{};
        inline for (comptime names) |n| {
            const xs = scratch[0..all.len];
            for (all, xs) |f, *x| x.* = @field(f, n);
            @field(m, n) = median(xs);
        }
        return m;
    }
};

/// The median of `xs`, which it sorts; 0 for none.
pub fn median(xs: []f64) f64 {
    if (xs.len == 0) return 0;
    std.mem.sort(f64, xs, {}, std.sort.asc(f64));
    const n = xs.len;
    return if (n % 2 == 0) (xs[n / 2 - 1] + xs[n / 2]) / 2 else xs[n / 2];
}

/// The `p`-th (0 to 1) of `sorted`, as the nearest rank below; 0 for none.
pub fn percentile(sorted: []const f64, p: f64) f64 {
    if (sorted.len == 0) return 0;
    const i: usize = @intFromFloat(p * @as(f64, @floatFromInt(sorted.len - 1)));
    return sorted[i];
}

test "a run's line reads back as its figures" {
    const f: Figures = .{ .refresh = 120, .events = 300, .mean = 27.25, .p99 = 41.5, .to_screen = 18.125, .new_frames = 99.5 };
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try f.write(&w);
    const out = w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "figures refresh=120.000 events=300.000 mean=27.250"));
    var with: [1100]u8 = undefined;
    const back = try Figures.parse(try std.fmt.bufPrint(&with, "warming up\r\n{s}", .{out}));
    try std.testing.expectEqual(f, back);
    try std.testing.expectError(error.NoFigures, Figures.parse("nothing here\n"));
    try std.testing.expectError(error.BadFigure, Figures.parse("figures mean=x\n"));
    try std.testing.expectError(error.BadFigure, Figures.parse("figures speed=1\n"));
}

test "medians and percentiles" {
    var odd = [_]f64{ 5, 1, 3 };
    try std.testing.expectEqual(@as(f64, 3), median(&odd));
    var even = [_]f64{ 4, 1, 3, 2 };
    try std.testing.expectEqual(@as(f64, 2.5), median(&even));
    try std.testing.expectEqual(@as(f64, 0), median(&.{}));
    const sorted = [_]f64{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 };
    try std.testing.expectEqual(@as(f64, 50), percentile(&sorted, 0.5));
    try std.testing.expectEqual(@as(f64, 90), percentile(&sorted, 0.9));
    try std.testing.expectEqual(@as(f64, 90), percentile(&sorted, 0.99));
    try std.testing.expectEqual(@as(f64, 100), percentile(&sorted, 1));
    const runs = [_]Figures{ .{ .mean = 30, .events = 300 }, .{ .mean = 20, .events = 290 }, .{ .mean = 25, .events = 310 } };
    var scratch: [3]f64 = undefined;
    const m = Figures.medianOf(&runs, &scratch);
    try std.testing.expectEqual(@as(f64, 25), m.mean);
    try std.testing.expectEqual(@as(f64, 300), m.events);
}
