//! Whether the computer is online on Linux: GIO's network monitor (over
//! NetworkManager or netlink), whose "network-changed" signal comes on
//! the main loop.
const std = @import("std");
const gtk = @import("gtk.zig");
const Status = @import("../network.zig").Status;

const Api = struct {
    g_network_monitor_get_default: *const fn () callconv(.c) ?*anyopaque,
    g_network_monitor_get_network_available: *const fn (m: *anyopaque) callconv(.c) c_int,
    g_network_monitor_get_network_metered: *const fn (m: *anyopaque) callconv(.c) c_int,
};
var api: Api = undefined;
var state: enum { untried, ok, missing } = .untried;

fn monitor() ?*anyopaque {
    if (state == .untried) {
        state = .missing;
        const lib = std.c.dlopen("libgio-2.0.so.0", .{ .NOW = true }) orelse return null;
        inline for (@typeInfo(Api).@"struct".field_names) |name| @field(api, name) = @ptrCast(@alignCast(std.c.dlsym(lib, name) orelse return null));
        state = .ok;
    }
    if (state != .ok) return null;
    return api.g_network_monitor_get_default();
}

/// The computer's network status now; online when GIO cannot say.
pub fn status() Status {
    const m = monitor() orelse return .{};
    return .{ .online = api.g_network_monitor_get_network_available(m) != 0, .metered = api.g_network_monitor_get_network_metered(m) != 0 };
}

pub const Changed = *const fn (ctx: *anyopaque) void;
var listener: ?struct { ctx: *anyopaque, func: Changed } = null;

/// Calls `func(ctx)` on the main thread as the network changes.
pub fn watch(ctx: *anyopaque, func: Changed) void {
    const m = monitor() orelse return;
    if (listener == null and gtk.load()) gtk.connect(m, "network-changed", @ptrCast(&onChanged), null);
    listener = .{ .ctx = ctx, .func = func };
}

pub fn unwatch() void {
    listener = null;
}

fn onChanged(_: *anyopaque, _: c_int, _: ?*anyopaque) callconv(.c) void {
    const l = listener orelse return;
    l.func(l.ctx);
}

test "the network's status, asked of GIO" {
    // Whatever the machine has: the call answers, with GIO or without.
    _ = status();
}
