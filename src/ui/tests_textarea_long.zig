//! Long lines in a text area, laid out within a frame's budget
//! (`textlayout_long.zig`), after mygo's TestCodeEditorWrapLongLines: a
//! line of megabytes shows its first rows at once and the rest over the
//! frames that follow, typing in it shapes what changed, and a line that
//! does not wrap draws only what shows of it.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const layout = @import("textlayout.zig");
const long = @import("textlayout_long.zig");

const Area = struct {
    ta: ui.TextArea,
    wrap: bool = true,
    fn view(s: *Area, c: *ui.Context) void {
        _ = ui.textArea(c, &s.ta, .{ .height = .fill, .wrap = s.wrap });
    }
};

fn words(gpa: std.mem.Allocator, lines: usize, bytes: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..lines) |l| {
        var k: usize = 0;
        while (out.items.len < (l + 1) * (bytes + 1) - 1) : (k += 1) try out.print(gpa, "w{d} ", .{k % 1000});
        out.shrinkRetainingCapacity((l + 1) * (bytes + 1) - 1);
        if (l + 1 < lines) try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

test "a line of megabytes shows its first rows at once, and the rest a budget a frame" {
    const gpa = testing.allocator;
    const s0 = try words(gpa, 1, 1 << 20);
    defer gpa.free(s0);
    var s: Area = .{ .ta = .init(gpa, s0) };
    defer s.ta.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Area.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    // The first frame laid out what its budget lets, which fills the view.
    try testing.expect(s.ta.long.shaped <= long.budget_bytes + long.piece_bytes);
    try testing.expect(s.ta.long.shaped > 0);
    try testing.expect(t.containsText("w0 w1 w2"));
    try testing.expect(t.ctx.animating);
    var frames: usize = 1;
    while (s.ta.long.pending) : (frames += 1) {
        t.frame();
        try testing.expect(s.ta.long.shaped <= long.budget_bytes + long.piece_bytes);
        if (frames > 200) return error.TestUnexpectedResult;
    }
    // About a megabyte at 32 KB a frame.
    try testing.expect(frames >= 30);
    // Then the frames shape nothing, and stop.
    t.frame();
    try testing.expectEqual(@as(usize, 0), s.ta.long.shaped);
    try testing.expect(!t.ctx.animating);
    // Typing at its end shapes the piece it is in, not the line.
    t.click(200, 100);
    s.ta.select(s0.len, s0.len);
    t.frame();
    t.typeText("x");
    errdefer std.debug.print("shaped {d}\n", .{s.ta.long.shaped});
    try testing.expect(s.ta.long.shaped <= 2 * long.piece_bytes);
    try testing.expect(s.ta.doc.len() == s0.len + 1);
}

test "a long line laid out in pieces wraps as it does laid out whole" {
    const gpa = testing.allocator;
    const s0 = try words(gpa, 1, 9000);
    defer gpa.free(s0);
    var s: Area = .{ .ta = .init(gpa, s0) };
    defer s.ta.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Area.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    t.settle(1);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const g: layout.Geo = .{ .ts = &t.text, .style = .{ .size = 14, .leading = 1.2 }, .wrap = 300, .row_h = 17, .arena = arena.allocator() };
    const whole = layout.wholeRows(g, &s.ta.doc, 0);
    var pieces = g;
    var lines: long.LongLines = .{};
    defer lines.deinit();
    for (0..20) |k| {
        lines.beginFrame(gpa, k);
        _ = layout.lineRows(blk: {
            pieces.long = &lines;
            break :blk pieces;
        }, &s.ta.doc, 0);
    }
    const cut = layout.lineRows(pieces, &s.ta.doc, 0);
    try testing.expectEqual(whole.str.len, cut.str.len);
    try testing.expectEqualSlices(u32, whole.rows, cut.rows);
    // (A piece kerns on its own: a few hundredths of a point a piece.)
    try testing.expectApproxEqAbs(whole.lay.width, cut.lay.width, 4);
}

test "many long lines: a frame lays out a budget of them" {
    const gpa = testing.allocator;
    const s0 = try words(gpa, 300, 6000);
    defer gpa.free(s0);
    var s: Area = .{ .ta = .init(gpa, s0), .wrap = false };
    defer s.ta.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Area.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    try testing.expect(s.ta.long.shaped <= long.budget_bytes + long.piece_bytes);
    t.settle(2);
    try testing.expect(!s.ta.long.pending);
    // Lines that don't wrap draw what shows of them, not their whole text.
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |x| try testing.expect(x.str.len < 1024),
        else => {},
    };
    try testing.expect(t.containsText("w0 w1 w2"));
}

test "the wrap of a line goes on where it stopped, as wrapped at once" {
    const gpa = testing.allocator;
    var a: Area = .{ .ta = .init(gpa, "") };
    defer a.ta.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, Area.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    const ts = &t.text;
    const s = "the quick brown fox jumps over the lazy dog, a sentence long enough to wrap a few times at this width";
    const lay = ts.layout(s, .{ .size = 14 });
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const whole = layout.breakRows(arena.allocator(), lay, s, 120);
    var b: long.Breaker = .{};
    b.reset(arena.allocator());
    while (b.next < lay.glyphs.len) b.run(arena.allocator(), lay, s, 120, true, 7);
    try testing.expectEqualSlices(u32, whole, b.rows.items);
    try testing.expect(whole.len > 3);
}

test "the code editor colors the first part of a long line, once" {
    const gpa = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    for (0..10_000) |i| try src.print(gpa, "var x{d} = 'a';", .{i});
    const Ed = struct {
        ed: ui.CodeEditor,
        fn view(s: *@This(), c: *ui.Context) void {
            _ = ui.codeEditor(c, &s.ed, .{});
        }
    };
    var s: Ed = .{ .ed = .init(gpa, src.items, "main.js") };
    defer s.ed.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Ed.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    t.settle(2);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const doc = &s.ed.area.doc;
    const line = doc.line(arena.allocator(), 0);
    const spans = s.ed.syntax.spans(arena.allocator(), doc, 0, line, false);
    try testing.expect(spans.len > 100);
    for (spans) |sp| try testing.expect(sp.end <= @import("editor/syntax.zig").max_tokenized);
    // Kept: asked again, the same runs.
    try testing.expectEqual(spans.ptr, s.ed.syntax.spans(arena.allocator(), doc, 0, line, false).ptr);
}
