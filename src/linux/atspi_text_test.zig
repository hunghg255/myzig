//! AT-SPI's Text through messages, answered from a Tester's tree: a text
//! field's and a text area's caret and selection set as Orca sets them
//! (SetCaretOffset, SetSelection, AddSelection, RemoveSelection), lines
//! as drawn, and where characters are and which is at a point.
const std = @import("std");
const dbus = @import("dbus.zig");
const proto = @import("atspi_proto.zig");
const serve = @import("atspi_serve.zig");
const ui = @import("../ui/ui.zig");
const access = @import("../ui/access.zig");
const Tree = @import("../ui/access_tree.zig").Tree;
const Node = @import("../ui/access_tree.zig").Node;
const testing = std.testing;
const I = proto.Interface;

const App = struct {
    name: ui.TextBuffer = .{},
    notes: ui.TextArea = undefined,

    fn view(s: *App, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(12), .gap = 8 });
        defer ui.end(c);
        _ = ui.textField(c, &s.name, .{ .label = "Name" });
        _ = ui.textArea(c, &s.notes, .{ .height = .{ .px = 120 } });
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
        f.app.name.set("héllo wide world");
        f.app.notes = .init(testing.allocator, "first line\nsecond line");
        try f.t.init(testing.allocator, .init(&f.app, App.view), .{});
        f.t.ctx.access.enabled = true;
        f.tree = .init(testing.allocator);
        f.win = .{ .tree = &f.tree, .title = "Demo", .origin = .{ .x = 100, .y = 50 }, .ptr = f, .perform = perform };
        f.windows = .{&f.win};
        f.step();
        f.step();
    }

    fn deinit(f: *Fixture) void {
        f.tree.deinit();
        f.t.deinit();
        f.app.notes.deinit();
    }

    fn step(f: *Fixture) void {
        f.t.frame();
        f.tree.build(&f.t.ctx);
    }

    fn field(f: *Fixture, multiline: bool) *const Node {
        for (f.tree.nodes.items) |*n| if (n.role == .text_field and n.states.multiline == multiline) return n;
        unreachable;
    }

    fn path(f: *Fixture, buf: []u8, multiline: bool) []const u8 {
        return proto.nodePath(buf, 0, f.field(multiline).id);
    }

    /// Calls `member` of Text on the field, its reply's body read by `read`.
    fn call(f: *Fixture, multiline: bool, member: []const u8, sig: []const u8, body: []const u8) !Reply {
        const gpa = testing.allocator;
        var buf: [96]u8 = undefined;
        const req = try dbus.message(gpa, .{ .type = .method_call, .serial = 9, .path = f.path(&buf, multiline), .interface = I.text, .member = member, .destination = ":1.42", .sender = ":1.7", .signature = sig }, body);
        defer gpa.free(req);
        var m = try dbus.parse(req);
        var e: dbus.Encoder = .{ .gpa = gpa };
        defer e.deinit();
        const mod: serve.Model = .{ .bus_name = ":1.42", .windows = &f.windows };
        const a = try serve.handle(&mod, &m, &e);
        if (a.error_name != null) return error.Remote;
        const reply = try dbus.message(gpa, .{ .type = .method_return, .serial = 1, .reply_serial = 9, .destination = ":1.7", .signature = a.signature }, e.buf.items);
        return .{ .bytes = reply, .msg = try dbus.parse(reply) };
    }
};

const Reply = struct {
    bytes: []u8,
    msg: dbus.Message,

    fn deinit(r: *Reply) void {
        testing.allocator.free(r.bytes);
    }

    fn boolean(r: *Reply) !bool {
        defer r.deinit();
        return try r.msg.body.u32_() != 0;
    }
};

fn ints(comptime n: usize, values: [n]i32) ![]u8 {
    var e: dbus.Encoder = .{ .gpa = testing.allocator };
    errdefer e.deinit();
    for (values) |v| try e.i32_(v);
    return e.buf.toOwnedSlice(testing.allocator);
}

test "the caret and the selection, set through AT-SPI" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();

    // The caret after "hé": characters, not bytes.
    const at2 = try ints(1, .{2});
    defer testing.allocator.free(at2);
    var r = try f.call(false, "SetCaretOffset", "i", at2);
    try testing.expect(try r.boolean());
    f.step();
    try testing.expectEqual(@as(u32, 3), f.field(false).caret);
    r = try f.call(false, "GetCaretOffset", "", "");
    try testing.expectEqual(@as(u32, 2), try r.msg.body.u32_());
    r.deinit();

    // "wide" selected, then removed, then added again.
    const sel = try ints(3, .{ 0, 6, 10 });
    defer testing.allocator.free(sel);
    r = try f.call(false, "SetSelection", "iii", sel);
    try testing.expect(try r.boolean());
    f.step();
    const n = f.field(false);
    try testing.expectEqual([2]u32{ 7, 11 }, [2]u32{ n.sel_start, n.sel_end });
    const zero = try ints(1, .{0});
    defer testing.allocator.free(zero);
    r = try f.call(false, "GetSelection", "i", zero);
    try testing.expectEqual(@as(u32, 6), try r.msg.body.u32_());
    try testing.expectEqual(@as(u32, 10), try r.msg.body.u32_());
    r.deinit();
    // One selection at most: none is added while there is one.
    const add = try ints(2, .{ 0, 5 });
    defer testing.allocator.free(add);
    r = try f.call(false, "AddSelection", "ii", add);
    try testing.expect(!try r.boolean());
    r = try f.call(false, "RemoveSelection", "i", zero);
    try testing.expect(try r.boolean());
    f.step();
    try testing.expectEqual(f.field(false).sel_start, f.field(false).sel_end);
    r = try f.call(false, "AddSelection", "ii", add);
    try testing.expect(try r.boolean());
    f.step();
    try testing.expectEqual([2]u32{ 0, 6 }, [2]u32{ f.field(false).sel_start, f.field(false).sel_end });

    // In the text area: the second line selected.
    const line = try ints(3, .{ 0, 11, 22 });
    defer testing.allocator.free(line);
    r = try f.call(true, "SetSelection", "iii", line);
    try testing.expect(try r.boolean());
    f.step();
    try testing.expectEqual(@as(usize, 11), f.app.notes.sel.lo());
    try testing.expectEqual(@as(usize, 22), f.app.notes.sel.hi());
}

test "lines as drawn, where characters are, and the character at a point" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();

    var e: dbus.Encoder = .{ .gpa = testing.allocator };
    defer e.deinit();
    try e.i32_(13);
    try e.u32_(3);
    var r = try f.call(true, "GetStringAtOffset", "iu", e.buf.items);
    try testing.expectEqualStrings("second line", try r.msg.body.string());
    r.deinit();

    // "w" of "wide", in the window's coordinates (1) and the screen's (0).
    e.buf.clearRetainingCapacity();
    try e.i32_(6);
    try e.u32_(1);
    r = try f.call(false, "GetCharacterExtents", "iu", e.buf.items);
    try r.msg.body.alignTo(8);
    var box: [4]i32 = undefined;
    for (&box) |*v| v.* = try proto.readInt(&r.msg.body);
    r.deinit();
    const n = f.field(false);
    try testing.expect(box[2] > 0 and box[3] > 0);
    try testing.expect(@as(f32, @floatFromInt(box[0])) > n.rect.x + 20 and @as(f32, @floatFromInt(box[0])) < n.rect.x + n.rect.w);
    e.buf.clearRetainingCapacity();
    try e.i32_(6);
    try e.u32_(0);
    r = try f.call(false, "GetCharacterExtents", "iu", e.buf.items);
    try r.msg.body.alignTo(8);
    try testing.expectEqual(box[0] + 100, try proto.readInt(&r.msg.body));
    r.deinit();

    // The point inside that box is on it.
    e.buf.clearRetainingCapacity();
    try e.i32_(box[0] + 1);
    try e.i32_(box[1] + @divTrunc(box[3], 2));
    try e.u32_(1);
    r = try f.call(false, "GetOffsetAtPoint", "iiu", e.buf.items);
    try testing.expectEqual(@as(u32, 6), try r.msg.body.u32_());
    r.deinit();

    // The text area's two lines: their boxes stack.
    e.buf.clearRetainingCapacity();
    try e.i32_(0);
    try e.i32_(22);
    try e.u32_(1);
    r = try f.call(true, "GetRangeExtents", "iiu", e.buf.items);
    try r.msg.body.alignTo(8);
    for (&box) |*v| v.* = try proto.readInt(&r.msg.body);
    r.deinit();
    try testing.expect(box[3] > 30);
}
