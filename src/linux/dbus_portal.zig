//! The desktop portal's messages for global shortcuts, built and read
//! (org.freedesktop.portal.GlobalShortcuts): CreateSession, BindShortcuts,
//! Session.Close, the version property, Registry.Register (the app's id,
//! for apps the desktop did not launch), and the signals that answer:
//! Request.Response (a request's code and results) and Activated (a
//! shortcut pressed). Requests answer later, on the object path made of
//! the connection's name and the request's token (`requestPath`).
const std = @import("std");
const dbus = @import("dbus.zig");

pub const name = "org.freedesktop.portal.Desktop";
pub const path = "/org/freedesktop/portal/desktop";
pub const shortcuts = "org.freedesktop.portal.GlobalShortcuts";
pub const request = "org.freedesktop.portal.Request";
pub const session = "org.freedesktop.portal.Session";
pub const registry = "org.freedesktop.host.portal.Registry";

/// The object a request answers on: .../request/<sender>/<token>, the
/// sender being the unique name without its colon, dots as underscores.
pub fn requestPath(buf: []u8, unique: []const u8, token: []const u8) ![]const u8 {
    return objectPath(buf, "request", unique, token);
}

/// The object of a session made with `session_handle_token` = `token`.
pub fn sessionPath(buf: []u8, unique: []const u8, token: []const u8) ![]const u8 {
    return objectPath(buf, "session", unique, token);
}

fn objectPath(buf: []u8, kind: []const u8, unique: []const u8, token: []const u8) ![]const u8 {
    const u = if (std.mem.startsWith(u8, unique, ":")) unique[1..] else unique;
    const out = try std.fmt.bufPrint(buf, "{s}/{s}/{s}/{s}", .{ path, kind, u, token });
    for (out[path.len + kind.len + 2 ..][0..u.len]) |*ch| if (ch.* == '.') {
        ch.* = '_';
    };
    return out;
}

/// A token of letters, digits and underscores only, after `prefix`.
pub fn safeToken(buf: []u8, prefix: []const u8, id: []const u8) []const u8 {
    const n = @min(buf.len, prefix.len + id.len);
    @memcpy(buf[0..prefix.len], prefix);
    for (buf[prefix.len..n], id[0 .. n - prefix.len]) |*o, ch| o.* = if (std.ascii.isAlphanumeric(ch)) ch else '_';
    return buf[0..n];
}

/// A global shortcut as the portal takes it: its id (which the desktop
/// remembers the user's keys by), a description and the preferred keys
/// in the XDG shortcuts format ("CTRL+ALT+space").
pub const Shortcut = struct { id: []const u8, description: []const u8, trigger: []const u8 };

/// One {sv} entry of a string.
pub fn entryString(e: *dbus.Encoder, key: []const u8, value: []const u8) !void {
    try e.structStart();
    try e.string(key);
    try e.signature("s");
    try e.string(value);
}

/// a(sa{sv}): the shortcuts with their description and preferred trigger.
pub fn encodeShortcuts(e: *dbus.Encoder, list: []const Shortcut) !void {
    const arr = try e.beginArray(8);
    for (list) |s| {
        try e.structStart();
        try e.string(s.id);
        const props = try e.beginArray(8);
        try entryString(e, "description", s.description);
        if (s.trigger.len > 0) try entryString(e, "preferred_trigger", s.trigger);
        e.endArray(props);
    }
    e.endArray(arr);
}

/// CreateSession's body (a{sv}): the request's and the session's tokens,
/// and the shortcuts (KDE Plasma 5 binds those given here).
pub fn createSession(gpa: std.mem.Allocator, handle_token: []const u8, session_token: []const u8, list: []const Shortcut) ![]u8 {
    var e: dbus.Encoder = .{ .gpa = gpa };
    errdefer e.deinit();
    const opts = try e.beginArray(8);
    try entryString(&e, "handle_token", handle_token);
    try entryString(&e, "session_handle_token", session_token);
    if (list.len > 0) {
        try e.structStart();
        try e.string("shortcuts");
        try e.signature("a(sa{sv})");
        try encodeShortcuts(&e, list);
    }
    e.endArray(opts);
    return e.buf.toOwnedSlice(gpa);
}
pub const create_session_signature = "a{sv}";

/// BindShortcuts' body (oa(sa{sv})sa{sv}): the session, the shortcuts,
/// the parent window ("" for none) and the request's token.
pub fn bindShortcuts(gpa: std.mem.Allocator, session_handle: []const u8, list: []const Shortcut, parent: []const u8, handle_token: []const u8) ![]u8 {
    var e: dbus.Encoder = .{ .gpa = gpa };
    errdefer e.deinit();
    try e.string(session_handle);
    try encodeShortcuts(&e, list);
    try e.string(parent);
    const opts = try e.beginArray(8);
    try entryString(&e, "handle_token", handle_token);
    e.endArray(opts);
    return e.buf.toOwnedSlice(gpa);
}
pub const bind_shortcuts_signature = "oa(sa{sv})sa{sv}";

/// Registry.Register's body (sa{sv}): the app's id, its desktop entry's name.
pub fn register(gpa: std.mem.Allocator, app_id: []const u8) ![]u8 {
    var e: dbus.Encoder = .{ .gpa = gpa };
    errdefer e.deinit();
    try e.string(app_id);
    const opts = try e.beginArray(8);
    e.endArray(opts);
    return e.buf.toOwnedSlice(gpa);
}
pub const register_signature = "sa{sv}";

/// Properties.Get's body (ss) for an interface's version.
pub fn versionQuery(gpa: std.mem.Allocator, iface: []const u8) ![]u8 {
    var e: dbus.Encoder = .{ .gpa = gpa };
    errdefer e.deinit();
    try e.string(iface);
    try e.string("version");
    return e.buf.toOwnedSlice(gpa);
}

/// The version a Properties.Get reply (v) holds; null when not a u.
pub fn parseVersion(m: *dbus.Message) ?u32 {
    const sig = m.body.signature() catch return null;
    if (!std.mem.eql(u8, sig, "u")) return null;
    return m.body.u32_() catch null;
}

/// The string (or object path) of `key` in the a{sv} at the decoder;
/// reads the whole dictionary.
pub fn lookupString(d: *dbus.Decoder, key: []const u8) !?[]const u8 {
    const len = try d.u32_();
    try d.alignTo(8);
    const end = d.pos + len;
    if (end > d.bytes.len) return error.Truncated;
    var found: ?[]const u8 = null;
    while (d.pos < end) {
        try d.alignTo(8);
        const k = try d.string();
        const sig = try d.signature();
        if (found == null and std.mem.eql(u8, k, key) and (std.mem.eql(u8, sig, "s") or std.mem.eql(u8, sig, "o"))) {
            found = try d.string();
        } else _ = try d.skip(sig);
    }
    d.pos = end;
    return found;
}

/// A request's answer: 0 succeeded, 1 the user cancelled, 2 it failed.
pub const Response = struct { code: u32, session_handle: ?[]const u8 };

/// A Request.Response signal (ua{sv}), or null for another message.
pub fn parseResponse(m: *dbus.Message) ?Response {
    const h = m.header;
    if (h.type != .signal or !std.mem.eql(u8, h.interface, request) or !std.mem.eql(u8, h.member, "Response")) return null;
    const code = m.body.u32_() catch return null;
    const handle = lookupString(&m.body, "session_handle") catch return .{ .code = code, .session_handle = null };
    return .{ .code = code, .session_handle = handle };
}

/// A shortcut pressed: its session, its id, and the XDG activation token
/// a window shown for it takes the focus with.
pub const Activated = struct { session_handle: []const u8, id: []const u8, timestamp: u64, activation_token: ?[]const u8 };

/// A GlobalShortcuts.Activated signal (osta{sv}), or null.
pub fn parseActivated(m: *dbus.Message) ?Activated {
    const h = m.header;
    if (h.type != .signal or !std.mem.eql(u8, h.interface, shortcuts) or !std.mem.eql(u8, h.member, "Activated")) return null;
    const s = m.body.string() catch return null;
    const id = m.body.string() catch return null;
    m.body.alignTo(8) catch return null;
    if (m.body.pos + 8 > m.body.bytes.len) return null;
    const ts = std.mem.readInt(u64, m.body.bytes[m.body.pos..][0..8], .little);
    m.body.pos += 8;
    const tok = lookupString(&m.body, "activation_token") catch null;
    return .{ .session_handle = s, .id = id, .timestamp = ts, .activation_token = tok };
}

/// The XDG shortcuts format of keys: modifiers then the keysym's name.
pub fn trigger(buf: []u8, ctrl: bool, alt: bool, shift: bool, keysym: []const u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    if (ctrl) try w.writeAll("CTRL+");
    if (alt) try w.writeAll("ALT+");
    if (shift) try w.writeAll("SHIFT+");
    try w.writeAll(keysym);
    return w.buffered();
}

test "request and session paths, tokens" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/org/freedesktop/portal/desktop/request/1_42/myzig3", try requestPath(&buf, ":1.42", "myzig3"));
    try std.testing.expectEqualStrings("/org/freedesktop/portal/desktop/session/1_42/s", try sessionPath(&buf, ":1.42", "s"));
    var t: [32]u8 = undefined;
    try std.testing.expectEqualStrings("myzig_com_example_notes", safeToken(&t, "myzig_", "com.example-notes"));
    var k: [32]u8 = undefined;
    try std.testing.expectEqualStrings("CTRL+ALT+space", try trigger(&k, true, true, false, "space"));
}

test "CreateSession and BindShortcuts, built and read back" {
    const gpa = std.testing.allocator;
    const list = [_]Shortcut{ .{ .id = "CTRL+ALT+space", .description = "Ctrl+Alt+Space", .trigger = "CTRL+ALT+space" }, .{ .id = "SHIFT+F1", .description = "Shift+F1", .trigger = "SHIFT+F1" } };
    const body = try createSession(gpa, "myzig1", "myzig_notes", &list);
    defer gpa.free(body);
    const msg = try dbus.message(gpa, .{ .type = .method_call, .serial = 2, .path = path, .interface = shortcuts, .member = "CreateSession", .destination = name, .signature = create_session_signature }, body);
    defer gpa.free(msg);
    const m = try dbus.parse(msg);
    var d = m.body;
    try std.testing.expectEqualStrings("myzig1", (try lookupString(&d, "handle_token")).?);
    try std.testing.expectEqual(msg.len, d.pos);
    d = m.body;
    try std.testing.expectEqualStrings("myzig_notes", (try lookupString(&d, "session_handle_token")).?);
    // The whole body is one a{sv}.
    d = m.body;
    try std.testing.expectEqualStrings("", try d.skip("a{sv}"));
    try std.testing.expectEqual(msg.len, d.pos);

    const bind = try bindShortcuts(gpa, "/org/freedesktop/portal/desktop/session/1_42/myzig_notes", &list, "", "myzig2");
    defer gpa.free(bind);
    const msg2 = try dbus.message(gpa, .{ .type = .method_call, .serial = 3, .path = path, .interface = shortcuts, .member = "BindShortcuts", .destination = name, .signature = bind_shortcuts_signature }, bind);
    defer gpa.free(msg2);
    var m2 = try dbus.parse(msg2);
    try std.testing.expectEqualStrings("/org/freedesktop/portal/desktop/session/1_42/myzig_notes", try m2.body.string());
    // a(sa{sv}): the first shortcut's id and trigger.
    _ = try m2.body.u32_();
    try m2.body.alignTo(8);
    try std.testing.expectEqualStrings("CTRL+ALT+space", try m2.body.string());
    try std.testing.expectEqualStrings("CTRL+ALT+space", (try lookupString(&m2.body, "preferred_trigger")).?);
    try m2.body.alignTo(8);
    try std.testing.expectEqualStrings("SHIFT+F1", try m2.body.string());
    _ = try lookupString(&m2.body, "x");
    try std.testing.expectEqualStrings("", try m2.body.string());
    try std.testing.expectEqualStrings("myzig2", (try lookupString(&m2.body, "handle_token")).?);
    try std.testing.expectEqual(msg2.len, m2.body.pos);
}

test "the portal's signals: a response with its session, a shortcut activated" {
    const gpa = std.testing.allocator;
    var e: dbus.Encoder = .{ .gpa = gpa };
    defer e.deinit();
    try e.u32_(0);
    const res = try e.beginArray(8);
    try e.structStart();
    try e.string("shortcuts");
    try e.signature("a(sa{sv})");
    try encodeShortcuts(&e, &.{.{ .id = "a", .description = "A", .trigger = "" }});
    try e.structStart();
    try e.string("session_handle");
    try e.signature("o");
    try e.string("/org/freedesktop/portal/desktop/session/1_7/t");
    e.endArray(res);
    const msg = try dbus.message(gpa, .{ .type = .signal, .serial = 9, .path = "/org/freedesktop/portal/desktop/request/1_7/myzig1", .interface = request, .member = "Response", .signature = "ua{sv}" }, e.buf.items);
    defer gpa.free(msg);
    var m = try dbus.parse(msg);
    const r = parseResponse(&m).?;
    try std.testing.expectEqual(@as(u32, 0), r.code);
    try std.testing.expectEqualStrings("/org/freedesktop/portal/desktop/session/1_7/t", r.session_handle.?);

    var a: dbus.Encoder = .{ .gpa = gpa };
    defer a.deinit();
    try a.string("/org/freedesktop/portal/desktop/session/1_7/t");
    try a.string("CTRL+ALT+space");
    try a.alignTo(8);
    try a.buf.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u64, 1234)));
    const opts = try a.beginArray(8);
    try entryString(&a, "activation_token", "tok-1");
    a.endArray(opts);
    const msg2 = try dbus.message(gpa, .{ .type = .signal, .serial = 10, .path = path, .interface = shortcuts, .member = "Activated", .signature = "osta{sv}" }, a.buf.items);
    defer gpa.free(msg2);
    var m2 = try dbus.parse(msg2);
    const act = parseActivated(&m2).?;
    try std.testing.expectEqualStrings("CTRL+ALT+space", act.id);
    try std.testing.expectEqual(@as(u64, 1234), act.timestamp);
    try std.testing.expectEqualStrings("tok-1", act.activation_token.?);
    var m3 = try dbus.parse(msg2);
    try std.testing.expect(parseResponse(&m3) == null);
}
