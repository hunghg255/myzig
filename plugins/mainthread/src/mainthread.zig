//! Running work on the main thread from any other: what plugins use to
//! hand results of their threads (a response, a message, a file changed)
//! to pages and views, which live on the main thread. It is the main
//! thread's own queue on each platform: libdispatch's main queue on macOS,
//! GLib's default context on Linux (GTK's loop), and a message-only window
//! on Windows. Nothing polls.
//!
//!     try mainthread.init(); // once, on the main thread
//!     mainthread.post(job, Job.run); // from any thread
const std = @import("std");
const builtin = @import("builtin");

pub const Func = *const fn (ctx: ?*anyopaque) callconv(.c) void;

const impl = switch (builtin.os.tag) {
    .macos => mac,
    .linux => linux,
    .windows => windows,
    else => @compileError("mainthread: macOS, Linux and Windows only"),
};

/// Prepares the queue: call it on the main thread before `post` (the
/// services of plugins do when they are created). Calling it again does
/// nothing.
pub fn init() !void {
    return impl.init();
}

/// Runs `func(ctx)` on the main thread, soon. Safe from any thread. False
/// when it could not be queued (no `init`, or out of memory): the caller
/// then still owns `ctx`.
pub fn post(ctx: ?*anyopaque, func: Func) bool {
    return impl.post(ctx, func);
}

/// Runs the main thread's queue until `done` is set: for tests and tools
/// that have no event loop of their own. Main thread only.
pub fn runUntil(done: *const std.atomic.Value(bool)) void {
    while (!done.load(.acquire)) impl.runOnce();
}

const mac = struct {
    extern "c" var _dispatch_main_q: opaque {};
    extern "c" fn dispatch_async_f(queue: *anyopaque, ctx: ?*anyopaque, work: Func) void;
    extern "c" fn CFRunLoopRunInMode(mode: *const anyopaque, seconds: f64, return_after: bool) i32;
    extern "c" const kCFRunLoopDefaultMode: *const anyopaque;

    fn init() !void {}

    fn post(ctx: ?*anyopaque, func: Func) bool {
        dispatch_async_f(@ptrCast(&_dispatch_main_q), ctx, func);
        return true;
    }

    fn runOnce() void {
        _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1e6, true);
    }
};

const linux = struct {
    const IdleFn = *const fn (data: ?*anyopaque) callconv(.c) c_int;
    var g_idle_add: ?*const fn (func: IdleFn, data: ?*anyopaque) callconv(.c) c_uint = null;
    var g_main_context_iteration: ?*const fn (ctx: ?*anyopaque, may_block: c_int) callconv(.c) c_int = null;

    const Thunk = struct { ctx: ?*anyopaque, func: Func };

    fn init() !void {
        if (g_idle_add != null) return;
        // GTK has loaded GLib already: this finds the same library.
        const lib = std.c.dlopen("libglib-2.0.so.0", .{ .NOW = true }) orelse return error.GlibMissing;
        g_idle_add = @ptrCast(@alignCast(std.c.dlsym(lib, "g_idle_add") orelse return error.GlibMissing));
        g_main_context_iteration = @ptrCast(@alignCast(std.c.dlsym(lib, "g_main_context_iteration") orelse return error.GlibMissing));
    }

    fn run(data: ?*anyopaque) callconv(.c) c_int {
        const t: *Thunk = @ptrCast(@alignCast(data));
        const job = t.*;
        std.heap.c_allocator.destroy(t);
        job.func(job.ctx);
        return 0; // G_SOURCE_REMOVE
    }

    fn post(ctx: ?*anyopaque, func: Func) bool {
        const add = g_idle_add orelse return false;
        const t = std.heap.c_allocator.create(Thunk) catch return false;
        t.* = .{ .ctx = ctx, .func = func };
        _ = add(run, t);
        return true;
    }

    fn runOnce() void {
        if (g_main_context_iteration) |iterate| _ = iterate(null, 1);
    }
};

const windows = struct {
    const HWND = *opaque {};
    const WNDPROC = *const fn (hwnd: HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize;
    const WNDCLASSEXW = extern struct {
        cbSize: u32 = @sizeOf(WNDCLASSEXW),
        style: u32 = 0,
        lpfnWndProc: WNDPROC,
        cbClsExtra: i32 = 0,
        cbWndExtra: i32 = 0,
        hInstance: ?*anyopaque = null,
        hIcon: ?*anyopaque = null,
        hCursor: ?*anyopaque = null,
        hbrBackground: ?*anyopaque = null,
        lpszMenuName: ?[*:0]const u16 = null,
        lpszClassName: [*:0]const u16,
        hIconSm: ?*anyopaque = null,
    };
    const MSG = extern struct { hwnd: ?HWND, message: u32, wParam: usize, lParam: isize, time: u32, pt: [2]i32, private: u32 = 0 };

    extern "user32" fn RegisterClassExW(wc: *const WNDCLASSEXW) callconv(.winapi) u16;
    extern "user32" fn CreateWindowExW(ex: u32, class: [*:0]const u16, title: ?[*:0]const u16, style: u32, x: i32, y: i32, w: i32, h: i32, parent: ?*anyopaque, menu: ?*anyopaque, inst: ?*anyopaque, param: ?*anyopaque) callconv(.winapi) ?HWND;
    extern "user32" fn DefWindowProcW(hwnd: HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize;
    extern "user32" fn PostMessageW(hwnd: HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) i32;
    extern "user32" fn GetMessageW(msg: *MSG, hwnd: ?HWND, min: u32, max: u32) callconv(.winapi) i32;
    extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) i32;
    extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) isize;
    extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;

    const WM_RUN = 0x8000 + 0x4D5A; // WM_APP + a number of ours
    const HWND_MESSAGE: *anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("MyZigPluginsMainThread");

    var hwnd: std.atomic.Value(?HWND) = .init(null);

    fn proc(h: HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize {
        if (msg != WM_RUN) return DefWindowProcW(h, msg, wp, lp);
        const func: Func = @ptrFromInt(wp);
        func(@ptrFromInt(@as(usize, @bitCast(lp))));
        return 0;
    }

    fn init() !void {
        if (hwnd.load(.acquire) != null) return;
        const inst = GetModuleHandleW(null);
        const wc: WNDCLASSEXW = .{ .lpfnWndProc = proc, .hInstance = inst, .lpszClassName = class_name };
        _ = RegisterClassExW(&wc); // fails harmlessly when registered already
        const h = CreateWindowExW(0, class_name, null, 0, 0, 0, 0, 0, HWND_MESSAGE, null, inst, null) orelse return error.CreateWindow;
        hwnd.store(h, .release);
    }

    fn post(ctx: ?*anyopaque, func: Func) bool {
        const h = hwnd.load(.acquire) orelse return false;
        return PostMessageW(h, WM_RUN, @intFromPtr(func), @bitCast(@intFromPtr(ctx))) != 0;
    }

    fn runOnce() void {
        var msg: MSG = undefined;
        if (GetMessageW(&msg, null, 0, 0) <= 0) return;
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
};

const TestState = struct {
    main: std.Thread.Id,
    seen: std.ArrayList(u32) = .empty,
    on_main: bool = true,
    done: std.atomic.Value(bool) = .init(false),
};
const TestItem = struct {
    state: *TestState,
    n: u32,

    fn run(ctx: ?*anyopaque) callconv(.c) void {
        const item: *TestItem = @ptrCast(@alignCast(ctx));
        const s = item.state;
        if (std.Thread.getCurrentId() != s.main) s.on_main = false;
        s.seen.append(std.testing.allocator, item.n) catch {};
        if (item.n == 9) s.done.store(true, .release);
    }

    fn worker(items: []TestItem) void {
        for (items) |*it| std.debug.assert(post(it, run));
    }
};

test "work posted from other threads runs on the main thread, in order" {
    try init();
    var s: TestState = .{ .main = std.Thread.getCurrentId() };
    defer s.seen.deinit(std.testing.allocator);
    var items: [10]TestItem = undefined;
    for (&items, 0..) |*it, i| it.* = .{ .state = &s, .n = @intCast(i) };
    const t = try std.Thread.spawn(.{}, TestItem.worker, .{&items});
    runUntil(&s.done);
    t.join();
    try std.testing.expect(s.on_main);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 }, s.seen.items);
}
