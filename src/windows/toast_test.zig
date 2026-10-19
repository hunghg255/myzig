//! Toasts without showing one: the notifier and a toast are made for a
//! test id, and the toast's Activated handler is invoked as Windows
//! invokes it, with a fake ToastActivatedEventArgs whose user input is a
//! real ValueSet holding the reply.
const std = @import("std");
const com = @import("com.zig");
const winrt = @import("winrt.zig");
const toast = @import("toast.zig");
const xml = @import("toast_xml.zig");
const app_types = @import("../app_types.zig");

const iid_unknown = com.GUID.parse("00000000-0000-0000-c000-000000000046");
const iid_inspectable = com.GUID.parse("af86e2e0-b12d-4c6a-9c5a-d7aa65101e90");
const iid_property_value_statics = com.GUID.parse("629bdbc8-d932-4ff4-96b9-8d96c5c1e858");

/// ToastActivatedEventArgs: IToastActivatedEventArgs (the arguments) and
/// IToastActivatedEventArgs2 (the user input), one vtable each.
const FakeArgs = extern struct {
    one: *const Vtbl,
    two: *const Vtbl,
    refs: u32 = 1,
    arguments: [*:0]const u8,
    input: ?com.Object,

    const Method = *const fn (*const *const Vtbl, *?*anyopaque) callconv(.winapi) com.HRESULT;
    const Vtbl = extern struct {
        query: *const fn (*const *const Vtbl, *const com.GUID, *?*anyopaque) callconv(.winapi) com.HRESULT = query,
        add_ref: *const fn (*const *const Vtbl) callconv(.winapi) u32 = addRef,
        release: *const fn (*const *const Vtbl) callconv(.winapi) u32 = release,
        iids: *const anyopaque = @ptrCast(&notImpl),
        class_name: *const anyopaque = @ptrCast(&notImpl),
        trust: *const anyopaque = @ptrCast(&notImpl),
        method: Method,
    };
    const vtbl_one: Vtbl = .{ .method = getArguments };
    const vtbl_two: Vtbl = .{ .method = getUserInput };

    fn of(p: *const *const Vtbl) *FakeArgs {
        if (p.* == &vtbl_one) return @fieldParentPtr("one", @constCast(p));
        return @fieldParentPtr("two", @constCast(p));
    }

    fn query(p: *const *const Vtbl, iid: *const com.GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
        const self = of(p);
        if (iid.eql(toast.iid_activated_args) or iid.eql(iid_unknown) or iid.eql(iid_inspectable)) {
            out.* = @ptrCast(&self.one);
        } else if (iid.eql(toast.iid_activated_args2)) {
            out.* = @ptrCast(&self.two);
        } else {
            out.* = null;
            return com.E_NOINTERFACE;
        }
        self.refs += 1;
        return com.S_OK;
    }

    fn addRef(p: *const *const Vtbl) callconv(.winapi) u32 {
        const self = of(p);
        self.refs += 1;
        return self.refs;
    }

    fn release(p: *const *const Vtbl) callconv(.winapi) u32 {
        const self = of(p);
        self.refs -= 1;
        return self.refs;
    }

    fn notImpl() callconv(.winapi) com.HRESULT {
        return com.E_FAIL;
    }

    fn getArguments(p: *const *const Vtbl, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
        out.* = winrt.string(std.mem.span(of(p).arguments)) catch return com.E_FAIL;
        return com.S_OK;
    }

    fn getUserInput(p: *const *const Vtbl, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
        const set = of(p).input orelse return com.E_FAIL;
        com.addRef(set);
        out.* = set;
        return com.S_OK;
    }
};

/// A ValueSet holding `key` = `value` (strings).
fn valueSet(key: []const u8, value: []const u8) !com.Object {
    const map = try winrt.activate("Windows.Foundation.Collections.ValueSet", &winrt.iid_map_string_object);
    errdefer com.release(map);
    const statics = try winrt.factory("Windows.Foundation.PropertyValue", &iid_property_value_statics);
    defer com.release(statics);
    const v = try winrt.string(value);
    defer winrt.free(v);
    var boxed: ?com.Object = null;
    if (com.failed(com.call(statics, winrt.first_method + 12, .{ v, &boxed }))) return error.Com; // CreateString
    defer com.release(boxed);
    const k = try winrt.string(key);
    defer winrt.free(k);
    var replaced: u8 = 0;
    if (com.failed(com.call(map, winrt.first_method + 4, .{ k, boxed.?, &replaced }))) return error.Com; // Insert
    return map;
}

const Got = struct {
    count: usize = 0,
    id: [64]u8 = undefined,
    id_len: usize = 0,
    action: [64]u8 = undefined,
    action_len: usize = 0,
    reply: [64]u8 = undefined,
    reply_len: usize = 0,

    fn take(ctx: ?*anyopaque, a: *toast.Activation) void {
        const g: *Got = @ptrCast(@alignCast(ctx));
        defer a.deinit();
        g.count += 1;
        @memcpy(g.id[0..a.id.len], a.id);
        g.id_len = a.id.len;
        @memcpy(g.action[0..a.action.len], a.action);
        g.action_len = a.action.len;
        @memcpy(g.reply[0..a.reply.len], a.reply);
        g.reply_len = a.reply.len;
    }
};

test "a toast is made for the app's id and its activation carries the action and the reply" {
    const gpa = std.testing.allocator;
    _ = com.CoInitializeEx(null, 0x2);
    if (!winrt.load()) return error.SkipZigTest;
    var got: Got = .{};
    const t = toast.Toaster.create(gpa, "com.myzig.test.toast", .{ .ctx = &got, .func = Got.take }) catch |e| {
        if (e == error.Unsupported or e == error.ClassNotRegistered) return error.SkipZigTest;
        return e;
    };
    defer t.destroy();
    // An id without a shortcut or package: Windows would show nothing.
    _ = t.enabled();
    const n: app_types.Notification = .{ .id = "chat:ada", .title = "Ada & Bob", .body = "Lunch?" };
    const made = try t.make(n);
    defer com.release(made);
    const tag = try toast.tagOf(gpa, made);
    defer gpa.free(tag);
    try std.testing.expectEqualStrings("chat:ada", tag);
    // With buttons and a reply's field.
    const with = try t.make(@import("../notify_types.zig").WithActions{ .id = "chat:bob", .title = "Bob", .actions = &.{
        .{ .id = "reply", .title = "Reply", .reply = true, .placeholder = "Message" },
        .{ .id = "read", .title = "Mark as Read", .destructive = true },
    } });
    com.release(with);
    try t.keep(n.id, made);
    try t.keep(n.id, made); // the same id again: one kept
    try std.testing.expectEqual(@as(usize, 1), t.kept.items.len);

    // A click on a button with a reply typed.
    const args_text = try xml.arguments(gpa, "chat:ada", "reply", "reply1");
    defer gpa.free(args_text);
    const z = try gpa.alloc(u8, args_text.len + 1);
    defer gpa.free(z);
    @memcpy(z[0..args_text.len], args_text);
    z[args_text.len] = 0;
    const input = try valueSet("reply1", "Sure, at noon");
    defer com.release(input);
    var fake: FakeArgs = .{ .one = &FakeArgs.vtbl_one, .two = &FakeArgs.vtbl_two, .arguments = @ptrCast(z.ptr), .input = input };
    const h = t.activatedHandler();
    try std.testing.expectEqual(com.S_OK, com.call(h, 3, .{ @as(usize, 0), @intFromPtr(&fake.one) }));
    try std.testing.expectEqual(@as(usize, 1), got.count);
    try std.testing.expectEqualStrings("chat:ada", got.id[0..got.id_len]);
    try std.testing.expectEqualStrings("reply", got.action[0..got.action_len]);
    try std.testing.expectEqualStrings("Sure, at noon", got.reply[0..got.reply_len]);

    // The toast itself: no action, no reply.
    var plain: FakeArgs = .{ .one = &FakeArgs.vtbl_one, .two = &FakeArgs.vtbl_two, .arguments = "myzig=1&id=chat%3Aada&action=", .input = null };
    _ = com.call(h, 3, .{ @as(usize, 0), @intFromPtr(&plain.one) });
    try std.testing.expectEqual(@as(usize, 2), got.count);
    try std.testing.expectEqual(@as(usize, 0), got.action_len);
    try std.testing.expectEqual(@as(usize, 0), got.reply_len);
    // Another app's arguments reach nobody.
    var other: FakeArgs = .{ .one = &FakeArgs.vtbl_one, .two = &FakeArgs.vtbl_two, .arguments = "conversationId=9813", .input = null };
    _ = com.call(h, 3, .{ @as(usize, 0), @intFromPtr(&other.one) });
    try std.testing.expectEqual(@as(usize, 2), got.count);
    try std.testing.expectEqual(@as(u32, 1), fake.refs);
}
