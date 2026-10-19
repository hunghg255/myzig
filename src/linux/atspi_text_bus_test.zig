//! On a real accessibility bus (the Linux container, with at-spi2-core):
//! another client moves a text field's caret and selects in it through
//! the bus, as Orca does; and the session's status, watched, tells an app
//! started before assistive technology when it turns on. Skipped without
//! a bus.
const std = @import("std");
const c = std.c;
const dbus = @import("dbus.zig");
const conn = @import("dbus_conn.zig");
const proto = @import("atspi_proto.zig");
const atspi = @import("atspi.zig");
const status = @import("atspi_status.zig");
const ui = @import("../ui/ui.zig");
const testing = std.testing;
const I = proto.Interface;

const App = struct {
    name: ui.TextBuffer = .{},
    fn view(s: *App, cx: *ui.Context) void {
        ui.column(cx, .{ .padding = .all(12) });
        defer ui.end(cx);
        _ = ui.textField(cx, &s.name, .{ .label = "Name" });
    }
};

fn noFrame(_: *anyopaque) void {}

/// Answers calls on another thread while the test, a client, waits for one.
const Serving = struct {
    server: *atspi.Server,
    stop: std.atomic.Value(bool) = .init(false),

    fn run(s: *Serving) void {
        while (!s.stop.load(.acquire)) {
            var fds = [_]c.pollfd{.{ .fd = s.server.bus.fd, .events = c.POLL.IN, .revents = 0 }};
            if (c.poll(&fds, 1, 50) > 0) s.server.dispatch();
        }
    }
};

/// Calls Text's `member` on `path`, served meanwhile: its boolean reply.
fn served(server: *atspi.Server, client: *conn.Bus, path: []const u8, member: []const u8, sig: []const u8, body: []const u8) !bool {
    var serving: Serving = .{ .server = server };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    const r = client.call(.{ .destination = server.name, .path = path, .interface = I.text, .member = member }, sig, body);
    serving.stop.store(true, .release);
    thread.join();
    var reply = try r;
    defer reply.deinit(testing.allocator);
    var m = try reply.message();
    return try m.body.u32_() != 0;
}

test "on the accessibility bus: a client moves a field's caret and selects in it" {
    const gpa = testing.allocator;
    if (c.getenv("DBUS_SESSION_BUS_ADDRESS") == null and c.getenv("AT_SPI_BUS_ADDRESS") == null) return error.SkipZigTest;
    const address = (atspi.busAddress(gpa) catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer gpa.free(address);
    const server = atspi.Server.connect(gpa, address) catch return error.SkipZigTest;
    defer server.close();

    var app: App = .{};
    app.name.set("hello wide world");
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&app, App.view), .{});
    defer t.deinit();
    const link = try server.attach(.{ .ptr = &t, .ctx = &t.ctx, .request_frame = noFrame });
    defer link.detach();
    t.frame();
    link.update();

    const client = try conn.Bus.open(gpa, address);
    defer client.close();
    var buf: [96]u8 = undefined;
    const path = proto.nodePath(&buf, link.k, link.tree.byName(.text_field, "Name").?.id);
    var e: dbus.Encoder = .{ .gpa = gpa };
    defer e.deinit();

    try e.i32_(5);
    try testing.expect(try served(server, client, path, "SetCaretOffset", "i", e.buf.items));
    t.frame();
    link.update();
    const field = link.tree.byName(.text_field, "Name").?;
    try testing.expectEqual(@as(u32, 5), field.caret);
    try testing.expectEqual(field.sel_start, field.sel_end);

    e.buf.clearRetainingCapacity();
    try e.i32_(0);
    try e.i32_(6);
    try e.i32_(10);
    try testing.expect(try served(server, client, path, "SetSelection", "iii", e.buf.items));
    t.frame();
    link.update();
    var n = link.tree.byName(.text_field, "Name").?;
    try testing.expectEqual([2]u32{ 6, 10 }, [2]u32{ n.sel_start, n.sel_end });
    // Typing replaces what the client selected.
    t.ctx.focus = n.id;
    t.typeText("WIDE");
    try testing.expectEqualStrings("hello WIDE world", app.name.text());

    // A selection added where there is none.
    e.buf.clearRetainingCapacity();
    try e.i32_(0);
    try e.i32_(5);
    link.update();
    try testing.expect(try served(server, client, path, "AddSelection", "ii", e.buf.items));
    t.frame();
    link.update();
    n = link.tree.byName(.text_field, "Name").?;
    try testing.expectEqual([2]u32{ 0, 5 }, [2]u32{ n.sel_start, n.sel_end });
}

fn wake(p: *anyopaque) void {
    const woke: *bool = @ptrCast(@alignCast(p));
    woke.* = true;
}

test "the session's accessibility status, watched: turned on later, it is seen" {
    const gpa = testing.allocator;
    if (c.getenv("DBUS_SESSION_BUS_ADDRESS") == null) return error.SkipZigTest;
    const session = conn.Bus.session(gpa) catch return error.SkipZigTest;
    defer session.close();
    const was = status.get(session, "IsEnabled") catch return error.SkipZigTest;
    const was_reader = status.get(session, "ScreenReaderEnabled") catch false;
    defer {
        status.set(session, "IsEnabled", was) catch {};
        status.set(session, "ScreenReaderEnabled", was_reader) catch {};
    }
    try status.set(session, "IsEnabled", false);
    try status.set(session, "ScreenReaderEnabled", false);

    const w = try status.Watch.open(gpa);
    defer w.close();
    try testing.expect(!w.on());
    if (c.getenv("AT_SPI_BUS_ADDRESS") == null and c.getenv("MYZIG_A11Y") == null) {
        const off = try atspi.busAddress(gpa);
        try testing.expect(off == null);
    }

    // Orca starts: the desktop turns the status on, and the watch hears it.
    try status.set(session, "ScreenReaderEnabled", true);
    var seen = false;
    var tries: usize = 0;
    // Waits for the signal (the guard only turns a hang into a failure).
    while (!seen and tries < 600) : (tries += 1) {
        var fds = [_]c.pollfd{.{ .fd = w.bus.fd, .events = c.POLL.IN, .revents = 0 }};
        if (c.poll(&fds, 1, 100) > 0) seen = w.dispatch() == .turned_on;
    }
    try testing.expect(seen and w.on());
    const address = (try atspi.busAddress(gpa)) orelse return error.StillOff;
    gpa.free(address);

    // Surfaces waiting are woken once it turns on, to try again.
    var woke = false;
    atspi.wait(std.heap.c_allocator, &woke, wake);
    atspi.turnedOn();
    try testing.expect(woke);
}
