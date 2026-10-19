//! A box following its end with a glide (`Style.follow_glide`), after
//! mygo's review_follow_test.go: on the frame its content changes, a child
//! that stays shows where it showed, then glides to its place; content
//! that fits with `justify = .start`, or a box as tall as its content,
//! moves nothing.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const types = @import("types.zig");

const smooth: @import("follow_glide.zig").FollowGlide = .of(.smooth);

const Chat = struct {
    n: usize,
    last: f32,
    row_h: f32 = 40,
    justify: types.Justify = .start,
    /// Above 0: the box is as tall as its content, up to this (in a column
    /// under a title); below 0, with no limit.
    hug: f32 = 0,
    /// A composer's height under the box.
    below: f32 = 0,
    glide: bool = true,
    ids: [64]u64 = undefined,
    box: u64 = 0,

    fn view(s: *Chat, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = if (s.hug != 0) .all(14) else .{}, .gap = if (s.hug != 0) 10 else 0 });
        defer ui.end(c);
        if (s.hug != 0) ui.text(c, "Chat", .{});
        const style: types.Style = .{
            .width = .fill,
            .height = if (s.hug != 0) .auto else .fill,
            .max_height = if (s.hug > 0) s.hug else if (s.hug < 0) 1e5 else std.math.inf(f32),
            .gap = if (s.hug != 0) 8 else 0,
            .padding = if (s.hug != 0) .all(10) else .{},
            .justify = s.justify,
            .scroll = true,
            .follow_end = true,
            .follow_glide = if (s.glide) &smooth else null,
        };
        const box = c.open(style, "chat");
        s.box = c.node(box).id;
        for (0..s.n) |i| {
            c.next_key_int = i;
            const h = if (i == s.n - 1) s.last else s.row_h;
            const r = c.leaf(.{ .width = .fill, .height = .{ .px = h } }, .none, null);
            s.ids[i] = c.node(r).id;
        }
        c.end();
        if (s.below > 0) _ = c.leaf(.{ .width = .fill, .height = .{ .px = s.below } }, .none, "composer");
    }

    fn rect(s: *const Chat, t: *ui.Tester, i: usize) types.Rect {
        return t.ctx.rects.get(s.ids[i]).?;
    }

    fn lag(s: *const Chat, t: *ui.Tester) f64 {
        return if (t.ctx.follow_glides.get(s.box)) |g| g.lag.value else 0;
    }
};

const Case = struct {
    name: []const u8,
    rows: usize,
    from: f32,
    to: f32,
    /// A row of height `to` comes after the last.
    add: bool = false,
    justify: types.Justify = .start,
    /// How far the row that stays moves, once settled.
    glide: f32,
    hug: f32 = 0,
};

test "a box gliding to its end leaves the rows that stay where they show, then glides them to their place" {
    const cases = [_]Case{
        .{ .name = "fit start grow", .rows = 3, .from = 40, .to = 100, .glide = 0 },
        .{ .name = "fit start add", .rows = 3, .from = 40, .to = 40, .add = true, .glide = 0 },
        .{ .name = "fit end grow", .rows = 3, .from = 40, .to = 100, .justify = .end, .glide = -60 },
        .{ .name = "fit center grow", .rows = 3, .from = 40, .to = 100, .justify = .center, .glide = -30 },
        .{ .name = "start to overflow", .rows = 9, .from = 40, .to = 100, .glide = -20 },
        .{ .name = "overflow grow", .rows = 20, .from = 40, .to = 100, .glide = -60 },
        .{ .name = "overflow add", .rows = 20, .from = 40, .to = 40, .add = true, .glide = -40 },
        .{ .name = "overflow to fit", .rows = 10, .from = 300, .to = 40, .glide = 260 },
        .{ .name = "overflow to fit, far", .rows = 5, .from = 500, .to = 40, .glide = 260 },
        .{ .name = "hug start grow", .rows = 3, .from = 44, .to = 66, .glide = 0, .hug = -1 },
        .{ .name = "hug start add", .rows = 3, .from = 44, .to = 44, .add = true, .glide = 0, .hug = -1 },
        .{ .name = "hug end grow", .rows = 3, .from = 44, .to = 66, .justify = .end, .glide = 0, .hug = -1 },
        .{ .name = "hug center grow", .rows = 3, .from = 44, .to = 66, .justify = .center, .glide = 0, .hug = -1 },
        .{ .name = "hug start shrink", .rows = 3, .from = 88, .to = 44, .glide = 0, .hug = -1 },
        .{ .name = "hug end shrink", .rows = 3, .from = 88, .to = 44, .justify = .end, .glide = 0, .hug = -1 },
        .{ .name = "hug to its max height", .rows = 3, .from = 44, .to = 110, .glide = -34, .hug = 200 },
    };
    for (cases) |tc| {
        errdefer std.debug.print("case {s}\n", .{tc.name});
        var s: Chat = .{ .n = tc.rows, .last = tc.from, .row_h = if (tc.hug != 0) 44 else 40, .justify = tc.justify, .hug = tc.hug };
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&s, Chat.view), .{ .width = 300, .height = 400 });
        defer t.deinit();
        t.dt = 0;
        t.frame();
        t.frame();
        const stay = tc.rows - 2;
        const before = s.rect(&t, stay);
        if (tc.add) s.n += 1;
        s.last = tc.to;
        t.frame();
        try testing.expectEqual(before.y, s.rect(&t, stay).y);
        t.dt = 0.05;
        t.frame();
        t.dt = 0;
        t.frame();
        const moved = s.rect(&t, stay).y - before.y;
        if (tc.glide == 0) {
            try testing.expectEqual(@as(f32, 0), moved);
        } else try testing.expect(moved * tc.glide > 0 and @abs(moved) < @abs(tc.glide));
        t.dt = 2;
        t.frame();
        t.dt = 0;
        t.frame();
        try testing.expectApproxEqAbs(before.y + tc.glide, s.rect(&t, stay).y, 0.01);
        if (tc.rows > 9) {
            const r = s.rect(&t, s.n - 1);
            try testing.expectApproxEqAbs(@as(f32, 400), r.y + r.h, 0.01);
        }
        try testing.expect(t.ctx.scroll_follow.get(s.box) orelse true);
    }
}

test "a box as tall as its content, its last row streaming, keeps the rows above it where they are" {
    var s: Chat = .{ .n = 3, .last = 44, .row_h = 44, .hug = -1 };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Chat.view), .{ .width = 300, .height = 400 });
    defer t.deinit();
    t.frame();
    const before = s.rect(&t, 1);
    for (0..8) |_| {
        s.last += 22;
        t.frame();
        try testing.expectEqual(before.y, s.rect(&t, 1).y);
    }
}

test "a box made shorter by a composer below shows its end at once" {
    var s: Chat = .{ .n = 30, .last = 40 };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Chat.view), .{ .width = 300, .height = 400 });
    defer t.deinit();
    t.frame();
    var r = s.rect(&t, s.n - 1);
    try testing.expectEqual(@as(f32, 400), r.y + r.h);
    s.below = 100;
    t.frame();
    r = s.rect(&t, s.n - 1);
    try testing.expectEqual(@as(f32, 300), r.y + r.h);
}

test "the last row shrinking back or going while the box glides leaves the rows in place" {
    var s: Chat = .{ .n = 30, .last = 40 };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Chat.view), .{ .width = 300, .height = 400 });
    defer t.deinit();
    t.dt = 0;
    t.frame();
    s.last = 300;
    t.frame();
    t.dt = 0.05;
    t.frame();
    const before = s.rect(&t, s.n - 2);
    s.last = 40;
    t.dt = 0.001;
    t.frame();
    // The rows above it stay where they show, then go down to their place.
    try testing.expect(s.rect(&t, s.n - 2).y <= before.y + 1);
    t.dt = 2;
    t.frame();
    t.dt = 0;
    t.frame();
    var r = s.rect(&t, s.n - 1);
    try testing.expectApproxEqAbs(@as(f32, 400), r.y + r.h, 0.01);
    // A row comes and goes on its way: the rows show in place.
    s.n += 1;
    s.last = 200;
    t.frame();
    t.dt = 0.05;
    t.frame();
    s.n -= 1;
    s.last = 40;
    t.dt = 0.001;
    t.frame();
    r = s.rect(&t, s.n - 1);
    try testing.expectApproxEqAbs(@as(f32, 400), r.y + r.h, 0.01);
    try testing.expectEqual(@as(f64, 0), s.lag(&t));
}

test "a box that doesn't change doesn't glide, and without a glide the end shows at once" {
    var s: Chat = .{ .n = 30, .last = 40 };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Chat.view), .{ .width = 300, .height = 400 });
    defer t.deinit();
    for (0..5) |_| {
        t.frame();
        try testing.expectEqual(@as(f64, 0), s.lag(&t));
    }
    s.glide = false;
    s.n += 1;
    t.frame();
    const r = s.rect(&t, s.n - 1);
    try testing.expectEqual(@as(f32, 400), r.y + r.h);
}

test "a list following its end glides as rows come, and builds the rows its glide shows" {
    const S = struct {
        n: usize = 40,
        shown: usize = 0,
        fn view(s: *@This(), c: *ui.Context) void {
            var rows = ui.list(c, .{ .count = s.n, .row_height = 30, .follow_end = true, .follow_glide = &smooth });
            s.shown = 0;
            while (rows.next()) |_| {
                _ = c.leaf(.{ .width = .fill, .height = .{ .px = 30 } }, .none, null);
                s.shown += 1;
            }
            rows.end();
        }
    };
    var s: S = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, S.view), .{ .width = 200, .height = 300 });
    defer t.deinit();
    t.frame();
    const base = s.shown;
    s.n += 8;
    t.dt = 0;
    t.frame();
    t.frame();
    // Eight rows came: the view shows the rows above them still.
    try testing.expect(s.shown >= base + 8);
    t.dt = 1.0 / 60.0;
    t.settle(3);
    try testing.expect(!t.ctx.animating);
}
