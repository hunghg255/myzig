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

/// A renderer on the GPU presenting to `h`, `pw` × `ph` pixels, or null
/// when Direct3D 11 or its swap chain can't be had: frames are drawn on the
/// CPU then.
pub fn renderer(gpa: std.mem.Allocator, h: w.HWND, pw: usize, ph: usize) ?*d3d11.Renderer {
    const r = gpa.create(d3d11.Renderer) catch return null;
    r.* = d3d11.Renderer.init(gpa) catch |e| {
        std.log.info("myzig: no Direct3D ({s}): frames are drawn on the CPU", .{@errorName(e)});
        gpa.destroy(r);
        return null;
    };
    r.attach(h, @intCast(pw), @intCast(ph)) catch |e| {
        std.log.info("myzig: no swap chain ({s}): frames are drawn on the CPU", .{@errorName(e)});
        r.deinit();
        gpa.destroy(r);
        return null;
    };
    return r;
}

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
