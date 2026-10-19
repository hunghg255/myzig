//! Clicks on toasts after the app has quit: a COM server for them. The
//! app's toasts name a CLSID of its own (derived from its id) through the
//! Start menu shortcut's System.AppUserModel.ToastActivatorCLSID, and
//! HKCU\Software\Classes\CLSID\{...}\LocalServer32 starts the program with
//! `--myzig-toast-activated`. Started so, or running with the class
//! registered, the app hands COM a class factory (CoRegisterClassObject)
//! whose INotificationActivationCallback receives the toast's arguments
//! and what was typed in it; the activation goes to the `Sink`, as the
//! toast's own Activated event does.
const std = @import("std");
const com = @import("com.zig");
const toast = @import("toast.zig");
const xml = @import("toast_xml.zig");
const registry = @import("registry.zig");
const aumid = @import("aumid.zig");

extern "ole32" fn CoRegisterClassObject(clsid: *const com.GUID, unk: *anyopaque, ctx: u32, flags: u32, cookie: *u32) callconv(.winapi) com.HRESULT;
extern "ole32" fn CoRevokeClassObject(cookie: u32) callconv(.winapi) com.HRESULT;

/// The flag COM starts the app with for a click.
pub const flag = "--myzig-toast-activated";

const CLSCTX_LOCAL_SERVER = 0x4;
const REGCLS_MULTIPLEUSE = 1;
const CLASS_E_NOAGGREGATION: com.HRESULT = @bitCast(@as(u32, 0x80040110));
const E_POINTER: com.HRESULT = @bitCast(@as(u32, 0x80004003));

const iid_unknown = com.GUID.parse("00000000-0000-0000-c000-000000000046");
const iid_class_factory = com.GUID.parse("00000001-0000-0000-c000-000000000046");
pub const iid_callback = com.GUID.parse("53e31837-6600-4a81-9395-75cffe746f94");
/// The namespace of the app ids' CLSIDs (a name-based UUID, version 5).
const namespace = com.GUID.parse("6d7a6967-746f-4173-8a74-616374697661");

/// Whether the launch's arguments (`args`, with or without the program)
/// say COM started the app for a click.
pub fn launchedByToast(args: []const []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, flag)) return true;
    return false;
}

/// The CLSID of `id`'s toast activator: the same for the same id, on
/// every machine.
pub fn clsidOf(id: []const u8) com.GUID {
    var h = std.crypto.hash.Sha1.init(.{});
    var ns: [16]u8 = undefined;
    bytesOf(namespace, &ns);
    h.update(&ns);
    h.update(id);
    var d: [20]u8 = undefined;
    h.final(&d);
    var b: [16]u8 = d[0..16].*;
    b[6] = (b[6] & 0x0f) | 0x50;
    b[8] = (b[8] & 0x3f) | 0x80;
    return .{ .a = std.mem.readInt(u32, b[0..4], .big), .b = std.mem.readInt(u16, b[4..6], .big), .c = std.mem.readInt(u16, b[6..8], .big), .d = b[8..16].* };
}

fn bytesOf(g: com.GUID, out: *[16]u8) void {
    std.mem.writeInt(u32, out[0..4], g.a, .big);
    std.mem.writeInt(u16, out[4..6], g.b, .big);
    std.mem.writeInt(u16, out[6..8], g.c, .big);
    out[8..16].* = g.d;
}

/// "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}", as the registry writes CLSIDs.
pub fn format(buf: *[38]u8, g: com.GUID) []const u8 {
    return std.fmt.bufPrint(buf, "{{{X:0>8}-{X:0>4}-{X:0>4}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}}}", .{ g.a, g.b, g.c, g.d[0], g.d[1], g.d[2], g.d[3], g.d[4], g.d[5], g.d[6], g.d[7] }) catch unreachable;
}

/// HKCU's key of the class: Software\Classes\CLSID\{...}\LocalServer32.
fn serverKey(buf: *[96]u8, id: []const u8) []const u8 {
    var g: [38]u8 = undefined;
    return std.fmt.bufPrint(buf, "Software\\Classes\\CLSID\\{s}\\LocalServer32", .{format(&g, clsidOf(id))}) catch unreachable;
}

/// The command COM runs for a click: the program, quoted, and the flag.
pub fn command(gpa: std.mem.Allocator) ![]u8 {
    var buf: [1024]u16 = undefined;
    const exe = try std.unicode.utf16LeToUtf8Alloc(gpa, aumid.exePath(&buf));
    defer gpa.free(exe);
    return std.fmt.allocPrint(gpa, "\"{s}\" {s}", .{ exe, flag });
}

/// Registers `id`'s class for the current user: COM starts this program
/// with `flag` when a toast is clicked and no instance has the class.
pub fn install(gpa: std.mem.Allocator, id: []const u8) !void {
    var kb: [96]u8 = undefined;
    const key = serverKey(&kb, id);
    const cmd = try command(gpa);
    defer gpa.free(cmd);
    const old = try registry.getString(gpa, key, "");
    defer if (old) |o| gpa.free(o);
    if (old != null and std.mem.eql(u8, old.?, cmd)) return;
    try registry.setString(key, "", cmd);
    var g: [38]u8 = undefined;
    var nb: [96]u8 = undefined;
    const name = std.fmt.bufPrint(&nb, "Software\\Classes\\CLSID\\{s}", .{format(&g, clsidOf(id))}) catch unreachable;
    registry.setString(name, "", id) catch {};
}

/// Whether `id`'s class is registered (the app has shown toasts before).
pub fn installed(gpa: std.mem.Allocator, id: []const u8) bool {
    var kb: [96]u8 = undefined;
    const v = (registry.getString(gpa, serverKey(&kb, id), "") catch return false) orelse return false;
    gpa.free(v);
    return true;
}

/// Removes `id`'s class from the registry (an uninstaller's part).
pub fn uninstall(id: []const u8) void {
    var g: [38]u8 = undefined;
    var nb: [96]u8 = undefined;
    registry.deleteTree(std.fmt.bufPrint(&nb, "Software\\Classes\\CLSID\\{s}", .{format(&g, clsidOf(id))}) catch unreachable) catch {};
}

const InputData = extern struct { key: ?[*:0]const u16, value: ?[*:0]const u16 };

/// The activation COM's arguments describe; null for arguments of other
/// origins.
pub fn activationOf(args: ?[*:0]const u16, data: ?[*]const InputData, count: u32) ?*toast.Activation {
    const ca = std.heap.c_allocator;
    const text = std.unicode.utf16LeToUtf8Alloc(ca, if (args) |a| std.mem.span(a) else &.{}) catch return null;
    defer ca.free(text);
    const parsed = (xml.parseArguments(ca, text) catch return null) orelse return null;
    defer ca.free(parsed.input);
    var reply: ?[]u8 = null;
    if (parsed.input.len > 0) if (data) |d| for (d[0..count]) |item| {
        const k = item.key orelse continue;
        const key = std.unicode.utf16LeToUtf8Alloc(ca, std.mem.span(k)) catch continue;
        defer ca.free(key);
        if (!std.mem.eql(u8, key, parsed.input)) continue;
        reply = std.unicode.utf16LeToUtf8Alloc(ca, if (item.value) |v| std.mem.span(v) else &.{}) catch null;
        break;
    };
    const out = ca.create(toast.Activation) catch null;
    const r = reply orelse ca.dupe(u8, "") catch null;
    if (out == null or r == null) {
        if (out) |o| ca.destroy(o);
        if (r) |x| ca.free(x);
        ca.free(parsed.id);
        ca.free(parsed.action);
        return null;
    }
    out.?.* = .{ .id = parsed.id, .action = parsed.action, .reply = r.?, .via_com = true };
    return out;
}

/// The class factory and the callback it makes: one static object of
/// the process (COM's references never free it).
const Server = extern struct {
    factory: *const FactoryVtbl = &factory_vtbl,
    callback: *const CallbackVtbl = &callback_vtbl,

    const FactoryVtbl = extern struct {
        query: *const fn (*const *const FactoryVtbl, *const com.GUID, *?*anyopaque) callconv(.winapi) com.HRESULT = factoryQuery,
        add_ref: *const fn (*anyopaque) callconv(.winapi) u32 = keep,
        release: *const fn (*anyopaque) callconv(.winapi) u32 = keep,
        create: *const fn (*anyopaque, ?*anyopaque, *const com.GUID, *?*anyopaque) callconv(.winapi) com.HRESULT = createInstance,
        lock: *const fn (*anyopaque, i32) callconv(.winapi) com.HRESULT = lockServer,
    };
    const CallbackVtbl = extern struct {
        query: *const fn (*const *const CallbackVtbl, *const com.GUID, *?*anyopaque) callconv(.winapi) com.HRESULT = callbackQuery,
        add_ref: *const fn (*anyopaque) callconv(.winapi) u32 = keep,
        release: *const fn (*anyopaque) callconv(.winapi) u32 = keep,
        activate: *const fn (*anyopaque, ?[*:0]const u16, ?[*:0]const u16, ?[*]const InputData, u32) callconv(.winapi) com.HRESULT = activate,
    };
    const factory_vtbl: FactoryVtbl = .{};
    const callback_vtbl: CallbackVtbl = .{};
};

var server: Server = .{};
/// Where activations go, set by `register` (and tests); read on COM's thread.
var sink: ?*const toast.Sink = null;
var sink_value: toast.Sink = undefined;

fn keep(_: *anyopaque) callconv(.winapi) u32 {
    return 1;
}

fn factoryQuery(_: *const *const Server.FactoryVtbl, iid: *const com.GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
    if (iid.eql(iid_unknown) or iid.eql(iid_class_factory)) {
        out.* = @ptrCast(&server.factory);
        return com.S_OK;
    }
    out.* = null;
    return com.E_NOINTERFACE;
}

fn callbackQuery(_: *const *const Server.CallbackVtbl, iid: *const com.GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
    if (iid.eql(iid_unknown) or iid.eql(iid_callback)) {
        out.* = @ptrCast(&server.callback);
        return com.S_OK;
    }
    out.* = null;
    return com.E_NOINTERFACE;
}

fn createInstance(_: *anyopaque, outer: ?*anyopaque, iid: *const com.GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
    out.* = null;
    if (outer != null) return CLASS_E_NOAGGREGATION;
    return callbackQuery(&server.callback, iid, out);
}

fn lockServer(_: *anyopaque, _: i32) callconv(.winapi) com.HRESULT {
    return com.S_OK;
}

/// INotificationActivationCallback::Activate(app id, arguments, inputs, count).
fn activate(_: *anyopaque, _: ?[*:0]const u16, args: ?[*:0]const u16, data: ?[*]const InputData, count: u32) callconv(.winapi) com.HRESULT {
    const a = activationOf(args, data, count) orelse return com.S_OK;
    const s = @atomicLoad(?*const toast.Sink, &sink, .acquire);
    if (s) |k| k.func(k.ctx, a) else a.deinit();
    return com.S_OK;
}

fn setSink(s: ?toast.Sink) void {
    @atomicStore(?*const toast.Sink, &sink, null, .release);
    if (s) |v| {
        sink_value = v;
        @atomicStore(?*const toast.Sink, &sink, &sink_value, .release);
    }
}

/// The class factory, as COM receives it (for tests).
pub fn factory() com.Object {
    return @ptrCast(&server.factory);
}

/// The class registered with COM for this process.
pub const Registration = struct {
    cookie: u32,

    pub fn revoke(r: Registration) void {
        _ = CoRevokeClassObject(r.cookie);
        setSink(null);
    }
};

/// Hands COM `id`'s class: clicks reach `to` (on COM's thread) until
/// `revoke`. COM must be initialized on the thread.
pub fn register(id: []const u8, to: toast.Sink) !Registration {
    setSink(to);
    var cookie: u32 = 0;
    const clsid = clsidOf(id);
    if (com.failed(CoRegisterClassObject(&clsid, factory(), CLSCTX_LOCAL_SERVER, REGCLS_MULTIPLEUSE, &cookie))) {
        setSink(null);
        return error.Com;
    }
    return .{ .cookie = cookie };
}

test "the launch flag is found among the arguments" {
    try std.testing.expect(launchedByToast(&.{ "C:\\app.exe", flag }));
    try std.testing.expect(!launchedByToast(&.{ "C:\\app.exe", "-ToastActivated", "--myzig-hidden" }));
    try std.testing.expect(!launchedByToast(&.{}));
}

test "an app id's CLSID: stable, a version 5 UUID, different for another id" {
    const a = clsidOf("com.example.notes");
    try std.testing.expect(a.eql(clsidOf("com.example.notes")));
    try std.testing.expect(!a.eql(clsidOf("com.example.other")));
    try std.testing.expectEqual(@as(u16, 5), a.c >> 12);
    try std.testing.expectEqual(@as(u8, 0b10), a.d[0] >> 6);
    var buf: [38]u8 = undefined;
    const s = format(&buf, a);
    try std.testing.expectEqual(@as(usize, 38), s.len);
    try std.testing.expect(s[0] == '{' and s[37] == '}' and s[9] == '-' and s[24] == '-');
}

test "the class's registry entries, under a test app id, removed after" {
    const gpa = std.testing.allocator;
    var rnd: [4]u8 = undefined;
    std.Io.random(std.Io.Threaded.global_single_threaded.io(), &rnd);
    var idb: [64]u8 = undefined;
    const id = try std.fmt.bufPrint(&idb, "com.myzig.test.activator-{x}", .{std.mem.readInt(u32, &rnd, .little)});
    defer uninstall(id);
    try std.testing.expect(!installed(gpa, id));
    try install(gpa, id);
    try install(gpa, id);
    try std.testing.expect(installed(gpa, id));
    var kb: [96]u8 = undefined;
    const v = (try registry.getString(gpa, serverKey(&kb, id), "")).?;
    defer gpa.free(v);
    const want = try command(gpa);
    defer gpa.free(want);
    try std.testing.expectEqualStrings(want, v);
    try std.testing.expect(std.mem.endsWith(u8, v, "\" " ++ flag) and v[0] == '"');
    uninstall(id);
    try std.testing.expect(!installed(gpa, id));
}

const Got = struct {
    n: usize = 0,
    text: [128]u8 = undefined,
    len: usize = 0,

    fn take(ctx: ?*anyopaque, a: *toast.Activation) void {
        const g: *Got = @ptrCast(@alignCast(ctx));
        defer a.deinit();
        g.n += 1;
        const t = std.fmt.bufPrint(&g.text, "{s}|{s}|{s}|{}", .{ a.id, a.action, a.reply, a.via_com }) catch return;
        g.len = t.len;
    }
};

test "the class factory makes the callback, whose Activate reaches the sink with the action and the reply" {
    _ = com.CoInitializeEx(null, 0x2);
    var got: Got = .{};
    const reg = try register("com.myzig.test.activator", .{ .ctx = &got, .func = Got.take });
    defer reg.revoke();
    var cb: ?com.Object = null;
    try std.testing.expectEqual(CLASS_E_NOAGGREGATION, com.call(factory(), 3, .{ @as(?*anyopaque, @ptrCast(&got)), &iid_callback, &cb }));
    try std.testing.expectEqual(com.S_OK, com.call(factory(), 3, .{ @as(?*anyopaque, null), &iid_callback, &cb }));
    const obj = cb.?;
    defer com.release(obj);
    try std.testing.expect(com.query(obj, &iid_class_factory) == null);
    const args = try xml.arguments(std.testing.allocator, "chat:ada", "reply", "reply1");
    defer std.testing.allocator.free(args);
    const wargs = try com.wide(std.testing.allocator, args);
    defer std.testing.allocator.free(wargs);
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const inputs = [_]InputData{ .{ .key = L("other"), .value = L("no") }, .{ .key = L("reply1"), .value = L("On my way") } };
    const app_id = L("com.myzig.test.activator");
    try std.testing.expectEqual(com.S_OK, com.call(obj, 3, .{ app_id.ptr, wargs.ptr, @as([*]const InputData, &inputs), @as(u32, inputs.len) }));
    try std.testing.expectEqual(@as(usize, 1), got.n);
    try std.testing.expectEqualStrings("chat:ada|reply|On my way|true", got.text[0..got.len]);
    // The toast itself: no action, no reply; others' arguments are dropped.
    const plain = try com.wide(std.testing.allocator, "myzig=1&id=x&action=");
    defer std.testing.allocator.free(plain);
    _ = com.call(obj, 3, .{ app_id.ptr, plain.ptr, @as(?[*]const InputData, null), @as(u32, 0) });
    _ = com.call(obj, 3, .{ app_id.ptr, L("action=viewConversation").ptr, @as(?[*]const InputData, null), @as(u32, 0) });
    try std.testing.expectEqual(@as(usize, 2), got.n);
    try std.testing.expectEqualStrings("x|||true", got.text[0..got.len]);
}
