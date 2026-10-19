//! Text fields with text read right to left, through `Tester`: the caret
//! sits where the bidirectional order puts it (at the left of a Hebrew word
//! typed, between the runs of mixed text), moves through the text in
//! logical order, and a click lands on the character under the pointer.
//! A selection across directions covers its characters' ranges.
const std = @import("std");
const ui = @import("ui.zig");
const text = @import("text.zig");
const testing = std.testing;

const hebrew = "\xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d"; // שלום

const Field = struct {
    buf: ui.TextBuffer = .{},
    fn view(s: *Field, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        _ = ui.textField(c, &s.buf, .{ .placeholder = "Type", .width = .{ .px = 240 } });
    }
};

fn caretX(t: *ui.Tester) f32 {
    return t.ctx.focused_text.?.caret_rect.x;
}

test "a Hebrew word typed: the caret ends at its left and moves right going back" {
    var s: Field = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Field.view), .{});
    defer t.deinit();
    try t.clickText("Type");
    t.textOps(&.{.{ .insert = hebrew }});
    try testing.expectEqualStrings(hebrew, s.buf.text());
    const word = t.findText(hebrew).?;
    // After its last letter: the word's left edge.
    try testing.expectApproxEqAbs(word.x, caretX(&t), 1);
    // Back a letter at a time (logical order): the caret goes right, to
    // the word's right edge before its first letter.
    var last = caretX(&t);
    for (0..4) |_| {
        t.textOps(&.{.{ .command = .move_left }});
        try testing.expect(caretX(&t) > last);
        last = caretX(&t);
    }
    try testing.expectEqual(@as(usize, 0), t.ctx.focused_text.?.caret);
    try testing.expectApproxEqAbs(word.x + t.ctx.text.width(hebrew, .{}), last, 1);
    // A click near the word's right edge puts the caret before its first letter.
    t.click(word.x + word.w - 1, word.y + word.h / 2);
    try testing.expectEqual(@as(usize, 0), t.ctx.focused_text.?.caret);
    t.click(word.x + 1, word.y + word.h / 2);
    try testing.expectEqual(hebrew.len, t.ctx.focused_text.?.caret);
}

test "mixed text: the caret between the runs, a selection in two ranges" {
    var s: Field = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Field.view), .{});
    defer t.deinit();
    try t.clickText("Type");
    const mixed = "abc " ++ hebrew;
    t.textOps(&.{.{ .insert = mixed }});
    const line = t.findText(mixed).?;
    const style: ui.TextStyle = .{};
    // At the end: after the Hebrew word's last letter, at its left.
    const lead = t.ctx.text.width("abc ", style);
    try testing.expectApproxEqAbs(line.x + lead, caretX(&t), 1);
    // Before the Hebrew word (byte 4): its right edge, the line's end.
    t.textOps(&.{ .{ .command = .move_left }, .{ .command = .move_left }, .{ .command = .move_left }, .{ .command = .move_left } });
    try testing.expectEqual(@as(usize, 4), t.ctx.focused_text.?.caret);
    try testing.expectApproxEqAbs(line.x + t.ctx.text.width(mixed, style), caretX(&t), 1);
    // "c ש" selected: the "c " at the left, the shin at the right.
    var out: [4][2]f32 = undefined;
    const n = text.selectionRanges(t.ctx.text, mixed, style, 2, 6, &out);
    try testing.expectEqual(@as(usize, if (text.portable) 2 else 1), n);
    if (text.portable) {
        try testing.expectApproxEqAbs(lead, out[0][1], 0.5);
        try testing.expectApproxEqAbs(t.ctx.text.width(mixed, style), out[1][1], 0.5);
    }
}
