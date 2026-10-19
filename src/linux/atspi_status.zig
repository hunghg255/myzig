//! Whether assistive technology is on, watched: the session bus's
//! org.a11y.Status (IsEnabled, ScreenReaderEnabled, which Orca and the
//! desktop's settings turn on), read once and then followed through its
//! PropertiesChanged signals, so that an app started before Orca shows
//! itself to it once it starts (`atspi.wait`).
const std = @import("std");
const c = std.c;
const dbus = @import("dbus.zig");
const conn = @import("dbus_conn.zig");

const properties = "org.freedesktop.DBus.Properties";
pub const rule = "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path='/org/a11y/bus',arg0='org.a11y.Status'";

/// What a PropertiesChanged signal of org.a11y.Status says (null: not told).
pub const Change = struct { enabled: ?bool = null, reader: ?bool = null };

/// Reads a PropertiesChanged signal; null for other signals.
pub fn changeOf(m: *dbus.Message) ?Change {
    const h = m.header;
    if (!std.mem.eql(u8, h.member, "PropertiesChanged") or !std.mem.eql(u8, h.interface, properties)) return null;
    if (!std.mem.eql(u8, h.path, "/org/a11y/bus")) return null;
    var d = m.body;
    const iface = d.string() catch return null;
    if (!std.mem.eql(u8, iface, "org.a11y.Status")) return null;
    var ch: Change = .{};
    const len = d.u32_() catch return null;
    d.alignTo(8) catch return null;
    const end = d.pos + len;
    while (d.pos < end) {
        d.alignTo(8) catch return null;
        const name = d.string() catch return null;
        const sig = d.signature() catch return null;
        if (std.mem.eql(u8, sig, "b")) {
            const v = (d.u32_() catch return null) != 0;
            if (std.mem.eql(u8, name, "IsEnabled")) ch.enabled = v;
            if (std.mem.eql(u8, name, "ScreenReaderEnabled")) ch.reader = v;
        } else _ = d.skip(sig) catch return null;
    }
    return ch;
}

/// One of org.a11y.Status's properties, asked of the session bus.
pub fn get(bus: *conn.Bus, name: []const u8) !bool {
    var e: dbus.Encoder = .{ .gpa = bus.gpa };
    defer e.deinit();
    try e.string("org.a11y.Status");
    try e.string(name);
    var r = try bus.call(.{ .destination = "org.a11y.Bus", .path = "/org/a11y/bus", .interface = properties, .member = "Get" }, "ss", e.buf.items);
    defer r.deinit(bus.gpa);
    var m = try r.message();
    const sig = try m.body.signature();
    return std.mem.eql(u8, sig, "b") and try m.body.u32_() != 0;
}

/// Sets one of them (as the desktop's settings do; for tests).
pub fn set(bus: *conn.Bus, name: []const u8, on: bool) !void {
    var e: dbus.Encoder = .{ .gpa = bus.gpa };
    defer e.deinit();
    try e.string("org.a11y.Status");
    try e.string(name);
    try e.signature("b");
    try e.boolean(on);
    var r = try bus.call(.{ .destination = "org.a11y.Bus", .path = "/org/a11y/bus", .interface = properties, .member = "Set" }, "ssv", e.buf.items);
    r.deinit(bus.gpa);
}

pub const Watch = struct {
    gpa: std.mem.Allocator,
    bus: *conn.Bus,
    enabled: bool = false,
    reader: bool = false,

    /// Connects to the session bus, asks for the status's changes, and
    /// reads it.
    pub fn open(gpa: std.mem.Allocator) !*Watch {
        const bus = try conn.Bus.session(gpa);
        errdefer bus.close();
        const w = try gpa.create(Watch);
        w.* = .{ .gpa = gpa, .bus = bus };
        bus.on_signal = onSignal;
        bus.signal_ctx = w;
        try bus.addMatch(rule);
        w.enabled = get(bus, "IsEnabled") catch false;
        w.reader = get(bus, "ScreenReaderEnabled") catch false;
        return w;
    }

    pub fn close(w: *Watch) void {
        w.bus.close();
        w.gpa.destroy(w);
    }

    pub fn on(w: *const Watch) bool {
        return w.enabled or w.reader;
    }

    pub const Event = enum { none, turned_on, closed };

    /// The connection has bytes: what they changed.
    pub fn dispatch(w: *Watch) Event {
        var b: [1]u8 = undefined;
        // MSG_PEEK | MSG_DONTWAIT: nothing to read at its end.
        if (c.recv(w.bus.fd, &b, 1, 0x2 | 0x40) == 0) return .closed;
        const was = w.on();
        w.bus.dispatch();
        return if (!was and w.on()) .turned_on else .none;
    }

    fn onSignal(ctx: ?*anyopaque, m: *dbus.Message) void {
        const w: *Watch = @ptrCast(@alignCast(ctx));
        const ch = changeOf(m) orelse return;
        if (ch.enabled) |v| w.enabled = v;
        if (ch.reader) |v| w.reader = v;
    }
};

test "the status's changes, read from their signals" {
    var e: dbus.Encoder = .{ .gpa = std.testing.allocator };
    defer e.deinit();
    try e.string("org.a11y.Status");
    const arr = try e.beginArray(8);
    try e.structStart();
    try e.string("ScreenReaderEnabled");
    try e.signature("b");
    try e.boolean(true);
    try e.structStart();
    try e.string("Other");
    try e.signature("s");
    try e.string("x");
    e.endArray(arr);
    const inv = try e.beginArray(4);
    e.endArray(inv);
    const msg = try dbus.message(std.testing.allocator, .{ .type = .signal, .serial = 1, .path = "/org/a11y/bus", .interface = properties, .member = "PropertiesChanged", .signature = "sa{sv}as" }, e.buf.items);
    defer std.testing.allocator.free(msg);
    var m = try dbus.parse(msg);
    const ch = changeOf(&m) orelse return error.NotRead;
    try std.testing.expectEqual(@as(?bool, true), ch.reader);
    try std.testing.expectEqual(@as(?bool, null), ch.enabled);
}
