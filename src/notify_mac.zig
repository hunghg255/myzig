//! Notifications on macOS: UNUserNotificationCenter (the framework loaded
//! when first used). It needs an app bundle with an identifier: a plain
//! binary gets `error.NeedsBundle`. The first notification asks the user
//! for permission; clicks reach the delegate, then the app's handler.
//! A notification's actions are a category's (UNNotificationCategory),
//! registered once per set of actions; one taking a reply is a
//! UNTextInputNotificationAction, whose text the response carries.
const std = @import("std");
const objc = @import("objc.zig");
const app_types = @import("app_types.zig");
const notify_types = @import("notify_types.zig");
const sender = @import("notify_sender_mac.zig");

var loaded = false;
var delegate: ?objc.Object = null;
var handler: ?app_types.Handler(app_types.NotificationResponse) = null;
var asked = false;

fn center() !objc.Object {
    const bundle = objc.msg(objc.Object, objc.class("NSBundle"), "mainBundle", .{});
    if (objc.msg(?objc.Object, bundle, "bundleIdentifier", .{}) == null) return error.NeedsBundle;
    if (!loaded) {
        _ = std.c.dlopen("/System/Library/Frameworks/UserNotifications.framework/UserNotifications", .{ .NOW = true });
        loaded = true;
    }
    if (lookUp("UNUserNotificationCenter") == null) return error.Unsupported;
    return objc.msg(objc.Object, lookUp("UNUserNotificationCenter").?, "currentNotificationCenter", .{});
}

const AuthCtx = struct {};
var auth_ctx: AuthCtx = .{};

fn authorized(_: *AuthCtx, _: objc.BOOL, _: ?objc.Object) void {}

/// Calls a completion handler block taking no argument or one integer.
fn callBlock(block: objc.Object, arg: ?objc.NSUInteger) void {
    const Layout = extern struct { isa: *anyopaque, flags: i32, reserved: i32, invoke: *const anyopaque };
    const b: *const Layout = @ptrCast(@alignCast(block));
    if (arg) |a| {
        const f: *const fn (objc.Object, objc.NSUInteger) callconv(.c) void = @ptrCast(@alignCast(b.invoke));
        f(block, a);
    } else {
        const f: *const fn (objc.Object) callconv(.c) void = @ptrCast(@alignCast(b.invoke));
        f(block);
    }
}

fn didReceive(_: objc.Object, _: objc.SEL, _: objc.Object, response: objc.Object, done: objc.Object) callconv(.c) void {
    const notification = objc.msg(objc.Object, response, "notification", .{});
    const request = objc.msg(objc.Object, notification, "request", .{});
    const id = objc.fromNSString(objc.msg(?objc.Object, request, "identifier", .{}));
    const action = objc.fromNSString(objc.msg(?objc.Object, response, "actionIdentifier", .{}));
    const default = std.mem.eql(u8, action, "com.apple.UNNotificationDefaultActionIdentifier");
    // UNTextInputNotificationResponse: what the user typed.
    const reply = if (objc.msg(objc.BOOL, response, "respondsToSelector:", .{objc.sel("userText")}))
        objc.fromNSString(objc.msg(?objc.Object, response, "userText", .{}))
    else
        "";
    if (handler) |h| h.call(notify_types.response(id, if (default) "" else action, reply));
    callBlock(done, null);
}

fn willPresent(_: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object, done: objc.Object) callconv(.c) void {
    // Banner, list and sound, also while the app is in front.
    callBlock(done, (1 << 4) | (1 << 3) | (1 << 1));
}

/// Where clicks go (`App.options.on_notification`).
pub fn setHandler(h: ?app_types.Handler(app_types.NotificationResponse)) void {
    handler = h;
}

fn setUp(c: objc.Object) void {
    if (delegate != null) return;
    const cls = objc.defineClass(.{
        .name = "MyZigNotificationDelegate",
        .protocols = &.{"UNUserNotificationCenterDelegate"},
        .methods = &.{
            .{ .name = "userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:", .imp = &didReceive, .types = "v@:@@@?" },
            .{ .name = "userNotificationCenter:willPresentNotification:withCompletionHandler:", .imp = &willPresent, .types = "v@:@@@?" },
        },
    });
    const d = objc.msg(objc.Object, cls, "new", .{});
    delegate = d;
    objc.msg(void, c, "setDelegate:", .{d});
}

/// Shows `n` (an `app_types.Notification`).
pub fn notify(n: anytype) !void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const c = try center();
    setUp(c);
    if (!asked) {
        asked = true;
        var block = objc.Block(AuthCtx, &.{ objc.BOOL, ?objc.Object }).init(&auth_ctx, authorized);
        // Alert, sound, badge.
        objc.msg(void, c, "requestAuthorizationWithOptions:completionHandler:", .{ @as(objc.NSUInteger, 7), &block });
    }
    const content = objc.msg(objc.Object, lookUp("UNMutableNotificationContent").?, "new", .{});
    defer objc.release(content);
    objc.msg(void, content, "setTitle:", .{objc.nsString(n.title)});
    if (n.subtitle.len > 0) objc.msg(void, content, "setSubtitle:", .{objc.nsString(n.subtitle)});
    if (n.body.len > 0) objc.msg(void, content, "setBody:", .{objc.nsString(n.body)});
    if (!n.silent) objc.msg(void, content, "setSound:", .{objc.msg(objc.Object, lookUp("UNNotificationSound").?, "defaultSound", .{})});
    const acts = notify_types.actions(n);
    if (acts.len > 0) {
        var cb: [40]u8 = undefined;
        const category = categoryId(&cb, acts);
        register(c, category, acts);
        objc.msg(void, content, "setCategoryIdentifier:", .{objc.nsString(category)});
    }
    var idb: [64]u8 = undefined;
    const id = if (n.id.len > 0) n.id else std.fmt.bufPrint(&idb, "myzig-{d}", .{@intFromPtr(content)}) catch "myzig";
    if (n.group.len > 0) objc.msg(void, content, "setThreadIdentifier:", .{objc.nsString(n.group)});
    // One being prepared under the id is replaced.
    sender.cancel(id);
    // An incoming message's: shown once SiriKit has the sender.
    if (n.sender != null and sender.prepare(c, content, id, n)) return;
    const request = objc.msg(objc.Object, lookUp("UNNotificationRequest").?, "requestWithIdentifier:content:trigger:", .{ objc.nsString(id), content, @as(?objc.Object, null) });
    objc.msg(void, c, "addNotificationRequest:withCompletionHandler:", .{ request, @as(?*anyopaque, null) });
}

pub fn remove(id: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    sender.cancel(id);
    const c = center() catch return;
    const ids = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{objc.nsString(id)});
    objc.msg(void, c, "removeDeliveredNotificationsWithIdentifiers:", .{ids});
    objc.msg(void, c, "removePendingNotificationRequestsWithIdentifiers:", .{ids});
}

/// The categories registered so far (retained): the center takes them all at once.
var categories: ?objc.Object = null;

/// The id of the category of `acts`: the same actions, the same category.
pub fn categoryId(buf: *[40]u8, acts: []const notify_types.Action) []const u8 {
    var h = std.hash.Wyhash.init(0);
    for (acts) |a| {
        h.update(a.id);
        h.update("\x00");
        h.update(a.title);
        h.update("\x00");
        h.update(a.placeholder);
        h.update(&.{ @intFromBool(a.reply), @intFromBool(a.destructive) });
    }
    return std.fmt.bufPrint(buf, "myzig.actions.{x:0>16}", .{h.final()}) catch unreachable;
}

/// UNNotificationActionOptions of an action: destructive (1 << 1), and
/// foreground (1 << 2), which brings the app forward as the user picks it.
pub fn actionOptions(a: notify_types.Action) objc.NSUInteger {
    var o: objc.NSUInteger = 1 << 2;
    if (a.destructive) o |= 1 << 1;
    return o;
}

/// Registers the category `id` of `acts` with the center, once.
fn register(c: objc.Object, id: []const u8, acts: []const notify_types.Action) void {
    if (categories == null) categories = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSMutableSet"), "alloc", .{}), "init", .{});
    const set = categories.?;
    const enumerator = objc.msg(objc.Object, set, "objectEnumerator", .{});
    while (objc.msg(?objc.Object, enumerator, "nextObject", .{})) |cat| {
        if (std.mem.eql(u8, objc.fromNSString(objc.msg(?objc.Object, cat, "identifier", .{})), id)) return;
    }
    const list = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    for (acts) |a| {
        const action = if (a.reply)
            objc.msg(objc.Object, lookUp("UNTextInputNotificationAction").?, "actionWithIdentifier:title:options:textInputButtonTitle:textInputPlaceholder:", .{ objc.nsString(a.id), objc.nsString(a.title), actionOptions(a), objc.nsString(a.title), objc.nsString(a.placeholder) })
        else
            objc.msg(objc.Object, lookUp("UNNotificationAction").?, "actionWithIdentifier:title:options:", .{ objc.nsString(a.id), objc.nsString(a.title), actionOptions(a) });
        objc.msg(void, list, "addObject:", .{action});
    }
    const empty = objc.msg(objc.Object, objc.class("NSArray"), "array", .{});
    const cat = objc.msg(objc.Object, lookUp("UNNotificationCategory").?, "categoryWithIdentifier:actions:intentIdentifiers:options:", .{ objc.nsString(id), list, empty, @as(objc.NSUInteger, 0) });
    objc.msg(void, set, "addObject:", .{cat});
    objc.msg(void, c, "setNotificationCategories:", .{set});
}

test "a category per set of actions; actions' options" {
    var a: [40]u8 = undefined;
    var b: [40]u8 = undefined;
    const reply: notify_types.Action = .{ .id = "reply", .title = "Reply", .reply = true };
    const read: notify_types.Action = .{ .id = "read", .title = "Mark as Read", .destructive = true };
    const one = categoryId(&a, &.{ reply, read });
    try std.testing.expect(std.mem.startsWith(u8, one, "myzig.actions."));
    try std.testing.expectEqualStrings(one, categoryId(&b, &.{ reply, read }));
    try std.testing.expect(!std.mem.eql(u8, one, categoryId(&b, &.{read})));
    try std.testing.expectEqual(@as(objc.NSUInteger, 6), actionOptions(read));
    try std.testing.expectEqual(@as(objc.NSUInteger, 4), actionOptions(reply));
}

extern "c" fn objc_getClass(name: [*:0]const u8) ?objc.Class;

/// A class of a framework that may not be loaded, or null.
fn lookUp(name: [*:0]const u8) ?objc.Class {
    return objc_getClass(name);
}
