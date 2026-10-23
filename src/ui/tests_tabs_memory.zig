//! Tabs must release owned allocations at teardown and keep only bounded
//! caches while switching pages or replacing the whole tab bar.
const std = @import("std");
const ui = @import("ui.zig");
const Key = @import("context.zig").Key;
const testing = std.testing;

const labels = [_][]const u8{ "General", "Appearance", "Advanced" };
const pages = [_][]const u8{
    "General settings for this workspace.",
    "Appearance settings for this workspace.",
    "Advanced settings for this workspace.",
};

const App = struct {
    selected: usize = 0,
    generation: usize = 0,
    show: bool = true,

    fn view(s: *App, c: *ui.Context) void {
        if (!s.show) return;
        c.keyed(s.generation);
        ui.column(c, .{ .width = .fill, .padding = .all(12), .gap = 8 });
        defer ui.end(c);
        _ = ui.tabs(c, &labels, &s.selected, .{});
        c.keyed(s.selected);
        ui.text(c, pages[s.selected], .{ .wrap = true });
    }
};

// With failure disabled this allocator counts actual bytes still owned,
// including successful resizes. The backing test allocator reports the
// allocation stack if anything is left after teardown.
fn liveBytes(tracked: *const testing.FailingAllocator) usize {
    return tracked.allocated_bytes - tracked.freed_bytes;
}

fn switchPages(t: *ui.Tester, s: *App, tracked: *const testing.FailingAllocator) !usize {
    var peak: usize = 0;
    for (0..120) |_| {
        for ([_]Key{ .home, .right, .right }, 0..) |key, selected| {
            t.key(key);
            try testing.expectEqual(selected, s.selected);
            try testing.expect(t.hasText(pages[selected]));
            peak = @max(peak, liveBytes(tracked));
        }
    }
    return peak;
}

test "tabs memory: repeated switching reaches a stable allocation ceiling" {
    var tracked: testing.FailingAllocator = .init(testing.allocator, .{});
    {
        var s: App = .{};
        var t: ui.Tester = undefined;
        try t.init(tracked.allocator(), .init(&s, App.view), .{});
        defer t.deinit();
        t.ctx.access.enabled = true;
        try t.clickText("General");
        // Warm the fonts, glyphs, layouts and both selected-label weights
        // before comparing equivalent batches of keyboard interactions.
        _ = try switchPages(&t, &s, &tracked);
        const ceiling = try switchPages(&t, &s, &tracked);
        for (0..4) |_| try testing.expect(try switchPages(&t, &s, &tracked) <= ceiling);
        t.settle(2);
        try testing.expect(!t.ctx.animating);
    }
    try testing.expectEqual(@as(usize, 0), liveBytes(&tracked));
}

test "tabs memory: replaced tab bars expire from animation and layout caches" {
    var tracked: testing.FailingAllocator = .init(testing.allocator, .{});
    {
        var s: App = .{};
        var t: ui.Tester = undefined;
        try t.init(tracked.allocator(), .init(&s, App.view), .{});
        defer t.deinit();
        t.ctx.access.enabled = true;
        for (0..720) |i| {
            // Fresh ids model opening and closing different documents.
            s.generation += 1;
            s.selected = i % labels.len;
            t.frame();
            // Two animations per label, with a 120-frame grace period
            // and sweeps every 120 frames; four texts swept every 60.
            try testing.expect(t.ctx.anims.count() <= 2 * labels.len * 240);
            try testing.expect(t.ctx.layout_cache.held.count() <= (labels.len + 1) * 64);
        }
        s.show = false;
        for (0..241) |_| t.frame();
        try testing.expectEqual(@as(u32, 0), t.ctx.anims.count());
        try testing.expectEqual(@as(u32, 0), t.ctx.layout_cache.held.count());
        try testing.expectEqual(@as(u32, 0), t.ctx.access.described.count());
    }
    try testing.expectEqual(@as(usize, 0), liveBytes(&tracked));
}

test "tabs memory: repeated view creation and teardown frees every allocation" {
    var tracked: testing.FailingAllocator = .init(testing.allocator, .{});
    for (0..8) |_| {
        {
            var s: App = .{};
            var t: ui.Tester = undefined;
            try t.init(tracked.allocator(), .init(&s, App.view), .{});
            defer t.deinit();
            t.ctx.access.enabled = true;
            for (labels, 0..) |label, selected| {
                try t.clickText(label);
                try testing.expectEqual(selected, s.selected);
            }
        }
        try testing.expectEqual(@as(usize, 0), liveBytes(&tracked));
    }
}
