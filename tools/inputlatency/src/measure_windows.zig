//! A run on Windows. The window shows without taking the keyboard or the
//! front (SW_SHOWNOACTIVATE, topmost so that nothing covers the probe).
//! Input is posted into the tool's own window, never through SendInput,
//! which types into whatever window is in front: the driver thread posts
//! an injection message whose window procedure (a subclass of myzig's)
//! notes when it began and finished handling it, around the real message
//! (WM_CHAR, WM_MOUSEWHEEL, WM_LBUTTONDOWN...) it hands myzig's. An event
//! arrives when posted, so the time the main thread was busy counts.
//!
//! The frame showing an event is the next one built after it: it shows
//! the event's number in the probe (`probe.zig`). A thread reads the probe
//! out of each desktop image the compositor presents (`dup_windows.zig`),
//! whose present time is when the frame reached the screen. A frame
//! presents within the window procedure that drew it, or once the swap
//! chain has room (WM_PRESENT): "to present" is then 0 and "to screen"
//! counts from the end of handling, and the main thread's waits for
//! drawables are macOS's only.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const plan = @import("plan.zig");
const record = @import("record.zig");
const view_mod = @import("view.zig");
const probe = @import("probe.zig");
const dup_mod = @import("dup_windows.zig");
const Options = @import("options.zig").Options;
const Figures = @import("figures.zig").Figures;

const HWND = *anyopaque;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const WndProc = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
const POINT = extern struct { x: i32, y: i32 };

extern "user32" fn SetWindowLongPtrW(hwnd: HWND, index: i32, value: isize) callconv(.winapi) isize;
extern "user32" fn CallWindowProcW(prev: WndProc, hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn PostMessageW(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(.winapi) i32;
extern "user32" fn ShowWindow(hwnd: HWND, cmd: i32) callconv(.winapi) i32;
extern "user32" fn SetWindowPos(hwnd: HWND, after: ?HWND, x: i32, y: i32, cx: i32, cy: i32, flags: u32) callconv(.winapi) i32;
extern "user32" fn ClientToScreen(hwnd: HWND, p: *POINT) callconv(.winapi) i32;
extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) u32;
extern "user32" fn GetDC(hwnd: ?HWND) callconv(.winapi) ?*anyopaque;
extern "user32" fn ReleaseDC(hwnd: ?HWND, dc: *anyopaque) callconv(.winapi) i32;
extern "gdi32" fn GetDeviceCaps(dc: *anyopaque, index: i32) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) i32;

const WM_APP = 0x8000;
/// The driver's injections: wParam is the slot of `ring`.
const WM_INJECT = WM_APP + 0x3F0;
const WM_CLOSE = 0x0010;
const WM_CHAR = 0x0102;
const WM_MOUSEMOVE = 0x0200;
const WM_LBUTTONDOWN = 0x0201;
const WM_LBUTTONUP = 0x0202;
const WM_MOUSEWHEEL = 0x020A;
const MK_LBUTTON = 1;

/// Seconds on the counter's clock, which the desktop's present times use.
fn now() f64 {
    var c: i64 = 0;
    _ = QueryPerformanceCounter(&c);
    return ticks(c);
}

var freq: f64 = 1;

fn ticks(c: i64) f64 {
    return @as(f64, @floatFromInt(c)) / freq;
}

const Injection = struct { msg: u32, wp: WPARAM, lp: LPARAM, arrived: f64, timed: bool };

/// The run, for the window procedure and the threads.
const Run = struct {
    rec: record.Recorder,
    state: view_mod.State,
    hwnd: HWND = undefined,
    prev: WndProc = undefined,
    ring: [1024]Injection = undefined,
    next_slot: usize = 0,
    scale: f32 = 1,
    done: std.atomic.Value(bool) = .init(false),
    failed: ?anyerror = null,
};

var run: *Run = undefined;

fn wndProc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT {
    if (msg != WM_INJECT) return CallWindowProcW(run.prev, hwnd, msg, wp, lp);
    const inj = run.ring[wp % run.ring.len];
    if (!inj.timed) return CallWindowProcW(run.prev, hwnd, inj.msg, inj.wp, inj.lp);
    var e: record.Event = .{ .arrived = inj.arrived, .handling = now() };
    // The frame it draws shows its number.
    run.state.seq += 1;
    _ = CallWindowProcW(run.prev, hwnd, inj.msg, inj.wp, inj.lp);
    e.handled = now();
    run.rec.handled(e);
    _ = run.rec.present(run.state.seq, e.handled);
    return 0;
}

/// Each frame of the animations: a number of its own.
fn onFrame(s: *view_mod.State) void {
    s.seq += 1;
    _ = run.rec.present(s.seq, now());
}

/// From the driver's thread: has the main thread handle `msg` as if it
/// arrived now.
fn inject(msg: u32, wp: WPARAM, lp: LPARAM, timed: bool) void {
    const slot = run.next_slot;
    run.next_slot += 1;
    run.ring[slot % run.ring.len] = .{ .msg = msg, .wp = wp, .lp = lp, .arrived = now(), .timed = timed };
    _ = PostMessageW(run.hwnd, WM_INJECT, slot, 0);
}

/// A point of the view in the window's client pixels, as lParam.
fn clientLparam(x: f32, y: f32) LPARAM {
    const px: i32 = @intFromFloat(@round(x * run.scale));
    const py: i32 = @intFromFloat(@round(y * run.scale));
    return @as(LPARAM, @as(u16, @bitCast(@as(i16, @intCast(py))))) << 16 | @as(u16, @bitCast(@as(i16, @intCast(px))));
}

fn screenLparam(x: f32, y: f32) LPARAM {
    var p: POINT = .{ .x = @intFromFloat(@round(x * run.scale)), .y = @intFromFloat(@round(y * run.scale)) };
    _ = ClientToScreen(run.hwnd, &p);
    return @as(LPARAM, @as(u16, @bitCast(@as(i16, @intCast(p.y))))) << 16 | @as(u16, @bitCast(@as(i16, @intCast(p.x))));
}

pub fn measure(init: std.process.Init, o: Options) !Figures {
    const gpa = init.gpa;
    const io = init.io;
    var f: i64 = 1;
    _ = QueryPerformanceFrequency(&f);
    freq = @floatFromInt(f);
    const r = try gpa.create(Run);
    defer gpa.destroy(r);
    r.* = .{ .rec = .init(gpa, io), .state = .init(gpa, o.mode) };
    defer r.rec.deinit();
    defer r.state.deinit();
    run = r;
    r.state.boxes = o.boxes;
    r.state.show_probe = true;
    r.state.on_frame = onFrame;

    const app = try myzig.App.create(init, .{ .name = "inputlatency", .quit_on_signal = true });
    defer app.destroy();
    const win = try app.newWindow(.{
        .title = "inputlatency",
        .width = 800,
        .height = 600,
        .x = if (o.x) |x| x else null,
        .y = if (o.y) |y| y else null,
        .always_on_top = true,
        .visible = false,
        .content = .{ .view = .init(&r.state, view_mod.State.view) },
    });
    r.hwnd = win.hwnd orelse return error.NoWindow;
    r.scale = @as(f32, @floatFromInt(GetDpiForWindow(r.hwnd))) / 96;
    r.prev = @ptrFromInt(@as(usize, @bitCast(SetWindowLongPtrW(r.hwnd, -4, @bitCast(@intFromPtr(&wndProc))))));
    // Out of the user's way: neither the keyboard nor the front taken.
    _ = ShowWindow(r.hwnd, 4); // SW_SHOWNOACTIVATE
    _ = SetWindowPos(r.hwnd, @ptrFromInt(@as(usize, @bitCast(@as(isize, -1)))), 0, 0, 0, 0, 0x0013); // HWND_TOPMOST; NOSIZE, NOMOVE, NOACTIVATE

    var refresh: f64 = 60;
    if (GetDC(null)) |dc| {
        refresh = @floatFromInt(@max(1, GetDeviceCaps(dc, 116))); // VREFRESH
        _ = ReleaseDC(null, dc);
    }
    var probe_at: POINT = .{ .x = @intFromFloat(probe.sample * r.scale), .y = @intFromFloat(probe.sample * r.scale) };
    _ = ClientToScreen(r.hwnd, &probe_at);
    var dup = try dup_mod.Duplication.open(probe_at.x, probe_at.y);
    defer dup.close();

    const reader = try std.Thread.spawn(.{}, readProbe, .{ &dup, probe_at });
    const driver = try std.Thread.spawn(.{}, drive, .{ io, o, refresh });
    try app.run();
    r.done.store(true, .release);
    driver.join();
    reader.join();
    if (r.failed) |e| return e;
    return r.rec.figures(refresh, o.mode.input());
}

/// The reader's thread: the probe of each desktop image presented.
fn readProbe(dup: *dup_mod.Duplication, at: POINT) void {
    var unwrap: probe.Unwrap = .{};
    while (!run.done.load(.acquire)) {
        const px = (dup.next(50, at.x, at.y) catch |e| {
            run.failed = e;
            return;
        }) orelse continue;
        const bits = probe.decode(px.bgra[2], px.bgra[1], px.bgra[0]) orelse continue;
        run.rec.shownUpTo(unwrap.next(bits), ticks(px.presented));
    }
}

fn sleepMs(io: std.Io, ms: f64) void {
    io.sleep(.fromMicroseconds(@intFromFloat(ms * 1000)), .awake) catch {};
}

/// The driver's thread: the run's plan, then the window closes.
fn drive(io: std.Io, o: Options, refresh: f64) void {
    defer _ = PostMessageW(run.hwnd, WM_CLOSE, 0, 0);
    // The first frames, at full speed.
    sleepMs(io, 1500);
    if (!o.mode.input()) {
        // Warmup and events count refreshes.
        sleepMs(io, @as(f64, @floatFromInt(o.warmup)) * 1000 / refresh);
        run.rec.setMeasuring(true);
        sleepMs(io, @as(f64, @floatFromInt(o.events)) * 1000 / refresh);
    } else {
        var p: plan.Plan = .init(o.mode, o.warmup, o.events, o.seed);
        var measuring = false;
        // The pointer's place, in view points, as the box was pressed.
        var x: f32 = 0;
        var y: f32 = 0;
        while (p.next()) |s| {
            if (s.measured and !measuring) {
                run.rec.setMeasuring(true);
                measuring = true;
            }
            switch (s.action) {
                .key => inject(WM_CHAR, 'a', 1, true),
                .scroll_begin, .scroll_end => {},
                // A precision touchpad's small delta: 3 points, as the
                // surface turns 120ths of a notch into 48 points a notch.
                .scroll => |dy| inject(WM_MOUSEWHEEL, @bitCast(@as(isize, @as(i16, @intFromFloat(@round(dy * 120 / 48)))) << 16), screenLparam(300, 300), true),
                .down => {
                    // Read while the main thread waits in the pause after
                    // the last release: the box no longer moves.
                    const b = run.state.boxPoint();
                    x = b.x;
                    y = b.y;
                    inject(WM_LBUTTONDOWN, MK_LBUTTON, clientLparam(x, y), false);
                },
                .drag => |dx| {
                    x += dx;
                    inject(WM_MOUSEMOVE, MK_LBUTTON, clientLparam(x, y), true);
                },
                .up => inject(WM_LBUTTONUP, 0, clientLparam(x, y), false),
            }
            sleepMs(io, s.wait_ms);
        }
    }
    // The last frames reach the screen.
    sleepMs(io, 300);
    run.rec.setMeasuring(false);
}
