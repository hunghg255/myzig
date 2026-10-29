//! Computeds that own their values (`Computed.withOptions`): what is freed
//! and when, compared by content; and the graph's one thread.
const std = @import("std");
const builtin = @import("builtin");
const signals = @import("signals.zig");
const t = @import("tests.zig");
const Signal = signals.Signal;
const Computed = signals.Computed;
const begin = t.begin;
const end = t.end;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// Text the getters allocate, and how often it was freed.
const Text = struct {
    var frees: u32 = 0;

    fn print(comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(signals.allocator, fmt, args) catch @panic("OOM");
    }

    fn free(s: []const u8) void {
        frees += 1;
        signals.allocator.free(s);
    }

    fn same(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};

test "a computed owning its text frees each value it replaces, compared by content" {
    begin();
    defer end();
    Text.frees = 0;
    const S = struct {
        var n = Signal(i32).init(0);
        var runs: u32 = 0;
        var label = Computed([]const u8).init(format).withOptions(.{ .eql = Text.same, .free = Text.free });
        fn format(_: ?[]const u8) []const u8 {
            return Text.print("{d}", .{@divTrunc(n.get(), 10)});
        }
        fn run() void {
            runs += 1;
            _ = label.get();
        }
    };
    const e = signals.effect(S.run);
    try expectEqual(1, S.runs);
    S.n.set(1); // "0" again: the effect doesn't run, the new copy is kept
    try expectEqual(1, S.runs);
    try expectEqual(1, Text.frees);
    S.n.set(10);
    try expectEqual(2, S.runs);
    try expectEqual(2, Text.frees);
    try expectEqualStrings("1", S.label.peek());
    e.dispose();
    S.label.deinit();
    try expectEqual(3, Text.frees);
}

test "a value read stays valid until the write that replaced it returns" {
    begin();
    defer end();
    Text.frees = 0;
    const S = struct {
        var n = Signal(i32).init(0);
        var label = Computed([]const u8).init(format).withOptions(.{ .free = Text.free });
        var kept_ok = false;
        fn format(_: ?[]const u8) []const u8 {
            return Text.print("n = {d}", .{n.get()});
        }
        fn show() void {
            _ = label.get();
        }
        // Holds the value while its write makes `show` compute the next.
        fn write() void {
            const held = label.peek();
            n.set(1);
            kept_ok = std.mem.eql(u8, held, "n = 0");
        }
    };
    const shown = signals.effect(S.show);
    const writer = signals.effect(S.write);
    try expect(S.kept_ok);
    try expectEqual(1, Text.frees);

    // A batch holds it too, until it ends.
    signals.startBatch();
    const held = S.label.get();
    S.n.set(2);
    try expectEqualStrings("n = 2", S.label.get());
    try expectEqualStrings("n = 1", held);
    try expectEqual(1, Text.frees);
    signals.endBatch();
    try expectEqual(2, Text.frees);

    writer.dispose();
    shown.dispose();
    S.label.deinit();
    try expectEqual(3, Text.frees);
}

test "a getter returning its previous value keeps it" {
    begin();
    defer end();
    Text.frees = 0;
    const S = struct {
        var n = Signal(i32).init(0);
        var label = Computed([]const u8).init(format).withOptions(.{ .free = Text.free });
        fn format(prev: ?[]const u8) []const u8 {
            const v = n.get();
            if (prev) |p| if (@mod(v, 2) == 0) return p;
            return Text.print("{d}", .{v});
        }
    };
    const first = S.label.get();
    S.n.set(2);
    try expectEqual(first.ptr, S.label.get().ptr);
    try expectEqual(0, Text.frees);
    S.n.set(3);
    try expectEqualStrings("3", S.label.get());
    try expectEqual(1, Text.frees);
    S.label.deinit();
    try expectEqual(2, Text.frees);
}

test "deinit frees the value, and a read after computes it again" {
    begin();
    defer end();
    Text.frees = 0;
    const S = struct {
        var n = Signal(i32).init(4);
        var label = Computed([]const u8).init(format).withOptions(.{ .free = Text.free });
        // Reads nothing: after deinit it has no links to mark it dirty.
        var fixed = Computed([]const u8).init(constant).withOptions(.{ .free = Text.free });
        fn format(_: ?[]const u8) []const u8 {
            return Text.print("{d}", .{n.get()});
        }
        fn constant(_: ?[]const u8) []const u8 {
            return Text.print("fixed", .{});
        }
    };
    try expectEqualStrings("4", S.label.get());
    try expectEqualStrings("fixed", S.fixed.get());
    S.label.deinit();
    S.fixed.deinit();
    try expectEqual(2, Text.frees);
    try expectEqualStrings("4", S.label.get());
    try expectEqualStrings("fixed", S.fixed.get());
    S.label.deinit();
    S.fixed.deinit();
    try expectEqual(4, Text.frees);
}

test "after deinit, another thread can use the graph" {
    if (builtin.single_threaded) return error.SkipZigTest;
    begin();
    var count = Signal(i32).init(0);
    count.set(1);
    end(); // lets go of this thread
    const W = struct {
        fn work(s: *Signal(i32)) void {
            s.set(s.get() + 1);
            signals.deinit();
        }
    };
    const th = try std.Thread.spawn(.{}, W.work, .{&count});
    th.join();
    begin();
    defer end();
    try expectEqual(2, count.get());
}
