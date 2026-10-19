//! Fetching the Metal layer's drawables off the main thread (macOS).
//!
//! `-[CAMetalLayer nextDrawable]` blocks while the layer's drawables are
//! all in use: the display holds them until its next refreshes, so a frame
//! following another would wait most of a refresh on the main thread,
//! which could do nothing else meanwhile (input waits). Instead, after each
//! frame presented as soon as drawn, a serial dispatch queue of the
//! main thread's priority fetches the next frame's drawable into a
//! one-slot mailbox, and tells the main thread once it has it.
//!
//! A frame that comes while the fetch is in flight is built at once (its
//! input handled, laid out, painted) and its drawing waits: the main
//! thread draws the surface's latest instances once the drawable came
//! (`Wake`). Frames of the display link's ticks are not built while a
//! fetch is in flight (`Renderer.ready`): the next is built once the
//! drawable came, and the link keeps ticking meanwhile.
//!
//! The main thread waits for a fetch in flight (`settle`) before it
//! changes the layer (its drawables' size or format, presenting with the
//! transaction, freeing it), so a fetch never races those; frames
//! presented with the transaction (a live resize's) take their drawable
//! on the main thread, as the first frame does.
//!
//! Threads: the queue only writes `slot`, then posts `completed` to the
//! main queue; everything else is the main thread's. The main thread reads
//! `slot` only once it knows the fetch ended: in `completed`, which the
//! queue posted after writing it, or after `settle`, which waited for the
//! queue (dispatch_sync); both order the write before the read.
const std = @import("std");
const builtin = @import("builtin");
const objc = @import("../objc.zig");

/// What the main thread runs once the drawable a frame waited for came.
pub const Wake = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) void,
};

/// The parts that touch the system, replaced in tests.
pub const Ops = struct {
    /// The layer, given to `fetch`.
    ctx: ?*anyopaque,
    /// Fetches the layer's next drawable, retained, on the queue's thread;
    /// null when none came (within a second).
    fetch: *const fn (ctx: ?*anyopaque) ?*anyopaque,
    release: *const fn (drawable: *anyopaque) void,
    /// Has the queue run `p.fetchNow()`, then the main thread `p.completed()`.
    enqueue: *const fn (p: *Presenter) void,
    /// Waits for the fetches queued to have ended.
    flush: *const fn (p: *Presenter) void,
    /// Frees `p` (and its queue).
    free: *const fn (p: *Presenter) void,
};

pub const Presenter = struct {
    ops: Ops,
    /// The serial queue fetching (macOS).
    queue: ?*anyopaque = null,
    /// The drawable fetched, retained, until a frame takes it.
    slot: ?*anyopaque = null,
    /// A fetch is in flight, as the main thread knows.
    fetching: bool = false,
    /// Completions posted to the main thread and not run yet, and how many
    /// of them are for fetches `settle` already waited for.
    posted: u32 = 0,
    stale: u32 = 0,
    /// A frame waits for the fetch: `wake` runs once it ended.
    wanted: bool = false,
    wake: ?Wake = null,
    /// Destroyed while completions were posted: the last one frees it.
    dead: bool = false,

    /// After a frame presented as soon as drawn: fetches the next frame's
    /// drawable, unless the presenter has or is fetching one.
    pub fn start(p: *Presenter) void {
        if (p.dead or p.fetching or p.slot != null) return;
        p.fetching = true;
        p.posted += 1;
        p.ops.enqueue(p);
    }

    /// Whether a fetch is in flight: a frame drawn now would wait for it.
    pub fn busy(p: *const Presenter) bool {
        return p.fetching;
    }

    /// Has `wake` run once the fetch in flight ended; false when none is,
    /// and a frame can take a drawable at once.
    pub fn waitFor(p: *Presenter) bool {
        if (!p.fetching) return false;
        p.wanted = true;
        return true;
    }

    /// Waits for a fetch in flight to end: before the layer changes.
    pub fn settle(p: *Presenter) void {
        if (!p.fetching) return;
        p.ops.flush(p);
        p.fetching = false;
        p.stale += 1;
    }

    /// The drawable fetched, retained, or null; after any fetch in flight.
    pub fn take(p: *Presenter) ?*anyopaque {
        p.settle();
        const d = p.slot;
        p.slot = null;
        return d;
    }

    /// Lets go of the drawable fetched: it is not the next frame's (the
    /// layer changes, or a frame takes its own).
    pub fn drain(p: *Presenter) void {
        if (p.take()) |d| p.ops.release(d);
    }

    /// On the queue's thread.
    pub fn fetchNow(p: *Presenter) void {
        p.slot = p.ops.fetch(p.ops.ctx);
    }

    /// On the main thread, once a fetch ended.
    pub fn completed(p: *Presenter) void {
        p.posted -= 1;
        if (p.dead) {
            if (p.posted == 0) p.ops.free(p);
            return;
        }
        if (p.stale > 0) p.stale -= 1 else p.fetching = false;
        if (p.fetching or !p.wanted) return;
        p.wanted = false;
        if (p.wake) |w| w.func(w.ctx);
    }

    /// Lets go of the drawable and the queue; frees the presenter now, or
    /// once the completions posted have run.
    pub fn destroy(p: *Presenter) void {
        p.drain();
        p.wake = null;
        p.wanted = false;
        p.dead = true;
        if (p.posted == 0) p.ops.free(p);
    }
};

/// macOS: a presenter of `layer`'s drawables, its queue at the main
/// thread's priority (user interactive), as the frames it serves.
pub fn create(layer: *anyopaque) !*Presenter {
    if (builtin.os.tag != .macos) return error.Unsupported;
    const p = try std.heap.c_allocator.create(Presenter);
    const attr = dispatch_queue_attr_make_with_qos_class(null, qos_class_user_interactive, 0);
    p.* = .{ .ops = mac_ops, .queue = dispatch_queue_create("myzig.drawables", attr) orelse {
        std.heap.c_allocator.destroy(p);
        return error.NoQueue;
    } };
    p.ops.ctx = layer;
    return p;
}

const mac = struct {
    fn fetch(layer: ?*anyopaque) ?*anyopaque {
        const pool = objc.Pool.push();
        defer pool.pop();
        const d = objc.msg(?objc.Object, @as(objc.Object, @ptrCast(layer.?)), "nextDrawable", .{}) orelse return null;
        return @ptrCast(objc.retain(d));
    }

    fn release(d: *anyopaque) void {
        objc.release(@ptrCast(d));
    }

    fn enqueue(p: *Presenter) void {
        dispatch_async_f(@ptrCast(p.queue.?), p, work);
    }

    fn work(ctx: ?*anyopaque) callconv(.c) void {
        const p: *Presenter = @ptrCast(@alignCast(ctx));
        p.fetchNow();
        objc.dispatchMain(p, done);
    }

    fn done(ctx: ?*anyopaque) callconv(.c) void {
        const p: *Presenter = @ptrCast(@alignCast(ctx));
        p.completed();
    }

    fn flush(p: *Presenter) void {
        dispatch_sync_f(@ptrCast(p.queue.?), null, nothing);
    }

    fn nothing(_: ?*anyopaque) callconv(.c) void {}

    fn free(p: *Presenter) void {
        if (p.queue) |q| objc.dispatch_release(q);
        std.heap.c_allocator.destroy(p);
    }
};

const mac_ops: Ops = .{ .ctx = null, .fetch = mac.fetch, .release = mac.release, .enqueue = mac.enqueue, .flush = mac.flush, .free = mac.free };

const qos_class_user_interactive: c_uint = 0x21;
extern "c" fn dispatch_queue_attr_make_with_qos_class(attr: ?*anyopaque, qos: c_uint, priority: c_int) ?*anyopaque;
extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) ?*anyopaque;
extern "c" fn dispatch_async_f(queue: objc.dispatch_queue_t, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn dispatch_sync_f(queue: objc.dispatch_queue_t, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
