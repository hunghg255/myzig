//! The app's notifications on Windows: toasts (`toast.zig`) for the
//! app's AppUserModelID, with the Start menu shortcut an unpackaged app
//! needs for them made on the first notification; their activations
//! passed from the system's thread to the main one through the hidden
//! window, then to `on_notification`. An unpackaged app also registers
//! its toast activator (`toast_activator.zig`), so a click after it quit
//! starts it again and still reaches `on_notification`; while it runs,
//! the activator and the toast's own event may both report a click: the
//! second is dropped. Where toasts cannot show (before
//! Windows 10, a shortcut Windows has not taken in yet, toasts turned off
//! for the app), `App.notify` shows the tray icon's balloon instead.
const std = @import("std");
const w = @import("win32.zig");
const toast = @import("toast.zig");
const aumid = @import("aumid.zig");
const activator = @import("toast_activator.zig");
const notify_types = @import("../notify_types.zig");

pub const WM_TOAST = w.WM_APP + 40;

pub const State = struct {
    toaster: ?*toast.Toaster = null,
    tried: bool = false,
    /// The activator's class, handed to COM.
    server: ?activator.Registration = null,
    /// The last activation delivered (`seen`), to drop its twin.
    last: ?Seen = null,
};

const Seen = struct { via_com: bool, hash: u64 };

fn seen(a: *const toast.Activation) Seen {
    var h = std.hash.Wyhash.init(0);
    for ([_][]const u8{ a.id, a.action, a.reply }) |part| {
        h.update(part);
        h.update(&.{0});
    }
    return .{ .via_com = a.via_com, .hash = h.final() };
}

/// Hands COM the app's toast activator, once: at launch when COM started
/// the app for a click (`launched`) or the app registered it before, and
/// when it first shows a toast.
pub fn serve(app: anytype, launched: bool) void {
    const s = &app.extras.toasts;
    if (s.server != null) return;
    const id = app.options.appId();
    if (!launched and (app.options.on_notification == null or !activator.installed(app.gpa, id))) return;
    const hwnd = app.appWindow() orelse return;
    s.server = activator.register(id, .{ .ctx = hwnd, .func = post }) catch null;
}

/// The toaster, made on first use; null where toasts cannot show.
fn toaster(app: anytype) ?*toast.Toaster {
    const s = &app.extras.toasts;
    if (s.toaster) |t| return t;
    if (s.tried) return null;
    s.tried = true;
    const hwnd = app.appWindow() orelse return null;
    const id = app.options.appId();
    if (!aumid.packaged()) {
        const dir = (aumid.startMenuPrograms(app.gpa) catch null) orelse return null;
        defer app.gpa.free(dir);
        const clsid = activator.clsidOf(id);
        _ = aumid.ensureShortcut(app.gpa, dir, app.options.name, id, clsid) catch return null;
        activator.install(app.gpa, id) catch {};
        serve(app, true);
    }
    s.toaster = toast.Toaster.create(app.gpa, id, .{ .ctx = hwnd, .func = post }) catch return null;
    return s.toaster;
}

/// Runs on the system's thread: the activation goes to the main thread.
fn post(ctx: ?*anyopaque, a: *toast.Activation) void {
    const hwnd: w.HWND = @ptrCast(ctx orelse return a.deinit());
    if (w.PostMessageW(hwnd, WM_TOAST, 0, @bitCast(@intFromPtr(a))) == 0) a.deinit();
}

/// Shows `n` as a toast; false when it cannot (the caller shows a balloon).
pub fn show(app: anytype, n: anytype) bool {
    const t = toaster(app) orelse return false;
    // Turned off for the app, or a shortcut the shell has not indexed yet.
    if (!t.enabled()) return false;
    t.show(n) catch return false;
    return true;
}

pub fn remove(app: anytype, id: []const u8) void {
    if (app.extras.toasts.toaster) |t| t.remove(id);
}

/// The hidden window's WM_TOAST: an activation for `on_notification`.
pub fn activated(app: anytype, lp: w.LPARAM) void {
    const a: *toast.Activation = @ptrFromInt(@as(usize, @bitCast(lp)));
    defer a.deinit();
    const now = seen(a);
    const s = &app.extras.toasts;
    if (s.last) |l| if (l.hash == now.hash and l.via_com != now.via_com) {
        s.last = null;
        return;
    };
    s.last = now;
    if (app.options.on_notification) |h| h.call(notify_types.response(a.id, a.action, a.reply));
}

pub fn stop(app: anytype) void {
    if (app.extras.toasts.server) |r| r.revoke();
    if (app.extras.toasts.toaster) |t| t.destroy();
    app.extras.toasts = .{};
}

test "an activation posted from another thread reaches on_notification on the main one" {
    const app_types = @import("../app_types.zig");
    const appwnd = @import("appwnd.zig");
    const Got = struct {
        n: usize = 0,
        action: [16]u8 = undefined,
        len: usize = 0,
        fn on(g: *@This(), r: app_types.NotificationResponse) void {
            g.n += 1;
            @memcpy(g.action[0..r.action.len], r.action);
            g.len = r.action.len;
        }
    };
    var got: Got = .{};
    const Fake = struct {
        options: app_types.Options,
        extras: struct { toasts: State = .{} } = .{},
        hooks: appwnd.Hooks = undefined,
        fn other(ctx: *anyopaque, msg: u32, _: w.WPARAM, lp: w.LPARAM) ?w.LRESULT {
            if (msg != WM_TOAST) return null;
            activated(@as(*@This(), @ptrCast(@alignCast(ctx))), lp);
            return 0;
        }
    };
    var fake: Fake = .{ .options = .{ .on_notification = .of(&got, Got.on) } };
    fake.hooks = .{ .ctx = &fake, .other = Fake.other };
    const hwnd = try appwnd.create("myzig-test-toast-post", &fake.hooks);
    defer appwnd.destroy(hwnd);
    const ca = std.heap.c_allocator;
    const a = try ca.create(toast.Activation);
    a.* = .{ .id = try ca.dupe(u8, "x"), .action = try ca.dupe(u8, "open"), .reply = try ca.dupe(u8, "") };
    const thread = try std.Thread.spawn(.{}, post, .{ @as(?*anyopaque, @ptrCast(hwnd)), a });
    thread.join();
    var msg: w.MSG = undefined;
    while (w.PeekMessageW(&msg, hwnd, 0, 0, 1) != 0) _ = w.DispatchMessageW(&msg);
    try std.testing.expectEqual(@as(usize, 1), got.n);
    try std.testing.expectEqualStrings("open", got.action[0..got.len]);
    // The same click through the activator: dropped; the next one is not.
    for ([_]bool{ true, true }) |via_com| {
        const b = try ca.create(toast.Activation);
        b.* = .{ .id = try ca.dupe(u8, "x"), .action = try ca.dupe(u8, "open"), .reply = try ca.dupe(u8, ""), .via_com = via_com };
        post(@ptrCast(hwnd), b);
        while (w.PeekMessageW(&msg, hwnd, 0, 0, 1) != 0) _ = w.DispatchMessageW(&msg);
    }
    try std.testing.expectEqual(@as(usize, 2), got.n);
}

test {
    _ = activator;
}
