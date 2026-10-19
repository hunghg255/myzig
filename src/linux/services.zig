//! The desktop's services over the session bus on Linux: notifications
//! (org.freedesktop.Notifications), the appearance the desktop portal
//! reports (org.freedesktop.appearance color-scheme) and its changes, and
//! the screen saver's inhibitions (keeping the display awake).
const std = @import("std");
const dbus = @import("dbus.zig");
const Bus = @import("dbus_conn.zig").Bus;

const notifications: Bus.Target = .{ .destination = "org.freedesktop.Notifications", .path = "/org/freedesktop/Notifications", .interface = "org.freedesktop.Notifications", .member = "" };

fn with(t: Bus.Target, member: []const u8) Bus.Target {
    var o = t;
    o.member = member;
    return o;
}

/// Shows a notification; returns the server's id for it. Clicks arrive
/// as ActionInvoked signals with the "default" action.
pub fn notify(bus: *Bus, app_name: []const u8, title: []const u8, body: []const u8, silent: bool, replaces: u32) !u32 {
    var e: dbus.Encoder = .{ .gpa = bus.gpa };
    defer e.deinit();
    try e.string(app_name);
    try e.u32_(replaces);
    try e.string("");
    try e.string(title);
    try e.string(body);
    const actions = try e.beginArray(4);
    try e.string("default");
    try e.string("Open");
    e.endArray(actions);
    const hints = try e.beginArray(8);
    if (silent) {
        try e.structStart();
        try e.string("suppress-sound");
        try e.signature("b");
        try e.boolean(true);
    }
    e.endArray(hints);
    try e.i32_(-1);
    var reply = try bus.call(with(notifications, "Notify"), "susssasa{sv}i", e.buf.items);
    defer reply.deinit(bus.gpa);
    var m = try reply.message();
    return m.body.u32_();
}

pub fn closeNotification(bus: *Bus, id: u32) void {
    var e: dbus.Encoder = .{ .gpa = bus.gpa };
    defer e.deinit();
    e.u32_(id) catch return;
    _ = bus.send(with(notifications, "CloseNotification"), "u", e.buf.items, true) catch {};
}

/// Asks for the signals of notifications and of the portal's settings.
pub fn watchSignals(bus: *Bus) void {
    bus.addMatch("type='signal',interface='org.freedesktop.Notifications'") catch {};
    bus.addMatch("type='signal',interface='org.freedesktop.portal.Settings',member='SettingChanged'") catch {};
}

/// What a signal says, for the app.
pub const Event = union(enum) {
    /// A notification's action ("default": the notification) was chosen.
    action: struct { id: u32, key: []const u8 },
    closed: u32,
    /// The desktop switched to dark (true) or light.
    appearance: bool,
    other,
};

pub fn event(m: *dbus.Message) Event {
    const h = m.header;
    if (std.mem.eql(u8, h.interface, "org.freedesktop.Notifications")) {
        if (std.mem.eql(u8, h.member, "ActionInvoked")) {
            const id = m.body.u32_() catch return .other;
            const key = m.body.string() catch return .other;
            return .{ .action = .{ .id = id, .key = key } };
        }
        if (std.mem.eql(u8, h.member, "NotificationClosed")) return .{ .closed = m.body.u32_() catch return .other };
    }
    if (std.mem.eql(u8, h.member, "SettingChanged")) {
        const ns = m.body.string() catch return .other;
        const key = m.body.string() catch return .other;
        if (!std.mem.eql(u8, ns, "org.freedesktop.appearance") or !std.mem.eql(u8, key, "color-scheme")) return .other;
        const v = variantU32(&m.body) orelse return .other;
        return .{ .appearance = v == 1 };
    }
    return .other;
}

/// A variant holding a u32 (or a variant holding one, as Settings.Read answers).
fn variantU32(d: *dbus.Decoder) ?u32 {
    var depth: usize = 0;
    while (depth < 3) : (depth += 1) {
        const sig = d.signature() catch return null;
        if (std.mem.eql(u8, sig, "u")) return d.u32_() catch null;
        if (!std.mem.eql(u8, sig, "v")) return null;
    }
    return null;
}

const portal: Bus.Target = .{ .destination = "org.freedesktop.portal.Desktop", .path = "/org/freedesktop/portal/desktop", .interface = "org.freedesktop.portal.Settings", .member = "Read" };

/// Whether the desktop prefers dark colors (the portal's color-scheme is
/// 1); null when no portal answers.
pub fn prefersDark(bus: *Bus) ?bool {
    var e: dbus.Encoder = .{ .gpa = bus.gpa };
    defer e.deinit();
    e.string("org.freedesktop.appearance") catch return null;
    e.string("color-scheme") catch return null;
    var reply = bus.call(portal, "ss", e.buf.items) catch return null;
    defer reply.deinit(bus.gpa);
    var m = reply.message() catch return null;
    // The reply is "v": the variant's signature comes first.
    const v = variantU32(&m.body) orelse return null;
    return v == 1;
}

const screensaver: Bus.Target = .{ .destination = "org.freedesktop.ScreenSaver", .path = "/org/freedesktop/ScreenSaver", .interface = "org.freedesktop.ScreenSaver", .member = "" };

/// Keeps the screen on until `uninhibit` (or the connection closes).
pub fn inhibit(bus: *Bus, app_name: []const u8, reason: []const u8) !u32 {
    var e: dbus.Encoder = .{ .gpa = bus.gpa };
    defer e.deinit();
    try e.string(app_name);
    try e.string(reason);
    var reply = try bus.call(with(screensaver, "Inhibit"), "ss", e.buf.items);
    defer reply.deinit(bus.gpa);
    var m = try reply.message();
    return m.body.u32_();
}

pub fn uninhibit(bus: *Bus, cookie: u32) void {
    var e: dbus.Encoder = .{ .gpa = bus.gpa };
    defer e.deinit();
    e.u32_(cookie) catch return;
    _ = bus.send(with(screensaver, "UnInhibit"), "u", e.buf.items, true) catch {};
}

test "signals: a notification's action and the portal's appearance" {
    const gpa = std.testing.allocator;
    var b: dbus.Encoder = .{ .gpa = gpa };
    defer b.deinit();
    try b.u32_(42);
    try b.string("default");
    const msg = try dbus.message(gpa, .{ .type = .signal, .serial = 3, .path = "/org/freedesktop/Notifications", .interface = "org.freedesktop.Notifications", .member = "ActionInvoked", .signature = "us" }, b.buf.items);
    defer gpa.free(msg);
    var m = try dbus.parse(msg);
    const ev = event(&m);
    try std.testing.expectEqual(@as(u32, 42), ev.action.id);
    try std.testing.expectEqualStrings("default", ev.action.key);

    var s: dbus.Encoder = .{ .gpa = gpa };
    defer s.deinit();
    try s.string("org.freedesktop.appearance");
    try s.string("color-scheme");
    try s.signature("u");
    try s.u32_(1);
    const msg2 = try dbus.message(gpa, .{ .type = .signal, .serial = 4, .path = "/org/freedesktop/portal/desktop", .interface = "org.freedesktop.portal.Settings", .member = "SettingChanged", .signature = "ssv" }, s.buf.items);
    defer gpa.free(msg2);
    var m2 = try dbus.parse(msg2);
    try std.testing.expect(event(&m2).appearance);
}
