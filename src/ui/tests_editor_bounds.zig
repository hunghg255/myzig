//! The code editor's scans bounded by bytes as well as lines: a bracket's
//! partner 70 KB away, in 71 lines, is past the 64 KB bound.
const std = @import("std");
const testing = std.testing;
const TextArea = @import("textarea.zig").TextArea;
const indent = @import("editor/indent.zig");

fn caretAt(ta: *TextArea, at: usize) void {
    ta.sel = .{ .caret = at, .anchor = at };
}

test "editor: a bracket's partner is looked for within 64 KB" {
    const gpa = testing.allocator;
    var far: std.ArrayList(u8) = .empty;
    defer far.deinit(gpa);
    try far.appendSlice(gpa, "f(\n");
    for (0..70) |_| {
        try far.appendNTimes(gpa, 'x', 1000);
        try far.append(gpa, '\n');
    }
    try far.append(gpa, ')');
    var ta: TextArea = .init(gpa, far.items);
    defer ta.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // Forward from the opener, and back from the closer: too far.
    caretAt(&ta, 1);
    try testing.expect(indent.matchBracket(&ta, arena.allocator(), 2000) == null);
    caretAt(&ta, far.items.len);
    try testing.expect(indent.matchBracket(&ta, arena.allocator(), 2000) == null);

    // Near, both ways.
    var near: TextArea = .init(gpa, "f(\nxx\n)");
    defer near.deinit();
    caretAt(&near, 1);
    try testing.expectEqual([2]usize{ 1, 6 }, indent.matchBracket(&near, arena.allocator(), 2000).?);
    caretAt(&near, 7);
    try testing.expectEqual([2]usize{ 6, 1 }, indent.matchBracket(&near, arena.allocator(), 2000).?);
}
