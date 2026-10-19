//! Comparing texts and the diff viewer: hunks of known cases, random edits
//! whose hunks turn the old text into the new, words within lines, rows
//! unified and split with unchanged lines collapsed, and a long file
//! building only the rows in view.
const std = @import("std");
const ui = @import("ui.zig");
const diff = @import("diff.zig");
const model = @import("diffview_model.zig");
const dview = @import("diffview.zig");
const testing = std.testing;
const gpa = testing.allocator;

fn hunksOf(a: []const u8, b: []const u8) ![]diff.Hunk {
    const la = try diff.splitLines(gpa, a);
    defer gpa.free(la);
    const lb = try diff.splitLines(gpa, b);
    defer gpa.free(lb);
    return diff.lines(gpa, la, lb);
}

/// The hunks applied to `a`'s lines give `b`'s.
fn expectApplies(a: []const []const u8, b: []const []const u8, hunks: []const diff.Hunk) !void {
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(gpa);
    var at: usize = 0;
    var last_b: usize = 0;
    for (hunks) |h| {
        try testing.expect(h.a0 >= at and h.a1 >= h.a0 and h.b1 >= h.b0 and h.b0 >= last_b);
        try out.appendSlice(gpa, a[at..h.a0]);
        try out.appendSlice(gpa, b[h.b0..h.b1]);
        at = h.a1;
        last_b = h.b1;
    }
    try out.appendSlice(gpa, a[at..]);
    try testing.expectEqual(b.len, out.items.len);
    for (b, out.items) |want, got| try testing.expectEqualStrings(want, got);
}

test "hunks of known cases" {
    const same = try hunksOf("a\nb\nc", "a\nb\nc");
    defer gpa.free(same);
    try testing.expectEqual(@as(usize, 0), same.len);
    const ins = try hunksOf("a\nc", "a\nb\nc");
    defer gpa.free(ins);
    try testing.expectEqualSlices(diff.Hunk, &.{.{ .a0 = 1, .a1 = 1, .b0 = 1, .b1 = 2 }}, ins);
    const del = try hunksOf("a\nb\nc", "a\nc");
    defer gpa.free(del);
    try testing.expectEqualSlices(diff.Hunk, &.{.{ .a0 = 1, .a1 = 2, .b0 = 1, .b1 = 1 }}, del);
    const chg = try hunksOf("a\nb\nc\nd", "a\nB\nc\nD\ne");
    defer gpa.free(chg);
    try testing.expectEqualSlices(diff.Hunk, &.{ .{ .a0 = 1, .a1 = 2, .b0 = 1, .b1 = 2 }, .{ .a0 = 3, .a1 = 4, .b0 = 3, .b1 = 5 } }, chg);
    const empty = try hunksOf("", "x\ny");
    defer gpa.free(empty);
    try testing.expectEqualSlices(diff.Hunk, &.{.{ .a0 = 0, .a1 = 1, .b0 = 0, .b1 = 2 }}, empty);
}

test "random edits: the hunks turn the old lines into the new" {
    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    const vocab = [_][]const u8{ "a", "b", "c", "d", "}", "", "return x;", "{" };
    for (0..300) |round| {
        var a: std.ArrayList([]const u8) = .empty;
        defer a.deinit(gpa);
        const n = rand.uintAtMost(usize, if (round % 10 == 0) 400 else 40);
        for (0..n) |_| try a.append(gpa, vocab[rand.uintLessThan(usize, vocab.len)]);
        var b: std.ArrayList([]const u8) = .empty;
        defer b.deinit(gpa);
        try b.appendSlice(gpa, a.items);
        for (0..rand.uintAtMost(usize, 8)) |_| {
            const at = rand.uintAtMost(usize, b.items.len);
            switch (rand.uintLessThan(u8, 3)) {
                0 => try b.insert(gpa, at, vocab[rand.uintLessThan(usize, vocab.len)]),
                1 => if (at < b.items.len) {
                    _ = b.orderedRemove(at);
                },
                else => if (at < b.items.len) {
                    b.items[at] = vocab[rand.uintLessThan(usize, vocab.len)];
                },
            }
        }
        const hunks = try diff.lines(gpa, a.items, b.items);
        defer gpa.free(hunks);
        try expectApplies(a.items, b.items, hunks);
    }
}

test "unrelated texts finish under the cost limit, and still apply" {
    var prng = std.Random.DefaultPrng.init(3);
    const rand = prng.random();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    var a: std.ArrayList([]const u8) = .empty;
    var b: std.ArrayList([]const u8) = .empty;
    for (0..4000) |_| {
        try a.append(al, try std.fmt.allocPrint(al, "{d}", .{rand.uintLessThan(u32, 50)}));
        try b.append(al, try std.fmt.allocPrint(al, "{d}", .{rand.uintLessThan(u32, 50)}));
    }
    const hunks = try diff.lines(gpa, a.items, b.items);
    defer gpa.free(hunks);
    try expectApplies(a.items, b.items, hunks);
}

test "words that changed within a line" {
    const w = try diff.words(gpa, "const x = compute(a, b);", "const y = compute(a, c);");
    defer w.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), w.a.len);
    try testing.expectEqual(diff.Range{ .start = 6, .end = 7 }, w.a[0]);
    try testing.expectEqual(diff.Range{ .start = 21, .end = 22 }, w.b[1]);
    try testing.expect(w.same > 0.8);
    // Changes a space apart read as one.
    const j = try diff.words(gpa, "one two three", "uno dos three");
    defer j.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), j.a.len);
    try testing.expectEqual(diff.Range{ .start = 0, .end = 7 }, j.a[0]);
}

fn numbered(n: usize, changed: []const usize, out: *std.ArrayList(u8)) !void {
    for (0..n) |i| {
        if (std.mem.indexOfScalar(usize, changed, i) != null) try out.print(gpa, "line {d} changed here\n", .{i}) else try out.print(gpa, "line {d}\n", .{i});
    }
}

test "rows: changes with context, the rest collapsed until expanded; split rows aligned" {
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try numbered(40, &.{}, &a);
    try numbered(40, &.{20}, &b);
    var dv = try model.DiffView.init(gpa, a.items, b.items, null);
    defer dv.deinit();
    dv.build();
    // A gap, 3 lines, the deleted and added line, 3 lines, a gap.
    const rows = dv.rows.items;
    try testing.expectEqual(@as(usize, 10), rows.len);
    try testing.expectEqual(model.Kind.gap, rows[0].kind);
    try testing.expectEqual(@as(u32, 17), rows[0].hidden);
    try testing.expectEqual(model.Kind.deleted, rows[4].kind);
    try testing.expectEqual(model.Kind.added, rows[5].kind);
    try testing.expectEqual(@as(?u32, 20), rows[5].pair);
    try testing.expectEqual(@as(u32, 17), rows[9].hidden);
    try testing.expectEqual(@as(usize, 1), dv.stats().added);
    dv.expand(rows[0].run);
    dv.build();
    try testing.expectEqual(@as(usize, 26), dv.rows.items.len);
    dv.setMode(.split);
    dv.build();
    // Side by side, the changed line is one row.
    var changed: usize = 0;
    for (dv.rows.items) |r| if (r.kind == .deleted) {
        changed += 1;
        try testing.expectEqual(model.Kind.added, r.new_kind);
        try testing.expectEqual(@as(?u32, 20), r.new);
    };
    try testing.expectEqual(@as(usize, 1), changed);
    dv.collapseAll();
    dv.build();
    try testing.expectEqual(@as(usize, 9), dv.rows.items.len);
}

const App = struct {
    dv: model.DiffView,

    fn view(s: *App, c: *ui.Context) void {
        dview.diffView(c, &s.dv, .{});
    }
};

test "the viewer shows numbers, signs and marked words, expands gaps, and builds only what is in view" {
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try numbered(100_000, &.{}, &a);
    try numbered(100_000, &.{ 10, 60_000 }, &b);
    var s: App = .{ .dv = try .init(gpa, a.items, b.items, "a.txt") };
    defer s.dv.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, App.view), .{ .width = 640, .height = 400 });
    defer t.deinit();
    try testing.expect(t.hasText("line 10 changed here"));
    try testing.expect(t.hasText("line 10"));
    try testing.expect(t.hasText("+") and t.hasText("-"));
    try testing.expect(t.hasText("11"));
    try testing.expect(t.ctx.stats.nodes < 400);
    // The words changed are marked over the line's tint.
    var words: usize = 0;
    for (t.ctx.nodes.items) |n| if (n.style.absolute and n.style.radius == 3) {
        words += 1;
    };
    try testing.expectEqual(@as(usize, 2), words);
    // The gap after the first change; a click shows its lines.
    try testing.expect(t.hasText("⋯ 59983 unchanged lines"));
    try t.clickText("⋯ 59983 unchanged lines");
    try testing.expect(!t.hasText("⋯ 59983 unchanged lines"));
    try testing.expect(t.hasText("line 14"));
    try testing.expect(t.ctx.stats.nodes < 400);
    s.dv.setMode(.split);
    t.frame();
    try testing.expect(t.hasText("line 10 changed here") and t.hasText("line 10"));
    try testing.expect(t.ctx.stats.nodes < 500);
    const pixels = try t.render(gpa);
    defer pixels.deinit(gpa);
}
