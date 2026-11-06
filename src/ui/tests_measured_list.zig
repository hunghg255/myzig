const std = @import("std");
const ui = @import("ui.zig");
const testing = std.testing;

/// Rows taller the further their index is along a cycle of three.
fn heightOf(i: usize) f32 {
    return switch (i % 3) {
        0 => 20,
        1 => 60,
        else => 140,
    };
}

const App = struct {
    list: ui.MeasuredListState = .{},
    count: usize = 10_000,
    estimate: f32 = 44,
    gap: f32 = 0,
    padding: ui.Edges = .{},
    follow: bool = false,
    /// The rows built by the last frame's last pass.
    built: usize = 0,
    grown: ?usize = null,
    wrapped: ?[]const u8 = null,

    fn view(s: *App, c: *ui.Context) void {
        var rows = ui.measuredList(c, &s.list, .{ .count = s.count, .estimate = s.estimate, .gap = s.gap, .padding = s.padding, .follow_end = s.follow });
        s.built = 0;
        while (rows.next()) |i| {
            s.built += 1;
            if (s.wrapped) |text| {
                ui.text(c, text, .{ .wrap = true });
                continue;
            }
            const h = if (s.grown == i) 300 else heightOf(i);
            ui.column(c, .{ .width = .fill, .height = .{ .px = h } });
            ui.text(c, c.print("row {d}", .{i}), .{});
            ui.end(c);
        }
        rows.end();
    }

    fn deinit(s: *App) void {
        s.list.deinit(testing.allocator);
    }
};

fn start(t: *ui.Tester, s: *App) !void {
    try t.init(testing.allocator, .init(s, App.view), .{ .width = 400, .height = 400 });
    t.frame();
    t.frame();
}

/// The row at the top of the view, as what is on screen says.
fn topOf(t: *ui.Tester, row: usize) !f32 {
    var buf: [32]u8 = undefined;
    const r = t.findText(try std.fmt.bufPrint(&buf, "row {d}", .{row})) orelse return error.NotBuilt;
    return r.y;
}

test "a measured list places rows of different heights and stops as the view fills" {
    var s: App = .{};
    defer s.deinit();
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    try testing.expectEqual(@as(f32, 0), try topOf(&t, 0));
    try testing.expectEqual(@as(f32, 20), try topOf(&t, 1));
    try testing.expectEqual(@as(f32, 80), try topOf(&t, 2));
    try testing.expectEqual(@as(f32, 220), try topOf(&t, 3));
    // A screenful and the rows past it, not ten thousand.
    try testing.expect(s.built < 12);
    try testing.expect(t.hasText("row 5"));
    try testing.expect(!t.hasText("row 40"));
}

test "a measured list shows the rows at any scroll, and the rows above keep their place" {
    var s: App = .{};
    defer s.deinit();
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    t.scroll(200, 200, -30_000);
    t.frame();
    // Rows lie end to end, by their real heights, wherever the jump went.
    const anchor = s.list.anchor;
    const a = try topOf(&t, anchor);
    const b = try topOf(&t, anchor + 1);
    try testing.expectEqual(heightOf(anchor), b - a);
    try testing.expect(a <= 0);
    try testing.expect(s.built < 14);
    // Nothing moves as nothing is touched.
    t.frame();
    try testing.expectEqual(a, try topOf(&t, anchor));
}

test "a measured list keeps the reader's row in place as rows above turn out other sizes" {
    var s: App = .{ .estimate = 500 };
    defer s.deinit();
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    t.scroll(200, 200, -50_000);
    t.frame();
    const row = s.list.anchor + 1;
    const at = try topOf(&t, row);
    // Up by a little: rows just above come in, shorter than their estimate.
    t.scroll(200, 200, 30);
    t.frame();
    try testing.expectApproxEqAbs(at + 30, try topOf(&t, row), 0.5);
    // A row above grows while out of view: nothing on screen moves.
    s.grown = s.list.anchor -| 1;
    t.frame();
    try testing.expectApproxEqAbs(at + 30, try topOf(&t, row), 0.5);
    t.frame();
    try testing.expectApproxEqAbs(at + 30, try topOf(&t, row), 0.5);
}

test "a measured list reaches its true end whatever it guessed, and its offset stays inside" {
    var s: App = .{ .count = 300, .estimate = 400 };
    defer s.deinit();
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    t.scroll(200, 200, -1_000_000);
    for (0..6) |_| t.frame();
    const r = try topOf(&t, 299);
    try testing.expectApproxEqAbs(400 - heightOf(299), r, 0.5);
    // Filled to the top of the view: no hole above the rows built.
    try testing.expect(t.hasText("row 297"));
}

test "a measured list following its end stays there as rows come, until the reader leaves" {
    var s: App = .{ .count = 100, .follow = true };
    defer s.deinit();
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    for (0..4) |_| t.frame();
    try testing.expectApproxEqAbs(400 - heightOf(99), try topOf(&t, 99), 0.5);
    s.count = 101;
    t.frame();
    t.frame();
    try testing.expectApproxEqAbs(400 - heightOf(100), try topOf(&t, 100), 0.5);
    t.scroll(200, 200, 500);
    t.frame();
    t.frame();
    const row = s.list.anchor;
    const at = try topOf(&t, row);
    s.count = 102;
    t.frame();
    t.frame();
    try testing.expectEqual(at, try topOf(&t, row));
    t.scroll(200, 200, -100_000);
    t.frame();
    t.frame();
    s.count = 103;
    t.frame();
    t.frame();
    try testing.expectApproxEqAbs(400 - heightOf(102), try topOf(&t, 102), 0.5);
}

test "a measured list measures wrapped text anew as its width changes" {
    var s: App = .{ .count = 5, .wrapped = "words that wrap to more lines the narrower the list becomes, as messages do" };
    defer s.deinit();
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    const wide = s.list.tops.items[1];
    t.resize(120, 400);
    t.frame();
    t.frame();
    const narrow = s.list.tops.items[1];
    try testing.expect(narrow > wide);
    // What layout gave the row is what the list reckons with.
    try testing.expectEqual(s.list.tops.items[1], s.list.tops.items[2] - narrow);
}

test "a measured list with a gap and padding brings a row into view, exactly" {
    var s: App = .{ .gap = 10, .padding = .all(8) };
    defer s.deinit();
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    try testing.expectEqual(@as(f32, 8), try topOf(&t, 0));
    try testing.expectEqual(@as(f32, 38), try topOf(&t, 1));
    s.list.reveal = 5000;
    t.frame();
    try testing.expectApproxEqAbs(@as(f32, 0), try topOf(&t, 5000), 0.5);
    // All of it shows: no move.
    s.list.reveal = 5000;
    t.frame();
    try testing.expectApproxEqAbs(@as(f32, 0), try topOf(&t, 5000), 0.5);
    s.list.reveal = 1;
    t.frame();
    try testing.expectApproxEqAbs(@as(f32, 0), try topOf(&t, 1), 0.5);
    s.list.reveal = 0;
    t.frame();
    try testing.expectEqual(@as(f32, 8), try topOf(&t, 0));
}

test "a measured list scrolls by less than its padding" {
    var s: App = .{ .padding = .all(20) };
    defer s.deinit();
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    t.scroll(200, 200, -5);
    t.frame();
    try testing.expectEqual(@as(f32, 15), try topOf(&t, 0));
    t.scroll(200, 200, -5);
    t.frame();
    try testing.expectEqual(@as(f32, 10), try topOf(&t, 0));
}

test "a measured list scrolled up into rows never built moves only as far as it was asked" {
    var s: App = .{ .count = 500, .estimate = 300, .follow = true };
    defer s.deinit();
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    for (0..6) |_| t.frame();
    // From the end, as a chat opens, a notch at a time past every row built.
    for (0..80) |_| {
        const row = s.list.anchor + 1;
        const at = try topOf(&t, row);
        t.scroll(200, 200, 25);
        try testing.expectApproxEqAbs(at + 25, try topOf(&t, row), 0.5);
    }
}

test "a measured list takes fewer rows, none, and a reset" {
    var s: App = .{};
    defer s.deinit();
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    t.scroll(200, 200, -30_000);
    t.frame();
    s.count = 3;
    t.frame();
    t.frame();
    try testing.expect(t.hasText("row 2") and !t.hasText("row 3"));
    s.count = 0;
    t.frame();
    t.frame();
    try testing.expectEqual(0, s.built);
    s.count = 4;
    s.list.reset();
    t.frame();
    try testing.expectEqual(@as(f32, 0), try topOf(&t, 0));
}
