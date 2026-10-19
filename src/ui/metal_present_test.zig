//! The drawable presenter's protocol (`metal_present.zig`) on every
//! platform: a fake layer hands out numbered drawables, and the test runs
//! the queue's fetches and the main thread's completions in the orders
//! the threads can.
const std = @import("std");
const present = @import("metal_present.zig");
const Presenter = present.Presenter;

const t = std.testing;

const Fake = struct {
    next: usize = 1,
    /// Drawables fetched and not released.
    live: usize = 0,
    /// Fetches queued, and their completions posted, in order.
    queued: usize = 0,
    posted: usize = 0,
    flushes: usize = 0,
    wakes: usize = 0,
    freed: bool = false,
    none: bool = false,

    var current: *Fake = undefined;

    fn fetch(_: ?*anyopaque) ?*anyopaque {
        const f = current;
        if (f.none) return null;
        f.live += 1;
        f.next += 1;
        return @ptrFromInt(f.next * 16);
    }
    fn release(_: *anyopaque) void {
        current.live -= 1;
    }
    fn enqueue(_: *Presenter) void {
        current.queued += 1;
    }
    fn flush(p: *Presenter) void {
        current.flushes += 1;
        runQueue(p);
    }
    fn free(_: *Presenter) void {
        current.freed = true;
    }
    fn wake(ctx: *anyopaque) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.wakes += 1;
    }

    /// The queue's thread: runs the fetches queued; each posts a completion.
    fn runQueue(p: *Presenter) void {
        const f = current;
        while (f.queued > 0) : (f.queued -= 1) {
            p.fetchNow();
            f.posted += 1;
        }
    }
    /// The main thread: runs the completions posted.
    fn runMain(p: *Presenter) void {
        const f = current;
        while (f.posted > 0) : (f.posted -= 1) p.completed();
    }

    fn presenter(f: *Fake) Presenter {
        current = f;
        return .{
            .ops = .{ .ctx = null, .fetch = fetch, .release = release, .enqueue = enqueue, .flush = flush, .free = free },
            .wake = .{ .ctx = f, .func = wake },
        };
    }
};

test "a frame takes the drawable fetched after the last present" {
    var f: Fake = .{};
    var p = f.presenter();
    p.start();
    try t.expect(p.busy());
    // Started again while fetching: one fetch.
    p.start();
    try t.expectEqual(@as(usize, 1), f.queued);
    Fake.runQueue(&p);
    Fake.runMain(&p);
    try t.expect(!p.busy());
    // Nothing waited: no wake.
    try t.expectEqual(@as(usize, 0), f.wakes);
    // With a drawable in the slot, no fetch starts.
    p.start();
    try t.expectEqual(@as(usize, 0), f.queued);
    const d = p.take() orelse return error.NoDrawable;
    try t.expectEqual(@as(usize, 0), f.flushes);
    p.ops.release(d);
    try t.expectEqual(@as(usize, 0), f.live);
    p.destroy();
    try t.expect(f.freed);
}

test "a frame that comes while the drawable is fetched draws once it came" {
    var f: Fake = .{};
    var p = f.presenter();
    p.start();
    // The frame waits: the main thread is free meanwhile.
    try t.expect(p.waitFor());
    Fake.runQueue(&p);
    try t.expectEqual(@as(usize, 0), f.wakes);
    Fake.runMain(&p);
    try t.expectEqual(@as(usize, 1), f.wakes);
    try t.expect(!p.waitFor());
    p.drain();
    try t.expectEqual(@as(usize, 0), f.live);
    p.destroy();
}

test "the layer changes only once the fetch in flight ended" {
    var f: Fake = .{};
    var p = f.presenter();
    p.start();
    try t.expect(p.waitFor());
    // A resize: the main thread waits for the queue, and lets go of the
    // drawable of the old size.
    p.drain();
    try t.expectEqual(@as(usize, 1), f.flushes);
    try t.expectEqual(@as(usize, 0), f.live);
    try t.expect(!p.busy());
    // A new fetch starts before the old completion ran.
    p.start();
    try t.expect(p.busy());
    // The old completion is stale: the new fetch is still in flight, and
    // the frame that waited is woken once that one ended.
    Fake.runMain(&p);
    try t.expect(p.busy());
    try t.expectEqual(@as(usize, 0), f.wakes);
    Fake.runQueue(&p);
    Fake.runMain(&p);
    try t.expect(!p.busy());
    try t.expectEqual(@as(usize, 1), f.wakes);
    try t.expect(p.slot != null);
    p.destroy();
    try t.expectEqual(@as(usize, 0), f.live);
}

test "a presenter destroyed with a completion posted frees itself when it runs" {
    var f: Fake = .{};
    var p = f.presenter();
    p.start();
    try t.expect(p.waitFor());
    Fake.runQueue(&p);
    p.destroy();
    try t.expect(!f.freed);
    try t.expectEqual(@as(usize, 0), f.live);
    Fake.runMain(&p);
    try t.expect(f.freed);
    // The surface is gone: nothing woken.
    try t.expectEqual(@as(usize, 0), f.wakes);
}

test "no drawable came: the next frame fetches its own" {
    var f: Fake = .{ .none = true };
    var p = f.presenter();
    p.start();
    Fake.runQueue(&p);
    Fake.runMain(&p);
    try t.expect(p.take() == null);
    // The slot is empty: the next present fetches again.
    p.start();
    try t.expectEqual(@as(usize, 1), f.queued);
    p.destroy();
    try t.expect(!f.freed);
    Fake.runMain(&p);
    try t.expect(f.freed);
}
