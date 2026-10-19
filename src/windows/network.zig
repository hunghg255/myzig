//! Whether the computer is online on Windows: the Network List Manager's
//! connectivity and cost (COM), and its changes, which IP Helper tells
//! from a thread of its own: they reach the app's hidden window as
//! `WM_NETWORK`, and the main thread asks the manager again.
const std = @import("std");
const w = @import("win32.zig");
const com = @import("com.zig");
const Status = @import("../network.zig").Status;

pub const WM_NETWORK = w.WM_APP + 30;

extern "ole32" fn CoCreateInstance(clsid: *const com.GUID, outer: ?*anyopaque, ctx: u32, iid: *const com.GUID, out: *?com.Object) callconv(.winapi) com.HRESULT;
const ChangeFn = *const fn (ctx: ?*anyopaque, row: ?*anyopaque, kind: u32) callconv(.winapi) void;
extern "iphlpapi" fn NotifyIpInterfaceChange(family: u16, cb: ChangeFn, ctx: ?*anyopaque, initial: u8, handle: *?*anyopaque) callconv(.winapi) u32;
extern "iphlpapi" fn NotifyRouteChange2(family: u16, cb: ChangeFn, ctx: ?*anyopaque, initial: u8, handle: *?*anyopaque) callconv(.winapi) u32;
extern "iphlpapi" fn CancelMibChangeNotify2(handle: *anyopaque) callconv(.winapi) u32;

const clsid_manager = com.GUID.parse("DCB00C01-570F-4A9B-8D69-199FDBA5723B");
const iid_manager = com.GUID.parse("DCB00000-570F-4A9B-8D69-199FDBA5723B");
const iid_cost = com.GUID.parse("DCB00008-570F-4A9B-8D69-199FDBA5723B");
/// INetworkListManager::GetConnectivity, after IUnknown's and IDispatch's.
const get_connectivity = 13;
/// INetworkCostManager::GetCost.
const get_cost = 3;

/// NLM_CONNECTIVITY: a local network's or the internet's, over IPv4 or IPv6.
const reach: u32 = 0x20 | 0x40 | 0x200 | 0x400;
/// NLM_CONNECTION_COST: fixed, variable, over or near its limit, roaming.
const metered_cost: u32 = 0x2 | 0x4 | 0x10000 | 0x40000 | 0x80000;

pub fn fromFlags(connectivity: u32, cost: u32) Status {
    return .{ .online = connectivity & reach != 0, .metered = cost & metered_cost != 0 };
}

var manager: ?com.Object = null;

fn listManager() ?com.Object {
    if (manager) |m| return m;
    var out: ?com.Object = null;
    if (com.failed(CoCreateInstance(&clsid_manager, null, 1 | 4, &iid_manager, &out))) return null; // in process or local server
    manager = out;
    return out;
}

/// The computer's network status now; online when the system cannot say.
pub fn status() Status {
    const m = listManager() orelse return .{};
    var connectivity: u32 = 0;
    if (com.failed(com.call(m, get_connectivity, .{&connectivity}))) return .{};
    var cost: u32 = 0;
    if (com.query(m, &iid_cost)) |c| {
        defer com.release(c);
        _ = com.call(c, get_cost, .{ &cost, @as(?*anyopaque, null) });
    }
    return fromFlags(connectivity, cost);
}

/// Changes of interfaces and routes, posted to `hwnd`.
pub const Watch = struct {
    interfaces: ?*anyopaque = null,
    routes: ?*anyopaque = null,

    pub fn start(hwnd: w.HWND) Watch {
        var wt: Watch = .{};
        const ctx: *anyopaque = @ptrCast(hwnd);
        _ = NotifyIpInterfaceChange(0, changed, ctx, 0, &wt.interfaces); // AF_UNSPEC
        _ = NotifyRouteChange2(0, changed, ctx, 0, &wt.routes);
        return wt;
    }

    pub fn stop(wt: *Watch) void {
        if (wt.interfaces) |h| _ = CancelMibChangeNotify2(h);
        if (wt.routes) |h| _ = CancelMibChangeNotify2(h);
        wt.* = .{};
    }
};

/// On IP Helper's thread: tell the main thread.
fn changed(ctx: ?*anyopaque, _: ?*anyopaque, _: u32) callconv(.winapi) void {
    const hwnd: w.HWND = @ptrCast(ctx orelse return);
    _ = w.PostMessageW(hwnd, WM_NETWORK, 0, 0);
}

test "the network's status from the manager's flags" {
    try std.testing.expect(fromFlags(0x40, 1).online);
    try std.testing.expect(!fromFlags(0x40, 1).metered);
    try std.testing.expect(fromFlags(0x400, 0x4).metered);
    try std.testing.expect(!fromFlags(0x1 | 0x2, 0).online);
}

test "the network's status, asked of the system" {
    _ = com.CoInitializeEx(null, 0x2);
    // Whatever the machine has: the call answers, through COM or not.
    _ = status();
    _ = status();
}
