//! AT-SPI through messages: calls built as Orca's are, answered from a
//! Tester's tree, the replies parsed (anywhere); then, where the session
//! has an accessibility bus with its registry (the Linux container), the
//! app embedded in the desktop and read and acted on by another client.
const std = @import("std");
const builtin = @import("builtin");
const dbus = @import("dbus.zig");
const proto = @import("atspi_proto.zig");
const serve = @import("atspi_serve.zig");
const ui = @import("../ui/ui.zig");
const access = @import("../ui/access.zig");
const Tree = @import("../ui/access_tree.zig").Tree;
const testing = std.testing;
const I = proto.Interface;

const App = struct {
    saves: u32 = 0,
    wifi: bool = false,
    volume: f32 = 0.5,
    name: ui.TextBuffer = .{},

    fn view(s: *App, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(12), .gap = 8 });
        defer ui.end(c);
        ui.heading(c, "Settings");
        if (ui.button(c, "Save", .{}).clicked) s.saves += 1;
        _ = ui.toggle(c, "Wi-Fi", &s.wifi);
        _ = ui.slider(c, &s.volume, .{ .label = "Volume" });
        _ = ui.textField(c, &s.name, .{ .label = "Name" });
    }
};

const Fixture = struct {
    app: App = .{},
    t: ui.Tester = undefined,
    tree: Tree = undefined,
    win: serve.Window = undefined,
    windows: [1]?*serve.Window = undefined,

    fn perform(p: *anyopaque, id: u64, role: access.Role, action: access.Action) void {
        const f: *Fixture = @ptrCast(@alignCast(p));
        access.perform(&f.t.ctx, id, role, action);
    }

    fn init(f: *Fixture) !void {
        try f.t.init(testing.allocator, .init(&f.app, App.view), .{});
        f.t.ctx.access.enabled = true;
        f.tree = .init(testing.allocator);
        f.win = .{ .tree = &f.tree, .title = "Demo", .origin = .{ .x = 100, .y = 50 }, .ptr = f, .perform = perform };
        f.windows = .{&f.win};
        f.step();
    }

    fn deinit(f: *Fixture) void {
        f.tree.deinit();
        f.t.deinit();
    }

    fn step(f: *Fixture) void {
        f.t.frame();
        f.tree.build(&f.t.ctx);
    }

    fn model(f: *Fixture) serve.Model {
        return .{ .bus_name = ":1.42", .parent_bus = "org.a11y.atspi.Registry", .parent_path = proto.root_path, .windows = &f.windows };
    }

    fn pathOf(f: *Fixture, buf: []u8, name: []const u8) []const u8 {
        return proto.nodePath(buf, 0, f.tree.byName(.auto, name).?.id);
    }
};

/// A call as a client sends it, answered, and its reply as it reads it.
const Call = struct {
    reply: []u8,
    msg: dbus.Message,

    fn deinit(c: *Call) void {
        testing.allocator.free(c.reply);
    }
};

fn call(f: *Fixture, path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) !Call {
    const gpa = testing.allocator;
    const req = try dbus.message(gpa, .{ .type = .method_call, .serial = 9, .path = path, .interface = iface, .member = member, .destination = ":1.42", .sender = ":1.7", .signature = sig }, body);
    defer gpa.free(req);
    var m = try dbus.parse(req);
    var e: dbus.Encoder = .{ .gpa = gpa };
    defer e.deinit();
    const mod = f.model();
    const a = try serve.handle(&mod, &m, &e);
    if (a.error_name) |name| {
        std.debug.print("error {s} for {s}.{s}\n", .{ name, iface, member });
        return error.Remote;
    }
    const reply = try dbus.message(gpa, .{ .type = .method_return, .serial = 1, .reply_serial = 9, .destination = ":1.7", .signature = a.signature }, e.buf.items);
    errdefer gpa.free(reply);
    const r = try dbus.parse(reply);
    try testing.expectEqual(@as(u32, 9), r.header.reply_serial);
    return .{ .reply = reply, .msg = r };
}

fn args(comptime fmt: []const u8, values: anytype) ![]u8 {
    var e: dbus.Encoder = .{ .gpa = testing.allocator };
    errdefer e.deinit();
    inline for (fmt, 0..) |ch, i| switch (ch) {
        's' => try e.string(values[i]),
        'i' => try e.i32_(values[i]),
        'u' => try e.u32_(values[i]),
        else => @compileError("unsupported"),
    };
    return e.buf.toOwnedSlice(testing.allocator);
}

test "the application, its window and the elements, as AT-SPI reads them" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();

    // The application: one window, a frame.
    var r = try call(&f, proto.root_path, I.accessible, "GetChildren", "", "");
    try testing.expectEqualStrings("a(so)", r.msg.header.signature);
    _ = try r.msg.body.u32_();
    try r.msg.body.alignTo(8);
    try testing.expectEqualStrings(":1.42", try r.msg.body.string());
    var wbuf: [64]u8 = undefined;
    const got = try r.msg.body.string();
    const window_path = wbuf[0..got.len];
    @memcpy(window_path, got);
    try testing.expectEqualStrings("/org/a11y/atspi/accessible/0", window_path);
    r.deinit();
    r = try call(&f, window_path, I.accessible, "GetRole", "", "");
    try testing.expectEqual(@as(u32, proto.AtRole.frame), try r.msg.body.u32_());
    r.deinit();

    var buf: [96]u8 = undefined;
    const save = f.pathOf(&buf, "Save");
    r = try call(&f, save, I.accessible, "GetRole", "", "");
    try testing.expectEqual(@as(u32, proto.AtRole.push_button), try r.msg.body.u32_());
    r.deinit();
    const get = try args("ss", .{ I.accessible, "Name" });
    defer testing.allocator.free(get);
    r = try call(&f, save, I.properties, "Get", "ss", get);
    try testing.expectEqualStrings("s", try r.msg.body.signature());
    try testing.expectEqualStrings("Save", try r.msg.body.string());
    r.deinit();
    r = try call(&f, save, I.accessible, "GetState", "", "");
    _ = try r.msg.body.u32_();
    const lo = try r.msg.body.u32_();
    const states: proto.StateSet = .{ .bits = lo };
    try testing.expect(states.has(.focusable) and states.has(.enabled) and states.has(.showing));
    r.deinit();
    r = try call(&f, save, I.accessible, "GetInterfaces", "", "");
    try testing.expectEqualStrings("as", r.msg.header.signature);
    const n_ifaces = try r.msg.body.u32_();
    try testing.expect(n_ifaces > 0);
    try testing.expectEqualStrings(I.accessible, try r.msg.body.string());
    try testing.expectEqualStrings(I.component, try r.msg.body.string());
    try testing.expectEqualStrings(I.action, try r.msg.body.string());
    r.deinit();

    // Its place on the screen: the window's origin and its box.
    const coords = try args("u", .{@as(u32, 0)});
    defer testing.allocator.free(coords);
    r = try call(&f, save, I.component, "GetExtents", "u", coords);
    try r.msg.body.alignTo(8);
    const x = try proto.readInt(&r.msg.body);
    const node = f.tree.byName(.button, "Save").?;
    try testing.expectEqual(@as(i32, @intFromFloat(@round(100 + node.rect.x))), x);
    r.deinit();

    // A heading says its level.
    const heading = f.pathOf(&buf, "Settings");
    r = try call(&f, heading, I.accessible, "GetRole", "", "");
    try testing.expectEqual(@as(u32, proto.AtRole.heading), try r.msg.body.u32_());
    r.deinit();
}

test "actions through AT-SPI change the app's state" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var buf: [96]u8 = undefined;

    const zero = try args("i", .{@as(i32, 0)});
    defer testing.allocator.free(zero);
    var r = try call(&f, f.pathOf(&buf, "Save"), I.action, "GetName", "i", zero);
    try testing.expectEqualStrings("click", try r.msg.body.string());
    r.deinit();
    r = try call(&f, f.pathOf(&buf, "Save"), I.action, "DoAction", "i", zero);
    try testing.expect(try r.msg.body.u32_() == 1);
    r.deinit();
    f.step();
    try testing.expectEqual(@as(u32, 1), f.app.saves);

    r = try call(&f, f.pathOf(&buf, "Wi-Fi"), I.action, "DoAction", "i", zero);
    r.deinit();
    f.step();
    try testing.expect(f.app.wifi);
    r = try call(&f, f.pathOf(&buf, "Wi-Fi"), I.accessible, "GetState", "", "");
    _ = try r.msg.body.u32_();
    try testing.expect((proto.StateSet{ .bits = try r.msg.body.u32_() }).has(.checked));
    r.deinit();

    // The slider's value, set as the arrows move it.
    var e: dbus.Encoder = .{ .gpa = testing.allocator };
    defer e.deinit();
    try e.string(I.value);
    try e.string("CurrentValue");
    try proto.variant(&e, .{ .d = 1 });
    r = try call(&f, f.pathOf(&buf, "Volume"), I.properties, "Set", "ssv", e.buf.items);
    r.deinit();
    f.step();
    try testing.expect(f.app.volume > 0.5);

    const text = try args("s", .{"Ada Lovelace"});
    defer testing.allocator.free(text);
    r = try call(&f, f.pathOf(&buf, "Name"), I.editable_text, "SetTextContents", "s", text);
    r.deinit();
    f.step();
    try testing.expectEqualStrings("Ada Lovelace", f.app.name.text());
    const word = try args("iu", .{ @as(i32, 5), @as(u32, 1) });
    defer testing.allocator.free(word);
    r = try call(&f, f.pathOf(&buf, "Name"), I.text, "GetStringAtOffset", "iu", word);
    try testing.expectEqualStrings("Lovelace", try r.msg.body.string());
    r.deinit();
}

test "events: a signal's body as listeners parse it" {
    const gpa = testing.allocator;
    var e: dbus.Encoder = .{ .gpa = gpa };
    defer e.deinit();
    try proto.eventBody(&e, "checked", 1, 0, .{ .i = 0 });
    const msg = try dbus.message(gpa, .{ .type = .signal, .serial = 3, .path = "/org/a11y/atspi/accessible/0_1", .interface = I.event_object, .member = "StateChanged", .signature = "siiva{sv}" }, e.buf.items);
    defer gpa.free(msg);
    var m = try dbus.parse(msg);
    try testing.expectEqualStrings("StateChanged", m.header.member);
    try testing.expectEqualStrings("checked", try m.body.string());
    try testing.expectEqual(@as(i32, 1), try proto.readInt(&m.body));
    try testing.expectEqual(@as(i32, 0), try proto.readInt(&m.body));
    try testing.expectEqualStrings("i", try m.body.signature());
}

test {
    _ = proto;
    _ = @import("atspi_text.zig");
    _ = @import("atspi_text_test.zig");
    _ = @import("atspi_status.zig");
    if (builtin.os.tag == .linux) {
        _ = @import("atspi_bus_test.zig");
        _ = @import("atspi_text_bus_test.zig");
    }
}
