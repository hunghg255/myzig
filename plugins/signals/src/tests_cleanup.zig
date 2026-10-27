//! alien-signals' tests of effects made inside effects, scopes and
//! computeds: who disposes them, and in which order cleanups run.
const std = @import("std");
const signals = @import("signals.zig");
const t = @import("tests.zig");
const Signal = signals.Signal;
const Computed = signals.Computed;
const Log = t.Log;
const begin = t.begin;
const end = t.end;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "should support custom recurse effect" {
    begin();
    defer end();
    const S = struct {
        var src = Signal(i32).init(0);
        var triggers: u32 = 0;
        fn run() void {
            signals.getActiveSub().?.flags &= ~signals.flags.recursed_check;
            triggers += 1;
            src.set(@min(src.get() + 1, 5));
        }
    };
    const e = signals.effect(S.run);
    defer e.dispose();
    try expectEqual(6, S.triggers);
}

pub const Nested = struct {
    pub var a = Signal(i32).init(0);
    pub var b = Signal(i32).init(0);

    pub fn reset() void {
        a = .init(0);
        b = .init(0);
    }

    fn innerCleanup() void {
        Log.push("inner:cleanup");
    }

    fn outerCleanup() void {
        Log.push("outer:cleanup");
    }

    pub fn inner() void {
        _ = b.get();
        Log.push("inner:run");
        signals.onCleanup(innerCleanup);
    }

    fn outer() void {
        _ = a.get();
        Log.push("outer:run");
        _ = signals.effect(inner);
        signals.onCleanup(outerCleanup);
    }
};

test "cleanup order on outer re-run: inner before outer, before new run" {
    begin();
    defer end();
    Nested.reset();
    const e = signals.effect(Nested.outer);
    defer e.dispose();
    try Log.expectLog(&.{ "outer:run", "inner:run" });
    Log.clear();
    Nested.a.set(1);
    try Log.expectLog(&.{ "inner:cleanup", "outer:cleanup", "outer:run", "inner:run" });
}

test "cleanup order on dispose: inner before outer" {
    begin();
    defer end();
    Nested.reset();
    const e = signals.effect(Nested.outer);
    Log.clear();
    e.dispose();
    try Log.expectLog(&.{ "inner:cleanup", "outer:cleanup" });
}

test "cleanup order is correct on outer re-run after a prior inner-only re-run" {
    begin();
    defer end();
    Nested.reset();
    const e = signals.effect(Nested.outer);
    defer e.dispose();
    Nested.b.set(1);
    Log.clear();
    Nested.a.set(1);
    try Log.expectLog(&.{ "inner:cleanup", "outer:cleanup", "outer:run", "inner:run" });
}

test "outer effect keeps responding to its own dep after inner re-runs" {
    begin();
    defer end();
    Nested.reset();
    const e = signals.effect(Nested.outer);
    defer e.dispose();
    Nested.b.set(1);
    try Log.expectLog(&.{ "outer:run", "inner:run", "inner:cleanup", "inner:run" });
    Log.clear();
    Nested.a.set(1);
    try Log.expectLog(&.{ "inner:cleanup", "outer:cleanup", "outer:run", "inner:run" });
}

const Siblings = struct {
    var a = Signal(i32).init(0);

    fn c1() void {
        Log.push("inner1:cleanup");
    }
    fn c2() void {
        Log.push("inner2:cleanup");
    }
    fn c3() void {
        Log.push("inner3:cleanup");
    }
    fn outerCleanup() void {
        Log.push("outer:cleanup");
    }
    fn e1() void {
        signals.onCleanup(c1);
    }
    fn e2() void {
        signals.onCleanup(c2);
    }
    fn e3() void {
        signals.onCleanup(c3);
    }
    fn outer() void {
        _ = a.get();
        _ = signals.effect(e1);
        _ = signals.effect(e2);
        _ = signals.effect(e3);
        signals.onCleanup(outerCleanup);
    }
    fn scope() void {
        _ = signals.effect(e1);
        _ = signals.effect(e2);
        _ = signals.effect(e3);
    }
};

test "sibling cleanup order on dispose: reverse creation (LIFO)" {
    begin();
    defer end();
    const e = signals.effect(Siblings.outer);
    e.dispose();
    try Log.expectLog(&.{ "inner3:cleanup", "inner2:cleanup", "inner1:cleanup", "outer:cleanup" });
}

test "sibling cleanup order on outer re-run: reverse creation (LIFO)" {
    begin();
    defer end();
    const e = signals.effect(Siblings.outer);
    defer e.dispose();
    Siblings.a.set(Siblings.a.peek() + 1);
    try expect(Log.len >= 4);
    Log.len = 4;
    try Log.expectLog(&.{ "inner3:cleanup", "inner2:cleanup", "inner1:cleanup", "outer:cleanup" });
}

test "scope dispose: sibling effects clean up in reverse creation (LIFO)" {
    begin();
    defer end();
    const s = signals.effectScope(Siblings.scope);
    s.dispose();
    try Log.expectLog(&.{ "inner3:cleanup", "inner2:cleanup", "inner1:cleanup" });
}

const Depth = struct {
    fn grandchildCleanup() void {
        Log.push("grandchild:cleanup");
    }
    fn childCleanup() void {
        Log.push("child:cleanup");
    }
    fn outerCleanup() void {
        Log.push("outer:cleanup");
    }
    fn grandchild() void {
        signals.onCleanup(grandchildCleanup);
    }
    fn child() void {
        _ = signals.effect(grandchild);
        signals.onCleanup(childCleanup);
    }
    fn outer() void {
        _ = signals.effect(child);
        signals.onCleanup(outerCleanup);
    }
    fn scope() void {
        _ = signals.effect(child);
    }
};

test "three-level nested cleanup on dispose: deepest first (depth-first reverse)" {
    begin();
    defer end();
    const e = signals.effect(Depth.outer);
    e.dispose();
    try Log.expectLog(&.{ "grandchild:cleanup", "child:cleanup", "outer:cleanup" });
}

test "scope dispose: nested effect cleanup runs depth-first reverse" {
    begin();
    defer end();
    const s = signals.effectScope(Depth.scope);
    s.dispose();
    try Log.expectLog(&.{ "grandchild:cleanup", "child:cleanup" });
}

test "computed unwatched: child effect cleanups run in reverse creation (LIFO)" {
    begin();
    defer end();
    const S = struct {
        fn l1() void {
            Log.push("e1");
        }
        fn l2() void {
            Log.push("e2");
        }
        fn l3() void {
            Log.push("e3");
        }
        fn e1() void {
            signals.onCleanup(l1);
        }
        fn e2() void {
            signals.onCleanup(l2);
        }
        fn e3() void {
            signals.onCleanup(l3);
        }
        var c = Computed(i32).init(struct {
            fn get(_: ?i32) i32 {
                _ = signals.effect(e1);
                _ = signals.effect(e2);
                _ = signals.effect(e3);
                return 0;
            }
        }.get);
        fn read() void {
            _ = c.get();
        }
    };
    const e = signals.effect(S.read);
    Log.clear();
    e.dispose();
    try Log.expectLog(&.{ "e3", "e2", "e1" });
}

test "effect created inside computed: old inner cleanup runs before new inner setup" {
    begin();
    defer end();
    const S = struct {
        var a = Signal(i32).init(0);
        fn cleanup() void {
            Log.push("inner:cleanup");
        }
        fn inner() void {
            Log.push("inner:run");
            signals.onCleanup(cleanup);
        }
        var c = Computed(i32).init(struct {
            fn get(_: ?i32) i32 {
                Log.push("computed:eval");
                _ = signals.effect(inner);
                return a.get();
            }
        }.get);
        fn read() void {
            _ = c.get();
        }
    };
    const e = signals.effect(S.read);
    defer e.dispose();
    Log.clear();
    S.a.set(1);
    try Log.expectLog(&.{ "inner:cleanup", "computed:eval", "inner:run" });
}

test "scope as intermediate parent: cleanup order respects nesting" {
    begin();
    defer end();
    const S = struct {
        var a = Signal(i32).init(0);
        fn scope() void {
            _ = signals.effect(Nested.inner);
        }
        fn outer() void {
            _ = a.get();
            Log.push("outer:run");
            _ = signals.effectScope(scope);
            signals.onCleanup(Nested.outerCleanup);
        }
    };
    Nested.reset();
    const e = signals.effect(S.outer);
    defer e.dispose();
    Log.clear();
    S.a.set(1);
    try Log.expectLog(&.{ "inner:cleanup", "outer:cleanup", "outer:run", "inner:run" });
}
