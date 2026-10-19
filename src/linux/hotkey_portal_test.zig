//! Global shortcuts through a mock GlobalShortcuts portal on a real
//! session bus (the Linux container, under dbus-run-session): the mock,
//! on a thread with a connection of its own, answers as
//! xdg-desktop-portal does (a request's path, then its Response signal)
//! and reports a press; the portal state binds, rebinds when shortcuts
//! change, and closes its sessions. Skipped without a session bus.
const std = @import("std");
const c = std.c;
const dbus = @import("dbus.zig");
const Bus = @import("dbus_conn.zig").Bus;
const msgs = @import("dbus_portal.zig");
const hp = @import("hotkey_portal.zig");
const menu_types = @import("../menu_types.zig");

const mock_name = "org.myzig.test.Portal";

const Mock = struct {
    bus: *Bus,
    stop: std.atomic.Value(bool) = .init(false),
    sessions: std.atomic.Value(u32) = .init(0),
    binds: std.atomic.Value(u32) = .init(0),
    closes: std.atomic.Value(u32) = .init(0),
    last_bound: std.atomic.Value(u32) = .init(0),
    /// A press of the first shortcut follows the first bind.
    pressed: bool = false,

    fn reply(m: *Mock, call: *dbus.Message, signature: []const u8, body: []const u8) void {
        const gpa = m.bus.gpa;
        m.bus.serial += 1;
        const out = dbus.message(gpa, .{ .type = .method_return, .serial = m.bus.serial, .reply_serial = call.header.serial, .destination = call.header.sender, .signature = signature }, body) catch return;
        defer gpa.free(out);
        m.bus.writeAll(out) catch {};
    }

    fn emit(m: *Mock, path: []const u8, iface: []const u8, member: []const u8, signature: []const u8, body: []const u8) void {
        const gpa = m.bus.gpa;
        m.bus.serial += 1;
        const out = dbus.message(gpa, .{ .type = .signal, .serial = m.bus.serial, .path = path, .interface = iface, .member = member, .signature = signature }, body) catch return;
        defer gpa.free(out);
        m.bus.writeAll(out) catch {};
    }

    /// Answers a request with its path, then its Response with `results`.
    fn answer(m: *Mock, call: *dbus.Message, handle_token: []const u8, results: []const u8) void {
        var pb: [256]u8 = undefined;
        const path = msgs.requestPath(&pb, call.header.sender, handle_token) catch return;
        var e: dbus.Encoder = .{ .gpa = m.bus.gpa };
        defer e.deinit();
        e.string(path) catch return;
        m.reply(call, "o", e.buf.items);
        var r: dbus.Encoder = .{ .gpa = m.bus.gpa };
        defer r.deinit();
        r.u32_(0) catch return;
        r.buf.appendSlice(m.bus.gpa, results) catch return;
        m.emit(path, msgs.request, "Response", "ua{sv}", r.buf.items);
    }

    fn handle(m: *Mock, call: *dbus.Message) void {
        const gpa = m.bus.gpa;
        const h = call.header;
        if (std.mem.eql(u8, h.member, "Register")) return m.reply(call, "", "");
        if (std.mem.eql(u8, h.member, "Get")) {
            var e: dbus.Encoder = .{ .gpa = gpa };
            defer e.deinit();
            e.signature("u") catch return;
            e.u32_(1) catch return;
            return m.reply(call, "v", e.buf.items);
        }
        if (std.mem.eql(u8, h.member, "Close")) {
            _ = m.closes.fetchAdd(1, .release);
            return;
        }
        if (std.mem.eql(u8, h.member, "CreateSession")) {
            var d = call.body;
            const handle_token = (msgs.lookupString(&d, "handle_token") catch null) orelse return;
            d = call.body;
            const session_token = (msgs.lookupString(&d, "session_handle_token") catch null) orelse return;
            var sb: [256]u8 = undefined;
            const session = msgs.sessionPath(&sb, h.sender, session_token) catch return;
            var r: dbus.Encoder = .{ .gpa = gpa };
            defer r.deinit();
            r.u32_(0) catch return; // where the code goes, removed below
            const res = r.beginArray(8) catch return;
            r.structStart() catch return;
            r.string("session_handle") catch return;
            r.signature("o") catch return;
            r.string(session) catch return;
            r.endArray(res);
            _ = m.sessions.fetchAdd(1, .release);
            // The results start 8-aligned after the code: keep their bytes.
            return m.answer(call, handle_token, r.buf.items[4..]);
        }
        if (std.mem.eql(u8, h.member, "BindShortcuts")) {
            var d = call.body;
            const session = d.string() catch return;
            const n_bytes = d.u32_() catch return;
            d.alignTo(8) catch return;
            const end = d.pos + n_bytes;
            var count: u32 = 0;
            var first: [64]u8 = undefined;
            var first_len: usize = 0;
            while (d.pos < end) : (count += 1) {
                d.alignTo(8) catch return;
                const id = d.string() catch return;
                if (count == 0) {
                    first_len = @min(id.len, first.len);
                    @memcpy(first[0..first_len], id[0..first_len]);
                }
                _ = msgs.lookupString(&d, "") catch return;
            }
            _ = d.string() catch return; // the parent window
            const handle_token = (msgs.lookupString(&d, "handle_token") catch null) orelse return;
            m.last_bound.store(count, .release);
            m.answer(call, handle_token, &.{ 0, 0, 0, 0 });
            _ = m.binds.fetchAdd(1, .release);
            if (!m.pressed) {
                m.pressed = true;
                var a: dbus.Encoder = .{ .gpa = gpa };
                defer a.deinit();
                a.string(session) catch return;
                a.string(first[0..first_len]) catch return;
                a.alignTo(8) catch return;
                a.buf.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u64, 99))) catch return;
                const opts = a.beginArray(8) catch return;
                msgs.entryString(&a, "activation_token", "tok") catch return;
                a.endArray(opts);
                m.emit(msgs.path, msgs.shortcuts, "Activated", "osta{sv}", a.buf.items);
            }
        }
    }

    fn run(m: *Mock) void {
        while (!m.stop.load(.acquire)) {
            const bytes = (m.bus.next(50) catch return) orelse continue;
            defer m.bus.gpa.free(bytes);
            var msg = dbus.parse(bytes) catch continue;
            if (msg.header.type == .method_call) m.handle(&msg);
        }
    }
};

const App = struct {
    portal: ?*hp.Portal = null,
    presses: u32 = 0,
    last: u32 = 0,
    token_ok: bool = false,

    fn pressed(ctx: *anyopaque, hotkey: u32, token: ?[]const u8) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        a.presses += 1;
        a.last = hotkey;
        a.token_ok = token != null and std.mem.eql(u8, token.?, "tok");
    }

    fn onSignal(ctx: ?*anyopaque, m: *dbus.Message) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        if (a.portal) |p| _ = p.signal(m);
    }
};

/// Handles the bus's messages until `done` holds (the guard only turns a
/// hang into a failure).
fn pump(bus: *Bus, ctx: anytype, comptime done: fn (@TypeOf(ctx)) bool) !void {
    var guard: usize = 0;
    while (!done(ctx)) : (guard += 1) {
        if (guard > 1200) return error.Hang;
        var fds = [_]c.pollfd{.{ .fd = bus.fd, .events = c.POLL.IN, .revents = 0 }};
        if (c.poll(&fds, 1, 50) > 0) bus.dispatch();
    }
}

fn requestName(bus: *Bus, name: []const u8) !void {
    var e: dbus.Encoder = .{ .gpa = bus.gpa };
    defer e.deinit();
    try e.string(name);
    try e.u32_(4); // DBUS_NAME_FLAG_DO_NOT_QUEUE
    var r = try bus.call(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "RequestName" }, "su", e.buf.items);
    defer r.deinit(bus.gpa);
    var m = try r.message();
    if (try m.body.u32_() != 1) return error.NameTaken;
}

test "global shortcuts bound through the GlobalShortcuts portal, pressed, rebound and closed" {
    const gpa = std.heap.c_allocator;
    const portal_bus = Bus.session(gpa) catch return error.SkipZigTest;
    defer portal_bus.close();
    try requestName(portal_bus, mock_name);
    var mock: Mock = .{ .bus = portal_bus };
    const thread = try std.Thread.spawn(.{}, Mock.run, .{&mock});
    defer {
        mock.stop.store(true, .release);
        thread.join();
    }

    const bus = try Bus.session(gpa);
    defer bus.close();
    var app: App = .{};
    bus.on_signal = App.onSignal;
    bus.signal_ctx = &app;
    const p = hp.Portal.open(gpa, bus, "com.example.notes", &app, App.pressed, mock_name) orelse return error.NoPortal;
    app.portal = p;
    defer p.close();

    try p.add(1, menu_types.parseAccelerator("CmdOrCtrl+Alt+Space"), "CmdOrCtrl+Alt+Space");
    // Created, bound, and the mock's press of it delivered.
    try pump(bus, &app, struct {
        fn f(a: *App) bool {
            return a.presses == 1 and a.portal.?.pending == null;
        }
    }.f);
    try std.testing.expectEqual(@as(u32, 1), app.last);
    try std.testing.expect(app.token_ok);
    try std.testing.expect(std.mem.endsWith(u8, p.session.?, "/myzig_com_example_notes"));
    try std.testing.expectEqualStrings("CTRL+ALT+space", p.entries.items[0].id);
    try std.testing.expectEqualStrings("Ctrl+Alt+Space", p.entries.items[0].description);

    // Another shortcut: the session is replaced by one binding both.
    try p.add(2, menu_types.parseAccelerator("Shift+F1"), "Shift+F1");
    try pump(bus, &mock, struct {
        fn f(m: *Mock) bool {
            return m.binds.load(.acquire) == 2;
        }
    }.f);
    try pump(bus, p, struct {
        fn f(q: *hp.Portal) bool {
            return q.pending == null;
        }
    }.f);
    try std.testing.expectEqual(@as(u32, 2), mock.last_bound.load(.acquire));
    try std.testing.expectEqual(@as(u32, 2), mock.sessions.load(.acquire));

    // None left: the session is closed, and no new one made.
    p.remove(1);
    p.remove(2);
    try pump(bus, p, struct {
        fn f(q: *hp.Portal) bool {
            return q.pending == null and q.session == null;
        }
    }.f);
    // The session of the first removal, made while the second came, is closed too.
    try pump(bus, &mock, struct {
        fn f(m: *Mock) bool {
            return m.closes.load(.acquire) == m.sessions.load(.acquire);
        }
    }.f);
    try std.testing.expectEqual(@as(u32, 1), app.presses);
}
