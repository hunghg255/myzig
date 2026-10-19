//! Keys of boxes by what Zig compares (`Context.keyed`): a pointer keys
//! its object, whatever it holds, and keys of different types apart.
const std = @import("std");
const ui = @import("ui.zig");
const testing = std.testing;

const Item = struct { title: []const u8, done: bool = false };

const Todos = struct {
    items: [3]Item = .{ .{ .title = "a" }, .{ .title = "a" }, .{ .title = "b" } },
    order: [3]usize = .{ 0, 1, 2 },
    ids: [3]u64 = undefined,

    fn view(s: *Todos, c: *ui.Context) void {
        ui.column(c, .{});
        defer ui.end(c);
        for (s.order) |i| {
            const it = &s.items[i];
            c.keyed(it);
            s.ids[i] = c.peekId(null);
            c.keyed(it);
            ui.text(c, it.title, .{});
        }
    }
};

test "keys: a pointer keys its item, whatever it holds and wherever it goes" {
    var s: Todos = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Todos.view), .{});
    defer t.deinit();
    const first = s.ids;
    // Two items alike are two keys.
    try testing.expect(first[0] != first[1]);
    // An item changed, and the items reordered: each keeps its id.
    s.items[0].done = true;
    s.items[0].title = "changed";
    s.order = .{ 2, 0, 1 };
    t.frame();
    try testing.expectEqualSlices(u64, &first, &s.ids);
}

const Mixed = struct {
    ids: [4]u64 = undefined,

    fn view(s: *Mixed, c: *ui.Context) void {
        ui.column(c, .{});
        defer ui.end(c);
        const keys = .{ @as(u32, 7), @as(u64, 7), "7", @as(i64, 7) };
        inline for (keys, 0..) |k, i| {
            c.keyed(k);
            s.ids[i] = c.peekId(null);
            c.keyed(k);
            ui.text(c, "x", .{});
        }
    }
};

test "keys: integers of different types and strings are different keys" {
    var s: Mixed = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Mixed.view), .{});
    defer t.deinit();
    for (s.ids, 0..) |a, i| for (s.ids[i + 1 ..]) |b| try testing.expect(a != b);
    // The same keys from frame to frame.
    const before = s.ids;
    t.frame();
    try testing.expectEqualSlices(u64, &before, &s.ids);
}

test {
    _ = @import("keyhash.zig");
}
