//! Events of a terminal's threads handed to the main thread, coalesced:
//! a bit per kind of event, posted once until the main thread takes them
//! (with the mainthread plugin's queue: nothing polls). The waker outlives
//! its terminal while a post is queued: `kill` marks it dead, and the last
//! of the two frees it.
const std = @import("std");
const mainthread = @import("mainthread");

pub const Deliver = *const fn (ctx: *anyopaque, events: u32) void;

pub const Waker = struct {
    ctx: *anyopaque,
    deliver: Deliver,
    events: std.atomic.Value(u32) = .init(0),
    /// Posted and not yet run.
    queued: std.atomic.Value(bool) = .init(false),
    dead: std.atomic.Value(bool) = .init(false),
    /// One for the owner, one for a queued post.
    refs: std.atomic.Value(u32) = .init(1),

    /// A waker calling `deliver(ctx, events)` on the main thread; prepares
    /// the main thread's queue (call it there).
    pub fn create(ctx: *anyopaque, deliver: Deliver) !*Waker {
        try mainthread.init();
        const w = try std.heap.c_allocator.create(Waker);
        w.* = .{ .ctx = ctx, .deliver = deliver };
        return w;
    }

    /// Adds event bit `bit`, and posts unless a post is queued. Any thread.
    pub fn post(w: *Waker, bit: u5) void {
        _ = w.events.fetchOr(@as(u32, 1) << bit, .acq_rel);
        if (w.queued.swap(true, .acq_rel)) return;
        _ = w.refs.fetchAdd(1, .acq_rel);
        if (!mainthread.post(w, run)) {
            w.queued.store(false, .release);
            w.release();
        }
    }

    fn run(ctx: ?*anyopaque) callconv(.c) void {
        const w: *Waker = @ptrCast(@alignCast(ctx.?));
        w.queued.store(false, .release);
        const events = w.events.swap(0, .acq_rel);
        if (!w.dead.load(.acquire) and events != 0) w.deliver(w.ctx, events);
        w.release();
    }

    /// The owner is gone: nothing is delivered any more. Main thread.
    pub fn kill(w: *Waker) void {
        w.dead.store(true, .release);
        w.release();
    }

    fn release(w: *Waker) void {
        if (w.refs.fetchSub(1, .acq_rel) == 1) std.heap.c_allocator.destroy(w);
    }
};
