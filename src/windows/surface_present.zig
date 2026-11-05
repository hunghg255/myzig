//! Presenting Direct3D frames without blocking the main thread, after
//! mygo's: the swap chain keeps one frame waiting ahead of the screen and
//! has a frame latency object, which DXGI signals as the screen takes a
//! frame (`d3d11.zig`). A frame presents once a wait on it succeeded, the
//! wait's token; a frame drawn when it is not signaled yet waits
//! (`Surface.pending`) while a thread waits on the object, and presents
//! when the thread posts `WM_PRESENT`, rather than blocking in `Present`
//! until the screen took the last. Frames the animation timer asks for
//! meanwhile are not built; frames for input draw into the frame waiting
//! (`Surface.present`). Every present takes one token, so the object's
//! count stays that of the frames the screen can take.
const std = @import("std");
const w = @import("win32.zig");
const d3d11 = @import("../ui/d3d11.zig");

pub const WM_PRESENT = w.WM_APP + 2;
/// The renderer's thread is done: the next paint can take it.
pub const WM_GPU_READY = w.WM_APP + 4;

/// A renderer on the GPU being made. A driver takes tens of milliseconds
/// to make a device, more when its caches are cold, so a thread makes it
/// while the window's first frames are drawn on the CPU. The swap chain is
/// made on the main thread (`finish`): DXGI talks to the window's thread,
/// which must not wait for it. The thread needs nothing of the main one, so
/// the main one may wait for it (`cancel`).
pub const Startup = struct {
    gpa: std.mem.Allocator,
    hwnd: w.HWND,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    /// Holds the renderer once `done`, unless it could not be made.
    made: ?d3d11.Renderer = null,

    /// Starts making a renderer for `hwnd`; null without the memory to.
    pub fn begin(gpa: std.mem.Allocator, hwnd: w.HWND) ?*Startup {
        const s = gpa.create(Startup) catch return null;
        s.* = .{ .gpa = gpa, .hwnd = hwnd };
        // A stack as Windows gives a thread: a default one would commit 16 MB.
        s.thread = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, run, .{s}) catch blk: {
            run(s);
            break :blk null;
        };
        return s;
    }

    fn run(s: *Startup) void {
        s.made = d3d11.Renderer.init(s.gpa) catch |e| blk: {
            std.log.info("myzig: no Direct3D ({s}): frames are drawn on the CPU", .{@errorName(e)});
            break :blk null;
        };
        s.done.store(true, .release);
        _ = w.PostMessageW(s.hwnd, WM_GPU_READY, 0, 0);
    }

    /// Whether `finish` can be called without waiting.
    pub fn ready(s: *const Startup) bool {
        return s.done.load(.acquire);
    }

    /// The renderer, presenting to the window, `pw` × `ph` pixels, or null
    /// when Direct3D 11 or its swap chain can't be had: frames are drawn on
    /// the CPU then. Nothing it draws shows before its first present, so
    /// the frame GDI copied stays until then. Frees `s`.
    pub fn finish(s: *Startup, pw: usize, ph: usize) ?*d3d11.Renderer {
        const gpa = s.gpa;
        const h = s.hwnd;
        const made = s.wait();
        var r = made orelse return null;
        const kept = gpa.create(d3d11.Renderer) catch {
            r.deinit();
            return null;
        };
        kept.* = r;
        kept.attach(h, @intCast(pw), @intCast(ph)) catch |e| {
            std.log.info("myzig: no swap chain ({s}): frames are drawn on the CPU", .{@errorName(e)});
            kept.deinit();
            gpa.destroy(kept);
            return null;
        };
        return kept;
    }

    /// The window goes first: waits for the thread, dropping what it made.
    pub fn cancel(s: *Startup) void {
        if (s.wait()) |made| {
            var r = made;
            r.deinit();
        }
    }

    fn wait(s: *Startup) ?d3d11.Renderer {
        if (s.thread) |t| t.join();
        const made = s.made;
        s.gpa.destroy(s);
        return made;
    }
};

const HANDLE = *anyopaque;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual: w.BOOL, initial: w.BOOL, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetEvent(h: HANDLE) callconv(.winapi) w.BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) w.BOOL;

const infinite: u32 = 0xffffffff;
/// The longest a wait takes: the screen takes a frame each refresh, but
/// none while the window shows nowhere, when a frame presents without its
/// token.
const timeout_ms = 1000;

/// What the waiting thread reads.
const Shared = struct {
    latency: HANDLE,
    hwnd: w.HWND,
    arm: HANDLE,
    quit: std.atomic.Value(bool) = .init(false),

    fn run(s: *Shared) void {
        while (true) {
            _ = WaitForSingleObject(s.arm, infinite);
            if (s.quit.load(.acquire)) return;
            const signaled = WaitForSingleObject(s.latency, timeout_ms) == 0;
            _ = w.PostMessageW(s.hwnd, WM_PRESENT, @intFromBool(signaled), 0);
        }
    }
};

/// A swap chain's frame latency object, on the main thread.
pub const Latency = struct {
    gpa: std.mem.Allocator,
    handle: ?HANDLE = null,
    /// A wait succeeded that no present took yet.
    token: bool = false,
    /// The thread waits on the object, and presents it owes tokens for
    /// (those that presented while it waited).
    waiting: bool = false,
    owed: u32 = 0,
    shared: ?*Shared = null,
    thread: ?std.Thread = null,

    /// Whether a frame can present at once, taking its token without
    /// waiting.
    pub fn ready(l: *Latency) bool {
        const h = l.handle orelse return true;
        if (l.token) return true;
        if (l.waiting) return false;
        l.token = WaitForSingleObject(h, 0) == 0;
        return l.token;
    }

    /// Has the thread wait for the object and post `WM_PRESENT` to `hwnd`.
    pub fn arm(l: *Latency, hwnd: w.HWND) void {
        const h = l.handle orelse return;
        if (l.waiting) return;
        if (l.shared == null) {
            const ev = CreateEventW(null, 0, 0, null) orelse return;
            const s = l.gpa.create(Shared) catch {
                _ = CloseHandle(ev);
                return;
            };
            s.* = .{ .latency = h, .hwnd = hwnd, .arm = ev };
            // It only waits and posts: a default stack would commit 16 MB.
            l.thread = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, Shared.run, .{s}) catch {
                _ = CloseHandle(ev);
                l.gpa.destroy(s);
                return;
            };
            l.shared = s;
        }
        l.waiting = true;
        _ = SetEvent(l.shared.?.arm);
    }

    /// The thread's wait ended, `signaled` or timed out; false when no
    /// wait was armed (a message left from before `stop`).
    pub fn done(l: *Latency, signaled: bool) bool {
        if (!l.waiting) return false;
        l.waiting = false;
        if (signaled) {
            if (l.owed > 0) l.owed -= 1 else l.token = true;
        }
        return true;
    }

    /// Takes the token a present needs: waiting for it (a resize's frame),
    /// at most `timeout_ms`, unless `wait` is false or the thread waits.
    pub fn take(l: *Latency, wait: bool) void {
        const h = l.handle orelse return;
        if (l.token) {
            l.token = false;
        } else if (l.waiting) {
            l.owed += 1;
        } else if (wait) {
            _ = WaitForSingleObject(h, timeout_ms);
        }
    }

    /// Stops the thread (a renderer goes, or the window): the object is
    /// the swap chain's, closed with it.
    pub fn stop(l: *Latency) void {
        if (l.shared) |s| {
            s.quit.store(true, .release);
            _ = SetEvent(s.arm);
            if (l.thread) |t| t.join();
            _ = CloseHandle(s.arm);
            l.gpa.destroy(s);
        }
        l.* = .{ .gpa = l.gpa };
    }
};
