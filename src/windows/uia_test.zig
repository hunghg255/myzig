//! UI Automation in process: the provider of a hidden window showing a
//! Tester's view, queried through its COM interfaces, then through UI
//! Automation's own client (CUIAutomation), which asks the window with
//! WM_GETOBJECT as Narrator does: names, control types, patterns, and
//! buttons invoked, boxes toggled, values set.
const std = @import("std");
const builtin = @import("builtin");
const w = @import("win32.zig");
const com = @import("com.zig");
const api_mod = @import("uia_api.zig");
const uia = @import("uia.zig");
const ui = @import("../ui/ui.zig");
const access = @import("../ui/access.zig");
const testing = std.testing;

const App = struct {
    saves: u32 = 0,
    remember: bool = false,
    volume: f32 = 0.5,
    name: ui.TextBuffer = .{},

    fn view(s: *App, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(12), .gap = 8 });
        defer ui.end(c);
        if (ui.button(c, "Save", .{}).clicked) s.saves += 1;
        _ = ui.checkbox(c, "Remember me", &s.remember);
        _ = ui.slider(c, &s.volume, .{ .label = "Volume" });
        _ = ui.textField(c, &s.name, .{ .label = "Name" });
    }
};

const Fixture = struct {
    app: App = .{},
    t: ui.Tester = undefined,
    hwnd: w.HWND = undefined,
    acc: *uia.Access = undefined,

    var current: ?*Fixture = null;

    fn perform(p: *anyopaque, id: u64, role: access.Role, action: access.Action) void {
        const f: *Fixture = @ptrCast(@alignCast(p));
        access.perform(&f.t.ctx, id, role, action);
    }

    fn frameNow(p: *anyopaque) void {
        const f: *Fixture = @ptrCast(@alignCast(p));
        f.step();
    }

    fn scale(_: *anyopaque) f32 {
        return 1;
    }

    /// A frame, as a surface runs it, then the tree updated.
    fn step(f: *Fixture) void {
        f.t.frame();
        f.acc.update();
    }

    fn wndProc(h: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
        if (msg == api_mod.WM_GETOBJECT) if (current) |f| if (f.acc.getObject(wp, lp)) |r| return r;
        return w.DefWindowProcW(h, msg, wp, lp);
    }

    fn init(f: *Fixture) !void {
        try f.t.init(testing.allocator, .init(&f.app, App.view), .{});
        errdefer f.t.deinit();
        const class = std.unicode.utf8ToUtf16LeStringLiteral("myzig-uia-test");
        const wc: w.WNDCLASSEXW = .{ .lpfnWndProc = wndProc, .lpszClassName = class, .hInstance = w.GetModuleHandleW(null) };
        _ = w.RegisterClassExW(&wc);
        // Never shown: no WS_VISIBLE, and nothing shows it.
        f.hwnd = w.CreateWindowExW(0, class, class, 0x00CF0000, 0, 0, 480, 360, null, null, w.GetModuleHandleW(null), null) orelse return error.NoWindow;
        f.acc = try uia.Access.create(testing.allocator, f.hwnd, .{ .ptr = f, .ctx = &f.t.ctx, .perform = perform, .frame_now = frameNow, .scale = scale });
        current = f;
        f.step();
    }

    fn deinit(f: *Fixture) void {
        current = null;
        f.acc.destroy();
        _ = DestroyWindow(f.hwnd);
        f.t.deinit();
    }
};

extern "user32" fn DestroyWindow(h: w.HWND) callconv(.winapi) i32;
extern "ole32" fn CoCreateInstance(clsid: *const com.GUID, outer: ?*anyopaque, ctx: u32, iid: *const com.GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT;

fn name(el: *anyopaque) ![]const u8 {
    var v: api_mod.VARIANT = .{};
    try testing.expectEqual(com.S_OK, com.call(el, 5, .{ @as(i32, api_mod.Prop.name), &v }));
    defer _ = api_mod.api().?.VariantClear(&v);
    if (v.vt != api_mod.VT_BSTR) return "";
    const p: [*:0]const u16 = @ptrFromInt(v.data[0]);
    var buf: [256]u8 = undefined;
    const n = try std.unicode.utf16LeToUtf8(&buf, std.mem.span(p));
    return try testing.allocator.dupe(u8, buf[0..n]);
}

/// The fragment named `want` among the root's descendants, through Navigate.
fn findByName(root: *anyopaque, want: []const u8) !?*anyopaque {
    var child: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, com.call(root, 3, .{ @as(i32, 3), &child }));
    while (child) |c| {
        const simple = com.query(c, &api_mod.iids[0]).?;
        const n = try name(simple);
        defer testing.allocator.free(n);
        if (std.mem.eql(u8, n, want)) {
            com.release(c);
            return simple;
        }
        com.release(simple);
        if (try findByName(c, want)) |found| {
            com.release(c);
            return found;
        }
        var next: ?*anyopaque = null;
        _ = com.call(c, 3, .{ @as(i32, 1), &next });
        com.release(c);
        child = next;
    }
    return null;
}

test "the provider's COM interfaces: names, control types, patterns, invoke" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    if (api_mod.api() == null) return error.SkipZigTest;
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();

    const root = f.acc.root.ptr(.fragment);
    const save = (try findByName(root, "Save")) orelse return error.NoSave;
    defer com.release(save);
    var v: api_mod.VARIANT = .{};
    try testing.expectEqual(com.S_OK, com.call(save, 5, .{ @as(i32, api_mod.Prop.control_type), &v }));
    try testing.expectEqual(@as(u64, 50000), v.data[0]);
    // A button has Invoke, not Toggle.
    var pat: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, com.call(save, 4, .{ @as(i32, 10015), &pat }));
    try testing.expect(pat == null);
    try testing.expectEqual(com.S_OK, com.call(save, 4, .{ @as(i32, 10000), &pat }));
    const invoke = pat orelse return error.NoInvoke;
    try testing.expectEqual(com.S_OK, com.call(invoke, 3, .{}));
    com.release(invoke);
    f.step();
    try testing.expectEqual(@as(u32, 1), f.app.saves);

    const remember = (try findByName(root, "Remember me")) orelse return error.NoCheckbox;
    defer com.release(remember);
    pat = null;
    _ = com.call(remember, 4, .{ @as(i32, 10015), &pat });
    const toggle = pat orelse return error.NoToggle;
    var state: i32 = -1;
    try testing.expectEqual(com.S_OK, com.call(toggle, 4, .{&state}));
    try testing.expectEqual(@as(i32, 0), state);
    _ = com.call(toggle, 3, .{});
    f.step();
    try testing.expect(f.app.remember);
    _ = com.call(toggle, 4, .{&state});
    try testing.expectEqual(@as(i32, 1), state);
    com.release(toggle);

    const volume = (try findByName(root, "Volume")) orelse return error.NoSlider;
    defer com.release(volume);
    pat = null;
    _ = com.call(volume, 4, .{ @as(i32, 10003), &pat });
    const range = pat orelse return error.NoRange;
    var now: f64 = 0;
    _ = com.call(range, 4, .{&now});
    try testing.expectEqual(@as(f64, 0.5), now);
    try testing.expectEqual(com.S_OK, com.call(range, 3, .{@as(f64, 1)}));
    f.step();
    try testing.expect(f.app.volume > 0.5);
    com.release(range);
}

test "UI Automation's client reads the window and acts on it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    if (api_mod.api() == null) return error.SkipZigTest;
    _ = com.CoInitializeEx(null, 2);
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();

    const clsid: com.GUID = .parse("ff48dba4-60ef-4201-aa87-54103eef594e");
    const iid: com.GUID = .parse("30cbe57d-d9d0-452a-ab13-7ac5ac4825ee");
    var client: ?*anyopaque = null;
    if (com.failed(CoCreateInstance(&clsid, null, 1, &iid, &client))) return error.SkipZigTest;
    const automation = client.?;
    defer com.release(automation);
    var window: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, com.call(automation, 6, .{ f.hwnd, &window })); // ElementFromHandle
    defer com.release(window);

    const find = struct {
        fn by(a: *anyopaque, from: *anyopaque, text: []const u8) !*anyopaque {
            var cond: ?*anyopaque = null;
            var v: api_mod.VARIANT = .string(text);
            defer _ = api_mod.api().?.VariantClear(&v);
            try testing.expectEqual(com.S_OK, com.call(a, 23, .{ @as(i32, api_mod.Prop.name), v, &cond })); // CreatePropertyCondition
            defer com.release(cond);
            var el: ?*anyopaque = null;
            try testing.expectEqual(com.S_OK, com.call(from, 5, .{ @as(i32, 4), cond.?, &el })); // FindFirst, descendants
            return el orelse error.NotFound;
        }
    };
    const save = try find.by(automation, window.?, "Save");
    defer com.release(save);
    var v: api_mod.VARIANT = .{};
    try testing.expectEqual(com.S_OK, com.call(save, 10, .{ @as(i32, api_mod.Prop.control_type), &v })); // GetCurrentPropertyValue
    try testing.expectEqual(@as(u64, 50000), v.data[0]);
    var pat: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, com.call(save, 16, .{ @as(i32, 10000), &pat })); // GetCurrentPattern
    const invoke = pat orelse return error.NoInvoke;
    defer com.release(invoke);
    try testing.expectEqual(com.S_OK, com.call(invoke, 3, .{}));
    f.step();
    try testing.expectEqual(@as(u32, 1), f.app.saves);

    const field = try find.by(automation, window.?, "Name");
    defer com.release(field);
    pat = null;
    try testing.expectEqual(com.S_OK, com.call(field, 16, .{ @as(i32, 10002), &pat }));
    const value = pat orelse return error.NoValue;
    defer com.release(value);
    const text = api_mod.bstr("Ada").?;
    defer api_mod.api().?.SysFreeString(text);
    try testing.expectEqual(com.S_OK, com.call(value, 3, .{text})); // SetValue
    f.step();
    try testing.expectEqualStrings("Ada", f.app.name.text());
}

test {
    _ = @import("uia_text_test.zig");
}
