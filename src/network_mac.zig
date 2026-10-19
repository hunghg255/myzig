//! Whether the computer is online on macOS: Network.framework's path
//! monitor (loaded with dlopen), whose updates come on the main queue.
//! The first status takes the system a few milliseconds: `status` waits
//! for it.
const std = @import("std");
const objc = @import("objc.zig");
const Status = @import("network.zig").Status;

const Api = struct {
    nw_path_monitor_create: *const fn () callconv(.c) ?*anyopaque,
    nw_path_monitor_set_queue: *const fn (m: *anyopaque, q: objc.dispatch_queue_t) callconv(.c) void,
    nw_path_monitor_set_update_handler: *const fn (m: *anyopaque, block: *const anyopaque) callconv(.c) void,
    nw_path_monitor_start: *const fn (m: *anyopaque) callconv(.c) void,
    nw_path_get_status: *const fn (p: *anyopaque) callconv(.c) c_int,
    nw_path_is_expensive: *const fn (p: *anyopaque) callconv(.c) bool,
    nw_path_is_constrained: *const fn (p: *anyopaque) callconv(.c) bool,
};
var api: Api = undefined;

const Monitor = struct {
    last: ?Status = null,
    listener: ?struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque) void } = null,
};
var monitor: Monitor = .{};
var started: enum { no, yes, failed } = .no;

fn update(m: *Monitor, path: ?*anyopaque) void {
    const p = path orelse return;
    m.last = .{ .online = api.nw_path_get_status(p) == 1, .metered = api.nw_path_is_expensive(p) or api.nw_path_is_constrained(p) };
    if (m.listener) |l| l.func(l.ctx);
}

fn start() bool {
    if (started != .no) return started == .yes;
    started = .failed;
    const lib = std.c.dlopen("/System/Library/Frameworks/Network.framework/Network", .{ .NOW = true }) orelse return false;
    inline for (@typeInfo(Api).@"struct".field_names) |name| @field(api, name) = @ptrCast(@alignCast(std.c.dlsym(lib, name) orelse return false));
    const m = api.nw_path_monitor_create() orelse return false;
    api.nw_path_monitor_set_queue(m, objc.mainQueue());
    // The monitor copies the block, and lives as long as the app.
    var block = objc.Block(Monitor, &.{?*anyopaque}).init(&monitor, update);
    api.nw_path_monitor_set_update_handler(m, @ptrCast(&block));
    api.nw_path_monitor_start(m);
    started = .yes;
    return true;
}

extern "c" fn CFRunLoopRunInMode(mode: *const anyopaque, seconds: f64, return_after: bool) i32;
extern "c" const kCFRunLoopDefaultMode: *const anyopaque;

/// The computer's network status; online when the system cannot say.
pub fn status() Status {
    if (!start()) return .{};
    // The first update, which comes within milliseconds (a second at most).
    var tries: usize = 0;
    while (monitor.last == null and tries < 100) : (tries += 1) _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
    return monitor.last orelse .{};
}

/// Calls `func(ctx)` on the main thread as the network's path changes.
pub fn watch(ctx: *anyopaque, func: *const fn (ctx: *anyopaque) void) void {
    if (!start()) return;
    monitor.listener = .{ .ctx = ctx, .func = func };
}

pub fn unwatch() void {
    monitor.listener = null;
}

/// The status the monitor last told, without waiting (in its updates).
pub fn last() Status {
    return monitor.last orelse .{};
}
