//! alien-signals' tests (`tests/*.spec.ts`), and the basics, with every
//! effect disposed and `std.testing.allocator` checking that nothing leaks.
const std = @import("std");
const signals = @import("signals.zig");
const cleanup = @import("tests_cleanup.zig");
const Signal = signals.Signal;
const Computed = signals.Computed;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test {
    _ = @import("tests_cleanup.zig");
}

/// What the effects of a test did, in order.
pub const Log = struct {
    var items: [32][]const u8 = undefined;
    pub var len: usize = 0;

    pub fn push(s: []const u8) void {
        items[len] = s;
        len += 1;
    }

    pub fn clear() void {
        len = 0;
    }

    pub fn expectLog(want: []const []const u8) !void {
        try expectEqual(want.len, len);
        for (want, items[0..len]) |w, got| try std.testing.expectEqualStrings(w, got);
    }
};

pub fn begin() void {
    signals.allocator = std.testing.allocator;
    Log.clear();
}

pub fn end() void {
    signals.deinit();
}

test "a computed is lazy and cached" {
    begin();
    defer end();
    const S = struct {
        var a = Signal(i32).init(1);
        var runs: u32 = 0;
        var double = Computed(i32).init(get);
        fn get(_: ?i32) i32 {
            runs += 1;
            return a.get() * 2;
        }
    };
    defer S.double.deinit();
    try expectEqual(0, S.runs);
    try expectEqual(2, S.double.get());
    try expectEqual(2, S.double.get());
    try expectEqual(1, S.runs);
    S.a.set(3);
    try expectEqual(1, S.runs);
    try expectEqual(6, S.double.get());
    try expectEqual(2, S.runs);
}

test "an effect runs once for a diamond" {
    begin();
    defer end();
    const S = struct {
        var a = Signal(i32).init(1);
        var b = Computed(i32).init(struct {
            fn get(_: ?i32) i32 {
                return a.get() + 1;
            }
        }.get);
        var c = Computed(i32).init(struct {
            fn get(_: ?i32) i32 {
                return a.get() * 10;
            }
        }.get);
        var runs: u32 = 0;
        var seen: i32 = 0;
        fn run() void {
            runs += 1;
            seen = b.get() + c.get();
        }
    };
    const e = signals.effect(S.run);
    defer e.dispose();
    try expectEqual(1, S.runs);
    try expectEqual(12, S.seen);
    S.a.set(2);
    try expectEqual(2, S.runs);
    try expectEqual(23, S.seen);
}

test "an effect doesn't run again when a computed it reads stays the same" {
    begin();
    defer end();
    const S = struct {
        var a = Signal(i32).init(1);
        var positive = Computed(bool).init(struct {
            fn get(_: ?bool) bool {
                return a.get() > 0;
            }
        }.get);
        var runs: u32 = 0;
        fn run() void {
            runs += 1;
            _ = positive.get();
        }
    };
    const e = signals.effect(S.run);
    defer e.dispose();
    S.a.set(2);
    S.a.set(3);
    try expectEqual(1, S.runs);
    S.a.set(-1);
    try expectEqual(2, S.runs);
}

test "a batch runs effects once, at its end" {
    begin();
    defer end();
    const S = struct {
        var a = Signal(i32).init(0);
        var b = Signal(i32).init(0);
        var runs: u32 = 0;
        var sum: i32 = 0;
        fn run() void {
            runs += 1;
            sum = a.get() + b.get();
        }
    };
    const e = signals.effect(S.run);
    defer e.dispose();
    signals.startBatch();
    S.a.set(1);
    S.b.set(2);
    try expectEqual(1, S.runs);
    signals.endBatch();
    try expectEqual(2, S.runs);
    try expectEqual(3, S.sum);
}

test "peek and setActiveSub(null) read without depending" {
    begin();
    defer end();
    const S = struct {
        var a = Signal(i32).init(0);
        var b = Signal(i32).init(0);
        var runs: u32 = 0;
        fn run() void {
            runs += 1;
            _ = a.peek();
            const prev = signals.setActiveSub(null);
            defer _ = signals.setActiveSub(prev);
            _ = b.get();
        }
    };
    const e = signals.effect(S.run);
    defer e.dispose();
    S.a.set(1);
    S.b.set(1);
    try expectEqual(1, S.runs);
}

test "a disposed effect stops, and a set to an equal value changes nothing" {
    begin();
    defer end();
    const S = struct {
        var a = Signal(i32).init(0);
        var runs: u32 = 0;
        fn run() void {
            runs += 1;
            _ = a.get();
        }
    };
    const e = signals.effect(S.run);
    S.a.set(0);
    try expectEqual(1, S.runs);
    S.a.set(1);
    try expectEqual(2, S.runs);
    e.dispose();
    S.a.set(2);
    try expectEqual(2, S.runs);
}

test "an effect of a context" {
    begin();
    defer end();
    const Counter = struct {
        n: Signal(i32) = .init(0),
        shown: i32 = -1,
        fn show(c: *@This()) void {
            c.shown = c.n.get();
        }
    };
    var counter: Counter = .{};
    const e = signals.effectWith(&counter, Counter.show);
    defer e.dispose();
    counter.n.set(5);
    try expectEqual(5, counter.shown);
}

const List = std.ArrayList(i32);

test "should trigger updates for dependent computed signals" {
    begin();
    defer end();
    const S = struct {
        var arr = Signal(List).init(.empty);
        var length = Computed(usize).init(struct {
            fn get(_: ?usize) usize {
                return arr.get().items.len;
            }
        }.get);
    };
    defer S.arr.mutate().deinit(std.testing.allocator);
    defer S.length.deinit();
    try expectEqual(0, S.length.get());
    try S.arr.mutate().append(std.testing.allocator, 1);
    S.arr.trigger();
    try expectEqual(1, S.length.get());
}

test "should not throw when triggering with no dependencies" {
    begin();
    defer end();
    signals.trigger(struct {
        fn f() void {}
    }.f);
}

test "should trigger effect once" {
    begin();
    defer end();
    const S = struct {
        var src1 = Signal(i32).init(0);
        var src2 = Signal(i32).init(0);
        var triggers: u32 = 0;
        fn run() void {
            triggers += 1;
            _ = src1.get();
            _ = src2.get();
        }
        fn both() void {
            _ = src1.get();
            _ = src2.get();
        }
    };
    const e = signals.effect(S.run);
    defer e.dispose();
    try expectEqual(1, S.triggers);
    signals.trigger(S.both);
    try expectEqual(2, S.triggers);
}

test "should rerun effect once when writing a signal after reading it" {
    begin();
    defer end();
    const S = struct {
        var src1 = Signal(i32).init(1);
        var triggers: u32 = 0;
        fn run() void {
            triggers += 1;
            _ = src1.get();
        }
        fn write() void {
            _ = src1.get();
            src1.set(src1.get() + 1);
        }
    };
    const e = signals.effect(S.run);
    defer e.dispose();
    signals.trigger(S.write);
    try expectEqual(2, S.triggers);
    try expectEqual(2, S.src1.peek());
}

test "should trigger updates for the second source signal" {
    begin();
    defer end();
    const S = struct {
        var src1 = Signal(List).init(.empty);
        var src2 = Signal(List).init(.empty);
        var length = Computed(usize).init(struct {
            fn get(_: ?usize) usize {
                return src2.get().items.len;
            }
        }.get);
        fn both() void {
            _ = src1.get();
            _ = src2.get();
        }
    };
    defer S.src2.mutate().deinit(std.testing.allocator);
    defer S.length.deinit();
    try expectEqual(0, S.length.get());
    try S.src2.mutate().append(std.testing.allocator, 1);
    signals.trigger(S.both);
    try expectEqual(1, S.length.get());
}

test "should not notify the trigger function sub" {
    begin();
    defer end();
    const S = struct {
        var src1 = Signal(i32).init(0);
        var src2 = Computed(i32).init(struct {
            fn get(_: ?i32) i32 {
                return src1.get();
            }
        }.get);
        fn both() void {
            _ = src1.get();
            _ = src2.get();
        }
    };
    const e = signals.effect(S.both);
    defer e.dispose();
    signals.trigger(S.both);
}

test "should allow writing a signal after reading it" {
    begin();
    defer end();
    const S = struct {
        var src1 = Signal(i32).init(1);
        fn write() void {
            src1.set(src1.get() + 1);
        }
    };
    signals.trigger(S.write);
    try expectEqual(2, S.src1.peek());
}

test "scope dispose runs child effect cleanup" {
    begin();
    defer end();
    const S = struct {
        fn scope() void {
            _ = signals.effect(cleanup.Nested.inner);
        }
    };
    cleanup.Nested.reset();
    const s = signals.effectScope(S.scope);
    Log.clear();
    s.dispose();
    try Log.expectLog(&.{"inner:cleanup"});
}

test "a chain deeper than the walks' stacks" {
    begin();
    defer end();
    const Chain = struct {
        const n = 40;
        var head = Signal(i32).init(0);
        var links: [n]Computed(i32) = undefined;
        var seen: i32 = -1;

        fn get(c: *Computed(i32), _: ?i32) i32 {
            const i = (@intFromPtr(c) - @intFromPtr(&links[0])) / @sizeOf(Computed(i32));
            return (if (i == 0) head.get() else links[i - 1].get()) + 1;
        }
        fn run() void {
            seen = links[n - 1].get();
        }
    };
    for (&Chain.links) |*c| c.* = .initWith(c, Chain.get);
    const e = signals.effect(Chain.run);
    defer e.dispose();
    try expectEqual(40, Chain.seen);
    Chain.head.set(10);
    try expectEqual(50, Chain.seen);
}

test "a disposed effect a read queued is not freed before the queue runs" {
    begin();
    defer end();
    // `a` writes what it read on its first run, so it waits pending; reading
    // `c` then queues it (a computed found changed) with no flush to run it.
    const S = struct {
        var s = Signal(i32).init(0);
        var c = Computed(i32).init(struct {
            fn get(_: ?i32) i32 {
                return s.get() + 1;
            }
        }.get);
        var a_runs: u32 = 0;
        var b_runs: u32 = 0;
        fn a() void {
            a_runs += 1;
            const v = c.get();
            if (a_runs == 1) s.set(v);
        }
        fn b() void {
            b_runs += 1;
            _ = s.get();
        }
    };
    const eb = signals.effect(S.b);
    defer eb.dispose();
    const ea = signals.effect(S.a);
    try expectEqual(2, S.c.get());
    ea.dispose();
    S.s.set(5); // flushes the queue, which still holds `a`
    try expectEqual(1, S.a_runs);
    try expectEqual(3, S.b_runs);
}
