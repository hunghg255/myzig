//! A run on macOS, as mygo's tool does. The window shows without
//! activating the app (accessory, orderFrontRegardless), so it takes
//! neither the keyboard nor the front. Events come from the driver's
//! thread through the main queue, as the window server's do, at any time
//! within the display's refresh, and go through the window as AppKit's
//! (sendEvent:, scrollWheel:): an event arrives when it is posted.
//!
//! The frame showing an event is the next one the main thread presents
//! after handling it. The tool swizzles the presents (the command
//! buffer's presentDrawable:, the drawable's present) to attribute events
//! to frames, adds a presented handler to each drawable for when it
//! reached the screen (presentedTime), and swizzles
//! -[CAMetalLayer nextDrawable] for the main thread's waits (myzig fetches
//! drawables off the main thread: `src/ui/metal_present.zig`).
const std = @import("std");
const myzig = @import("myzig");
const objc = myzig.objc;
const plan = @import("plan.zig");
const record = @import("record.zig");
const view_mod = @import("view.zig");
const Options = @import("options.zig").Options;
const Figures = @import("figures.zig").Figures;

extern "c" fn CACurrentMediaTime() f64;
extern "c" fn pthread_main_np() c_int;
extern "c" fn class_getInstanceMethod(cls: objc.Class, sel: objc.SEL) ?*anyopaque;
extern "c" fn method_setImplementation(m: *anyopaque, imp: *const anyopaque) ?*const anyopaque;
extern "c" fn object_getClass(obj: objc.Object) objc.Class;
extern "c" fn class_getName(cls: objc.Class) [*:0]const u8;
extern "c" fn MTLCreateSystemDefaultDevice() ?objc.Object;
extern "c" fn CGEventCreateScrollWheelEvent2(source: ?*anyopaque, units: u32, count: u32, dy: i32, dx: i32, dz: i32) ?*anyopaque;
extern "c" fn CGEventSetIntegerValueField(event: *anyopaque, field: u32, v: i64) void;
extern "c" fn CGEventSetLocation(event: *anyopaque, p: objc.CGPoint) void;
extern "c" fn CFRelease(obj: *anyopaque) void;
extern "c" var _dispatch_main_q: opaque {};
extern "c" fn dispatch_async_f(queue: *anyopaque, ctx: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;

fn mainQueue() *anyopaque {
    return @ptrCast(&_dispatch_main_q);
}

const Run = struct {
    rec: record.Recorder,
    state: view_mod.State,
    app: *myzig.App = undefined,
    nswindow: objc.Object = undefined,
    view: objc.Object = undefined,
};

var run: *Run = undefined;

const NextImp = *const fn (objc.Object, objc.SEL) callconv(.c) ?objc.Object;
const PresentInImp = *const fn (objc.Object, objc.SEL, objc.Object) callconv(.c) void;
const PresentImp = *const fn (objc.Object, objc.SEL) callconv(.c) void;
var orig_next: NextImp = undefined;
var orig_present_in: PresentInImp = undefined;
var orig_present: PresentImp = undefined;

fn nextDrawable(self: objc.Object, cmd: objc.SEL) callconv(.c) ?objc.Object {
    const asked = CACurrentMediaTime();
    const d = orig_next(self, cmd);
    if (pthread_main_np() != 0) run.rec.mainWait(CACurrentMediaTime() - asked);
    return d;
}

fn presentIn(self: objc.Object, cmd: objc.SEL, d: objc.Object) callconv(.c) void {
    present(d);
    orig_present_in(self, cmd, d);
}

fn presentSelf(self: objc.Object, cmd: objc.SEL) callconv(.c) void {
    present(self);
    orig_present(self, cmd);
}

/// The frame presenting drawable `d`, once: a command buffer's
/// presentDrawable: may present it with present.
fn present(d: objc.Object) void {
    const id = objc.msg(objc.NSUInteger, d, "drawableID", .{});
    if (!run.rec.present(id, CACurrentMediaTime())) return;
    // Metal copies the block.
    var block = objc.Block(Run, &.{objc.Object}).init(run, presented);
    objc.msg(void, d, "addPresentedHandler:", .{@as(*anyopaque, @ptrCast(&block))});
}

fn presented(r: *Run, d: objc.Object) void {
    // 0: another frame replaced it before the screen showed it.
    r.rec.shown(objc.msg(objc.NSUInteger, d, "drawableID", .{}), objc.msg(f64, d, "presentedTime", .{}));
}

fn swizzle(cls: objc.Class, name: [:0]const u8, imp: *const anyopaque) !*const anyopaque {
    const m = class_getInstanceMethod(cls, objc.sel(name)) orelse return error.MethodGone;
    return method_setImplementation(m, imp) orelse error.MethodGone;
}

fn swizzleAll() !void {
    orig_next = @ptrCast(@alignCast(try swizzle(objc.class("CAMetalLayer"), "nextDrawable", @ptrCast(&nextDrawable))));
    // The command buffer's class is private: one of a queue's shows it.
    const device = MTLCreateSystemDefaultDevice() orelse return error.NoMetal;
    const queue = objc.msg(objc.Object, device, "newCommandQueue", .{});
    const buffer = objc.msg(objc.Object, queue, "commandBuffer", .{});
    orig_present_in = @ptrCast(@alignCast(try swizzle(object_getClass(buffer), "presentDrawable:", @ptrCast(&presentIn))));
    orig_present = @ptrCast(@alignCast(try swizzle(objc.class("CAMetalDrawable"), "present", @ptrCast(&presentSelf))));
}

pub fn measure(init: std.process.Init, o: Options) !Figures {
    const gpa = init.gpa;
    const r = try gpa.create(Run);
    defer gpa.destroy(r);
    r.* = .{ .rec = .init(gpa, init.io), .state = .init(gpa, o.mode) };
    defer r.rec.deinit();
    defer r.state.deinit();
    run = r;
    r.state.boxes = o.boxes;
    // `--myzig-hidden`: the app starts without activating.
    const app = try myzig.App.create(init, .{ .name = "inputlatency", .quit_on_signal = true });
    defer app.destroy();
    r.app = app;
    const win = try app.newWindow(.{
        .title = "inputlatency",
        .width = 800,
        .height = 600,
        .x = o.x,
        .y = o.y,
        .visible = false,
        .content = .{ .view = .init(&r.state, view_mod.State.view) },
    });
    r.nswindow = win.nswindow;
    r.view = objc.msg(objc.Object, win.nswindow, "contentView", .{});
    if (!std.mem.eql(u8, std.mem.span(class_getName(object_getClass(r.view))), "MyZigView")) return error.NoSurfaceView;
    // Out of the user's way: an accessory app, its window ordered in
    // front without becoming key.
    const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    _ = objc.msg(objc.BOOL, nsapp, "setActivationPolicy:", .{@as(objc.NSInteger, 1)});
    // As the app the user types into, which is active: App Nap would
    // delay an inactive app's wakeups by milliseconds.
    const user_initiated: u64 = 0x00EFFFFF;
    const latency_critical: u64 = 0xFF00000000;
    const info = objc.msg(objc.Object, objc.class("NSProcessInfo"), "processInfo", .{});
    _ = objc.retain(objc.msg(objc.Object, info, "beginActivityWithOptions:reason:", .{ user_initiated | latency_critical, objc.nsString("measuring input latency") }));
    objc.msg(void, win.nswindow, "orderFrontRegardless", .{});
    const screen = objc.msg(objc.Object, win.nswindow, "screen", .{});
    const refresh: f64 = @floatFromInt(objc.msg(objc.NSInteger, screen, "maximumFramesPerSecond", .{}));
    try swizzleAll();

    const driver = try std.Thread.spawn(.{}, drive, .{ init.io, o, refresh });
    try app.run();
    driver.join();
    return r.rec.figures(refresh, o.mode.input());
}

const Job = struct { action: plan.Action, timed: bool, arrived: f64 };

/// From the driver's thread: has the main thread handle `action` as an
/// event arriving now.
fn inject(action: plan.Action, timed: bool) void {
    const job = std.heap.c_allocator.create(Job) catch return;
    job.* = .{ .action = action, .timed = timed, .arrived = CACurrentMediaTime() };
    dispatch_async_f(mainQueue(), job, handleJob);
}

fn handleJob(ctx: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(ctx));
    defer std.heap.c_allocator.destroy(job);
    var e: record.Event = .{ .arrived = job.arrived, .handling = CACurrentMediaTime() };
    perform(job.action);
    e.handled = CACurrentMediaTime();
    if (job.timed) run.rec.handled(e);
}

/// The pointer's place while dragging, in view points.
var pointer: objc.CGPoint = .{};

fn perform(action: plan.Action) void {
    switch (action) {
        .key => sendKey(),
        .scroll_begin => sendScroll(1, -2),
        .scroll => |dy| sendScroll(2, @intFromFloat(dy)),
        .scroll_end => sendScroll(4, 0),
        .down => {
            const b = run.state.boxPoint();
            pointer = .{ .x = b.x, .y = b.y };
            sendMouse(1, pointer); // NSEventTypeLeftMouseDown
        },
        .drag => |dx| {
            pointer.x += dx;
            sendMouse(6, pointer); // NSEventTypeLeftMouseDragged
        },
        .up => sendMouse(2, pointer), // NSEventTypeLeftMouseUp
    }
}

fn windowPoint(p: objc.CGPoint) objc.CGPoint {
    return objc.msg(objc.CGPoint, run.view, "convertPoint:toView:", .{ p, @as(?objc.Object, null) });
}

fn sendKey() void {
    const number = objc.msg(objc.NSInteger, run.nswindow, "windowNumber", .{});
    const s = objc.nsString("a");
    for ([_]objc.NSUInteger{ 10, 11 }) |t| { // NSEventTypeKeyDown, KeyUp
        const ev = objc.msg(objc.Object, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
            t, objc.CGPoint{}, @as(objc.NSUInteger, 0), CACurrentMediaTime(), number, @as(?objc.Object, null), s, s, objc.NO, @as(u16, 0),
        });
        objc.msg(void, run.nswindow, "sendEvent:", .{ev});
    }
}

fn sendMouse(t: objc.NSUInteger, p: objc.CGPoint) void {
    const number = objc.msg(objc.NSInteger, run.nswindow, "windowNumber", .{});
    const ev = objc.msg(objc.Object, objc.class("NSEvent"), "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{
        t, windowPoint(p), @as(objc.NSUInteger, 0), CACurrentMediaTime(), number, @as(?objc.Object, null), @as(objc.NSInteger, 0), @as(objc.NSInteger, 1), @as(f32, 1),
    });
    objc.msg(void, run.nswindow, "sendEvent:", .{ev});
}

/// Scrolls as a trackpad does, by `dy` points, in a phase of the gesture
/// (kCGScrollPhase: 1 began, 2 changed, 4 ended).
fn sendScroll(phase: i64, dy: i32) void {
    const ev = CGEventCreateScrollWheelEvent2(null, 0, 1, dy, 0, 0) orelse return; // in pixels
    defer CFRelease(ev);
    CGEventSetIntegerValueField(ev, 88, 1); // kCGScrollWheelEventIsContinuous
    CGEventSetIntegerValueField(ev, 99, phase); // kCGScrollWheelEventScrollPhase
    CGEventSetIntegerValueField(ev, 96, dy); // kCGScrollWheelEventPointDeltaAxis1
    // A window-less event's location is on the screen, flipped by Core
    // Graphics: its locationInWindow is then this point.
    const p = windowPoint(.{ .x = 300, .y = 300 });
    const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    const first = objc.msg(objc.Object, screens, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
    const frame = objc.msg(objc.CGRect, first, "frame", .{});
    CGEventSetLocation(ev, .{ .x = p.x, .y = frame.size.height - p.y });
    const ns = objc.msg(objc.Object, objc.class("NSEvent"), "eventWithCGEvent:", .{ev});
    objc.msg(void, run.view, "scrollWheel:", .{ns});
}

fn quitApp(_: ?*anyopaque) callconv(.c) void {
    run.app.quit();
}

fn sleepMs(io: std.Io, ms: f64) void {
    io.sleep(.fromMicroseconds(@intFromFloat(ms * 1000)), .awake) catch {};
}

/// The driver's thread: the run's plan, then the app quits.
fn drive(io: std.Io, o: Options, refresh: f64) void {
    defer dispatch_async_f(mainQueue(), null, quitApp);
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
        while (p.next()) |s| {
            if (s.measured and !measuring) {
                run.rec.setMeasuring(true);
                measuring = true;
            }
            inject(s.action, s.timed);
            sleepMs(io, s.wait_ms);
        }
    }
    // The last frames reach the screen.
    sleepMs(io, 300);
    run.rec.setMeasuring(false);
}
