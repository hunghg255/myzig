//! The cores the CPU renderer draws a frame's bands on: threads started
//! when a frame first needs them, that then wait between frames, as
//! starting threads each frame costs about what drawing a small one does.
const std = @import("std");

pub const max = 8;

/// The work the threads share: each calls `run(ctx)`, as the caller does.
const Job = struct {
    run: *const fn (*anyopaque) void,
    ctx: *anyopaque,
};

/// Draws with the pool: one caller at a time.
var busy: std.atomic.Value(bool) = .init(false);
/// Threads started (by the caller holding `busy`).
var started: usize = 0;
/// Each thread's count of jobs, bumped to wake it for one: the threads
/// a job does not need sleep on.
var jobs: [max - 1]std.atomic.Value(u32) = @splat(.init(0));
/// Threads still in the job.
var pending: std.atomic.Value(u32) = .init(0);
var job: Job = undefined;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn worker(index: usize) void {
    const count = &jobs[index];
    var seen: u32 = 0;
    while (true) {
        while (count.load(.acquire) == seen) io().futexWaitUncancelable(u32, &count.raw, seen);
        seen +%= 1;
        job.run(job.ctx);
        if (pending.fetchSub(1, .acq_rel) == 1) io().futexWake(u32, &pending.raw, 1);
    }
}

/// Calls `run(ctx)` on the calling thread and on up to `helpers` threads
/// of the pool at once, returning when all have returned. False, having
/// called nothing, when another thread is using the pool.
pub fn share(helpers: usize, run: *const fn (*anyopaque) void, ctx: *anyopaque) bool {
    if (busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return false;
    defer busy.store(false, .release);
    const n = @min(helpers, max - 1);
    while (started < n) : (started += 1) {
        const t = std.Thread.spawn(.{}, worker, .{started}) catch break;
        t.detach();
    }
    const helping = @min(n, started);
    job = .{ .run = run, .ctx = ctx };
    pending.store(@intCast(helping), .monotonic);
    for (jobs[0..helping]) |*count| {
        _ = count.fetchAdd(1, .release);
        io().futexWake(u32, &count.raw, 1);
    }
    run(ctx);
    while (true) {
        const p = pending.load(.acquire);
        if (p == 0) return true;
        io().futexWaitUncancelable(u32, &pending.raw, p);
    }
}
