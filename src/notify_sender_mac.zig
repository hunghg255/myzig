//! Notifications of incoming direct messages on macOS 12 and later (after
//! mygo): the sender's avatar shows with the app's small icon. The
//! message is an INSendMessageIntent with the sender as an INPerson,
//! donated to SiriKit as an incoming interaction, whose content then
//! updates the notification's (`contentByUpdatingWithProvider:error:`).
//! It needs the signed entitlement
//! `com.apple.developer.usernotifications.communication`, checked first;
//! without it, with an incomplete sender or an avatar that isn't an
//! image, or when the donation or the update fails, the ordinary
//! notification shows. Intents is loaded only for such a notification.
const std = @import("std");
const objc = @import("objc.zig");
const app_types = @import("app_types.zig");

extern "c" fn objc_getClass(name: [*:0]const u8) ?objc.Class;
extern "c" fn CFRelease(obj: *anyopaque) void;

var authorization: enum { unknown, granted, denied } = .unknown;

/// Whether the app may show communication notifications: Intents has
/// what they need, and the app is signed with the entitlement.
fn authorized() bool {
    if (authorization == .unknown) authorization = if (checkAuthorization()) .granted else .denied;
    return authorization == .granted;
}

fn checkAuthorization() bool {
    _ = std.c.dlopen("/System/Library/Frameworks/Intents.framework/Intents", .{ .NOW = true, .GLOBAL = true }) orelse return false;
    if (objc_getClass("INSendMessageIntent") == null) return false;
    const content = objc_getClass("UNMutableNotificationContent") orelse return false;
    if (!objc.msg(objc.BOOL, content, "instancesRespondToSelector:", .{objc.sel("contentByUpdatingWithProvider:error:")})) return false;
    const security = std.c.dlopen("/System/Library/Frameworks/Security.framework/Security", .{ .NOW = true }) orelse return false;
    const create: *const fn (?*anyopaque) callconv(.c) ?*anyopaque = @ptrCast(@alignCast(std.c.dlsym(security, "SecTaskCreateFromSelf") orelse return false));
    const copy: *const fn (*anyopaque, objc.Object, ?*anyopaque) callconv(.c) ?objc.Object = @ptrCast(@alignCast(std.c.dlsym(security, "SecTaskCopyValueForEntitlement") orelse return false));
    const task = create(null) orelse return false;
    defer CFRelease(task);
    const value = copy(task, objc.nsString("com.apple.developer.usernotifications.communication"), null) orelse return false;
    defer CFRelease(value);
    return objc.msg(objc.BOOL, value, "respondsToSelector:", .{objc.sel("boolValue")}) and objc.msg(objc.BOOL, value, "boolValue", .{});
}

/// The text of the message: the subtitle above the body, as macOS lays
/// communication notifications out without a subtitle of their own.
pub fn messageText(buf: []u8, subtitle: []const u8, body: []const u8) []const u8 {
    if (subtitle.len == 0) return body;
    if (body.len == 0) return subtitle;
    return std.fmt.bufPrint(buf, "{s}\n{s}", .{ subtitle, body }) catch body;
}

/// Whether `s` makes a sender notification: an id and an avatar.
pub fn complete(s: app_types.NotificationSender) bool {
    return s.id.len > 0 and s.avatar.len > 0;
}

/// An owned INSendMessageIntent of `n`, or null for an incomplete sender.
fn intentOf(n: app_types.Notification, id: []const u8) ?objc.Object {
    const s = n.sender orelse return null;
    if (!complete(s)) return null;
    const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ s.avatar.ptr, s.avatar.len });
    const decoded = objc.msg(?objc.Object, objc.alloc("NSImage"), "initWithData:", .{data}) orelse return null;
    objc.release(decoded);
    // INPersonHandleTypeUnknown: the id is the app's, not contact details.
    const handle = objc.msg(objc.Object, objc.msg(objc.Object, objc.msg(objc.Object, objc_getClass("INPersonHandle").?, "alloc", .{}), "initWithValue:type:", .{ objc.nsString(s.id), @as(objc.NSInteger, 0) }), "autorelease", .{});
    const image = objc.msg(objc.Object, objc_getClass("INImage").?, "imageWithImageData:", .{data});
    const name = if (s.name.len > 0) s.name else n.title;
    const person = objc.msg(objc.Object, objc.msg(objc.Object, objc_getClass("INPerson").?, "alloc", .{}), "initWithPersonHandle:nameComponents:displayName:image:contactIdentifier:customIdentifier:isMe:suggestionType:", .{
        handle, @as(?objc.Object, null), objc.nsString(name), image, @as(?objc.Object, null), objc.nsString(s.id), objc.NO, @as(objc.NSInteger, 0),
    });
    defer objc.release(person);
    var buf: [2048]u8 = undefined;
    const text = messageText(&buf, n.subtitle, n.body);
    const conversation = if (n.group.len > 0) n.group else id;
    // INOutgoingMessageTypeOutgoingMessageText.
    return objc.msg(objc.Object, objc.msg(objc.Object, objc_getClass("INSendMessageIntent").?, "alloc", .{}), "initWithRecipients:outgoingMessageType:content:speakableGroupName:conversationIdentifier:serviceName:sender:attachments:", .{
        @as(?objc.Object, null), @as(objc.NSInteger, 1), objc.nsString(text), @as(?objc.Object, null), objc.nsString(conversation), @as(?objc.Object, null), person, @as(?objc.Object, null),
    });
}

/// A notification waiting for its donation to finish.
const Pending = struct {
    center: objc.Object,
    content: objc.Object,
    intent: objc.Object,
    interaction: objc.Object,
    id: []u8,
    failed: bool = false,
    /// Removed, replaced or cleared meanwhile: it never shows.
    canceled: bool = false,
};

var pending: std.ArrayList(*Pending) = .empty;

/// Starts showing `content` as a communication notification of `n`
/// under `id`; false when it can't, and the caller shows it as is.
pub fn prepare(center: objc.Object, content: objc.Object, id: []const u8, n: app_types.Notification) bool {
    cancel(id);
    if (n.sender == null or !authorized()) return false;
    const intent = intentOf(n, id) orelse return false;
    const gpa = std.heap.c_allocator;
    const p = gpa.create(Pending) catch {
        objc.release(intent);
        return false;
    };
    const owned_id = gpa.dupe(u8, id) catch {
        gpa.destroy(p);
        objc.release(intent);
        return false;
    };
    const interaction = objc.msg(objc.Object, objc.msg(objc.Object, objc_getClass("INInteraction").?, "alloc", .{}), "initWithIntent:response:", .{ intent, @as(?objc.Object, null) });
    objc.msg(void, interaction, "setDirection:", .{@as(objc.NSInteger, 2)}); // INInteractionDirectionIncoming
    p.* = .{ .center = center, .content = objc.retain(content), .intent = intent, .interaction = interaction, .id = owned_id };
    pending.append(gpa, p) catch {};
    var block = objc.Block(Pending, &.{?objc.Object}).init(p, donated);
    objc.msg(void, interaction, "donateInteractionWithCompletion:", .{&block});
    return true;
}

/// The donation finished, on a queue of SiriKit's: the rest is the main
/// thread's.
fn donated(p: *Pending, err: ?objc.Object) void {
    p.failed = err != null;
    objc.dispatchMain(p, finish);
}

fn finish(arg: ?*anyopaque) callconv(.c) void {
    const p: *Pending = @ptrCast(@alignCast(arg));
    const gpa = std.heap.c_allocator;
    const pool = objc.Pool.push();
    defer pool.pop();
    defer {
        for (pending.items, 0..) |x, i| if (x == p) {
            _ = pending.swapRemove(i);
            break;
        };
        objc.release(p.content);
        objc.release(p.intent);
        objc.release(p.interaction);
        gpa.free(p.id);
        gpa.destroy(p);
    }
    if (p.canceled) return;
    var ready = p.content;
    if (!p.failed) {
        // The ordinary content stays where the update fails.
        const copy = objc.msg(objc.Object, p.content, "mutableCopy", .{});
        objc.autorelease(copy);
        objc.msg(void, copy, "setBody:", .{objc.msg(objc.Object, p.intent, "content", .{})});
        var err: ?objc.Object = null;
        if (objc.msg(?objc.Object, copy, "contentByUpdatingWithProvider:error:", .{ p.intent, &err })) |updated| {
            if (err == null) ready = updated;
        }
    }
    const request = objc.msg(objc.Object, objc_getClass("UNNotificationRequest").?, "requestWithIdentifier:content:trigger:", .{ objc.nsString(p.id), ready, @as(?objc.Object, null) });
    objc.msg(void, p.center, "addNotificationRequest:withCompletionHandler:", .{ request, @as(?*anyopaque, null) });
}

/// The notification `id` is removed or replaced: one still being
/// prepared never shows.
pub fn cancel(id: []const u8) void {
    for (pending.items) |p| if (std.mem.eql(u8, p.id, id)) {
        p.canceled = true;
    };
}

test "a sender notification's text and completeness" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Lunch\nSee you at noon", messageText(&buf, "Lunch", "See you at noon"));
    try std.testing.expectEqualStrings("See you", messageText(&buf, "", "See you"));
    try std.testing.expectEqualStrings("Lunch", messageText(&buf, "Lunch", ""));
    try std.testing.expect(complete(.{ .id = "user:ada", .avatar = "\x89PNG" }));
    try std.testing.expect(!complete(.{ .id = "", .avatar = "\x89PNG" }));
    try std.testing.expect(!complete(.{ .id = "user:ada" }));
}
