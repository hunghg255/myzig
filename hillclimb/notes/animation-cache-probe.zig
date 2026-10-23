//! Headless virtual-list allocation probe; see the accompanying notes.
const std = @import("std");
const ui = @import("myzig").ui;

const List = struct {
    frame: usize = 0,
    show: bool = true,

    fn view(s: *List, c: *ui.Context) void {
        if (!s.show) return;
        const row = s.frame * 3;
        var it = ui.list(c, .{ .count = 100_000, .row_height = 40, .scroll_to = @as(f32, @floatFromInt(row)) * 40 });
        while (it.next()) |i| {
            ui.row(c, .{ .width = .fill, .height = .{ .px = 40 }, .gap = 8 });
            ui.textf(c, .{ .size = 13 }, "Row {d}", .{i});
            _ = ui.button(c, "Open", .{});
            ui.end(c);
        }
        it.end();
    }
};

fn report(t: *ui.Tester, tracked: *std.testing.FailingAllocator, frame: usize) void {
    var expired: usize = 0;
    var it = t.ctx.anims.valueIterator();
    while (it.next()) |v| {
        if (t.ctx.frame - v.frame > 120) expired += 1;
    }
    std.debug.print("frames={d} nodes={d} animations={d} expired={d} capacity={d} live_bytes={d}\n", .{
        frame,                  t.ctx.nodes.items.len,                         t.ctx.anims.count(), expired,
        t.ctx.anims.capacity(), tracked.allocated_bytes - tracked.freed_bytes,
    });
}

pub fn main(init: std.process.Init) !void {
    var tracked: std.testing.FailingAllocator = .init(init.gpa, .{});
    const gpa = tracked.allocator();
    {
        var s: List = .{};
        var t: ui.Tester = undefined;
        try t.init(gpa, .init(&s, List.view), .{ .width = 900, .height = 640 });
        defer t.deinit();
        var timings: [6000]f64 = undefined;
        report(&t, &tracked, 0);
        for (&timings, 0..) |*ms, frame| {
            s.frame = frame;
            const start = ui.clock.now();
            t.frame();
            ms.* = (ui.clock.now() - start) * 1000;
            if ((frame + 1) % 600 == 0) report(&t, &tracked, frame + 1);
        }
        std.mem.sort(f64, &timings, {}, std.sort.asc(f64));
        std.debug.print("median_ms={d:.4} p95_ms={d:.4} p99_ms={d:.4}\n", .{ timings[3000], timings[5700], timings[5940] });
        s.show = false;
        for (0..1200) |_| t.frame();
        report(&t, &tracked, 7200);
    }
    std.debug.assert(tracked.allocated_bytes == tracked.freed_bytes);
}
