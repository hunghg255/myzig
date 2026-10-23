//! Headless live-allocation probe for layout-cache-memory-2026-10-22.md.
//! Counts requested Zig allocations, not process working set or native API memory.
const std = @import("std");
const ui = @import("myzig").ui;

const List = struct {
    frame: usize = 0,

    fn view(s: *List, c: *ui.Context) void {
        const row = (s.frame * 3) % (100_000 - 40);
        var it = ui.list(c, .{ .count = 100_000, .row_height = 28, .scroll_to = @as(f32, @floatFromInt(row)) * 28 });
        while (it.next()) |i| {
            ui.row(c, .{ .width = .fill, .height = .{ .px = 28 }, .gap = 8 });
            ui.textf(c, .{ .size = 13 }, "Row {d} - a line of a long list", .{i});
            ui.spacer(c);
            ui.textf(c, .{ .size = 12 }, "{d}", .{i * 7 % 100});
            ui.end(c);
        }
        it.end();
    }
};

pub fn main(init: std.process.Init) !void {
    // With no failure configured, FailingAllocator forwards every operation
    // and counts successful allocations, frees, resizes and remaps.
    var tracked: std.testing.FailingAllocator = .init(init.gpa, .{});
    {
        var s: List = .{};
        var t: ui.Tester = undefined;
        try t.init(tracked.allocator(), .init(&s, List.view), .{ .width = 900, .height = 640 });
        defer t.deinit();
        var timings: [6000]f64 = undefined;
        var peak: usize = 0;
        for (0..timings.len) |frame| {
            s.frame = frame;
            const start = ui.clock.now();
            t.frame();
            timings[frame] = (ui.clock.now() - start) * 1000;
            const live = tracked.allocated_bytes - tracked.freed_bytes;
            peak = @max(peak, live);
            if ((frame + 1) % 600 == 0) {
                std.debug.print("list frames={d} nodes={d} cache_entries={d} cache_capacity={d} live_bytes={d}\n", .{
                    frame + 1, t.ctx.nodes.items.len, t.ctx.layout_cache.held.count(), t.ctx.layout_cache.held.capacity(), live,
                });
            }
        }
        std.mem.sort(f64, &timings, {}, std.sort.asc(f64));
        std.debug.print("list median_ms={d:.4} p95_ms={d:.4} p99_ms={d:.4} peak_frame_boundary_bytes={d}\n", .{ timings[3000], timings[5700], timings[5940], peak });
    }
    std.debug.assert(tracked.allocated_bytes == tracked.freed_bytes);
}
