//! What a run records, and the figures it makes of it. An event arrives
//! (when it was posted to the main thread: the time the main thread was
//! busy counts), is handled, and joins the next frame presented; the
//! frame reaches the screen at a time the system reports (macOS: the
//! drawable's presentedTime; Windows: the desktop's present time of the
//! first desktop image showing it), or never (another replaced it).
//! Times are seconds of the platform's frame clock (CACurrentMediaTime,
//! QueryPerformanceCounter). Safe from any thread.
const std = @import("std");
const Io = std.Io;
const figures_mod = @import("figures.zig");
const Figures = figures_mod.Figures;

pub const Event = struct {
    arrived: f64,
    handling: f64 = 0,
    handled: f64 = 0,
};

pub const Sample = struct {
    event: Event,
    presented: f64,
    shown: f64,
};

const Frame = struct {
    presented: f64,
    events: []Event,
};

pub const Recorder = struct {
    gpa: std.mem.Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    measuring: bool = false,
    /// Handled since the last frame presented.
    pending: std.ArrayList(Event) = .empty,
    /// Presented and not shown yet, by id (the drawable's, or a sequence
    /// number the window shows).
    frames: std.AutoHashMapUnmanaged(u64, Frame) = .empty,
    samples: std.ArrayList(Sample) = .empty,
    /// When the frames presented while measuring were shown.
    shown_at: std.ArrayList(f64) = .empty,
    presents: usize = 0,
    not_shown: usize = 0,
    /// The main thread's waits for drawables while measuring, in seconds.
    main_waits: std.ArrayList(f64) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: Io) Recorder {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(r: *Recorder) void {
        var it = r.frames.valueIterator();
        while (it.next()) |f| r.gpa.free(f.events);
        r.frames.deinit(r.gpa);
        r.pending.deinit(r.gpa);
        r.samples.deinit(r.gpa);
        r.shown_at.deinit(r.gpa);
        r.main_waits.deinit(r.gpa);
    }

    fn lock(r: *Recorder) void {
        r.mutex.lockUncancelable(r.io);
    }

    fn unlock(r: *Recorder) void {
        r.mutex.unlock(r.io);
    }

    pub fn setMeasuring(r: *Recorder, on: bool) void {
        r.lock();
        defer r.unlock();
        r.measuring = on;
    }

    /// The main thread handled `e`: the next frame presented shows it.
    pub fn handled(r: *Recorder, e: Event) void {
        r.lock();
        defer r.unlock();
        r.pending.append(r.gpa, e) catch {};
    }

    /// The frame `id` presented at `at`, showing the events handled since
    /// the last; a frame presented again (a command buffer's
    /// presentDrawable: presents with present) counts once: false then.
    pub fn present(r: *Recorder, id: u64, at: f64) bool {
        r.lock();
        defer r.unlock();
        const gop = r.frames.getOrPut(r.gpa, id) catch return false;
        if (gop.found_existing) return false;
        gop.value_ptr.* = .{ .presented = at, .events = r.pending.toOwnedSlice(r.gpa) catch &.{} };
        if (r.measuring) r.presents += 1;
        return true;
    }

    /// The frame `id` reached the screen at `at`; 0 tells that it never
    /// did, replaced by the next, which shows its events too: they are
    /// not counted.
    pub fn shown(r: *Recorder, id: u64, at: f64) void {
        r.lock();
        defer r.unlock();
        const kv = r.frames.fetchRemove(id) orelse return;
        r.show(kv.value, at, at == 0);
    }

    /// The window shows frame `id` from `at`, read from its pixels: every
    /// frame up to it not seen yet reached the screen then, within it
    /// (those before it are counted as not shown on their own, their
    /// events at that time).
    pub fn shownUpTo(r: *Recorder, id: u64, at: f64) void {
        r.lock();
        defer r.unlock();
        var done: std.ArrayList(u64) = .empty;
        defer done.deinit(r.gpa);
        var it = r.frames.iterator();
        while (it.next()) |kv| if (kv.key_ptr.* <= id) done.append(r.gpa, kv.key_ptr.*) catch return;
        var first = true;
        std.mem.sort(u64, done.items, {}, std.sort.desc(u64));
        for (done.items) |k| {
            const f = r.frames.fetchRemove(k).?.value;
            if (r.measuring and first) r.shown_at.append(r.gpa, at) catch {};
            if (r.measuring and !first) r.not_shown += 1;
            first = false;
            r.addSamples(f, at);
        }
    }

    fn show(r: *Recorder, f: Frame, at: f64, never: bool) void {
        defer r.gpa.free(f.events);
        if (!r.measuring) return;
        if (never) {
            r.not_shown += 1;
            return;
        }
        r.shown_at.append(r.gpa, at) catch {};
        for (f.events) |e| r.samples.append(r.gpa, .{ .event = e, .presented = f.presented, .shown = at }) catch {};
    }

    fn addSamples(r: *Recorder, f: Frame, at: f64) void {
        defer r.gpa.free(f.events);
        if (!r.measuring) return;
        for (f.events) |e| r.samples.append(r.gpa, .{ .event = e, .presented = f.presented, .shown = at }) catch {};
    }

    /// The main thread waited `seconds` for a drawable.
    pub fn mainWait(r: *Recorder, seconds: f64) void {
        r.lock();
        defer r.unlock();
        if (r.measuring) r.main_waits.append(r.gpa, seconds) catch {};
    }

    /// The run's figures, at a display of `refresh` Hz; `need_events`:
    /// a run of input that showed none failed.
    pub fn figures(r: *Recorder, refresh: f64, need_events: bool) !Figures {
        r.lock();
        defer r.unlock();
        if (r.presents == 0) return error.NoFramePresented;
        var f: Figures = .{ .refresh = refresh, .events = @floatFromInt(r.samples.items.len) };
        const np: f64 = @floatFromInt(r.presents);
        for (r.main_waits.items) |w| {
            f.main_wait += w * 1000 / np;
            if (w > 0.004) f.blocked += 100 / np;
        }
        f.not_shown = 100 * @as(f64, @floatFromInt(r.not_shown)) / np;
        f.new_frames = newFrames(r.gpa, r.shown_at.items, refresh);
        const ss = r.samples.items;
        if (ss.len == 0) {
            if (need_events) return error.NoEventShown;
            return f;
        }
        const total = try r.gpa.alloc(f64, ss.len);
        defer r.gpa.free(total);
        const k: f64 = @floatFromInt(ss.len);
        for (ss, total) |s, *x| {
            x.* = (s.shown - s.event.arrived) * 1000;
            f.queue += (s.event.handling - s.event.arrived) * 1000 / k;
            f.handle += (s.event.handled - s.event.handling) * 1000 / k;
            f.to_present += (s.presented - s.event.handled) * 1000 / k;
            f.to_screen += (s.shown - s.presented) * 1000 / k;
        }
        std.mem.sort(f64, total, {}, std.sort.asc(f64));
        for (total) |x| f.mean += x / k;
        f.p50 = figures_mod.percentile(total, 0.5);
        f.p90 = figures_mod.percentile(total, 0.9);
        f.p99 = figures_mod.percentile(total, 0.99);
        return f;
    }
};

/// The percent of the display's refreshes, from the first frame shown to
/// the last, that showed a new one.
pub fn newFrames(gpa: std.mem.Allocator, shown_at: []const f64, refresh: f64) f64 {
    if (shown_at.len < 2 or refresh <= 0) return 0;
    var refreshes: std.AutoHashMapUnmanaged(i64, void) = .empty;
    defer refreshes.deinit(gpa);
    var lo = shown_at[0];
    var hi = shown_at[0];
    for (shown_at) |x| {
        lo = @min(lo, x);
        hi = @max(hi, x);
        refreshes.put(gpa, @intFromFloat(@round(x * refresh)), {}) catch return 0;
    }
    const span = @round((hi - lo) * refresh) + 1;
    return 100 * @as(f64, @floatFromInt(refreshes.count())) / span;
}

const t = std.testing;

test "events join the frame presented after them, and count once it showed" {
    var r: Recorder = .init(t.allocator, t.io);
    defer r.deinit();
    // Before measuring: presented and shown, not counted.
    r.handled(.{ .arrived = 0.9, .handling = 0.9, .handled = 0.901 });
    _ = r.present(1, 0.905);
    r.shown(1, 0.92);
    r.setMeasuring(true);
    // Two events in one frame, at a 100 Hz display.
    r.handled(.{ .arrived = 1.000, .handling = 1.001, .handled = 1.002 });
    r.handled(.{ .arrived = 1.003, .handling = 1.003, .handled = 1.004 });
    _ = r.present(2, 1.010);
    try t.expect(!r.present(2, 1.011)); // presentDrawable: then present: once
    r.mainWait(0.005);
    r.handled(.{ .arrived = 1.020, .handling = 1.020, .handled = 1.021 });
    _ = r.present(3, 1.025);
    // Frame 3 was replaced before the screen showed it; frame 2 showed.
    r.shown(3, 0);
    r.shown(2, 1.030);
    r.handled(.{ .arrived = 1.040, .handling = 1.040, .handled = 1.041 });
    _ = r.present(4, 1.045);
    r.shown(4, 1.050);
    const f = try r.figures(100, true);
    try t.expectEqual(@as(f64, 3), f.events);
    try t.expectApproxEqAbs(@as(f64, (30.0 + 27.0 + 10.0)) / 3.0, f.mean, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 27), f.p50, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 27), f.p90, 1e-9);
    try t.expectApproxEqAbs(@as(f64, (1.0 + 0.0 + 0.0)) / 3.0, f.queue, 1e-9);
    try t.expectApproxEqAbs(@as(f64, (1.0 + 1.0 + 1.0)) / 3.0, f.handle, 1e-9);
    try t.expectApproxEqAbs(@as(f64, (8.0 + 6.0 + 4.0)) / 3.0, f.to_present, 1e-9);
    try t.expectApproxEqAbs(@as(f64, (20.0 + 20.0 + 5.0)) / 3.0, f.to_screen, 1e-9);
    // Three frames presented while measuring, one never shown, one wait
    // over 4 ms.
    try t.expectApproxEqAbs(@as(f64, 100.0 / 3.0), f.not_shown, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 5.0 / 3.0), f.main_wait, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 100.0 / 3.0), f.blocked, 1e-9);
    // Shown at refreshes 103 and 105 of three: two new.
    try t.expectApproxEqAbs(@as(f64, 200.0 / 3.0), f.new_frames, 1e-9);
}

test "frames read from the window's pixels: the one seen and those before it" {
    var r: Recorder = .init(t.allocator, t.io);
    defer r.deinit();
    r.setMeasuring(true);
    for (1..4) |i| {
        const at: f64 = @floatFromInt(i);
        r.handled(.{ .arrived = at, .handling = at, .handled = at + 0.001 });
        _ = r.present(i, at + 0.001);
    }
    // Frame 3 seen first: 1 and 2 never showed on their own.
    r.shownUpTo(3, 3.5);
    r.shownUpTo(3, 3.6);
    const f = try r.figures(60, true);
    try t.expectEqual(@as(f64, 3), f.events);
    try t.expectApproxEqAbs(@as(f64, 200.0 / 3.0), f.not_shown, 1e-9);
    try t.expectApproxEqAbs(@as(f64, (2500.0 + 1500.0 + 500.0)) / 3.0, f.mean, 1e-6);
}

test "a run without frames, or of input without events shown, fails" {
    var r: Recorder = .init(t.allocator, t.io);
    defer r.deinit();
    r.setMeasuring(true);
    try t.expectError(error.NoFramePresented, r.figures(60, true));
    _ = r.present(1, 1);
    r.shown(1, 1.01);
    try t.expectError(error.NoEventShown, r.figures(60, true));
    // An animation's run counts frames only.
    const f = try r.figures(60, false);
    try t.expectEqual(@as(f64, 0), f.events);
}

test "new frames: the share of refreshes showing one" {
    // Every refresh at 60 Hz for a sixth of a second.
    var every: [11]f64 = undefined;
    for (&every, 0..) |*x, i| x.* = 10 + @as(f64, @floatFromInt(i)) / 60;
    try t.expectApproxEqAbs(@as(f64, 100), newFrames(t.allocator, &every, 60), 1e-9);
    // Every other refresh.
    var half: [6]f64 = undefined;
    for (&half, 0..) |*x, i| x.* = 10 + @as(f64, @floatFromInt(i * 2)) / 60;
    try t.expectApproxEqAbs(@as(f64, 600.0 / 11.0), newFrames(t.allocator, &half, 60), 1e-9);
    try t.expectEqual(@as(f64, 0), newFrames(t.allocator, &.{1}, 60));
}
