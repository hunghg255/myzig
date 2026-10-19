//! The app's entry in Linux docks that follow the Unity launcher API (KDE
//! Plasma's task manager, Ubuntu's dock, Plank): a progress bar and a
//! count over its icon, set by a signal on the session bus.
const std = @import("std");
const dbus = @import("dbus.zig");
const Bus = @import("dbus_conn.zig").Bus;
const Progress = @import("../window_types.zig").Progress;

/// What the entry shows.
pub const Props = struct {
    progress: ?f64 = null,
    count: ?i64 = null,
    urgent: ?bool = null,
};

/// The body of LauncherEntry.Update ("sa{sv}") for the app `id`'s entry.
pub fn body(gpa: std.mem.Allocator, id: []const u8, p: Props) ![]u8 {
    var e: dbus.Encoder = .{ .gpa = gpa };
    errdefer e.deinit();
    var uri: [256]u8 = undefined;
    try e.string(try std.fmt.bufPrint(&uri, "application://{s}.desktop", .{id}));
    const a = try e.beginArray(8);
    if (p.progress) |v| {
        try entry(&e, "progress", "d");
        try e.alignTo(8);
        try e.buf.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(u64, @bitCast(v))));
    }
    try entry(&e, "progress-visible", "b");
    try e.boolean(p.progress != null);
    if (p.count) |v| {
        try entry(&e, "count", "x");
        try e.alignTo(8);
        try e.buf.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(i64, v)));
    }
    if (p.count != null or p.progress == null) {
        try entry(&e, "count-visible", "b");
        try e.boolean(p.count != null);
    }
    if (p.urgent) |u| {
        try entry(&e, "urgent", "b");
        try e.boolean(u);
    }
    e.endArray(a);
    return e.buf.toOwnedSlice(gpa);
}

fn entry(e: *dbus.Encoder, key: []const u8, sig: []const u8) !void {
    try e.structStart();
    try e.string(key);
    try e.signature(sig);
}

/// Sends the entry's update as a signal of the app's object.
pub fn send(bus: *Bus, id: []const u8, p: Props) !void {
    const gpa = bus.gpa;
    const b = try body(gpa, id, p);
    defer gpa.free(b);
    bus.serial += 1;
    const msg = try dbus.message(gpa, .{ .type = .signal, .serial = bus.serial, .path = "/com/canonical/unity/launcherentry/myzig", .interface = "com.canonical.Unity.LauncherEntry", .member = "Update", .signature = "sa{sv}" }, b);
    defer gpa.free(msg);
    var sent: usize = 0;
    while (sent < msg.len) {
        const n = std.c.write(bus.fd, msg[sent..].ptr, msg.len - sent);
        if (n <= 0) return error.Write;
        sent += @intCast(n);
    }
}

/// Shows `p` on the app's entry; false without a session bus.
pub fn setProgress(app: anytype, p: Progress) bool {
    const bus = app.sessionBus() orelse return false;
    const v: ?f64 = switch (p.state) {
        .none => null,
        .indeterminate => 0,
        else => std.math.clamp(p.value, 0, 1),
    };
    send(bus, app.options.appId(), .{ .progress = v }) catch return false;
    return true;
}

/// A count on the app's entry (its badge's digits; text that is not a
/// number shows nothing), or none when empty.
pub fn setBadge(app: anytype, text: []const u8) bool {
    const bus = app.sessionBus() orelse return false;
    const n: ?i64 = if (text.len == 0) null else std.fmt.parseInt(i64, text, 10) catch null;
    send(bus, app.options.appId(), .{ .count = n }) catch return false;
    return true;
}

test "a launcher entry's update in D-Bus's encoding" {
    const gpa = std.testing.allocator;
    const b = try body(gpa, "notes", .{ .progress = 0.5 });
    defer gpa.free(b);
    var d: dbus.Decoder = .{ .bytes = b };
    try std.testing.expectEqualStrings("application://notes.desktop", try d.string());
    // The array's length, then its first entry: the key and the variant's signature.
    _ = try d.u32_();
    try d.alignTo(8);
    try std.testing.expectEqualStrings("progress", try d.string());
    try std.testing.expect(std.mem.indexOf(u8, b, "progress-visible") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "count") == null);
}
