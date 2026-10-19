//! AT-SPI on a real accessibility bus (the Linux container, with
//! at-spi2-core): the app embeds itself in the registry's desktop, which
//! then lists it, and another client reads its elements and presses a
//! button through the bus, as Orca would. Skipped without a bus.
const std = @import("std");
const c = std.c;
const dbus = @import("dbus.zig");
const conn = @import("dbus_conn.zig");
const proto = @import("atspi_proto.zig");
const atspi = @import("atspi.zig");
const ui = @import("../ui/ui.zig");
const testing = std.testing;
const I = proto.Interface;

const App = struct {
    saves: u32 = 0,
    fn view(s: *App, cx: *ui.Context) void {
        ui.column(cx, .{ .padding = .all(12) });
        defer ui.end(cx);
        if (ui.button(cx, "Save", .{}).clicked) s.saves += 1;
    }
};

fn noFrame(_: *anyopaque) void {}

/// Answers calls on another thread while the test, a client, waits for them.
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

fn childrenOf(client: *conn.Bus, dest: []const u8, path: []const u8, out: *std.ArrayList([2][]u8)) !void {
    var r = try client.call(.{ .destination = dest, .path = path, .interface = I.accessible, .member = "GetChildren" }, "", "");
    defer r.deinit(testing.allocator);
    var m = try r.message();
    const len = try m.body.u32_();
    try m.body.alignTo(8);
    const end = m.body.pos + len;
    while (m.body.pos < end) {
        try m.body.alignTo(8);
        const bus = try testing.allocator.dupe(u8, try m.body.string());
        const p = try testing.allocator.dupe(u8, try m.body.string());
        try out.append(testing.allocator, .{ bus, p });
    }
}

fn freeAll(list: *std.ArrayList([2][]u8)) void {
    for (list.items) |x| {
        testing.allocator.free(x[0]);
        testing.allocator.free(x[1]);
    }
    list.deinit(testing.allocator);
}

test "on the accessibility bus: embedded in the desktop, read and pressed by a client" {
    const gpa = testing.allocator;
    if (c.getenv("DBUS_SESSION_BUS_ADDRESS") == null and c.getenv("AT_SPI_BUS_ADDRESS") == null) return error.SkipZigTest;
    const address = (atspi.busAddress(gpa) catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer gpa.free(address);
    const server = atspi.Server.connect(gpa, address) catch return error.SkipZigTest;
    defer server.close();

    var app: App = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&app, App.view), .{});
    defer t.deinit();
    const link = try server.attach(.{ .ptr = &t, .ctx = &t.ctx, .request_frame = noFrame });
    defer link.detach();
    t.frame();
    link.update();

    var serving: Serving = .{ .server = server };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        serving.stop.store(true, .release);
        thread.join();
    }

    const client = try conn.Bus.open(gpa, address);
    defer client.close();
    // The desktop lists the app.
    var apps: std.ArrayList([2][]u8) = .empty;
    defer freeAll(&apps);
    try childrenOf(client, "org.a11y.atspi.Registry", proto.root_path, &apps);
    var listed = false;
    for (apps.items) |x| listed = listed or std.mem.eql(u8, x[0], server.name);
    try testing.expect(listed);

    // The app's window, and the button in it.
    var wins: std.ArrayList([2][]u8) = .empty;
    defer freeAll(&wins);
    try childrenOf(client, server.name, proto.root_path, &wins);
    try testing.expectEqual(@as(usize, 1), wins.items.len);
    var buf: [96]u8 = undefined;
    const save = proto.nodePath(&buf, link.k, link.tree.byName(.button, "Save").?.id);
    var e: dbus.Encoder = .{ .gpa = gpa };
    defer e.deinit();
    try e.string(I.accessible);
    try e.string("Name");
    var r = try client.call(.{ .destination = server.name, .path = save, .interface = I.properties, .member = "Get" }, "ss", e.buf.items);
    var m = try r.message();
    _ = try m.body.signature();
    try testing.expectEqualStrings("Save", try m.body.string());
    r.deinit(gpa);

    e.buf.clearRetainingCapacity();
    try e.i32_(0);
    r = try client.call(.{ .destination = server.name, .path = save, .interface = I.action, .member = "DoAction" }, "i", e.buf.items);
    m = try r.message();
    try testing.expect(try m.body.u32_() == 1);
    r.deinit(gpa);
    serving.stop.store(true, .release);
    t.frame();
    try testing.expectEqual(@as(u32, 1), app.saves);
}
