//! What layout keeps across frames and measures once a frame
//! (`layout_cache.zig`, `Node.measured_at`) lays out as laying everything
//! out anew does: random trees of rows, columns, wrapping and single-line
//! texts, growing and stretched boxes, changing at random frame after
//! frame, laid out with and without (`Cache.off`), box for box.
const std = @import("std");
const ui = @import("ui.zig");
const testing = std.testing;

const words = [_][]const u8{ "a", "word", "longer words", "a sentence that wraps when it is narrow", "x", "", "twelve chars" };

const Tree = struct {
    seed: u64,
    frame: u64 = 0,
    width: f32 = 400,

    fn view(s: *Tree, c: *ui.Context) void {
        var prng: std.Random.DefaultPrng = .init(s.seed);
        const r = prng.random();
        // Each frame, a tenth of the texts change.
        var change: std.Random.DefaultPrng = .init(s.seed ^ (s.frame *% 0x9e3779b97f4a7c15));
        _ = c.open(.{ .width = .{ .px = s.width }, .align_items = .stretch }, null);
        box(c, r, change.random(), 0);
        c.end();
    }

    fn box(c: *ui.Context, r: std.Random, ch: std.Random, depth: u32) void {
        const n = r.intRangeAtMost(u32, 1, if (depth > 3) 1 else 4);
        for (0..n) |_| {
            const kind = r.intRangeAtMost(u8, 0, 5);
            if (depth < 5 and kind < 3) {
                const row = r.boolean();
                _ = c.open(.{
                    .direction = if (row) .row else .column,
                    .gap = @floatFromInt(r.intRangeAtMost(u8, 0, 8)),
                    .padding = .all(@floatFromInt(r.intRangeAtMost(u8, 0, 6))),
                    .grow = if (r.intRangeAtMost(u8, 0, 3) == 0) 1 else 0,
                    .align_items = r.enumValue(@import("types.zig").Align),
                    .min_width = if (r.intRangeAtMost(u8, 0, 5) == 0) 40 else 0,
                    .max_width = if (r.intRangeAtMost(u8, 0, 5) == 0) 120 else std.math.inf(f32),
                }, null);
                box(c, r, ch, depth + 1);
                c.end();
            } else {
                var w = words[r.uintLessThan(usize, words.len)];
                if (ch.intRangeAtMost(u8, 0, 9) == 0) w = words[ch.uintLessThan(usize, words.len)];
                _ = c.leaf(.{ .grow = if (r.boolean()) 1 else 0, .padding = .xy(@floatFromInt(r.intRangeAtMost(u8, 0, 4)), 0) }, .{ .text = .{
                    .str = w,
                    .style = .{ .size = @floatFromInt(r.intRangeAtMost(u8, 11, 16)), .wrap = r.boolean() },
                    .color = c.theme.text,
                } }, null);
            }
        }
    }
};

test "layout cache: random trees changing frame after frame lay out as anew" {
    for (0..12) |seed| {
        var a: Tree = .{ .seed = seed };
        var b: Tree = .{ .seed = seed };
        var ta: ui.Tester = undefined;
        var tb: ui.Tester = undefined;
        try ta.init(testing.allocator, .init(&a, Tree.view), .{ .width = 420, .height = 600 });
        defer ta.deinit();
        try tb.init(testing.allocator, .init(&b, Tree.view), .{ .width = 420, .height = 600 });
        defer tb.deinit();
        tb.ctx.layout_cache.off = true;
        for (0..20) |f| {
            a.frame = f;
            b.frame = f;
            // Now and then narrower: wraps at other widths.
            a.width = if (f % 7 == 3) 260 else 400;
            b.width = a.width;
            ta.frame();
            tb.frame();
            try testing.expectEqual(ta.ctx.nodes.items.len, tb.ctx.nodes.items.len);
            for (ta.ctx.nodes.items, tb.ctx.nodes.items) |x, y| {
                try testing.expectEqual(x.id, y.id);
                try testing.expectEqual(x.rect, y.rect);
            }
        }
    }
}

const Counter = struct {
    n: u32 = 0,
    fn view(s: *Counter, c: *ui.Context) void {
        ui.column(c, .{});
        defer ui.end(c);
        ui.textf(c, .{}, "{d}", .{s.n});
        ui.text(c, "unchanged", .{ .wrap = true });
    }
};

test "layout cache: a text changing every frame keeps its buffers; unchanged ones are kept" {
    var s: Counter = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Counter.view), .{});
    defer t.deinit();
    for (0..5) |i| {
        s.n = @intCast(i * 1111);
        t.frame();
    }
    try testing.expectEqual(@as(u32, 2), t.ctx.layout_cache.held.count());
    const w = t.findText("4444").?.w;
    try testing.expectApproxEqAbs(@ceil(t.text.width("4444", .{})), w, 0.01);
    // A change of zoom forgets what was kept, and measures anew.
    t.ctx.setZoom(2);
    t.frame();
    try testing.expectApproxEqAbs(@ceil(t.text.width("4444", .{})), t.findText("4444").?.w, 0.01);
    try testing.expect(t.findText("4444").?.w > w * 1.5);
}

const Scrolling = struct {
    row: usize = 0,

    fn view(s: *Scrolling, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        ui.text(c, "kept across sweeps", .{ .wrap = true });
        var rows = ui.list(c, .{ .count = 100_000, .row_height = 28, .scroll_to = @as(f32, @floatFromInt(s.row)) * 28 });
        while (rows.next()) |i| {
            ui.row(c, .{ .width = .fill, .height = .{ .px = 28 } });
            ui.textf(c, .{}, "Row {d}", .{i});
            ui.textf(c, .{}, "Value {d}", .{i * 7});
            ui.end(c);
        }
        rows.end();
    }
};

// Scroll far enough between sweeps to expire more than 256 texts. Expired
// entries must all go, while live buffers and the uncached layout agree.
test "layout cache: scrolling evicts every expired text and keeps live wraps" {
    var s: Scrolling = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scrolling.view), .{});
    defer t.deinit();
    var reference: ui.Tester = undefined;
    try reference.init(testing.allocator, .init(&s, Scrolling.view), .{});
    defer reference.deinit();
    reference.ctx.layout_cache.off = true;
    const id = t.ctx.nodes.items[2].id;
    const kept = t.ctx.layout_cache.held.get(id).?;
    try testing.expectEqualStrings("kept across sweeps", kept.str.items);
    for (0..180) |f| {
        s.row = f * 12;
        const frame = t.ctx.frame;
        t.frame();
        reference.frame();
        try testing.expectEqual(t.ctx.nodes.items.len, reference.ctx.nodes.items.len);
        for (t.ctx.nodes.items, reference.ctx.nodes.items) |a, b| {
            try testing.expectEqual(a.rect, b.rect);
        }
        const live = t.ctx.layout_cache.held.get(id).?;
        try testing.expectEqual(kept.str.items.ptr, live.str.items.ptr);
        try testing.expectEqual(kept.wraps[0].lines.items.ptr, live.wraps[0].lines.items.ptr);
        if (frame % 60 == 0) {
            var it = t.ctx.layout_cache.held.valueIterator();
            while (it.next()) |entry| try testing.expect(entry.frame + 2 >= frame);
        }
    }
}

// Even without scratch memory, a sweep makes progress without discarding
// the text still in view or leaking the entries it removes.
test "layout cache: scratch allocation failure still evicts old texts" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var s: Scrolling = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scrolling.view), .{});
    defer t.deinit();
    for (0..59) |f| {
        s.row = f * 12;
        t.frame();
    }
    const before = t.ctx.layout_cache.held.count();
    try testing.expect(before > 256);
    const id = t.ctx.nodes.items[2].id;
    const kept = t.ctx.layout_cache.held.get(id).?.str.items;
    t.ctx.arena.deinit();
    t.ctx.arena = .init(failing.allocator());
    @import("layout_cache.zig").beginFrame(&t.ctx);
    try testing.expect(failing.has_induced_failure);
    try testing.expect(t.ctx.layout_cache.held.count() < before);
    try testing.expectEqual(kept.ptr, t.ctx.layout_cache.held.get(id).?.str.items.ptr);
}
